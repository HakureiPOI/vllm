# vLLM RISC-V 静态审计

本目录存放对 `vllm-project/vllm` 中 RISC-V 相关代码的静态审计产物。

## 审计基线

- 分支：`audit/riscv`（跟踪 `upstream/main`）
- 基线提交：`6fbbcf215`（upstream/main @ 2026-07-29）
- 参考调研文档：`D:\Notes\riscv-ai-infra-issues\projects\vllm.md`（截止 2026-07-27）

## 目录结构

```
.riscv-audit/
├── README.md          本文件
├── STATUS.md          审计状态与发现汇总
├── findings/          候选缺陷记录（按编号）
├── analyses/          深度分析与去重记录
├── evidence/          源码证据快照
├── references/        官方文档引用
├── scripts/           静态分析脚本
└── tmp/               临时分析记录
```

## 发现编号规则

- `F0xx`：候选缺陷编号
- 已修复问题记录在 `analyses/dedup-already-fixed.md`，不分配 F 编号

## 工作原则

- 仅进行静态审计，不修改源码
- 每个发现需独立验证当前分支代码状态
- 与参考调研文档去重，不重复报告已修复问题
- 证据不足时不夸大影响
