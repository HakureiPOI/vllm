# F001: FP32→FP16/BF16 缩窄转换未显式固定舍入模式

## 1. 问题标题

RVV 缩窄浮点转换（FP32→FP16/BF16）使用非 `_rm` intrinsic 形式，舍入模式依赖 `fcsr.frm` 而非显式编码。

## 2. 涉及位置

- `csrc/cpu/cpu_types_riscv_impl.hpp:940` — `FP16Vec16::FP16Vec16(const FP32Vec16& v)`
- `csrc/cpu/cpu_types_riscv_impl.hpp:943` — `FP16Vec8::FP16Vec8(const FP32Vec8& v)`
- `csrc/cpu/cpu_types_riscv_impl.hpp:982` — `BF16Vec8::BF16Vec8(const FP32Vec8& v)`（`#ifdef __riscv_zvfbfmin` 路径）
- `csrc/cpu/cpu_types_riscv_impl.hpp:985` — `BF16Vec16::BF16Vec16(const FP32Vec16& v)`（`#ifdef __riscv_zvfbfmin` 路径）

关键代码：

```cpp
// 行 940
reg = RVVI(__riscv_vfncvt_f_f_w_f16, LMUL_256)(v.reg, VEC_ELEM_NUM);
// 行 943
reg = RVVI(__riscv_vfncvt_f_f_w_f16, LMUL_128)(v.reg, VEC_ELEM_NUM);
// 行 982
: reg(RVVI(__riscv_vfncvtbf16_f_f_w_bf16, LMUL_128)(v.reg, VEC_ELEM_NUM)) {
// 行 985
: reg(RVVI(__riscv_vfncvtbf16_f_f_w_bf16, LMUL_256)(v.reg, VEC_ELEM_NUM)) {
```

`RVVI(base, lmul)` 宏（`cpu_types_riscv_defs.hpp:40`）展开为 `base##lmul`，即非 `_rm` 变体。

## 3. 问题描述

### 已确认事实

- 4 处 `vfncvt` / `vfncvtbf16` 调用使用非 `_rm` intrinsic 变体。
- 对应 `_rm` 变体（如 `__riscv_vfncvt_f_f_w_f16m2_rm`）确实存在于 RISC-V Vector C Intrinsics 规范中。
- `vfncvt.f.f.w` 和 `vfncvtbf16.f.f.w` 是缩窄浮点转换，涉及舍入。

### RISC-V Vector C Intrinsics 舍入语义

RISC-V Vector C Intrinsics 为涉及舍入的操作提供两种形式：

- **非 `_rm` 变体**（如 `__riscv_vfncvt_f_f_w_f16m2`）：属于 implicit rounding intrinsic。在默认浮点环境下使用规范规定的默认舍入语义；当浮点环境访问被启用时，遵循当前浮点环境和 `fcsr.frm`。具体机器码和 CSR 管理由编译器按照 Vector C Intrinsics 规范实现。
- **`_rm` 变体**（如 `__riscv_vfncvt_f_f_w_f16m2_rm`）：属于 explicit rounding intrinsic，要求该操作使用调用者通过参数（如 `__RISCV_FRM_RNE`）指定的舍入模式。编译器可能通过设置 `fcsr.frm`、临时保存旧 `fcsr.frm`、执行向量转换、恢复旧 `fcsr.frm` 的方式实现，或采用其他符合规范的 CSR 管理方式。`_rm` intrinsic 可能因此引入额外的 `frm` 保存和恢复开销。

### `FENV_ACCESS` 与浮点环境语义

C/C++ 标准 `FENV_ACCESS` 的默认状态影响编译器对浮点环境的假设：

- `FENV_ACCESS` OFF（C/C++ 默认）：编译器可假设浮点环境未被修改。在此假设下，implicit rounding intrinsic 的行为遵循规范定义的默认浮点环境语义。
- `FENV_ACCESS` ON（通过 `#pragma STDC FENV_ACCESS ON` 显式开启）：编译器不再假设浮点环境未被修改，implicit rounding intrinsic 将遵循当前 `fcsr.frm` 的动态值。
- `_rm` intrinsic 不依赖 `FENV_ACCESS` 状态：它要求使用参数指定的舍入模式，编译器负责生成相应的 `frm` 管理代码。

