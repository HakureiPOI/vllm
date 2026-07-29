#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 RESULT_DIRECTORY REPOSITORY_ROOT" >&2
    exit 2
fi

result_dir=$1
repository_root=$2
manifest="$result_dir/manifest.txt"
validation_dir="$repository_root/.riscv-audit/validation/F001-rounding"

if [[ ! -d "$result_dir" ]]; then
    echo "result directory not found: $result_dir" >&2
    exit 2
fi
if [[ -e "$manifest" ]]; then
    echo "refusing to overwrite existing manifest: $manifest" >&2
    exit 2
fi
for tool in git sha256sum find sort; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "required tool not found: $tool" >&2
        exit 2
    }
done

{
    echo "F001 remediation evidence manifest"
    echo "UTC timestamp: $(basename "$result_dir")"
    echo "Repository HEAD: $(git -C "$repository_root" rev-parse HEAD)"
    echo "Branch: $(git -C "$repository_root" branch --show-current)"
    echo "Remote host roles: bianbu=RISC-V runtime and native GCC probe; aliyun=x86_64 cross GCC and Clang probe"
    echo
    echo "Package document, source, script, environment and first-run SHA256:"
    sha256sum \
        "$validation_dir/src/test_fp16_isa.c" \
        "$validation_dir/src/probes/"*.c \
        "$validation_dir/scripts/"*.sh \
        "$validation_dir/environment/"*.txt \
        "$validation_dir/results/20260729T112835Z/"*.txt \
        "$validation_dir/README.md" \
        "$validation_dir/REPORT.md"
    find "$validation_dir/results/20260729T144517Z" -type f -print0 |
        sort -z |
        xargs -0 sha256sum
    echo
    echo "Compiler paths and versions:"
    find "$result_dir" -type f \
        \( -name compiler-path.txt -o -name compiler-version.txt \) \
        -print -exec sed 's/^/  /' {} \;
    echo
    echo "Header paths and SHA256:"
    find "$result_dir" -type f \
        \( -name header-path.txt -o -name header-sha256.txt \) \
        -print -exec sed 's/^/  /' {} \;
    echo
    echo "Compile and run exit codes:"
    find "$result_dir" -type f \
        \( -name compile-exit-code.txt -o -name run-exit-code.txt \
        -o -name macros-fp16-exit-code.txt \
        -o -name macros-bf16-exit-code.txt \) \
        -print -exec sed 's/^/  /' {} \;
    echo
    echo "Remote binary and object SHA256 records:"
    find "$result_dir" -type f \
        \( -name binary-sha256.txt -o -name object-sha256.txt \) \
        -print -exec sed 's/^/  /' {} \;
    echo
    echo "Remote-produced evidence checksum sets:"
    find "$result_dir" -type f -name remote-files-sha256.txt \
        -print -exec sed 's/^/  /' {} \;
    echo
    echo "CPU and environment evidence:"
    find "$result_dir" -type f \
        \( -name uname.txt -o -name lscpu.txt \
        -o -name cpuinfo-summary.txt -o -name remote-host-role.txt \) \
        -print
    echo
    echo "Full compile commands:"
    find "$result_dir" -type f \
        \( -name compile-command.txt -o -name macros-fp16-command.txt \
        -o -name macros-bf16-command.txt \) \
        -print -exec sed 's/^/  /' {} \;
    echo
    echo "All evidence file SHA256:"
    find "$result_dir" -type f ! -name manifest.txt -print0 |
        sort -z |
        xargs -0 sha256sum
} >"$manifest"
