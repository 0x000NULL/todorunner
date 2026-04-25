# Verification harness for the 5-upgrade Run-Todos.ps1 changes.
# Re-defines just the helpers under test (verbatim from Run-Todos.ps1) so
# we can run isolated smoke tests without firing Invoke-Main. NOT a unit-test
# framework — just enough to validate the upgrades end-to-end.

#Requires -Version 7.0
$ErrorActionPreference = 'Stop'

# ----- copies of helpers under test (sync if they change) -----

function ConvertTo-Slug {
    param([Parameter(Mandatory)][string]$Text)
    $s = $Text.ToLowerInvariant()
    $s = [regex]::Replace($s, '[^a-z0-9]+', '-')
    $s = $s.Trim('-')
    if ($s.Length -gt 60) {
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

        $subitems = @()
        $j = $i + 1
        while ($j -lt $lines.Count) {
            $next = $lines[$j]
            if ([string]::IsNullOrWhiteSpace($next)) { $j++; continue }
            if ($next -match '^-\s*\[') { break }
            if ($next -match '^#{1,6}\s') { break }
            if ($next -notmatch '^\s+\S') { break }
            $sm = [regex]::Match($next, '^\s+-\s*\[[ xX]\]\s*(.+?)\s*$')
            if ($sm.Success) { $subitems += $sm.Groups[1].Value }
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

$script:VerifyForbiddenPatterns = @(
    '\b(grep|rg|ack)\b[^|;&]*\b(TODO|todo|needs-review|HALT)\.md\b',
    '\b(grep|rg|ack)\b[^|;&]*\.claude[/\\]',
    '\b(cargo run|npm start|npm run dev|yarn start|yarn dev)\b',
    '\bpwsh\b[^|;&]*-Command'
)

function Test-PlanVerifyGrammar {
    param([Parameter(Mandatory)][string[]]$Verify)
    foreach ($cmd in $Verify) {
        if (-not $cmd) { continue }
        foreach ($pat in $script:VerifyForbiddenPatterns) {
            if ($cmd -match $pat) {
                return [pscustomobject]@{ Passed = $false; FirstOffender = $cmd; Pattern = $pat }
            }
        }
    }
    return [pscustomobject]@{ Passed = $true; FirstOffender = $null; Pattern = $null }
}

function Get-VerifyFingerprint {
    param([string]$Output)
    if (-not $Output) { return '00000000' }
    $norm = ($Output.ToLowerInvariant() -replace '\s+', ' ').Trim()
    $bytes = [Text.Encoding]::UTF8.GetBytes($norm)
    $hash  = [System.Security.Cryptography.SHA1]::Create().ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace '-','').Substring(0,8).ToLower()
}

# ----- tests -----

$pass = 0
$fail = 0
function Assert {
    param([string]$Name, [bool]$Cond, [string]$Detail = '')
    if ($Cond) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red
        $script:fail++
    }
}

Write-Host "== Test 2: Container parsing ==" -ForegroundColor Cyan
@'
- [ ] Parent with subitems
  - [ ] First substep
  - [ ] Second substep
- [ ] Standalone parent
- [x] Already-done parent
    - [ ] Deeper-indented sub
- [ ] Parent then heading

### Heading stops peek

- [ ] After heading
'@ | Set-Content "$env:TEMP/test-todo.md"

$items = Get-TodoItems "$env:TEMP/test-todo.md"
Assert "Item count = 5" ($items.Count -eq 5) "got $($items.Count)"
Assert "Item[0] has 2 subitems" ($items[0].Subitems.Count -eq 2)
Assert "Item[0].Subitems[0] = First substep" ($items[0].Subitems[0] -eq 'First substep')
Assert "Item[0].Subitems[1] = Second substep" ($items[0].Subitems[1] -eq 'Second substep')
Assert "Item[1] has 0 subitems" ($items[1].Subitems.Count -eq 0)
Assert "Item[2] checked" ($items[2].Checked)
Assert "Item[2] has 1 subitem" ($items[2].Subitems.Count -eq 1)
Assert "Item[3] (Parent then heading) has 0 subitems" ($items[3].Subitems.Count -eq 0)
Assert "Item[4] (After heading) is unchecked" (-not $items[4].Checked)

Write-Host "`n== Test 4: Verify-grammar validator ==" -ForegroundColor Cyan
$bad1 = Test-PlanVerifyGrammar -Verify @('grep -q "Fix stdc++.lib link failure" TODO.md')
Assert "Rejects grep against TODO.md" (-not $bad1.Passed)

$bad2 = Test-PlanVerifyGrammar -Verify @('cargo check', 'rg --quiet "X" needs-review.md')
Assert "Rejects rg against needs-review.md" (-not $bad2.Passed)

$bad3 = Test-PlanVerifyGrammar -Verify @('cargo run --release')
Assert "Rejects cargo run" (-not $bad3.Passed)

$bad4 = Test-PlanVerifyGrammar -Verify @('npm start')
Assert "Rejects npm start" (-not $bad4.Passed)

$bad5 = Test-PlanVerifyGrammar -Verify @('pwsh -Command "echo hi"')
Assert "Rejects nested pwsh -Command" (-not $bad5.Passed)

$bad6 = Test-PlanVerifyGrammar -Verify @('grep -q ALPHA .claude/plans/foo.md')
Assert "Rejects grep against .claude/" (-not $bad6.Passed)

$ok1 = Test-PlanVerifyGrammar -Verify @('cargo check --all-targets', 'test -f src/foo.rs')
Assert "Accepts cargo check + test -f" $ok1.Passed

$ok2 = Test-PlanVerifyGrammar -Verify @('grep -q "fn capture_screen" src/capture.rs', 'cargo build')
Assert "Accepts grep against deliverable source" $ok2.Passed

$ok3 = Test-PlanVerifyGrammar -Verify @('npm test')
Assert "Accepts npm test" $ok3.Passed

Write-Host "`n== Test: Fingerprint stability ==" -ForegroundColor Cyan
$fp1 = Get-VerifyFingerprint -Output "Error: thing failed`n  at line 5"
$fp2 = Get-VerifyFingerprint -Output "ERROR:    THING failed`n at line 5"
$fp3 = Get-VerifyFingerprint -Output "Different error entirely"
Assert "Same content (case/whitespace) -> same fingerprint" ($fp1 -eq $fp2) "fp1=$fp1 fp2=$fp2"
Assert "Different content -> different fingerprint" ($fp1 -ne $fp3)
Assert "Fingerprint is 8 hex chars" ($fp1 -match '^[0-9a-f]{8}$')

Write-Host ""
Write-Host "Passed: $pass   Failed: $fail"
Remove-Item "$env:TEMP/test-todo.md" -ErrorAction SilentlyContinue
exit ([int]($fail -gt 0))
