# F001 FP32→FP16 ISA 级动态舍入验证整改报告

## 1. 执行摘要

本轮完成对第一轮验证包的工程整改。结论严格限定为：

- **ISA-equivalent FP32→FP16 mechanism observed**：在 Spacemit X60 上，
  O0 和 O3 均动态观察到裸 `vfncvt.f.f.w` 使用当前 `frm`。
- manual CSR RNE control 已在 RNE、RTZ、RDN、RUP 四种真实外部模式下运行；
  结果始终为 RNE，返回后 `frm` 恢复为调用前外部模式。
- manual 只恢复 `frm`；转换产生的 `fflags` 不被恢复。
- bianbu GCC 13.2 和 aliyun RISC-V GCC 13.3 的正确 LMUL FP16 C intrinsic
  probes 均编译失败。
- aliyun Clang 18 的正确 LMUL FP16 implicit 与 explicit `_rm` probes 均
  编译成功，并取得可区分的代码生成证据。
- **C intrinsic runtime behavior not validated**：Clang 结果是 compile-only
  codegen observation，未运行。
- BF16 只有 API inventory 和失败的 compile probes；无成功 codegen、无
  runtime validation。
- **vLLM path not tested；F001 not confirmed**。

推荐状态仍为：机制可信度高、缺陷结论可信度中、needs behavior/semantic
validation，不升级为 confirmed defect。

## 2. 整改依据与证据代际

独立审查报告：

`.riscv-audit/reviews/F001-rounding-first-validation-audit.md`

证据分为两代：

| 目录 | 定位 | 处理 |
|---|---|---|
| `results/20260729T112835Z/` | first-run evidence | 不可变原始证据，保留原局限 |
| `results/20260729T144517Z/` | remediation evidence | 修正第一轮主要实验设计问题 |
| `results/20260729T152738Z/` | evidence-closure evidence | 本报告最终依据；补齐 fflags 与哈希闭环 |

第一轮没有 O3 运行日志，manual 在调用前已被恢复到 RNE，API 探针类型关系
错误且缺少原始诊断。本轮没有改写第一轮文件，而是在新时间戳目录重新生成。

实验针对的仓库 HEAD 为：

`8d4a0e429e64c7d5b32021525dc78ae6806db804`

分支为：

`validation/f001-rounding`

## 3. 正式源码可疑点

正式源码 `csrc/cpu/cpu_types_riscv_impl.hpp` 中存在四处 non-`_rm`
narrowing intrinsic 调用：

| 位置 | 目标类型/LMUL | 源类型/LMUL | VL |
|---|---|---|---|
| FP16Vec16 赋值 | FP16 m2 | FP32 m4 | 16 |
| FP16Vec8 赋值 | FP16 m1 | FP32 m2 | 8 |
| BF16Vec8 构造 | BF16 m1 | FP32 m2 | 8 |
| BF16Vec16 构造 | BF16 m2 | FP32 m4 | 16 |

`RVVI(base, lmul)` 仅连接 intrinsic 名称和 LMUL，不生成 `_rm` 后缀。

这是静态源码事实，不等于缺陷已确认。本实验没有包含 vLLM header，也没有
直接编译或调用这四处实现。

## 4. 证据层级

| 层级 | 状态 | 本轮证据 |
|---|---|---|
| ISA 规范机制 | confirmed | vfncvt.f.f.w 使用动态 frm；转换可设置 fflags |
| X60 ISA 运行行为 | observed | O0/O3 裸 ISA 动态结果、frm/fflags readback |
| GCC 13.2 C intrinsic | probe failed | 正确 LMUL source、命令、诊断、退出码 |
| GCC 13.3 C intrinsic | probe failed | 正确 LMUL source、命令、诊断、退出码 |
| Clang 18 FP16 C intrinsic | codegen observed | implicit 与 explicit _rm 均编译并反汇编 |
| C intrinsic 运行行为 | not tested | 未运行 Clang 交叉编译对象 |
| BF16 C intrinsic | inventory/probe only | 类型/宏分层与失败诊断，无成功 codegen |
| vLLM 最小源码路径 | not tested | 未编译正式封装 |
| vLLM 实际调用 | not tested | 未运行算子或模型 |
| 用户可见影响 | not tested | 未测量输出或性能 |

