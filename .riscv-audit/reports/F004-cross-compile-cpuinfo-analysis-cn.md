# F004：RISC-V 交叉编译中 host `/proc/cpuinfo` 污染目标能力判断的技术分析

## 文档信息与结论标识

| 项目 | 内容 |
|---|---|
| 审计分支 | `audit/riscv` |
| 源码审计与实验基线 | `57f327ef9c827788c85c0a69c0cf86e446ff27ae` |
| 第一版动态证据 | `16659b79de18595dcf17072dfc3486fb948f2a73` |
| 证据整改 | `594917a9a9ba082bae1431fbd6b2bd96771dfd4b` |
| finding/STATUS 收口 | `a0cec6afe5c412e12ab100582cd148efb0ef9586` |
| 当前判定 | **F004 场景 B 已在 CMake 配置阶段动态确认** |
| 不在本结论内 | 编译、链接、wheel、目标运行、性能、VLEN=256、macOS 场景 A |

本文是对 [F004 finding](../findings/F004-cross-compile-cpuinfo-unguarded.md)、[验证说明](../validation/F004-cross-compile/README.md)、[动态验证报告](../validation/F004-cross-compile/REPORT.md)及原始结果的综合技术归档。为避免循环论证，本文把“源码确认”“动态观察”“基于证据的解释”“尚未验证”和“修复设计建议”分开陈述。

本文面向项目内部归档、修复设计评审以及与上游提交者沟通。读者可以先看执行摘要和第 10 节掌握结论边界，再通过第 4、8、9 节回溯源码与原始实验文件；第 11、12 节只整理决策空间和待确认问题，不代表已经批准的实现方案。

## 1. 执行摘要

F004 是一个交叉编译配置中的 host/target 信息混淆问题。源码基线 `57f327e...` 在非 macOS 目标配置中执行 `cat /proc/cpuinfo`，再用其中的 `zvfhmin`、`zvfbfmin` 字符串设置 RISC-V Vector（RVV）FP16/BF16 能力变量。CMake 的 `execute_process` 在配置主机上运行；交叉编译时，该文件描述的是 host，而不是由 `CMAKE_SYSTEM_PROCESSOR` 指定的 target。因此，在 x86_64 Linux host 配置 riscv64 target 时，目标能力会被 x86 cpuinfo 的缺失字符串错误地判为 OFF。

