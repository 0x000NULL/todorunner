#Requires -Version 7.0
# Run-Todos.ps1 — Autonomous todo-runner for Claude Code (pwsh 7+, cross-platform).
# Drop a todo.md in a project, run this script, watch Claude work through items
# via a plan->execute split with fresh sessions per phase.
#
# Windows note: the claude binary resolves as claude.cmd; Get-Command handles both.

[CmdletBinding()]
param(
    [decimal]$CostCeilingPerItem = 3.00,
    [int]$MaxIterations = 50,
    [string]$TodoFile = './todo.md',
    [string]$NeedsReviewFile = './needs-review.md',
    [switch]$DryRunPlan,
    [switch]$SkipPlan,
    [switch]$ProceedOnBlockers,
    [switch]$PlanAllFirst,
    [ValidateSet('stash','reset')]
    [string]$RollbackStrategy = 'stash',
    [int]$MaxTurns = 30,
    [switch]$SkipDepProbe,
    [int]$VerifyFingerprintConsecLimit = 3,
    [int]$VerifyFingerprintTotalLimit  = 5
)

$ErrorActionPreference = 'Stop'
$script:PlansDir    = Join-Path '.claude' 'plans'
$script:RunnerDir   = Join-Path '.claude' 'todo-runner'
$script:RunsLog     = Join-Path $script:RunnerDir 'runs.jsonl'
$script:BlockersDb  = Join-Path $script:RunnerDir 'blockers.json'
$script:VerifyFailDb = Join-Path $script:RunnerDir 'verify-fails.json'
$script:Transcripts = Join-Path $script:RunnerDir 'transcripts'
$script:HaltFile    = './HALT.md'
$script:ClaudeExe   = $null  # resolved in pre-flight
$script:BashExe     = $null  # resolved in pre-flight

# ---------------------------------------------------------------------------
# Pre-flight dep registry (Upgrade 5)
# ---------------------------------------------------------------------------
# Crates that pull in C-library system deps which the autonomous runner cannot
# install. If the project's Cargo.toml declares one of these, run the matching
# Probe at startup; on miss, write HALT.md and exit before any item runs.
#
# Each entry is matched against Cargo.toml lines via Pattern (regex). If
# SkipIfLineContains is set and the matching line contains that substring,
# the probe is skipped (e.g. openssl-sys with `vendored`, rdkafka-sys with
# `cmake-build`). WarnOnly entries log a warning instead of halting — used
# for deps where the probe path is fragile (Windows + librdkafka).

$script:DepRegistry = @(
    [pscustomobject]@{
        Pattern            = '^\s*(tesseract|leptonica-sys)\s*='
        Description        = 'leptonica + tesseract C libraries (tesseract / leptonica-sys)'
        InstallWindows     = 'vcpkg install leptonica tesseract; setx VCPKG_ROOT C:\path\to\vcpkg'
        InstallLinux       = 'apt-get install libleptonica-dev libtesseract-dev'
        InstallMac         = 'brew install leptonica tesseract'
        WarnOnly           = $false
        SkipIfLineContains = $null
        Probe              = {
            if ($IsWindows) {
                if ($env:VCPKG_ROOT -and (Test-Path (Join-Path $env:VCPKG_ROOT 'installed\x64-windows\include\leptonica'))) { return $true }
                if (Get-Command tesseract -ErrorAction SilentlyContinue) { return $true }
                return $false
            }
            if (-not (Get-Command pkg-config -ErrorAction SilentlyContinue)) { return $false }
            & pkg-config --exists lept tesseract 2>$null
            return ($LASTEXITCODE -eq 0)
        }
    }
    [pscustomobject]@{
        Pattern            = '^\s*openssl-sys\s*='
        Description        = 'OpenSSL development headers (openssl-sys)'
        InstallWindows     = 'vcpkg install openssl; setx VCPKG_ROOT C:\path\to\vcpkg'
        InstallLinux       = 'apt-get install libssl-dev pkg-config'
        InstallMac         = 'brew install openssl@3 pkg-config'
        WarnOnly           = $false
        SkipIfLineContains = 'vendored'
        Probe              = {
            if ($IsWindows) {
                return ($env:VCPKG_ROOT -and (Test-Path (Join-Path $env:VCPKG_ROOT 'installed\x64-windows\include\openssl')))
            }
            if (-not (Get-Command pkg-config -ErrorAction SilentlyContinue)) { return $false }
            & pkg-config --exists openssl 2>$null
            return ($LASTEXITCODE -eq 0)
        }
    }
    [pscustomobject]@{
        Pattern            = '^\s*rdkafka-sys\s*='
        Description        = 'librdkafka (rdkafka-sys)'
        InstallWindows     = '(unsupported on Windows without manual setup; use -SkipDepProbe)'
        InstallLinux       = 'apt-get install librdkafka-dev pkg-config'
        InstallMac         = 'brew install librdkafka pkg-config'
        WarnOnly           = $true
        SkipIfLineContains = 'cmake-build'
        Probe              = {
            if ($IsWindows) { return $true }
            if (-not (Get-Command pkg-config -ErrorAction SilentlyContinue)) { return $false }
            & pkg-config --exists rdkafka 2>$null
            return ($LASTEXITCODE -eq 0)
        }
    }
)

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

