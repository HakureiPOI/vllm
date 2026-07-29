#!/usr/bin/env python3
"""检查 .riscv-audit/ 中 finding 引用的源码模式是否仍然存在。

该脚本仅检查 finding 引用的源码模式是否仍然存在，
不验证行为后果，也不确认候选问题构成实际缺陷。

输出语义：
    PRESENT        — 源码模式仍存在
    ABSENT         — 源码模式已消失
    SOURCE_CHANGED — 源码存在但模式有变化

用法：
    python .riscv-audit/scripts/check_source_markers.py

在仓库根目录运行。
"""

import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

BASELINE_COMMIT = "6fbbcf215"


def get_current_commit():
    """获取当前 HEAD commit SHA。"""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, cwd=REPO_ROOT
        )
        return result.stdout.strip()
    except Exception:
        return "unknown"


def check_f001_vfncvt():
    """F001: 检查 4 处非 _rm 的 vfncvt 调用是否仍存在。"""
    f = REPO_ROOT / "csrc" / "cpu" / "cpu_types_riscv_impl.hpp"
    if not f.exists():
        return "ABSENT", "file not found"
    content = f.read_text()
    pattern = r"RVVI\(__riscv_vfncvt[a-z_]*,[^)]*\)"
    matches = re.findall(pattern, content)
    non_rm = [m for m in matches if "_rm" not in m]
    if len(non_rm) == 4:
        return "PRESENT", f"{len(non_rm)} non-_rm vfncvt calls found"
    elif len(non_rm) == 0:
        return "ABSENT", "no non-_rm vfncvt calls found"
    else:
        return "SOURCE_CHANGED", f"expected 4, found {len(non_rm)} non-_rm vfncvt calls"


def check_f002_vfcvt_x_f():
    """F002: 检查 3 处非 _rm 的 vfcvt_x_f_v_i32 调用是否仍存在。"""
    f = REPO_ROOT / "csrc" / "cpu" / "cpu_types_riscv_impl.hpp"
    if not f.exists():
        return "ABSENT", "file not found"
    content = f.read_text()
    pattern = r"RVVI\(__riscv_vfcvt_x_f_v_i32,[^)]*\)"
    matches = re.findall(pattern, content)
    non_rm = [m for m in matches if "_rm" not in m]
    if len(non_rm) == 3:
        return "PRESENT", f"{len(non_rm)} non-_rm vfcvt_x_f_v_i32 calls found"
    elif len(non_rm) == 0:
        return "ABSENT", "no non-_rm vfcvt_x_f_v_i32 calls found (possibly fixed by #47983)"
    else:
        return "SOURCE_CHANGED", f"expected 3, found {len(non_rm)} non-_rm vfcvt_x_f_v_i32 calls"


def check_f003_cpuinfo_fallback():
    """F003: 检查 _riscv_supports_rvv() 函数内是否仍有 /proc/cpuinfo fallback。

    限定到 _riscv_supports_rvv() 函数范围，而非整个文件。
    """
    f = REPO_ROOT / "vllm" / "v1" / "attention" / "backends" / "cpu_attn.py"
    if not f.exists():
        return "ABSENT", "file not found"
    content = f.read_text()

    # 提取 _riscv_supports_rvv 函数体
    func_match = re.search(
        r"def _riscv_supports_rvv\(\)[^:]*:(.*?)(?=\ndef |\Z)",
        content, re.DOTALL
    )
    if not func_match:
        return "SOURCE_CHANGED", "_riscv_supports_rvv() function not found"

    func_body = func_match.group(1)
    has_cpuinfo = "/proc/cpuinfo" in func_body
    has_native = "cpu_attn_has_isa" in func_body
    has_zvl = "zvl" in func_body

    if has_cpuinfo and has_native and has_zvl:
        return "PRESENT", "/proc/cpuinfo fallback still in _riscv_supports_rvv()"
    elif not has_cpuinfo and has_native:
        return "ABSENT", "/proc/cpuinfo fallback removed (possibly fixed by #48487)"
    else:
        return "SOURCE_CHANGED", f"cpuinfo={has_cpuinfo}, native={has_native}, zvl={has_zvl}"


def check_f004_cross_compile():
    """F004: 检查 cat /proc/cpuinfo 是否未被 CMAKE_CROSSCOMPILING 守卫。

    不仅通过关键词首次出现顺序判断，而是检查 cat /proc/cpuinfo 所在的
    控制流块是否包含 CMAKE_CROSSCOMPILING 守卫。
    """
    f = REPO_ROOT / "cmake" / "cpu_extension.cmake"
    if not f.exists():
        return "ABSENT", "file not found"
    lines = f.read_text().splitlines()

    # 找到 cat /proc/cpuinfo 所在行
    cpuinfo_line = None
    for i, line in enumerate(lines):
        if "cat /proc/cpuinfo" in line:
            cpuinfo_line = i
            break

    if cpuinfo_line is None:
        return "ABSENT", "cat /proc/cpuinfo not found"

    # 向上查找最近的 if 块开始
    # 检查 cat /proc/cpuinfo 所在的 if 块是否包含 CMAKE_CROSSCOMPILING
    # 向上搜索 20 行，查找 if/elseif/else 和 CMAKE_CROSSCOMPILING
    start = max(0, cpuinfo_line - 20)
    block = "\n".join(lines[start:cpuinfo_line + 10])

    has_crosscompile_guard = "CMAKE_CROSSCOMPILING" in block
    has_macos_guard = "MACOSX_FOUND" in block

    if has_crosscompile_guard:
        return "ABSENT", "cat /proc/cpuinfo is guarded by CMAKE_CROSSCOMPILING"
    elif has_macos_guard and not has_crosscompile_guard:
        return "PRESENT", "cat /proc/cpuinfo guarded only by MACOSX_FOUND, not CMAKE_CROSSCOMPILING"
    else:
        return "SOURCE_CHANGED", f"guard context unclear at line {cpuinfo_line + 1}"


def main():
    current_commit = get_current_commit()

    print("=" * 70)
    print("Source Marker Check for .riscv-audit/ Findings")
    print("=" * 70)
    print(f"Baseline commit: {BASELINE_COMMIT}")
    print(f"Current commit:  {current_commit}")
    print()
    print("NOTE: This script only checks whether the source code patterns")
    print("      referenced by findings still exist. It does NOT verify")
    print("      behavioral consequences or confirm that candidate issues")
    print("      constitute actual defects.")
    print("=" * 70)
    print()

    checks = [
        ("F001", "vfncvt non-_rm calls", check_f001_vfncvt),
        ("F002", "vfcvt_x_f_v_i32 non-_rm calls", check_f002_vfcvt_x_f),
        ("F003", "_riscv_supports_rvv() cpuinfo fallback", check_f003_cpuinfo_fallback),
        ("F004", "cross-compile cat /proc/cpuinfo unguarded", check_f004_cross_compile),
    ]

    for finding_id, description, check_func in checks:
        status, detail = check_func()
        print(f"[{finding_id}] {description}")
        print(f"  Status: {status}")
        print(f"  Detail: {detail}")
        print()

    print("=" * 70)
    print("NOTE: This script only checks whether the source code patterns")
    print("      referenced by findings still exist. It does NOT verify")
    print("      behavioral consequences or confirm that candidate issues")
    print("      constitute actual defects.")
    print("=" * 70)

    return 0


if __name__ == "__main__":
    sys.exit(main())
