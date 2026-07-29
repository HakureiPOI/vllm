#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 --python /path/to/venv/bin/python --output <new-results-directory>" >&2
}

PYTHON=''
OUTPUT=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --python)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            PYTHON="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            OUTPUT="$2"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

[[ -n "$PYTHON" && -n "$OUTPUT" ]] || { usage; exit 2; }

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
VALIDATION="$ROOT/.riscv-audit/validation/F004-cross-compile"
TOOLCHAIN="$VALIDATION/toolchains/riscv64-linux-gnu.cmake"
PATCH="$VALIDATION/instrumentation/f004-log-only.patch"
TARGET="$ROOT/cmake/cpu_extension.cmake"
EXPECTED_INSTRUMENTED_BLOB='766edb26ee5e29d5b16bd63d25b3d2ed5b1a0aa7'

[[ -x "$PYTHON" ]] || { echo "python is not executable: $PYTHON" >&2; exit 1; }
PYTHON="$(readlink -f "$PYTHON")"

case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$ROOT/$OUTPUT" ;;
esac

if [[ -e "$OUTPUT" ]]; then
    echo "results directory already exists: $OUTPUT" >&2
    exit 1
fi

MARKER_COUNT="$(grep -Fc 'message(STATUS "[F004]' "$TARGET" || true)"
if [[ "$MARKER_COUNT" -ne 13 ]]; then
    echo "expected 13 F004 instrumentation messages; found $MARKER_COUNT" >&2
    exit 1
fi
if [[ "$(git -C "$ROOT" hash-object cmake/cpu_extension.cmake)" != \
        "$EXPECTED_INSTRUMENTED_BLOB" ]]; then
    echo "instrumented source blob is not the validated blob" >&2
    exit 1
fi
git -C "$ROOT" apply --unidiff-zero --check -R "$PATCH" || {
    echo "exact F004 instrumentation patch is not applied" >&2
    exit 1
}

"$PYTHON" -c 'import torch' >/dev/null
command -v cmake >/dev/null
command -v ninja >/dev/null
command -v riscv64-linux-gnu-gcc >/dev/null
command -v riscv64-linux-gnu-g++ >/dev/null

mkdir "$OUTPUT"
{
    echo "utc_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "repository=$ROOT"
    echo "git_commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "source_baseline=57f327ef9c827788c85c0a69c0cf86e446ff27ae"
    echo "source_blob=$(git -C "$ROOT" rev-parse '57f327ef9c827788c85c0a69c0cf86e446ff27ae:cmake/cpu_extension.cmake')"
    echo "instrumented_blob=$(git -C "$ROOT" hash-object cmake/cpu_extension.cmake)"
    echo "python=$PYTHON"
    "$PYTHON" --version 2>&1 | sed 's/^/python_version=/'
    "$PYTHON" -c 'import sys, torch; print("python_executable=" + sys.executable); print("torch_version=" + torch.__version__); print("torch_cmake_prefix=" + torch.utils.cmake_prefix_path)'
    cmake --version | head -n 1 | sed 's/^/cmake_version=/'
    ninja --version | sed 's/^/ninja_version=/'
    riscv64-linux-gnu-gcc --version | head -n 1 | sed 's/^/c_compiler_version=/'
    riscv64-linux-gnu-g++ --version | head -n 1 | sed 's/^/cxx_compiler_version=/'
} | tee "$OUTPUT/run-environment.txt"

CLEAN_ENV=(
    env
    -u VLLM_CPU_RVV_BF16
    -u VLLM_CPU_ARM_BF16
    -u VLLM_CPU_ARM_I8MM
    -u VLLM_CPU_X86
    -u CMAKE_ARGS
)

run_case() {
    local test_name="$1"
    local vlen="$2"
    local enable_bf16="$3"
    local expected="$4"
    local test_dir="$OUTPUT/$test_name"
    local build_dir="$test_dir/build"
    local exit_code
    local -a cmake_args

    [[ ! -e "$test_dir" ]] || {
        echo "test directory already exists: $test_dir" >&2
        return 1
    }
    mkdir "$test_dir"

    cmake_args=(
        -S "$ROOT"
        -B "$build_dir"
        -G Ninja
        -DVLLM_TARGET_DEVICE=cpu
        -DVLLM_PYTHON_EXECUTABLE="$PYTHON"
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN"
        -DCMAKE_BUILD_TYPE=Release
    )
    if [[ -n "$vlen" ]]; then
        cmake_args+=("-DVLLM_RVV_VLEN=$vlen")
    fi

    {
        echo "test=$test_name"
        echo "VLLM_RVV_VLEN=${vlen:-<unset>}"
        echo "VLLM_CPU_RVV_BF16=$([[ "$enable_bf16" == 1 ]] && echo 1 || echo '<unset>')"
        echo "python=$PYTHON"
        echo "toolchain=$TOOLCHAIN"
        echo "build_type=Release"
        printf 'cmake_arg=%q\n' "${cmake_args[@]}"
    } > "$test_dir/input.txt"

    set +e
    if [[ "$enable_bf16" == 1 ]]; then
        "${CLEAN_ENV[@]}" VLLM_CPU_RVV_BF16=1 \
            cmake "${cmake_args[@]}" 2>&1 | tee "$test_dir/configure.log"
        exit_code="${PIPESTATUS[0]}"
    else
        "${CLEAN_ENV[@]}" \
            cmake "${cmake_args[@]}" 2>&1 | tee "$test_dir/configure.log"
        exit_code="${PIPESTATUS[0]}"
    fi
    set -e

    printf '%s\n' "$exit_code" > "$test_dir/exit_code.txt"
    if [[ "$expected" == success && "$exit_code" -ne 0 ]]; then
        echo "$test_name unexpectedly failed with exit code $exit_code" >&2
        return 1
    fi
    if [[ "$expected" == failure && "$exit_code" -eq 0 ]]; then
        echo "$test_name unexpectedly succeeded" >&2
        return 1
    fi
}

matrix_failed=0
run_case T0-scalar 0 0 success || matrix_failed=1
run_case T1-vlen128 128 0 success || matrix_failed=1
run_case T2-vlen128-bf16 128 1 success || matrix_failed=1
run_case T3-bf16-no-vlen '' 1 failure || matrix_failed=1

echo "utc_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUTPUT/run-environment.txt"
if [[ "$matrix_failed" -ne 0 ]]; then
    echo "matrix completed with unexpected result(s): $OUTPUT" >&2
    exit 1
fi

echo "matrix completed: $OUTPUT"
