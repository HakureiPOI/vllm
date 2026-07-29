#!/usr/bin/env python3
"""验证 .riscv-audit/ 中记录的候选缺陷。

用法：
    python .riscv-audit/scripts/verify_findings.py

在仓库根目录运行，检查各发现的源码位置是否仍存在。
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def check_f001_vfncvt():
    """F001: vfncvt.f.f.w / vfncvtbf16.f.f.w 动态舍入。"""
    f = REPO_ROOT / "csrc" / "cpu" / "cpu_types_riscv_impl.hpp"
    content = f.read_text()
    # 查找非 _rm 的 vfncvt 调用
    pattern = r"RVVI\(__riscv_vfncvt[a-z_]*,[^)]*\)"
    matches = re.findall(pattern, content)
    # 排除 _rm 变体
    non_rm = [m for m in matches if "_rm" not in m]
    status = "CONFIRMED" if len(non_rm) >= 4 else "MISMATCH"
    print(f"[F001] vfncvt dynamic rounding: {status}")
    print(f"  Expected: >= 4 non-_rm vfncvt calls")
    print(f"  Found:    {len(non_rm)}")
    for m in non_rm:
        print(f"    {m}")
    print()


def check_f002_vfcvt_x_f():
    """F002: vfcvt_x_f_v_i32 动态舍入。"""
    f = REPO_ROOT / "csrc" / "cpu" / "cpu_types_riscv_impl.hpp"
    content = f.read_text()
    pattern = r"RVVI\(__riscv_vfcvt_x_f_v_i32,[^)]*\)"
    matches = re.findall(pattern, content)
    non_rm = [m for m in matches if "_rm" not in m]
    status = "CONFIRMED" if len(non_rm) >= 3 else "MISMATCH"
    print(f"[F002] vfcvt_x_f_v_i32 dynamic rounding: {status}")
    print(f"  Expected: >= 3 non-_rm vfcvt_x_f_v_i32 calls")
    print(f"  Found:    {len(non_rm)}")
    for m in non_rm:
        print(f"    {m}")
    print()


def check_f003_cpuinfo_fallback():
    """F003: _riscv_supports_rvv() /proc/cpuinfo fallback。"""
    f = REPO_ROOT / "vllm" / "v1" / "attention" / "backends" / "cpu_attn.py"
    content = f.read_text()
    has_fallback = "/proc/cpuinfo" in content and "zvl" in content
    has_native = "cpu_attn_has_isa" in content
    status = "CONFIRMED" if has_fallback and has_native else "MISMATCH"
    print(f"[F003] _riscv_supports_rvv() cpuinfo fallback: {status}")
    print(f"  /proc/cpuinfo fallback present: {has_fallback}")
    print(f"  native probe present:            {has_native}")
    print()


def check_f004_cross_compile():
    """F004: 交叉编译 cat /proc/cpuinfo 未守卫。"""
    f = REPO_ROOT / "cmake" / "cpu_extension.cmake"
    lines = f.read_text().splitlines()
    # 查找 cat /proc/cpuinfo 行
    cpuinfo_lines = [i + 1 for i, l in enumerate(lines) if "cat /proc/cpuinfo" in l]
    # 查找 CMAKE_CROSSCOMPILING 守卫
    crosscompile_lines = [i + 1 for i, l in enumerate(lines) if "CMAKE_CROSSCOMPILING" in l]
    # 检查 cat /proc/cpuinfo 之前是否有 CMAKE_CROSSCOMPILING
    first_cpuinfo = cpuinfo_lines[0] if cpuinfo_lines else 0
    first_cross = crosscompile_lines[0] if crosscompile_lines else 0
    unguarded = first_cpuinfo > 0 and (first_cross == 0 or first_cross > first_cpuinfo)
    status = "CONFIRMED" if unguarded else "MISMATCH"
    print(f"[F004] cross-compile cat /proc/cpuinfo unguarded: {status}")
    print(f"  cat /proc/cpuinfo at line:      {first_cpuinfo}")
    print(f"  CMAKE_CROSSCOMPILING at line:   {first_cross}")
    print()


def check_f005_bf16_detection():
    """F005: BF16 检测未迁移到 native probe。"""
    f = REPO_ROOT / "cmake" / "cpu_extension.cmake"
    content = f.read_text()
    has_find_isa_zvfbfmin = 'find_isa(${CPUINFO} "zvfbfmin"' in content
    has_env_override = "ENABLE_RVV_BF16" in content
    has_native_probe = "try_compile" in content and "zvfbfmin" in content
    status = "CONFIRMED" if has_find_isa_zvfbfmin and has_env_override and not has_native_probe else "MISMATCH"
    print(f"[F005] BF16 detection not native: {status}")
    print(f"  find_isa zvfbfmin:    {has_find_isa_zvfbfmin}")
    print(f"  env override:         {has_env_override}")
    print(f"  native try_compile:   {has_native_probe}")
    print()


def main():
    print(f"Repository: {REPO_ROOT}")
    print(f"Verifying .riscv-audit/ findings against current source.\n")
    check_f001_vfncvt()
    check_f002_vfcvt_x_f()
    check_f003_cpuinfo_fallback()
    check_f004_cross_compile()
    check_f005_bf16_detection()
    print("Done. If any MISMATCH, the source may have changed since audit.")


if __name__ == "__main__":
    sys.exit(main())
