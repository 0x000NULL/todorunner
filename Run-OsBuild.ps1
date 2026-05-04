#Requires -Version 7.0
# Run-OsBuild.ps1 — Autonomous OS-build + blog runner for Claude Code (pwsh 7+, cross-platform).
# Specialized fork of Run-Todos.ps1: drives Claude through a roadmap of kernel,
# blog, and status items derived from a Phase-0 design pass. Reads a toolchain
# manifest at ./.claude/os-design/toolchain.yaml; verifies kernel items by
# booting under QEMU and scraping serial output.
#
# Windows note: the claude binary resolves as claude.cmd; Get-Command handles both.

[CmdletBinding()]
param(
    # OS-build mode selector. 'build' is the legacy plan->execute->verify loop
    # (default). 'design' produces a Phase-0 spec + toolchain.yaml. 'roadmap'
    # turns the spec into todo.md. 'digest' fires the status-digest hook ad-hoc.
    [ValidateSet('build','design','roadmap','digest')]
    [string]$Mode = 'build',

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
    [int]$MaxTurns = 100,
    [int]$MaxTurnsRetryMultiplier = 2,
    [switch]$SkipToolchainProbe,
    [switch]$RetryNeedsReview,
    [int]$VerifyFingerprintConsecLimit = 3,
    [int]$VerifyFingerprintTotalLimit  = 5,

    # Phase-0 design pass + toolchain manifest paths.
    [string]$OsDesignDir     = './.claude/os-design',
    [string]$ToolchainConfig = './.claude/os-design/toolchain.yaml',
    [string]$DesignSpecPath  = './.claude/os-design/spec.md',

    # Blog publishing (sibling repo with /posts and STATUS-*.md).
    [string]$BlogRepoPath    = '../os-blog',
    [string]$BlogPostsSubdir = 'posts',
    [int]$BlogMinWords       = 400,

    # Status digest cadence.
    [int]$StatusEveryN       = 5,
    [switch]$DisableStatusDigest,

    # QEMU verify dialect knobs (Phase E).
    [int]$QemuTimeoutSeconds = 60,
    [string]$SerialLogPath   = './.claude/todo-runner/serial.log',
    [string]$QemuExtraArgs   = '',

    # Phase H — dev-only fixture mode for the smoke test. When -NoClaude is
    # set, every Invoke-Claude call returns a pre-canned reply read from
    # $FixtureRepliesDir/<N>.json (N is a monotonically-incrementing counter
    # starting at 1). Lets the runner exercise its full control flow
    # deterministically without API access.
    [switch]$NoClaude,
    [string]$FixtureRepliesDir = './tests/fixture-os/replies'
)

$ErrorActionPreference = 'Stop'
$script:PlansDir    = Join-Path '.claude' 'plans'
$script:RunnerDir   = Join-Path '.claude' 'todo-runner'
$script:RunsLog     = Join-Path $script:RunnerDir 'runs.jsonl'
$script:BlockersDb  = Join-Path $script:RunnerDir 'blockers.json'
$script:VerifyFailDb = Join-Path $script:RunnerDir 'verify-fails.json'
$script:Transcripts = Join-Path $script:RunnerDir 'transcripts'
$script:HaltFile     = './HALT.md'
$script:ClaudeExe    = $null  # resolved in pre-flight
$script:BashExe      = $null  # resolved in pre-flight
$script:FixtureCount = 0      # Phase H — monotonic Invoke-Claude counter for -NoClaude

# ---------------------------------------------------------------------------
# Toolchain registry (populated in Phase D from .claude/os-design/toolchain.yaml)
# ---------------------------------------------------------------------------
# Phase A leaves this as an empty placeholder so Invoke-DepProbe can stay a
# no-op stub. Phase D wires it to the OS toolchain manifest produced by the
# Phase-0 design pass.

$script:Toolchain   = $null
$script:DepRegistry = @()

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

