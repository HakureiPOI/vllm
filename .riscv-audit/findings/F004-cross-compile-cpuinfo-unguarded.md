# F004: RISC-V 交叉编译使用构建主机 /proc/cpuinfo 判断目标 FP16/BF16 能力，可能导致 RVV 配置失败或用户显式请求的 RVV 配置生成标量编译命令

> 状态：场景 B `confirmed`（仅配置阶段）；场景 A `not tested`；正式修复尚未设计。

## 1. 问题标题

CMake 在交叉编译时无条件执行 `cat /proc/cpuinfo` 并用其结果设置 RISC-V FP16/BF16 能力标志，导致构建主机信息污染目标构建配置。

## 2. 涉及位置

- `cmake/cpu_extension.cmake:60-67` — 无条件 `cat /proc/cpuinfo`（仅 macOS 豁免）
- `cmake/cpu_extension.cmake:109-110` — `find_isa` 查找 `zvfhmin`/`zvfbfmin`，基于上述 cpuinfo
- `cmake/cpu_extension.cmake:19` — `ENABLE_RVV_BF16` 环境变量（BF16 override）
- `cmake/cpu_extension.cmake:122-128` — BF16 override 逻辑
- `cmake/cpu_extension.cmake:200-232` — VLEN 自动检测（已守卫 `CMAKE_CROSSCOMPILING`）
- `cmake/cpu_extension.cmake:234-252` — MARCH_FLAGS 选择逻辑

## 3. 问题描述

### 变量传播链

```
构建主机 /proc/cpuinfo
  → CPUINFO 变量 (行 62)
  → find_isa(CPUINFO, "zvfhmin") → RVV_FP16_FOUND (行 109)
  → find_isa(CPUINFO, "zvfbfmin") → RVV_BF16_FOUND (行 110)
  → if(RVV_BF16_FOUND) → MARCH_FLAGS = rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl${VLLM_RVV_VLEN}b (行 239-241)
  → elseif(RVV_FP16_FOUND) → MARCH_FLAGS = rv64gcv_zvfh_zvl${VLLM_RVV_VLEN}b (行 242-244)
  → else() → MARCH_FLAGS = rv64gc (行 246-247) ← 标量！
  → list(APPEND CXX_COMPILE_FLAGS ${MARCH_FLAGS}) (行 253)
  → RVV 优化代码是否被编译取决于 -march 中是否含 v/zvfh/zvfbfmin
```

### 已确认事实

- `cat /proc/cpuinfo`（行 60-67）在 `NOT MACOSX_FOUND` 时无条件执行，不检查 `CMAKE_CROSSCOMPILING`。
- `find_isa`（行 109-110）使用上述 cpuinfo 结果设置 `RVV_FP16_FOUND` 和 `RVV_BF16_FOUND`。
- VLEN 自动检测（行 200-232）**已**守卫 `CMAKE_CROSSCOMPILING`（#47532 修复），但 `cat /proc/cpuinfo` 和 `find_isa` **未**守卫。
- BF16 有 `VLLM_CPU_RVV_BF16` 环境变量 override（行 19, 122-128）。
- FP16 **无**显式 override 环境变量。

### 场景区分

#### 场景 A：macOS 主机 → riscv64-linux 交叉编译

**动态状态：not tested。** 以下结果来自静态变量传播分析。

- `CMAKE_SYSTEM_NAME = "Linux"`（目标系统），`MACOSX_FOUND = FALSE`。
- `cat /proc/cpuinfo` 在 macOS 上失败（无 `/proc/cpuinfo`）。
- `CPUINFO_RET != 0` → `FATAL_ERROR "Failed to check CPU features via /proc/cpuinfo"`（行 65）。
- **后果**：构建失败，无法配置。

#### 场景 B：x86 Linux 主机 → riscv64-linux 交叉编译

**动态状态：confirmed（配置阶段）。**

