# F004 Cross-Compile Validation Report

## 1. 验证目标

动态验证 F004 场景 B：x86 Linux → riscv64 Linux 交叉编译时，CMake 使用构建主机 `/proc/cpuinfo` 判断目标 FP16/BF16 能力，导致用户显式设置 `VLLM_RVV_VLEN=128` 时仍生成标量 `-march=rv64gc`。

## 2. 基线和实际 HEAD

- 基线提交：`57f327ef9c827788c85c0a69c0cf86e446ff27ae`
- 实际 HEAD：`57f327ef9c827788c85c0a69c0cf86e446ff27ae`
- 基线是 HEAD 的祖先：是
- 工作区状态：干净

## 3. aliyun 环境

- OS: Ubuntu 24.04.4 LTS (Noble Numbat)
- Kernel: 6.8.0-124-generic
- Arch: x86_64
- CPU: Intel Xeon Platinum (2 cores, AVX-512)
- git: 2.43.0
- cmake: 3.28.3
- ninja: 1.11.1
- python3: 3.12.3
- PyTorch: 2.13.0+cpu (in venv `~/work/.venv-vllm-f004`)
- riscv64-linux-gnu-gcc/g++: 13.3.0
- jq: 1.7

## 4. bianbu 只读环境摘要

- OS: Bianbu Linux (kernel 6.6.63)
- Arch: riscv64
- CPU: Spacemit X60, 8 cores, 1600 MHz
- ISA: `rv64imafdcv_zicbom_zicboz_..._zvfh_zvfhmin_zve64d_zve64f_zve64x_...`
- 关键观察：cpuinfo 含 `zvfh`/`zvfhmin` 但**不含** `zvfbfmin`；**不含** `zvl128b`/`zvl256b`
- gcc: 13.2.0 (Bianbu)
- clang: 未安装
- 本轮未在 bianbu 安装软件或编译

## 5. Toolchain 文件

`toolchains/riscv64-linux-gnu.cmake`：
- `CMAKE_SYSTEM_NAME=Linux`
- `CMAKE_SYSTEM_PROCESSOR=riscv64`
- `CMAKE_C_COMPILER=riscv64-linux-gnu-gcc`
- `CMAKE_CXX_COMPILER=riscv64-linux-gnu-g++`
- `CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY`

## 6. Instrumentation 方法

在 `cmake/cpu_extension.cmake` 中添加 10 条 `message(STATUS "[F004] ...")` 日志，不修改任何判断逻辑。日志位置：
1. `cat /proc/cpuinfo` 后、`find_isa` 前：host/target 信息
2. `find_isa` 和 override 后：`RVV_FP16_FOUND`/`RVV_BF16_FOUND`/`ENABLE_RVV_BF16`/`VLLM_RVV_VLEN`
3. `MARCH_FLAGS` 最终选择后：`MARCH_FLAGS`/`CXX_COMPILE_FLAGS`

补丁文件：`instrumentation/f004-log-only.patch`

## 7. 测试结果

### T0：显式标量控制组（VLLM_RVV_VLEN=0）

| 变量 | 值 |
|---|---|
| CMAKE_CROSSCOMPILING | TRUE |
| CMAKE_HOST_SYSTEM_PROCESSOR | x86_64 |
| CMAKE_SYSTEM_PROCESSOR | riscv64 |
| RVV_FP16_FOUND | OFF |
| RVV_BF16_FOUND | OFF |
| VLLM_RVV_VLEN | 0 |
| **-march** | **-march=rv64gc** |
| 退出码 | 0 |

### T1：核心可疑场景（VLLM_RVV_VLEN=128，无 BF16 override）

| 变量 | 值 |
|---|---|
| CMAKE_CROSSCOMPILING | TRUE |
| CMAKE_HOST_SYSTEM_PROCESSOR | x86_64 |
| CMAKE_SYSTEM_PROCESSOR | riscv64 |
| CPUINFO_RET | 0（cat /proc/cpuinfo 成功） |
| RVV_FP16_FOUND | **OFF** |
| RVV_BF16_FOUND | **OFF** |
| ENABLE_RVV_BF16 | （空） |
| VLLM_RVV_VLEN | **128** |
| **-march** | **-march=rv64gc**（标量！） |
| 退出码 | 0 |

### T2：BF16 override 正向控制组（VLLM_RVV_VLEN=128 + VLLM_CPU_RVV_BF16=1）

| 变量 | 值 |
|---|---|
| CMAKE_CROSSCOMPILING | TRUE |
| CMAKE_HOST_SYSTEM_PROCESSOR | x86_64 |
| CMAKE_SYSTEM_PROCESSOR | riscv64 |
| RVV_FP16_FOUND | OFF |
| RVV_BF16_FOUND | **ON** |
| ENABLE_RVV_BF16 | **1** |
| VLLM_RVV_VLEN | 128 |
| **-march (vLLM)** | **-march=rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl128b** |
| **-march (oneDNN)** | -march=rv64gc（oneDNN 独立选择） |
| 退出码 | 0 |