需要验证编译器如何按照 implicit rounding 语义处理默认浮点环境，以及是否对 `frm` 进行显式或隐式管理。

### 尚未验证的假设

- 非 `_rm` intrinsic 在当前 vLLM 编译环境下是否导致不可接受的动态舍入依赖——需要验证编译器如何按照 implicit rounding 语义处理默认浮点环境，以及是否对 `frm` 进行显式或隐式管理。
- vLLM 此处语义是否必须固定为 RNE——尚未确认 vLLM 是否有代码路径修改 `fcsr.frm`。
- 修改为显式 RNE 不会改变项目原本允许的浮点环境行为——尚未确认 vLLM 是否有意依赖动态舍入。

## 4. 触发条件

- RISC-V 架构（rv64gcv），`__riscv_v_min_vlen` 定义为 128 或 256。
- FP16 路径：文件在 RVV 编译时包含，`vfncvt_f_f_w_f16` 在 `FP16Vec` 构造函数中调用。
- BF16 路径：`__riscv_zvfbfmin` 定义时，`vfncvtbf16_f_f_w_bf16` 在 `BF16Vec` 构造函数中调用。
- **潜在触发**：调用前有线程代码改变 `fcsr.frm`（如 `fesetround()` 或其他 RVV 指令的副作用）。当前未确认 vLLM 中是否存在此类代码路径。

## 5. 调用链与证据

### FP32→FP16 转换链路

```
模型前向计算
  → FP32 中间结果存储为 FP16
    → FP16Vec16::FP16Vec16(const FP32Vec16& v)  [cpu_types_riscv_impl.hpp:939-941]
      → __riscv_vfncvt_f_f_w_f16m4(v.reg, 16)   // implicit rounding
```

`FP16Vec16(const FP32Vec16&)` 用于将 FP32 计算结果转回 FP16 存储。调用场景包括 KV cache 写入和注意力输出存储。

### FP32→BF16 转换链路

```
模型前向计算
  → FP32 中间结果存储为 BF16
    → BF16Vec8::BF16Vec8(const FP32Vec8& v)     [cpu_types_riscv_impl.hpp:981-983]
      → __riscv_vfncvtbf16_f_f_w_bf16m2(v.reg, 8)  // implicit rounding
    → BF16Vec16::BF16Vec16(const FP32Vec16& v)   [cpu_types_riscv_impl.hpp:984-986]
      → __riscv_vfncvtbf16_f_f_w_bf16m4(v.reg, 16) // implicit rounding
```

### 跨架构对比

#### FP32→FP16

| 架构 | 实现 | 舍入方式 | 位置 |
|---|---|---|---|
| x86 (AVX-512/AVX2) | `_mm512_cvtps_ph` / `_mm256_cvtps_ph` | **显式** `_MM_FROUND_TO_NEAREST_INT \| _MM_FROUND_NO_EXC` | `cpu_types_x86.hpp:970-977` |
| x86 标量 | `_cvtss_sh` | **显式** `_MM_FROUND_TO_NEAREST_INT \| _MM_FROUND_NO_EXC` | `cpu_types_x86.hpp:964-968` |
| ARM | `convert_float_half`（ATen 库） | 隐式（ATen 内部使用 NEON RTE） | `cpu_types_arm.hpp:936-943` |
| 标量 fallback | `float_to_fp16`（位操作） | **显式** RTE（位操作实现 round-half-to-even） | `float_convert.hpp:22-78` |
| **RISC-V** | `__riscv_vfncvt_f_f_w_f16`（非 `_rm`） | **隐式**，读 `fcsr.frm`（默认 RNE） | `cpu_types_riscv_impl.hpp:940,943` |

**观察**：x86 和标量路径显式固定为 RTE。ARM 通过 ATen 隐式使用 RTE。RISC-V 使用非 `_rm` intrinsic，默认 `fcsr.frm=RNE` 时行为与 RTE 一致，但依赖浮点环境状态。

#### FP32→BF16

