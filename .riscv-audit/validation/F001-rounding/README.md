# F001 FP32→FP16 ISA 级动态舍入验证

## 1. 目标

本目录验证一个严格限定的机制：

> 在 Spacemit X60 上直接执行裸 ISA 指令 `vfncvt.f.f.w` 时，
> FP32→FP16 narrowing 的结果是否随当前 `frm` 改变；以及手工 CSR
> 控制是否能够临时切换到 RNE、执行转换并恢复调用前的 `frm`。

这是 **ISA-equivalent validation（ISA 等价验证）**，不是 C intrinsic
运行时验证，也不是 vLLM 源码或运行时复现。

## 2. 证据层级

| 层级 | 当前覆盖 |
|---|---|
| ISA 规范机制 | 规范确认 |
| X60 裸 ISA 运行行为 | O0/O3 动态观察 |
| C intrinsic 编译与代码生成 | GCC 13.2/13.3 失败诊断；Clang 18 FP16 编译与反汇编 |
| C intrinsic 运行行为 | 未验证 |
| vLLM 最小源码路径 | 未测试 |
| vLLM 实际调用路径 | 未测试 |
| 用户可见数值影响 | 未测试 |

不得把 inline assembly 路径称为 implicit C intrinsic、explicit `_rm`
intrinsic、source-equivalent 或 vLLM runtime reproduction。

## 3. 两轮证据

- `results/20260729T112835Z/` 是 first-run evidence。该目录不可变，
  保留第一轮原始日志及其局限。
- `results/20260729T144517Z/` 是 remediation evidence。它修正 manual
  调用顺序，补齐 O3 运行、编译日志、退出码、fflags、正确 LMUL API
  探针、Clang 分层结果和 manifest。
- `results/20260729T152738Z/` 是 evidence-closure evidence。它新增转换前、
  转换后和最终恢复后的 fflags readback，并保存远端生成的 source→
  binary/object→disassembly/run 哈希链、objdump 命令/版本和可移植校验集。
  本报告以该目录作为最终动态证据。

新实验不得写入或覆盖第一轮目录。所有复跑都必须使用新的 UTC 时间戳。

## 4. 文件布局

~~~text
src/test_fp16_isa.c
src/probes/probe_fp16_implicit.c
src/probes/probe_fp16_explicit_rm.c
src/probes/probe_bf16_implicit.c
src/probes/probe_bf16_explicit_rm.c
scripts/build_fp16_isa.sh
scripts/run_fp16_isa.sh
scripts/probe_intrinsics.sh
scripts/extract_environment.sh
scripts/create_remote_checksums.sh
scripts/create_manifest.sh
results/<UTC timestamp>/
~~~

脚本均使用 `set -euo pipefail`，要求显式输出目录并拒绝覆盖。它们不会安装
软件、修改正式源码、提交代码或推送分支。

`probe_intrinsics.sh` 的脚本退出码只表示采集过程是否完成。每个 probe 的
`compile-exit-code.txt` 才是该 probe 的编译结果；编译失败本身是预期证据。

## 5. 环境

### bianbu

- 角色：RISC-V 实机运行、原生 GCC probe、反汇编和 frm/fflags 观察。
- 架构：riscv64，Spacemit X60。
- 当前 cpuinfo 宣告 `v`、`zvfh` 和 `zvfhmin`，未宣告 `zvfbfmin`。
- 编译器：Bianbu GCC 13.2.0。
- 不得将 cpuinfo 未宣告 zvfbfmin 扩展为“硬件确定不支持”。

### aliyun

- 角色：x86_64 主机上的 RISC-V 交叉编译探针。
- RISC-V GCC：Ubuntu 13.3.0。
- Clang：Ubuntu Clang 18.1.3；`--print-targets` 明确列出 riscv32/riscv64。
- Clang 可定位 RISC-V GCC 安装、目标 crt1 和系统 include 路径；本轮只做
  compile-only probe，没有链接或运行 Clang 产物。

完整环境证据位于 remediation result 的 `bianbu/environment` 和
`aliyun/environment-*`。

## 6. ISA 测试实现

`convert_fp16_ambient_isa` 使用：

~~~text
AVL=1
e32,m1 source
e16,mf2 destination
vfncvt.f.f.w
~~~

