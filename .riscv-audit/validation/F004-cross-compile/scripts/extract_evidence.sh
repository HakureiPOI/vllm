#!/bin/bash
set -euo pipefail

# F004 cross-compile validation: extract evidence from test results
# Run after run_matrix.sh

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
VALIDATION="$ROOT/.riscv-audit/validation/F004-cross-compile"
RESULTS_DIR="$VALIDATION/results"

# Find the latest results directory
LATEST=$(ls -d "$RESULTS_DIR"/*/ 2>/dev/null | sort | tail -1)
if [ -z "$LATEST" ]; then
    echo "No results directory found."
    exit 1
fi

echo "Extracting evidence from: $LATEST"

for test_dir in "$LATEST"T*/; do
    test_name=$(basename "$test_dir")
    echo ""
    echo "=== $test_name ==="

    # Copy CMakeCache if exists
    if [ -f "$test_dir/build/CMakeCache.txt" ]; then
        cp "$test_dir/build/CMakeCache.txt" "$test_dir/CMakeCache.txt"
        echo "  CMakeCache.txt: copied"
    else
        echo "  CMakeCache.txt: not found"
    fi

    # Copy compile_commands if exists
    if [ -f "$test_dir/build/compile_commands.json" ]; then
        cp "$test_dir/build/compile_commands.json" "$test_dir/compile_commands.json"
        echo "  compile_commands.json: copied"
    else
        echo "  compile_commands.json: not found"
    fi

    # Extract F004 messages
    if [ -f "$test_dir/configure.log" ]; then
        grep -F "[F004]" "$test_dir/configure.log" > "$test_dir/f004-messages.txt" 2>/dev/null || true
        echo "  F004 messages: $(wc -l < "$test_dir/f004-messages.txt" 2>/dev/null || echo 0) lines"

        # Extract -march from compile_commands or build.ninja
        march_file="$test_dir/march-values.txt"
        > "$march_file"

        if [ -f "$test_dir/compile_commands.json" ]; then
            jq -r '.[].command // .[].arguments[]?' "$test_dir/compile_commands.json" 2>/dev/null \
                | grep -o -- '-march=[^ "'\'']*' \
                | sort -u >> "$march_file" || true
        fi

        # Also check build.ninja
        find "$test_dir/build" -name "*.ninja" -exec grep -Rho -- '-march=[^ "'\'']*' {} + 2>/dev/null \
            | sort -u >> "$march_file" || true

        sort -u -o "$march_file" "$march_file"
        echo "  march-values: $(cat "$march_file" 2>/dev/null | tr '\n' ' ')"

        # Show exit code
        if [ -f "$test_dir/exit_code.txt" ]; then
            echo "  exit code: $(cat "$test_dir/exit_code.txt")"
        fi
    fi
done

echo ""
echo "=== Evidence extraction complete ==="