| 架构 | 实现 | 舍入方式 | 位置 |
|---|---|---|---|
| x86 (AVX-512 BF16) | `_mm256_cvtneps_pbh` / `_mm512_cvtneps_pbh` | 隐式（硬件 RTE） | `cpu_types_x86.hpp:991-995` |
| x86 (AVX-512F, 无 BF16) | `_mm256_cvtepi32_epi16` + `bsrli_epi128` | **截断**（右移 16 位，无舍入） | `cpu_types_x86.hpp:1008-1015` |
| x86 (AVX2) | `FP32Vec8_to_BF16Vec8_avx2`（`_mm256_srli_epi32`） | **截断**（右移 16 位，无舍入） | `cpu_types_x86.hpp:1017-1028` |
| x86 标量 (AVX-512 BF16) | `_mm_cvtness_sbh` | 隐式（硬件 RTE） | `cpu_types_x86.hpp:985-989` |
| x86 标量 (无 AVX-512 BF16) | `*(ptr + 1)` 位别名 | **截断** | `cpu_types_x86.hpp:1001-1006` |
| ARM | `convert_float_bfloat16`（ATen）或 `vcvth_bf16_f32` | 隐式（硬件 RTE） | `cpu_types_arm.hpp:952-959,976-983` |
| 标量 fallback | `float_to_bf16`（`bits >> 16`） | **截断**（无舍入） | `float_convert.hpp:11-14` |
| **RISC-V (zvfbfmin)** | `__riscv_vfncvtbf16_f_f_w_bf16`（非 `_rm`） | **隐式**，读 `fcsr.frm`（默认 RNE） | `cpu_types_riscv_impl.hpp:982,985` |
| RISC-V (fallback) | `float_to_bf16` | **截断** | `cpu_types_riscv_impl.hpp:988-991` |

**关键观察**：FP32→BF16 的舍入语义在跨架构间**本就不一致**：
- 有 BF16 硬件指令的路径（x86 AVX-512 BF16、ARM、RISC-V zvfbfmin）使用 RTE。
- 无 BF16 硬件指令的 fallback 路径（x86 AVX2/AVX-512F、标量）使用**截断**。
- RISC-V 的非 `_rm` intrinsic 在默认 `fcsr.frm=RNE` 时与 RTE 一致，但与 x86/ARM 的隐式 RTE 不同——x86/ARM 的硬件指令固定编码 RTE，而 RISC-V 的非 `_rm` intrinsic 在运行时读 `fcsr.frm`。

## 6. 潜在影响

### 已确认

- 4 处非 `_rm` intrinsic 使用 implicit rounding 语义，其浮点环境行为由 Vector C Intrinsics 规范定义。
- `fcsr.frm` 默认值为 RNE。

### 推断（尚未验证）

- 若 `fcsr.frm` 被改为非 RNE 模式，FP32→FP16/BF16 的舍入结果可能不同。
- 对推理输出精度有潜在影响，且难以调试（结果依赖调用历史）。

### 尚未验证

- vLLM 中是否存在修改 `fcsr.frm` 的代码路径。
- 编译器如何按照 implicit rounding 语义处理默认浮点环境，以及是否对 `frm` 进行显式或隐式管理。
- 实际推理场景中 `fcsr.frm` 是否会被改变。

### 不构成

- 不构成安全漏洞：无 CVE/GHSA 关联，无上游安全公告。
- 不构成已确认的数值错误：在默认 `fcsr.frm=RNE` 下，行为与 RTE 一致。

## 7. 去重检查

- **当前分支代码**：4 处 `vfncvt` 调用确认存在。
- **已有测试**：`tests/kernels/attention/test_cpu_attn.py` 未覆盖舍入模式非确定性。
- **调研文档**：案例 B（#47983）仅覆盖 `vfcvt_x_f_v_i32`（FP32→INT32），**未覆盖** `vfncvt_f_f_w`（FP32→FP16）和 `vfncvtbf16_f_f_w`（FP32→BF16）。
- **历史 PR**：#47983（OPEN）的 diff 仅修改 3 处 `vfcvt_x_f_v_i32`，未触及 4 处 `vfncvt`。

## 8. 可信度

```
机制可信度：高
缺陷结论可信度：中
```