它不管理 CSR，直接使用当前 `frm`。

`convert_fp16_manual_rne_isa` 使用：

~~~text
frrm       save frm
fsrmi 0    set RNE
vfncvt.f.f.w
fsrm       restore frm
~~~

manual 路径只恢复舍入模式字段 `frm`，不保存或恢复 `fflags`。转换产生的
NX、OF 等异常标志会保留。不能描述为完整恢复 fcsr 或无浮点环境副作用。

正式 vLLM 源码使用 FP16 m1/m2 目标和多元素 VL；本 ISA 测试使用
e16,mf2、AVL=1。二者共享相同 narrowing opcode 和逐元素舍入机制，因此
只能称为 ISA-equivalent，不能称为 source-equivalent。

## 7. 在 bianbu 构建和运行 O0/O3

先创建全新的远端工作目录，并把本目录的 `src` 和 `scripts` 放入
`package`。以下示例中的输出目录必须不存在：

~~~bash
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
work=/tmp/f001-rounding-remediation-$timestamp
mkdir -p "$work/package"
cd "$work/package"

bash scripts/extract_environment.sh \
  "$work/evidence/bianbu/environment" \
  bianbu-riscv64-runtime gcc -march=rv64gcv_zvfh

F001_MARCH=rv64gcv_zvfh \
F001_MARCH_SOURCE=explicit-from-bianbu-cpuinfo-zvfh-and-gcc-acceptance \
  bash scripts/build_fp16_isa.sh \
    src/test_fp16_isa.c "$work/evidence/bianbu/isa"

bash scripts/run_fp16_isa.sh "$work/evidence/bianbu/isa"
~~~

实际 `-march` 不能凭空复制：应先核对 cpuinfo，并确认本机 GCC 接受该
参数。本轮使用 `rv64gcv_zvfh`，来源记录在 `march-source.txt`。

每个 O0/O3 目录保存：

- `compile-command.txt`、`compile-stdout.txt`、`compile-stderr.txt`；
- `compile-exit-code.txt`；
- `binary-sha256.txt`；
- `disasm.txt`；
- `run-command.txt`、`run.txt`、`run-stderr.txt`；
- `run-exit-code.txt`。

二进制只保留在远端临时目录，不进入仓库。

## 8. 成功条件

程序带有检查并失败即返回非零。成功必须同时满足：

- `fesetround` 成功，fegetround 和 frm readback 与请求模式一致；
- positive midpoint 的 ambient 结果符合当前 RNE/RTZ/RDN/RUP；
- manual 在四种外部模式下都得到 RNE 结果；
- manual 返回后的 frm 等于调用前外部模式；
- 每行结束恢复程序初始 frm/fflags；
- 每个优化等级、每种模式、ambient/manual 两条路径的单进程 10 次循环一致；
- O0/O3 run exit code 均为 0，`SUMMARY` 为 PASS。

稳定性准确名称是 **single-process 10-iteration stability check**，不是
十次独立进程运行。

## 9. fflags 解释

测试在 ambient 和 manual 转换前分别清零 fflags，并立即 readback
`fflags_before_*`；转换后记录 `fflags_after_*`，最终状态恢复后再记录
`fflags_after_final_restore`：

- `0x01`：NX（inexact）；
- `0x04`：OF（overflow）；
- `0x05`：OF | NX。

该设计观察转换产生的标志，并证明 manual 不恢复它们。测试程序在每行结束
恢复进程初始 frm 和 fflags；这不改变 manual 函数自身只有 frm 恢复语义的
事实。

## 10. 测试值边界

核心值包括 positive midpoint、negative midpoint、midpoint below/above、
exact FP16 minimum normal、maximum finite、overflow threshold 和正负零。

`6.103515625e-05` 是 **exact FP16 minimum normal**，不得称为 near minimum
normal。当前未覆盖 true subnormal、underflow boundary、NaN 和 signaling
NaN；这些不是本轮整改阻塞项。

## 11. C intrinsic compile probe

FP16 正确 LMUL 关系：

~~~text
FP16 m1 destination <- FP32 m2 source
FP16 m2 destination <- FP32 m4 source
~~~