## 5. 实验环境

### 5.1 bianbu：RISC-V 实机

- Linux riscv64，内核 `6.6.63-cloud`；
- Spacemit X60；
- Bianbu GCC `13.2.0-23ubuntu4bb4`；
- `/proc/cpuinfo` 当前宣告 `v`、`zvfh`、`zvfhmin`，未宣告
  `zvfbfmin`；
- GCC header：
  `/usr/lib/gcc/riscv64-linux-gnu/13/include/riscv_vector.h`；
- header SHA-256：
  `9201ab7df8abdf4794ffa0f78a0d12224bdddbb98c86c455904c56d9b2903a20`。

证据位置：

- `results/20260729T152738Z/bianbu/environment/`；
- `results/20260729T152738Z/bianbu/gcc-probes/`。

cpuinfo 未宣告 zvfbfmin 只说明当前内核导出信息没有宣告该扩展，不能证明 X60
硬件一定不支持。

### 5.2 aliyun：x86_64 交叉编译主机

- Linux x86_64；
- RISC-V GCC `13.3.0-6ubuntu2~24.04.1`；
- GCC header：
  `/usr/lib/gcc-cross/riscv64-linux-gnu/13/include/riscv_vector.h`；
- GCC header SHA-256 与 bianbu 相同；
- Ubuntu Clang `18.1.3`；
- Clang `--print-targets` 列出 riscv32 和 riscv64；
- Clang resource header：
  `/usr/lib/llvm-18/lib/clang/18/include/riscv_vector.h`；
- Clang header SHA-256：
  `8dc1b13e12396ee0b014b656cf2187f7a499ef7643aa1ed5de459e937fc70fdf`。

Clang target preprocess 记录显示它选择了 RISC-V GCC 13 安装，并搜索 Clang
resource include、RISC-V target include 和系统 include。`crt1.o` 查询也解析
到 RISC-V 目标文件。故准确分类为：

- backend available；
- target GCC installation and target runtime file discoverable；
- `riscv_vector.h` available；
- FP16 types and API available for compile-only probe；
- link not attempted；
- runtime not attempted。

证据位置：

- `results/20260729T152738Z/aliyun/environment-*`；
- `results/20260729T152738Z/aliyun/clang-probes/`；
- `results/20260729T152738Z/aliyun/clang-experimental-bf16-probes/`。

## 6. ISA 实验实现与中立性

ambient-frm ISA path：

~~~text
li             AVL = 1
vsetvli        e32,m1
vfmv.s.f       load one FP32 element
vsetvli        e16,mf2
vfncvt.f.f.w   narrow using current frm
vmv.x.s        extract FP16 bits
~~~

manual CSR RNE control：

~~~text
frrm           save caller frm
fsrmi 0        set RNE
vfncvt.f.f.w
fsrm           restore caller frm
~~~

寄存器组关系 e32,m1 → e16,mf2 对 narrowing 有效，AVL=1。两条函数路径都
使用 inline assembly，不经过 C intrinsic。

测试程序还实现 `read_frm`、`write_frm`、`read_fflags` 和 `write_fflags`，
检查每次 `fesetround` 返回值，并将所有预期写成程序级判断。任何模式、
结果、状态恢复或稳定性不匹配都会使程序返回非零。

本实验与正式代码共享 FP32→FP16 `vfncvt.f.f.w` 舍入机制，但 LMUL、VL、
编译前端和集成路径不同，因此是 ISA-equivalent，不是 source-equivalent。

## 7. 理论输入与预期

### 7.1 positive midpoint

`1.00048828125`，FP32 bits `0x3f801000`，位于 FP16 `0x3c00`（1.0）
与 `0x3c01`（1.0009765625）正中间。较低候选尾位为偶数：

| frm | 预期 |
|---|---|
| RNE | 0x3c00 |
| RTZ | 0x3c00 |
| RDN | 0x3c00 |
| RUP | 0x3c01 |

### 7.2 negative midpoint

`-1.00048828125`，FP32 bits `0xbf801000`：

