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

- **非 `_rm` 变体**（如 `__riscv_vfncvt_f_f_w_f16m2`）：映射到 `vfncvt.f.f.w` 指令，舍入模式由 `fcsr.frm` 字段决定。指令编码中 `rm=111`（dynamic），在运行时读取 `fcsr.frm`。
- **`_rm` 变体**（如 `__riscv_vfncvt_f_f_w_f16m2_rm`）：同样映射到 `vfncvt.f.f.w` 指令，但接受显式舍入模式参数（如 `__RISCV_FRM_RNE`），编译器将其直接编码到指令的 `rm` 字段中（如 `rm=000` for RNE），不读取 `fcsr.frm`。

### `FENV_ACCESS` 与编译器行为

C/C++ 标准默认 `FENV_ACCESS` 为 OFF，编译器可假设浮点环境未被修改。在此假设下：

- 编译器**可能**将非 `_rm` intrinsic 优化为使用默认 RNE（因为 `fcsr.frm` 初始值为 RNE）。
- 但如果同一翻译单元或链接代码中有路径修改了 `fcsr.frm`（如通过 `fesetround()`），且编译器未感知该修改，则非 `_rm` intrinsic 的行为可能不符合预期。
- 此行为在 C 标准下属于未定义行为（`FENV_ACCESS` OFF 时修改浮点环境的效果未定义）。

### 尚未验证的假设

- 非 `_rm` intrinsic 在当前 vLLM 编译环境下**一定**导致不可接受的动态舍入依赖——尚未验证编译器是否已将其优化为静态 RNE。
- vLLM 此处语义**必须**固定为 RNE——尚未确认 vLLM 是否有代码路径修改 `fcsr.frm`。
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
      → __riscv_vfncvt_f_f_w_f16m4(v.reg, 16)   // 非 _rm，读 fcsr.frm
```

`FP16Vec16(const FP32Vec16&)` 用于将 FP32 计算结果转回 FP16 存储。调用场景包括 KV cache 写入和注意力输出存储。

### FP32→BF16 转换链路

```
模型前向计算
  → FP32 中间结果存储为 BF16
    → BF16Vec8::BF16Vec8(const FP32Vec8& v)     [cpu_types_riscv_impl.hpp:981-983]
      → __riscv_vfncvtbf16_f_f_w_bf16m2(v.reg, 8)  // 非 _rm，读 fcsr.frm
    → BF16Vec16::BF16Vec16(const FP32Vec16& v)   [cpu_types_riscv_impl.hpp:984-986]
      → __riscv_vfncvtbf16_f_f_w_bf16m4(v.reg, 16) // 非 _rm，读 fcsr.frm
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

- 非 `_rm` intrinsic 映射到 `rm=111`（dynamic）指令编码，运行时读 `fcsr.frm`。
- `fcsr.frm` 默认值为 RNE（`000`）。

### 推断（尚未验证）

- 若 `fcsr.frm` 被改为非 RNE 模式，FP32→FP16/BF16 的舍入结果可能不同。
- 对推理输出精度有潜在影响，且难以调试（结果依赖调用历史）。

### 尚未验证

- vLLM 中是否存在修改 `fcsr.frm` 的代码路径。
- 编译器是否已将非 `_rm` intrinsic 优化为静态 RNE（基于 `FENV_ACCESS` OFF 假设）。
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

**机制可信度（高）**：源码确认 4 处非 `_rm` intrinsic 调用存在；RISC-V ISA 和 Vector C Intrinsics 规范确认非 `_rm` 变体读 `fcsr.frm`；`_rm` 变体存在且接受显式舍入参数。

**缺陷结论可信度（中）**：非 `_rm` intrinsic 在默认 `fcsr.frm=RNE` 下行为正确；是否产生实际非确定性取决于是否有代码修改 `fcsr.frm`，当前未确认；编译器在 `FENV_ACCESS` OFF 下可能已优化为静态 RNE；跨架构 BF16 舍入语义本就不一致（部分路径使用截断），RISC-V 的非 `_rm` intrinsic 在默认状态下反而比截断路径更接近 RTE。

## 9. 验证建议

### 最小独立验证程序

编写独立 C 程序，不依赖完整 vLLM 编译：

1. **输入构造**：选择舍入边界附近的 FP32 值（如恰好位于两个可表示 FP16/BF16 值中间的值）。
2. **舍入模式设置**：分别设置 `fcsr.frm` 为 RNE、RTZ、RDN、RUP（通过 `fesetround()` 或直接写 `fcsr`）。
3. **输出比较**：比较非 `_rm` intrinsic 和 `_rm` intrinsic 在各舍入模式下的 FP16/BF16 输出位模式。
4. **汇编检查**：`objdump -d` 查看编译器是否将非 `_rm` intrinsic 优化为静态 `rm` 编码，还是保留 `rm=111`（dynamic）。
5. **`FENV_ACCESS` 测试**：分别在 `#pragma STDC FENV_ACCESS ON` 和默认 OFF 下编译，比较汇编差异。
6. **跨架构对比**：在 x86 和 ARM 上运行等价程序，比较输出。

### 预期结果

- 若编译器将非 `_rm` 优化为静态 RNE：非 `_rm` 和 `_rm` 在所有 `frm` 下输出相同 → 问题不成立。
- 若编译器保留 `rm=111`：非 `_rm` 输出随 `frm` 变化，`_rm` 固定 → 机制确认，需进一步验证 vLLM 是否有路径修改 `frm`。

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
