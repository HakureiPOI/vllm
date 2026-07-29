#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 SOURCE_FILE NEW_OUTPUT_DIRECTORY" >&2
    exit 2
fi

source_file=$1
output_dir=$2
compiler=${CC:-gcc}
objdump_tool=${OBJDUMP:-objdump}
march=${F001_MARCH:-rv64gcv_zvfh}
march_source=${F001_MARCH_SOURCE:-explicit after cpuinfo and compiler probe}

if [[ ! -f "$source_file" ]]; then
    echo "source file not found: $source_file" >&2
    exit 2
fi
if [[ -e "$output_dir" ]]; then
    echo "refusing to overwrite existing output: $output_dir" >&2
    exit 2
fi
for tool in "$compiler" "$objdump_tool" sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "required tool not found: $tool" >&2
        exit 2
    }
done

mkdir -p "$output_dir"
sha256sum "$source_file" >"$output_dir/test-source-sha256.txt"
printf '%s\n' "$march" >"$output_dir/march.txt"
printf '%s\n' "$march_source" >"$output_dir/march-source.txt"
command -v "$compiler" >"$output_dir/compiler-path.txt"
"$compiler" --version >"$output_dir/compiler-version.txt"
command -v "$objdump_tool" >"$output_dir/objdump-path.txt"
"$objdump_tool" --version >"$output_dir/objdump-version.txt"

overall=0
for optimization in O0 O3; do
    case "$optimization" in
        O0) optimization_flags=(-O0) ;;
        O3) optimization_flags=(-O3 -DNDEBUG) ;;
    esac
    case_dir="$output_dir/$optimization"
    mkdir -p "$case_dir"
    binary="$case_dir/test_fp16_isa"
    command_line=(
        "$compiler"
        -std=c11
        "${optimization_flags[@]}"
        -fno-lto
        -frounding-math
        "-march=$march"
        "$source_file"
        -o "$binary"
        -lm
    )
    printf '%q ' "${command_line[@]}" >"$case_dir/compile-command.txt"
    printf '\n' >>"$case_dir/compile-command.txt"

    set +e
    "${command_line[@]}" >"$case_dir/compile-stdout.txt" \
        2>"$case_dir/compile-stderr.txt"
    exit_code=$?
    set -e
    printf '%s\n' "$exit_code" >"$case_dir/compile-exit-code.txt"

    if [[ $exit_code -eq 0 ]]; then
        sha256sum "$binary" >"$case_dir/binary-sha256.txt"
        printf '%q ' "$objdump_tool" -drwC "$binary" \
            >"$case_dir/disasm-command.txt"
        printf '\n' >>"$case_dir/disasm-command.txt"
        "$objdump_tool" -drwC "$binary" >"$case_dir/disasm.txt"
        sha256sum "$case_dir/disasm.txt" >"$case_dir/disasm-sha256.txt"
        {
            cat "$output_dir/test-source-sha256.txt"
            cat "$case_dir/binary-sha256.txt"
            cat "$case_dir/disasm-sha256.txt"
        } >"$case_dir/artifact-chain.txt"
    else
        overall=1
    fi
done

exit "$overall"