- `CMAKE_SYSTEM_NAME = "Linux"`，`MACOSX_FOUND = FALSE`。
- `cat /proc/cpuinfo` 成功，返回 x86 cpuinfo。
- `find_isa(CPUINFO, "zvfhmin")` → x86 cpuinfo 中无此字符串 → `RVV_FP16_FOUND = OFF`。
- `find_isa(CPUINFO, "zvfbfmin")` → x86 cpuinfo 中无此字符串 → `RVV_BF16_FOUND = OFF`。
- VLEN 自动检测被 `CMAKE_CROSSCOMPILING` 守卫跳过（行 203-204）。
- 若用户设 `-DVLLM_RVV_VLEN=128`：
  - `VLLM_RVV_VLEN > 0` → 进入行 234 分支。
  - `RVV_BF16_FOUND = OFF` → 跳过行 239。
  - `RVV_FP16_FOUND = OFF` → 跳过行 242。
  - `else()` → `MARCH_FLAGS = -march=rv64gc`（行 246-247）← **标量！**
  - 即使设了 `VLLM_RVV_VLEN=128`，vLLM `_C` 目标仍生成使用 `-march=rv64gc` 的编译命令。
- 若用户额外设 `VLLM_CPU_RVV_BF16=1`：
  - `RVV_BF16_FOUND = ON`（行 126）。
  - `MARCH_FLAGS = rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl128b`（行 241）。
  - 包含 `zvfh`，FP16 也被启用。
  - **动态观察**：该 override 将 `RVV_BF16_FOUND` 设为 ON；vLLM `_C` 和 `dnnl_ext` 生成包含 `v`、`zvfh`、`zvfbfmin` 和 VLEN=128 的编译命令。
- 若用户只设 `VLLM_RVV_VLEN=128` 但不设 `VLLM_CPU_RVV_BF16=1`：
  - **动态观察**：用户显式请求了 RVV（`VLLM_RVV_VLEN=128`），但 vLLM `_C` 目标仍生成 `-march=rv64gc` 编译命令。未实际编译或检查目标二进制。

#### 场景 C：未声明目标扩展能力时的标量默认行为

用户未提供目标 VLEN、FP16、BF16 或完整目标 ISA。构建系统最终选择 `rv64gc`。

- `VLLM_RVV_VLEN` 未定义，`CMAKE_CROSSCOMPILING` 跳过自动检测。
- `RVV_FP16_FOUND = OFF`，`RVV_BF16_FOUND = OFF`。
- 行 226 条件 `NOT DEFINED VLLM_RVV_VLEN AND (RVV_FP16_FOUND OR RVV_BF16_FOUND)` → 两者均 OFF → 不触发 FATAL_ERROR。
- `VLLM_RVV_VLEN` 未定义 → 行 234 条件 `VLLM_RVV_VLEN AND VLLM_RVV_VLEN GREATER 0` → FALSE。
- 进入 `else()` → `MARCH_FLAGS = -march=rv64gc`（行 250-251）。

该行为本身**不作为 F004 的缺陷证据**，因为构建系统缺少足够信息，无法安全假设目标硬件支持 RVV。选择标量 `rv64gc` 是未声明目标扩展时的安全默认行为。

该场景反映的是交叉编译配置接口和提示信息仍可改进：构建系统可以更明确地提示用户如何声明目标 RVV 能力，但不能仅凭未启用 RVV 就认定为错误。

### FP16 override 缺失

当前 CMake 中：
- BF16 有 `VLLM_CPU_RVV_BF16` 环境变量 override（行 19）。
- FP16 **无**对应的环境变量 override。
- 用户若只想启用 FP16（不含 BF16），交叉编译时无法通过环境变量实现。
- BF16 override 会同时启用 FP16（因为 `-march` 包含 `zvfh`），但这不是显式的 FP16 override。

### BF16 override 覆盖范围

