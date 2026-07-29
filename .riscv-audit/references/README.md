# 参考文档

## RISC-V V Extension

ISA Manual — Vector Extension：
- `vfcvt.x.f.v`：FP→INT 转换，舍入由 `frm` 决定
- `vfcvt.f.x.v`：INT→FP 转换，大值需舍入（由 `frm` 决定）
- `vfncvt.f.f.w`：FP32→FP16 缩窄转换，舍入由 `frm` 决定
- `vfwcvt.f.f.v`：FP16→FP32 宽化转换，精确（无舍入）
- `fcsr.frm` 字段：舍入模式控制（000=RNE, 001=RTZ, 010=RDN, 011=RUP, 100=RMM, 111=dynamic）

参考：<https://docs.riscv.org/reference/isa/v20260120/unpriv/v-ext.html>

## RISC-V BF16 Extension

ISA Manual — Zvfbfmin/Zvfbfwa Extension：
- `vfncvtbf16.f.f.w`：FP32→BF16 缩窄转换，舍入由 `frm` 决定
- `vfwcvtbf16.f.f.v`：BF16→FP32 宽化转换，精确（无舍入）
- `zvfbfmin`：BF16 向量加载/存储扩展
- `zvfbfwa`：BF16 宽化算术扩展

参考：<https://docs.riscv.org/reference/isa/v20260120/unpriv/zvfbfmin-zvfbfwa-ext.html>

## RISC-V Vector C Intrinsics Specification

GCC/Clang RVV intrinsic API：

### 隐式舍入 intrinsic（非 `_rm` 变体）

- 如 `__riscv_vfncvt_f_f_w_f16m2(op, vl)`
- 映射到 `vfncvt.f.f.w` 指令，编码 `rm=111`（dynamic）
- 运行时读 `fcsr.frm` 字段确定舍入模式
- 在 `FENV_ACCESS` OFF（C/C++ 默认）下，编译器可假设 `fcsr.frm` 未被修改

### 显式舍入 intrinsic（`_rm` 变体）

- 如 `__riscv_vfncvt_f_f_w_f16m2_rm(op, rmode, vl)`
- 同样映射到 `vfncvt.f.f.w` 指令，但舍入模式直接编码到指令 `rm` 字段
- 不读 `fcsr.frm`，行为与浮点环境无关
- `rmode` 参数取值：`__RISCV_FRM_RNE`、`__RISCV_FRM_RTZ`、`__RISCV_FRM_RDN`、`__RISCV_FRM_RUP`、`__RISCV_FRM_RMM`

### `FENV_ACCESS` 相关语义

- C/C++ 标准默认 `FENV_ACCESS` 为 OFF
- `FENV_ACCESS` OFF 时，编译器可假设浮点环境未被修改
- 若代码在 `FENV_ACCESS` OFF 下修改 `fcsr.frm`（如 `fesetround()`），行为未定义
- `#pragma STDC FENV_ACCESS ON` 显式开启浮点环境访问，编译器不再优化 `fcsr.frm` 读取

### ISA 指令行为与 C intrinsic 语义的区别

- ISA 指令（如 `vfncvt.f.f.w`）的 `rm=111` 编码在硬件层面始终读 `fcsr.frm`
- C intrinsic 的非 `_rm` 变体在源码层面读 `fcsr.frm`，但编译器可在 `FENV_ACCESS` OFF 下优化为静态编码
- `_rm` 变体在源码层面和编译层面都不读 `fcsr.frm`

参考：
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
