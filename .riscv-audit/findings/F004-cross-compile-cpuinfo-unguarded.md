# F004: 交叉编译时 `cat /proc/cpuinfo` 与 `find_isa` 未被守卫

## 1. 问题标题

CMake 在交叉编译时无条件执行 `cat /proc/cpuinfo` 并用其结果设置 RISC-V 能力标志，导致构建主机信息污染目标构建。

## 2. 涉及位置

- `cmake/cpu_extension.cmake:60-67` — 无条件 `cat /proc/cpuinfo`（仅 macOS 豁免）
- `cmake/cpu_extension.cmake:109-110` — `find_isa` 查找 `zvfhmin`/`zvfbfmin`，基于上述 cpuinfo
- `cmake/cpu_extension.cmake:203-204` — VLEN 自动检测**已**守卫 `CMAKE_CROSSCOMPILING`（#47532 修复）

关键代码：

```cmake
# 行 60-67：无条件读 /proc/cpuinfo（仅 macOS 豁免）
if (NOT MACOSX_FOUND)
    execute_process(COMMAND cat /proc/cpuinfo
                    RESULT_VARIABLE CPUINFO_RET
                    OUTPUT_VARIABLE CPUINFO)
    if (NOT CPUINFO_RET EQUAL 0)
        message(FATAL_ERROR "Failed to check CPU features via /proc/cpuinfo")
    endif()
endif()

# 行 109-110：基于构建主机 cpuinfo 设置 RISC-V 标志
find_isa(${CPUINFO} "zvfhmin" RVV_FP16_FOUND)
find_isa(${CPUINFO} "zvfbfmin" RVV_BF16_FOUND)

# 行 203-204：VLEN 检测已守卫（#47532 修复）
if(CMAKE_CROSSCOMPILING)
    message(STATUS "Cross-compiling: skipping VLEN auto-detection from /proc/cpuinfo")
```

## 3. 问题描述

#47532 修复了 VLEN 自动检测的交叉编译问题（行 203-204 加 `CMAKE_CROSSCOMPILING` 守卫），但**未修复**上游的 `cat /proc/cpuinfo`（行 60-67）和 `find_isa` 调用（行 109-110）。

交叉编译时，`CMAKE_SYSTEM_NAME` 反映**目标**系统。若目标为 Linux（riscv64），`MACOSX_FOUND=FALSE`，CMake 在**构建主机**上执行 `cat /proc/cpuinfo`：

- **x86 Linux → riscv64**：`cat /proc/cpuinfo` 成功，返回 x86 cpuinfo。`find_isa("zvfhmin")` / `find_isa("zvfbfmin")` 在 x86 cpuinfo 中找不到 → `RVV_FP16_FOUND=OFF` / `RVV_BF16_FOUND=OFF`。结果"正确但出于偶然"——因为 x86 cpuinfo 不含 RISC-V 字符串，而非因为正确检测了目标能力。
- **macOS → riscv64**：`cat /proc/cpuinfo` 失败（macOS 无 `/proc/cpuinfo`）→ `FATAL_ERROR`。**构建失败。**

## 4. 触发条件

- 交叉编译到 RISC-V（`CMAKE_SYSTEM_PROCESSOR=riscv64`，`CMAKE_CROSSCOMPILING=TRUE`）
- 构建主机为 macOS：直接 FATAL_ERROR
- 构建主机为 x86 Linux：`RVV_FP16_FOUND`/`RVV_BF16_FOUND` 被设为 OFF（正确但出于偶然），用户需手动设 `VLLM_CPU_RVV_BF16=1` 和 `VLLM_RVV_VLEN=128/256`

## 5. 调用链与证据

