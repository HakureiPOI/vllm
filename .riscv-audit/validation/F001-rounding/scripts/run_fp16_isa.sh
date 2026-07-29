#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 EXISTING_BUILD_OUTPUT_DIRECTORY" >&2
    exit 2
fi

output_dir=$1
if [[ ! -d "$output_dir" ]]; then
    echo "build output directory not found: $output_dir" >&2
    exit 2
fi

overall=0
for optimization in O0 O3; do
    case_dir="$output_dir/$optimization"
    binary="$case_dir/test_fp16_isa"
    if [[ ! -x "$binary" ]]; then
        echo "binary not found or not executable: $binary" >&2
        overall=1
        continue
    fi
    for output_file in run-command.txt run.txt run-stderr.txt \
        run-exit-code.txt run-sha256.txt run-stderr-sha256.txt \
        runtime-chain.txt; do
        if [[ -e "$case_dir/$output_file" ]]; then
            echo "refusing to overwrite: $case_dir/$output_file" >&2
            exit 2
        fi
    done

    printf '%q\n' "$binary" >"$case_dir/run-command.txt"
    set +e
    "$binary" >"$case_dir/run.txt" 2>"$case_dir/run-stderr.txt"
    exit_code=$?
    set -e
    printf '%s\n' "$exit_code" >"$case_dir/run-exit-code.txt"
    sha256sum "$case_dir/run.txt" >"$case_dir/run-sha256.txt"
    sha256sum "$case_dir/run-stderr.txt" \
        >"$case_dir/run-stderr-sha256.txt"
    {
        cat "$case_dir/binary-sha256.txt"
        cat "$case_dir/run-sha256.txt"
        cat "$case_dir/run-stderr-sha256.txt"
    } >"$case_dir/runtime-chain.txt"
    if [[ $exit_code -ne 0 ]]; then
        overall=1
    fi
done

exit "$overall"
