#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <results-directory>" >&2
    exit 2
fi

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
VALIDATION="$ROOT/.riscv-audit/validation/F004-cross-compile"
RESULTS="$(readlink -f "$1")"

[[ -d "$RESULTS" ]] || { echo "results directory not found: $1" >&2; exit 1; }
case "$RESULTS" in
    "$VALIDATION/results/"*) ;;
    *)
        echo "results directory is outside the F004 validation tree: $RESULTS" >&2
        exit 1
        ;;
esac

command -v jq >/dev/null
command -v sha256sum >/dev/null

sync_artifact() {
    local source="$1"
    local destination="$2"
    local required="$3"

    if [[ -f "$source" ]]; then
        if [[ -f "$destination" ]]; then
            cmp -s "$source" "$destination" || {
                echo "artifact mismatch: $destination" >&2
                exit 1
            }
        else
            cp "$source" "$destination"
        fi
    elif [[ "$required" == required && ! -f "$destination" ]]; then
        echo "required artifact missing: $destination" >&2
        exit 1
    fi
}

extract_target_tables() {
    local test_name="$1"
    local compile_commands="$2"
    local vllm_tsv="$3"
    local dependency_tsv="$4"

    printf 'test\ttarget\tsource_file\toutput\tcompiler\tmarch\tother_riscv_flags\n' > "$vllm_tsv"
    printf 'test\ttarget\tsource_file\toutput\tcompiler\tmarch\tother_riscv_flags\n' > "$dependency_tsv"
    [[ -f "$compile_commands" ]] || return 0

    jq -r --arg test "$test_name" '
        def command_text: (.command // (.arguments | join(" ")));
        def compiler:
            if .arguments then .arguments[0]
            else (command_text | split(" ")[0])
            end;
        def flags($prefix):
            [command_text | split(" ")[] | select(startswith($prefix))]
            | if length > 0 then join(" ") else "-" end;
        def other_riscv_flags:
            [flags("-mabi="), flags("-mrvv-vector-bits=")]
            | map(select(. != "-"))
            | if length > 0 then join(" ") else "-" end;
        .[]
        | select((.output // "") | test("(^|/)CMakeFiles/(_C|dnnl_ext)\\.dir/"))
        | [
            $test,
            ((.output // "") | capture("CMakeFiles/(?<target>_C|dnnl_ext)\\.dir/").target),
            .file,
            (.output // ""),
            compiler,
            flags("-march="),
            other_riscv_flags
        ] | @tsv
    ' "$compile_commands" >> "$vllm_tsv"

    jq -r --arg test "$test_name" '
        def command_text: (.command // (.arguments | join(" ")));
        def compiler:
            if .arguments then .arguments[0]
            else (command_text | split(" ")[0])
            end;
        def flags($prefix):
            [command_text | split(" ")[] | select(startswith($prefix))]
            | if length > 0 then join(" ") else "-" end;
        def other_riscv_flags:
            [flags("-mabi="), flags("-mrvv-vector-bits=")]
            | map(select(. != "-"))
            | if length > 0 then join(" ") else "-" end;
        def dependency_target:
            try ((.output // "") | capture("CMakeFiles/(?<target>[^/]+)\\.dir/").target)
            catch "dependency";
        .[]
        | select(
            ((.file // "") | contains("/_deps/")) or
            ((.output // "") | contains("_deps/"))
        )
        | [
            $test,
            dependency_target,
            .file,
            (.output // ""),
            compiler,
            flags("-march="),
            other_riscv_flags
        ] | @tsv
    ' "$compile_commands" >> "$dependency_tsv"
}

for test_name in T0-scalar T1-vlen128 T2-vlen128-bf16 T3-bf16-no-vlen; do
    test_dir="$RESULTS/$test_name"
    build_dir="$test_dir/build"
    [[ -d "$test_dir" ]] || { echo "test directory missing: $test_dir" >&2; exit 1; }
    [[ -f "$test_dir/configure.log" ]] || {
        echo "full configure log missing: $test_dir/configure.log" >&2
        exit 1
    }
    [[ -f "$test_dir/exit_code.txt" ]] || {
        echo "exit code missing: $test_dir/exit_code.txt" >&2
        exit 1
    }

    exit_code="$(tr -d '[:space:]' < "$test_dir/exit_code.txt")"
    [[ "$exit_code" =~ ^[0-9]+$ ]] || {
        echo "invalid exit code for $test_name: $exit_code" >&2
        exit 1
    }

    sync_artifact "$build_dir/CMakeCache.txt" "$test_dir/CMakeCache.txt" required
    if [[ "$exit_code" -eq 0 ]]; then
        sync_artifact "$build_dir/compile_commands.json" \
            "$test_dir/compile_commands.json" required
    else
        sync_artifact "$build_dir/compile_commands.json" \
            "$test_dir/compile_commands.json" optional
    fi

    messages_tmp="$(mktemp)"
    grep -F '[F004]' "$test_dir/configure.log" > "$messages_tmp" || {
        rm -f "$messages_tmp"
        echo "no F004 instrumentation messages in $test_dir/configure.log" >&2
        exit 1
    }
    if [[ -f "$test_dir/f004-messages.txt" ]]; then
        cmp -s "$messages_tmp" "$test_dir/f004-messages.txt" || {
            rm -f "$messages_tmp"
            echo "F004 message artifact mismatch: $test_dir/f004-messages.txt" >&2
            exit 1
        }
        rm -f "$messages_tmp"
    else
        mv "$messages_tmp" "$test_dir/f004-messages.txt"
    fi

    grep -E '^((CMAKE_(BUILD_TYPE|TOOLCHAIN_FILE|HOME_DIRECTORY|GENERATOR)|VLLM_(PYTHON_EXECUTABLE|RVV_VLEN|TARGET_DEVICE)|Torch_DIR):)' \
        "$test_dir/CMakeCache.txt" > "$test_dir/cmake-cache-selected.txt" || true

    extract_target_tables \
        "$test_name" \
        "$test_dir/compile_commands.json" \
        "$test_dir/vllm-target-march.tsv" \
        "$test_dir/dependency-target-march.tsv"

    {
        echo '# Summary only; use the target-attributed TSV files as evidence.'
        printf 'category\ttarget\tmarch\tother_riscv_flags\n'
        {
            awk -F '\t' 'NR > 1 {print "vllm\t" $2 "\t" $6 "\t" $7}' \
                "$test_dir/vllm-target-march.tsv"
            awk -F '\t' 'NR > 1 {print "dependency\t" $2 "\t" $6 "\t" $7}' \
                "$test_dir/dependency-target-march.tsv"
        } | sort -u
    } > "$test_dir/march-summary-attributed.txt"

    if [[ ! -f "$test_dir/march-values.txt" ]]; then
        {
            awk -F '\t' 'NR > 1 && $6 != "-" {print $6}' \
                "$test_dir/vllm-target-march.tsv"
            awk -F '\t' 'NR > 1 && $6 != "-" {print $6}' \
                "$test_dir/dependency-target-march.tsv"
        } | sort -u > "$test_dir/march-values.txt"
    fi
done

FIRST_CACHE="$RESULTS/T1-vlen128/CMakeCache.txt"
PYTHON="$(sed -n 's/^VLLM_PYTHON_EXECUTABLE:[^=]*=//p' "$FIRST_CACHE" | head -n 1)"
[[ -x "$PYTHON" ]] || { echo "recorded Python is unavailable: $PYTHON" >&2; exit 1; }
"$PYTHON" -c 'import torch' >/dev/null

{
    echo "results_directory=$RESULTS"
    echo "manifest_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "git_commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "experiment_source_commit=57f327ef9c827788c85c0a69c0cf86e446ff27ae"
    echo "source_blob=$(git -C "$ROOT" rev-parse '57f327ef9c827788c85c0a69c0cf86e446ff27ae:cmake/cpu_extension.cmake')"
    echo "instrumentation_patch_sha256=$(sha256sum "$VALIDATION/instrumentation/f004-log-only.patch" | awk '{print $1}')"
    echo "toolchain_sha256=$(sha256sum "$VALIDATION/toolchains/riscv64-linux-gnu.cmake" | awk '{print $1}')"
    echo "run_matrix_sha256=$(sha256sum "$VALIDATION/scripts/run_matrix.sh" | awk '{print $1}')"
    echo "python=$PYTHON"
    "$PYTHON" --version 2>&1 | sed 's/^/python_version=/'
    "$PYTHON" -c 'import sys, torch; print("python_executable=" + sys.executable); print("torch_version=" + torch.__version__); print("torch_cmake_prefix=" + torch.utils.cmake_prefix_path)'
    cmake --version | head -n 1 | sed 's/^/cmake_version=/'
    riscv64-linux-gnu-g++ --version | head -n 1 | sed 's/^/cxx_compiler_version=/'
    echo 'artifact_sha256:'
    find "$RESULTS" -mindepth 2 -maxdepth 2 -type f \
        ! -name manifest.txt -print0 | sort -z | xargs -0 sha256sum
} > "$RESULTS/manifest.txt"

echo "evidence extracted: $RESULTS"
