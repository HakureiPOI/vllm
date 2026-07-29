# 参考文档

## RISC-V V Extension

ISA Manual — Vector Extension：
- `vfcvt.x.f.v`：FP→INT 转换，使用 `fcsr.frm` 控制舍入
- `vfcvt.f.x.v`：INT→FP 转换，大值需舍入（使用 `fcsr.frm`）
- `vfncvt.f.f.w`：FP32→FP16 缩窄转换，使用 `fcsr.frm` 控制舍入
- `vfwcvt.f.f.v`：FP16→FP32 宽化转换，精确（无舍入）
- `fcsr.frm` 字段：舍入模式控制（RNE, RTZ, RDN, RUP, RMM）

RVV 浮点向量指令使用 `fcsr.frm` CSR 控制舍入模式。

参考：<https://docs.riscv.org/reference/isa/unpriv/v-st-ext.html>

## RISC-V BF16 Extension

ISA Manual — Zvfbfmin/Zvfbfwma Extension：
- `vfncvtbf16.f.f.w`：FP32→BF16 缩窄转换，使用 `fcsr.frm` 控制舍入
- `vfwcvtbf16.f.f.v`：BF16→FP32 宽化转换，精确（无舍入）
- `zvfbfmin`：BF16 向量加载/存储扩展
- `zvfbfwma`：BF16 宽化乘加扩展

参考：<https://docs.riscv.org/reference/isa/unpriv/bfloat16.html>

## RISC-V Vector C Intrinsics Specification

### 官方规范（首要来源）

**RISC-V Vector C Intrinsics Specification v1.0** 是 implicit/explicit rounding intrinsic 语义的权威来源。

首要来源（RISC-V 官方 Ratified Specifications Library）：
- Vector C Intrinsics 入口：<https://docs.riscv.org/reference/vector-c-intrinsics/index.html>
- v1.0 规范正文：<https://docs.riscv.org/reference/vector-c-intrinsics/v1.0/rvv-intrinsic-spec.html>

辅助来源（规范 GitHub 仓库，源码和版本历史）：
- <https://github.com/riscv-non-isa/rvv-intrinsic-doc>

### ISA 规范与 intrinsic 规范的区别

- **ISA 规范**（V Extension、BF16 Extension）：描述 RVV 指令使用 `fcsr.frm` 的硬件语义。
- **Vector C Intrinsics 规范**：描述 implicit 和 explicit `_rm` intrinsic 的语言接口语义，以及编译器需要承担的浮点环境管理责任。

两者不应混淆：ISA 指令的硬件行为不等于 C intrinsic 的可观察语义。

### 隐式舍入 intrinsic（非 `_rm` 变体）

- 如 `__riscv_vfncvt_f_f_w_f16m2(op, vl)`
- 属于 implicit rounding intrinsic
- 在默认浮点环境下使用规范规定的默认舍入语义
- 当浮点环境访问被启用时，遵循当前浮点环境和 `fcsr.frm`
- 具体机器码和 CSR 管理由编译器按照 Vector C Intrinsics 规范实现

### 显式舍入 intrinsic（`_rm` 变体）

- 如 `__riscv_vfncvt_f_f_w_f16m2_rm(op, rmode, vl)`
- 属于 explicit rounding intrinsic，要求使用参数指定的舍入模式
- `rmode` 参数取值：`__RISCV_FRM_RNE`、`__RISCV_FRM_RTZ`、`__RISCV_FRM_RDN`、`__RISCV_FRM_RUP`、`__RISCV_FRM_RMM`
- 编译器可能通过设置 `fcsr.frm`、临时保存旧 `fcsr.frm`、执行向量转换、恢复旧 `fcsr.frm` 的方式实现
- 或采用其他符合规范的 CSR 管理方式
- `_rm` intrinsic 可能因此引入额外的 `frm` 保存和恢复开销

### `FENV_ACCESS` 相关语义

- C/C++ 标准 `FENV_ACCESS` 的默认状态影响编译器对浮点环境的假设
- `FENV_ACCESS` OFF（C/C++ 默认）：编译器可假设浮点环境未被修改
- `FENV_ACCESS` ON（`#pragma STDC FENV_ACCESS ON`）：编译器不再假设浮点环境未被修改
- implicit rounding intrinsic 的行为受 `FENV_ACCESS` 状态影响
- explicit `_rm` intrinsic 不依赖 `FENV_ACCESS` 状态

### 辅助来源（GCC/LLVM 文档）

GCC 和 LLVM 文档作为辅助来源，不应取代正式规范：

- GCC RISC-V intrinsic 文档：<https://gcc.gnu.org/onlinedocs/gcc/RISC-V-Vector-Loops.html>
- Clang RISC-V intrinsic 文档：<https://llvm.org/docs/RISCV/RISCVVectorInstrinsics.html>

## 官方 auto-generated API tests

- GCC/Clang 的 RVV intrinsic 测试套件包含每个 intrinsic 的参数顺序和类型签名
- 可用于验证 `_rm` 变体的参数顺序（`op, rmode, vl` vs 非 `_rm` 的 `op, vl`）

参考：
- GCC testsuite: `gcc.target/riscv/rvv/`
- Clang testsuite: `test/CodeGen/RISCV/rvv/`

## vLLM 上游 PR

### 能力检测（案例 A 族）

- #43179（MERGED）：SG2044 无 zvl 标志时委托 C++ native probe
- #47532（MERGED，种子）：VLEN 检测三连修复（128/256 支持、交叉编译守卫、>256 clamp）
- #48487（OPEN，种子）：移除 /proc/cpuinfo fallback，仅信 native probe
- #45243（MERGED）：BF16 on VLEN=256，添加 VLLM_CPU_RVV_BF16 override

### 数值正确性（案例 B/C）

- #40428（MERGED）：exp() input clamp 防 NaN
- #47983（OPEN，种子）：vfcvt_x_f_v_i32 改用 _rm 显式舍入（仅覆盖 3 处，未覆盖 4 处 vfncvt）

### OMP 绑定（案例 D）

- #40569（MERGED）：RISC-V auto-bind，复用 ARM 分支
- #41888（CLOSED/DRAFT）：CI 分析器自动生成的回退提案，未合并

### 段错误（案例 E）

- #25655（CLOSED）：SG2044 段错误报告
- #26228（MERGED）：float32 限制 workaround
- #36578（MERGED）：移除 float32 限制，重新开放 FP16/BF16

### 构建/工具链

- #24951（MERGED）：显式 `#include <omp.h>`
- #40427（MERGED）：lscpu 解析 bare `-`
- #40575（MERGED）：libgomp fallback
- #41912（CLOSED）：fp8 tag stubs for GCC 15
- #41913（CLOSED）：compiler-provided `__riscv_zvfbfmin`

### 量化/kernel

- #44478（MERGED）：oneDNN W8A8 INT8 on RISC-V
- #44523（MERGED）：W4A8 scalar fallback
- #45269（MERGED）：W4A8 RVV path
- #47538（MERGED，种子）：LMUL 寄存器压力优化

## 本地调研文档

- `D:\Notes\riscv-ai-infra-issues\projects\vllm.md`（截止 2026-07-27）