function Write-Phase   { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok      { param($m) Write-Host "    $m" -ForegroundColor Green }
function Write-Review  { param($m) Write-Host "    $m" -ForegroundColor Yellow }
function Write-Halt    { param($m) Write-Host "!!  $m" -ForegroundColor Red }
function Write-Info2   { param($m) Write-Host "    $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

function Invoke-DepProbe {
    # Upgrade 5 — scan Cargo.toml for known-fragile crates and probe their
    # system deps before any item runs. On hard miss, write HALT.md + exit 6.
    # On warn-only miss, just log a warning. Bypassed entirely with
    # -SkipDepProbe.
    if ($SkipDepProbe) { return }
    if (-not (Test-Path './Cargo.toml')) { return }

    $cargo = Get-Content -Path './Cargo.toml' -Raw -ErrorAction SilentlyContinue
    if (-not $cargo) { return }
    $lines = $cargo -split "`r?`n"

    $missing  = @()
    $seenDesc = @{}

    foreach ($entry in $script:DepRegistry) {
        # find the first matching line for this entry; skip if SkipIfLineContains hits
        $matchedLine = $null
        foreach ($line in $lines) {
            if ($line -match $entry.Pattern) {
                if ($entry.SkipIfLineContains -and ($line -like "*$($entry.SkipIfLineContains)*")) { continue }
                $matchedLine = $line
                break
            }
        }
        if (-not $matchedLine) { continue }
        if ($seenDesc.ContainsKey($entry.Description)) { continue }
        $seenDesc[$entry.Description] = $true

        try {
            $passed = & $entry.Probe
        } catch {
            $passed = $false
        }
        if (-not $passed) { $missing += $entry }
    }

    if (-not $missing) { return }

    # Warn-only entries log + drop; hard entries accumulate for HALT.
    $warnOnly = @($missing | Where-Object { $_.WarnOnly })
    foreach ($e in $warnOnly) {
        Write-Warning "Possible missing system dep: $($e.Description). Install hint:"
        if ($IsWindows)  { Write-Warning "  $($e.InstallWindows)" }
        elseif ($IsMacOS) { Write-Warning "  $($e.InstallMac)" }
        else              { Write-Warning "  $($e.InstallLinux)" }
    }
    $hard = @($missing | Where-Object { -not $_.WarnOnly })
    if (-not $hard) { return }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# HALT: missing system dependency")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("``Cargo.toml`` declares crates that need C-library headers/binaries which are not detected on this system. Install the missing libraries and re-run, or pass ``-SkipDepProbe`` to bypass this check (useful for non-default toolchains like MinGW/MSYS2 with custom prefixes).")
    [void]$sb.AppendLine("")
    foreach ($e in $hard) {
        [void]$sb.AppendLine("## $($e.Description)")
        [void]$sb.AppendLine("Install:")
        [void]$sb.AppendLine("- **Windows:** ``$($e.InstallWindows)``")
        [void]$sb.AppendLine("- **Linux:**   ``$($e.InstallLinux)``")
        [void]$sb.AppendLine("- **macOS:**   ``$($e.InstallMac)``")
        [void]$sb.AppendLine("")
    }
    Set-Content -Path $script:HaltFile -Value $sb.ToString() -Encoding utf8
    Write-Halt "Missing system dep(s); HALT.md written. Install or rerun with -SkipDepProbe."
    foreach ($e in $hard) { Write-Halt "  - $($e.Description)" }
    exit 6
}

function Invoke-PreFlight {
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claude) {
        throw "claude CLI not found on PATH. Install from https://claude.com/code and ensure `claude --version` runs."
    }
    $script:ClaudeExe = $claude.Source

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git not found on PATH."
    }

    # Resolve bash for Test-Verify. On Windows we MUST prefer Git Bash over
    # WSL bash (`C:\Windows\system32\bash.exe`) — WSL translates paths
    # (`C:/foo` becomes `/mnt/c/foo`) which breaks relative-path verifies
    # and confuses cargo. Git Bash is MSYS-flavored and behaves like a
    # normal POSIX shell with a Windows view of the filesystem.
    $script:BashExe = $null
    if ($IsWindows) {
        $candidates = @()
        $git = (Get-Command git -ErrorAction SilentlyContinue).Source
        if ($git) {
            $gitDir = Split-Path (Split-Path $git -Parent) -Parent
            $candidates += Join-Path $gitDir 'bin\bash.exe'
            $candidates += Join-Path $gitDir 'usr\bin\bash.exe'
        }
        $candidates += @(
            'C:\Program Files\Git\bin\bash.exe',
            'C:\Program Files\Git\usr\bin\bash.exe',
            'C:\Program Files (x86)\Git\bin\bash.exe'
        )
        foreach ($c in $candidates) {
            if ($c -and (Test-Path $c)) { $script:BashExe = $c; break }
        }
    } else {
        $script:BashExe = (Get-Command bash -ErrorAction SilentlyContinue).Source
    }
    if (-not $script:BashExe) {
        Write-Warning "No POSIX bash found (Git Bash on Windows / system bash on POSIX). Verify commands will fall back to pwsh, which doesn't support 'test', 'grep', '/dev/null', etc. Plans may need pwsh-only verifies to pass."
    } else {
        Write-Verbose "Using bash: $script:BashExe"
    }

    try {
        $inRepo = (git rev-parse --is-inside-work-tree 2>$null).Trim()
    } catch { $inRepo = 'false' }
    if ($inRepo -ne 'true') {
        throw "Current directory is not inside a git repository. Run 'git init' first (rollback and per-item commits depend on it)."
    }

    if (-not (Test-Path $TodoFile)) {
        throw "Todo file not found: $TodoFile"
    }

    $dirty = git status --porcelain
    if ($dirty) {
        Write-Warning "Working tree is dirty. Runner will create commits interleaved with your uncommitted work. Consider 'git worktree add ../todo-run' first."
    }

    # Upgrade 5 — fail-fast on missing system deps (vcpkg/leptonica/etc.)
    # before we modify any state. Probe is a no-op for non-Rust projects or
    # when -SkipDepProbe is set.
    Invoke-DepProbe

    foreach ($d in @($script:PlansDir, $script:RunnerDir, $script:Transcripts)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    if (-not (Test-Path $script:BlockersDb)) {
        '{"by_slug": {}}' | Set-Content -Path $script:BlockersDb -Encoding utf8
    }
    # Upgrade 2 — verify-fail fingerprint registry. Bootstrapped alongside
    # blockers.json. Cleared on -SkipPlan (the human has reviewed; reset the
    # circuit-breaker counter).
    if (-not (Test-Path $script:VerifyFailDb)) {
        '{"fingerprints":{},"consecutive_same":{"fingerprint":null,"count":0}}' | Set-Content -Path $script:VerifyFailDb -Encoding utf8
    }
    # If -SkipPlan was passed the human has reviewed needs-review.md and is
    # asking the runner to retry. Stale cross-item registry entries from the
    # prior run would gate items even though their resolutions are now in
    # place — clear the registry so the eligibility loop respects the
    # resolutions. Items that re-emit cross-item blockers in this run will
    # repopulate the registry as they go.
    if ($SkipPlan) {
        '{"by_slug": {}}' | Set-Content -Path $script:BlockersDb -Encoding utf8
        '{"fingerprints":{},"consecutive_same":{"fingerprint":null,"count":0}}' | Set-Content -Path $script:VerifyFailDb -Encoding utf8
        Write-Verbose "SkipPlan: cleared stale blockers registry + verify-fail fingerprints"
    }
    # Keep runner state local — runs.jsonl and blockers.json are runtime data,
    # not source. Plans dir stays committable as audit trail.
    $runnerGitignore = Join-Path $script:RunnerDir '.gitignore'
    if (-not (Test-Path $runnerGitignore)) {
        "*`n!.gitignore`n" | Set-Content -Path $runnerGitignore -Encoding utf8
    }
}

# ---------------------------------------------------------------------------
# Slug + todo parser
# ---------------------------------------------------------------------------

function ConvertTo-Slug {
    param([Parameter(Mandatory)][string]$Text)
    $s = $Text.ToLowerInvariant()
    $s = [regex]::Replace($s, '[^a-z0-9]+', '-')
    $s = $s.Trim('-')
    if ($s.Length -gt 60) {
        # Prefer cutting at a word boundary (last '-' between pos 40 and 60).
        $cut = 60
        $lastDash = $s.LastIndexOf('-', 59)
        if ($lastDash -ge 40) { $cut = $lastDash }
        $s = $s.Substring(0, $cut).TrimEnd('-')
    }
    if (-not $s) { $s = 'item' }
    return $s
}

function Get-TodoItems {
    param([string]$Path)
    $lines = Get-Content -Path $Path
    $items = @()
    $usedSlugs = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # Only match top-level checkboxes at column 0 — indented `- [ ]` lines
        # are visual sub-steps inside the parent item, not standalone tasks.
        $m = [regex]::Match($lines[$i], '^-\s*\[([ xX])\]\s*(.+?)\s*$')
        if (-not $m.Success) { continue }
        $checked = $m.Groups[1].Value -match '[xX]'
        $text    = $m.Groups[2].Value
        $slug    = ConvertTo-Slug $text
        if ($usedSlugs.ContainsKey($slug)) {
            $hash = ([BitConverter]::ToString(
                [System.Security.Cryptography.SHA1]::Create().ComputeHash(
                    [Text.Encoding]::UTF8.GetBytes($text))) -replace '-','').Substring(0,6).ToLower()
            $slug = "$slug-$hash"
        }
        $usedSlugs[$slug] = $true

        # Upgrade 1 — peek forward for indented `- [ ]` sub-bullets and capture
        # them as descriptive sub-steps belonging to this parent item. Stop on
        # the next column-0 item, the next markdown heading, or any non-indented
        # non-blank line. Sub-bullets are NOT separately queued; they ride
        # along in the plan prompt as spec context for the parent.
        $subitems = @()
        $j = $i + 1
        while ($j -lt $lines.Count) {
            $next = $lines[$j]
            if ([string]::IsNullOrWhiteSpace($next)) { $j++; continue }
            if ($next -match '^-\s*\[') { break }       # next column-0 item
            if ($next -match '^#{1,6}\s') { break }     # next heading
            if ($next -notmatch '^\s+\S') { break }     # out of indented context
            $sm = [regex]::Match($next, '^\s+-\s*\[[ xX]\]\s*(.+?)\s*$')
            if ($sm.Success) { $subitems += $sm.Groups[1].Value }
            # non-checkbox indented text is descriptive prose — keep peeking
            $j++
        }

        $items += [pscustomobject]@{
            Checked    = $checked
            Text       = $text
            Slug       = $slug
            LineNumber = $i
            Subitems   = $subitems
        }
    }
    return ,$items
}

function Update-TodoCheckbox {
    param([string]$Path, [string]$Slug)
    $lines = Get-Content -Path $Path
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # Match only top-level checkboxes (consistent with Get-TodoItems).
        $m = [regex]::Match($lines[$i], '^(-\s*\[)[ xX](\]\s*)(.+?)(\s*)$')
        if (-not $m.Success) { continue }
        if ((ConvertTo-Slug $m.Groups[3].Value) -eq $Slug) {
            $lines[$i] = "$($m.Groups[1].Value)x$($m.Groups[2].Value)$($m.Groups[3].Value)$($m.Groups[4].Value)"
            Set-Content -Path $Path -Value $lines -Encoding utf8
            return $true
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Claude invocation
# ---------------------------------------------------------------------------

function Invoke-Claude {
    <#
        Runs claude -p with the supplied prompt, permission mode, and allowed-tools list.
        Captures stdout, stderr, and exit code separately. Returns a pscustomobject
        with ExitCode, Raw, StdErr, Json, WallSeconds, and the Prompt that was sent
        (so callers can write a forensic transcript).
        stderr is captured via temp files because pwsh's native-command stderr handling
        wraps output in ErrorRecord objects that stringify inconsistently.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][ValidateSet('default','auto')][string]$Mode,
        [Parameter(Mandatory)][string]$AllowedTools,
        [int]$MaxTurns = 30
    )

    $promptFile = New-TemporaryFile
    $outFile    = New-TemporaryFile
    $errFile    = New-TemporaryFile
    try {
        $Prompt | Set-Content -Path $promptFile -Encoding utf8 -NoNewline

        $argList = @(
            '-p'
            '--output-format', 'json'
            '--permission-mode', $Mode
            '--allowedTools', $AllowedTools
            '--max-turns', "$MaxTurns"
        )

        Write-Verbose "claude $($argList -join ' ')"

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $proc = Start-Process -FilePath $script:ClaudeExe `
            -ArgumentList $argList `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardInput  $promptFile.FullName `
            -RedirectStandardOutput $outFile.FullName `
            -RedirectStandardError  $errFile.FullName
        $sw.Stop()

        $raw = Get-Content -Path $outFile.FullName -Raw
        $err = Get-Content -Path $errFile.FullName -Raw
        $json = $null
        if ($raw) {
            try { $json = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
        }

        return [pscustomobject]@{
            ExitCode    = $proc.ExitCode
            Raw         = $raw
            StdErr      = $err
            Json        = $json
            Prompt      = $Prompt
            WallSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        }
    } finally {
        Remove-Item -Path $promptFile.FullName, $outFile.FullName, $errFile.FullName -ErrorAction SilentlyContinue
    }
}

function Write-Transcript {
    # Persists the full claude exchange for one invocation to a per-item file.
    # This is the primary forensic trail when something goes wrong — runs.jsonl
    # has summary fields, the transcript has the actual prompt and reply.
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][ValidateSet('plan','execute')][string]$Phase,
        [Parameter(Mandatory)][object]$InvocationResult,
        [string]$FailureMode = ''
    )
    $ts   = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff')
    $name = "$Slug-$Phase-$ts.txt"
    $path = Join-Path $script:Transcripts $name
    if (-not (Test-Path $script:Transcripts)) {
        New-Item -ItemType Directory -Path $script:Transcripts -Force | Out-Null
    }

    $resultText = ''
    if ($InvocationResult.Json) { $resultText = [string]$InvocationResult.Json.result }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("=== META ===")
    [void]$sb.AppendLine("phase: $Phase")
    [void]$sb.AppendLine("slug: $Slug")
    [void]$sb.AppendLine("ts_utc: $((Get-Date).ToUniversalTime().ToString('o'))")
    [void]$sb.AppendLine("wall_seconds: $($InvocationResult.WallSeconds)")
    [void]$sb.AppendLine("exit_code: $($InvocationResult.ExitCode)")
    [void]$sb.AppendLine("failure_mode: $FailureMode")
    if ($InvocationResult.Json) {
        [void]$sb.AppendLine("total_cost_usd: $($InvocationResult.Json.total_cost_usd)")
        [void]$sb.AppendLine("num_turns: $($InvocationResult.Json.num_turns)")
        [void]$sb.AppendLine("is_error: $($InvocationResult.Json.is_error)")
        [void]$sb.AppendLine("subtype: $($InvocationResult.Json.subtype)")
        [void]$sb.AppendLine("stop_reason: $($InvocationResult.Json.stop_reason)")
        [void]$sb.AppendLine("session_id: $($InvocationResult.Json.session_id)")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("=== PROMPT ===")
    [void]$sb.AppendLine($InvocationResult.Prompt)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("=== RESULT (model reply text) ===")
    [void]$sb.AppendLine($resultText)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("=== STDERR ===")
    [void]$sb.AppendLine([string]$InvocationResult.StdErr)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("=== RAW JSON STDOUT ===")
    [void]$sb.AppendLine([string]$InvocationResult.Raw)
    Set-Content -Path $path -Value $sb.ToString() -Encoding utf8
    return $path
}