BF16 probes 使用同样的 narrowing LMUL 比例。运行示例：

~~~bash
bash scripts/probe_intrinsics.sh \
  "$work/evidence/bianbu/gcc-probes" \
  gcc bianbu-gcc-13.2 \
  rv64gcv_zvfh rv64gcv_zvfh_zvfbfmin

OBJDUMP=riscv64-linux-gnu-objdump \
  bash scripts/probe_intrinsics.sh \
    "$work/evidence/aliyun/gcc-probes" \
    riscv64-linux-gnu-gcc aliyun-riscv64-gcc-13.3 \
    rv64gcv_zvfh rv64gcv_zvfh_zvfbfmin

OBJDUMP=riscv64-linux-gnu-objdump \
  bash scripts/probe_intrinsics.sh \
    "$work/evidence/aliyun/clang-probes" \
    clang aliyun-clang-18-riscv64 \
    rv64gcv_zvfh rv64gcv_zvfh_zvfbfmin \
    --target=riscv64-linux-gnu
~~~

Clang 18 对 zvfbfmin 要求 experimental 开关和显式版本。本轮还保存了：

~~~bash
OBJDUMP=riscv64-linux-gnu-objdump \
  bash scripts/probe_intrinsics.sh \
    "$work/evidence/aliyun/clang-experimental-bf16-probes" \
    clang aliyun-clang-18-riscv64-experimental-bf16 \
    rv64gcv_zvfh rv64gcv_zvfh_zvfbfmin1p0 \
    --target=riscv64-linux-gnu -menable-experimental-extensions
~~~

每组保存完整 probe source、编译器路径/版本、命令、stdout、stderr、退出码、
完整预处理宏、header trace/path/SHA-256；成功编译时另存对象 SHA-256 和
反汇编。成功对象还保存 objdump 路径/版本、disasm 命令、远端 disasm
SHA-256 和 artifact-chain。对象本身不进入仓库。

## 12. 当前 API 边界

- bianbu GCC 13.2 与 aliyun RISC-V GCC 13.3：在记录的 header、march 和安装
  下，FP16 implicit/explicit `_rm` 均编译失败，诊断为 FP16 类型和 API
  不可用。
- aliyun Clang 18：FP16 implicit 和 explicit `_rm` 均编译成功；反汇编显示
  implicit 为裸 `vfncvt.f.f.w`，explicit `_rm` 生成保存/设置/恢复 frm 的
  CSR 序列。这是 codegen observation，不是运行时观察。
- BF16：GCC 两环境均失败；Clang 在启用 zvfbfmin 1.0 后暴露 BF16 vector
  类型和宏，但被测 narrowing intrinsic 名称仍未声明。没有成功 BF16
  codegen，更没有 runtime validation。

不得概括为“所有 GCC 13 均不支持”或“GCC 14 才首次支持”，除非另有独立
官方版本证据。

## 13. 为什么不能确认 F001 defect

本材料确认底层 FP16 ISA 动态舍入机制，并观察到 Clang 18 对独立 FP16
intrinsic probe 的代码生成，但仍没有证明：

- 正式 vLLM 源码在项目实际工具链下生成何种代码；
- vLLM 调用时存在 non-RNE 环境；
- 项目语义要求必须固定 RNE；
- 实际算子或模型输出受到影响。

因此 F001 保持“机制可信度高、缺陷结论可信度中、needs behavior/semantic
validation”，不升级为 confirmed defect。

## 14. manifest

远端采集完成后，在每台主机的 evidence 根目录生成相对路径校验集：

~~~bash
bash scripts/create_remote_checksums.sh <remote-evidence-directory>
~~~

校验集必须先在远端通过，再随文本证据回收并在本地再次通过。随后完成
README 和 REPORT，再运行：

~~~bash
bash scripts/create_manifest.sh \
  .riscv-audit/validation/F001-rounding/results/<timestamp> \
  <repository-root>
~~~

manifest 记录基线 HEAD、分支、三代结果、顶层环境摘要、源码、脚本和文档
哈希，以及编译器/header、CPU/环境、完整命令、退出码、远端校验集、
二进制/对象哈希文本、反汇编和运行日志哈希。它不记录密钥、token、密码或
无关环境变量。
