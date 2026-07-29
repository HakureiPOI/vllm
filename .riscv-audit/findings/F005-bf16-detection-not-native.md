# F005: BF16 能力检测未迁移到 native probe

## 1. 问题标题

RISC-V BF16 能力检测仍依赖 `/proc/cpuinfo` 的 `zvfbfmin` 字符串和环境变量 override，未像 RVV 检测那样迁移到 C++ 编译期 native probe。

## 2. 涉及位置

- `cmake/cpu_extension.cmake:110` — `find_isa(${CPUINFO} "zvfbfmin" RVV_BF16_FOUND)`
- `cmake/cpu_extension.cmake:122-128` — `VLLM_CPU_RVV_BF16` 环境变量 override
- `cmake/cpu_extension.cmake:239-241` — 基于 `RVV_BF16_FOUND` 选择 `-march` 标志

关键代码：

```cmake
# 行 110：从 /proc/cpuinfo 检测 zvfbfmin
find_isa(${CPUINFO} "zvfbfmin" RVV_BF16_FOUND)

# 行 122-128：手动 override
if (ENABLE_RVV_BF16)
    set(RVV_BF16_FOUND ON)
    message(STATUS "RVV BF16 support enabled via VLLM_CPU_RVV_BF16 environment variable")
endif()

# 行 239-241：基于检测结果选择 -march
if(RVV_BF16_FOUND)
    set(MARCH_FLAGS -march=rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl${VLLM_RVV_VLEN}b ...)
```

## 3. 问题描述

RVV 能力检测已部分迁移到 native probe（`cpu_attn_has_isa("rvv")` 检查 `__riscv_v_min_vlen`），但 BF16 能力检测仍完全依赖：

1. `/proc/cpuinfo` 中查找 `zvfbfmin` 字符串（行 110）
2. `VLLM_CPU_RVV_BF16=1` 环境变量 override（行 125-127）

Spacemit X100/K3 的内核/固件不在 `/proc/cpuinfo` 报告 `zvfbfmin`（尽管硬件支持），导致 BF16 被静默禁用。用户必须手动设 `VLLM_CPU_RVV_BF16=1`，且该 override 是 unchecked（不验证硬件是否真的支持）。

## 4. 触发条件

- RISC-V 架构，VLEN=256（Spacemit X100/K3）
- 硬件支持 BF16（`zvfbfmin` 扩展）
- `/proc/cpuinfo` 不报告 `zvfbfmin`（X100/K3 内核/固件限制）
- 用户未设 `VLLM_CPU_RVV_BF16=1`

## 5. 调用链与证据

```
cmake -DVLLM_RVV_VLEN=256 ...
  → cat /proc/cpuinfo                        [行 61]
  → find_isa(CPUINFO, "zvfbfmin")            [行 110]
    → X100: "zvfbfmin" 不在 cpuinfo 中
    → RVV_BF16_FOUND = OFF
  → if(ENABLE_RVV_BF16)                     [行 125]
    → 用户未设 VLLM_CPU_RVV_BF16=1
    → 跳过
  → if(RVV_BF16_FOUND)                      [行 239]
    → OFF → 走 elseif(RVV_FP16_FOUND)       [行 242]
    → -march=rv64gcv_zvfh_zvl256b ...（无 zvfbfmin）
  → __riscv_zvfbfmin 未定义
    → BF16Vec8/16 走 FP32 模拟回退路径     [cpu_types_riscv_impl.hpp:247-393]
    → 性能损失，无功能错误
```

### #45243 背景

#45243（MERGED）添加了 `VLLM_CPU_RVV_BF16` 环境变量 override 作为 workaround。但这是手动 override，不是 native probe。

### 与 RVV 检测的对比

| 能力 | 检测方式 | native probe | /proc/cpuinfo 依赖 |
|---|---|---|---|
| RVV | `cpu_attn_has_isa("rvv")` 检查 `__riscv_v_min_vlen` | 是（C++ 编译期） | 部分（fallback，见 F003） |
| BF16 | `find_isa(CPUINFO, "zvfbfmin")` + 环境变量 | 否 | 完全依赖 |

## 6. 潜在影响

- **静默性能损失**：BF16 走 FP32 模拟回退路径，性能下降（多次 `vle32`/`vse32` + 标量 `bf16_to_float`/`float_to_bf16` 转换）。
- **无功能错误**：FP32 模拟回退路径数值正确，仅性能损失。
- **用户体验**：用户需知道设 `VLLM_CPU_RVV_BF16=1`，否则 BF16 性能受损且无告警。

## 7. 去重检查

- **调研文档**：案例 A 背景材料（#45243）记录了 BF16 检测问题。调研文档"Open Questions"第 3 点提到"BF16 是否也应有等价的 native 编译期探测"。
- **当前分支**：BF16 检测确认仍用 `/proc/cpuinfo` + 环境变量。
- **#48487 关系**：#48487 仅修复 RVV 的 `/proc/cpuinfo` 依赖（F003），未覆盖 BF16。本发现是 BF16 的同类问题。

## 8. 可信度

**中**。代码确认 BF16 检测依赖 `/proc/cpuinfo`。X100 不报 `zvfbfmin` 有 #45243 明确记录。但"native probe 可行性"未验证——需确认 `__riscv_zvfbfmin` 宏是否在 CMake 检测阶段可用（CMake 不编译 C++ 代码检查宏，需用 `try_compile` 或等价机制）。

## 9. 验证建议

1. 在 Spacemit X100 上检查 `/proc/cpuinfo` 是否含 `zvfbfmin`（预计无）。
2. 确认 `__riscv_zvfbfmin` 宏在 `-march=...zvfbfmin...` 时由 GCC/Clang 自动定义（预计是）。
3. 评估 CMake `try_compile` 检测 `__riscv_zvfbfmin` 的可行性。

## 10. 修复思路

### 方案 A：CMake `try_compile` 检测

在 `cpu_extension.cmake` 中用 `try_compile` 编译一个小程序检查 `__riscv_zvfbfmin`：

```cmake
include(CheckCXXSourceCompiles)
set(CMAKE_REQUIRED_FLAGS "-march=rv64gcv_zvfbfmin_zvl${VLLM_RVV_VLEN}b")
check_cxx_source_compiles("
  #ifndef __riscv_zvfbfmin
  #error
  #endif
  int main() { return 0; }
" RVV_BF16_COMPILER_SUPPORTED)
```

但这有鸡生蛋问题：需要先设 `-march` 才能检查 `__riscv_zvfbfmin`，而 `-march` 的选择又依赖 `RVV_BF16_FOUND`。

### 方案 B：运行时 native probe（类似 RVV）

在 `cpu_attn.cpp` 的 `cpu_attn_has_isa` 中添加 `"bf16"` 检查：

```cpp
if (isa == "bf16") {
#if defined(__riscv) && defined(__riscv_zvfbfmin)
    return true;
#else
    return false;
#endif
}
```

Python 端添加 `_riscv_supports_bf16()` 函数，类似 `_riscv_supports_rvv()`，仅信 native probe，fail-closed。

### 方案 C：保持现状 + 告警

在 `RVV_BF16_FOUND=OFF` 但 `VLLM_RVV_VLEN>0` 时，输出 `WARNING` 提示用户可能需要设 `VLLM_CPU_RVV_BF16=1`。

### 推荐

方案 B 最符合现有设计（与 RVV 检测一致），但改动范围较大（需修改 C++ 和 Python）。方案 C 最小化改动，可作为短期缓解。本发现暂不提出具体 PR，待 #48487（F003）合并后再评估 BF16 检测的迁移。