| frm | 预期 |
|---|---|
| RNE | 0xbc00 |
| RTZ | 0xbc00 |
| RDN | 0xbc01 |
| RUP | 0xbc00 |

### 7.3 最大值与阈值

- `65504`，FP32 bits `0x477fe000`，是 FP16 maximum finite，预期
  `0x7bff`。
- `65520`，FP32 bits `0x477ff000`，是本测试使用的 FP16 overflow
  threshold：RNE/RUP 得到 `0x7c00`，RTZ/RDN 得到 `0x7bff`。

### 7.4 其他输入

- midpoint above 与 midpoint below；
- `6.103515625e-05`：exact FP16 minimum normal；
- positive zero 与 negative zero。

未覆盖 true subnormal、underflow boundary、NaN 和 signaling NaN。

## 8. O0 结果

证据目录：

`results/20260729T152738Z/bianbu/isa/O0/`

- 编译命令包含 `-O0 -fno-lto -frounding-math -march=rv64gcv_zvfh`；
- compile exit code：0；
- run exit code：0；
- 36 行功能矩阵全部 PASS；
- 40 行 single-process stability 全部 PASS；
- 最终 `SUMMARY failures=0 status=PASS`；
- 最终状态恢复为 `frm=0 fflags=0x00`（该进程的初始状态）。

positive midpoint：

| 外部模式 | ambient | manual RNE | manual 前 frm | manual 后 frm |
|---|---:|---:|---:|---:|
| RNE | 0x3c00 | 0x3c00 | 0 | 0 |
| RTZ | 0x3c00 | 0x3c00 | 1 | 1 |
| RDN | 0x3c00 | 0x3c00 | 2 | 2 |
| RUP | 0x3c01 | 0x3c00 | 3 | 3 |

这直接修正了第一轮 manual 只在恢复后的 RNE 下执行的问题。

## 9. O3 结果

证据目录：

`results/20260729T152738Z/bianbu/isa/O3/`

- 编译命令包含
  `-O3 -DNDEBUG -fno-lto -frounding-math -march=rv64gcv_zvfh`；
- compile exit code：0；
- run exit code：0；
- 36 行功能矩阵全部 PASS；
- 40 行 single-process stability 全部 PASS；
- 最终 `SUMMARY failures=0 status=PASS`；
- positive/negative midpoint、边界、manual frm 恢复均与 O0 一致。

因此 O3 结论不再仅依赖反汇编，而有完整动态日志。

## 10. manual RNE 与 frm

每一条功能记录均按如下真实顺序执行：

~~~text
保存初始 frm/fflags
设置外部模式
读取 frm_before_ambient
执行 ambient
读取 frm_before_manual
在仍生效的外部模式下执行 manual RNE
读取 frm_after_manual
恢复初始 frm/fflags
读取 frm_after_final_restore
~~~

O0/O3 对 RNE、RTZ、RDN、RUP 均观察到：

- `frm_before_manual` 分别为 0、1、2、3；
- manual midpoint 结果始终为 RNE 的 `0x3c00`；
- `frm_after_manual` 分别仍为 0、1、2、3；
- `frm_after_final_restore` 均为本次进程初始值 0。

这支持“manual CSR RNE control 会恢复调用前 frm”。它不是 explicit `_rm`
intrinsic；后者另由 Clang compile probe 观察。

## 11. fflags

测试在每条路径转换前独立清零 fflags，并立即读取
`fflags_before_ambient`/`fflags_before_manual`；转换后读取
`fflags_after_ambient`/`fflags_after_manual`，最终恢复后读取
`fflags_after_final_restore`。

O0/O3 共 72 条功能记录和 80 条稳定性记录中，全部观察到：

~~~text
fflags_before_ambient=0x00
fflags_before_manual=0x00
fflags_after_final_restore=0x00
status=PASS
~~~

转换后的观察为：

| 输入 | 观察 |
|---|---|
| midpoint、above、below | ambient/manual 均为 `0x01`（NX） |
| exact minimum normal | `0x00` |
| maximum finite | `0x00` |
| positive/negative zero | `0x00` |
| 65520 ambient RNE/RUP | `0x05`（OF \| NX） |
| 65520 ambient RTZ/RDN | `0x01`（NX） |
| 65520 manual RNE | 所有外部模式下均为 `0x05`（OF \| NX） |

