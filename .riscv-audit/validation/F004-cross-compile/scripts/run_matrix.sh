#!/bin/bash
set -euo pipefail

# F004 cross-compile validation: run test matrix T0-T3
# Each test uses a fresh build directory.

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
VALIDATION="$ROOT/.riscv-audit/validation/F004-cross-compile"
TOOLCHAIN="$VALIDATION/toolchains/riscv64-linux-gnu.cmake"
PYTHON_EXECUTABLE="$ROOT/../.venv-vllm-f004/bin/python"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS="$VALIDATION/results/$STAMP"

mkdir -p "$RESULTS"

echo "=== F004 Cross-Compile Validation Matrix ==="
echo "Timestamp: $STAMP"
echo "ROOT: $ROOT"
echo "PYTHON: $PYTHON_EXECUTABLE"
echo "RESULTS: $RESULTS"
echo ""

# --- T0: scalar control ---
echo ">>> T0: VLLM_RVV_VLEN=0 (scalar control)"
mkdir -p "$RESULTS/T0-scalar"
set +e
env -u VLLM_CPU_RVV_BF16 \
cmake -S "$ROOT" -B "$RESULTS/T0-scalar/build" -G Ninja \
  -DVLLM_TARGET_DEVICE=cpu \
  -DVLLM_PYTHON_EXECUTABLE="$PYTHON_EXECUTABLE" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DVLLM_RVV_VLEN=0 \
  -DCMAKE_BUILD_TYPE=Release \
  2>&1 | tee "$RESULTS/T0-scalar/configure.log"
echo "${PIPESTATUS[0]}" > "$RESULTS/T0-scalar/exit_code.txt"
set -e
echo "T0 exit code: $(cat "$RESULTS/T0-scalar/exit_code.txt")"
echo ""

# --- T1: core suspect scenario ---
echo ">>> T1: VLLM_RVV_VLEN=128 (core suspect)"
mkdir -p "$RESULTS/T1-vlen128"
set +e
env -u VLLM_CPU_RVV_BF16 \
cmake -S "$ROOT" -B "$RESULTS/T1-vlen128/build" -G Ninja \
  -DVLLM_TARGET_DEVICE=cpu \
  -DVLLM_PYTHON_EXECUTABLE="$PYTHON_EXECUTABLE" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DVLLM_RVV_VLEN=128 \
  -DCMAKE_BUILD_TYPE=Release \
  --trace-source="$ROOT/cmake/cpu_extension.cmake" \
  --trace-expand \
  2>&1 | tee "$RESULTS/T1-vlen128/configure.log"
echo "${PIPESTATUS[0]}" > "$RESULTS/T1-vlen128/exit_code.txt"
set -e
echo "T1 exit code: $(cat "$RESULTS/T1-vlen128/exit_code.txt")"
echo ""

# --- T2: BF16 override positive control ---
echo ">>> T2: VLLM_RVV_VLEN=128 + VLLM_CPU_RVV_BF16=1 (BF16 override)"
mkdir -p "$RESULTS/T2-vlen128-bf16"
set +e
VLLM_CPU_RVV_BF16=1 \
cmake -S "$ROOT" -B "$RESULTS/T2-vlen128-bf16/build" -G Ninja \
  -DVLLM_TARGET_DEVICE=cpu \
  -DVLLM_PYTHON_EXECUTABLE="$PYTHON_EXECUTABLE" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DVLLM_RVV_VLEN=128 \
  -DCMAKE_BUILD_TYPE=Release \
  2>&1 | tee "$RESULTS/T2-vlen128-bf16/configure.log"
echo "${PIPESTATUS[0]}" > "$RESULTS/T2-vlen128-bf16/exit_code.txt"
set -e
echo "T2 exit code: $(cat "$RESULTS/T2-vlen128-bf16/exit_code.txt")"
echo ""

# --- T3: BF16 without VLEN ---
echo ">>> T3: VLLM_CPU_RVV_BF16=1, no VLEN (expect FATAL_ERROR)"
mkdir -p "$RESULTS/T3-bf16-no-vlen"
set +e
VLLM_CPU_RVV_BF16=1 \
cmake -S "$ROOT" -B "$RESULTS/T3-bf16-no-vlen/build" -G Ninja \
  -DVLLM_TARGET_DEVICE=cpu \
  -DVLLM_PYTHON_EXECUTABLE="$PYTHON_EXECUTABLE" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_BUILD_TYPE=Release \
  2>&1 | tee "$RESULTS/T3-bf16-no-vlen/configure.log"
echo "${PIPESTATUS[0]}" > "$RESULTS/T3-bf16-no-vlen/exit_code.txt"
set -e
echo "T3 exit code: $(cat "$RESULTS/T3-bf16-no-vlen/exit_code.txt")"
echo ""

echo "=== Test matrix complete ==="
echo "Results in: $RESULTS"
