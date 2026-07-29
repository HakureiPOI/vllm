#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "usage: $0 NEW_OUTPUT_DIR ROLE COMPILER [COMPILER_FLAGS...]" >&2
    exit 2
fi

output_dir=$1
role=$2
compiler=$3
shift 3
compiler_flags=("$@")

if [[ -e "$output_dir" ]]; then
    echo "refusing to overwrite existing output: $output_dir" >&2
    exit 2
fi
command -v "$compiler" >/dev/null 2>&1 || {
    echo "compiler not found: $compiler" >&2
    exit 2
}

mkdir -p "$output_dir"
printf '%s\n' "$role" >"$output_dir/remote-host-role.txt"
date -u +%Y-%m-%dT%H:%M:%SZ >"$output_dir/captured-at-utc.txt"
uname -a >"$output_dir/uname.txt"
lscpu >"$output_dir/lscpu.txt" 2>&1 || true
grep -E '^(processor|hart|isa|uarch|model name|vendor_id|Hardware)' \
    /proc/cpuinfo >"$output_dir/cpuinfo-summary.txt" 2>&1 || true
command -v "$compiler" >"$output_dir/compiler-path.txt"
"$compiler" --version >"$output_dir/compiler-version.txt"
printf '%q ' "$compiler" "${compiler_flags[@]}" \
    >"$output_dir/compiler-invocation.txt"
printf '\n' >>"$output_dir/compiler-invocation.txt"

if command -v cmake >/dev/null 2>&1; then
    cmake --version >"$output_dir/cmake-version.txt"
fi
if command -v ninja >/dev/null 2>&1; then
    ninja --version >"$output_dir/ninja-version.txt"
fi
if command -v clang >/dev/null 2>&1; then
    clang --version >"$output_dir/clang-version.txt"
    clang --print-targets >"$output_dir/clang-targets.txt" 2>&1 || true
fi
