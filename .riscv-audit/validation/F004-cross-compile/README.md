# F004 Cross-Compile Validation

This package validates the configuration-stage behavior of F004 scenario B:
an x86_64 Linux host configuring a riscv64 target with
`VLLM_RVV_VLEN=128`.

The experiment does not compile, link, or run a target binary. It does not
validate performance, VLEN=256, macOS scenario A, or every cross-compilation
environment.

## Requirements

- x86_64 Linux
- CMake 3.28 or newer
- Ninja
- `riscv64-linux-gnu-gcc` and `riscv64-linux-gnu-g++`
- `jq`
- an explicit virtual-environment Python with an importable CPU PyTorch

The validated source baseline is
`57f327ef9c827788c85c0a69c0cf86e446ff27ae`. The scripts refuse to apply the
instrumentation unless `cmake/cpu_extension.cmake` has the exact baseline
blob `64df94e947d44da6dd67dd4cd5c90589e215b8b2`.

## Safe workflow

Run the scripts from any directory inside the repository. They locate the
repository through their own paths and verify the configured `origin`.

```bash
bash .riscv-audit/validation/F004-cross-compile/scripts/apply_instrumentation.sh

RESULTS=".riscv-audit/validation/F004-cross-compile/results/$(date -u +%Y%m%dT%H%M%SZ)"
bash .riscv-audit/validation/F004-cross-compile/scripts/run_matrix.sh \
  --python /path/to/venv/bin/python \
  --output "$RESULTS"

bash .riscv-audit/validation/F004-cross-compile/scripts/extract_evidence.sh \
  "$RESULTS"

bash .riscv-audit/validation/F004-cross-compile/scripts/remove_instrumentation.sh
```

Safety properties:

- instrumentation is applied with the committed patch only;
- the source blob, repository origin, patch content, marker count, and patched
  blob are verified;
- repeated application is rejected;
- removal uses the exact reverse patch and rejects any source state other than
  the validated instrumented blob;
- result directories must not already exist;
- every test receives a new build directory;
- relevant architecture overrides and `CMAKE_ARGS` are cleared per test;
- Python is explicit and PyTorch import is checked before configuration;
- extraction requires an explicit result directory and refuses mismatched
  copied artifacts.

Do not replace the removal step with an unconditional `git restore`: that
could discard unrelated user changes.

## Matrix

| Test | VLEN | BF16 override | Expected configuration result |
|---|---:|---:|---|
| T0-scalar | 0 | unset | success, scalar control |
| T1-vlen128 | 128 | unset | success, core reproduction |
| T2-vlen128-bf16 | 128 | 1 | success, positive control |
| T3-bf16-no-vlen | unset | 1 | expected VLEN error |

T1 and T2 use identical CMake logging options. Their only input difference
that affects configuration semantics is `VLLM_CPU_RVV_BF16=1`.

## Evidence files

Each test directory contains the full `configure.log`, the real CMake exit
code, the selected cache, and—when configuration succeeds—the complete
`compile_commands.json`.

The extraction script adds:

- `f004-messages.txt`: all instrumentation lines, including counterexamples;
- `cmake-cache-selected.txt`: selected configuration inputs;
- `vllm-target-march.tsv`: `_C` and `dnnl_ext`, with source/output ownership;
- `dependency-target-march.tsv`: `_deps/*` commands kept separate;
- `march-summary-attributed.txt`: target-attributed unique flag summary;
- `march-values.txt`: compatibility summary without target ownership;
- `manifest.txt`: source, script, patch, toolchain, environment, and artifact
  hashes for the complete result directory.

`compile_commands.json` and the target-attributed TSV files are the primary
evidence for generated compiler flags. `march-values.txt` alone is not enough
to distinguish vLLM targets from dependencies.

## Existing first-round result

`results/20260729T074037Z` is the preserved first-round run. Its four original
`configure.log` files were recovered from the original aliyun result directory
during remediation. The existing cache, compile database, exit-code, F004
message, and original `march-values.txt` artifacts were not replaced.

Absolute paths such as `/root/work/vllm-f004-validation` record the original
layout. They affect direct portability but are not sensitive information and
do not weaken the configuration evidence.

## Classification

- `blocked`: configuration does not reach the instrumented vLLM CPU CMake
  path because a prerequisite or toolchain fails first.
- `not-reproduced`: T1 reaches that path but the vLLM `_C` commands are not
  generated with `-march=rv64gc`, or the expected T1/T2 variable chain differs.
- `confirmed`: T1 records cross-compiling x86_64 → riscv64, FP16/BF16 OFF and
  VLEN=128, with vLLM `_C` commands using `-march=rv64gc`; T2 changes the BF16
  override to 1 and vLLM targets receive the expected RVV/BF16 flags.