`VLLM_CPU_RVV_BF16=1` 在以下场景有效：
- 场景 B（x86 → riscv64）：配置阶段已动态确认会选择包含 `v`、`zvfh`、`zvfbfmin` 和 VLEN=128 的 `MARCH_FLAGS`。
- 场景 A（macOS → riscv64）：无效，因为 `cat /proc/cpuinfo` 在 override 之前就 FATAL_ERROR。

## 4. 触发条件

- 交叉编译到 RISC-V（`CMAKE_SYSTEM_PROCESSOR=riscv64`，`CMAKE_CROSSCOMPILING=TRUE`）。
- 场景 A（macOS 主机）：直接 FATAL_ERROR。
- 场景 B（x86 Linux 主机）：用户已显式设置 `VLLM_RVV_VLEN>0`，但 `RVV_FP16_FOUND`/`RVV_BF16_FOUND` 仍被宿主机 cpuinfo 决定为 OFF，最终选择 `rv64gc`。

## 5. 调用链与证据

见上方"变量传播链"和"场景区分"。

### #47532 修复范围

#47532（MERGED）仅在行 203 加了 `CMAKE_CROSSCOMPILING` 守卫，**未**守卫行 60-67 和行 109-110。本发现是 #47532 修复的残留部分。

## 6. 潜在影响

- **macOS 宿主机交叉编译可能在配置阶段失败**：`FATAL_ERROR` 阻断构建配置。
- **用户已显式设置 `VLLM_RVV_VLEN` 时，FP16/BF16 能力仍被宿主机 cpuinfo 错误决定**：场景 B 已观察到 vLLM `_C` 生成 `-march=rv64gc` 编译命令，即使用户已请求 RVV。
- **目标基础架构、目标可选扩展和宿主机自动探测没有被清晰分层**：VLEN 检测已守卫交叉编译，但能力检测（FP16/BF16）未守卫，同一问题域修复不完整。

用户未声明任何目标 RVV 能力而得到标量构建的情况，不属于核心缺陷影响，最多属于配置可用性问题（缺少告警或说明）。

## 7. 去重检查

- **调研文档**：案例 A3（#47532 第②点）记录了交叉编译读构建主机 cpuinfo 的问题。#47532 修复了 VLEN 检测部分，但**未修复** `cat /proc/cpuinfo` 和 `find_isa` 部分。本发现是 A3 的**残留**，非重复。
- **当前分支**：行 60-67 和 109-110 确认未守卫 `CMAKE_CROSSCOMPILING`。
- **ARM 同类问题**：`find_isa("asimd")` / `find_isa("bf16")` / `find_isa("i8mm")` 也读同一 CPUINFO，交叉编译到 ARM 同样受影响。本发现聚焦 RISC-V，但修复设计需考虑跨架构影响。

## 8. 可信度

```
变量传播链可信度：高
x86 Linux → riscv64 配置复现可信度：高
完整编译与目标运行：未验证
macOS 场景 A：未验证
```

**变量传播链可信度（高）**：源码变量传播链已经明确，`cat /proc/cpuinfo` → `find_isa` → `RVV_FP16_FOUND`/`RVV_BF16_FOUND` → `MARCH_FLAGS` 选择路径可从源码直接追踪。

**x86 Linux → riscv64 配置复现可信度（高）**：真实 vLLM CMake 入口记录了 host/target/cross-compiling 状态、能力变量和 VLEN，并由 target-attributed `compile_commands.json` 证明 `_C`/`dnnl_ext` 的生成命令。该结论不扩展到实际编译、链接、目标运行或性能。

## 9. 动态验证证据

- 验证目录：`.riscv-audit/validation/F004-cross-compile/`
  （[README](../validation/F004-cross-compile/README.md) / [REPORT](../validation/F004-cross-compile/REPORT.md)）
- 第一版证据提交：`16659b79de18595dcf17072dfc3486fb948f2a73`
- 整改后证据提交：`594917a9a9ba082bae1431fbd6b2bd96771dfd4b`
- 第一轮结果：`results/20260729T074037Z`

