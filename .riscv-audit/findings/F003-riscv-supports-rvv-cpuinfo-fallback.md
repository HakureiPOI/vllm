# F003: `_riscv_supports_rvv()` `/proc/cpuinfo` fallback 可产生假阳性

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
    → return True  ← 假阳性！
  → return "rvv"                              [行 495]
→ CPU_ATTN_DISPATCH with ISA::RVV             [cpu_attn.cpp:45-46]
  → AttentionImpl<ISA::RVV, ...>             [cpu_attn_rvv.hpp:262]
    → #if defined(__riscv_v_min_vlen) ...     [cpu_attn_rvv.hpp:14-15]
    → 未编译 → 链接错误或空实现
```

### 后果

当 `_get_attn_isa()` 返回 `"rvv"` 但二进制未编译 RVV kernel 时：
- `CPU_ATTN_DISPATCH` 尝试实例化 `AttentionImpl<ISA::RVV, ...>`
- 若 `cpu_attn_rvv.hpp` 的 `#if` 守卫为 false，整个类体被排除
- 导致编译错误（符号未定义）或运行时崩溃（空指针/未注册算子）

## 6. 潜在影响

- **启动失败或运行时崩溃**：尝试调用不存在的 RVV kernel。
- **静默性能损失**：若回退路径恰好不崩溃（如 `cpu_attn_has_isa` 抛 `AttributeError` 被 `except` 吞掉），用户可能误以为 RVV 已启用但实际走 scalar 路径。
- **影响场景**：用户在 SG2044/X100 上以 scalar 模式编译（忘记设 `VLLM_RVV_VLEN`），但硬件报 `zvl128b`，导致假阳性。

## 7. 去重检查

- **调研文档**：案例 A5（#47532 → #48487）完整覆盖此问题。
- **当前分支**：`/proc/cpuinfo` fallback 确认存在（行 455-461）。
- **#48487 状态**：OPEN，未合并。#48487 的修复是移除 `/proc/cpuinfo` 启发式，仅信 native probe，fail-closed。
- **本 fork**：`fix/riscv-rvv-capability-probe` 分支包含 #48487 的提交（`3e750066a`），但未合并到 `upstream/main`。

## 8. 可信度

**高**。源码调用链完整，假阳性逻辑明确。#48487 已提供完整修复与测试。

## 9. 验证建议

1. 在 SG2044 上以 `VLLM_RVV_VLEN=0` 编译 vLLM（scalar 模式），运行模型，观察是否触发 RVV 路径错误。
2. 单元测试：mock `torch.ops._C.cpu_attn_has_isa` 返回 False，mock `/proc/cpuinfo` 含 `zvl128b`，验证 `_riscv_supports_rvv()` 返回 False（当前返回 True = bug）。

## 10. 修复思路

#48487 已提出修复：

1. 移除 `/proc/cpuinfo` fallback（行 455-461）
2. `_riscv_supports_rvv()` 仅信 `torch.ops._C.cpu_attn_has_isa("rvv")`
3. 捕获 `(AttributeError, RuntimeError)` 时 `return False`（fail-closed）
4. 补充测试：`test_riscv_rvv_support_uses_native_result` / `test_riscv_rvv_support_fails_closed` / `test_riscv_native_false_selects_scalar_attention`

本 fork 的 `fix/riscv-rvv-capability-probe` 分支已包含此修复，可作为独立 PR 提交。
