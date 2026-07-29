# 去重记录：已修复问题

本文件记录参考调研文档中已在当前分支修复的问题，避免重复报告。

基线：`upstream/main@6fbbcf215`（audit/riscv 分支）

## 案例 A：RVV attention 能力检测不一致

### A1：SG2044 无 zvl 标志导致假阴性 — 部分修复

- **调研案例**：A1（#43179 MERGED）
- **问题**：SG2044 的 `/proc/cpuinfo` 不报 `zvl<N>b`，导致 `_get_attn_isa()` 回退到 `"vec"`。
- **当前状态**：部分修复。`cpu_attn_has_isa("rvv")` 已添加（`cpu_attn.cpp:14-24`），检查 `__riscv_v_min_vlen == 128 || == 256`。Python 端 `_riscv_supports_rvv()` 优先信 native probe（`cpu_attn.py:447-453`）。
- **残留**：`/proc/cpuinfo` fallback 仍存在（F003），可产生假阳性。#48487（OPEN）未合并。

### A2：仅支持 VLEN=128，排除 VLEN=256 — 已修复

- **调研案例**：A2（#47532 第①点 MERGED）
- **问题**：`cpu_attn_has_isa("rvv")` 只判 `__riscv_v_min_vlen == 128`，排除 VLEN=256。
- **当前状态**：已修复。`cpu_attn.cpp:17` 现在检查 `__riscv_v_min_vlen == 128 || __riscv_v_min_vlen == 256`。`cpu_attn_rvv.hpp:14-15` 同样守卫。

### A3：交叉编译读构建主机 cpuinfo — 部分修复

- **调研案例**：A3（#47532 第②点 MERGED）
- **问题**：CMake VLEN 自动检测无条件读 `/proc/cpuinfo`，交叉编译时描述构建主机。
- **当前状态**：部分修复。VLEN 自动检测已加 `CMAKE_CROSSCOMPILING` 守卫（`cpu_extension.cmake:203-204`）。
- **残留**：`cat /proc/cpuinfo`（行 60-67）和 `find_isa`（行 109-110）未守卫（F004）。

### A4：VLEN 512/1024 触发 #error — 已修复

- **调研案例**：A4（#47532 第③点 MERGED）
- **问题**：自动检测选 VLEN=512/1024，触发 `cpu_types_riscv_defs.hpp` 的 `#error`。
- **当前状态**：已修复。`cpu_extension.cmake:214-218` 在 `_best > 256` 时 clamp 到 256。

### A5：/proc/cpuinfo 覆盖 native False — 未修复

- **调研案例**：A5（#47532 → #48487 OPEN）
- **问题**：`_riscv_supports_rvv()` 的 `/proc/cpuinfo` fallback 可覆盖 native probe 的 False。
- **当前状态**：未修复。见 F003。

## 案例 B：vfcvt 动态舍入 — 未修复

- **调研案例**：B（#47983 OPEN）
- **当前状态**：未修复。3 处 `vfcvt_x_f_v_i32` 仍用非 `_rm` 变体。见 F002。
- **新发现**：4 处 `vfncvt_f_f_w` / `vfncvtbf16_f_f_w` 也有同类问题，#47983 未覆盖。见 F001。

## 案例 C：exp() 多项式下溢 NaN — 已修复

- **调研案例**：C（#40428 MERGED）
- **问题**：`FP32Vec8::exp()` / `FP32Vec16::exp()` 对大输入产生 NaN（`-inf * 0.0 = NaN`）。
- **当前状态**：已修复。`cpu_types_riscv_impl.hpp:511-515`（FP32Vec8）和 `777-781`（FP32Vec16）已加 clamp `[-87.3365447505, 88.7228391117]`。
- **边界精度**：review 中 gemini-code-assist 指出下界 `ln(FLT_MIN)` 使 `exp(-inf)` 返回 `FLT_MIN` 而非 0。当前代码未改用 `-103.0f`，边界精度可能有微小偏差，但不影响正确性（`FLT_MIN` 是正规格化最小值，非 NaN）。

## 案例 D：OMP 自动绑定 — 未确认

- **调研案例**：D（#40569 MERGED，#41888 CLOSED/DRAFT 未合并）
- **当前状态**：#40569 仍在主分支。`ompmultiprocessing.py:46-51`（`reserve_cpu_num`）、`142-144`（auto-bind `(ARM, RISCV)` 分支）、`182-183`（`enumerate` 日志）确认存在。
- **ARM CI 信号**：#41888 回退提案未合并，ARM CPU Test 挂起的因果关系未获维护者确认。本审计不作为缺陷输出。

## 案例 E：RISC-V 段错误 + float32 限制 — 限制已移除

- **调研案例**：E（#25655 CLOSED，#26228 MERGED workaround，#36578 MERGED 移除限制）
- **当前状态**：#26228 的 float32 限制已移除。`vllm/platforms/cpu.py:65-66` 现在返回 `[torch.bfloat16, torch.float16, torch.float32]`。
- **段错误根因**：#25655 的异常 `physical_block_idx` 根因未定位。#36578 后 RVV attention 路径重写（#40119/#42943），是否仍可复现未知。本审计不作为缺陷输出（证据不足）。
- **chunked prefill**：RISC-V 仍禁用 chunked prefill 和 prefix caching（`arg_utils.py:2625-2641`），这是 #25816 的保留改动，非缺陷。

## 其他已修复/已排除

| 调研项 | 状态 | 说明 |
|---|---|---|
| #24951 `#include <omp.h>` | 已修复 | 显式包含已落地 |
| #40427 lscpu 解析 | 已修复 | `cpu_resource_utils.py:229-239` 处理 bare `-` |
| #40575 libgomp fallback | 已修复 | `cpu_extension.cmake:41-57` 有 fallback 逻辑 |
| #41912 fp8 tag stubs | 已修复 | `cpu_types_riscv_impl.hpp:27-28, 208-213, 348-353` 有 stubs |
| #41913 `__riscv_zvfbfmin` | 已采用 | `cpu_extension.cmake:239-241` 用 `zvfbfmin`，`RISCV_BF16_SUPPORT` 宏已移除 |
| #44478 oneDNN W8A8 | 已修复 | oneDNN 在 RISC-V 编译 |
| #44523 W4A8 scalar fallback | 已修复 | `mixed_precision/cpu.py:172-178` 有 RISC-V W4A8 路径 |
| #47538 LMUL 寄存器压力 | 已修复 | `cpu_types_riscv_impl.hpp:632-656` 用 32 位半拆分 |