**机制可信度（高）**：源码确认 4 处非 `_rm` intrinsic 调用存在；转换确实涉及舍入；`_rm` API 确实允许请求显式舍入模式；implicit 和 explicit intrinsic 的浮点环境语义不同。

**缺陷结论可信度（中）**：当前尚未证明 vLLM 执行期间存在合法改变 `fcsr.frm` 的调用路径；尚未完成 GCC/Clang 的实际代码生成验证；尚未证明固定 RNE 是 vLLM 此处唯一正确的项目语义；BF16 跨架构 fallback 的舍入语义本来就并不完全一致。

## 9. 验证建议

### 最小独立验证程序

编写独立 C 程序，不依赖完整 vLLM 编译。程序应包含两组函数：

```cpp
// implicit rounding
void convert_implicit(...)

// explicit RNE
void convert_explicit_rne(...)
```

分别测试 `FP32 → FP16` 和 `FP32 → BF16` 两种转换。

#### 测试要求

1. 选择位于 FP16/BF16 舍入边界附近的 FP32 输入（如恰好位于两个可表示 FP16/BF16 值中间的值）。
2. 将 `fcsr.frm` 分别设置为：RNE、RTZ、RDN、RUP。
3. 比较 implicit intrinsic 的输出是否随 `frm` 变化。
4. 比较 explicit `_rm(...RNE...)` 的输出是否始终保持 RNE。
5. 使用反汇编检查 `_rm` 调用附近是否出现 `frrm`、`fsrm`、`fsrmi` 或其他 `frm` 保存、设置、恢复逻辑。
6. 检查 implicit intrinsic 周围是否依赖当前 `frm`。
7. 分别测试默认编译和显式浮点环境访问配置（`#pragma STDC FENV_ACCESS ON`）。
8. 记录 GCC 与 Clang 是否生成不同实现。

### 预期结果

- 若 implicit intrinsic 输出不随 `frm` 变化：说明编译器在默认浮点环境下已按规范处理，问题机制不成立。
- 若 implicit intrinsic 输出随 `frm` 变化，而 explicit `_rm` 固定 RNE：机制确认，需进一步验证 vLLM 是否有路径修改 `frm`。

## 10. 修复思路

### 修复方案

将 4 处非 `_rm` 变体改为 `_rm` 变体，显式传入 `__RISCV_FRM_RNE`：

```cpp
// 行 940 改为：
reg = RVVI3(__riscv_vfncvt_f_f_w_f16, LMUL_256, _rm)(v.reg, __RISCV_FRM_RNE, VEC_ELEM_NUM);
// 行 943 改为：
reg = RVVI3(__riscv_vfncvt_f_f_w_f16, LMUL_128, _rm)(v.reg, __RISCV_FRM_RNE, VEC_ELEM_NUM);
// 行 982 改为：
: reg(RVVI3(__riscv_vfncvtbf16_f_f_w_bf16, LMUL_128, _rm)(v.reg, __RISCV_FRM_RNE, VEC_ELEM_NUM)) {
// 行 985 改为：
: reg(RVVI3(__riscv_vfncvtbf16_f_f_w_bf16, LMUL_256, _rm)(v.reg, __RISCV_FRM_RNE, VEC_ELEM_NUM)) {
```

`RVVI3(base, lmul, suffix)` 宏（`cpu_types_riscv_defs.hpp:41`）展开为 `base##lmul##suffix`，即 `__riscv_vfncvt_f_f_w_f16m2_rm`。

### 修复范围

- 改动文件：`csrc/cpu/cpu_types_riscv_impl.hpp`（4 处）
- 改动行数：约 4 行
- 不影响其他架构（文件仅在 `__riscv_vector` 定义时编译）

### 与 #47983 的关系

F001 与 #47983 属于相近的浮点舍入问题，但验证范围和目标转换类型不同：

- #47983 覆盖 `vfcvt_x_f_v_i32`（FP32→INT32），已有提交者在 Spacemit X100 上的实测数据。
- F001 覆盖 `vfncvt_f_f_w` / `vfncvtbf16_f_f_w`（FP32→FP16/BF16），尚无实测数据。

应先独立验证 F001 的机制是否在实际编译中成立，再决定作为 #47983 的补充提交或独立 follow-up PR。不应在验证前直接合并。