核心动态观察：

- T1：x86_64 host、riscv64 target、`CMAKE_CROSSCOMPILING=TRUE`、`VLLM_RVV_VLEN=128`、FP16/BF16 均为 OFF；12 条 vLLM `_C` 命令均使用 `-march=rv64gc`。
- T2：唯一影响配置语义的输入差异为 `VLLM_CPU_RVV_BF16=1`；14 条 `_C` 和 1 条 `dnnl_ext` 命令均使用 `-march=rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl128b -mrvv-vector-bits=zvl -mabi=lp64d`。
- T2 中另有 170 条 oneDNN 或其子构建命令使用 `-march=rv64gc`；这些命令不属于 vLLM `_C`/`dnnl_ext`，原因未在本轮分析，不纳入 F004 结论。
- T3 的完整日志记录了预期 VLEN `FATAL_ERROR`。

限制：

- 仅验证配置生成阶段；
- 未执行真实编译、链接或目标运行；
- 未生成或检查目标二进制；
- 未验证性能影响；
- 未验证 VLEN=256；
- 未验证 macOS 场景 A；
- 未验证所有 RISC-V 交叉编译环境。

## 10. 后续验证建议

1. 在 macOS 上配置 RISC-V 交叉编译工具链，确认场景 A 是否在 `/proc/cpuinfo` 检查处失败。
2. 最小编译一个 `_C` 对象，验证配置生成的 T1/T2 flags 能被交叉编译器实际执行。
3. 单独验证 VLEN=256；不得从本次 VLEN=128 结果外推。

## 11. 修复思路

### 设计约束

不得简单将所有 `find_isa()` 放入 `if(NOT CMAKE_CROSSCOMPILING)`，因为 ARM、PowerPC、S390 的架构分支选择也依赖这些变量。全部设为 OFF 可能导致交叉编译直接落入"不支持的 CPU backend"（行 255 FATAL_ERROR）。

修复设计应区分三个层次：

### 层次 1：目标基础架构识别

通过 `CMAKE_SYSTEM_PROCESSOR` 识别目标基础架构（`riscv64`、`aarch64`、`x86_64` 等）。这是已有逻辑，不受交叉编译影响。

### 层次 2：目标可选扩展配置

交叉编译时，用户需通过以下方式之一显式声明目标扩展能力：

#### 方案 A：增加显式 CMake 参数

```cmake
set(VLLM_RVV_FP16 $ENV{VLLM_CPU_RVV_FP16})
set(VLLM_RVV_BF16 $ENV{VLLM_CPU_RVV_BF16})  # 已有
# 交叉编译时，find_isa 跳过，用户通过环境变量指定
if(CMAKE_CROSSCOMPILING)
    if(VLLM_RVV_FP16) set(RVV_FP16_FOUND ON) endif()
    if(VLLM_RVV_BF16) set(RVV_BF16_FOUND ON) endif()
endif()
```

优点：与现有 `VLLM_CPU_RVV_BF16` 模式一致，用户熟悉。
缺点：需为每个扩展添加独立参数，扩展数量多时不便。

#### 方案 B：允许显式提供完整目标 -march

```cmake
set(VLLM_RVV_MARCH $ENV{VLLM_CPU_RVV_MARCH})
if(VLLM_RVV_MARCH)
    set(MARCH_FLAGS -march=${VLLM_RVV_MARCH} -mabi=lp64d)
endif()
```

优点：用户可一次性指定完整 `-march`（如 `rv64gcv_zvfh_zvfbfmin_zvl128b`），无需逐个扩展配置。
缺点：用户需了解目标 `-march` 字符串的完整语法。

#### 方案 C：交叉编译时禁止宿主机探测，要求显式声明目标能力