manual 汇编没有保存或恢复 fflags。转换产生的标志在 manual 返回后仍存在。
因此只能说“恢复舍入模式字段 frm”，不能说“完整恢复 fcsr”或“无浮点环境
副作用”。

程序级 harness 在完成每行后恢复启动时的 frm 和 fflags，以避免测试之间
污染；这与 manual 函数本身的边界是两件事。

## 12. single-process 稳定性

每个优化等级、每种舍入模式都在一个进程内循环 10 次，并在每次迭代同时
检查 ambient 和 manual 两条路径：

~~~text
2 optimization levels
x 4 rounding modes
x 10 iterations
= 80 stability records
~~~

O0 和 O3 各 40 行，全部 PASS。该结果只能称为 single-process
10-iteration stability check，不代表 10 次独立进程、跨机器稳定性或长期
压力测试。

## 13. 反汇编

### 13.1 bare ambient ISA

O0/O3 `convert_fp16_ambient_isa` 都包含 e32,m1 → e16,mf2 与
`vfncvt.f.f.w`，函数内没有 frm CSR 管理。

### 13.2 manual CSR RNE

O0/O3 `convert_fp16_manual_rne_isa` 都包含：

~~~text
frrm
fsrmi 0
vfncvt.f.f.w
fsrm
~~~

### 13.3 Clang C intrinsic codegen

Clang 18 FP16 implicit probe 的 m1/m2 函数均生成 `vfncvt.f.f.w`，没有
显式 frm 保存/设置/恢复。

Clang 18 FP16 explicit `_rm` probe 的 m1/m2 函数均生成：

~~~text
fsrmi <saved-register>, 0
vfncvt.f.f.w
fsrm <saved-register>
~~~

这是成功的 C intrinsic codegen observation，但没有在 RISC-V 目标上运行
这些交叉编译对象，故不是 runtime observation，也不是 vLLM 路径验证。

## 14. C intrinsic API probe

所有 probes 均使用正式 narrowing 所需的正确关系：

~~~text
FP16/BF16 m1 destination <- FP32 m2 source
FP16/BF16 m2 destination <- FP32 m4 source
~~~

| 工具链/参数 | FP16 implicit | FP16 explicit _rm | BF16 implicit | BF16 explicit _rm |
|---|---:|---:|---:|---:|
| bianbu GCC 13.2 | fail | fail | fail | fail |
| aliyun GCC 13.3 | fail | fail | fail | fail |
| aliyun Clang 18，普通 zvfbfmin 名称 | pass | pass | arch rejected | arch rejected |
| Clang 18，experimental zvfbfmin1p0 | pass | pass | fail | fail |

### 14.1 GCC 13.2

FP16 probes 的首要诊断是未知 `vfloat16m1_t`/`vfloat16m2_t`，并报告被测
intrinsic 未声明；explicit probe 还报告 `__RISCV_FRM_RNE` 未声明。

### 14.2 GCC 13.3

结果与 GCC 13.2 相同。两个 GCC header SHA-256 相同，但不能由两个安装
泛化到所有 GCC 13 或宣称某个后续大版本才首次支持。

### 14.3 Clang 18 FP16

在 `--target=riscv64-linux-gnu -march=rv64gcv_zvfh` 下：

- backend 可用；
- target header 可用；
- `vfloat16m1_t`、`vfloat16m2_t` 可用；
- implicit probe 编译成功；
- `__RISCV_FRM_RNE` 与 explicit `_rm` probe 编译成功；
- 生成 RISC-V ELF 对象并由 RISC-V objdump 反汇编；
- 未链接，未运行。

因此原“Clang 仅支持 x86”以及“explicit `_rm` 完全 blocked”说法已纠正。
准确说法是：GCC 两个被测安装 blocked；Clang 18 compile/codegen available，
runtime not tested。

## 15. BF16 边界

GCC 13.2/13.3 在显式
`-march=rv64gcv_zvfh_zvfbfmin` 下能产生 `__riscv_zvfbfmin` 宏，但其
header/API probe 仍报告 BF16 vector 类型和 narrowing intrinsic 不可用。