function Write-Phase   { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok      { param($m) Write-Host "    $m" -ForegroundColor Green }
function Write-Review  { param($m) Write-Host "    $m" -ForegroundColor Yellow }
function Write-Halt    { param($m) Write-Host "!!  $m" -ForegroundColor Red }
function Write-Info2   { param($m) Write-Host "    $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Toolchain manifest (YAML) — minimal hand-rolled parser
# ---------------------------------------------------------------------------
# Schema is fixed (see make-a-plan-to-dreamy-flamingo.md §5). Block style only:
# nested maps via 2-space indentation, lists via leading "- ". Quoted strings
# ("..." / '...'), integers, booleans (true/false), null/~. NO flow-style
# (no `[a, b]`, no `{k: v}`). Comments are full-line (`#`); trailing comments
# are not supported. The design-pass prompt enforces this style.

function _Parse-OsYamlValue {
    param([string]$Text)
    if ($null -eq $Text -or $Text -eq '') { return '' }
    if ($Text -match '^"(.*)"$') {
        $s = $matches[1]
        $sentinel = "`u{0001}"
        $s = $s.Replace('\\', $sentinel)
        $s = $s.Replace('\"', '"')
        $s = $s.Replace('\n', "`n")
        $s = $s.Replace('\t', "`t")
        $s = $s.Replace($sentinel, '\')
        return $s
    }
    if ($Text -match "^'(.*)'$") { return $matches[1] }
    if ($Text -match '^-?\d+$')  { return [int]$Text }
    if ($Text -eq 'true')  { return $true }
    if ($Text -eq 'false') { return $false }
    if ($Text -eq 'null' -or $Text -eq '~') { return $null }
    return $Text   # bare string
}

function _Parse-OsYamlMap {
    param([System.Collections.Generic.List[object]]$Tokens, [ref]$Idx, [int]$BaseIndent)
    $map = [ordered]@{}
    while ($Idx.Value -lt $Tokens.Count) {
        $tok = $Tokens[$Idx.Value]
        if ($tok.Indent -lt $BaseIndent) { return $map }
        if ($tok.Indent -gt $BaseIndent) {
            throw "Unexpected indentation at line: $($tok.Raw)"
        }
        if ($tok.Text -match '^-\s') { return $map }
        if ($tok.Text -notmatch '^([A-Za-z_][\w\-]*):\s*(.*)$') {
            throw "Expected 'key:' or 'key: value' at line: $($tok.Raw)"
        }
        $key  = $matches[1]
        $rest = $matches[2]
        $Idx.Value++
        if ($rest -ne '') {
            $map[$key] = _Parse-OsYamlValue $rest
            continue
        }
        if ($Idx.Value -ge $Tokens.Count) { $map[$key] = $null; continue }
        $next = $Tokens[$Idx.Value]
        if ($next.Indent -le $BaseIndent) { $map[$key] = $null; continue }
        if ($next.Text -match '^-\s') {
            $map[$key] = _Parse-OsYamlList -Tokens $Tokens -Idx $Idx -BaseIndent $next.Indent
        } else {
            $map[$key] = _Parse-OsYamlMap -Tokens $Tokens -Idx $Idx -BaseIndent $next.Indent
        }
    }
    return $map
}

function _Parse-OsYamlList {
    param([System.Collections.Generic.List[object]]$Tokens, [ref]$Idx, [int]$BaseIndent)
    $list = New-Object System.Collections.Generic.List[object]
    while ($Idx.Value -lt $Tokens.Count) {
        $tok = $Tokens[$Idx.Value]
        if ($tok.Indent -lt $BaseIndent) { break }
        if ($tok.Indent -gt $BaseIndent) {
            throw "Unexpected indentation at line: $($tok.Raw)"
        }
        if ($tok.Text -notmatch '^-\s*(.*)$') { break }
        $rest = $matches[1]
        $Idx.Value++
        if ($rest -eq '') {
            if ($Idx.Value -ge $Tokens.Count) { $list.Add($null); continue }
            $next = $Tokens[$Idx.Value]
            if ($next.Indent -le $BaseIndent) { $list.Add($null); continue }
            $list.Add( (_Parse-OsYamlMap -Tokens $Tokens -Idx $Idx -BaseIndent $next.Indent) )
        } elseif ($rest -match '^([A-Za-z_][\w\-]*):\s*(.*)$') {
            $first = [ordered]@{}
            $first[$matches[1]] = _Parse-OsYamlValue $matches[2]
            $deeperIndent = $BaseIndent + 2
            $sub = _Parse-OsYamlMap -Tokens $Tokens -Idx $Idx -BaseIndent $deeperIndent
            foreach ($k in $sub.Keys) { $first[$k] = $sub[$k] }
            $list.Add($first)
        } else {
            $list.Add( (_Parse-OsYamlValue $rest) )
        }
    }
    # Return as object[] so callers can use @(...) and -join freely without
    # tripping PowerShell's argument-type-match on Generic.List<object>.
    return ,($list.ToArray())
}

function ConvertFrom-OsYaml {
    param([Parameter(Mandatory)][string]$Text)
    $rawLines = $Text -split "`r?`n"
    $tokens = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rawLines) {
        $line = $r -replace '\s+$',''
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s*#') { continue }
        $indent = 0
        while ($indent -lt $line.Length -and $line[$indent] -eq ' ') { $indent++ }
        $tokens.Add([pscustomobject]@{
            Indent = $indent
            Text   = $line.Substring($indent)
            Raw    = $line
        })
    }
    $idx = [ref]0
    return _Parse-OsYamlMap -Tokens $tokens -Idx $idx -BaseIndent 0
}

function Read-ToolchainConfig {
    # Loads + validates the OS toolchain manifest. Throws with a clear message
    # on malformed YAML or schema violations.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Toolchain config not found: $Path. Run with -Mode design first to produce it."
    }
    $text = Get-Content -Path $Path -Raw -ErrorAction Stop
    try {
        $doc = ConvertFrom-OsYaml -Text $text
    } catch {
        throw "Failed to parse toolchain config '$Path': $($_.Exception.Message)"
    }

    $known = @('project','required_tools','build','boot','blog')
    foreach ($k in $doc.Keys) {
        if ($known -notcontains $k) {
            throw "Toolchain config: unknown top-level key '$k' (expected one of: $($known -join ', '))"
        }
    }
    foreach ($req in @('project','required_tools','build','boot')) {
        if (-not $doc.Contains($req)) {
            throw "Toolchain config: missing required top-level section '$req'"
        }
    }
    if (-not $doc['project'].Contains('arch')) {
        throw "Toolchain config: project.arch is required"
    }
    if ($doc['project']['arch'] -notmatch '^[a-z0-9_]+$') {
        throw "Toolchain config: project.arch must match ^[a-z0-9_]+$ (got '$($doc['project']['arch'])')"
    }
    if (-not $doc['boot'].Contains('qemu_args')) {
        throw "Toolchain config: boot.qemu_args is required"
    }
    $argsBlob = ($doc['boot']['qemu_args'] -join ' ')
    if ($argsBlob -notmatch '\{\{ARTIFACT\}\}') {
        throw "Toolchain config: boot.qemu_args must contain '{{ARTIFACT}}' placeholder"
    }
    if ($argsBlob -notmatch '\{\{SERIAL_LOG\}\}') {
        throw "Toolchain config: boot.qemu_args must contain '{{SERIAL_LOG}}' placeholder"
    }
    return $doc
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

function Invoke-DepProbe {
    # Toolchain probe (Phase D). Iterates $script:Toolchain.required_tools and
    # runs each entry's probe_command via bash, optionally checking
    # version_regex + min_version. On hard miss, write HALT.md and exit 6.
    if ($SkipToolchainProbe) {
        Write-Verbose "Toolchain probe skipped via -SkipToolchainProbe"
        return
    }
    if (-not $script:Toolchain) { return }
    $tools = $script:Toolchain['required_tools']
    if (-not $tools -or $tools.Count -eq 0) { return }

    Write-Phase "toolchain probe ($($tools.Count) tool(s))"
    $missing = New-Object System.Collections.Generic.List[object]
    foreach ($t in $tools) {
        $name = [string]$t['name']
        $cmd  = [string]$t['probe_command']
        $rx   = [string]$t['version_regex']
        $min  = [string]$t['min_version']
        $warnOnly = [bool]$t['warn_only']
        if (-not $name -or -not $cmd) { continue }

        Write-Info2 "  probe $name : $cmd"
        $out = ''
        $exit = 0
        try {
            if ($script:BashExe) {
                $out  = (& $script:BashExe -c $cmd 2>&1 | Out-String)
                $exit = $LASTEXITCODE
            } else {
                $out  = (& pwsh -NoProfile -Command $cmd 2>&1 | Out-String)
                $exit = $LASTEXITCODE
            }
        } catch {
            $exit = 127
            $out  = $_.Exception.Message
        }

        $found   = $true
        $version = ''
        if ($exit -ne 0) {
            $found = $false
        } elseif ($rx) {
            $m = [regex]::Match($out, $rx)
            if ($m.Success -and $m.Groups.Count -gt 1) {
                $version = $m.Groups[1].Value
                if ($min) {
                    try {
                        $vClean = ($version -replace '[^\d\.].*$', '')
                        $mClean = ($min     -replace '[^\d\.].*$', '')
                        if ($vClean -and $mClean -and ([version]$vClean -lt [version]$mClean)) {
                            $found = $false
                        }
                    } catch {
                        Write-Verbose "    couldn't parse version '$version' vs min '$min'; skipping comparison"
                    }
                }
            } else {
                $found = $false
            }
        }

        if ($found) {
            if ($version) { Write-Ok "    $name $version" } else { Write-Ok "    $name" }
            continue
        }
        $hints = $t['install_hints']
        $missing.Add([pscustomobject]@{
            Name           = $name
            Cmd            = $cmd
            Version        = $version
            MinVersion     = $min
            WarnOnly       = $warnOnly
            InstallWindows = if ($hints) { [string]$hints['windows'] } else { '' }
            InstallLinux   = if ($hints) { [string]$hints['linux'] }   else { '' }
            InstallMac     = if ($hints) { [string]$hints['mac'] }     else { '' }
            ExitCode       = $exit
            Output         = ($out -as [string]).Trim()
        })
        Write-Review "    $name MISSING (exit=$exit$( if ($version -and $min) { ", found=$version<min=$min" } else { '' } ))"
    }

    if ($missing.Count -eq 0) { return }

    $warnList = @($missing | Where-Object { $_.WarnOnly })
    foreach ($e in $warnList) {
        Write-Warning "Optional tool not found: $($e.Name) (warn_only)"
        if ($IsWindows)   { Write-Warning "  install: $($e.InstallWindows)" }
        elseif ($IsMacOS) { Write-Warning "  install: $($e.InstallMac)" }
        else              { Write-Warning "  install: $($e.InstallLinux)" }
    }
    $hard = @($missing | Where-Object { -not $_.WarnOnly })
    if ($hard.Count -eq 0) { return }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# HALT: missing toolchain")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("The OS toolchain manifest at ``$ToolchainConfig`` lists required tools that are not present (or below their declared ``min_version``). Install them and re-run, or pass ``-SkipToolchainProbe`` to bypass.")
    [void]$sb.AppendLine("")
    foreach ($e in $hard) {
        [void]$sb.AppendLine("## $($e.Name)")
        if ($e.MinVersion -and $e.Version) {
            [void]$sb.AppendLine("Required: ``$($e.Name) >= $($e.MinVersion)`` (found: $($e.Version))")
        } elseif ($e.MinVersion) {
            [void]$sb.AppendLine("Required: ``$($e.Name) >= $($e.MinVersion)`` (probe exited $($e.ExitCode))")
        } else {
            [void]$sb.AppendLine("Required: ``$($e.Name)`` (probe ``$($e.Cmd)`` exited $($e.ExitCode))")
        }
        [void]$sb.AppendLine("Install:")
        [void]$sb.AppendLine("- **Windows:** ``$($e.InstallWindows)``")
        [void]$sb.AppendLine("- **Linux:**   ``$($e.InstallLinux)``")
        [void]$sb.AppendLine("- **macOS:**   ``$($e.InstallMac)``")
        [void]$sb.AppendLine("")
    }
    Set-Content -Path $script:HaltFile -Value $sb.ToString() -Encoding utf8
    Write-Halt "Toolchain probe failed: $($hard.Count) tool(s) missing; HALT.md written."
    foreach ($e in $hard) { Write-Halt "  - $($e.Name)" }
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

    # Design and roadmap modes author todo.md / spec.md themselves, so they
    # don't require a pre-existing todo.md and don't worry about a dirty tree.
    if ($Mode -eq 'build') {
        if (-not (Test-Path $TodoFile)) {
            throw "Todo file not found: $TodoFile (run -Mode roadmap to generate it from the design spec)"
        }
        $dirty = git status --porcelain
        if ($dirty) {
            Write-Warning "Working tree is dirty. Runner will create commits interleaved with your uncommitted work. Consider 'git worktree add ../todo-run' first."
        }
    }

    foreach ($d in @($script:PlansDir, $script:RunnerDir, $script:Transcripts, $OsDesignDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # Load the OS toolchain manifest in build mode. Design and roadmap modes
    # operate before the manifest is finalized; digest mode only reads
    # runs.jsonl + git log and doesn't need it.
    if ($Mode -eq 'build') {
        $script:Toolchain = Read-ToolchainConfig -Path $ToolchainConfig
        Write-Verbose "Toolchain loaded: $($script:Toolchain['project']['name']) ($($script:Toolchain['project']['arch']))"
    }

    # Phase A stub: dep-probe is a no-op until Phase D wires it to the
    # toolchain manifest. Multi-language baseline check is permanently gone
    # (kernel work has its own QEMU-boot verify dialect added in Phase E).
    if ($Mode -eq 'build') {
        Invoke-DepProbe
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

        # Phase F — capture an <!-- type: kernel|blog|status --> marker. The
        # marker may trail the checkbox line itself, or appear on the very
        # next line indented 0-4 spaces. Missing marker => 'kernel'. Marker
        # line is consumed and never becomes a sub-bullet.
        $type = 'kernel'
        if ($text -match '^(.*?)\s*<!--\s*type:\s*(kernel|blog|status)\s*-->\s*$') {
            $text = $matches[1].TrimEnd()
            $type = $matches[2]
        }
        elseif ($i + 1 -lt $lines.Count -and `
                $lines[$i + 1] -match '^\s{0,4}<!--\s*type:\s*(kernel|blog|status)\s*-->\s*$') {
            $type = $matches[1]
            $i++   # consume the marker line so subitem peek and the outer
                   # for-loop both skip past it
        }

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
            Type       = $type
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
        [int]$MaxTurns = 100
    )

    # Phase H — fixture short-circuit. When -NoClaude is set, return a
    # pre-canned reply JSON from $FixtureRepliesDir/<N>.json, never hitting
    # the API. The fixture file must be a top-level "claude -p --output-format
    # json"-shaped object (result, total_cost_usd, num_turns, is_error,
    # subtype, stop_reason, session_id). The counter is global to the run.
    if ($NoClaude) {
        $script:FixtureCount++
        $fxPath = Join-Path $FixtureRepliesDir "$($script:FixtureCount).json"
        if (-not (Test-Path $fxPath)) {
            throw "Invoke-Claude (-NoClaude): fixture reply not found at $fxPath (call #$($script:FixtureCount))"
        }
        $raw = Get-Content -Path $fxPath -Raw
        $json = $null
        try { $json = $raw | ConvertFrom-Json -ErrorAction Stop } catch {}
        return [pscustomobject]@{
            ExitCode    = 0
            Raw         = $raw
            StdErr      = ''
            Json        = $json
            Prompt      = $Prompt
            WallSeconds = 0.01
        }
    }

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
           success | classifier-terminated | needs-clarification |
           max-turns-exhausted | other-error | infra-error
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
    $subtype    = [string]$json.subtype
    $numTurns   = [int]($json.num_turns | ForEach-Object { if ($_ -ne $null) { $_ } else { 0 } })

    # Max-turns exhaustion is reported by the CLI as is_error=true with
    # subtype="error_max_turns". Surface it as its own failure mode so the
    # runner can auto-retry with a bigger budget instead of dumping to
    # needs-review like a generic infra error.
    if ($subtype -eq 'error_max_turns') { return 'max-turns-exhausted' }

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

    # Phase F+: capture the leading `# kind:` and optional `# skip-boot:`
    # markers. Both are top-of-file directives, not section headers; their
    # job is to steer the verify dispatcher (kernel/blog/status) and let
    # setup-only kernel items opt out of the QEMU boot pass.
    $kind = ''
    $km = [regex]::Match($text, '(?im)^\s*#\s*kind:\s*(kernel|blog|status)\s*$')
    if ($km.Success) { $kind = $km.Groups[1].Value }

    $skipBoot = ''
    $sbm = [regex]::Match($text, '(?im)^\s*#\s*skip-boot:\s*(.+?)\s*$')
    if ($sbm.Success) { $skipBoot = $sbm.Groups[1].Value.Trim() }

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

    # Upgrade 11 — Prereqs section. Slugs of sibling items this plan
    # depends on; the eligibility loop topo-sorts on these. Format is
    # either "Prereqs: none" (line in body) or a bulleted list of slugs.
    $prereqs = @()
    $pm = [regex]::Match($text, '(?ms)^##\s*Prereqs\s*\r?\n(.*?)(?=^##\s|\z)')
    if ($pm.Success) {
        $body = $pm.Groups[1].Value.Trim()
        if ($body -notmatch '^(?i)Prereqs:\s*none') {
            foreach ($line in ($body -split "`n")) {
                $tm = [regex]::Match($line.Trim(), '^[-*]\s*([a-z0-9][a-z0-9\-]*)')
                if ($tm.Success) { $prereqs += $tm.Groups[1].Value }
            }
        }
    }

    return [pscustomobject]@{
        Verify      = $verify
        Assumptions = $assumptions
        Blockers    = $blockers
        Summary     = $summary
        Prereqs     = @($prereqs | Select-Object -Unique)
        Kind        = $kind
        SkipBoot    = $skipBoot
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
    # grep/rg/ack against runner bookkeeping files (drift-prone; staleness signal)
    '\b(grep|rg|ack)\b[^|;&]*\b(TODO|todo|needs-review|HALT)\.md\b',
    '\b(grep|rg|ack)\b[^|;&]*\.claude[/\\]',
    # nested pwsh inside a bash verify line — quoting nightmare
    '\bpwsh\b[^|;&]*-Command',
    # generic dev-runner traps that don't apply to OS work; cargo xrun/xtask
    # are the canonical Rust-OS entry points and remain allowed by the word
    # boundary on `cargo run` (xrun != run).
    '\b(cargo run|npm start|npm run dev|yarn start|yarn dev)\b',
    # bare qemu-system-* with no timeout/no-reboot/monitor wrapper. The
    # runner wraps kernel verify itself; plans should not invoke qemu
    # directly without explicit safeguards.
    '\bqemu-system-[a-z0-9_]+\b(?![^|;&]*\b(timeout|-no-shutdown\s+-no-reboot|--?monitor)\b)'
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

function Test-VerifySanity {
    # Phase E — kernel/blog-aware lint of plan verify commands. Returns
    # Passed (bool) + FirstOffender + Reason. Caller (Invoke-Phase1) routes
    # a failure through Add-NeedsReview with reason 'plan-validation-failed'
    # so the runner re-plans on the next pass instead of burning Phase 2 on
    # a doomed verify.
    #
    # Checks:
    #   (a) qemu-system-<arch> referenced ⇒ binary must be on PATH.
    #   (b) ELF/IMG/ISO/BIN artefacts referenced ⇒ a build line earlier in
    #       the same Verify block must plausibly produce them, OR the file
    #       already exists.
    param([Parameter(Mandatory)][string[]]$Verify)

    # (a)
    foreach ($cmd in $Verify) {
        if (-not $cmd) { continue }
        $qm = [regex]::Match($cmd, '\b(qemu-system-[a-z0-9_]+)\b')
        if ($qm.Success) {
            $qb = $qm.Groups[1].Value
            if (-not (Get-Command $qb -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{
                    Passed        = $false
                    FirstOffender = $cmd
                    Reason        = "Verify references '$qb' but it is not on PATH. Install QEMU or align toolchain.yaml with what is installed."
                }
            }
        }
    }

    # (b) — does any verify line look like a build step?
    $hasBuild = $false
    foreach ($cmd in $Verify) {
        if (-not $cmd) { continue }
        if ($cmd -match '\b(cargo\s+(build|xtask|xrun|test|check)|make\b|cmake\s+--build|ninja\b|zig\s+build|go\s+(build|test))\b') {
            $hasBuild = $true; break
        }
    }
    foreach ($cmd in $Verify) {
        if (-not $cmd) { continue }
        $artifactRefs = [regex]::Matches($cmd, '(?<![\w.-])(target/[\w./\\-]+|build/[\w./\\-]+|[\w./\\-]+\.(?:elf|img|iso|bin))')
        foreach ($am in $artifactRefs) {
            $ap = $am.Groups[1].Value.TrimEnd(',', ';', ')')
            if ($hasBuild) { continue }
            if (Test-Path -LiteralPath $ap) { continue }
            return [pscustomobject]@{
                Passed        = $false
                FirstOffender = $cmd
                Reason        = "Verify references artefact '$ap' but no build command (cargo/make/cmake/ninja/zig/go) earlier in the same Verify block produces it."
            }
        }
    }

    return [pscustomobject]@{ Passed = $true; FirstOffender = $null; Reason = $null }
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
    #
    # Phase F: -Kind / -Context get plumbed through to Test-Verify so the
    # right dialect runs (kernel boot vs blog frontmatter vs status). For
    # legacy unmarked plans, Get-PlanKind returns 'shell' and we fall back
    # to the literal-shell verifier.
    param(
        [Parameter(Mandatory)]$Plan, [string]$Slug,
        [string]$Kind = 'shell',
        [hashtable]$Context = @{}
    )

    if (-not $Plan -or -not $Plan.Verify -or $Plan.Verify.Count -eq 0) {
        return [pscustomobject]@{ Verdict = 'reusable'; FailedCommand = $null }
    }

    # Enrich context from the cached plan so the kernel verify can honor a
    # leading `# skip-boot: <reason>` directive without the caller needing
    # to re-parse the plan text.
    if ($Plan.PSObject.Properties.Name -contains 'SkipBoot' -and $Plan.SkipBoot -and -not $Context['SkipBoot']) {
        $Context = @{} + $Context
        $Context['SkipBoot'] = $Plan.SkipBoot
    }

    $r = Test-Verify -Commands $Plan.Verify -Kind $Kind -Context $Context
    if ($r.Passed) {
        return [pscustomobject]@{ Verdict = 'already-done'; FailedCommand = $null }
    }
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

function _Invoke-VerifyShellLine {
    # Internal helper: run one shell line via $script:BashExe (or pwsh
    # fallback). Returns [pscustomobject]@{ Output; ExitCode }.
    param([string]$Cmd)
    try {
        if ($script:BashExe) {
            $out = & $script:BashExe -c $Cmd 2>&1 | Out-String
        } else {
            $out = pwsh -NoProfile -Command $Cmd 2>&1 | Out-String
        }
        return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
    } catch {
        return [pscustomobject]@{ Output = $_.Exception.Message; ExitCode = 127 }
    }
}

function Test-VerifyKernelBoot {
    # Kernel verify: run pre-boot lines from the plan literally; then build
    # the qemu invocation from $script:Toolchain.boot, run it under a
    # cross-platform timeout, and pass iff every expect_serial.required
    # regex matches the captured serial output AND no expect_serial.forbidden
    # regex matches. Optional `integration: <cmd>` lines run after a
    # successful boot.
    #
    # When -SkipBootReason is set (driven by the plan's leading
    # `# skip-boot: <reason>` directive — used for setup-only items that
    # don't yet produce a bootable kernel image), the runner runs the
    # plan's verify lines literally and skips the QEMU pass entirely.
    # Pass iff every command exits 0.
    param([string[]]$Commands, $Toolchain, [string]$SkipBootReason = '')
    if (-not $Toolchain -and -not $SkipBootReason) {
        return [pscustomobject]@{ Passed = $false; Output = "no toolchain loaded; kernel verify cannot run"; FailedCommand = '<runner>' }
    }

    # Skip-boot path: run lines literally, no QEMU.
    if ($SkipBootReason) {
        $allOutput = [System.Text.StringBuilder]::new()
        [void]$allOutput.AppendLine("(boot skipped: $SkipBootReason)")
        foreach ($cmd in $Commands) {
            if (-not $cmd) { continue }
            if ($cmd -match '^\s*integration:') { continue }
            [void]$allOutput.AppendLine("+ $cmd")
            $r = _Invoke-VerifyShellLine -Cmd $cmd
            [void]$allOutput.Append($r.Output)
            if ($r.ExitCode -ne 0) {
                return [pscustomobject]@{ Passed = $false; Output = $allOutput.ToString(); FailedCommand = $cmd }
            }
        }
        return [pscustomobject]@{ Passed = $true; Output = $allOutput.ToString(); FailedCommand = $null }
    }

    $bootCfg   = $Toolchain['boot']
    $qemuBin   = [string]$bootCfg['qemu_binary']
    $qemuArgs  = @($bootCfg['qemu_args'])
    $timeout   = [int]$bootCfg['timeout_seconds']
    if ($timeout -le 0) { $timeout = $QemuTimeoutSeconds }
    $expect    = $bootCfg['expect_serial']
    $required  = if ($expect -and $expect['required'])  { @($expect['required'])  } else { @() }
    $forbidden = if ($expect -and $expect['forbidden']) { @($expect['forbidden']) } else { @() }
    $artifact  = [string]$Toolchain['build']['artifact']

    $allOutput = [System.Text.StringBuilder]::new()

    # 1) Pre-boot lines: anything that's not the qemu binary and isn't an
    # `integration:` directive runs first.
    foreach ($cmd in $Commands) {
        if (-not $cmd) { continue }
        if ($cmd -match '\bqemu-system-[a-z0-9_]+\b') { continue }
        if ($cmd -match '^\s*integration:') { continue }
        [void]$allOutput.AppendLine("+ $cmd")
        $r = _Invoke-VerifyShellLine -Cmd $cmd
        [void]$allOutput.Append($r.Output)
        if ($r.ExitCode -ne 0) {
            return [pscustomobject]@{ Passed = $false; Output = $allOutput.ToString(); FailedCommand = $cmd }
        }
    }

    # 2) Truncate the serial log so we only see this run's output.
    $serialDir = Split-Path $SerialLogPath -Parent
    if ($serialDir -and -not (Test-Path $serialDir)) {
        New-Item -ItemType Directory -Path $serialDir -Force | Out-Null
    }
    Set-Content -Path $SerialLogPath -Value '' -Encoding utf8

    # 3) Substitute placeholders.
    $finalArgs = @()
    foreach ($a in $qemuArgs) {
        $sub = ([string]$a).Replace('{{ARTIFACT}}', $artifact).Replace('{{SERIAL_LOG}}', $SerialLogPath)
        $finalArgs += $sub
    }
    if ($QemuExtraArgs) {
        $finalArgs += ($QemuExtraArgs -split '\s+' | Where-Object { $_ })
    }

    [void]$allOutput.AppendLine("+ $qemuBin $($finalArgs -join ' ')   (timeout=${timeout}s)")

    # 4) Run qemu under a cross-platform timeout. On Windows, resolve a bare
    # 'bash' qemu_binary to $script:BashExe (Git Bash) so we don't accidentally
    # pick up the WSL bash on PATH, which mangles `file:C:\...` paths.
    $qemuExit = 0
    $timedOut = $false
    $resolvedQemuBin = $qemuBin
    if ($IsWindows -and $qemuBin -eq 'bash' -and $script:BashExe) {
        $resolvedQemuBin = $script:BashExe
    }
    if ($IsWindows) {
        try {
            $proc = Start-Process -FilePath $resolvedQemuBin -ArgumentList $finalArgs -NoNewWindow -PassThru
            if (-not $proc.WaitForExit($timeout * 1000)) {
                $timedOut = $true
                try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
                Start-Sleep -Milliseconds 250
            }
            $qemuExit = $proc.ExitCode
        } catch {
            return [pscustomobject]@{
                Passed = $false
                Output = "$($allOutput.ToString())qemu launch failed: $($_.Exception.Message)"
                FailedCommand = "$qemuBin $($finalArgs -join ' ')"
            }
        }
    } else {
        # POSIX: wrap with timeout(1). Use bash to handle quoting consistently.
        $quoted = ($finalArgs | ForEach-Object { "'" + ($_ -replace "'", "'\\''") + "'" }) -join ' '
        $shellLine = "timeout ${timeout}s $qemuBin $quoted"
        $r = _Invoke-VerifyShellLine -Cmd $shellLine
        $qemuExit = $r.ExitCode
        if ($qemuExit -eq 124) { $timedOut = $true }
    }
    [void]$allOutput.AppendLine("(qemu exit=$qemuExit$( if ($timedOut) { ' TIMEOUT' } else { '' } ))")

    # 5) Read the serial log.
    $serial = ''
    if (Test-Path $SerialLogPath) {
        $serial = [string](Get-Content -Path $SerialLogPath -Raw -ErrorAction SilentlyContinue)
    }
    [void]$allOutput.AppendLine("--- serial.log (last 40 lines) ---")
    $tail = (($serial -split "`r?`n") | Select-Object -Last 40) -join "`n"
    [void]$allOutput.AppendLine($tail)

    foreach ($p in $required) {
        if (-not $p) { continue }
        try { $matched = $serial -match $p } catch { $matched = $serial -match [regex]::Escape($p) }
        if (-not $matched) {
            return [pscustomobject]@{ Passed = $false; Output = $allOutput.ToString(); FailedCommand = "expect_serial.required: $p" }
        }
    }
    foreach ($p in $forbidden) {
        if (-not $p) { continue }
        try { $matched = $serial -match $p } catch { $matched = $serial -match [regex]::Escape($p) }
        if ($matched) {
            return [pscustomobject]@{ Passed = $false; Output = $allOutput.ToString(); FailedCommand = "expect_serial.forbidden: $p" }
        }
    }

    # 6) Optional integration commands after a successful boot.
    foreach ($cmd in $Commands) {
        if ($cmd -match '^\s*integration:\s*(.+)$') {
            $intCmd = $matches[1].Trim()
            [void]$allOutput.AppendLine("+ $intCmd  (integration)")
            $r = _Invoke-VerifyShellLine -Cmd $intCmd
            [void]$allOutput.Append($r.Output)
            if ($r.ExitCode -ne 0) {
                return [pscustomobject]@{ Passed = $false; Output = $allOutput.ToString(); FailedCommand = $intCmd }
            }
        }
    }

    return [pscustomobject]@{ Passed = $true; Output = $allOutput.ToString(); FailedCommand = $null }
}

function Test-VerifyBlog {
    # Blog verify: structural (frontmatter present + min wordcount) + run
    # any plan-supplied verify commands (typically markdownlint).
    param([string[]]$Commands, [string]$PostPath, [int]$MinWords = 400)
    if (-not $PostPath) {
        # Best-effort: extract a posts/<n>-<slug>.md path from the commands.
        foreach ($c in $Commands) {
            $m = [regex]::Match([string]$c, '(posts/\d+-[\w\-]+\.md)')
            if ($m.Success) {
                $PostPath = Join-Path $BlogRepoPath $m.Groups[1].Value
                break
            }
        }
    }
    if (-not $PostPath -or -not (Test-Path -LiteralPath $PostPath)) {
        return [pscustomobject]@{ Passed = $false; Output = "blog post not found: $PostPath"; FailedCommand = '<post path>' }
    }
    $body = [string](Get-Content -LiteralPath $PostPath -Raw)
    if ($body -notmatch '(?ms)\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n') {
        return [pscustomobject]@{ Passed = $false; Output = "post is missing YAML frontmatter (--- ... ---)"; FailedCommand = '<frontmatter>' }
    }
    $fm = $matches[1]
    if ($fm -notmatch '(?im)^\s*title\s*:') {
        return [pscustomobject]@{ Passed = $false; Output = "frontmatter missing 'title:' key"; FailedCommand = '<frontmatter>' }
    }
    if ($fm -notmatch '(?im)^\s*date\s*:') {
        return [pscustomobject]@{ Passed = $false; Output = "frontmatter missing 'date:' key"; FailedCommand = '<frontmatter>' }
    }
    $afterFm = $body -replace '(?ms)\A---\s*\r?\n.*?\r?\n---\s*\r?\n',''
    $words = ($afterFm -split '\s+' | Where-Object { $_ -ne '' }).Count
    if ($words -lt $MinWords) {
        return [pscustomobject]@{ Passed = $false; Output = "wordcount $words < min $MinWords"; FailedCommand = '<wordcount>' }
    }

    # Run plan-supplied verify commands (markdownlint, etc.).
    $allOutput = [System.Text.StringBuilder]::new()
    [void]$allOutput.AppendLine("post: $PostPath ($words words; frontmatter ok)")
    foreach ($cmd in $Commands) {
        if (-not $cmd) { continue }
        if ($cmd -match '^\s*integration:') { continue }
        [void]$allOutput.AppendLine("+ $cmd")
        $r = _Invoke-VerifyShellLine -Cmd $cmd
        [void]$allOutput.Append($r.Output)
        if ($r.ExitCode -ne 0) {
            return [pscustomobject]@{ Passed = $false; Output = $allOutput.ToString(); FailedCommand = $cmd }
        }
    }
    return [pscustomobject]@{ Passed = $true; Output = $allOutput.ToString(); FailedCommand = $null }
}

function Test-VerifyStatus {
    # Status digest verify: frontmatter + non-empty body (>= 50 words).
    # Lighter than blog verify; no markdownlint, no min-words gate.
    param([string[]]$Commands, [string]$PostPath)
    if (-not $PostPath) {
        foreach ($c in $Commands) {
            $m = [regex]::Match([string]$c, '(STATUS-[\w\-]+\.md)')
            if ($m.Success) {
                $PostPath = Join-Path $BlogRepoPath $m.Groups[1].Value
                break
            }
        }
    }
    if (-not $PostPath -or -not (Test-Path -LiteralPath $PostPath)) {
        return [pscustomobject]@{ Passed = $false; Output = "status doc not found: $PostPath"; FailedCommand = '<post path>' }
    }
    $body = [string](Get-Content -LiteralPath $PostPath -Raw)
    if ($body -notmatch '(?ms)\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n') {
        return [pscustomobject]@{ Passed = $false; Output = "status doc missing frontmatter"; FailedCommand = '<frontmatter>' }
    }
    $afterFm = $body -replace '(?ms)\A---\s*\r?\n.*?\r?\n---\s*\r?\n',''
    $words = ($afterFm -split '\s+' | Where-Object { $_ -ne '' }).Count
    if ($words -lt 50) {
        return [pscustomobject]@{ Passed = $false; Output = "status doc body too short ($words < 50 words)"; FailedCommand = '<wordcount>' }
    }
    return [pscustomobject]@{ Passed = $true; Output = "status ok ($words words)"; FailedCommand = $null }
}

function Test-Verify {
    # Dispatcher. -Kind selects the dialect:
    #   kernel   — Test-VerifyKernelBoot (QEMU + serial scrape)
    #   blog     — Test-VerifyBlog       (frontmatter + wordcount + cmds)
    #   status   — Test-VerifyStatus     (frontmatter + non-empty body)
    #   shell    — legacy literal shell-line behaviour (default)
    # The shell branch preserves the original semantics for any caller that
    # doesn't pass -Kind (notably: Test-PlanStaleness's default callsite
    # before Phase F plumbs item-kind through).
    param(
        [string[]]$Commands,
        [string]$Kind = 'shell',
        [hashtable]$Context = @{}
    )
    if (-not $Commands -or $Commands.Count -eq 0) {
        return [pscustomobject]@{ Passed = $true; Output = '(no verify commands)'; FailedCommand = $null }
    }
    switch ($Kind) {
        'kernel' { return (Test-VerifyKernelBoot -Commands $Commands -Toolchain $script:Toolchain -SkipBootReason ([string]$Context['SkipBoot'])) }
        'blog'   { return (Test-VerifyBlog       -Commands $Commands -PostPath $Context['PostPath'] -MinWords $BlogMinWords) }
        'status' { return (Test-VerifyStatus     -Commands $Commands -PostPath $Context['PostPath']) }
        default  {
            $allOutput = [System.Text.StringBuilder]::new()
            foreach ($cmd in $Commands) {
                [void]$allOutput.AppendLine("+ $cmd")
                $r = _Invoke-VerifyShellLine -Cmd $cmd
                [void]$allOutput.Append($r.Output)
                if ($r.ExitCode -ne 0) {
                    return [pscustomobject]@{ Passed = $false; Output = $allOutput.ToString(); FailedCommand = $cmd }
                }
            }
            return [pscustomobject]@{ Passed = $true; Output = $allOutput.ToString(); FailedCommand = $null }
        }
    }
}

# ---------------------------------------------------------------------------
# Verify-fail fingerprint circuit breaker (Upgrade 2)
# ---------------------------------------------------------------------------

function Get-VerifyFingerprint {
    # 8-char hex SHA1 of an aggressively-normalized Output. Real-world verify
    # output across items had identical root causes hashing differently
    # because of: per-item paths (slugs), changing line numbers, ctest
    # indices like "12/14 Test #1287:", per-run timestamps, hex object IDs.
    # Stripping all of those lets the consecutive_same counter actually fire
    # when the SAME bug repeats across items.
    param([string]$Output)
    if (-not $Output) { return '00000000' }
    $norm = $Output.ToLowerInvariant()
    # Absolute-ish paths (Windows + POSIX). Replace with a placeholder so two
    # items hitting the same "no such file" don't drift on different cwds.
    $norm = $norm -replace '[a-z]:[\\/][^\s:"`'']+', '<PATH>'
    $norm = $norm -replace '/(?:home|users|tmp|var|root|mnt)/[^\s:"`'']+', '<PATH>'
    # Build-output refs (with or without extension): "./build/tests/foo",
    # "build/Debug/bar.exe", "target/release/qux" -> <BIN_PATH>. Catches the
    # Windows-vs-Linux drift where the same target shows up at different
    # paths across items. Run BEFORE the file-extension regex so .exe under
    # build/ collapses to the same <BIN_PATH> as a no-extension binary.
    $norm = $norm -replace '\.?/?(?:build|target)/[^\s:"`'']+', '<BIN_PATH>'
    # File-relative refs that include a slug: build/foo-bar-baz.cpp -> build/<P>.<EXT>
    $norm = $norm -replace '([a-z0-9_/\\.-]+\.(cpp|h|hpp|rs|js|ts|tsx|py|go|c|cc|exe|dll|so|dylib|o|obj))', '<PATH>'
    # Line/column markers: "foo.rs:123:45", "line 88", ":44:"
    $norm = $norm -replace ':\d+(:\d+)?', ':<N>'
    $norm = $norm -replace '\bline\s+\d+\b', 'line <N>'
    # CTest indices: "12/14 Test #1287:", "Test #4 ...", " 1/12 Test"
    $norm = $norm -replace '\b\d+\s*/\s*\d+\s+test\b', '<X>/<Y> test'
    $norm = $norm -replace '\btest\s+#\d+\b', 'test #<N>'
    # ISO-ish timestamps + bare hex object IDs (commit shas, allocator ptrs).
    $norm = $norm -replace '\b\d{4}-\d{2}-\d{2}t\d{2}:\d{2}:\d{2}(\.\d+)?z?\b', '<TS>'
    $norm = $norm -replace '\b0x[0-9a-f]{4,}\b', '<HEX>'
    $norm = $norm -replace '\b[0-9a-f]{7,40}\b', '<HEX>'
    # Bare integers that are plausibly counts/sizes the next run won't repeat.
    $norm = $norm -replace '\b\d{3,}\b', '<N>'
    # Whitespace collapse last so all the placeholders above stay split.
    $norm = ($norm -replace '\s+', ' ').Trim()
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
    # NOTE: do NOT name a parameter `-Db` here. PowerShell auto-aliases
    # `-Debug` (a common parameter on advanced functions, which any function
    # with [Parameter(...)] attributes implicitly is) to its prefix, and the
    # runtime throws "parameter 'Db' cannot be specified because it conflicts
    # with the parameter alias of the same name for parameter 'Debug'" the
    # first time a caller writes `-Db $value`.
    param([Parameter(Mandatory)]$Registry)
    ($Registry | ConvertTo-Json -Depth 10) | Set-Content -Path $script:VerifyFailDb -Encoding utf8
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
    Save-VerifyFailDb -Registry $db

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
        Save-VerifyFailDb -Registry $db
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
        Parses needs-review.md into slug -> @{ Resolved, Resolutions[], Blockers[],
        Reason, FailureTail }. An item is "resolved" if every Blocker section under
        its slug has a non-empty Resolution: line. FailureTail captures the last
        ~40 lines of the Detail block (used by -RetryNeedsReview to seed the new
        phase-1 prompt with what went wrong last time).
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

        $reason = ([regex]::Match($sec, '(?im)^\s*-\s*Reason:\s*(.+)$')).Groups[1].Value.Trim()
        $detail = ''
        $dm = [regex]::Match($sec, '(?ms)^### Detail\s*\r?\n```\s*\r?\n(.*?)```')
        if ($dm.Success) {
            $detail = $dm.Groups[1].Value
            $detail = (($detail -split "`n" | Select-Object -Last 40) -join "`n").Trim()
        }

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
            Reason      = $reason
            FailureTail = $detail
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
    param(
        [string]$Slug, [string]$Summary, [string[]]$Assumptions,
        [string[]]$Forced, [string]$VerifyCmd, [string]$ExecutionNotes = '',
        [string]$ItemType = 'kernel'
    )
    $msg = [System.Text.StringBuilder]::new()
    if ($Summary) { [void]$msg.AppendLine($Summary) } else { [void]$msg.AppendLine("todo-runner: $Slug") }
    [void]$msg.AppendLine("")
    [void]$msg.AppendLine("Plan: $(Join-Path $script:PlansDir "$Slug.md")")
    if ($ItemType -and $ItemType -ne 'kernel') { [void]$msg.AppendLine("Type: $ItemType") }
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

    # Phase G — push blog/status deliverables to the sibling blog repo.
    # Kernel items are committed to the OS repo only; the runner does not
    # touch the blog repo for them.
    if ($ItemType -eq 'blog' -or $ItemType -eq 'status') {
        $bm = if ($Summary) { "$ItemType`: $Summary" } else { "$ItemType`: $Slug" }
        Push-BlogRepo -Path $BlogRepoPath -CommitMessage $bm | Out-Null
    }
    return $sha
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

function Get-PlanKind {
    # Reads the leading `# kind: kernel|blog|status` header from a plan
    # markdown blob (set by the new plan template). Falls back to 'shell'
    # for legacy or malformed plans so the verify dispatcher still works.
    param([string]$PlanText)
    if (-not $PlanText) { return 'shell' }
    $m = [regex]::Match($PlanText, '(?im)^\s*#\s*kind:\s*(kernel|blog|status)\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'shell'
}

function _Assign-BlogNumber {
    # Picks the next available <n> for a blog post under
    # $BlogRepoPath/$BlogPostsSubdir, accounting for files already on disk
    # AND numbers already assigned earlier in this run (via $script:BlogNumbers).
    # Idempotent per-slug: subsequent calls with the same slug return the
    # number cached from the first call, so PlanAllFirst (compute number at
    # plan time) and the per-item loop (use number at execute time) agree.
    param([Parameter(Mandatory)][string]$Slug)
    if (-not $script:BlogNumbers) { $script:BlogNumbers = @{} }
    if ($script:BlogNumbers.ContainsKey($Slug)) { return $script:BlogNumbers[$Slug] }
    $dir = Join-Path $BlogRepoPath $BlogPostsSubdir
    $max = 0
    if (Test-Path $dir) {
        foreach ($f in (Get-ChildItem -Path $dir -Filter '*.md' -ErrorAction SilentlyContinue)) {
            $m = [regex]::Match($f.Name, '^(\d+)-')
            if ($m.Success) {
                $n = [int]$m.Groups[1].Value
                if ($n -gt $max) { $max = $n }
            }
        }
    }
    foreach ($n in $script:BlogNumbers.Values) {
        if ($n -gt $max) { $max = $n }
    }
    $next = $max + 1
    $script:BlogNumbers[$Slug] = $next
    return $next
}

function _Get-ItemKind {
    # Resolves an item's kind, defaulting to 'kernel' if the marker is
    # missing or the field is unset (back-compat with pre-Phase-F items).
    param([object]$Item)
    if ($Item.PSObject.Properties.Name -contains 'Type' -and $Item.Type) { return [string]$Item.Type }
    return 'kernel'
}

function _Get-ItemPostPath {
    # Resolves the deliverable path for blog/status items so verify can
    # find the file. Returns empty string for kernel items.
    param([object]$Item, [string]$Kind)
    switch ($Kind) {
        'blog' {
            $n = _Assign-BlogNumber -Slug $Item.Slug
            return (Join-Path (Join-Path $BlogRepoPath $BlogPostsSubdir) "$n-$($Item.Slug).md")
        }
        'status' {
            $datestr = (Get-Date).ToString('yyyy-MM-dd')
            return (Join-Path $BlogRepoPath "STATUS-$datestr.md")
        }
        default { return '' }
    }
}

function Format-ToolchainContext {
    # Builds a short human-readable summary of the toolchain manifest for
    # injection into plan/execute prompts. Empty string if no toolchain.
    param($Toolchain)
    if (-not $Toolchain) { return '' }
    $p = $Toolchain['project']
    $b = $Toolchain['boot']
    $bld = $Toolchain['build']
    $required  = if ($b -and $b['expect_serial'] -and $b['expect_serial']['required'])  { ($b['expect_serial']['required']  -join ', ') } else { '' }
    $forbidden = if ($b -and $b['expect_serial'] -and $b['expect_serial']['forbidden']) { ($b['expect_serial']['forbidden'] -join ', ') } else { '' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("- arch: $($p['arch'])")
    [void]$sb.AppendLine("- lang: $($p['lang'])")
    [void]$sb.AppendLine("- bootloader: $($p['bootloader'])")
    if ($p['target_triple']) { [void]$sb.AppendLine("- target_triple: $($p['target_triple'])") }
    if ($bld -and $bld['command'])  { [void]$sb.AppendLine("- build command: $($bld['command'])") }
    if ($bld -and $bld['artifact']) { [void]$sb.AppendLine("- build artifact: $($bld['artifact'])") }
    if ($b   -and $b['qemu_binary']){ [void]$sb.AppendLine("- qemu binary: $($b['qemu_binary'])") }
    if ($required)  { [void]$sb.AppendLine("- expected serial signature(s): $required") }
    if ($forbidden) { [void]$sb.AppendLine("- forbidden serial pattern(s): $forbidden") }
    return $sb.ToString().TrimEnd()
}

function New-PlanPrompt {
    # Single-quoted here-strings + literal .Replace() so user item text and
    # plan/resolution content can contain backticks, dollar signs, or any other
    # PowerShell escape character without corrupting the prompt.
    param(
        [string]$ItemText, [string]$Slug, [string]$Resolutions,
        [string[]]$Subitems, [string[]]$SiblingSlugs,
        [string]$PreviousFailure, [string]$PreviousFailureReason,
        [string]$ItemType = 'kernel',
        [string]$ToolchainContext = ''
    )

    $resolutionBlock = ''
    if ($Resolutions) {
        $resolutionTemplate = @'

Previously blocked, now resolved:
{{R}}

Incorporate these answers into your plan. Do not re-emit blockers that were resolved.
'@
        $resolutionBlock = $resolutionTemplate.Replace('{{R}}', $Resolutions)
    }

    $substepsBlock = ''
    if ($Subitems -and $Subitems.Count -gt 0) {
        $bullets = ($Subitems | ForEach-Object { "  - $_" }) -join "`n"
        $substepsTemplate = @'

This item bundles {{N}} descriptive sub-step(s). Treat them as the spec for ONE plan whose execute phase implements them all in a single coherent commit. Do NOT propose separate plans/items for each sub-step:
{{B}}
'@
        $substepsBlock = $substepsTemplate.Replace('{{N}}', $Subitems.Count.ToString()).Replace('{{B}}', $bullets)
    }

    $siblingsBlock = ''
    if ($SiblingSlugs -and $SiblingSlugs.Count -gt 0) {
        $sib = ($SiblingSlugs | ForEach-Object { "  - $_" }) -join "`n"
        $siblingsTemplate = @'

Other pending items in this run (slugs only; for the optional Prereqs section):
{{S}}
'@
        $siblingsBlock = $siblingsTemplate.Replace('{{S}}', $sib)
    }

    $previousBlock = ''
    if ($PreviousFailure) {
        $previousTemplate = @'

PRIOR ATTEMPT FAILED. Reason: {{REASON}}
Previous failure tail (last ~40 lines of the failed run's Detail block):
```
{{TAIL}}
```
Take this into account when planning. If the prior failure was a verify-command issue (qemu not on path, missing artefact, wrong serial signature), pick a different verify form. If the prior failure was max-turns-exhausted, prefer a tighter, more targeted plan with fewer optional steps.

'@
        $previousBlock = $previousTemplate.
            Replace('{{REASON}}', ($PreviousFailureReason -as [string])).
            Replace('{{TAIL}}', $PreviousFailure)
    }

    # Phase F — toolchain context (the design pass spec, summarised). The
    # planner uses this to know what arch / what serial signature to target.
    $toolchainBlock = ''
    if ($ToolchainContext) {
        $toolchainTemplate = @'

TOOLCHAIN CONTEXT (from the design pass):
{{TC}}
'@
        $toolchainBlock = $toolchainTemplate.Replace('{{TC}}', $ToolchainContext)
    }

    # Phase F — kind-switched ALLOWED / FORBIDDEN block.
    $allowedForbidden = ''
    switch ($ItemType) {
        'kernel' {
            $allowedForbidden = @'
ALLOWED Verify commands (whitelist):
- `cargo {build,test,check,xtask,xrun}` (any subcommand/args; NOT `cargo run`)
- `make`, `cmake --build`, `ninja`, `zig build`
- `test -f / -d / -e <path>` -- existence checks for kernel artefacts
- `grep -q '<pattern>' ./.claude/todo-runner/serial.log` -- post-boot serial assertions
- `cksum <path> | grep -q <hex>` -- artefact checksum match
- `integration: <command>` -- runs through bash AFTER the runner's QEMU pass
  succeeds. Use this for host-side smoke tests that need a working kernel.

The runner BUILDS THE QEMU INVOCATION ITSELF from the toolchain manifest.
Do NOT include a `qemu-system-...` line in your Verify block. Just include
the build/preparation commands; the runner will append qemu, run it under
its configured timeout, and check the serial log for the toolchain's
required/forbidden signatures.

SETUP-ONLY KERNEL ITEMS (no bootable image yet):
If this item does NOT yet produce a kernel ELF/ISO that the QEMU pass can
boot (workspace init, linker script authoring, build-script setup, embedding
the limine binaries into the iso tree -- anything before milestone M1's
BOOT_HANDOFF lands), opt out of the QEMU pass by adding this directive on
LINE 2 of your reply, immediately after `# kind: kernel`:

  # skip-boot: <one-line reason>

When skip-boot is set, the runner runs your Verify commands literally and
skips QEMU. Pick verify commands that prove the deliverable: e.g.
`cargo check --target x86_64-unknown-none`, `test -f scripts/build-iso.sh`,
`grep -q "0xFFFFFFFF80000000" linker.ld`. Once any milestone-producing
item lands (M1 onwards), all later kernel items MUST drop skip-boot and
keep the QEMU verify.

FORBIDDEN -- the runner WILL reject the plan if any verify line matches:
- `grep`/`rg`/`ack` against TODO.md, todo.md, needs-review.md, HALT.md, or any `.claude/*` path (runner bookkeeping; drifts).
- Bare `qemu-system-*` lines (the runner wraps qemu itself; bare invocations have no timeout / -no-reboot guard).
- `cargo run`, `npm start`, `npm run dev`, `yarn start`, `yarn dev` (interactive; cargo xrun and xtask are fine).
- Nested `pwsh -Command "..."` inside a bash line -- the outer bash mangles the inner quoting.
'@
        }
        'blog' {
            $allowedForbidden = @'
ALLOWED Verify commands (whitelist):
- `markdownlint <postfile>` (skipped if markdownlint is not on PATH)
- `wc -w <postfile>` (informational; the runner enforces min wordcount independently)
- `grep -q '^---' <postfile>` (frontmatter sanity)
- `test -f <postfile>` (existence)

The runner ENFORCES STRUCTURAL CHECKS independently of your Verify block:
- frontmatter present (--- ... --- with title: and date: keys)
- body word count >= the configured min (default 400)
You do NOT need to write commands for those; just ensure the post is
well-formed and at the path the execute phase will create.

FORBIDDEN:
- Anything that touches the blog repo's .git directly -- the runner publishes.
- Running node/python/etc. servers; nested `pwsh -Command "..."`.
- `grep`/`rg`/`ack` against TODO.md, needs-review.md, HALT.md, `.claude/*`.
'@
        }
        'status' {
            $allowedForbidden = @'
ALLOWED Verify commands (whitelist):
- `test -f <statusfile>` (existence)
- `grep -q '^---' <statusfile>` (frontmatter sanity)

The runner CHECKS structural correctness (frontmatter + non-empty body)
independently. Most status digests are fired automatically by the runner's
per-N-items hook; explicit ones are rare and usually mark a milestone.

FORBIDDEN:
- Anything that touches the blog repo's git directly.
- `grep`/`rg`/`ack` against runner bookkeeping files.
- Nested `pwsh -Command "..."`.
'@
        }
    }

    $template = @'
You are planning ONE todo item in a larger automated run. You cannot ask questions -- this session has no user. You have read-only access (Read, Glob, Grep) for research; do not attempt to edit files or run shell commands.

OUTPUT FORMAT: respond with the plan markdown as your direct text reply. Do not call ExitPlanMode or any plan-saving tool -- the runner captures your reply text and saves it.

Item kind: {{ITEM_TYPE}}
Todo item: {{ITEM}}
Slug: {{SLUG}}
{{TOOLCHAIN_BLOCK}}{{SUBSTEPS_BLOCK}}{{SIBLINGS_BLOCK}}{{PREVIOUS_BLOCK}}{{RESOLUTIONS_BLOCK}}
Produce a plan in this exact structure. The FIRST line of your reply MUST be the kind header below; the runner reads it to dispatch the correct verify dialect. For kernel items that don't yet produce a bootable image, optionally add a `# skip-boot: <reason>` directive on line 2 (see SETUP-ONLY KERNEL ITEMS in the Verify rules below).

# kind: {{ITEM_TYPE}}

# Plan: {{SLUG}}

## Goal
<one sentence>

## Steps
1. ...

## Files
- path/to/file -- what changes

## Risks
- ...

## Prereqs
List slugs of other pending items (from the "Other pending items" list above) whose work this plan depends on -- e.g. they create a type/function/file this plan references. Use ONLY slugs from the provided list. If none, write exactly: `Prereqs: none`.

## Verify
```
<shell command 1>
<shell command 2>
```

{{ALLOWED_FORBIDDEN}}

Each command runs through `bash -c` (Git Bash on Windows; system bash on Linux/macOS). Exit code 0 = pass. Verify must check the deliverable; the runner manages todo.md / needs-review.md itself, do not test those.

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

    return $template.
        Replace('{{TOOLCHAIN_BLOCK}}',   $toolchainBlock).
        Replace('{{SUBSTEPS_BLOCK}}',    $substepsBlock).
        Replace('{{SIBLINGS_BLOCK}}',    $siblingsBlock).
        Replace('{{PREVIOUS_BLOCK}}',    $previousBlock).
        Replace('{{RESOLUTIONS_BLOCK}}', $resolutionBlock).
        Replace('{{ALLOWED_FORBIDDEN}}', $allowedForbidden).
        Replace('{{ITEM_TYPE}}',         $ItemType).
        Replace('{{SLUG}}',              $Slug).
        Replace('{{ITEM}}',              $ItemText)
}

function New-ExecutePrompt {
    # Single-quoted templates so plan text (markdown code fences, arbitrary
    # content) flows through literally. Kind-specific guidance is appended.
    param(
        [string]$PlanText, [string]$ForcedAssumptions,
        [string]$ItemType = 'kernel',
        [string]$ToolchainContext = '',
        [int]$BlogPostNumber = 0,
        [string]$BlogPostSlug = ''
    )

    $forcedBlock = ''
    if ($ForcedAssumptions) {
        $forcedTemplate = @'

FORCED ASSUMPTIONS (runner invoked with -ProceedOnBlockers; proceed using these):
{{F}}

'@
        $forcedBlock = $forcedTemplate.Replace('{{F}}', $ForcedAssumptions)
    }

    $tcBlock = ''
    if ($ToolchainContext) {
        $tcTemplate = @'

TOOLCHAIN CONTEXT:
{{TC}}

'@
        $tcBlock = $tcTemplate.Replace('{{TC}}', $ToolchainContext)
    }

    $kindSpecific = ''
    switch ($ItemType) {
        'kernel' {
            $kindSpecific = @'

KERNEL ITEM:
- Edit kernel source files per the plan's Steps.
- Stage changes (no `git commit` -- the runner commits).
- The runner will rebuild + boot under QEMU and scrape the serial log. Make
  sure your changes preserve the toolchain's required serial signature and
  do not introduce any forbidden patterns (PANIC / DOUBLE FAULT / etc.).
'@
        }
        'blog' {
            $blogTarget = if ($BlogPostNumber -gt 0 -and $BlogPostSlug) { "$BlogRepoPath/$BlogPostsSubdir/$BlogPostNumber-$BlogPostSlug.md" } else { "$BlogRepoPath/$BlogPostsSubdir/<n>-<slug>.md (pre-computed by runner; passed via plan)" }
            $kindSpecific = @"

BLOG POST ITEM:
- Write a markdown post at: $blogTarget
- The post MUST start with YAML frontmatter:
    ---
    title: "..."
    date: "<today, yyyy-mm-dd>"
    tags: [os, ...]
    ---
- Body must be >= $BlogMinWords words. Aim for substance: explain the design
  choice, what surprised you, what changed in the kernel, what's next.
- Do NOT run ``git`` inside the blog repo -- the runner handles publishing.
- The post number and slug are pre-computed by the runner; use the path above.
"@
        }
        'status' {
            $kindSpecific = @"

STATUS DIGEST ITEM:
- Write the status doc to $BlogRepoPath/STATUS-<yyyy-MM-dd>.md (pick today's date).
- Frontmatter required (title:, date:); body summarises recent work in plain
  language. >= 50 words.
- Do NOT run ``git`` inside the blog repo -- the runner handles publishing.
"@
        }
    }

    $template = @'
Execute this plan exactly. The session has no user; you cannot ask questions.
{{TC_BLOCK}}{{FORCED_BLOCK}}
{{PLAN}}
{{KIND_SPECIFIC}}

Rules (apply to all item kinds):
1. Make the code/content changes per the plan's Steps.
2. If the plan is ambiguous, pick the most conservative interpretation and record your choice in an "EXECUTION NOTES:" block at the end of your reply.
3. Run the Verify commands and report their output.
4. Do NOT run `git commit`. Leave changes staged. The runner commits.
5. Do NOT edit todo.md. The runner marks it.
6. End your reply with "EXECUTION NOTES:" listing any conservative interpretations you made.
'@

    return $template.
        Replace('{{TC_BLOCK}}',      $tcBlock).
        Replace('{{FORCED_BLOCK}}',  $forcedBlock).
        Replace('{{KIND_SPECIFIC}}', $kindSpecific).
        Replace('{{PLAN}}',          $PlanText)
}

# ---------------------------------------------------------------------------
# Main per-item functions
# ---------------------------------------------------------------------------

function Invoke-Phase1 {
    param(
        [string]$ItemText, [string]$Slug, [string]$Resolutions,
        [string[]]$Subitems, [string[]]$SiblingSlugs,
        [string]$PreviousFailure, [string]$PreviousFailureReason,
        [string]$ItemType = 'kernel',
        [string]$ToolchainContext = '',
        [hashtable]$VerifyContext = @{}
    )
    $planPath = Join-Path $script:PlansDir "$Slug.md"

    if ($SkipPlan -and (Test-Path $planPath) -and -not $Resolutions) {
        $cachedPlan = Read-Plan $planPath
        $grammar = Test-PlanVerifyGrammar -Verify $cachedPlan.Verify
        $sanity = if ($grammar.Passed) { Test-VerifySanity -Verify $cachedPlan.Verify } else { [pscustomobject]@{ Passed = $true } }
        if (-not $grammar.Passed) {
            Write-Info2 "  cached plan has forbidden verify command ($($grammar.FirstOffender)) -- discarding"
            Remove-Item -Path $planPath -Force -ErrorAction SilentlyContinue
        } elseif (-not $sanity.Passed) {
            Write-Info2 "  cached plan has insane verify ref ($($sanity.Reason)) -- discarding"
            Remove-Item -Path $planPath -Force -ErrorAction SilentlyContinue
        } else {
            # Phase F: dispatch the staleness check using the item's kind
            # so kernel items are checked by booting under QEMU (not just
            # running shell verify lines).
            $stale = Test-PlanStaleness -Plan $cachedPlan -Slug $Slug -Kind $ItemType -Context $VerifyContext
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

    Write-Phase "plan  $Slug ($ItemType)"
    $prompt = New-PlanPrompt -ItemText $ItemText -Slug $Slug -Resolutions $Resolutions `
        -Subitems $Subitems -SiblingSlugs $SiblingSlugs `
        -PreviousFailure $PreviousFailure -PreviousFailureReason $PreviousFailureReason `
        -ItemType $ItemType -ToolchainContext $ToolchainContext
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

    # Upgrade 10 — sanity-check verify references against the actual tree.
    $sanity = Test-VerifySanity -Verify $parsed.Verify
    if (-not $sanity.Passed) {
        Write-Review "  plan rejected: insane verify ref -> $($sanity.FirstOffender)"
        Write-Info2  "    reason: $($sanity.Reason)"
        return [pscustomobject]@{
            PlanPath          = $planPath
            Cost              = $cost
            Mode              = 'error'
            Blockers          = @()
            FailureMode       = 'plan-validation-failed'
            Raw               = $r
            ValidationOffender = "$($sanity.FirstOffender) -- $($sanity.Reason)"
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
    param(
        [string]$Slug, [string]$PlanPath, [string[]]$ForcedAssumptions,
        [decimal]$PlanCost, [string]$ItemText = '',
        [int]$MaxTurnsBoost = 1, [int]$CostCeilingBoost = 1,
        [string]$ItemType = 'kernel',
        [string]$ToolchainContext = '',
        [int]$BlogPostNumber = 0,
        [string]$BlogPostSlug = ''
    )
    Write-Phase "exec  $Slug ($ItemType)"
    $planText = Get-Content -Path $PlanPath -Raw
    $parsed   = Read-Plan $PlanPath

    $forcedBlock = ($ForcedAssumptions -join "`n")
    $prompt = New-ExecutePrompt -PlanText $planText -ForcedAssumptions $forcedBlock `
        -ItemType $ItemType -ToolchainContext $ToolchainContext `
        -BlogPostNumber $BlogPostNumber -BlogPostSlug $BlogPostSlug

    # Phase-2 invocation with auto-retry on max-turns-exhausted.
    # First attempt uses $MaxTurns * $MaxTurnsBoost; if the CLI reports
    # subtype=error_max_turns (the agent did real work but ran out of
    # turns), we retry once with the boosted budget * $MaxTurnsRetryMultiplier.
    # The retry is a fresh session — no context shared from attempt 1 — so
    # the plan must be self-contained, but the agent restarts cleanly with
    # a bigger budget.
    $execTurns = $MaxTurns * $MaxTurnsBoost
    $r = Invoke-Claude -Prompt $prompt -Mode 'auto' -AllowedTools 'Read,Edit,Write,Bash,Glob,Grep' -MaxTurns $execTurns

    $failure = if ($r.ExitCode -ne 0 -or -not $r.Json) { 'infra-error' } else { Get-FailureMode -Result $r }
    $tx = Write-Transcript -Slug $Slug -Phase 'execute' -InvocationResult $r -FailureMode $failure
    Add-RunLog -Phase 'execute' -Slug $Slug -InvocationResult $r -Extra @{
        plan_cost_usd   = [double]$PlanCost
        item_text       = $ItemText
        failure_mode    = $failure
        transcript_path = $tx
        max_turns       = $execTurns
    }
    Write-Info2 "  exec: $($r.WallSeconds)s, failure_mode=$failure, transcript=$tx"

    $retryCost = [decimal]0
    if ($failure -eq 'max-turns-exhausted' -and $MaxTurnsRetryMultiplier -gt 1) {
        $retryTurns = $MaxTurns * $MaxTurnsRetryMultiplier
        Write-Review "  max-turns hit at $execTurns; retrying once with $retryTurns turns"
        $rRetry = Invoke-Claude -Prompt $prompt -Mode 'auto' -AllowedTools 'Read,Edit,Write,Bash,Glob,Grep' -MaxTurns $retryTurns
        $retryFailure = if ($rRetry.ExitCode -ne 0 -or -not $rRetry.Json) { 'infra-error' } else { Get-FailureMode -Result $rRetry }
        $txRetry = Write-Transcript -Slug $Slug -Phase 'execute' -InvocationResult $rRetry -FailureMode $retryFailure
        Add-RunLog -Phase 'execute-retry' -Slug $Slug -InvocationResult $rRetry -Extra @{
            plan_cost_usd       = [double]$PlanCost
            item_text           = $ItemText
            failure_mode        = $retryFailure
            transcript_path     = $txRetry
            max_turns           = $retryTurns
            previous_attempt    = 'max-turns-exhausted'
        }
        Write-Info2 "  exec-retry: $($rRetry.WallSeconds)s, failure_mode=$retryFailure, transcript=$txRetry"
        $retryCost = [decimal]($rRetry.Json.total_cost_usd ?? 0)
        # Replace the working result with the retry; cost from attempt 1 is
        # still counted toward the cost ceiling below.
        $r       = $rRetry
        $failure = $retryFailure
    }

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

    $execCost = [decimal]($r.Json.total_cost_usd ?? 0) + $retryCost
    $total    = $PlanCost + $execCost

    $effectiveCeiling = $CostCeilingPerItem * $CostCeilingBoost
    $overCeiling = $total -ge $effectiveCeiling

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
# Mode subcommands (design / roadmap / digest)
# ---------------------------------------------------------------------------

function Push-BlogRepo {
    # Stage + commit + push the blog repo. Adds only ./posts and any
    # STATUS-*.md at the repo root (never the .git dir or unrelated files).
    # Tolerates "nothing to commit" and "no remote configured". Returns
    # $true on success (including no-op), $false on commit/push failure.
    param([Parameter(Mandatory)][string]$Path, [string]$CommitMessage = 'blog: update')
    if (-not (Test-Path $Path)) {
        Write-Verbose "Push-BlogRepo: blog repo path '$Path' does not exist; skipping"
        return $false
    }
    Push-Location $Path
    try {
        $paths = @()
        if (Test-Path './posts') { $paths += './posts' }
        foreach ($f in (Get-ChildItem -Path '.' -Filter 'STATUS-*.md' -ErrorAction SilentlyContinue)) {
            $paths += $f.Name
        }
        if ($paths.Count -eq 0) {
            Write-Verbose "Push-BlogRepo: no posts/ or STATUS-*.md to add"
            return $true
        }
        & git add @paths 2>&1 | Out-Null
        $status = (& git status --porcelain) -join "`n"
        if (-not $status.Trim()) {
            Write-Verbose "Push-BlogRepo: nothing to commit"
            return $true
        }
        $msgFile = New-TemporaryFile
        try {
            $CommitMessage | Set-Content -Path $msgFile -Encoding utf8 -NoNewline
            & git commit -F $msgFile.FullName 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Push-BlogRepo: git commit failed (exit $LASTEXITCODE)"
                return $false
            }
        } finally {
            Remove-Item -Path $msgFile.FullName -ErrorAction SilentlyContinue
        }
        $remotes = (& git remote 2>&1) -join "`n"
        if ($remotes.Trim()) {
            & git push 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Push-BlogRepo: git push failed (exit $LASTEXITCODE); commit landed locally"
            }
        } else {
            Write-Verbose "Push-BlogRepo: no remote configured; committed locally only"
        }
        return $true
    } finally {
        Pop-Location
    }
}

function Invoke-StatusDigest {
    # Fires a separate low-budget Claude session that drafts STATUS-<date>.md
    # in the blog repo from the tail of runs.jsonl + recent commit subjects.
    # No verify gate beyond the light Test-VerifyStatus structural check.
    # Failures are warnings, never halts — the digest is observability, not
    # blocking work.
    param([int]$ItemsCompletedSinceLast = 0)
    $datestr    = (Get-Date).ToString('yyyy-MM-dd')
    $statusPath = Join-Path $BlogRepoPath "STATUS-$datestr.md"

    $runsTail = ''
    if (Test-Path $script:RunsLog) {
        $allLines = Get-Content -Path $script:RunsLog -Tail 200 -ErrorAction SilentlyContinue
        if ($allLines) { $runsTail = ($allLines -join "`n") }
    }
    $gitLog = (& git log -n 20 --pretty=format:'%h %s' 2>&1 | Out-String).TrimEnd()

    $promptTemplate = @'
You are writing a one-page status digest for an autonomous OS-build run.

Recent runs.jsonl (last 200 lines, one JSON per line, newest at the bottom).
Each entry has fields like phase, slug, exit_code, total_cost_usd, num_turns,
is_error, subtype:
```
{{RUNS}}
```

Last 20 git commits in the OS repo (newest first):
```
{{GIT}}
```

Items completed since the last digest: {{N}}.

Write the digest to: {{TARGET}}

The file MUST start with YAML frontmatter:

---
title: "Status digest -- {{DATE}}"
date: "{{DATE}}"
tags: [status, os]
---

Then >= 50 words of body, in prose (NOT a checklist), covering:
  - What got done -- call out interesting milestones; cite specific slugs.
  - What broke -- anything routed to needs-review.md or rolled back.
  - What's next -- one or two sentences on the kinds of items still queued.

Keep it readable; this is for a human reader who skipped the run. No robot
dumps of raw JSON or commit hashes; cite slugs in the prose.

When the file is written, end your reply with:
  STATUS_DONE
or, if you cannot proceed:
  STATUS_BLOCKED: <one-line reason>
'@
    $prompt = $promptTemplate.
        Replace('{{RUNS}}',   $runsTail).
        Replace('{{GIT}}',    $gitLog).
        Replace('{{N}}',      "$ItemsCompletedSinceLast").
        Replace('{{TARGET}}', $statusPath).
        Replace('{{DATE}}',   $datestr)

    if (-not (Test-Path $BlogRepoPath)) {
        Write-Warning "status digest: blog repo not at '$BlogRepoPath'; skipping"
        return $false
    }

    Write-Phase "status digest -> $(Split-Path $statusPath -Leaf)"
    $r = Invoke-Claude -Prompt $prompt -Mode 'auto' `
        -AllowedTools 'Read,Edit,Write,Bash,Glob,Grep' -MaxTurns 20
    Write-Transcript -Slug '__status__' -Phase 'plan' -InvocationResult $r | Out-Null
    Add-RunLog -Phase 'status-digest' -Slug '__status__' -InvocationResult $r -Extra @{
        target           = $statusPath
        items_since_last = $ItemsCompletedSinceLast
    }

    if ($r.ExitCode -ne 0 -or -not $r.Json) {
        Write-Warning "status digest: claude exited $($r.ExitCode); skipping"
        return $false
    }
    $reply = [string]$r.Json.result
    if ($reply -notmatch '(?im)^STATUS_DONE\s*$') {
        Write-Warning "status digest did not declare STATUS_DONE; skipping"
        return $false
    }
    if (-not (Test-Path $statusPath)) {
        Write-Warning "status digest claimed DONE but $statusPath was not written"
        return $false
    }
    $v = Test-VerifyStatus -Commands @() -PostPath $statusPath
    if (-not $v.Passed) {
        Write-Warning "status digest verify failed: $($v.FailedCommand)"
        return $false
    }
    Push-BlogRepo -Path $BlogRepoPath -CommitMessage "status: digest $datestr" | Out-Null
    Write-Ok "  status digest committed to blog repo"
    return $true
}

function _MaybeFireStatusDigest {
    # Per-N-items cadence trigger. Increment the counter; if it's reached
    # the threshold, fire Invoke-StatusDigest and reset. Skip if the user
    # disabled digests or the blog repo isn't present (digest still works
    # if it exists, even without a remote — Push-BlogRepo tolerates that).
    if ($DisableStatusDigest) { return }
    if (-not $BlogRepoPath -or -not (Test-Path $BlogRepoPath)) {
        Write-Verbose "_MaybeFireStatusDigest: blog repo not at '$BlogRepoPath'; skipping cadence"
        return
    }
    $script:ItemsSinceDigest++
    if ($script:ItemsSinceDigest -lt $StatusEveryN) { return }
    $n = $script:ItemsSinceDigest
    $script:ItemsSinceDigest = 0
    Invoke-StatusDigest -ItemsCompletedSinceLast $n | Out-Null
}

function Invoke-DesignPass {
    # Mode=design. Single Claude session that produces:
    #   $DesignSpecPath  — markdown design doc (rationale, arch, milestones)
    #   $ToolchainConfig — block-style YAML manifest the runner consumes
    # Returns 0 on success, non-zero on any failure (with HALT message).
    Write-Phase "design pass: producing $(Split-Path $DesignSpecPath -Leaf) + $(Split-Path $ToolchainConfig -Leaf)"

    foreach ($p in @($DesignSpecPath, $ToolchainConfig)) {
        if (Test-Path $p) {
            $backup = "$p.bak-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmss'))"
            Move-Item -Path $p -Destination $backup -Force
            Write-Info2 "  backed up $(Split-Path $p -Leaf) -> $(Split-Path $backup -Leaf)"
        }
    }

    $promptTemplate = @'
You are an OS architect designing an operating system from scratch. Your job
is to make the foundational design decisions and hand the implementation team
a complete spec + toolchain manifest they can build against autonomously.

You have full latitude over:
  - Target architecture (x86_64, aarch64, riscv64, ...)
  - Implementation language (Rust no_std is the natural 2026 choice for a
    new OS, but you may pick something else if you have a strong reason)
  - Bootloader (limine, multiboot2, GRUB, custom)
  - Kernel architecture (monolithic, microkernel, hybrid)
  - Userspace ABI / first-filesystem / userspace init story for v1

Deliverables — write each file directly with the Write tool:

(1) {{SPEC_PATH}} — markdown design document. Required sections:
      # OS Design v1
      ## Rationale (why this OS at all)
      ## Architecture choice (with reasoning + alternatives considered)
      ## Language choice (with reasoning)
      ## Bootloader choice (with reasoning)
      ## Memory layout (kernel base, higher-half y/n, heap region, etc.)
      ## v1 milestones (numbered list, each one a self-contained, verifiable
         step. Roughly: bootloader handoff -> serial output -> GDT/IDT ->
         paging -> physical frame allocator -> heap -> simple scheduler ->
         first task -> system calls -> ramdisk init.)
      ## Open questions
      ## Out of scope for v1 (network stack, USB, full POSIX, GUI, ...)

(2) {{TOOLCHAIN_PATH}} — YAML manifest in BLOCK STYLE ONLY. The runner's
    parser is intentionally minimal: NO flow-style. No `[a, b, c]`. No
    `{k: v}`. All lists are `- item`. All maps are nested via 2-space
    indentation. Strings are "double-quoted". Schema:

```
project:
  name: "<short slug, lowercase, dashes ok>"
  arch: "<x86_64|aarch64|riscv64|...>"     # required, lowercase, [a-z0-9_]+
  lang: "<rust|zig|c|...>"
  bootloader: "<limine|multiboot2|...>"
  target_triple: "<rustc target triple, or empty for non-rust>"

required_tools:
  - name: "<binary name>"
    probe_command: "<one-line shell command that prints version>"
    version_regex: "<regex with one capture group for version>"
    min_version: "<semver string or empty>"
    install_hints:
      windows: "<install command for windows>"
      linux: "<install command for linux>"
      mac: "<install command for mac>"
    warn_only: false      # true if optional / fragile probe

build:
  command:  "<one-line shell to build the kernel artifact>"
  artifact: "<path to ELF or kernel image, repo-relative>"
  iso_command: ""         # optional; empty if no iso step

boot:
  qemu_binary: "<qemu-system-<arch>>"
  qemu_args:              # MUST contain {{ARTIFACT}} and {{SERIAL_LOG}}
    - "-machine"
    - "<machine type>"
    - "-kernel"
    - "{{ARTIFACT}}"
    - "-nographic"
    - "-serial"
    - "file:{{SERIAL_LOG}}"
    - "-no-reboot"
    - "-no-shutdown"
  timeout_seconds: 60
  expect_serial:
    required:
      - "<exact line the kernel must print on success, e.g. BOOT_OK>"
    forbidden:
      - "PANIC"
      - "DOUBLE FAULT"

blog:
  repo_path:    "../os-blog"
  posts_subdir: "posts"
  min_words:    400
```

When BOTH files are written and present on disk, end your reply with this
exact line on its own:

  DESIGN_DONE

If you cannot complete the design (genuine ambiguity, missing constraint),
write nothing to disk and end with:

  DESIGN_BLOCKED: <one-line reason>
'@
    $prompt = $promptTemplate.
        Replace('{{SPEC_PATH}}',      $DesignSpecPath).
        Replace('{{TOOLCHAIN_PATH}}', $ToolchainConfig)

    $r = Invoke-Claude -Prompt $prompt -Mode 'auto' `
        -AllowedTools 'Read,Edit,Write,Glob,Grep,Bash' -MaxTurns ($MaxTurns * 2)
    Write-Transcript -Slug '__design__' -Phase 'plan' -InvocationResult $r | Out-Null
    Add-RunLog -Phase 'design' -Slug '__design__' -InvocationResult $r -Extra @{
        spec_path      = $DesignSpecPath
        toolchain_path = $ToolchainConfig
    }

    if ($r.ExitCode -ne 0 -or -not $r.Json) {
        Write-Halt "design pass: claude exited $($r.ExitCode); see transcript"
        return 1
    }
    $reply = [string]$r.Json.result
    if ($reply -match '(?im)^DESIGN_BLOCKED:\s*(.+)$') {
        Write-Halt "design pass blocked: $($matches[1])"
        return 2
    }
    if ($reply -notmatch '(?im)^DESIGN_DONE\s*$') {
        Write-Halt "design pass did not declare DESIGN_DONE; see transcript"
        return 3
    }
    if (-not (Test-Path $DesignSpecPath))  { Write-Halt "DESIGN_DONE claimed but $DesignSpecPath missing"; return 4 }
    if (-not (Test-Path $ToolchainConfig)) { Write-Halt "DESIGN_DONE claimed but $ToolchainConfig missing"; return 4 }
    try {
        $tc = Read-ToolchainConfig -Path $ToolchainConfig
    } catch {
        Write-Halt "design pass produced invalid toolchain manifest: $($_.Exception.Message)"
        return 5
    }
    Write-Ok "design complete: $($tc['project']['name']) ($($tc['project']['arch']), $($tc['project']['lang']))"
    Write-Ok "  spec:      $DesignSpecPath"
    Write-Ok "  toolchain: $ToolchainConfig"
    Write-Ok "Next: review/edit the two files, then run -Mode roadmap to generate todo.md."
    return 0
}

function Invoke-GenerateRoadmap {
    # Mode=roadmap. Reads $DesignSpecPath + $ToolchainConfig and emits
    # $TodoFile populated with kernel + blog + status items, each marked
    # with <!-- type: ... -->. Backs up any existing todo.md.
    Write-Phase "roadmap: generating $(Split-Path $TodoFile -Leaf) from design spec"

    if (-not (Test-Path $DesignSpecPath))  { Write-Halt "design spec not found at $DesignSpecPath; run -Mode design first"; return 1 }
    if (-not (Test-Path $ToolchainConfig)) { Write-Halt "toolchain manifest not found at $ToolchainConfig; run -Mode design first"; return 1 }

    if (Test-Path $TodoFile) {
        $backup = "$TodoFile.bak-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmss'))"
        Move-Item -Path $TodoFile -Destination $backup -Force
        Write-Info2 "  backed up existing $(Split-Path $TodoFile -Leaf) -> $(Split-Path $backup -Leaf)"
    }

    $promptTemplate = @'
You are turning a finished OS design spec into an actionable roadmap that
the autonomous runner will work through.

Read these two files first using the Read tool:
  - {{SPEC_PATH}}      (the design doc — milestones live in there)
  - {{TOOLCHAIN_PATH}} (the manifest — references "BOOT_OK" or whatever the
                        kernel prints on success; cite this in kernel items)

Then write {{TODO_PATH}} as a flat checkbox markdown list. Grammar (strict):

  - [ ] <one-line item description>
    <!-- type: kernel|blog|status -->

The marker can also trail the checkbox on the same line:

  - [ ] Some item  <!-- type: blog -->

Rules:

  1. Every item MUST have a <!-- type: ... --> marker. Allowed values:
     kernel, blog, status. (Default kernel only if you are certain it is.)

  2. Order items by dependency. If item B needs item A's deliverable, A
     goes first. The runner topo-sorts but cannot recover from cycles.

  3. One concept per item. No compound items. Examples of correct
     granularity:
       BAD:  - [ ] Implement paging
       GOOD: - [ ] Identity-map the first 1 GiB in the bootloader
             - [ ] Switch to higher-half kernel mapping
             - [ ] Enable the write-protect bit and zero-fault-on-write

  4. Item types:
       kernel — a self-contained kernel deliverable verifiable by booting
                under QEMU and scraping the serial output.
       blog   — a markdown post in ../os-blog/posts/<n>-<slug>.md, >= 400
                words. Explain a feature you just shipped.
       status — a STATUS-<date>.md digest. Usually leave these to the
                automatic per-N-items hook; only emit explicit ones for
                milestone summaries (end of memory, end of scheduler, etc.)

  5. Interleave kernel + blog so blog posts can explain newly-landed
     features. Suggested cadence: 1 blog item per 3-5 kernel items.

  6. Aim for 30-80 items total for a v1 roadmap (bootloader + memory +
     basic scheduling + first userspace task + one filesystem). Don't try
     to finish a full POSIX OS in one roadmap.

When the file is written, end your reply with:

  ROADMAP_DONE

or, if you cannot proceed:

  ROADMAP_BLOCKED: <one-line reason>
'@
    $prompt = $promptTemplate.
        Replace('{{SPEC_PATH}}',      $DesignSpecPath).
        Replace('{{TOOLCHAIN_PATH}}', $ToolchainConfig).
        Replace('{{TODO_PATH}}',      $TodoFile)

    $r = Invoke-Claude -Prompt $prompt -Mode 'auto' `
        -AllowedTools 'Read,Edit,Write,Glob,Grep' -MaxTurns $MaxTurns
    Write-Transcript -Slug '__roadmap__' -Phase 'plan' -InvocationResult $r | Out-Null
    Add-RunLog -Phase 'roadmap' -Slug '__roadmap__' -InvocationResult $r -Extra @{ todo_path = $TodoFile }

    if ($r.ExitCode -ne 0 -or -not $r.Json) {
        Write-Halt "roadmap: claude exited $($r.ExitCode); see transcript"
        return 1
    }
    $reply = [string]$r.Json.result
    if ($reply -match '(?im)^ROADMAP_BLOCKED:\s*(.+)$') {
        Write-Halt "roadmap blocked: $($matches[1])"
        return 2
    }
    if ($reply -notmatch '(?im)^ROADMAP_DONE\s*$') {
        Write-Halt "roadmap did not declare ROADMAP_DONE; see transcript"
        return 3
    }
    if (-not (Test-Path $TodoFile)) {
        Write-Halt "ROADMAP_DONE claimed but $TodoFile missing"
        return 4
    }
    $items = Get-TodoItems -Path $TodoFile
    if (-not $items -or $items.Count -eq 0) {
        Write-Halt "roadmap produced an empty $TodoFile"
        return 5
    }
    # Type-aware breakdown only meaningful after Phase F. If items lack a
    # Type field, all three counts will be 0; that is non-fatal.
    $kernel = @($items | Where-Object { $_.Type -eq 'kernel' }).Count
    $blog   = @($items | Where-Object { $_.Type -eq 'blog'   }).Count
    $status = @($items | Where-Object { $_.Type -eq 'status' }).Count
    Write-Ok "roadmap complete: $($items.Count) items ($kernel kernel, $blog blog, $status status)"
    Write-Ok "  todo: $TodoFile"
    Write-Ok "Next: review todo.md, then run with no -Mode (defaults to build) to start."
    return 0
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

function Invoke-Main {
    $items = Get-TodoItems -Path $TodoFile
    if (-not $items) { Write-Ok "No todo items found. Nothing to do."; return 0 }

    $reviewed = Get-ReviewedItems -Path $NeedsReviewFile

    $iterations     = 0
    $consecClass    = 0
    $completedSlugs = New-Object System.Collections.Generic.HashSet[string]
    $planCache      = @{}  # slug -> Phase1 result (for PlanAllFirst)
    $script:RetryContext = @{}

    # Phase F — pre-format the toolchain context block once; every plan and
    # execute prompt for kernel items splices it in. Phase G — initialise
    # the blog-number cache and the items-since-digest counter.
    $script:ToolchainContextStr = Format-ToolchainContext -Toolchain $script:Toolchain
    $script:BlogNumbers         = @{}
    $script:ItemsSinceDigest    = 0

    # ---------------- Pre-flight: eligible items ----------------
    $eligible = @()
    foreach ($it in $items) {
        if ($it.Checked) { continue }

        $reviewInfo = $reviewed[$it.Slug]
        if ($reviewInfo) {
            if ($RetryNeedsReview) {
                Write-Info2 "  [$($it.Slug)] in needs-review; -RetryNeedsReview re-queuing with bumped budgets"
                # Force a fresh plan: discard the cached one so phase 1 re-plans
                # with the previous-failure context injected into the prompt.
                $stalePlan = Join-Path $script:PlansDir "$($it.Slug).md"
                if (Test-Path $stalePlan) { Remove-Item -Path $stalePlan -Force -ErrorAction SilentlyContinue }
                $script:RetryContext[$it.Slug] = @{
                    PreviousFailure       = $reviewInfo.FailureTail
                    PreviousFailureReason = $reviewInfo.Reason
                    MaxTurnsBoost         = 2
                    CostCeilingBoost      = 2
                }
            } elseif ($reviewInfo.Resolved) {
                Write-Info2 "  [$($it.Slug)] resolutions present; re-queuing"
            } elseif ($SkipPlan) {
                Write-Info2 "  [$($it.Slug)] in needs-review but -SkipPlan: re-queuing"
            } else {
                Write-Review "  [$($it.Slug)] skipping: in needs-review.md with unresolved blockers"
                continue
            }
        }

        $blockingSlug = Get-ItemBlockedBy -ItemText $it.Text
        if ($blockingSlug -and -not $RetryNeedsReview) {
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
            $siblingSlugs = @($eligible | Where-Object { $_.Slug -ne $it.Slug } | ForEach-Object { $_.Slug })
            $rc = $script:RetryContext[$it.Slug]
            $prevFail   = if ($rc) { [string]$rc.PreviousFailure } else { '' }
            $prevReason = if ($rc) { [string]$rc.PreviousFailureReason } else { '' }
            $itemKind     = _Get-ItemKind -Item $it
            $itemPostPath = _Get-ItemPostPath -Item $it -Kind $itemKind
            $verifyCtx    = @{ PostPath = $itemPostPath }
            $p1 = Invoke-Phase1 -ItemText $it.Text -Slug $it.Slug -Resolutions $resolutionText -Subitems $it.Subitems -SiblingSlugs $siblingSlugs -PreviousFailure $prevFail -PreviousFailureReason $prevReason -ItemType $itemKind -ToolchainContext $script:ToolchainContextStr -VerifyContext $verifyCtx
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
                    -ExecutionNotes 'No execute phase ran. The cached plan''s verify gate already passes against the current tree.' `
                    -ItemType $itemKind
                Remove-BlockerRegistry -Slug $it.Slug
                $null = $completedSlugs.Add($it.Slug)
                Add-RunLog -Phase 'already-done' -Slug $it.Slug -InvocationResult ([pscustomobject]@{ExitCode=0;Json=$null}) -Extra @{
                    item_text    = $it.Text
                    mode         = 'already-done'
                    failure_mode = 'success'
                }
                Write-Ok "  [$($it.Slug)] already-done (verify already passes); committed $sha"
                _MaybeFireStatusDigest
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

    # ---------------- Prereq topo-sort (Upgrade 11) ----------------
    # If PlanAllFirst was used, every $eligible item already has a cached
    # plan in $planCache with a parsed Prereqs list — use it to topo-sort.
    # In the per-item branch we don't have plans yet, so prereqs are
    # discovered lazily during the loop and items are deferred to the back.
    if ($PlanAllFirst -and $planCache.Count -gt 0) {
        $eligibleBySlug = @{}
        foreach ($it in $eligible) { $eligibleBySlug[$it.Slug] = $it }
        $sorted   = [System.Collections.Generic.List[object]]::new()
        $visited  = @{}
        $visiting = @{}
        $visit = $null
        $visit = {
            param($slug)
            if ($visited.ContainsKey($slug)) { return }
            if ($visiting.ContainsKey($slug)) { return }  # cycle: break
            $visiting[$slug] = $true
            $entry = $planCache[$slug]
            $prereqs = @()
            if ($entry -and $entry.PSObject.Properties.Name -contains 'Plan' -and $entry.Plan -and $entry.Plan.Prereqs) {
                $prereqs = $entry.Plan.Prereqs
            } elseif ($entry -and $entry.PSObject.Properties.Name -contains 'PlanPath' -and $entry.PlanPath -and (Test-Path $entry.PlanPath)) {
                $prereqs = (Read-Plan $entry.PlanPath).Prereqs
            }
            foreach ($p in $prereqs) {
                if ($eligibleBySlug.ContainsKey($p)) { & $visit $p }
            }
            $visited[$slug] = $true
            $visiting.Remove($slug) | Out-Null
            $sorted.Add($eligibleBySlug[$slug])
        }
        foreach ($it in $eligible) { & $visit $it.Slug }
        if ($sorted.Count -eq $eligible.Count) {
            $eligible = $sorted.ToArray()
            Write-Verbose "Topo-sorted $($eligible.Count) items by Prereqs."
        }
    }

    # ---------------- Per-item main loop ----------------
    # Lazy prereq deferral: an item whose plan declares prereqs not yet
    # completed is pushed to the back of the queue once. The deferred map
    # records how many times each slug has been deferred; we only defer
    # twice total before giving up and routing to needs-review.
    $deferred = @{}
    $itemNum = 0
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($it in $eligible) { $queue.Enqueue($it) }
    while ($queue.Count -gt 0) {
        $it = $queue.Dequeue()
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
            $siblingSlugs = @($eligible | Where-Object { $_.Slug -ne $it.Slug } | ForEach-Object { $_.Slug })
            $rc = $script:RetryContext[$it.Slug]
            $prevFail   = if ($rc) { [string]$rc.PreviousFailure } else { '' }
            $prevReason = if ($rc) { [string]$rc.PreviousFailureReason } else { '' }
            $itemKind     = _Get-ItemKind -Item $it
            $itemPostPath = _Get-ItemPostPath -Item $it -Kind $itemKind
            $verifyCtx    = @{ PostPath = $itemPostPath }
            $p1 = Invoke-Phase1 -ItemText $it.Text -Slug $it.Slug -Resolutions $resolutionText -Subitems $it.Subitems -SiblingSlugs $siblingSlugs -PreviousFailure $prevFail -PreviousFailureReason $prevReason -ItemType $itemKind -ToolchainContext $script:ToolchainContextStr -VerifyContext $verifyCtx
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
                -ExecutionNotes 'No execute phase ran. The cached plan''s verify gate already passes against the current tree (work landed externally); the runner short-circuited.' `
                -ItemType $itemKind
            Remove-BlockerRegistry -Slug $it.Slug
            $null = $completedSlugs.Add($it.Slug)
            Add-RunLog -Phase 'already-done' -Slug $it.Slug -InvocationResult ([pscustomobject]@{ExitCode=0;Json=$null}) -Extra @{
                item_text    = $it.Text
                mode         = 'already-done'
                failure_mode = 'success'
            }
            Write-Ok "[$itemNum/$($eligible.Count)] $($it.Slug): already-done (verify already passes); committed $sha"
            $consecClass = 0
            _MaybeFireStatusDigest
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

        $rc = $script:RetryContext[$it.Slug]
        $costBoost = if ($rc) { [int]$rc.CostCeilingBoost } else { 1 }
        $turnsBoost = if ($rc) { [int]$rc.MaxTurnsBoost } else { 1 }
        $effectiveCeilingP1 = $CostCeilingPerItem * $costBoost
        if ($p1.Cost -ge $effectiveCeilingP1) {
            Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason 'cost ceiling (phase 1)' -Detail "plan cost = $($p1.Cost) (ceiling = $effectiveCeilingP1)"
            Write-Review "[$itemNum/$($eligible.Count)] $($it.Slug): cost ceiling hit at phase 1"
            $consecClass = 0
            continue
        }

        if ($DryRunPlan -and -not $PlanAllFirst) {
            Write-Ok "[$itemNum/$($eligible.Count)] $($it.Slug): planned (DryRunPlan, skipping execute)"
            continue
        }

        # --- prereq deferral (Upgrade 11) ---
        # If this plan declares prereq slugs that aren't yet completed AND
        # are still pending in the queue, push this item to the back and
        # let the prereqs run first. Defer at most twice per slug to avoid
        # cycles; on the third encounter we route to needs-review.
        $planObj = if ($p1.PSObject.Properties.Name -contains 'Plan' -and $p1.Plan) { $p1.Plan } else { Read-Plan $p1.PlanPath }
        $prereqs = if ($planObj -and $planObj.PSObject.Properties.Name -contains 'Prereqs') { $planObj.Prereqs } else { @() }
        $unmet = @()
        if ($prereqs -and $prereqs.Count -gt 0) {
            $pendingInQueue = @($queue | ForEach-Object { $_.Slug })
            foreach ($p in $prereqs) {
                if ($completedSlugs.Contains($p)) { continue }
                if ($pendingInQueue -contains $p) { $unmet += $p }
            }
        }
        if ($unmet.Count -gt 0) {
            $deferCount = if ($deferred.ContainsKey($it.Slug)) { [int]$deferred[$it.Slug] } else { 0 }
            if ($deferCount -lt 2) {
                $deferred[$it.Slug] = $deferCount + 1
                Write-Info2 "  [$($it.Slug)] deferring: prereqs not yet done -> $($unmet -join ', ') (defer #$($deferCount + 1))"
                $queue.Enqueue($it)
                $consecClass = 0
                continue
            } else {
                Add-NeedsReview -Slug $it.Slug -ItemText $it.Text -Reason 'prereqs unresolved' -Detail "Declared prereqs not completed after 2 deferrals: $($unmet -join ', ')"
                Write-Review "[$itemNum/$($eligible.Count)] $($it.Slug): prereqs unresolved -> needs-review ($($unmet -join ', '))"
                $consecClass = 0
                continue
            }
        }

        # --- phase 2 ---
        $blogN = if ($itemKind -eq 'blog') { _Assign-BlogNumber -Slug $it.Slug } else { 0 }
        $blogS = if ($itemKind -eq 'blog') { $it.Slug } else { '' }
        $p2 = Invoke-Phase2 -Slug $it.Slug -PlanPath $p1.PlanPath -ForcedAssumptions $forcedAssumptions -PlanCost $p1.Cost -ItemText $it.Text -MaxTurnsBoost $turnsBoost -CostCeilingBoost $costBoost -ItemType $itemKind -ToolchainContext $script:ToolchainContextStr -BlogPostNumber $blogN -BlogPostSlug $blogS

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
        # Pull SkipBoot off the parsed plan so kernel items can opt out of
        # the QEMU pass when they don't yet produce a bootable image.
        if ($p2.Parsed.PSObject.Properties.Name -contains 'SkipBoot' -and $p2.Parsed.SkipBoot) {
            $verifyCtx['SkipBoot'] = $p2.Parsed.SkipBoot
        }
        $verify = Test-Verify -Commands $p2.Parsed.Verify -Kind $itemKind -Context $verifyCtx
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
        $sha = Commit-Item -Slug $it.Slug -Summary $p2.Parsed.Summary -Assumptions $p2.Parsed.Assumptions -Forced $forcedAssumptions -VerifyCmd $verifyCmd -ExecutionNotes $execNotes -ItemType $itemKind
        Remove-BlockerRegistry -Slug $it.Slug
        $null = $completedSlugs.Add($it.Slug)

        $planCostStr = '{0:N2}' -f $p1.Cost
        $execCostStr = '{0:N2}' -f $p2.ExecCost
        Write-Ok "[$itemNum/$($eligible.Count)] $($it.Slug): plan `$$planCostStr / execute `$$execCostStr / verified / committed $sha"
        $consecClass = 0
        _MaybeFireStatusDigest
    }

    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

try {
    Invoke-PreFlight
    $code = 0
    switch ($Mode) {
        'design'  { $code = Invoke-DesignPass }
        'roadmap' { $code = Invoke-GenerateRoadmap }
        'digest'  {
            $ok = Invoke-StatusDigest -ItemsCompletedSinceLast 0
            $code = if ($ok) { 0 } else { 1 }
        }
        'build'   { $code = Invoke-Main }
        default   { Write-Halt "unknown -Mode '$Mode'"; $code = 99 }
    }
    exit $code
} catch {
    Write-Halt $_.Exception.Message
    Write-Verbose ($_.ScriptStackTrace)
    exit 1
}
