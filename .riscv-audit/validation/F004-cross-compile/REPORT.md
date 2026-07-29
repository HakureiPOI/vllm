# F004 Cross-Compile Validation Report

## 1. Result

**confirmed: F004 scenario B is dynamically confirmed at CMake configuration
stage.**

In the recorded x86_64 Linux → riscv64 configuration, setting
`VLLM_RVV_VLEN=128` without the BF16 override leaves
`RVV_FP16_FOUND=OFF` and `RVV_BF16_FOUND=OFF`. CMake consequently generates
vLLM `_C` compile commands with `-march=rv64gc`. Setting
`VLLM_CPU_RVV_BF16=1` changes `RVV_BF16_FOUND` to ON and generates the expected
RVV/BF16/VLEN128 flags for vLLM `_C` and `dnnl_ext` targets.

This conclusion is limited to generated configuration-stage commands. No
target object, library, wheel, or binary was compiled, linked, or run.

## 2. Source and evidence revisions

- Experiment source baseline / experiment HEAD:
  `57f327ef9c827788c85c0a69c0cf86e446ff27ae`
- Baseline `cmake/cpu_extension.cmake` blob:
  `64df94e947d44da6dd67dd4cd5c90589e215b8b2`
- First evidence commit:
  `16659b79de18595dcf17072dfc3486fb948f2a73`
- Remediated evidence commit: the commit containing this report; its full SHA
  is recorded by the subsequent F004 finding/STATUS commit and final handoff.

At experiment time, the tree consisted of the baseline source plus log-only
instrumentation. Validation files were untracked or newly generated. It was
therefore not literally a clean worktree. Production source had no change
other than the temporary instrumentation, which was later removed.

The first-round result directory remains:

```text
results/20260729T074037Z
```

No second matrix was run during remediation.

## 3. Environment

### x86_64 configuration host

- Ubuntu 24.04.4 LTS, kernel 6.8.0-124-generic
- CMake 3.28.3
- Ninja 1.11.1
- RISC-V GNU C/C++ cross compiler 13.3.0
- venv Python: `/root/work/.venv-vllm-f004/bin/python`
- Python 3.12.3
- PyTorch 2.13.0+cpu
- torch CMake prefix:
  `/root/work/.venv-vllm-f004/lib/python3.12/site-packages/torch/share/cmake`

The original `environment/aliyun.txt` line `torch: not found` describes the
system `/usr/bin/python3`, not the venv Python passed to CMake. The actual venv
path is present in all recorded CMake caches and was rechecked during
remediation. See `environment/remediation-20260729.txt` and the result
manifest.

### Bianbu reference host

The Bianbu record is read-only target context, not a sysroot or target ISA
input to this experiment. Its cpuinfo records `zvfh`/`zvfhmin`, but not
`zvfbfmin` or `zvl128b`/`zvl256b`. This experiment does not prove that those
hardware capabilities were passed to CMake.

## 4. Source chain

Direct source observations at the experiment baseline:

1. Non-macOS configuration executes `cat /proc/cpuinfo` without a
   `CMAKE_CROSSCOMPILING` guard.
2. `find_isa(..., "zvfhmin")` and `find_isa(..., "zvfbfmin")` set
   `RVV_FP16_FOUND` and `RVV_BF16_FOUND` from that `CPUINFO` value.
3. VLEN auto-detection has a separate cross-compilation guard.
4. An explicit `VLLM_RVV_VLEN` selects VLEN but does not set FP16/BF16
   capability variables.
5. With VLEN positive and both capability variables OFF, `MARCH_FLAGS` is
   `-march=rv64gc`.
6. `VLLM_CPU_RVV_BF16=1` sets `RVV_BF16_FOUND=ON`.
7. BF16 ON with VLEN 128 selects:

   ```text
   -march=rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl128b
   -mrvv-vector-bits=zvl
   -mabi=lp64d
   ```

8. `MARCH_FLAGS` is appended to `CXX_COMPILE_FLAGS`, which is passed to
   vLLM targets and materialized in `compile_commands.json`.

The source confirms the detection and propagation mechanism; the result files
confirm the runtime values and generated commands.

## 5. Toolchain and real cross-compilation state

`toolchains/riscv64-linux-gnu.cmake` sets only:

- `CMAKE_SYSTEM_NAME=Linux`
- `CMAKE_SYSTEM_PROCESSOR=riscv64`
- `CMAKE_C_COMPILER=riscv64-linux-gnu-gcc`
- `CMAKE_CXX_COMPILER=riscv64-linux-gnu-g++`
- `CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY`

It does not set any tested RVV variable or compile flag. Runtime messages show
`CMAKE_CROSSCOMPILING=TRUE`, host `Linux/x86_64`, and target `Linux/riscv64`.
The compile database uses `/usr/bin/riscv64-linux-gnu-g++`.

## 6. Instrumentation

The remediated patch contains exactly 13 `message(STATUS ...)` calls:

- seven host/target and cpuinfo-status messages before `find_isa`;
- four capability/override/VLEN messages after detection and overrides;
- two final `MARCH_FLAGS`/`CXX_COMPILE_FLAGS` messages after architecture
  selection and after the RISC-V flags have been appended.

The patch adds only comments, blank lines, and status messages. It changes no
variable, condition, toolchain setting, target processor, flag, or control
flow. Application is restricted to the exact baseline blob and exact patched
blob; both repeated application and unsafe reversal are rejected.

The original run used the first instrumentation version. Its result files
therefore contain the original 11 reachable messages (T1 has each line twice
because trace output and normal status output were both retained). Final flags
for the original run are proved by `compile_commands.json`, not by an
instrumentation claim.

