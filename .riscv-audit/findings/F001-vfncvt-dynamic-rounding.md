# F001: `vfncvt.f.f.w` / `vfncvtbf16.f.f.w` 缩窄浮点转换使用动态舍入模式

## 1. 问题标题

RVV 缩窄浮点转换（FP32→FP16/BF16）使用非 `_rm` intrinsic 形式，结果依赖 `fcsr.frm` 动态舍入模式。

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

`RVVI(base, lmul)` 宏展开为 `base##lmul`，即非 `_rm` 变体。

## 3. 问题描述

RISC-V V 扩展中，`vfncvt.f.f.w`（FP32→FP16）和 `vfncvtbf16.f.f.w`（FP32→BF16）是缩窄浮点转换，需要舍入。根据 RISC-V ISA Manual，这些指令的舍入模式由 `fcsr.frm` 字段决定。

GCC/Clang 的 RVV intrinsic 提供两种形式：
- 非 `_rm` 变体（如 `__riscv_vfncvt_f_f_w_f16m2`）：读 `fcsr.frm` 动态舍入模式
- `_rm` 变体（如 `__riscv_vfncvt_f_f_w_f16m2_rm`）：接受显式舍入模式参数

当前代码使用非 `_rm` 变体，因此转换结果依赖线程当前的 `fcsr.frm` 值。若调用前有代码改变 `frm`（如通过 `fesetround()` 或其他 RVV 指令的副作用），相同输入可能得到不同结果。

## 4. 触发条件

- RISC-V 架构（rv64gcv）
- 启用 RVV（`__riscv_v_min_vlen` 定义为 128 或 256）
- FP16 路径：`__riscv_zvfh` 定义（行 940/943 在 `FP16Vec` 构造函数中，无 `#ifdef` 守卫，但整个文件仅在 RVV 编译时包含）
- BF16 路径：`__riscv_zvfbfmin` 定义（行 982/985 在 `#ifdef __riscv_zvfbfmin` 块内）
- 调用前有线程代码改变 `fcsr.frm`（如从 RNE 改为 RTZ/RDN/RUP/RMM）

## 5. 调用链与证据

### FP32→FP16 转换链路

```
模型前向计算
  → FP32 中间结果存储为 FP16
    → FP16Vec16::FP16Vec16(const FP32Vec16& v)  [行 939-941]
      → __riscv_vfncvt_f_f_w_f16m4(v.reg, 16)   // 非 _rm，读 fcsr.frm
```

`FP16Vec16(const FP32Vec16&)` 在 `cpu_types_riscv_impl.hpp:939-941` 定义，用于将 FP32 计算结果转回 FP16 存储。调用场景包括：
- KV cache 写入（`reshape_and_cache` 中 `scalar_t` 为 `c10::Half` 时）
- 注意力输出存储
- 任何 FP16 模型的中间结果持久化

### FP32→BF16 转换链路

```
模型前向计算
  → FP32 中间结果存储为 BF16
    → BF16Vec8::BF16Vec8(const FP32Vec8& v)     [行 981-983]
      → __riscv_vfncvtbf16_f_f_w_bf16m2(v.reg, 8)  // 非 _rm，读 fcsr.frm
    → BF16Vec16::BF16Vec16(const FP32Vec16& v)   [行 984-986]
      → __riscv_vfncvtbf16_f_f_w_bf16m4(v.reg, 16) // 非 _rm，读 fcsr.frm
```

### ISA 依据

RISC-V ISA Manual（`vfncvt.f.f.w` 指令说明）：
> "The result is rounded to the narrower precision according to the rounding mode in `frm`."

参考链接：<https://docs.riscv.org/reference/isa/v20260120/unpriv/f-st-ext.html>

### 与 x86/ARM 对比

- x86 AVX-512：`_mm512_cvtps_ph` 接受显式舍入模式参数（`_MM_FROUND_TO_NEAREST_INT`）
- ARM NEON：`vcvtnq_s32_f32` 硬编码 RNE（round to nearest, ties away from zero）

两者均不依赖动态舍入环境。

## 6. 潜在影响

- **数值正确性与可复现性**：若 `fcsr.frm` 被改为非 RNE 模式，FP32→FP16/BF16 的舍入结果不同。对推理输出精度有影响，且难以调试（结果依赖调用历史）。
- **影响范围**：所有 FP16/BF16 模型在 RISC-V RVV 路径上的输出存储。BF16 是 RISC-V 上最常用的训练/推理 dtype 之一。
- **不构成安全漏洞**：无 CVE/GHSA 关联，无上游安全公告。本发现仅作为正确性/可复现性问题记录。

## 7. 去重检查

- **当前分支代码**：4 处 `vfncvt` 调用确认存在（grep `__riscv_vfncvt` 在 `csrc/cpu/`）。
- **已有测试**：`tests/kernels/attention/test_cpu_attn.py` 未覆盖舍入模式非确定性。
- **调研文档**：案例 B（#47983）仅覆盖 `vfcvt_x_f_v_i32`（FP32→INT32），**未覆盖** `vfncvt_f_f_w`（FP32→FP16）和 `vfncvtbf16_f_f_w`（FP32→BF16）。本发现是 #47983 的**补集**，非重复。
- **历史 PR**：#47983（OPEN）的 diff 仅修改 `cpu_types_riscv_impl.hpp` 中 3 处 `vfcvt_x_f_v_i32`，未触及 4 处 `vfncvt`。

## 8. 可信度

**高**。源码调用链完整，RISC-V ISA Manual 明确 `vfncvt.f.f.w` 依赖 `frm`，4 处调用位置明确。与 #47983 已确认的 `vfcvt_x_f_v_i32` 问题同构。

## 9. 验证建议

1. **编译验证**：在 RISC-V RVV 环境（VLEN=128 或 256）编译 vLLM CPU 扩展，确认 4 处 `vfncvt` 调用存在。
2. **运行验证**：在 Spacemit X100 或 SG2044 上，用 `fesetround(FE_TOWARDZERO)` 改变 `frm`，跑 FP16/BF16 模型，对比输出与 RNE 模式下的差异。
3. **汇编检查**：`objdump -d` 查看 `_C.so` 中 `vfncvt.f.f.w` 指令是否编码 `rm=111`（动态）。

## 10. 修复思路

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

注意：`RVVI3(base, lmul, suffix)` 宏展开为 `base##lmul##suffix`，即 `__riscv_vfncvt_f_f_w_f16m2_rm`。

### 修复范围

- 改动文件：`csrc/cpu/cpu_types_riscv_impl.hpp`（4 处）
- 改动行数：约 4 行
- 不影响其他架构（文件仅在 `__riscv_vector` 定义时编译）
- 可补充测试：在 `test_cpu_attn.py` 中添加舍入模式确定性测试

### 与 #47983 的关系

本修复是 #47983 的补充。#47983 修复 3 处 `vfcvt_x_f_v_i32`（FP32→INT32），本修复覆盖 4 处 `vfncvt`（FP32→FP16/BF16）。两者可合并为一个 PR，或作为 #47983 的后续 PR。建议合并为一个 PR，因为根因相同（动态舍入模式非确定性），且修复方式一致。