### T3：BF16 无 VLEN（VLLM_CPU_RVV_BF16=1，未设 VLEN）

| 变量 | 值 |
|---|---|
| RVV_BF16_FOUND | ON |
| VLLM_RVV_VLEN | （空） |
| 结果 | FATAL_ERROR: "RISC-V RVV is available but VLEN could not be auto-detected" |
| 退出码 | 1（预期失败） |

## 8. T1 与 T2 对照

| 指标 | T1 (VLEN=128, no BF16) | T2 (VLEN=128 + BF16=1) |
|---|---|---|
| RVV_FP16_FOUND | OFF | OFF |
| RVV_BF16_FOUND | OFF | **ON** |
| VLLM_RVV_VLEN | 128 | 128 |
| -march | **-march=rv64gc**（标量） | **-march=rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl128b**（RVV） |
| 退出码 | 0 | 0 |

T1 和 T2 的唯一差异是 `VLLM_CPU_RVV_BF16=1`。T1 生成标量 `rv64gc`，T2 生成 RVV `rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl128b`。这证明：
- RISC-V 分支确实到达
- VLEN 参数本身有效
- T1 生成标量不是因为整个 RISC-V 配置入口失效
- BF16 能力变量确实控制最终 `-march`

## 9. compile_commands.json 确认

- T0：生成，`-march=rv64gc`
- T1：生成，`-march=rv64gc`
- T2：生成，`-march=rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl128b`（vLLM 扩展）+ `-march=rv64gc`（oneDNN）
- T3：未生成（配置失败）

## 10. 是否到达真实 vLLM CMake 路径

**是。** 所有 4 组测试均到达 `cmake/cpu_extension.cmake` 的 RISC-V 分支。T0/T1/T2 配置成功完成（退出码 0），T3 在预期位置 FATAL_ERROR（退出码 1）。`[F004]` 日志在所有测试中均出现。

## 11. 结论状态

### **confirmed**

F004 的 x86 Linux → riscv64 场景 B 已动态复现。

满足全部判定条件：
1. CMAKE_CROSSCOMPILING=TRUE ✓
2. CMAKE_HOST_SYSTEM_PROCESSOR=x86_64 ✓
3. CMAKE_SYSTEM_PROCESSOR=riscv64 ✓
4. CMake 读取 x86 host /proc/cpuinfo（CPUINFO_RET=0）✓
5. RVV_FP16_FOUND=OFF, RVV_BF16_FOUND=OFF ✓
6. VLLM_RVV_VLEN=128 → -march=rv64gc（标量）✓
7. VLLM_CPU_RVV_BF16=1 → -march=rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl128b（RVV）✓
8. compile_commands.json 确认实际 -march ✓

## 12. 证据限制

- 仅验证 x86 Linux → riscv64 场景 B；macOS 场景 A 未验证。
- 未执行实际编译（`cmake --build`），仅验证配置阶段。
- T2 的 oneDNN 使用独立的 `-march=rv64gc`（oneDNN 自身的 RVV 检测失败，但这是 oneDNN 的问题，不影响 vLLM CPU 扩展的 -march）。
- T1 的 configure.log 含 `--trace-source` 输出，体积较大（56KB），但已保留作为完整证据。

## 13. 后续事项

- T2 中 oneDNN 的 RVV 检测失败（`CAN_COMPILE_RVV_INTRINSICS - Failed`）是独立问题，不影响 F004 结论。
- bianbu 的 cpuinfo 不含 `zvfbfmin` 和 `zvl` 标志，与 F005 的 BF16 检测问题和 F003 的 RVV 检测问题一致。
- 下一批建议：F001 最小验证程序（在 bianbu 上运行）。

## 14. 区分

### 已观察事实
- T1 在 `VLLM_RVV_VLEN=128` 时生成 `-march=rv64gc`
- T2 在 `VLLM_CPU_RVV_BF16=1` 时生成 `-march=rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl128b`
- T3 在无 VLEN 时 FATAL_ERROR

### 解释
- x86 host cpuinfo 不含 `zvfhmin`/`zvfbfmin`，导致 `RVV_FP16_FOUND`/`RVV_BF16_FOUND` 为 OFF
- 即使 `VLLM_RVV_VLEN=128` 已设置，`MARCH_FLAGS` 选择逻辑仍依赖 `RVV_BF16_FOUND`/`RVV_FP16_FOUND`
- BF16 override 绕过 cpuinfo 检测，正确设置 `RVV_BF16_FOUND=ON`

### 仍未验证
- macOS → riscv64 场景 A
- 实际编译是否成功
- 实际运行性能影响
