#!/usr/bin/env pwsh
# Mock qemu shim (PowerShell variant). Behaves like tests/mock-qemu.sh:
# parses "-serial file:<path>" out of args and writes BOOT_OK to that path.
# Set $env:TEST_FAIL_QEMU = '1' before invoking to write a PANIC line instead.
param([Parameter(ValueFromRemainingArguments)]$RawArgs)
$serial = $null
for ($i = 0; $i -lt $RawArgs.Count; $i++) {
    if ($RawArgs[$i] -eq '-serial' -and ($i + 1) -lt $RawArgs.Count) {
        $a = [string]$RawArgs[$i + 1]
        if ($a.StartsWith('file:')) { $serial = $a.Substring(5); break }
    }
}
if ($serial) {
    if ($env:TEST_FAIL_QEMU -eq '1') {
        "mock-qemu booting...`nPANIC: page fault`n" | Set-Content -Path $serial -Encoding utf8 -NoNewline
    } else {
        "mock-qemu booting...`nBOOT_OK`nmock-qemu shutdown`n" | Set-Content -Path $serial -Encoding utf8 -NoNewline
    }
}
exit 0
