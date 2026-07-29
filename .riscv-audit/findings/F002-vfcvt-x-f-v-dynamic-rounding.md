# F002: `vfcvt_x_f_v_i32` 浮点转整数使用动态舍入模式

## 1. 问题标题

RVV 浮点转整数（FP32→INT32）使用非 `_rm` intrinsic 形式，结果依赖 `fcsr.frm` 动态舍入模式。

## 2. 涉及位置

- `csrc/cpu/cpu_types_riscv_impl.hpp:521` — `FP32Vec8::exp()` 中 `vfcvt_x_f_v_i32`
- `csrc/cpu/cpu_types_riscv_impl.hpp:787` — `FP32Vec16::exp()` 中 `vfcvt_x_f_v_i32`
- `csrc/cpu/cpu_types_riscv_impl.hpp:886` — `INT8Vec16::INT8Vec16(const FP32Vec16&)` 中 `vfcvt_x_f_v_i32`

关键代码：

```cpp
// 行 521 (FP32Vec8::exp)
fixed_i32x8_t n_int =
    RVVI(__riscv_vfcvt_x_f_v_i32, LMUL_256)(x_scaled, VEC_ELEM_NUM);
// 行 787 (FP32Vec16::exp)
fixed_i32x16_t n_int =
    RVVI(__riscv_vfcvt_x_f_v_i32, LMUL_512)(x_scaled, VEC_ELEM_NUM);
// 行 886 (INT8Vec16 构造)
auto i32_vec =
    RVVI(__riscv_vfcvt_x_f_v_i32, LMUL_512)(vec.reg, VEC_ELEM_NUM);
```

## 3. 问题描述

`vfcvt.x.f.v` 将 FP32 转为 INT32，需要舍入。非 `_rm` 变体读 `fcsr.frm` 动态舍入模式。若 `frm` 被改变，相同输入得到不同 INT32 结果。

## 4. 触发条件

- RISC-V 架构，启用 RVV
- `exp()` 路径：softmax 等依赖 exp 的计算
- `INT8Vec16` 构造：INT8 量化路径
- 调用前有线程代码改变 `fcsr.frm`

## 5. 调用链与证据

### exp() 路径

```
softmax → FP32Vec8/16::exp()
  → x_scaled = x * inv_ln2
  → n_int = __riscv_vfcvt_x_f_v_i32(x_scaled)  // 行 521/787，读 fcsr.frm
  → r = x_scaled - vfcvt_f_x_v_f32(n_int)       // 行 523/789，INT32→FP32 精确
  → poly = ... (多项式近似)
  → return poly * scale
```

### INT8 量化路径

```
FP32 计算结果 → INT8Vec16(vec)
  → i32_vec = __riscv_vfcvt_x_f_v_i32(vec.reg)  // 行 886，读 fcsr.frm
  → i16_vec = vnclip_wx_i16(i32_vec, 0, __RISCV_VXRM_RNU)  // 行 888，显式整数舍入
  → reg = vnclip_wx_i8(i16_vec, 0, __RISCV_VXRM_RNU)        // 行 889，显式整数舍入
```

注意：`vnclip` 已使用显式 `__RISCV_VXRM_RNU`，但上游 `vfcvt_x_f_v_i32` 未使用显式舍入。

### ISA 依据

RISC-V ISA Manual：`vfcvt.x.f.v` 的舍入由 `frm` 字段决定。

### 提交者报告（#47983）

#47983 作者在 Spacemit X100 实测，`frm` 从 RNE 改为其他模式时，42.2% 的 INT8 值发生变化（提交者自报，未独立复现）。

## 6. 潜在影响

- **exp() 非确定性**：`frm` 非 RNE 时，`x * inv_ln2` 的整数舍入不同，导致 exp 多项式分解不同，最终结果微小偏差。
- **INT8 量化非确定性**：`frm` 非 RNE 时，FP32→INT32 舍入不同，影响 INT8 量化输出。
- **可复现性**：结果依赖调用历史，难以调试。

## 7. 去重检查

- **调研文档**：案例 B（#47983）完整覆盖此问题。
- **当前分支**：3 处 `vfcvt_x_f_v_i32` 确认存在，#47983 未合并。
- **F001 关系**：F001 覆盖 `vfncvt`（FP32→FP16/BF16），本发现覆盖 `vfcvt_x_f_v_i32`（FP32→INT32），两者是 #47983 的补集与本体。

## 8. 可信度

**高**。#47983 已提供完整分析与提交者实测数据。源码确认 3 处调用使用非 `_rm` 变体。

## 9. 验证建议

见 F001 验证建议。额外：在 Spacemit X100 上用 `fesetround` 改变 `frm`，跑 INT8 量化模型对比输出。

## 10. 修复思路

#47983 已提出修复：将 3 处 `vfcvt_x_f_v_i32` 改为 `_rm` 变体，传入 `__RISCV_FRM_RNE`。

建议将 F001（4 处 `vfncvt`）与本发现（3 处 `vfcvt_x_f_v_i32`）合并为一个 PR，共 7 处修改，根因相同，修复方式一致。
