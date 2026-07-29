# F003: `_riscv_supports_rvv()` `/proc/cpuinfo` fallback 可产生假阳性

> **状态**：`tracked-upstream` `behavior-reproduced` `known-open-pr`
>
> #48487（OPEN）已完整覆盖此问题，且包含开发板验证。本文件用于持续跟踪当前基线中问题是否仍存在。

## 1. 问题标题

`_riscv_supports_rvv()` 在 native probe 返回 False 时回退到 `/proc/cpuinfo` 检查，可对未编译 RVV 的二进制产生假阳性。

## 2. 涉及位置

- `vllm/v1/attention/backends/cpu_attn.py:434-461` — `_riscv_supports_rvv()` 函数

关键代码：

```python
@functools.lru_cache(maxsize=1)
def _riscv_supports_rvv() -> bool:
    # The C++ compile-time check is the ground truth...
    try:
        import torch
        if torch.ops._C.cpu_attn_has_isa("rvv"):
            return True
    except Exception:
        pass

    # Fallback: check /proc/cpuinfo for zvl128b/zvl256b.
    try:
        with open("/proc/cpuinfo") as f:
            cpuinfo = f.read()
    except OSError:
        return False
    return any(f"zvl{n}b" in cpuinfo for n in (128, 256))
```

## 3. 问题描述

函数先检查 C++ 编译期探测 `torch.ops._C.cpu_attn_has_isa("rvv")`（基于 `__riscv_v_min_vlen`）。若返回 True，直接返回 True（正确）。

但若 native probe 返回 False（二进制未编译 RVV kernel）或抛异常（`_C` 扩展未加载），函数回退到读 `/proc/cpuinfo` 查找 `zvl128b`/`zvl256b`。若硬件支持 RVV（`/proc/cpuinfo` 有 `zvl` 标志）但二进制未编译 RVV，函数仍返回 True——这是**假阳性**，因为二进制实际上没有 RVV attention kernel。

## 4. 触发条件

- RISC-V 架构
- 硬件支持 RVV（`/proc/cpuinfo` 报告 `zvl128b` 或 `zvl256b`）
- vLLM 二进制以 scalar 模式编译（`VLLM_RVV_VLEN=0` 或未设置且自动检测失败）
- `_C` 扩展加载但 `cpu_attn_has_isa("rvv")` 返回 False

## 5. 调用链与证据

```
_get_attn_isa()                          [cpu_attn.py:464]
  → supports_riscv and _riscv_supports_rvv()  [行 494]
    → torch.ops._C.cpu_attn_has_isa("rvv")    [行 450]
      → #if defined(__riscv_v_min_vlen) ...   [cpu_attn.cpp:16-17]
      → return false (二进制未编译 RVV)
    → fallback: /proc/cpuinfo has "zvl128b"    [行 457-461]
    → return True  ← 假阳性
  → return "rvv"                              [行 495]
```

### 已确认后果

当 `_get_attn_isa()` 返回 `"rvv"` 但二进制未编译 RVV kernel 时：

- Python 端错误选择 RVV attention ISA。
- 选择结果与已加载 C++ 扩展的实际能力不一致。
- 真实 scheduler 拒绝该配置并抛出 `RuntimeError`。
- 请求无法继续执行。

### #48487 验证

#48487 包含开发板验证和测试用例：
- `test_riscv_rvv_support_uses_native_result`
- `test_riscv_rvv_support_fails_closed`
- `test_riscv_native_false_selects_scalar_attention`

## 6. 潜在影响

### 已确认（有实际证据）

- Python 端错误选择 RVV attention ISA。
- 选择结果与已加载 C++ 扩展能力不一致。
- 真实 scheduler 拒绝该配置并抛出 RuntimeError。
- 请求无法继续执行。

### 未确认（无证据支持，不再声称）

- ~~编译错误~~：不适用，这是运行时派发问题，不是编译期问题。
- ~~链接错误~~：不适用，`_C` 扩展已加载，只是能力判断错误。
- ~~空实现~~：不适用，`cpu_attn_rvv.hpp` 的 `#if` 守卫在编译期决定，不影响运行时。
- ~~空指针~~：无证据支持。
- ~~运行时崩溃~~：无证据支持，实际表现为 RuntimeError。
- ~~静默回退~~：无证据支持，实际表现为请求无法继续。

## 7. 去重检查

- **上游 PR**：#48487（OPEN）完整覆盖此问题，包含开发板验证和测试。
- **当前分支**：`/proc/cpuinfo` fallback 确认存在（行 455-461）。
- **本 fork**：`fix/riscv-rvv-capability-probe` 分支包含 #48487 的提交（`3e750066a`），但未合并到 `upstream/main`。

## 8. 可信度

**高**。源码调用链完整，假阳性逻辑明确。#48487 已提供完整修复与开发板验证。

## 9. 验证建议

见 #48487 PR 描述和测试用例。

## 10. 修复思路

#48487 已提出修复：

1. 移除 `/proc/cpuinfo` fallback（行 455-461）
2. `_riscv_supports_rvv()` 仅信 `torch.ops._C.cpu_attn_has_isa("rvv")`
3. 捕获 `(AttributeError, RuntimeError)` 时 `return False`（fail-closed）
4. 补充测试

本文件仅跟踪上游 PR 状态，不提出独立修复方案。