Clang 18 首次使用无版本 `zvfbfmin` 时拒绝参数，明确要求
`-menable-experimental-extensions` 和显式版本。补充 probe 使用编译器诊断
确认的 `zvfbfmin1p0` 后：

- 宏 `__riscv_zvfbfmin 1000000` 存在；
- `vbfloat16m1_t`/`vbfloat16m2_t` 类型可用；
- 被测 implicit 和 explicit `_rm` narrowing intrinsic 名称均未声明；
- 两个 BF16 probe 均退出 1；
- 没有对象和反汇编。

因此 BF16 当前为 **API inventory and compile probe only**：

- no successful codegen；
- no runtime validation；
- 未在 bianbu 执行 BF16 指令；
- 未证明 X60 硬件支持或不支持 zvfbfmin。

## 16. 已确认与未确认

### 已确认

- RISC-V `vfncvt.f.f.w` 的动态 frm 机制；
- X60 上 O0/O3 ambient FP32→FP16 单元素结果随 frm 变化；
- manual CSR RNE 在四种真实外部模式下输出 RNE 并恢复 frm；
- manual 不恢复 fflags，转换可留下 NX/OF；
- O0/O3 单进程、每模式十次稳定性；
- 两个被测 GCC 13 安装中的 FP16/BF16 probe 失败方式；
- Clang 18 RISC-V 后端、target header 与 FP16 intrinsic compile/codegen；
- Clang 18 BF16 experimental 参数、类型与 intrinsic 可用性边界。

### 未确认

- C intrinsic 的 RISC-V 运行时行为；
- GCC 其他构建、发行版或版本的普遍能力；
- 正式 vLLM C intrinsic 的项目代码生成；
- vLLM 运行时存在 non-RNE 调用环境；
- 项目语义必须固定 RNE；
- BF16 codegen 或 runtime；
- true subnormal、underflow boundary、NaN、signaling NaN；
- 用户可见数值或模型影响。

## 17. 对 F001 状态的影响

推荐结论：

> F001 的 FP16 ISA 级动态舍入机制已在 Spacemit X60 上以 O0/O3
> ISA-equivalent 实验观察；Clang 18 对独立、正确 LMUL 的 FP16 implicit
> 和 explicit _rm C intrinsic 已取得代码生成证据，但尚未验证其运行时，
> 也未证明正式 vLLM 路径在 non-RNE 环境下触发，或项目语义要求固定 RNE。
> 因此维持机制可信度高、缺陷结论可信度中，不升级为 confirmed。

状态保持：

`needs behavior/semantic validation`

## 18. 后续验证

本轮不实施以下工作：

1. 在可运行且支持 Vector C Intrinsics v1.0 FP16 API 的 RISC-V 工具链上执行
   implicit/explicit `_rm` runtime 对照；
2. 编译正式 vLLM 使用的 m1/m2、VL=8/16 最小源码路径；
3. 证明 vLLM 实际调用时存在 non-RNE 环境；
4. 明确项目所要求的舍入语义；
5. 在明确宣告 zvfbfmin 的运行目标上验证 BF16；
6. 测量实际算子或模型输出影响。

在这些行为和语义条件满足前，不进入 F001 修复实现，也不升级为 confirmed
defect。

## 19. 可复现性与仓库卫生

`results/20260729T152738Z/manifest.txt` 记录：

- UTC 时间戳、仓库 HEAD、分支；
- 测试源、probes、脚本、顶层环境摘要、README、REPORT SHA-256；
- first-run、remediation 和 evidence-closure 三代证据哈希；
- 编译器路径/版本；
- header 路径/SHA-256；
- CPU/环境证据；
- 完整编译和宏命令；
- 编译/运行退出码；
- 远端生成并在本地复核的相对路径 checksum sets；
- 二进制/对象 SHA-256、objdump 命令/版本和远端 disassembly SHA-256；
- source→binary/object→disassembly/run artifact-chain；
- 反汇编、运行日志及全部 evidence-closure 文件哈希；
- 远端主机角色。

仓库只保存文本和 C/shell 源码，不保存测试二进制、`.o`、`.so` 或 `.a`。
证据不包含 SSH key、token、密码或私密配置。
