# 参考文档

## RISC-V ISA

- RISC-V ISA Manual（F/S/V 扩展）：<https://docs.riscv.org/reference/isa/v20260120/unpriv/f-st-ext.html>
  - `vfcvt.x.f.v`：FP→INT，舍入由 `frm` 决定
  - `vfncvt.f.f.w`：FP32→FP16 缩窄，舍入由 `frm` 决定
  - `vfwcvt.f.f.v`：FP16→FP32 宽化，精确（无舍入）
  - `vfcvt.f.x.v`：INT→FP，大值需舍入（由 `frm` 决定）

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