当前方案 C 的简单判断 `if(NOT DEFINED VLLM_RVV_VLEN AND NOT VLLM_RVV_MARCH)` 不足以避免 F004：用户只设置 `VLLM_RVV_VLEN=128` 时条件已通过，但没有 FP16/BF16 目标能力信息，后续仍可能选择 `rv64gc`。

重新设计为支持以下三种模式：

##### 模式 1：显式标量构建

```text
VLLM_RVV_VLEN=0
```

表示用户明确请求标量 RISC-V 构建。

##### 模式 2：显式完整目标 ISA

```text
VLLM_RVV_MARCH=<完整 march>
```

例如：

```text
rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl256b
```

此时直接使用用户提供的目标 ISA，不读取宿主机 cpuinfo。

##### 模式 3：结构化声明 RVV 能力

用户必须同时提供：

```text
VLLM_RVV_VLEN > 0
```

以及至少一种目标扩展能力，例如：

```text
VLLM_RVV_FP16=1
VLLM_RVV_BF16=1
```

构建系统再据此生成目标 `-march`。

##### 伪代码

```cmake
if(CMAKE_CROSSCOMPILING)
    if(DEFINED VLLM_RVV_MARCH)
        # 模式 2：使用完整目标 ISA
        set(MARCH_FLAGS -march=${VLLM_RVV_MARCH} -mabi=lp64d)
    elseif(DEFINED VLLM_RVV_VLEN AND VLLM_RVV_VLEN EQUAL 0)
        # 模式 1：用户明确请求 scalar
        set(MARCH_FLAGS -march=rv64gc)
    elseif(DEFINED VLLM_RVV_VLEN AND VLLM_RVV_VLEN GREATER 0
           AND (VLLM_RVV_FP16 OR VLLM_RVV_BF16))
        # 模式 3：根据显式目标扩展构造 -march
        if(VLLM_RVV_BF16)
            set(MARCH_FLAGS -march=rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl${VLLM_RVV_VLEN}b ...)
        elseif(VLLM_RVV_FP16)
            set(MARCH_FLAGS -march=rv64gcv_zvfh_zvl${VLLM_RVV_VLEN}b ...)
        endif()
    else()
        message(FATAL_ERROR
            "RISC-V cross-compilation requires either an explicit "
            "VLLM_RVV_MARCH, VLLM_RVV_VLEN=0 for scalar, or "
            "VLLM_RVV_VLEN>0 with explicit FP16/BF16 target capability")
    endif()
else()
    # 本机构建：自动探测
    execute_process(COMMAND cat /proc/cpuinfo ...)
    find_isa(...)
endif()
```

优点：覆盖"只设置 VLEN 仍生成标量"的问题；强制用户在交叉编译时显式声明目标扩展能力。
缺点：用户体验略差，但交叉编译本就需显式配置。

### 推荐

方案 C 最安全（强制显式声明，避免用户显式请求 RVV 后仍生成标量编译命令），可结合方案 A（添加 `VLLM_CPU_RVV_FP16`）或方案 B（添加 `VLLM_RVV_MARCH`）提供配置接口。

### 与 ARM/PowerPC/S390 的关系

修复应区分：
- `CMAKE_SYSTEM_PROCESSOR`（目标基础架构，不受交叉编译影响）→ 用于选择架构分支（行 131-256）。
- `find_isa` 结果（目标可选扩展，交叉编译时不应读宿主机）→ 用于设置 `*_FOUND` 变量。
- 交叉编译时，`*_FOUND` 变量应通过显式参数设置，而非 `find_isa`。

ARM 的 `find_isa("asimd")` / `find_isa("bf16")` / `find_isa("i8mm")` 同样应受 `CMAKE_CROSSCOMPILING` 守卫，但 ARM 已有 `VLLM_CPU_ARM_BF16` / `VLLM_CPU_ARM_I8MM` override（行 113-121）。RISC-V 的 FP16 缺少对应 override。

正式修复设计尚未收口；本次状态更新不实现修复。