# ---------------------------------------------------------------------------
# Failure-mode classifier
# ---------------------------------------------------------------------------

function Get-FailureMode {
    <#
        Maps a completed claude invocation to one of:
           success | classifier-terminated | needs-clarification | other-error | infra-error
    #>
    param(
        [Parameter(Mandatory)]$Result,  # the object from Invoke-Claude
        [int]$ClassifierMaxTurnsHint = 10
    )

    if ($Result.ExitCode -ne 0 -and -not $Result.Json) { return 'infra-error' }

    $json = $Result.Json
    if (-not $json) { return 'other-error' }

    $resultText = [string]$json.result
    $isError    = [bool]$json.is_error
    $numTurns   = [int]($json.num_turns | ForEach-Object { if ($_ -ne $null) { $_ } else { 0 } })

    if ($isError) {
        if ($resultText -match '(?i)deni(ed|al)|blocked|unsafe|classifier|permission' -and $numTurns -lt $ClassifierMaxTurnsHint) {
            return 'classifier-terminated'
        }
        return 'other-error'
    }

    if ($numTurns -lt 3 -and $resultText -match '(?i)I need to know|please clarify|cannot proceed without|need more (info|information|context)') {
        return 'needs-clarification'
    }

    return 'success'
}

# ---------------------------------------------------------------------------
# Plan markdown parser
# ---------------------------------------------------------------------------

function Read-Plan {
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-Content -Path $Path -Raw

    $verify = @()
    $vm = [regex]::Match($text, '(?ms)^##\s*Verify\s*\r?\n```[^\n]*\r?\n(.*?)```')
    if ($vm.Success) {
        $verify = $vm.Groups[1].Value -split "`n" |
                  ForEach-Object { $_.Trim() } |
                  Where-Object { $_ -and -not $_.StartsWith('#') }
    }

    $assumptions = @()
    $am = [regex]::Match($text, '(?ms)^##\s*Assumptions\s*\r?\n(.*?)(?=^##\s|\z)')
    if ($am.Success) {
        $assumptions = $am.Groups[1].Value -split "`n" |
                       ForEach-Object { $_.Trim() } |
                       Where-Object { $_.StartsWith('-') } |
                       ForEach-Object { $_.Substring(1).Trim() }
    }

    $blockers = @()
    $bm = [regex]::Match($text, '(?ms)^##\s*Blockers\s*\r?\n(.*?)(?=^##\s(?!#)|\z)')
    if ($bm.Success) {
        $body = $bm.Groups[1].Value.Trim()
        if ($body -notmatch '^(?i)Blockers:\s*none') {
            foreach ($block in [regex]::Split($body, '(?m)^###\s*Blocker:\s*')) {
                # Only treat chunks that actually contain a severity line as blockers;
                # this skips preamble and any junk before the first ### header.
                if ($block -notmatch '(?im)^\s*-\s*severity:\s*(foundational|cross-item|local)') { continue }
                $sev  = ([regex]::Match($block, '(?im)^\s*-\s*severity:\s*(foundational|cross-item|local)')).Groups[1].Value
                if (-not $sev) { continue }
                $aff  = ([regex]::Match($block, '(?im)^\s*-\s*affects:\s*(.+)$')).Groups[1].Value
                $q    = ([regex]::Match($block, '(?im)^\s*-\s*question:\s*(.+)$')).Groups[1].Value
                $def  = ([regex]::Match($block, '(?im)^\s*-\s*default_assumption:\s*(.+)$')).Groups[1].Value
                $name = ($block -split "`n" | Select-Object -First 1).Trim()
                $blockers += [pscustomobject]@{
                    Name              = $name
                    Severity          = $sev
                    Affects           = @(($aff -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    Question          = $q.Trim()
                    DefaultAssumption = $def.Trim()
                }
            }
        }
    }

    $summary = ''
    $sm = [regex]::Match($text, '(?ms)^##\s*Summary\s*\r?\n(.*?)(?=^##\s|\z)')
    if ($sm.Success) { $summary = $sm.Groups[1].Value.Trim() -split "`n" | Select-Object -First 1 }

    return [pscustomobject]@{
        Verify      = $verify
        Assumptions = $assumptions
        Blockers    = $blockers
        Summary     = $summary
    }
}

# ---------------------------------------------------------------------------
# Plan verify-grammar validator (Upgrade 3) + staleness check (Upgrade 4)
# ---------------------------------------------------------------------------

# Patterns shared by Upgrade 3 (reject plans with these in Verify) and
# Upgrade 4 (a stale-plan signal: a verify-fail on one of these means the
# plan's gate references runner bookkeeping that has drifted, NOT that the
# deliverable is broken).
$script:VerifyForbiddenPatterns = @(
    # grep/rg/ack against runner bookkeeping files
    '\b(grep|rg|ack)\b[^|;&]*\b(TODO|todo|needs-review|HALT)\.md\b',
    '\b(grep|rg|ack)\b[^|;&]*\.claude[/\\]',
    # interactive commands the runner cannot drive unattended
    '\b(cargo run|npm start|npm run dev|yarn start|yarn dev)\b',
    # nested pwsh inside a bash verify line — quoting nightmare
    '\bpwsh\b[^|;&]*-Command'
)

function Test-PlanVerifyGrammar {
    # Scans a plan's Verify commands for forbidden patterns. Returns an
    # object with Passed (bool) and FirstOffender (the first matching
    # command, if any). Caller routes a failure through Add-NeedsReview
    # with a 'plan-validation-failed' reason and rolls back so the runner
    # re-plans on next pass.
    param([Parameter(Mandatory)][string[]]$Verify)
    foreach ($cmd in $Verify) {
        if (-not $cmd) { continue }
        foreach ($pat in $script:VerifyForbiddenPatterns) {
            if ($cmd -match $pat) {
                return [pscustomobject]@{
                    Passed        = $false
                    FirstOffender = $cmd
                    Pattern       = $pat
                }
            }
        }
    }
    return [pscustomobject]@{ Passed = $true; FirstOffender = $null; Pattern = $null }
}

function Test-PlanStaleness {
    # Upgrade 4 — given a parsed plan and the current tree state, decide one
    # of three outcomes:
    #   already-done : verify gate passes RIGHT NOW (deliverable is built;
    #                  the runner should auto-tick + commit, skip phase 2)
    #   stale        : verify fails AND the failed command targets bookkeeping
    #                  files (runner-managed state has drifted; plan must be
    #                  regenerated)
    #   reusable     : verify fails on a deliverable command (work just isn't
    #                  built yet; plan is fine, run phase 2 as normal)
    param([Parameter(Mandatory)]$Plan, [string]$Slug)

    if (-not $Plan -or -not $Plan.Verify -or $Plan.Verify.Count -eq 0) {
        return [pscustomobject]@{ Verdict = 'reusable'; FailedCommand = $null }
    }

    $r = Test-Verify -Commands $Plan.Verify
    if ($r.Passed) {
        return [pscustomobject]@{ Verdict = 'already-done'; FailedCommand = $null }
    }
    # Verify failed -- decide whether the failed command targets bookkeeping.
    $failed = $r.FailedCommand
    foreach ($pat in $script:VerifyForbiddenPatterns) {
        if ($failed -match $pat) {
            return [pscustomobject]@{ Verdict = 'stale'; FailedCommand = $failed }
        }
    }
    return [pscustomobject]@{ Verdict = 'reusable'; FailedCommand = $failed }
}

# ---------------------------------------------------------------------------
# Verify executor
# ---------------------------------------------------------------------------

function Test-Verify {
    # Verify commands run through bash because Claude (and most build/test
    # docs in the wild) write commands in bash style — `test -f`, `grep -q`,
    # `&& chained`, `> /dev/null`, etc. None of those work in pwsh, which
    # has no `test` builtin and treats `/dev/null` as a literal path.
    #
    # On Windows: requires Git for Windows on PATH (provides bash, test,
    # grep, etc.). On Linux/macOS: bash is always present.
    #
    # If bash isn't on PATH, fall back to pwsh and hope the plan happens
    # to write pwsh-compatible verify commands.
    param([string[]]$Commands)
    if (-not $Commands -or $Commands.Count -eq 0) {
        return [pscustomobject]@{ Passed = $true; Output = '(no verify commands)'; FailedCommand = $null }
    }
    $allOutput = [System.Text.StringBuilder]::new()
    foreach ($cmd in $Commands) {
        [void]$allOutput.AppendLine("+ $cmd")
        try {
            if ($script:BashExe) {
                $out = & $script:BashExe -c $cmd 2>&1 | Out-String
            } else {
                $out = pwsh -NoProfile -Command $cmd 2>&1 | Out-String
            }
            [void]$allOutput.Append($out)
            if ($LASTEXITCODE -ne 0) {
                return [pscustomobject]@{
                    Passed        = $false
                    Output        = $allOutput.ToString()
                    FailedCommand = $cmd
                }
            }
        } catch {
            [void]$allOutput.AppendLine($_.Exception.Message)
            return [pscustomobject]@{
                Passed        = $false
                Output        = $allOutput.ToString()
                FailedCommand = $cmd
            }
        }
    }
    return [pscustomobject]@{ Passed = $true; Output = $allOutput.ToString(); FailedCommand = $null }
}

# ---------------------------------------------------------------------------
# Verify-fail fingerprint circuit breaker (Upgrade 2)
# ---------------------------------------------------------------------------

function Get-VerifyFingerprint {
    # 8-char hex SHA1 of the lower-cased, whitespace-collapsed Output. Stable
    # across timestamp/path noise; collisions are acceptable (a collision
    # halts slightly early on an unrelated repeating error, which is fine).
    param([string]$Output)
    if (-not $Output) { return '00000000' }
    $norm = ($Output.ToLowerInvariant() -replace '\s+', ' ').Trim()
    $bytes = [Text.Encoding]::UTF8.GetBytes($norm)
    $hash  = [System.Security.Cryptography.SHA1]::Create().ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace '-','').Substring(0,8).ToLower()
}

function Read-VerifyFailDb {
    if (-not (Test-Path $script:VerifyFailDb)) {
        return [pscustomobject]@{
            fingerprints     = @{}
            consecutive_same = [pscustomobject]@{ fingerprint = $null; count = 0 }
        }
    }
    try {
        $raw = Get-Content -Path $script:VerifyFailDb -Raw
        return $raw | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{
            fingerprints     = @{}
            consecutive_same = [pscustomobject]@{ fingerprint = $null; count = 0 }
        }
    }
}

function Save-VerifyFailDb {
    param([Parameter(Mandatory)]$Db)
    ($Db | ConvertTo-Json -Depth 10) | Set-Content -Path $script:VerifyFailDb -Encoding utf8
}

function Update-VerifyFailRegistry {
    # Records a verify failure, updates per-fingerprint and consecutive
    # counters, and (if either threshold is hit) writes HALT.md and signals
    # the caller to exit. Returns an object: HaltTriggered (bool), Tail
    # (last 30 lines of Output), Fingerprint, FpEntry (the per-fingerprint
    # record after update), Consec (the consecutive counter).
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$Output,
        [string]$FailedCommand
    )
    $fp = Get-VerifyFingerprint -Output $Output
    $tail = ($Output -split "`n" | Select-Object -Last 30) -join "`n"

    $db = Read-VerifyFailDb
    # Normalize fingerprints into a hashtable for mutation (ConvertFrom-Json
    # gives a PSCustomObject by default).
    $fpTable = @{}
    if ($db.fingerprints) {
        foreach ($k in $db.fingerprints.PSObject.Properties.Name) {
            $fpTable[$k] = $db.fingerprints.$k
        }
    }

    if ($fpTable.ContainsKey($fp)) {
        $entry = $fpTable[$fp]
        $entry.count               = ([int]$entry.count) + 1
        $entry.last_seen_slug      = $Slug
        $entry.last_failed_command = $FailedCommand
        $entry.tail                = $tail
    } else {
        $entry = [pscustomobject]@{
            count               = 1
            first_seen_slug     = $Slug
            last_seen_slug      = $Slug
            last_failed_command = $FailedCommand
            tail                = $tail
        }
        $fpTable[$fp] = $entry
    }

    # Consecutive counter: increment if same fp as last; otherwise reset.
    $consec = $db.consecutive_same
    if (-not $consec) {
        $consec = [pscustomobject]@{ fingerprint = $null; count = 0 }
    }
    if ($consec.fingerprint -eq $fp) {
        $consec.count = ([int]$consec.count) + 1
    } else {
        $consec = [pscustomobject]@{ fingerprint = $fp; count = 1 }
    }

    # Write back. ConvertTo-Json on hashtables produces an object; that's
    # what we want for fingerprints (map of fingerprint -> entry).
    $db = [pscustomobject]@{
        fingerprints     = $fpTable
        consecutive_same = $consec
    }
    Save-VerifyFailDb -Db $db

    $halt = ($consec.count -ge $VerifyFingerprintConsecLimit) -or ($entry.count -ge $VerifyFingerprintTotalLimit)
    if ($halt) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("# HALT: verify-fail circuit breaker tripped")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("The same verify error has fired repeatedly across items. The runner is stuck in a retry loop and cannot recover on its own.")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("- **Fingerprint:** ``$fp``")
        [void]$sb.AppendLine("- **Consecutive same-fingerprint failures:** $($consec.count) (limit $VerifyFingerprintConsecLimit)")
        [void]$sb.AppendLine("- **Total occurrences of this fingerprint:** $($entry.count) (limit $VerifyFingerprintTotalLimit)")
        [void]$sb.AppendLine("- **First seen on slug:** ``$($entry.first_seen_slug)``")
        [void]$sb.AppendLine("- **Last seen on slug:** ``$($entry.last_seen_slug)``")
        [void]$sb.AppendLine("- **Failed command:** ``$($entry.last_failed_command)``")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("## Last 30 lines of verify output")
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine($entry.tail)
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("## Suggested action")
        [void]$sb.AppendLine("Hand-fix the underlying issue (look for a system-dep miss, a toolchain version mismatch, or a generated-code bug the runner can't self-correct). Then rerun with ``-SkipPlan`` — the circuit-breaker counter is cleared on ``-SkipPlan``.")
        Set-Content -Path $script:HaltFile -Value $sb.ToString() -Encoding utf8
    }

    return [pscustomobject]@{
        HaltTriggered = $halt
        Fingerprint   = $fp
        Tail          = $tail
        FpCount       = [int]$entry.count
        ConsecCount   = [int]$consec.count
    }
}

