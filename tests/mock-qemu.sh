#!/usr/bin/env bash
# Mock qemu shim for Run-OsBuild.ps1's smoke test.
serial=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -serial)
            arg="$2"
            if [[ "$arg" == file:* ]]; then
                serial="${arg#file:}"
            fi
            shift 2
            ;;
        *) shift ;;
    esac
done
if [[ -n "$serial" ]]; then
    if [[ "${TEST_FAIL_QEMU:-0}" == "1" ]]; then
        printf 'mock-qemu booting...\nPANIC: page fault\n' > "$serial"
    else
        printf 'mock-qemu booting...\nBOOT_OK\nmock-qemu shutdown\n' > "$serial"
    fi
fi
exit 0