```
cmake -DCMAKE_SYSTEM_PROCESSOR=riscv64 ...
  → execute_process(cat /proc/cpuinfo)     [行 61-63]  ← 构建主机 cpuinfo
    → macOS: 失败 → FATAL_ERROR           [行 65]
    → x86: 成功，CPUINFO = x86 cpuinfo
  → find_isa(CPUINFO, "zvfhmin")          [行 109]    ← 在 x86 cpuinfo 中查找
    → RVV_FP16_FOUND = OFF
  → find_isa(CPUINFO, "zvfbfmin")         [行 110]    ← 在 x86 cpuinfo 中查找
    → RVV_BF16_FOUND = OFF
  → if(CMAKE_CROSSCOMPILING) skip VLEN    [行 203]    ← #47532 修复，正确跳过
  → if(NOT DEFINED VLLM_RVV_VLEN AND (RVV_FP16_FOUND OR RVV_BF16_FOUND))  [行 226]
    → 两者均 OFF，不触发 FATAL_ERROR
  → scalar build                           [行 249-252]
```

### #47532 修复范围

#47532（MERGED）仅在行 203 加了 `CMAKE_CROSSCOMPILING` 守卫，**未**守卫行 60-67 和行 109-110。

## 6. 潜在影响

- **macOS 交叉编译失败**：`FATAL_ERROR` 阻断构建。
- **x86 交叉编译静默降级**：即使目标支持 RVV，也产出 scalar 二进制，用户需手动设环境变量。
- **设计不一致**：VLEN 检测已守卫交叉编译，但能力检测（FP16/BF16）未守卫，同一问题域修复不完整。

## 7. 去重检查

- **调研文档**：案例 A3（#47532 第②点）记录了交叉编译读构建主机 cpuinfo 的问题。#47532 修复了 VLEN 检测部分，但**未修复** `cat /proc/cpuinfo` 和 `find_isa` 部分。本发现是 A3 的**残留**，非重复。
- **当前分支**：行 60-67 和 109-110 确认未守卫 `CMAKE_CROSSCOMPILING`。
- **ARM 同类问题**：`find_isa("asimd")` / `find_isa("bf16")` / `find_isa("i8mm")` 也读同一 CPUINFO，交叉编译到 ARM 同样受影响。本发现聚焦 RISC-V，但修复应一并覆盖 ARM。

## 8. 可信度

**中**。macOS 交叉编译 FATAL_ERROR 路径明确（高可信度）。x86 交叉编译静默降级路径明确但"正确出于偶然"（中可信度）。实际影响取决于用户是否常用 macOS 作为 RISC-V 交叉编译主机。

## 9. 验证建议

1. 在 macOS 上配置 RISC-V 交叉编译工具链，运行 `cmake -DCMAKE_SYSTEM_PROCESSOR=riscv64 ...`，确认是否 FATAL_ERROR。
2. 在 x86 Linux 上交叉编译，检查 `RVV_FP16_FOUND`/`RVV_BF16_FOUND` 是否为 OFF。
3. 检查 vLLM CI 是否有 macOS 交叉编译 RISC-V 的用例（预计无）。

## 10. 修复思路

在 `cat /proc/cpuinfo` 和 `find_isa` 调用前加 `CMAKE_CROSSCOMPILING` 守卫：

```cmake
if (NOT MACOSX_FOUND AND NOT CMAKE_CROSSCOMPILING)
    execute_process(COMMAND cat /proc/cpuinfo ...)
    ...
endif()

# find_isa 调用也应在非交叉编译时执行
if (NOT CMAKE_CROSSCOMPILING)
    find_isa(${CPUINFO} "zvfhmin" RVV_FP16_FOUND)
    find_isa(${CPUINFO} "zvfbfmin" RVV_BF16_FOUND)
    find_isa(${CPUINFO} "asimd" ASIMD_FOUND)
    # ... 其他 find_isa 调用
endif()
```

交叉编译时，所有 `*_FOUND` 变量保持 OFF，用户通过环境变量（`VLLM_CPU_RVV_BF16` 等）显式指定。

### 修复范围

- 改动文件：`cmake/cpu_extension.cmake`
- 改动行数：约 10-15 行（加守卫 + 调整缩进）
- 影响所有架构的交叉编译路径（ARM/PowerPC/S390X 同样受益）
- 可补充 CI 测试（若有 macOS 交叉编译环境）
