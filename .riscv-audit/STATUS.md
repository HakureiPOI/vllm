# 审计状态

## 基线信息

| 项目 | 值 |
|---|---|
| 审计分支 | `audit/riscv` |
| 基线提交 | `6fbbcf215` |
| 上游同步 | upstream/main @ 2026-07-29 |
| 参考文档 | `D:\Notes\riscv-ai-infra-issues\projects\vllm.md`（截止 2026-07-27） |

## 审计范围

- `vllm/platforms/` 架构识别与能力检测
- `vllm/v1/attention/backends/cpu_attn.py` 运行时 ISA 派发
- `csrc/cpu/` CPU/RISC-V/RVV 实现与条件编译
- `cmake/cpu_extension.cmake` 构建配置
- `vllm/utils/` OMP 绑定、CPU 资源、lscpu 解析
- `vllm/engine/arg_utils.py` 平台特定参数
- `vllm/model_executor/kernels/linear/mixed_precision/cpu.py` 算子选择

## 发现汇总

新增候选问题 2 个；跟踪中的已知开放问题 2 个；已知限制或设计问题 1 个。

### 新的候选问题

| 编号 | 标题 | 可信度 | 状态 |
|---|---|---|---|
| F001 | FP32→FP16/BF16 缩窄转换未显式固定舍入模式 | 机制高，缺陷结论中 | 需要行为与语义验证 |
| F004 | RISC-V 交叉编译使用构建主机 /proc/cpuinfo 判断目标 FP16/BF16 能力 | 中高 | 构建链问题较明确，修复设计待完善 |

### 已知且已有开放 PR

| 编号 | 标题 | 上游 PR | 状态 |
|---|---|---|---|
| F002 | `vfcvt_x_f_v_i32` 浮点转整数使用动态舍入模式 | #47983 OPEN | `tracked-upstream` `known-open-pr` |
| F003 | `_riscv_supports_rvv()` `/proc/cpuinfo` fallback 可产生假阳性 | #48487 OPEN | `tracked-upstream` `behavior-reproduced` `known-open-pr` |

### 已知限制或待研究设计问题

| 编号 | 标题 | 分类 |
|---|---|---|
| F005 | RISC-V BF16 优化依赖 cpuinfo 或显式 override，内核漏报时默认构建可能无法启用 BF16 优化 | `known limitation` `configuration usability` `performance feature detection` |

详见 `analyses/open-questions/bf16-detection-cpuinfo-override.md`。

### 当前基线已修复或已排除

详见 `analyses/dedup-already-fixed.md`：

| 调研案例 | 状态 | 修复 PR |
|---|---|---|
| A1 SG2044 无 zvl 标志 | 部分修复 | #43179 MERGED |
| A2 仅支持 VLEN=128 | 已修复 | #47532 MERGED |
| A3 VLEN 自动检测读构建主机 | 部分修复 | #47532 MERGED（VLEN 守卫），cat /proc/cpuinfo 仍未守卫 → F004 |
| A4 VLEN 512/1024 触发 #error | 已修复 | #47532 MERGED |
| C exp() 多项式下溢 NaN | 已修复 | #40428 MERGED |
| E float32 限制 | 已移除 | #36578 MERGED |

## 下一步

1. F001：编写最小独立验证程序，检查编译器如何按照 implicit rounding 语义处理默认浮点环境
2. F004：完善修复设计，区分目标基础架构/可选扩展/本机自动探测三个层次
3. F002/F003：持续跟踪 #47983 和 #48487 的上游合并状态
4. 继续审计 `csrc/cpu/micro_gemm/` 和量化路径
5. 检查 CI 配置中是否有 RISC-V 覆盖
