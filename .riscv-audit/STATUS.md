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

### 候选缺陷

| 编号 | 标题 | 可信度 | 状态 | 对应调研案例 |
|---|---|---|---|---|
| F001 | `vfncvt.f.f.w` / `vfncvtbf16.f.f.w` 缩窄浮点转换使用动态舍入模式 | 高 | 新发现 | 无（#47983 未覆盖） |
| F002 | `vfcvt_x_f_v_i32` 浮点转整数使用动态舍入模式 | 高 | 待修复 | 案例 B（#47983 OPEN） |
| F003 | `_riscv_supports_rvv()` `/proc/cpuinfo` fallback 可产生假阳性 | 高 | 待修复 | 案例 A5（#48487 OPEN） |
| F004 | 交叉编译时 `cat /proc/cpuinfo` 与 `find_isa` 未被守卫 | 中 | 待修复 | 案例 A3 残留 |
| F005 | BF16 能力检测未迁移到 native probe | 中 | 待修复 | 案例 A BF16（#45243 背景） |

### 已修复问题（去重记录）

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

1. 对 F001-F005 进行深度验证（编译/运行测试）
2. 对证据充分的问题创建 `fix/riscv-xxx` 修复分支
3. 继续审计 `csrc/cpu/micro_gemm/` 和量化路径
4. 检查 CI 配置中是否有 RISC-V 覆盖