function Reset-VerifyFailConsecutive {
    # Called after ANY verify pass. Different items can succeed; we only halt
    # on real lock-up, so a single pass resets the consecutive counter.
    $db = Read-VerifyFailDb
    if ($db.consecutive_same -and $db.consecutive_same.count -gt 0) {
        $db = [pscustomobject]@{
            fingerprints     = $db.fingerprints
            consecutive_same = [pscustomobject]@{ fingerprint = $null; count = 0 }
        }
        Save-VerifyFailDb -Db $db
    }
}

# ---------------------------------------------------------------------------
# needs-review.md + blockers.json
# ---------------------------------------------------------------------------

function Add-NeedsReview {
    param(
        [string]$Slug,
        [string]$ItemText,
        [string]$Reason,
        [string]$Detail,
        [object[]]$Blockers = @()
    )
    $ts = [DateTime]::UtcNow.ToString('o')
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## $Slug")
    [void]$sb.AppendLine("- Item: $ItemText")
    [void]$sb.AppendLine("- Reason: $Reason")
    [void]$sb.AppendLine("- Timestamp: $ts")
    if ($Detail) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("### Detail")
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine($Detail.TrimEnd())
        [void]$sb.AppendLine('```')
    }
    if ($Blockers -and $Blockers.Count -gt 0) {
        foreach ($b in $Blockers) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("### Blocker: $($b.Name)")
            [void]$sb.AppendLine("- severity: $($b.Severity)")
            [void]$sb.AppendLine("- affects: $($b.Affects -join ', ')")
            [void]$sb.AppendLine("- question: $($b.Question)")
            [void]$sb.AppendLine("- default_assumption: $($b.DefaultAssumption)")
            [void]$sb.AppendLine("- Resolution: ")  # human fills this in
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("---")
    Add-Content -Path $NeedsReviewFile -Value $sb.ToString() -Encoding utf8
}

function Get-ReviewedItems {
    <#
        Parses needs-review.md into slug -> @{ Resolved, Resolutions[], Blockers[] }.
        An item is "resolved" if every Blocker section under its slug has a non-empty
        Resolution: line. If an item has no blockers at all (e.g., routed for verify-fail
        or cost ceiling), it's treated as unresolved unless manually removed from the file.
    #>
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path $Path)) { return $result }
    $text = Get-Content -Path $Path -Raw
    $sections = [regex]::Split($text, '(?m)^---\s*$')
    foreach ($sec in $sections) {
        $sm = [regex]::Match($sec, '(?m)^##\s+([a-z0-9\-]+)\s*$')
        if (-not $sm.Success) { continue }
        $slug = $sm.Groups[1].Value

        $blockerChunks = [regex]::Matches($sec, '(?ms)^###\s*Blocker:.*?(?=^###\s|\z)')
        $blockers = @()
        $anyUnresolved = $false
        foreach ($chunk in $blockerChunks) {
            $block = $chunk.Value
            $q    = ([regex]::Match($block, '(?im)^\s*-\s*question:\s*(.+)$')).Groups[1].Value.Trim()
            $r    = ([regex]::Match($block, '(?im)^\s*-\s*Resolution:\s*(.*)$')).Groups[1].Value.Trim()
            $sev  = ([regex]::Match($block, '(?im)^\s*-\s*severity:\s*(.+)$')).Groups[1].Value.Trim()
            if (-not $r) { $anyUnresolved = $true }
            $blockers += [pscustomobject]@{ Question = $q; Resolution = $r; Severity = $sev }
        }
        $hasBlockers = $blockers.Count -gt 0
        $resolved    = $hasBlockers -and -not $anyUnresolved
        $result[$slug] = @{
            Resolved    = $resolved
            HasBlockers = $hasBlockers
            Blockers    = $blockers
        }
    }
    return $result
}

function Add-BlockerRegistry {
    param([string]$Slug, [object[]]$CrossItemBlockers)
    $db = Get-Content -Path $script:BlockersDb -Raw | ConvertFrom-Json -AsHashtable
    if (-not $db.by_slug) { $db.by_slug = @{} }
    $keywords = @()
    foreach ($b in $CrossItemBlockers) { $keywords += $b.Affects }
    $db.by_slug[$Slug] = @{
        keywords = @($keywords | Select-Object -Unique)
        question = ($CrossItemBlockers | ForEach-Object { $_.Question }) -join ' | '
    }
    ($db | ConvertTo-Json -Depth 10) | Set-Content -Path $script:BlockersDb -Encoding utf8
}