[vLLM PR #47532](https://github.com/vllm-project/vllm/pull/47532) 已修复同一问题域内的 VLEN 自动检测：交叉编译时不再读取 host `/proc/cpuinfo` 来推断向量寄存器长度，并补充 VLEN=256 支持及超出实现范围时的钳制。但 PR 的补丁没有覆盖更早执行的 FP16/BF16 `find_isa` 路径。F004 因而是修复完整性分析发现的未覆盖路径，是 #47532 的 follow-up 候选，而不是对其已修复具体代码的重复报告。

动态矩阵在 x86_64 Ubuntu 24.04 上用 riscv64 GNU 13.3 工具链进入真实 CMake 交叉配置。T1 设置 `VLLM_RVV_VLEN=128`、不设置 BF16 override，记录到 FP16/BF16 均为 OFF，且 12 条 vLLM `_C` 命令均为 `-march=rv64gc`；T2 仅增加影响配置语义的 `VLLM_CPU_RVV_BF16=1`，即切换为 14 条 `_C` 和 1 条 `dnnl_ext` RVV/BF16 命令。由此，**F004 场景 B 已在 CMake 配置阶段动态确认**。`compile_commands.json` 证明错误命令已经生成，但不证明命令已执行或错误二进制已产生。缺陷存在性无需继续扩大证明；下一阶段应先与 #47532 提交者确认目标能力声明、VLEN 语义及信息不足时的回退策略，再收敛修复设计。

## 2. 背景

vLLM CPU 后端在 [`cmake/cpu_extension.cmake`](../../cmake/cpu_extension.cmake) 中识别目标架构、选择 CPU 扩展源文件并生成编译参数。对 riscv64 路径，几个概念承担不同职责：

- RVV 表示 RISC-V 向量扩展；`-march` 中是否包含 `v` 及相关扩展，决定编译器是否定义对应宏并允许相关指令和代码路径。
- VLEN 是向量寄存器长度。当前逻辑接受 128 或 256 等显式值，并把它编码为 `zvl<N>b`；它描述长度，不等价于声明 FP16 或 BF16 能力。
- `zvfh`/`zvfhmin` 和 `zvfbfmin` 分别关联向量 FP16、BF16 能力；当前 CMake 通过 cpuinfo 字符串或 BF16 override 形成 `RVV_FP16_FOUND`、`RVV_BF16_FOUND`。
- `MARCH_FLAGS` 最终被追加到 `CXX_COMPILE_FLAGS`，后者传给 `_C`，在 oneDNN 路径启用时也传给 vLLM 自己的 `dnnl_ext`。

原生编译中，配置进程与目标程序运行于同一系统，读取本机 `/proc/cpuinfo` 可以作为硬件能力探测的一种输入。交叉编译则不同：编译器在 host 上生成 target 指令，`CMAKE_HOST_SYSTEM_PROCESSOR` 描述配置主机，`CMAKE_SYSTEM_PROCESSOR` 描述目标架构。目标硬件可能不存在于配置现场，也可能需要 sysroot、toolchain 文件或显式参数描述；host 的 cpuinfo 不能替代 target 能力声明。

F004 的核心因此不是“选择 `rv64gc` 一定错误”，而是：用户已经提供正 VLEN、进入 riscv64 目标分支后，FP16/BF16 决策仍被无关的 host 信息控制，且系统没有明确告诉用户还缺少哪些目标能力信息。

## 3. 与 #47532 的关系

### 3.1 #47532 实际处理的范围

根据 #47532 的原始描述及补丁，该 PR 至少处理了三项相互关联的问题：

1. **C++ VLEN 支持范围**：`cpu_attn_has_isa("rvv")` 原先只接受 `__riscv_v_min_vlen == 128`，与注意力实现同时支持 128/256 不一致；补丁增加 256。
2. **交叉编译时 VLEN 自动检测读取 host cpuinfo**：`VLLM_RVV_VLEN` 未定义时的 `file(READ /proc/cpuinfo _cpuinfo)` 增加 `CMAKE_CROSSCOMPILING` 守卫，交叉编译直接跳过自动检测。
3. **自动检测结果超出实现范围**：检测到 512/1024 时不再把该值直接传播到只支持 128/256 的实现，而是警告并钳制到 256。

该 PR 还调整了 Python 运行时 RVV 检查，使 C++ 编译期结果优先于 `/proc/cpuinfo` 的启发式判断。其补丁文件范围为 `cmake/cpu_extension.cmake`、`csrc/cpu/cpu_attn.cpp` 和 `vllm/v1/attention/backends/cpu_attn.py`。

### 3.2 F004 位于修复边界之外

**已由源码确认：** #47532 增加的 guard 位于 VLEN 自动检测分支，即当前基线第 200–232 行；而基线第 60–67 行已经先执行 `cat /proc/cpuinfo`，第 109–110 行再用同一 `CPUINFO` 检测 `zvfhmin`/`zvfbfmin`。后两处仍没有 `CMAKE_CROSSCOMPILING` 守卫。

**基于证据的解释：** #47532 修复了“用 host cpuinfo 推断 target VLEN”的具体路径，但没有建立统一的“交叉编译时目标能力信息来源”边界。F004 是同一 host/target 信息混淆问题域中的未覆盖路径，可描述为“修复残留”“修复完整性分析发现”或“#47532 的 follow-up 候选”。它不否定 #47532 已完成的三项修复，也不应被描述为 #47532 中同一具体路径再次失效。

## 4. 源码逻辑与根因

以下行号对应源码基线 `57f327ef9c827788c85c0a69c0cf86e446ff27ae`；当前 HEAD 中该文件 blob 与基线相同，均为 `64df94e947d44da6dd67dd4cd5c90589e215b8b2`。

```text
构建主机 /proc/cpuinfo                 第 60–63 行
  → CPUINFO
  → find_isa(CPUINFO, "zvfhmin")       第 109 行
  → RVV_FP16_FOUND
  → find_isa(CPUINFO, "zvfbfmin")      第 110 行
  → RVV_BF16_FOUND
  → VLLM_RVV_VLEN 分支                 第 193–252 行
  → MARCH_FLAGS
  → CXX_COMPILE_FLAGS                  第 253 行
  → _C / dnnl_ext 编译选项             第 382–384、587–592 行
  → compile_commands.json
```

### 4.1 host 信息如何进入 target 决策

**已由源码确认：** [`cpu_extension.cmake` 第 60–67 行](../../cmake/cpu_extension.cmake#L60-L67)只以 `NOT MACOSX_FOUND` 为条件执行 `cat /proc/cpuinfo`。这里没有交叉编译判断。CMake `execute_process` 不是在尚未生成的 target 上运行，而是在执行 CMake 的 host 上启动 `cat`。随后 [`find_isa` 第 70–77 行](../../cmake/cpu_extension.cmake#L70-L77)执行字符串查找，第 109–110 行把结果写入 RVV 能力变量。

当动态实验同时记录 `CMAKE_HOST_SYSTEM_PROCESSOR=x86_64`、`CMAKE_SYSTEM_PROCESSOR=riscv64` 和 `CMAKE_CROSSCOMPILING=TRUE` 时，前者是运行 CMake/`cat` 的机器，后者才是交叉编译目标。`CPUINFO_RET=0` 只说明 host 文件读取成功；结合源码中命令执行位置，可以确定它来自 host 命名空间，而不是 riscv64 target。

### 4.2 VLEN 守卫为何没有覆盖能力检测

[`VLLM_RVV_VLEN` 自动检测](../../cmake/cpu_extension.cmake#L197-L232)已经在第 203 行检查 `CMAKE_CROSSCOMPILING`，因此未显式设置 VLEN 时不会再从 host 文件推导 `zvl<N>b`。然而该守卫出现于通用 cpuinfo 读取和 `find_isa` 之后，只保护 VLEN，不会回溯修正 `RVV_FP16_FOUND`/`RVV_BF16_FOUND`。

显式 `VLLM_RVV_VLEN=128` 仅使第 234 行的正 VLEN 条件成立；源码没有把正 VLEN转换成任一 capability 变量。若 FP16/BF16 都是 OFF，第 239、242 行均不成立，控制流进入第 245–247 行并设置 `-march=rv64gc`。反之，环境变量 `VLLM_CPU_RVV_BF16=1` 经第 19、122–127 行把 `RVV_BF16_FOUND` 强制为 ON，随后第 239–241 行生成：

```text
-march=rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl128b
-mrvv-vector-bits=zvl
-mabi=lp64d
```

这解释了 T1/T2 的可控切换。它不表示“VLEN 本应隐含 BF16”，而是揭示交叉编译接口没有清晰表达“长度”和“可选算术扩展”之间的契约。

## 5. 场景划分

### 5.1 场景 A：macOS host → riscv64 Linux target

**状态：`not tested`。**

**静态推断：** toolchain 将目标系统设为 Linux 后，`MACOSX_FOUND` 按目标系统判断可能为假，于是进入非 macOS 分支；配置 host 上通常没有 `/proc/cpuinfo`，`cat` 失败后第 64–65 行触发 `FATAL_ERROR`。该路径尚未在真实 macOS 交叉配置中观察，报告不能把“可能失败”提升为已复现事实。

### 5.2 场景 B：x86 Linux host → riscv64 Linux target

**状态：`confirmed`，仅限 CMake 配置阶段。**

**动态观察：** host 的 `/proc/cpuinfo` 可读取，但其内容对应 x86_64；RISC-V FP16/BF16 字符串搜索保持 OFF。显式 VLEN=128 后，CMake 仍为实际 vLLM `_C` 源文件生成 `-march=rv64gc`。BF16 override 正向对照可以把相同 target/toolchain/Python/build type 切换到 RVV/BF16 参数。

### 5.3 场景 C：用户没有声明目标 RVV 能力

**解释：** 若 VLEN、FP16、BF16 和完整目标 ISA 都未声明，交叉编译系统没有充分信息确认 target 支持 RVV。此时选择 `rv64gc` 可以是安全默认，不单独构成 F004 证据。F004 聚焦的是 host 信息参与目标能力判断，以及用户已经设置正 VLEN时缺少明确、可靠的能力声明语义；不能把所有标量回退都归类为缺陷。

## 6. 动态验证目标与实验设计

### 6.1 环境与目标

配置 host 记录于 [`environment/aliyun.txt`](../validation/F004-cross-compile/environment/aliyun.txt)和[整改补充记录](../validation/F004-cross-compile/environment/remediation-20260729.txt)：x86_64 Ubuntu 24.04.4、CMake 3.28.3、Ninja 1.11.1、RISC-V GNU C/C++ 13.3.0、venv Python 3.12.3、PyTorch 2.13.0+cpu。原始 `aliyun.txt` 的 `torch: not found` 来自系统 `/usr/bin/python3`；缓存与整改记录确认实验传给 CMake 的是 `/root/work/.venv-vllm-f004/bin/python`。

[`environment/bianbu.txt`](../validation/F004-cross-compile/environment/bianbu.txt)记录了一台 RISC-V Spacemit X60 的背景 ISA，其中有 `zvfh`/`zvfhmin`，未记录 `zvfbfmin` 或 `zvl128b`/`zvl256b`。该机器没有作为本轮 CMake sysroot、toolchain target 信息源或运行环境；它的 ISA 没有传给 CMake，因此不能用来证明实验 target 的实际能力。

工具链文件只设置 Linux/riscv64、交叉 C/C++ 编译器及 `CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY`，没有预设任何 RVV 能力变量、VLEN 或 `-march`。运行时 host/target 信息和编译数据库中的 `/usr/bin/riscv64-linux-gnu-g++`共同证明实验进入真实交叉配置，而不是 instrumentation 人工设置 `CMAKE_CROSSCOMPILING`。

### 6.2 中立 instrumentation

整改后的 [`f004-log-only.patch`](../validation/F004-cross-compile/instrumentation/f004-log-only.patch)只增加注释、空行和 13 条 `message(STATUS ...)`：7 条记录 host/target/cpuinfo 状态，4 条记录能力、override 和 VLEN，2 条记录最终 flags。它没有增加 `set(...)`，没有改变 `if/elseif/else`、toolchain、处理器或控制流。

第一轮结果使用的是较早的 11 条可达消息版本；最终 flags 不依赖消息自报，而由原始 `compile_commands.json` 独立确认。整改时另做临时 T1 冒烟配置，确认修正后的最终两条消息位于正常 RISC-V 路径且可达；该冒烟测试不属于新的 F004 矩阵。

### 6.3 整改后的可复现性约束

[`apply_instrumentation.sh`](../validation/F004-cross-compile/scripts/apply_instrumentation.sh)校验仓库 origin、基线提交对应 blob、补丁只含观察性新增、精确 instrumented blob 和 13 条 marker，并拒绝重复应用。[`remove_instrumentation.sh`](../validation/F004-cross-compile/scripts/remove_instrumentation.sh)只允许从精确 instrumented blob 反向恢复，并再次校验基线 blob。[`run_matrix.sh`](../validation/F004-cross-compile/scripts/run_matrix.sh)要求显式 Python 和全新结果目录，为每组建立独立 build，逐组清除架构 override 与 `CMAKE_ARGS`，用 `PIPESTATUS[0]` 保存 CMake 的真实退出码。[`extract_evidence.sh`](../validation/F004-cross-compile/scripts/extract_evidence.sh)要求显式且位于验证树内的结果目录，保留完整日志/缓存/编译数据库，并按输出路径区分 vLLM `_C`、`dnnl_ext` 与 `_deps/`。

第一轮缺失的四份完整 `configure.log` 在原 aliyun 结果目录找回，经路径、消息、退出结果、缓存/编译数据库对应关系和敏感模式检查后纳入 `594917a...`。[`manifest.txt`](../validation/F004-cross-compile/results/20260729T074037Z/manifest.txt)记录源码提交、blob、脚本/补丁/toolchain 哈希、Python/PyTorch/CMake/编译器及各证据文件哈希。`/root/work/...` 只是原实验布局，降低原地可移植性但不改变证据含义。

## 7. 测试矩阵

| 测试 | VLEN | BF16 override | 退出码 | 主要用途 |
|---|---:|---:|---:|---|
| T0 | 0 | 未设置 | 0 | 显式标量控制组 |
| T1 | 128 | 未设置 | 0 | 核心复现组 |
| T2 | 128 | 1 | 0 | RVV/BF16 正向对照 |
| T3 | 未设置 | 1 | 1 | 缺少 VLEN 的预期失败路径 |

T0 证明同一工具链可以完成显式标量配置，但不证明缺陷。T1 让正 VLEN 与 host 派生的 capability OFF 同时存在，是核心观察。T2 只增加影响配置语义的 BF16 override，用于验证能力变量到最终 flags 的因果传播。T3 证明交叉编译中 capability 为 ON 且 VLEN 未声明时，系统会在预期检查点要求显式 VLEN，而不是因其他依赖或工具链故障退出。

第一轮 T1 比 T2 多启用了 CMake trace 日志；trace 影响日志表现，不改变被测配置语义。整改后的 runner 已统一 T1/T2 日志选项。准确说法是：T1/T2 唯一影响配置语义的输入差异为 `VLLM_CPU_RVV_BF16=1`。

## 8. 动态结果

### 8.1 T0：标量控制

[`T0 exit_code.txt`](../validation/F004-cross-compile/results/20260729T074037Z/T0-scalar/exit_code.txt)为 0；[消息](../validation/F004-cross-compile/results/20260729T074037Z/T0-scalar/f004-messages.txt)记录 VLEN=0、FP16/BF16=OFF；[归属表](../validation/F004-cross-compile/results/20260729T074037Z/T0-scalar/vllm-target-march.tsv)包含 12 条 `_C` 命令，均为 `-march=rv64gc`。这符合显式标量输入。

### 8.2 T1：核心复现

[`T1 f004-messages.txt`](../validation/F004-cross-compile/results/20260729T074037Z/T1-vlen128/f004-messages.txt)直接记录：

```text
CMAKE_CROSSCOMPILING=TRUE
CMAKE_HOST_SYSTEM_NAME=Linux
CMAKE_HOST_SYSTEM_PROCESSOR=x86_64
CMAKE_SYSTEM_NAME=Linux
CMAKE_SYSTEM_PROCESSOR=riscv64
CPUINFO_RET=0
RVV_FP16_FOUND=OFF
RVV_BF16_FOUND=OFF
ENABLE_RVV_BF16=
VLLM_RVV_VLEN=128
```

[`CMakeCache.txt`](../validation/F004-cross-compile/results/20260729T074037Z/T1-vlen128/CMakeCache.txt)确认 Release、同一 toolchain、Python 和 VLEN 输入；[`configure.log`](../validation/F004-cross-compile/results/20260729T074037Z/T1-vlen128/configure.log)以退出码 0完成 configuring/generating。原始 [`compile_commands.json`](../validation/F004-cross-compile/results/20260729T074037Z/T1-vlen128/compile_commands.json)中共有 12 条命令，输出均位于 `CMakeFiles/_C.dir/`，源文件来自 `csrc/cpu/`，编译器为 `riscv64-linux-gnu-g++`，全部包含：

```text
-march=rv64gc
```

[`vllm-target-march.tsv`](../validation/F004-cross-compile/results/20260729T074037Z/T1-vlen128/vllm-target-march.tsv)是对这些原始命令的目标归属展开；T1 不含 `dnnl_ext`，因为两个 RVV capability 均为 OFF 时源码没有启用对应 oneDNN 路径。

### 8.3 T2：BF16 override 正向对照

[`T2 f004-messages.txt`](../validation/F004-cross-compile/results/20260729T074037Z/T2-vlen128-bf16/f004-messages.txt)记录相同 cross/host/target 和 VLEN，同时：

```text
RVV_FP16_FOUND=OFF
RVV_BF16_FOUND=ON
ENABLE_RVV_BF16=1
VLLM_RVV_VLEN=128
```

原始 [`compile_commands.json`](../validation/F004-cross-compile/results/20260729T074037Z/T2-vlen128-bf16/compile_commands.json)中，14 条 `_C` 和 1 条 `dnnl_ext` 命令均使用：

```text
-march=rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl128b
-mrvv-vector-bits=zvl
-mabi=lp64d
```

目标数与参数组合可由 [`vllm-target-march.tsv`](../validation/F004-cross-compile/results/20260729T074037Z/T2-vlen128-bf16/vllm-target-march.tsv)复核。T1/T2 对照排除了“VLEN 参数完全未生效”“没有进入 RISC-V 分支”“toolchain 完全失效”等替代解释，并验证 override → capability → `MARCH_FLAGS` → 真实 vLLM 目标命令的传播。

T2 的 [`dependency-target-march.tsv`](../validation/F004-cross-compile/results/20260729T074037Z/T2-vlen128-bf16/dependency-target-march.tsv)另有 170 条命令使用 `-march=rv64gc`。oneDNN 或其子构建仍生成 `-march=rv64gc`；这些命令位于 `_deps/`，不属于 vLLM `_C` 或 `dnnl_ext`，原因未在本轮分析，不纳入 F004 结论。

### 8.4 T3：缺少 VLEN 的控制路径

[`T3 exit_code.txt`](../validation/F004-cross-compile/results/20260729T074037Z/T3-bf16-no-vlen/exit_code.txt)为 1；[完整日志](../validation/F004-cross-compile/results/20260729T074037Z/T3-bf16-no-vlen/configure.log)记录 BF16=ON、VLEN 未设置，并在预期位置报错 `RISC-V RVV is available but VLEN could not be auto-detected`。配置未完成，因此没有 `compile_commands.json`。该组只证明当前接口在 capability ON 且无法自动取得 VLEN 时要求显式输入。

## 9. 缺陷存在性的证明

**问题：当前证据能否证明缺陷存在？**

**结论：能，但证明范围限于 x86_64 Linux → riscv64 的 CMake 配置阶段。**

证明链由相互独立的源码和运行证据组成：

1. **已由源码确认：** 非 macOS 分支在 host 上执行 `cat /proc/cpuinfo`，没有交叉编译守卫。
2. **已由动态实验观察：** CMake 同时记录 host=x86_64、target=riscv64、cross-compiling=TRUE 和 `CPUINFO_RET=0`。
3. **已由源码与实验共同确认：** 该 CPUINFO 输入经过 `find_isa` 后，T1 的 RVV FP16/BF16 均为 OFF；显式 VLEN 不会改变它们。
4. **已由原始编译数据库确认：** 真实 `_C` 输出路径对应的 12 条命令使用 `-march=rv64gc`，不是依赖或编译器探测命令。
5. **已由动态对照确认：** T2 只增加 BF16 override 即把 capability 置为 ON，并令 vLLM 目标生成完整 RVV/BF16/VLEN128 flags。
6. **基于证据的解释：** host 派生的能力变量确实改变了 target 编译命令，错误配置行为已发生，不只是静态可达性推测。

### 9.1 证据强度与替代解释排除

证据包不是只搜索一个预期 `-march` 字符串。完整日志证明配置进入 vLLM CPU CMake，cache 固定 Python、toolchain、build type 和 VLEN，消息记录中间变量，编译数据库记录最终命令，目标归属表再把 `_C`/`dnnl_ext` 与 `_deps/` 分开。几类证据来自变量传播链的不同位置，能够相互校验：若插桩消息有误，编译数据库仍可显示最终 flags；若任意依赖带有 `rv64gc`，输出路径筛选可阻止它被误当作 vLLM `_C`；若配置在前置依赖处失败，成功退出码和 `Configuring done`/`Generating done` 也不会同时存在。

T1/T2 对照还排除了若干更弱解释。两组使用相同源码 blob、RISC-V toolchain、Python/PyTorch、Release build type、target device 和 VLEN=128，且都记录 cross=TRUE、host=x86_64、target=riscv64。T2 能生成 RVV 命令，说明编译器名称、target 架构分支和 VLEN 参数并非完全失效；T1 保持标量而 T2 随 BF16 override 切换，符合源码中唯一相关变量链。第一轮 T1 的 trace 选项虽然造成消息重复，但只改变诊断输出，不参与变量条件或 flags 构造；整改 runner 已消除这一非语义差异。

这组证据仍不是目标硬件能力的实测。实验没有把 bianbu cpuinfo、sysroot 特征或硬件探测结果传入 CMake，因此不能进一步断言“T1 的 target 确实支持某一扩展”。已确认缺陷建立在更窄、但充分的事实之上：交叉配置使用了 host 信息来决定 target 参数，而且该决定在用户给出正 VLEN 时真实产生了标量命令。至于期望接口应要求何种 target capability 声明，属于后续设计问题，不是动态结果本身。

`compile_commands.json` 是 CMake 为构建系统生成、准备交给真实交叉编译器的命令集合。它足以证明配置阶段的目标参数选择；但文件存在不表示编译器已经执行这些命令，也不表示对象、共享库、wheel 或目标二进制产物已经生成。因此本文始终把观察表述为“生成标量编译命令”。

## 10. 已确认和未确认的边界

### 10.1 已确认

- x86_64 Linux host → riscv64 Linux target 的真实 CMake 交叉配置；
- `CMAKE_CROSSCOMPILING=TRUE` 时，早期 FP16/BF16 检测仍读取 host `/proc/cpuinfo`；
- VLEN=128 且无 capability override 时，T1 的 `_C` 命令全部使用 `-march=rv64gc`；
- `VLLM_CPU_RVV_BF16=1` 能把能力变量及 vLLM 目标 flags 切换到 RVV/BF16/VLEN128；
- VLEN 自动检测有交叉编译守卫，而 FP16/BF16 检测没有；
- F004 是 #47532 同一 host/target 信息混淆问题域中的残留路径和 follow-up 候选。

### 10.2 尚未验证

- 任一 `_C` 或 `dnnl_ext` 对象的实际编译；
- 链接、wheel 生成、目标二进制 ISA 检查；
- 在 bianbu 或其他 riscv64 target 上运行；
- 性能下降、模型输出或精度影响；
- VLEN=256；
- macOS 场景 A；
- 所有 RISC-V host/toolchain/sysroot 组合；
- bianbu ISA 信息被传给 CMake；
- oneDNN 依赖侧 170 条 `rv64gc` 命令的成因。

## 11. 为什么暂不直接提交修复

移除错误信息源只是第一步；真正需要维护者决定的问题是：**交叉编译时目标能力信息应从哪里获得，以及缺失时采取什么行为。** 简单给所有 `find_isa` 增加 guard 可能让 ARM、PowerPC、S390 的 `*_FOUND` 同时变为 OFF，进而落入“不支持 CPU backend”的错误分支；简单把正 VLEN 当成完整 RVV 能力，又可能把“长度”错误等同于 FP16/BF16 支持。

以下均属于**修复设计问题或待维护者决定**，本文不选择最终方案：

1. `VLLM_RVV_VLEN>0` 是只声明向量长度，还是也表达用户明确请求包含 `v` 的构建？
2. 即使正 VLEN 表示请求 RVV，它是否仍不应隐含 FP16/BF16？
3. 是否新增与现有 BF16 override 对称的显式 FP16 override，例如 `VLLM_CPU_RVV_FP16`？
4. 是否允许高级用户直接提供完整 target `-march`，以及如何验证其与 VLEN、ABI 一致？
5. 用户只提供 VLEN、没有扩展能力时，应 fail-fast、给出警告后回退，还是保持当前静默标量行为？
6. 如何保留原生 riscv64 构建基于本机 cpuinfo 的便利性，同时保证 cross-compiling 不读 host 能力？
7. follow-up 只修 RISC-V，还是同步梳理 ARM 等复用同一 `CPUINFO` 的架构？
8. 如何兼容已经使用 `VLLM_CPU_RVV_BF16`、`VLLM_RVV_VLEN=0/128/256` 的现有构建流程？

在这些接口语义未确认前直接编码，容易把一种未经维护者确认的策略固化为兼容性承诺。当前证据已足以进入设计讨论，但不足以替维护者决定接口。

## 12. 待与 #47532 提交者讨论的问题

以下问题可以直接作为沟通清单：

1. `VLLM_RVV_VLEN=128` 的原始语义是“只声明 VLEN”，还是“显式请求 RVV 构建”？
2. 正值 VLEN 是否应保证最终 `-march` 至少包含 `v`，还是仍允许静默回退到 `rv64gc`？
3. 交叉编译时，目标 FP16/BF16 能力应通过环境变量、CMake cache、toolchain，还是完整 `-march` 声明？
4. `VLLM_CPU_RVV_BF16` 是否被设计为稳定、官方的交叉编译接口？
5. 是否接受增加 `VLLM_CPU_RVV_FP16`，并明确 BF16 是否蕴含 FP16？
6. 当 VLEN>0 但 capability 信息不足时，维护者倾向 fail-fast、警告还是标量回退？
7. 是否希望提供完整目标 `-march` 参数；若提供，谁负责 VLEN/ABI/扩展组合校验？
8. 修复范围应只作为 RISC-V follow-up，还是统一整理跨架构的 host capability 探测？
9. 在 #47532 合并后，维护者是否建议以独立 follow-up PR 提交该未覆盖路径？

## 13. 与提交者沟通用英文摘要

> We found a potential follow-up to vLLM PR #47532 in the same host/target information-mixing area. #47532 correctly guards RISC-V VLEN auto-detection with `CMAKE_CROSSCOMPILING`, adds VLEN=256 support, and clamps auto-detected VLEN values beyond the implemented range. However, an earlier path in `cmake/cpu_extension.cmake` still executes `cat /proc/cpuinfo` and uses the host contents to set `RVV_FP16_FOUND` and `RVV_BF16_FOUND` without a cross-compilation guard.
>
> We reproduced this at the CMake configuration stage on an x86_64 Ubuntu host targeting riscv64. With `VLLM_RVV_VLEN=128` and no BF16 override, both capability variables remained OFF and all 12 generated vLLM `_C` commands used `-march=rv64gc`. With the same target configuration plus `VLLM_CPU_RVV_BF16=1`, 14 `_C` commands and one `dnnl_ext` command used the expected RVV/BF16/VLEN128 flags. We did not compile, link, or run a target binary.
>
> We have not proposed a fix yet because the intended interface semantics need clarification: whether a positive VLEN means an explicit RVV request, how cross builds should declare FP16/BF16 target capabilities, and whether incomplete target information should fail fast, warn, or fall back to scalar. Would you prefer this to be handled as a focused follow-up to #47532, and what configuration interface should remain compatible?

## 14. 方法论意义

F004 的发现过程形成了一条可审计的方法链：

```text
历史 PR 收集
  → 提取 host/target 信息混淆模式
  → 分析既有修复边界
  → 定位未覆盖的 FP16/BF16 路径
  → 静态重建变量传播
  → T0–T3 动态对照验证
  → 独立、只读、对抗式审查
  → 补回日志并加固脚本与目标归属证据
  → 范围受限的 confirmed finding
```

这说明调研文件不必只是历史案例目录。一个已修复案例可以被转化为审计假设：先提取缺陷模式，再检查补丁保护了哪些入口、遗漏了哪些语义相邻路径。F004 不是在已修改代码中机械寻找同一个 bug，而是用 #47532 暴露的 host/target 混淆模式检查修复完整性，最终在更早的 capability 检测中找到残留。

该案例也表明，“静态变量传播 + 最小配置矩阵 + target-attributed 编译命令”适合验证构建系统缺陷；独立审查则迫使证据包补齐完整日志、退出码、变量隔离、插桩中立性和依赖归属。与此同时，这仍只是 vLLM/RISC-V 的单项目案例，不能据此宣称历史案例驱动方法在所有项目或缺陷类别中普遍有效。其价值目前是提供一个可复核的实例和可复用的审计流程。

## 15. 结论与下一步

F004 已足以作为范围明确的已确认构建配置缺陷记录：在本次 x86_64 Linux → riscv64、VLEN=128 的 CMake 交叉配置中，host `/proc/cpuinfo` 决定了 target FP16/BF16 capability，并使 vLLM `_C` 生成 `-march=rv64gc`；BF16 override 对照能够切换到预期 RVV flags。该结论由基线源码、运行时变量和实际目标归属的编译数据库共同支撑。

当前无需为了证明“缺陷是否存在”而继续扩大实验。后续顺序建议为：

1. 与 #47532 提交者讨论第 12 节的接口和回退语义；
2. 根据维护者反馈确定目标能力声明方式与兼容边界；
3. 设计覆盖原生/交叉、scalar、FP16、BF16、VLEN=128/256 和错误输入的回归矩阵；
4. 如需提高编译器兼容性证据，最小编译一个真实 `_C` 对象；
5. 完成人工评审后，再决定是否提交独立 follow-up PR。

本报告不实现修复，不修改正式源码，也不把未验证的场景 A、二进制结果、性能影响或依赖侧 `rv64gc` 扩展为已确认结论。

## 附录 A：证据与提交索引

| 证据 | 用途 |
|---|---|
| [`cmake/cpu_extension.cmake`](../../cmake/cpu_extension.cmake) @ `57f327e...` | 源码变量链与行号基线 |
| [F004 finding](../findings/F004-cross-compile-cpuinfo-unguarded.md) | 正式 finding 状态、场景和设计讨论 |
| [审计 STATUS](../STATUS.md) | 场景 B confirmed 的状态收口 |
| [验证 README](../validation/F004-cross-compile/README.md) | 安全工作流、矩阵、证据定义 |
| [验证 REPORT](../validation/F004-cross-compile/REPORT.md) | 独立审查整改后的动态结论 |
| [结果 manifest](../validation/F004-cross-compile/results/20260729T074037Z/manifest.txt) | 环境、提交、工具和证据哈希 |
| `16659b79de18595dcf17072dfc3486fb948f2a73` | 第一版动态验证证据 |
| `594917a9a9ba082bae1431fbd6b2bd96771dfd4b` | 日志恢复、插桩/脚本加固、目标归属证据 |
| `a0cec6afe5c412e12ab100582cd148efb0ef9586` | finding 与 STATUS 状态收口 |
| [vLLM PR #47532](https://github.com/vllm-project/vllm/pull/47532) | 历史修复范围与 follow-up 背景 |
