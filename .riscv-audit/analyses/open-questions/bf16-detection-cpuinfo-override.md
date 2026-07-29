# RISC-V BF16 优化依赖 cpuinfo 或显式 override，内核漏报时默认构建可能无法启用 BF16 优化

> **分类**：`known limitation` `configuration usability` `performance feature detection`
>
> 本文件不是候选缺陷。#45243（MERGED）已引入 `VLLM_CPU_RVV_BF16=1` 作为 workaround，上游已接受该设计。当前问题主要是自动配置能力和用户体验，不是已确认的功能正确性缺陷。

## 问题描述

RISC-V BF16 能力检测仍依赖 `/proc/cpuinfo` 的 `zvfbfmin` 字符串和环境变量 override，未像 RVV 检测那样迁移到 C++ 编译期 native probe。

Spacemit X100/K3 的内核/固件不在 `/proc/cpuinfo` 报告 `zvfbfmin`（尽管硬件支持），导致 BF16 被静默禁用。用户必须手动设 `VLLM_CPU_RVV_BF16=1`，且该 override 是 unchecked（不验证硬件是否真的支持）。

## 涉及位置

- `cmake/cpu_extension.cmake:110` — `find_isa(${CPUINFO} "zvfbfmin" RVV_BF16_FOUND)`
- `cmake/cpu_extension.cmake:122-128` — `VLLM_CPU_RVV_BF16` 环境变量 override
- `cmake/cpu_extension.cmake:239-241` — 基于 `RVV_BF16_FOUND` 选择 `-march` 标志

## 当前状态

- #45243（MERGED）已明确引入 `VLLM_CPU_RVV_BF16=1` 作为 workaround。
- 上游已经接受该设计。
- 当前问题主要是自动配置能力和用户体验，而不是已确认的功能正确性缺陷。
- unchecked override 可能在错误硬件上产生 SIGILL 风险，但这是已明确告知用户的配置责任。

## 关于运行时 native probe 的限制

运行时 native probe（如 `cpu_attn_has_isa`）只能判断当前二进制已经编译进了什么能力，不能反向决定当前二进制在 CMake 阶段应使用什么 `-march`。运行时探测是构建后的验证，不是构建期的配置来源。

因此，"将 BF16 检测迁移到 native probe"不能解决构建期 `-march` 选择问题。构建期需要的是工具链能力检测或用户显式声明。

## 关于 try_compile 的限制

`try_compile` 只能证明工具链是否接受某个扩展（如 `-march=...zvfbfmin...` 能否编译），不能证明目标硬件实际支持该扩展。工具链接受 ≠ 硬件支持。

因此，`try_compile` 可用于交叉编译时验证工具链能力，但不能替代用户对目标硬件能力的显式声明。

## 与 F004 的关系

- **F004**：交叉编译时能力来源错误（读构建主机 cpuinfo）。
- **本问题**：本机构建时硬件能力信息可能漏报（X100/K3 不报 `zvfbfmin`）。

两者有交集（都涉及 BF16 能力检测），但不是完全相同的问题：
- F004 是交叉编译场景下的信息源错误。
- 本问题是本机构建场景下的硬件能力漏报。

## 下一步

- 不作为独立候选缺陷。
- 待 F004 修复设计确定后，评估是否一并改善 BF16 自动检测体验。
- 可考虑添加 `VLLM_CPU_RVV_FP16` 环境变量（当前 FP16 无 override），或允许显式 `-march` 字符串。
