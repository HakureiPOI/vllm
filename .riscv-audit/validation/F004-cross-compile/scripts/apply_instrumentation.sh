#!/bin/bash
set -euo pipefail

# F004 cross-compile validation: apply log-only instrumentation to cmake/cpu_extension.cmake
# Does NOT modify any logic, only adds message() calls.

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
CMAKE_FILE="$ROOT/cmake/cpu_extension.cmake"
PATCH_FILE="$ROOT/.riscv-audit/validation/F004-cross-compile/instrumentation/f004-log-only.patch"

cd "$ROOT"

# Create a backup
cp cmake/cpu_extension.cmake cmake/cpu_extension.cmake.bak

# Insert instrumentation messages at strategic points
# 1. After the cat /proc/cpuinfo block (after line 67, before find_isa)
# 2. After the override block (after line 128, before arch detection)
# 3. After MARCH_FLAGS final selection (after line 253)

python3 -c "
import re

with open('cmake/cpu_extension.cmake', 'r') as f:
    content = f.read()

# Insert point 1: after the cat /proc/cpuinfo block, before find_isa
# Find the line with 'find_isa(\${CPUINFO} \"Power11\"' and insert before it
marker1 = 'find_isa(\${CPUINFO} \"Power11\" POWER11_FOUND)'
inst1 = '''# [F004] Instrumentation: host/target info and cpuinfo status
message(STATUS \"[F004] CMAKE_CROSSCOMPILING=\${CMAKE_CROSSCOMPILING}\")
message(STATUS \"[F004] CMAKE_HOST_SYSTEM_NAME=\${CMAKE_HOST_SYSTEM_NAME}\")
message(STATUS \"[F004] CMAKE_HOST_SYSTEM_PROCESSOR=\${CMAKE_HOST_SYSTEM_PROCESSOR}\")
message(STATUS \"[F004] CMAKE_SYSTEM_NAME=\${CMAKE_SYSTEM_NAME}\")
message(STATUS \"[F004] CMAKE_SYSTEM_PROCESSOR=\${CMAKE_SYSTEM_PROCESSOR}\")
message(STATUS \"[F004] CPUINFO_RET=\${CPUINFO_RET}\")
message(STATUS \"[F004] MACOSX_FOUND=\${MACOSX_FOUND}\")

'''
content = content.replace(marker1, inst1 + marker1)

# Insert point 2: after the override block, before arch detection
# Find 'if (CMAKE_SYSTEM_PROCESSOR MATCHES \"x86_64|amd64\"' and insert before it
marker2 = 'if (CMAKE_SYSTEM_PROCESSOR MATCHES \"x86_64|amd64\" OR ENABLE_X86_ISA)'
inst2 = '''# [F004] Instrumentation: capability flags after find_isa and overrides
message(STATUS \"[F004] RVV_FP16_FOUND=\${RVV_FP16_FOUND}\")
message(STATUS \"[F004] RVV_BF16_FOUND=\${RVV_BF16_FOUND}\")
message(STATUS \"[F004] ENABLE_RVV_BF16=\${ENABLE_RVV_BF16}\")
message(STATUS \"[F004] VLLM_RVV_VLEN=\${VLLM_RVV_VLEN}\")

'''
content = content.replace(marker2, inst2 + marker2)

# Insert point 3: after MARCH_FLAGS is set, before the else() FATAL_ERROR
# Find 'message(FATAL_ERROR \"vLLM CPU backend requires' and insert before it
marker3 = 'message(FATAL_ERROR \"vLLM CPU backend requires'
inst3 = '''# [F004] Instrumentation: final MARCH_FLAGS
message(STATUS \"[F004] MARCH_FLAGS=\${MARCH_FLAGS}\")
message(STATUS \"[F004] CXX_COMPILE_FLAGS=\${CXX_COMPILE_FLAGS}\")

'''
content = content.replace(marker3, inst3 + marker3)

with open('cmake/cpu_extension.cmake', 'w') as f:
    f.write(content)

print('Instrumentation applied successfully.')
"

# Generate the patch
git diff -- cmake/cpu_extension.cmake > "$PATCH_FILE"

echo "Patch saved to: $PATCH_FILE"