During remediation, a temporary T1 configuration smoke test confirmed that
the corrected patch emits both final messages on the normal RISC-V path:

```text
-- [F004] MARCH_FLAGS=-march=rv64gc
-- [F004] CXX_COMPILE_FLAGS=-fopenmp;-DVLLM_CPU_EXTENSION;-march=rv64gc
```

That smoke test only validates instrumentation reachability and is not a new
F004 result matrix.

## 7. Matrix inputs and isolation

| Test | `VLLM_RVV_VLEN` | `VLLM_CPU_RVV_BF16` | Expected |
|---|---:|---:|---|
| T0 | 0 | unset | configuration succeeds |
| T1 | 128 | unset | configuration succeeds |
| T2 | 128 | 1 | configuration succeeds |
| T3 | unset | 1 | expected VLEN error |

Every first-round test used a separate build directory. T0 and T1 explicitly
cleared the BF16 override. T2 and T3 explicitly set it to 1.

The original T1 additionally used CMake trace logging while T2 did not. Trace
does not affect the tested configuration semantics. Thus the correct statement
is: **the only input difference between T1 and T2 that affects configuration
semantics is `VLLM_CPU_RVV_BF16=1`.**

The remediated runner now gives T1 and T2 identical logging options, clears all
relevant architecture overrides and `CMAKE_ARGS`, requires a new results
directory, and records the real CMake pipeline exit status.

## 8. Original logs recovered during remediation

All four original `configure.log` files remained on the aliyun validation host
under `results/20260729T074037Z`. Before copying them into this evidence
package, remediation checked:

- the exact result path and build path;
- the F004 runtime messages;
- configuration completion or the expected T3 error;
- correspondence with the existing tracked cache, compile database, exit code,
  and message artifacts;
- credential and private-key patterns.

No sensitive-pattern match was found. The logs were added without global path
rewriting or other redaction. Their absolute `/root/work/...` paths are
non-sensitive experiment provenance.

## 9. Results

### T0: scalar control

- Exit code: 0
- `VLLM_RVV_VLEN=0`
- `RVV_FP16_FOUND=OFF`, `RVV_BF16_FOUND=OFF`
- 12 vLLM `_C` commands, all `-march=rv64gc`

This is a control, not defect evidence.

### T1: core reproduction

- Exit code: 0
- `CMAKE_CROSSCOMPILING=TRUE`
- Host: `Linux/x86_64`
- Target: `Linux/riscv64`
- `CPUINFO_RET=0`
- `RVV_FP16_FOUND=OFF`
- `RVV_BF16_FOUND=OFF`
- `ENABLE_RVV_BF16` empty
- `VLLM_RVV_VLEN=128`
- 12 vLLM `_C` commands, all `-march=rv64gc`

`dnnl_ext` is absent in T1 because the source does not enable the oneDNN path
when both RVV capability variables are OFF. The `_C` target is direct and
sufficient evidence for the configuration-stage finding.

### T2: BF16 override positive control

- Exit code: 0
- Cross/host/target values identical to T1
- `RVV_FP16_FOUND=OFF`
- `RVV_BF16_FOUND=ON`
- `ENABLE_RVV_BF16=1`
- `VLLM_RVV_VLEN=128`
- 15 vLLM commands (`_C` and `dnnl_ext`), all using:

  ```text
  -march=rv64gcv_zvfh_zfbfmin_zvfbfmin_zvl128b
  -mrvv-vector-bits=zvl
  -mabi=lp64d
  ```

- 170 commands belonging to oneDNN or its subbuild use `-march=rv64gc`.

The dependency commands are not vLLM `_C` or `dnnl_ext`. Their cause was not
analysed in this round and is not part of the F004 conclusion.

### T3: BF16 without VLEN

- Exit code: 1
- `RVV_BF16_FOUND=ON`
- `VLLM_RVV_VLEN` unset
- The recovered full log directly records the expected CMake error:
  `RISC-V RVV is available but VLEN could not be auto-detected`.
- No `compile_commands.json` was generated.

T3 only shows that the configuration requires explicit VLEN when RVV
capability is ON and VLEN auto-detection is skipped while cross-compiling.

## 10. `/proc/cpuinfo` evidence strength

The experiment records `CPUINFO_RET=0`, host x86_64, target riscv64, and both
RISC-V feature searches OFF. The baseline source explicitly executes
`cat /proc/cpuinfo` during CMake configuration. `execute_process` runs on the
configuration host, so the combined source and runtime evidence supports the
host-cpuinfo conclusion.

The complete cpuinfo text was intentionally not committed. The experiment does
not provide a byte-for-byte cpuinfo capture, but that is not necessary to
establish which host namespace executes the command.

## 11. Primary evidence and conclusion

The target-attributed TSV files separate vLLM targets from dependencies and
retain every `-march`, `-mabi`, and `-mrvv-vector-bits` value. The complete
`compile_commands.json` remains the stronger primary evidence.

The T1/T2 contrast confirms the following limited statement:

> In this x86_64 Linux → riscv64 CMake cross-configuration with
> `VLLM_RVV_VLEN=128`, absence of the BF16 override leaves the host-derived
> FP16/BF16 capability variables OFF and generates vLLM `_C` compile commands
> using `-march=rv64gc`. Setting `VLLM_CPU_RVV_BF16=1` generates the expected
> RVV/BF16/VLEN128 commands for vLLM targets.

## 12. Not validated

- actual compilation or linking;
- generation or execution of a target binary;
- measured performance impact;
- VLEN=256;
- macOS scenario A;
- all RISC-V cross-compilation environments;
- passing Bianbu target capabilities to CMake;
- the cause of dependency/oneDNN `-march=rv64gc` commands.