function Remove-BlockerRegistry {
    param([string]$Slug)
    $db = Get-Content -Path $script:BlockersDb -Raw | ConvertFrom-Json -AsHashtable
    if ($db.by_slug -and $db.by_slug.ContainsKey($Slug)) {
        $db.by_slug.Remove($Slug) | Out-Null
        ($db | ConvertTo-Json -Depth 10) | Set-Content -Path $script:BlockersDb -Encoding utf8
    }
}

function Get-ItemBlockedBy {
    param([string]$ItemText)
    $db = Get-Content -Path $script:BlockersDb -Raw | ConvertFrom-Json -AsHashtable
    if (-not $db.by_slug) { return $null }
    $lower = $ItemText.ToLowerInvariant()
    foreach ($entry in $db.by_slug.GetEnumerator()) {
        foreach ($kw in $entry.Value.keywords) {
            if ($kw -and $lower.Contains($kw.ToString().ToLowerInvariant())) {
                return $entry.Key
            }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Runs log
# ---------------------------------------------------------------------------

function Add-RunLog {
    param([string]$Phase, [string]$Slug, [object]$InvocationResult, [hashtable]$Extra = @{})
    $entry = [ordered]@{
        ts_utc         = [DateTime]::UtcNow.ToString('o')
        phase          = $Phase
        slug           = $Slug
        exit_code      = $InvocationResult.ExitCode
        wall_seconds   = if ($InvocationResult.PSObject.Properties.Name -contains 'WallSeconds') { $InvocationResult.WallSeconds } else { $null }
        total_cost_usd = if ($InvocationResult.Json) { $InvocationResult.Json.total_cost_usd } else { $null }
        num_turns      = if ($InvocationResult.Json) { $InvocationResult.Json.num_turns } else { $null }
        is_error       = if ($InvocationResult.Json) { $InvocationResult.Json.is_error } else { $null }
        subtype        = if ($InvocationResult.Json) { $InvocationResult.Json.subtype } else { $null }
        stop_reason    = if ($InvocationResult.Json) { $InvocationResult.Json.stop_reason } else { $null }
        session_id     = if ($InvocationResult.Json) { $InvocationResult.Json.session_id } else { $null }
    }
    foreach ($k in $Extra.Keys) { $entry[$k] = $Extra[$k] }
    $line = ($entry | ConvertTo-Json -Depth 5 -Compress)
    Add-Content -Path $script:RunsLog -Value $line -Encoding utf8
    Write-Information $line
}

# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

function Invoke-Rollback {
    # Stashes everything in the working tree EXCEPT the runner's own bookkeeping:
    #   - .claude/                  (plans dir, todo-runner state, runs.jsonl)
    #   - needs-review.md, HALT.md  (triage outputs the runner just wrote)
    #   - $TodoFile                 (the source-of-truth list; losing it ends the run)
    # Without these exclusions, an unscoped `git stash push -u` sweeps the
    # plan file we just wrote, the needs-review entry we just appended, and
    # the runs.jsonl line — leaving the next phase-1 invocation unable to
    # write its plan file because the dir was emptied. Pathspec exclusions
    # require a positive pathspec to subtract from, so we pass `.` (cwd)
    # plus `:(exclude)<path>` for each path we want to keep.
    param([string]$Slug)
    if ($RollbackStrategy -eq 'stash') {
        git stash push -u -m "todo-runner rollback $Slug" -- `
            '.' `
            ':(exclude).claude' `
            ':(exclude)needs-review.md' `
            ':(exclude)HALT.md' `
            (':(exclude)' + $TodoFile) 2>&1 | Out-Null
    } else {
        # `git reset --hard HEAD` only touches tracked files; runner state in
        # .claude (untracked + gitignored) is unaffected. Plan file just
        # written this phase is also untracked → survives, no extra scoping
        # needed for the reset path.
        git reset --hard HEAD 2>&1 | Out-Null
    }
}

function Get-ExecutionNotes {
    # Pull the "EXECUTION NOTES:" trailer from a phase-2 result text. Returns
    # the body (without the header) or empty string. Phase 2 is instructed to
    # end its reply with this block listing any conservative interpretations.
    param([string]$ResultText)
    if (-not $ResultText) { return '' }
    $m = [regex]::Match($ResultText, '(?ms)EXECUTION\s+NOTES\s*:?\s*\r?\n?(.*?)\z')
    if (-not $m.Success) { return '' }
    $body = $m.Groups[1].Value.Trim()
    if (-not $body -or $body -match '^(?i)none\.?$') { return '' }
    return $body
}

function Commit-Item {
    param([string]$Slug, [string]$Summary, [string[]]$Assumptions, [string[]]$Forced, [string]$VerifyCmd, [string]$ExecutionNotes = '')
    $msg = [System.Text.StringBuilder]::new()
    if ($Summary) { [void]$msg.AppendLine($Summary) } else { [void]$msg.AppendLine("todo-runner: $Slug") }
    [void]$msg.AppendLine("")
    [void]$msg.AppendLine("Plan: $(Join-Path $script:PlansDir "$Slug.md")")
    if ($Assumptions -and $Assumptions.Count -gt 0) {
        [void]$msg.AppendLine("Assumptions:")
        foreach ($a in $Assumptions) { [void]$msg.AppendLine("  - $a") }
    }
    if ($Forced -and $Forced.Count -gt 0) {
        [void]$msg.AppendLine("ASSUMED (forced by -ProceedOnBlockers):")
        foreach ($f in $Forced) { [void]$msg.AppendLine("  - $f") }
    }
    if ($ExecutionNotes) {
        [void]$msg.AppendLine("Execution notes:")
        foreach ($line in ($ExecutionNotes -split "`n")) { [void]$msg.AppendLine("  $($line.TrimEnd())") }
    }
    if ($VerifyCmd) { [void]$msg.AppendLine("Verify: $VerifyCmd OK") }
    [void]$msg.AppendLine("[runner] claude-code todo-runner")

    git add -A 2>&1 | Out-Null
    $msgFile = New-TemporaryFile
    try {
        $msg.ToString() | Set-Content -Path $msgFile -Encoding utf8 -NoNewline
        git commit -F $msgFile.FullName 2>&1 | Out-Null
    } finally {
        Remove-Item -Path $msgFile.FullName -ErrorAction SilentlyContinue
    }
    $sha = (git rev-parse --short HEAD).Trim()
    return $sha
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

function New-PlanPrompt {
    # Single-quoted here-strings + literal .Replace() so user item text and
    # plan/resolution content can contain backticks, dollar signs, or any other
    # PowerShell escape character without corrupting the prompt.
    param([string]$ItemText, [string]$Slug, [string]$Resolutions, [string[]]$Subitems)

    $resolutionBlock = ''
    if ($Resolutions) {
        $resolutionTemplate = @'

Previously blocked, now resolved:
{{R}}

Incorporate these answers into your plan. Do not re-emit blockers that were resolved.
'@
        $resolutionBlock = $resolutionTemplate.Replace('{{R}}', $Resolutions)
    }

    # Upgrade 1 — when the parent item has nested `- [ ]` sub-bullets in
    # todo.md, surface them as a single bundled spec for ONE plan. Without
    # this, the agent treats each sub-step as a separable concern and asks
    # "is this part of one function or many?" as a planning blocker.
    $substepsBlock = ''
    if ($Subitems -and $Subitems.Count -gt 0) {
        $bullets = ($Subitems | ForEach-Object { "  - $_" }) -join "`n"
        $substepsTemplate = @'

This item bundles {{N}} descriptive sub-step(s). Treat them as the spec for ONE plan whose execute phase implements them all in a single coherent commit. Do NOT propose separate plans/items for each sub-step:
{{B}}
'@
        $substepsBlock = $substepsTemplate.Replace('{{N}}', $Subitems.Count.ToString()).Replace('{{B}}', $bullets)
    }

    $template = @'
You are planning ONE todo item in a larger automated run. You cannot ask questions -- this session has no user. You have read-only access (Read, Glob, Grep) for research; do not attempt to edit files or run shell commands.

OUTPUT FORMAT: respond with the plan markdown as your direct text reply. Do not call ExitPlanMode or any plan-saving tool -- the runner captures your reply text and saves it.

Todo item: {{ITEM}}
Slug: {{SLUG}}
{{SUBSTEPS_BLOCK}}{{RESOLUTIONS_BLOCK}}
Produce a plan in this exact structure:

# Plan: {{SLUG}}

## Goal
<one sentence>

## Steps
1. ...

## Files
- path/to/file -- what changes

## Risks
- ...

## Verify
```
<shell command 1>
<shell command 2>
```
Each command runs through `bash -c` (Git Bash on Windows; system bash on Linux/macOS). Exit code 0 = pass.

ALLOWED commands (whitelist):
- `cargo {check,test,clippy,build,fmt}` ... (any subcommand/args; NOT `cargo run`)
- `test -f / test -d / test -e <path>` -- existence checks for deliverable files
- `cksum <path> | grep -q <hex>` -- file checksum match
- `grep -q <pattern> <file>` ONLY against deliverable source files
- `npm test`, `pytest`, `go test`, `mvn test`, `./gradlew test`, `python -m unittest`

FORBIDDEN -- the runner WILL reject the plan if any verify line matches:
- `grep` / `rg` / `ack` against TODO.md, todo.md, needs-review.md, HALT.md, or any `.claude/*` path. These are runner bookkeeping; their content drifts for reasons unrelated to your work and would falsely fail your verify.
- Interactive commands: `cargo run`, `npm start`, `npm run dev`, `yarn start`, `yarn dev`, anything that opens a window, plays sound, or waits for input.
- Nested `pwsh -Command "..."` inside a bash line -- the outer bash mangles the inner quoting.

Verify must check that the DELIVERABLE exists/works (compile/test/file presence). Do NOT verify that text was added to TODO.md or that an entry was appended to needs-review.md -- the runner manages those files itself.

## Assumptions
- <every non-obvious choice you made>

## Blockers
If you have NO blockers, write exactly: `Blockers: none`

Otherwise, one block per blocker:

### Blocker: <short name>
- severity: foundational | cross-item | local
- affects: <comma-separated keywords>
- question: <the question>
- default_assumption: <what you would do if forced to proceed>

Severity definitions:
- foundational: affects the whole codebase/architecture; proceeding without an answer risks destroying work across many items
- cross-item: other pending items probably touch the same area; answering affects how they should be planned
- local: only affects this one item

## Summary
<one line; what this change accomplishes>

Rules:
- Do NOT ask clarifying questions. Make assumptions and list them.
- Do NOT write code. Just plan.
- Do NOT mark anything in todo.md.
- Always include the Blockers section, even if empty.
- Always include a default_assumption for every blocker (so -ProceedOnBlockers has something to use).
'@

    # Replace dynamic blocks first, then SLUG, then ITEM (user-supplied) last
    # so user text never gets fed back through another Replace pass.
    return $template.
        Replace('{{SUBSTEPS_BLOCK}}', $substepsBlock).
        Replace('{{RESOLUTIONS_BLOCK}}', $resolutionBlock).
        Replace('{{SLUG}}', $Slug).
        Replace('{{ITEM}}', $ItemText)
}

function New-ExecutePrompt {
    # Same rationale as New-PlanPrompt: single-quoted templates so plan text
    # (markdown code fences, arbitrary content) flows through literally.
    param([string]$PlanText, [string]$ForcedAssumptions)

    $forcedBlock = ''
    if ($ForcedAssumptions) {
        $forcedTemplate = @'

FORCED ASSUMPTIONS (runner invoked with -ProceedOnBlockers; proceed using these):
{{F}}

'@
        $forcedBlock = $forcedTemplate.Replace('{{F}}', $ForcedAssumptions)
    }

    $template = @'
Execute this plan exactly. The session has no user; you cannot ask questions.
{{FORCED_BLOCK}}
{{PLAN}}

Rules:
1. Make the code changes per the Steps.
2. If the plan is ambiguous, pick the most conservative interpretation and record your choice in an "EXECUTION NOTES:" block at the end of your reply.
3. Run the Verify commands and report their output.
4. Do NOT run `git commit`. Leave changes staged. The runner commits.
5. Do NOT edit todo.md. The runner marks it.
6. End your reply with "EXECUTION NOTES:" listing any conservative interpretations you made.
'@

    return $template.
        Replace('{{FORCED_BLOCK}}', $forcedBlock).
        Replace('{{PLAN}}', $PlanText)
}

# ---------------------------------------------------------------------------
# Main per-item functions
# ---------------------------------------------------------------------------

function Invoke-Phase1 {
    param([string]$ItemText, [string]$Slug, [string]$Resolutions, [string[]]$Subitems)
    $planPath = Join-Path $script:PlansDir "$Slug.md"

    if ($SkipPlan -and (Test-Path $planPath) -and -not $Resolutions) {
        # Upgrade 4 — before reusing a cached plan, run its verify gate. If
        # the gate already passes, the deliverable is already done (a hand-fix
        # landed externally between runs); short-circuit with 'already-done'.
        # If the gate fails AND any failed command targets bookkeeping files
        # (TODO.md, needs-review.md, etc.), the plan is stale; delete it and
        # fall through to fresh planning. Otherwise reuse as today.
        $cachedPlan = Read-Plan $planPath
        # Upgrade 3 — reject cached plans whose verify gate violates the
        # grammar (e.g. greps against TODO.md). A grammar-bad plan is by
        # definition stale-or-broken; delete and re-plan.
        $grammar = Test-PlanVerifyGrammar -Verify $cachedPlan.Verify
        if (-not $grammar.Passed) {
            Write-Info2 "  cached plan has forbidden verify command ($($grammar.FirstOffender)) -- discarding"
            Remove-Item -Path $planPath -Force -ErrorAction SilentlyContinue
            # fall through to fresh planning below
        } else {
            $stale = Test-PlanStaleness -Plan $cachedPlan -Slug $Slug
            if ($stale.Verdict -eq 'already-done') {
                Write-Info2 "  cached plan verify already passes -- item already done; auto-tick"
                return [pscustomobject]@{
                    PlanPath = $planPath
                    Cost     = 0.0
                    Mode     = 'already-done'
                    Blockers = $cachedPlan.Blockers
                    Plan     = $cachedPlan
                }
            }
            if ($stale.Verdict -eq 'stale') {
                Write-Info2 "  cached plan verify fails on bookkeeping check -- discarding stale plan ($($stale.FailedCommand))"
                Remove-Item -Path $planPath -Force -ErrorAction SilentlyContinue
                # fall through to fresh planning below
            } else {
                Write-Info2 "  reusing existing plan: $planPath"
                return [pscustomobject]@{
                    PlanPath = $planPath
                    Cost     = 0.0
                    Mode     = 'reused'
                    Blockers = $cachedPlan.Blockers
                }
            }
        }
    }

    Write-Phase "plan  $Slug"
    $prompt = New-PlanPrompt -ItemText $ItemText -Slug $Slug -Resolutions $Resolutions -Subitems $Subitems
    # Read-only research mode: 'default' permission with only Read/Glob/Grep allowed.
    # We deliberately avoid '--permission-mode plan' — in headless that triggers
    # Claude's ExitPlanMode tool which writes the plan to a separate file and
    # leaves only a summary in the JSON result; we want the actual plan as text.
    $r = Invoke-Claude -Prompt $prompt -Mode 'default' -AllowedTools 'Read,Glob,Grep' -MaxTurns $MaxTurns

    # Decide failure mode early so the transcript records it.
    if ($r.ExitCode -ne 0 -or -not $r.Json) {
        $failure = 'infra-error'
    } else {
        $failure = Get-FailureMode -Result $r
    }
    $tx = Write-Transcript -Slug $Slug -Phase 'plan' -InvocationResult $r -FailureMode $failure
    Add-RunLog -Phase 'plan' -Slug $Slug -InvocationResult $r -Extra @{
        item_text       = $ItemText
        failure_mode    = $failure
        transcript_path = $tx
    }
    Write-Info2 "  plan: $($r.WallSeconds)s, failure_mode=$failure, transcript=$tx"

    if ($r.ExitCode -ne 0 -or -not $r.Json) {
        # Show the first chunk of stderr so the user can see why claude failed.
        $errPreview = if ($r.StdErr) { ($r.StdErr -split "`n" | Select-Object -First 5) -join "`n  " } else { '(no stderr)' }
        Write-Review "  infra-error stderr: $errPreview"
        return [pscustomobject]@{ PlanPath = $null; Cost = 0.0; Mode = 'error'; Blockers = @(); FailureMode = 'infra-error'; Raw = $r }
    }

    $cost = [decimal]($r.Json.total_cost_usd ?? 0)

    if ($failure -ne 'success') {
        # Show the first lines of the model's reply so the failure is visible.
        $resultPreview = if ($r.Json.result) { (([string]$r.Json.result) -split "`n" | Select-Object -First 5) -join "`n  " } else { '(empty)' }
        Write-Review "  $($failure): $resultPreview"
        return [pscustomobject]@{ PlanPath = $null; Cost = $cost; Mode = 'error'; Blockers = @(); FailureMode = $failure; Raw = $r }
    }

    $planText = [string]$r.Json.result
    # Defense in depth: a prior rollback (or external tool) might have
    # removed the plans dir. Recreate it before writing so we don't crash
    # the runner with "Could not find a part of the path".
    $planDir = Split-Path $planPath -Parent
    if (-not (Test-Path $planDir)) { New-Item -ItemType Directory -Path $planDir -Force | Out-Null }
    Set-Content -Path $planPath -Value $planText -Encoding utf8
    $parsed = Read-Plan $planPath

    # Upgrade 3 — reject plans whose Verify section contains forbidden
    # commands (greps against TODO.md, interactive cargo run, nested pwsh).
    # The runner re-queues; the next plan attempt sees the rejection in
    # needs-review.md and (with -SkipPlan + Resolutions) gets a steer.
    $grammar = Test-PlanVerifyGrammar -Verify $parsed.Verify
    if (-not $grammar.Passed) {
        Write-Review "  plan rejected: forbidden verify command -> $($grammar.FirstOffender)"
        return [pscustomobject]@{
            PlanPath          = $planPath
            Cost              = $cost
            Mode              = 'error'
            Blockers          = @()
            FailureMode       = 'plan-validation-failed'
            Raw               = $r
            ValidationOffender = $grammar.FirstOffender
        }
    }

    return [pscustomobject]@{
        PlanPath    = $planPath
        Cost        = $cost
        Mode        = 'planned'
        Blockers    = $parsed.Blockers
        FailureMode = 'success'
        Raw         = $r
    }
}

function Invoke-Phase2 {
    param([string]$Slug, [string]$PlanPath, [string[]]$ForcedAssumptions, [decimal]$PlanCost, [string]$ItemText = '')
    Write-Phase "exec  $Slug"
    $planText = Get-Content -Path $PlanPath -Raw
    $parsed   = Read-Plan $PlanPath

    $forcedBlock = ($ForcedAssumptions -join "`n")
    $prompt = New-ExecutePrompt -PlanText $planText -ForcedAssumptions $forcedBlock
    $r = Invoke-Claude -Prompt $prompt -Mode 'auto' -AllowedTools 'Read,Edit,Write,Bash,Glob,Grep' -MaxTurns $MaxTurns

    $failure = if ($r.ExitCode -ne 0 -or -not $r.Json) { 'infra-error' } else { Get-FailureMode -Result $r }
    $tx = Write-Transcript -Slug $Slug -Phase 'execute' -InvocationResult $r -FailureMode $failure
    Add-RunLog -Phase 'execute' -Slug $Slug -InvocationResult $r -Extra @{
        plan_cost_usd   = [double]$PlanCost
        item_text       = $ItemText
        failure_mode    = $failure
        transcript_path = $tx
    }
    Write-Info2 "  exec: $($r.WallSeconds)s, failure_mode=$failure, transcript=$tx"

    # Echo a slice of the model's reply (after EXECUTION NOTES) so user can
    # see anything notable without opening the transcript file.
    if ($r.Json -and $r.Json.result) {
        $execNotes = Get-ExecutionNotes -ResultText ([string]$r.Json.result)
        if ($execNotes) {
            $line1 = ($execNotes -split "`n" | Select-Object -First 2) -join ' / '
            Write-Info2 "  notes: $line1"
        }
    }
    if ($failure -ne 'success' -and $r.Json -and $r.Json.result) {
        $resultPreview = ((([string]$r.Json.result) -split "`n") | Select-Object -First 5) -join "`n  "
        Write-Review "  $($failure): $resultPreview"
    }

    $execCost = [decimal]($r.Json.total_cost_usd ?? 0)
    $total    = $PlanCost + $execCost

    $overCeiling = $total -ge $CostCeilingPerItem

    return [pscustomobject]@{
        FailureMode = $failure
        ExecCost    = $execCost
        TotalCost   = $total
        OverCeiling = $overCeiling
        Parsed      = $parsed
        Raw         = $r
    }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

function Invoke-Main {
    Invoke-PreFlight

    $items = Get-TodoItems -Path $TodoFile
    if (-not $items) { Write-Ok "No todo items found. Nothing to do."; return 0 }

    $reviewed = Get-ReviewedItems -Path $NeedsReviewFile

    $iterations     = 0
    $consecClass    = 0
    $completedSlugs = New-Object System.Collections.Generic.HashSet[string]
    $planCache      = @{}  # slug -> Phase1 result (for PlanAllFirst)

    # ---------------- Pre-flight: eligible items ----------------
    $eligible = @()
    foreach ($it in $items) {
        if ($it.Checked) { continue }

        $reviewInfo = $reviewed[$it.Slug]
        if ($reviewInfo) {
            if ($reviewInfo.Resolved) {
                Write-Info2 "  [$($it.Slug)] resolutions present; re-queuing"
            } elseif ($SkipPlan) {
                Write-Info2 "  [$($it.Slug)] in needs-review but -SkipPlan: re-queuing"
            } else {
                Write-Review "  [$($it.Slug)] skipping: in needs-review.md with unresolved blockers"
                continue
            }
        }

        $blockingSlug = Get-ItemBlockedBy -ItemText $it.Text
        if ($blockingSlug) {
            Write-Review "  [$($it.Slug)] skipping: blocked by pending question on $blockingSlug"
            Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason "blocked by pending question on $blockingSlug" -Detail ''
            continue
        }

        $eligible += $it
    }

    if (-not $eligible) {
        Write-Ok "No eligible items. All done or all blocked."
        return 0
    }

    # ---------------- PlanAllFirst branch ----------------
    # Plan every eligible item upfront, route blocked ones to needs-review, then
    # rebuild the eligible list for phase 2 to just the survivors.
    if ($PlanAllFirst) {
        Write-Phase "PlanAllFirst: planning $($eligible.Count) items upfront"
        $foundational   = @()
        $phase2Eligible = @()
        foreach ($it in $eligible) {
            if ($iterations -ge $MaxIterations) { Write-Halt "MaxIterations"; return 4 }
            $iterations++
            $res = $reviewed[$it.Slug]
            $resolutionText = ''
            if ($res -and $res.Resolved) {
                $resolutionText = ($res.Blockers | ForEach-Object { "- Q: $($_.Question) -> A: $($_.Resolution)" }) -join "`n"
            }
            $p1 = Invoke-Phase1 -ItemText $it.Text -Slug $it.Slug -Resolutions $resolutionText -Subitems $it.Subitems
            $planCache[$it.Slug] = $p1

            if ($p1.Mode -eq 'error') {
                $detail = if ($p1.FailureMode -eq 'plan-validation-failed' -and $p1.ValidationOffender) {
                    "Forbidden verify command: $($p1.ValidationOffender)`n`nPlan content:`n$([string]$p1.Raw.Raw)"
                } else { [string]$p1.Raw.Raw }
                Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason "phase-1 failure: $($p1.FailureMode)" -Detail $detail
                Write-Review "  plan failure: $($p1.FailureMode)"
                continue
            }

            # Upgrade 4 — auto-tick if cached plan's verify already passes,
            # mirroring the per-item loop's already-done branch.
            if ($p1.Mode -eq 'already-done') {
                Update-TodoCheckbox -Path $TodoFile -Slug $it.Slug | Out-Null
                $verifyCmd = if ($p1.Plan -and $p1.Plan.Verify) { $p1.Plan.Verify[0] } else { '' }
                $sha = Commit-Item -Slug $it.Slug `
                    -Summary 'verify gate already passes; auto-tick via plan-staleness check' `
                    -Assumptions @() `
                    -Forced @() `
                    -VerifyCmd $verifyCmd `
                    -ExecutionNotes 'No execute phase ran. The cached plan''s verify gate already passes against the current tree.'
                Remove-BlockerRegistry -Slug $it.Slug
                $null = $completedSlugs.Add($it.Slug)
                Add-RunLog -Phase 'already-done' -Slug $it.Slug -InvocationResult ([pscustomobject]@{ExitCode=0;Json=$null}) -Extra @{
                    item_text    = $it.Text
                    mode         = 'already-done'
                    failure_mode = 'success'
                }
                Write-Ok "  [$($it.Slug)] already-done (verify already passes); committed $sha"
                continue
            }

            $fb = @($p1.Blockers | Where-Object { $_.Severity -eq 'foundational' })
            $ci = @($p1.Blockers | Where-Object { $_.Severity -eq 'cross-item' })
            $lo = @($p1.Blockers | Where-Object { $_.Severity -eq 'local' })

            if ($fb) { $foundational += [pscustomobject]@{ Slug = $it.Slug; Blockers = $fb } }
            if ($ci -and -not $ProceedOnBlockers) { Add-BlockerRegistry -Slug $it.Slug -CrossItemBlockers $ci }

            $hasAnyBlocker = ($fb -or $ci -or $lo)
            if ($hasAnyBlocker -and -not $ProceedOnBlockers) {
                Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason 'blockers' -Blockers @($fb + $ci + $lo) -Detail ''
                Write-Review "  [$($it.Slug)] blockers: $($fb.Count) foundational, $($ci.Count) cross-item, $($lo.Count) local"
                continue  # do NOT advance to phase 2
            }
            if ($fb -and $ProceedOnBlockers) {
                # foundational always halts regardless of -ProceedOnBlockers
                continue
            }
            Write-Ok "  [$($it.Slug)] planned: `$$('{0:N2}' -f $p1.Cost)"
            $phase2Eligible += $it
        }

        if ($foundational.Count -gt 0) {
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine("# HALT: foundational blockers found during PlanAllFirst")
            [void]$sb.AppendLine("")
            foreach ($f in $foundational) {
                [void]$sb.AppendLine("## $($f.Slug)")
                foreach ($b in $f.Blockers) {
                    [void]$sb.AppendLine("- **$($b.Name)** ($($b.Severity))")
                    [void]$sb.AppendLine("  - q: $($b.Question)")
                    [void]$sb.AppendLine("  - default: $($b.DefaultAssumption)")
                }
                [void]$sb.AppendLine("")
            }
            [void]$sb.AppendLine("See needs-review.md for the full set of blockers. Resolve foundational ones before re-running.")
            Set-Content -Path $script:HaltFile -Value $sb.ToString() -Encoding utf8
            Write-Halt "foundational blockers found; HALT.md written"
            return 2
        }

        if ($DryRunPlan) {
            Write-Ok "PlanAllFirst + DryRunPlan: stopping after planning pass."
            return 0
        }

        # From here on, only items that planned cleanly (or were forced past blockers)
        # are in the eligible list. The main loop below reuses their cached plans.
        $eligible = $phase2Eligible
        if (-not $eligible) {
            Write-Ok "PlanAllFirst: nothing to execute after planning pass."
            return 0
        }
    }

    # ---------------- Per-item main loop ----------------
    $itemNum = 0
    foreach ($it in $eligible) {
        $itemNum++
        # Upgrade 2 — honor a HALT.md written mid-cycle (e.g. by the verify
        # circuit breaker on the previous item) before starting more work.
        if (Test-Path $script:HaltFile) {
            Write-Halt "HALT.md present; stopping per-item loop"
            return 5
        }
        if ($iterations -ge $MaxIterations -and -not $PlanAllFirst) {
            Write-Halt "MaxIterations reached ($MaxIterations)"
            return 4
        }

        # --- phase 1 (skip if PlanAllFirst already cached a clean plan) ---
        $forcedAssumptions = @()
        $planAllFirstCached = ($PlanAllFirst -and $planCache.ContainsKey($it.Slug))

        if ($planAllFirstCached) {
            $p1 = $planCache[$it.Slug]
        } else {
            $iterations++
            $res = $reviewed[$it.Slug]
            $resolutionText = ''
            if ($res -and $res.Resolved) {
                $resolutionText = ($res.Blockers | ForEach-Object { "- Q: $($_.Question) -> A: $($_.Resolution)" }) -join "`n"
            }
            $p1 = Invoke-Phase1 -ItemText $it.Text -Slug $it.Slug -Resolutions $resolutionText -Subitems $it.Subitems
        }

        if ($p1.Mode -eq 'error') {
            $detail = if ($p1.FailureMode -eq 'plan-validation-failed' -and $p1.ValidationOffender) {
                "Forbidden verify command: $($p1.ValidationOffender)`n`nPlan content:`n$([string]$p1.Raw.Raw)"
            } else { [string]$p1.Raw.Raw }
            Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason "phase-1 failure: $($p1.FailureMode)" -Detail $detail
            Write-Review "[$itemNum/$($eligible.Count)] $($it.Slug): plan failure ($($p1.FailureMode))"
            if ($p1.FailureMode -eq 'classifier-terminated') {
                $consecClass++
                if ($consecClass -ge 3) { Write-Halt "3 consecutive classifier terminations"; return 3 }
            } else { $consecClass = 0 }
            continue
        }

        # Upgrade 4 — short-circuit when the cached plan's verify gate already
        # passes against the current tree. Work was done externally between
        # runs (e.g. a hand-fix); just tick the box and commit.
        if ($p1.Mode -eq 'already-done') {
            Update-TodoCheckbox -Path $TodoFile -Slug $it.Slug | Out-Null
            $verifyCmd = if ($p1.Plan -and $p1.Plan.Verify) { $p1.Plan.Verify[0] } else { '' }
            $sha = Commit-Item -Slug $it.Slug `
                -Summary 'verify gate already passes; auto-tick via plan-staleness check' `
                -Assumptions @() `
                -Forced @() `
                -VerifyCmd $verifyCmd `
                -ExecutionNotes 'No execute phase ran. The cached plan''s verify gate already passes against the current tree (work landed externally); the runner short-circuited.'
            Remove-BlockerRegistry -Slug $it.Slug
            $null = $completedSlugs.Add($it.Slug)
            Add-RunLog -Phase 'already-done' -Slug $it.Slug -InvocationResult ([pscustomobject]@{ExitCode=0;Json=$null}) -Extra @{
                item_text    = $it.Text
                mode         = 'already-done'
                failure_mode = 'success'
            }
            Write-Ok "[$itemNum/$($eligible.Count)] $($it.Slug): already-done (verify already passes); committed $sha"
            $consecClass = 0
            continue
        }

        # --- blocker triage (skip entirely if PlanAllFirst already vetted this item) ---
        if (-not $planAllFirstCached) {
            $fb = @($p1.Blockers | Where-Object { $_.Severity -eq 'foundational' })
            $ci = @($p1.Blockers | Where-Object { $_.Severity -eq 'cross-item' })
            $lo = @($p1.Blockers | Where-Object { $_.Severity -eq 'local' })

            if ($fb) {
                Set-Content -Path $script:HaltFile -Value ("# HALT: foundational blocker on $($it.Slug)`n`n" +
                    (($fb | ForEach-Object { "- $($_.Name): $($_.Question)`n  default: $($_.DefaultAssumption)" }) -join "`n")) -Encoding utf8
                Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason 'foundational blocker' -Blockers $fb -Detail ''
                Write-Halt "[$itemNum/$($eligible.Count)] $($it.Slug): foundational blocker; HALT.md written"
                foreach ($b in $fb) {
                    Write-Halt "    [foundational] $($b.Question)"
                    Write-Info2 "      default: $($b.DefaultAssumption)"
                }
                return 2
            }

            if ($ci -or $lo) {
                if ($ProceedOnBlockers) {
                    foreach ($b in @($ci + $lo)) {
                        $forcedAssumptions += "$($b.Question) -> $($b.DefaultAssumption)"
                    }
                    Add-RunLog -Phase 'assumption' -Slug $it.Slug -InvocationResult ([pscustomobject]@{ExitCode=0;Json=$null}) -Extra @{
                        ASSUMPTION_FORCED = $true
                        blockers = @($ci + $lo) | ForEach-Object { @{ q=$_.Question; default=$_.DefaultAssumption; sev=$_.Severity } }
                    }
                } else {
                    if ($ci) { Add-BlockerRegistry -Slug $it.Slug -CrossItemBlockers $ci }
                    Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason 'blockers' -Blockers @($ci + $lo) -Detail ''
                    Write-Review "[$itemNum/$($eligible.Count)] $($it.Slug): $($ci.Count) cross-item, $($lo.Count) local blockers -> needs-review"
                    foreach ($b in @($ci + $lo)) {
                        Write-Review "    [$($b.Severity)] $($b.Question)"
                        Write-Info2  "      default: $($b.DefaultAssumption)"
                    }
                    $consecClass = 0
                    continue
                }
            }
        } elseif ($ProceedOnBlockers -and $p1.Blockers) {
            # Cached clean-or-forced plan under PlanAllFirst: rebuild forcedAssumptions from cached blockers
            foreach ($b in $p1.Blockers | Where-Object { $_.Severity -ne 'foundational' }) {
                $forcedAssumptions += "$($b.Question) -> $($b.DefaultAssumption)"
            }
            if ($forcedAssumptions) {
                Add-RunLog -Phase 'assumption' -Slug $it.Slug -InvocationResult ([pscustomobject]@{ExitCode=0;Json=$null}) -Extra @{
                    ASSUMPTION_FORCED = $true
                    blockers = $p1.Blockers | Where-Object { $_.Severity -ne 'foundational' } | ForEach-Object { @{ q=$_.Question; default=$_.DefaultAssumption; sev=$_.Severity } }
                }
            }
        }

        if ($p1.Cost -ge $CostCeilingPerItem) {
            Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason 'cost ceiling (phase 1)' -Detail "plan cost = $($p1.Cost)"
            Write-Review "[$itemNum/$($eligible.Count)] $($it.Slug): cost ceiling hit at phase 1"
            $consecClass = 0
            continue
        }

        if ($DryRunPlan -and -not $PlanAllFirst) {
            Write-Ok "[$itemNum/$($eligible.Count)] $($it.Slug): planned (DryRunPlan, skipping execute)"
            continue
        }

        # --- phase 2 ---
        $p2 = Invoke-Phase2 -Slug $it.Slug -PlanPath $p1.PlanPath -ForcedAssumptions $forcedAssumptions -PlanCost $p1.Cost -ItemText $it.Text

        if ($p2.FailureMode -eq 'classifier-terminated') {
            Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason 'auto-mode blocked (classifier)' -Detail ([string]$p2.Raw.Raw)
            Invoke-Rollback -Slug $it.Slug
            Write-Review "[$itemNum/$($eligible.Count)] $($it.Slug): classifier-terminated"
            $consecClass++
            if ($consecClass -ge 3) { Write-Halt "3 consecutive classifier terminations"; return 3 }
            continue
        }
        if ($p2.FailureMode -eq 'needs-clarification') {
            Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason 'needs clarification' -Detail ([string]$p2.Raw.Json.result)
            Invoke-Rollback -Slug $it.Slug
            Write-Review "[$itemNum/$($eligible.Count)] $($it.Slug): needs clarification"
            $consecClass = 0
            continue
        }
        if ($p2.FailureMode -ne 'success') {
            Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason "phase-2 $($p2.FailureMode)" -Detail ([string]$p2.Raw.Raw)
            Invoke-Rollback -Slug $it.Slug
            Write-Review "[$itemNum/$($eligible.Count)] $($it.Slug): phase-2 $($p2.FailureMode)"
            $consecClass = 0
            continue
        }
        if ($p2.OverCeiling) {
            Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason 'cost ceiling' -Detail ("plan=$($p1.Cost) exec=$($p2.ExecCost) total=$($p2.TotalCost)")
            Invoke-Rollback -Slug $it.Slug
            Write-Review "[$itemNum/$($eligible.Count)] $($it.Slug): cost ceiling hit (total=$($p2.TotalCost))"
            $consecClass = 0
            continue
        }

        # --- independent verify ---
        $verify = Test-Verify -Commands $p2.Parsed.Verify
        if (-not $verify.Passed) {
            Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason 'verify failed' -Detail $verify.Output
            Invoke-Rollback -Slug $it.Slug
            Write-Review "[$itemNum/$($eligible.Count)] $($it.Slug): verify failed on '$($verify.FailedCommand)'"
            # Print the last few lines of verify output so the failure is visible
            # without opening needs-review.md.
            $tail = ($verify.Output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 5) -join "`n    "
            if ($tail) { Write-Review "    $tail" }

            # Upgrade 2 — circuit breaker: track verify-fail fingerprints. If
            # the same error repeats N consecutive items or M total times,
            # write HALT.md and exit; the runner can't self-correct from a
            # repeating-error loop.
            $vf = Update-VerifyFailRegistry -Slug $it.Slug -Output $verify.Output -FailedCommand $verify.FailedCommand
            if ($vf.HaltTriggered) {
                Write-Halt "verify-fail circuit breaker tripped (fingerprint=$($vf.Fingerprint), consec=$($vf.ConsecCount), total=$($vf.FpCount)); HALT.md written"
                return 5
            }

            $consecClass = 0
            continue
        }
        # Upgrade 2 — verify passed: reset the consecutive-same counter so a
        # later mismatched fail doesn't keep tripping the breaker.
        Reset-VerifyFailConsecutive

        # --- mark + commit (mark first so the [x] is included in the commit) ---
        Update-TodoCheckbox -Path $TodoFile -Slug $it.Slug | Out-Null
        $verifyCmd = if ($p2.Parsed.Verify) { $p2.Parsed.Verify[0] } else { '' }
        $execNotes = Get-ExecutionNotes -ResultText ([string]$p2.Raw.Json.result)
        $sha = Commit-Item -Slug $it.Slug -Summary $p2.Parsed.Summary -Assumptions $p2.Parsed.Assumptions -Forced $forcedAssumptions -VerifyCmd $verifyCmd -ExecutionNotes $execNotes
        Remove-BlockerRegistry -Slug $it.Slug
        $null = $completedSlugs.Add($it.Slug)

        $planCostStr = '{0:N2}' -f $p1.Cost
        $execCostStr = '{0:N2}' -f $p2.ExecCost
        Write-Ok "[$itemNum/$($eligible.Count)] $($it.Slug): plan `$$planCostStr / execute `$$execCostStr / verified / committed $sha"
        $consecClass = 0
    }

    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

try {
    $code = Invoke-Main
    exit $code
} catch {
    Write-Halt $_.Exception.Message
    Write-Verbose ($_.ScriptStackTrace)
    exit 1
}
