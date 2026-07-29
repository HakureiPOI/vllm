#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 5 ]]; then
    echo "usage: $0 NEW_OUTPUT_DIR COMPILER LABEL FP16_MARCH BF16_MARCH [COMPILER_PREFIX_FLAGS...]" >&2
    exit 2
fi

output_dir=$1
compiler=$2
label=$3
fp16_march=$4
bf16_march=$5
shift 5
prefix_flags=("$@")
objdump_tool=${OBJDUMP:-objdump}

script_dir=$(cd "$(dirname "$0")" && pwd)
validation_dir=$(cd "$script_dir/.." && pwd)
probe_dir="$validation_dir/src/probes"

if [[ -e "$output_dir" ]]; then
    echo "refusing to overwrite existing output: $output_dir" >&2
    exit 2
fi
command -v "$compiler" >/dev/null 2>&1 || {
    echo "compiler not found: $compiler" >&2
    exit 2
}
for tool in sha256sum "$objdump_tool"; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "required tool not found: $tool" >&2
        exit 2
    }
done
for source_name in \
    probe_fp16_implicit.c \
    probe_fp16_explicit_rm.c \
    probe_bf16_implicit.c \
    probe_bf16_explicit_rm.c; do
    [[ -f "$probe_dir/$source_name" ]] || {
        echo "probe source not found: $probe_dir/$source_name" >&2
        exit 2
    }
done

mkdir -p "$output_dir"
printf '%s\n' "$label" >"$output_dir/label.txt"
command -v "$compiler" >"$output_dir/compiler-path.txt"
"$compiler" --version >"$output_dir/compiler-version.txt"
command -v "$objdump_tool" >"$output_dir/objdump-path.txt"
"$objdump_tool" --version >"$output_dir/objdump-version.txt"
printf '%q ' "$compiler" "${prefix_flags[@]}" >"$output_dir/compiler-prefix.txt"
printf '\n' >>"$output_dir/compiler-prefix.txt"
printf '%s\n' "$fp16_march" >"$output_dir/fp16-march.txt"
printf '%s\n' "$bf16_march" >"$output_dir/bf16-march.txt"
"$compiler" "${prefix_flags[@]}" -print-search-dirs \
    >"$output_dir/compiler-search-dirs.txt" 2>&1 || true

if [[ "$compiler" == *clang* ]]; then
    "$compiler" --print-targets >"$output_dir/clang-targets.txt" 2>&1 || true
    "$compiler" -print-resource-dir >"$output_dir/clang-resource-dir.txt" \
        2>&1 || true
    "$compiler" "${prefix_flags[@]}" -v -E -x c /dev/null \
        >"$output_dir/clang-target-preprocess-stdout.txt" \
        2>"$output_dir/clang-target-preprocess-stderr.txt" || true
    "$compiler" "${prefix_flags[@]}" --print-file-name=crt1.o \
        >"$output_dir/clang-target-crt1-path.txt" 2>&1 || true
fi

capture_macros() {
    local name=$1
    local march=$2
    local command_line=(
        "$compiler" "${prefix_flags[@]}" "-march=$march"
        -dM -E -x c /dev/null
    )
    printf '%q ' "${command_line[@]}" >"$output_dir/macros-$name-command.txt"
    printf '\n' >>"$output_dir/macros-$name-command.txt"
    set +e
    "${command_line[@]}" >"$output_dir/macros-$name.txt" \
        2>"$output_dir/macros-$name-stderr.txt"
    local exit_code=$?
    set -e
    printf '%s\n' "$exit_code" >"$output_dir/macros-$name-exit-code.txt"
}

capture_header() {
    local name=$1
    local march=$2
    local case_dir="$output_dir/header-$name"
    mkdir -p "$case_dir"
    printf '#include <riscv_vector.h>\n' >"$case_dir/header-probe.c"
    local command_line=(
        "$compiler" "${prefix_flags[@]}" "-march=$march"
        -E -H "$case_dir/header-probe.c"
    )
    printf '%q ' "${command_line[@]}" >"$case_dir/command.txt"
    printf '\n' >>"$case_dir/command.txt"
    set +e
    "${command_line[@]}" >"$case_dir/stdout.txt" 2>"$case_dir/stderr.txt"
    local exit_code=$?
    set -e
    printf '%s\n' "$exit_code" >"$case_dir/exit-code.txt"

    local header_path
    header_path=$(sed -n 's/^[. ][. ]*//p' "$case_dir/stderr.txt" |
        grep '/riscv_vector.h$' | head -n 1 || true)
    printf '%s\n' "$header_path" >"$case_dir/header-path.txt"
    if [[ -n "$header_path" && -f "$header_path" ]]; then
        sha256sum "$header_path" >"$case_dir/header-sha256.txt"
    fi
}

compile_probe() {
    local source_name=$1
    local march=$2
    local case_name=${source_name%.c}
    local case_dir="$output_dir/$case_name"
    local source_file="$probe_dir/$source_name"
    local object_file="$case_dir/$case_name.o"
    mkdir -p "$case_dir"
    cp "$source_file" "$case_dir/source.c"
    sha256sum "$case_dir/source.c" >"$case_dir/source-sha256.txt"
    local command_line=(
        "$compiler" "${prefix_flags[@]}" "-march=$march"
        -std=c11 -O2 -fno-lto -c "$case_dir/source.c" -o "$object_file"
    )
    printf '%q ' "${command_line[@]}" >"$case_dir/compile-command.txt"
    printf '\n' >>"$case_dir/compile-command.txt"
    set +e
    "${command_line[@]}" >"$case_dir/compile-stdout.txt" \
        2>"$case_dir/compile-stderr.txt"
    local exit_code=$?
    set -e
    printf '%s\n' "$exit_code" >"$case_dir/compile-exit-code.txt"
    if [[ $exit_code -eq 0 ]]; then
        sha256sum "$object_file" >"$case_dir/object-sha256.txt"
        printf '%q ' "$objdump_tool" -drwC "$object_file" \
            >"$case_dir/disasm-command.txt"
        printf '\n' >>"$case_dir/disasm-command.txt"
        "$objdump_tool" -drwC "$object_file" >"$case_dir/disasm.txt" \
            2>&1 || true
        sha256sum "$case_dir/disasm.txt" >"$case_dir/disasm-sha256.txt"
        {
            cat "$case_dir/source-sha256.txt"
            cat "$case_dir/object-sha256.txt"
            cat "$case_dir/disasm-sha256.txt"
        } >"$case_dir/artifact-chain.txt"
    fi
}

capture_macros fp16 "$fp16_march"
capture_macros bf16 "$bf16_march"
capture_header fp16 "$fp16_march"
capture_header bf16 "$bf16_march"
compile_probe probe_fp16_implicit.c "$fp16_march"
compile_probe probe_fp16_explicit_rm.c "$fp16_march"
compile_probe probe_bf16_implicit.c "$bf16_march"
compile_probe probe_bf16_explicit_rm.c "$bf16_march"

exit 0
