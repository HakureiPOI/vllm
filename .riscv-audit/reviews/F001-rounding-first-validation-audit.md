# F001 第一轮最小动态验证独立审查报告

## 1. 审查结论

**总体结论：NEEDS CORRECTION**

现有实验能够证明一个有价值但范围有限的事实：在被测 Spacemit X60 RISC-V 环境中，直接执行 ISA 指令 vfncvt.f.f.w 时，舍入结果随动态 frm 改变；显式保存 frm、临时切换到 RNE、执行转换并恢复 frm 的汇编序列在指令层面正确。O0 运行记录与 O0/O3 反汇编也支持这些判断。

但证据包尚不足以接受报告中较宽的 API、BF16、优化级别和手工 RNE 运行时结论。主要原因是：缺少 O3 运行记录和编译过程原始日志；手工 RNE 函数总是在调用者先恢复到原 RNE 后才执行，未在非 RNE 环境中验证其保存、覆盖和恢复行为；API 探针使用了错误的源 LMUL 且缺少原始诊断；BF16 没有对应的编译或运行探针；部分术语把 ISA、C intrinsic、vLLM 源码和实际触发链混为一谈。

因此本轮实验不是无效实验，但证据包必须整改后才能作为严谨、可复现的动态验证材料。F001 不应在本轮升级为 confirmed。

## 2. 审查范围与只读约束

审查对象：

- `.riscv-audit/findings/F001-vfncvt-dynamic-rounding.md`
- `.riscv-audit/STATUS.md`
- `.riscv-audit/validation/F001-rounding/` 下的 README、REPORT、测试源、环境摘要和结果文件
- 正式实现 `csrc/cpu/cpu_types_riscv_impl.hpp` 及其类型/LMUL 定义
- bianbu 与 aliyun 上仍存在的实验文件，仅进行哈希、反汇编、文件内容和工具链能力的只读核验

本审查没有：

- 修改正式源码、finding、STATUS 或原始验证材料；
- 重编译或重跑实验；
- 实现 F001 修复；
- 提交或推送任何变更。

远端二进制复跑曾按任务授权请求执行，但运行环境拒绝了该远端执行请求。此限制不影响既有证据的静态核验，但意味着本审查没有生成新的运行结果。

## 3. 证据清单与可追溯性

证据包包含 8 个文件：

- `README.md`
- `REPORT.md`
- `src/test_fp16_isa.c`
- `environment/bianbu.txt`
- `environment/aliyun.txt`
- `results/20260729T112835Z/compile-commands.txt`
- `results/20260729T112835Z/disasm.txt`
- `results/20260729T112835Z/run_o0.txt`

缺失但对完整复现重要的材料：

- O3 运行日志；
- O0/O3 编译 stdout、stderr 和退出码；
- API 探针源码、实际命令、原始编译诊断及退出码；
- 预处理宏的原始输出；
- 头文件哈希的原始命令输出；
- BF16 探针；
- 文件清单和哈希 manifest；
- README 所提到的 `scripts/inventory.sh`。

本次远端只读核验确认：

- bianbu 上测试源、O0 和 O3 二进制仍存在；
- 测试源和两个二进制 SHA-256 与 `disasm.txt` 记录一致；
- O0/O3 四个目标函数的现场反汇编与已提交摘录一致；
- bianbu 与 aliyun 上目标 RVV intrinsic 头文件 SHA-256 均为 `9201ab7df8abdf4794ffa0f78a0d12224bdddb98c86c455904c56d9b2903a20`；
- aliyun 上遗留的 FP16 intrinsic 探针源码存在，但未被纳入证据包；
- aliyun 的 Clang 18 列出了 riscv32/riscv64 后端，因此“Clang 只有 x86、不能面向 RISC-V”不能由现有信息支持。

## 4. 正式源码与实验的对应关系

### 4.1 正式源码直接确认

正式实现中四处使用无显式舍入参数的 RVV narrowing intrinsic：

- FP16Vec16：`__riscv_vfncvt_f_f_w_f16`，目标 LMUL 为 m2，VL 为 16；
- FP16Vec8：同一 intrinsic，目标 LMUL 为 m1，VL 为 8；
- BF16Vec8：BF16 对应 narrowing intrinsic，目标 LMUL 为 m1，VL 为 8；
- BF16Vec16：BF16 对应 narrowing intrinsic，目标 LMUL 为 m2，VL 为 16。

宏展开没有附加显式 `_rm` 变体或固定 RNE 参数。就 ISA 语义而言，vfncvt.f.f.w 使用动态舍入模式 frm，并更新浮点异常标志。

### 4.2 实验实际覆盖

测试程序没有包含 vLLM 头文件，也没有调用上述 C intrinsic。它用内联汇编直接执行 FP32 到 FP16 的 vfncvt.f.f.w，AVL 为 1，源配置为 e32,m1，目标配置为 e16,mf2。

因此实验与正式实现的准确关系是：

**ISA-equivalent（ISA 等价）**。

它验证了同一 FP16 ISA 操作单元素舍入受 frm 控制的机制，但没有验证：

- GCC/Clang 对正式 C intrinsic 的前端解析和代码生成；
- 正式实现使用的 m1/m2 目标 LMUL 和 VL=8/16；
- vLLM 模板、类型封装和调用路径；
- BF16 指令路径；
- 实际模型或算子触发。

不应将其称为 source-equivalent、vLLM 最小复现或 vLLM 动态复现。

## 5. 内联汇编技术审查

### 5.1 指令、寄存器组与约束

测试序列在被测配置下有效：

- `vsetvli ..., e32, m1` 后，v1 承载单个 FP32 源元素；
- narrowing 后目标 EEW 减半，e16,mf2 与源 e32,m1 的元素组关系匹配；
- v1 与 v2 不重叠，满足 narrowing 指令寄存器组约束；
- AVL=1，使两次 vsetvli 的实际 VL 均为 1；
- `vfmv.s.f` 写入元素 0，`vmv.x.s` 取回元素 0；
- 输出为寄存器约束，v1/v2/t0（以及手工路径中的 t1）列为 clobber；
- 汇编不访问内存，缺少 memory clobber 不构成问题；
- volatile、noinline 和寄存器输出足以阻止该核心转换被优化删除或常量折叠。

源文件中重复写了 `noinline, noinline`，这是无害的可读性问题。

### 5.2 ambient 路径

ambient 函数只设置 vtype/VL、装载输入、执行 vfncvt.f.f.w 并取回结果，没有读写 frm。O0 和 O3 反汇编均显示预期 narrowing 指令，且函数体中没有 CSR 舍入模式操作。

### 5.3 manual RNE 路径

manual 函数的指令序列为：

1. frrm 保存当前 frm；
2. fsrmi 0 设置 RNE；
3. 执行 vfncvt.f.f.w；
4. fsrm 恢复保存的 frm。

O0 和 O3 反汇编均与此一致。对单一正常返回路径而言，该序列能保存和恢复 frm。

但是它只保存 frm，不保存整个 fcsr，也不会恢复转换累积的 fflags。报告若把它描述为“完整保存并恢复浮点环境”或“无副作用”，属于过度表述。更准确的说法是“保存并恢复舍入模式，但保留指令产生的浮点异常标志副作用”。

## 6. 舍入理论与运行结果审查

### 6.1 中点与邻值选择

关键正中点 `1.00048828125` 位于 FP16 的 1.0（0x3c00）与 1.0009765625（0x3c01）之间。较低候选的尾数最低位为偶数，因此预期：

- RNE、RTZ、RDN -> 0x3c00；
- RUP -> 0x3c01。

负中点 `-1.00048828125` 位于 -1.0（0xbc00）与 -1.0009765625（0xbc01）之间，预期：

- RNE、RTZ、RUP -> 0xbc00；
- RDN -> 0xbc01。

O0 日志与上述理论一致。高于和低于中点的两个正数也分别产生符合四种舍入方向的结果。

### 6.2 边界值

- `6.103515625e-05` 是 FP16 最小正规数本身，不只是“接近最小正规数”；结果 0x0400 正确。
- 65504 是最大有限 FP16，结果 0x7bff 正确。
- 65520 是 RNE 从最大有限值到无穷的阈值；日志显示 RNE/RUP 为正无穷，RTZ/RDN 为最大有限值，符合预期。
- 正负零保号结果正确。

该集合没有覆盖真正的 FP16 次正规数、下溢、NaN、信号 NaN 或舍入导致的符号相关极端情况。它们可作为后续补充，但不影响“中点受 frm 控制”这一核心观察。

## 7. O0、O3 与稳定性证据

### 7.1 O0

`run_o0.txt` 包含 9 个输入在 RNE、RTZ、RDN、RUP 下的结果，以及 10 次稳定性循环。日志内部的 frm readback 与设置模式一致，ambient 结果随模式变化并符合理论。

这足以支持：在该机器、该二进制的一次 O0 运行中，直接 ISA narrowing 观察到了动态舍入行为。

### 7.2 O3

证据包只有 O3 编译命令、二进制哈希和目标函数反汇编，没有 O3 运行日志。因此只能确认 O3 二进制中保留了目标指令序列，不能声称 O3 运行结果已与 O0 一致、O3 稳定性已验证或 O3 全部测试通过。

### 7.3 十次稳定性循环

十次循环是在同一个 O0 进程内完成，覆盖四种 ambient 模式的重复输出。它能支持该次运行内结果稳定，不能等同于：

- 十次独立进程运行；
- O3 稳定性；
- 不同机器或工具链稳定性；
- manual RNE 在非 RNE 调用环境中的恢复稳定性。

## 8. manual RNE 运行时对照的关键缺陷

测试主循环的调用顺序是：

1. 设置待测舍入模式；
2. 调用 ambient；
3. 恢复程序进入时的旧舍入模式；
4. 读取恢复后的 frm；
5. 调用 manual RNE。

日志表明旧模式是 RNE。因此在 RTZ、RDN、RUP 行中，manual 函数被调用前，调用者已经恢复为 RNE。稳定性循环也采用相同顺序。

这造成两个限制：

- manual 函数从未在非 RNE ambient 环境下执行，无法动态证明它能临时覆盖 RTZ/RDN/RUP；
- 调用后没有再次读取 frm，无法动态证明函数返回后恢复了调用前模式。

反汇编证明指令序列静态上正确，但当前运行日志不能支持“manual RNE 在四种外部舍入模式下均强制 RNE并恢复原模式”的动态结论。整改时应在设置非 RNE 后直接调用 manual，并分别记录调用前、调用后 frm；ambient 与 manual 应共享同一外部模式输入。

## 9. C intrinsic API 与 FENV 结论

### 9.1 现有 API 证据的问题

证据包没有纳入 API 探针源码、原始编译命令、编译诊断或退出码。远端遗留源码显示 FP16 m1 返回类型的探针传入了 `vfloat32m1_t`，而标准 v1.0 API 对 FP16 m1 narrowing 的源类型应为 `vfloat32m2_t`。因此该探针即使在完整支持 API 的工具链上也会因签名不匹配而失败。

诊断首先出现未知 `vfloat16m1_t`，可作为“这两个被测 GCC 安装在该参数下没有暴露所需 FP16 类型”的线索，但缺少原始诊断且探针本身错误，不能据此概括“GCC 13 均不支持”或把任何失败都归因于 API 缺失。

准确结论应限定为：

> 在已记录的两个 GCC 13.x 安装和所用 `-march` 参数下，环境摘要表明所需 FP16 intrinsic 类型/API 未能成功使用；现有证据包不足以形成可独立复现的完整编译探针结论。

### 9.2 FENV 术语

GCC 的 `-frounding-math` 与编译器对动态舍入环境的假设有关，但本测试的核心转换由内联汇编直接发出，不经过 C intrinsic 的舍入语义选择。因而矩阵中把该实验直接标为 C intrinsic 的 FENV=ON 容易误导。

应分别记录：

- 编译命令是否使用 `-frounding-math`；
- ISA 汇编路径的实际 frm 行为；
- C intrinsic 在默认/动态 FENV 语义下选择隐式或显式 `_rm` API 的问题。

三者不能互相替代。

### 9.3 Clang

bianbu 未安装 Clang。aliyun 的 Clang 18 列出 RISC-V 后端，但尚未验证 sysroot、头文件或 intrinsic API 是否可用。应写成“后端存在，API 编译未测试”，而不是“仅支持 x86”。

## 10. BF16 证据评价

本轮没有 BF16 测试源、编译探针、汇编、运行日志或数值结果。环境摘要中的头文件/宏搜索最多属于 API inventory。

`/proc/cpuinfo` 未列出 zvfbfmin 只说明当前内核暴露的信息没有宣告该扩展，不能单独证明硬件必然不支持。尤其在审计上下文已经关注内核与硬件能力报告差异时，更不应把“未宣告”写成“硬件不支持”。

因此 BF16 当前只能表述为：

- 做过有限的头文件/宏摘要检查；
- 未完成可复现的 API 编译验证；
- 未完成代码生成验证；
- 未完成运行时语义验证；
- 未证明硬件支持或不支持。

## 11. 分层结论

| 层级 | 本轮状态 | 可接受结论 |
|---|---|---|
| ISA 规范机制 | 已确认 | vfncvt.f.f.w 使用动态 frm，并影响舍入结果；异常标志会被累积 |
| 被测机器 ISA 行为 | 部分动态确认 | Spacemit X60 的 O0 记录显示 FP32->FP16 narrowing 随四种 frm 改变；O3 仅确认指令存在 |
| C intrinsic API/代码生成 | 证据不足 | 被测 GCC 环境疑似缺少所需 FP16 API，但探针错误且原始证据缺失；Clang 未测试 |
| vLLM 最小源码路径 | 未测试 | 实验没有编译或调用正式 vLLM intrinsic 封装 |
| vLLM 实际触发路径 | 未测试 | 未运行 vLLM 算子或模型路径 |
| 用户可见数值/模型影响 | 未测试 | 未测量真实输出差异、误差或性能 |

这一区分必须保留在 README、REPORT、finding 和 STATUS 的后续整改中。

## 12. 审查发现

### Critical

No Critical findings.

### Major

#### M1：O3 动态运行证据缺失

- 文件/位置：`results/20260729T112835Z/`，`REPORT.md` 的 O0/O3 结论。
- 问题：只有 `run_o0.txt`，没有 O3 运行日志；也没有两次编译的 stdout、stderr 和退出码。
- 影响：不能独立确认 O3 运行成功、数值与 O0 一致或 O3 稳定性。
- 是否需修正：是。
- 建议：保存 O0/O3 编译日志和退出码，补充 O3 完整运行日志，并在补齐前收紧所有 O3 动态措辞。

#### M2：manual RNE 对照没有在非 RNE 环境中执行

- 文件/位置：`src/test_fp16_isa.c` 主循环和稳定性循环；`run_o0.txt`。
- 问题：调用 manual 前已恢复旧 RNE，且调用后没有 frm readback。
- 影响：运行时证据不能证明强制 RNE或恢复外部 RTZ/RDN/RUP；结论依赖反汇编静态推断。
- 是否需修正：是。
- 建议：在每个外部模式仍生效时调用 manual，记录调用前后 frm，并断言 manual 输出为 RNE、返回后模式不变。

#### M3：实验等价层级与 FENV 术语混用

- 文件/位置：`README.md`、`REPORT.md` 的范围、矩阵和结论段。
- 问题：直接 ISA 汇编被用于支持 C intrinsic、FENV 和 vLLM 路径的较宽结论。
- 影响：读者可能误认为正式源码/API 已被动态复现。
- 是否需修正：是。
- 建议：统一标注 ISA-equivalent；分别列出 ISA、C intrinsic、vLLM 源码、实际触发和影响层。

#### M4：FP16 API 探针不可独立复现且源 LMUL 错误

- 文件/位置：`environment/*.txt`、`REPORT.md` 的工具链/API 结论；远端遗留探针。
- 问题：证据包缺原始探针/诊断；m1 目标错误使用 m1 FP32 源，而标准签名需要 m2 源。
- 影响：失败原因不唯一，无法支持跨 GCC 版本的普遍结论。
- 是否需修正：是。
- 建议：提交正确类型组合的最小探针、完整命令、版本、stdout/stderr、退出码和宏输出；结论限定到实际测试的安装与参数。

#### M5：BF16 验证状态被过度表述

- 文件/位置：`README.md`、`REPORT.md`、`environment/*.txt` 的 BF16 描述。
- 问题：没有 BF16 编译、代码生成或运行证据；cpuinfo 缺失扩展也不能证明硬件不支持。
- 影响：将 inventory 错写为验证结论。
- 是否需修正：是。
- 建议：当前改写为 inventory only；如需推进，另做正确 BF16 API 探针和具备能力目标上的运行验证。

#### M6：证据来源和复现材料不完整

- 文件/位置：整个证据包，尤其 README 提及但未包含的脚本。
- 问题：缺原始编译/API/宏/哈希日志、manifest 和实际 inventory 脚本。
- 影响：第三方不能仅凭提交内容重建全部报告结论。
- 是否需修正：是。
- 建议：补齐原始材料，增加带 SHA-256、命令、主机、时间和退出码的 manifest；删除或补齐失效脚本引用。

#### M7：Clang 能力描述不准确

- 文件/位置：`environment/aliyun.txt`、`REPORT.md` 的 Clang 描述。
- 问题：现有 Clang 18 实际列出 RISC-V 后端；但 API/sysroot 未测试。
- 影响：环境能力边界被错误陈述。
- 是否需修正：是。
- 建议：改为“RISC-V 后端存在，目标 sysroot/header/intrinsic API 未验证”。

### Minor

#### m1：只恢复 frm，未处理 fflags

- 文件/位置：`src/test_fp16_isa.c` manual 函数；REPORT 的恢复表述。
- 问题：转换可能设置 NX/OF，程序没有清零、读取或恢复 fflags。
- 影响：不影响舍入结果观察，但影响“完整恢复浮点环境/无副作用”的表述。
- 是否需修正：措辞必须修正；是否测试 fflags 可选。
- 建议：明确只恢复 frm；若目标要求环境透明，再增加 fflags 策略和测试。

#### m2：十次稳定性范围较窄

- 文件/位置：`run_o0.txt` 稳定性段。
- 问题：同一 O0 进程内循环 10 次，不是独立运行，且不覆盖 O3/manual 外部模式恢复。
- 影响：稳定性外推范围有限。
- 是否需修正：是，主要是收紧措辞。
- 建议：写明“单进程 O0 十次循环”；必要时补独立进程/O3。

#### m3：边界用例命名与覆盖不完整

- 文件/位置：测试输入表和 REPORT。
- 问题：所谓 near-min-normal 实际是精确最小正规数；没有真实次正规数、NaN 和下溢。
- 影响：边界覆盖描述略宽。
- 是否需修正：是，改名即可；额外用例可选。
- 建议：准确标注 exact min normal，并列出未覆盖类别。

#### m4：缺少失败即退出的程序级断言

- 文件/位置：`src/test_fp16_isa.c`。
- 问题：未检查 fesetround 返回值，也未将错误结果转化为非零退出码。
- 影响：自动化复跑时仅凭进程成功不能判断语义通过。
- 是否需修正：建议修正。
- 建议：检查设置/读取结果，对期望位模式和恢复状态断言，失败返回非零。

#### m5：重复 noinline 属性

- 文件/位置：`src/test_fp16_isa.c` 三个函数声明。
- 问题：`noinline` 重复。
- 影响：无语义影响，仅降低整洁度。
- 是否需修正：可选。
- 建议：保留一个 noinline。

### Informational

- O0/O3 目标函数的二进制哈希和现场反汇编与证据包一致，未发现反汇编摘录伪造或错配。
- ambient 的结果表与 RISC-V frm 四种模式和 FP16 邻值理论一致。
- 正式源码调用与实验在 FP16 narrowing opcode 机制上有关联，但 LMUL、VL、前端/API 和集成路径不同。
- 当前材料没有证明实际 vLLM 模型输出受影响，也没有反证该风险。

## 13. 状态建议

F001 建议保持：

- **机制置信度：高**；
- **缺陷置信度：中**；
- **状态：needs behavior/semantic validation**。

不建议升级为 confirmed。更精确的阶段性描述是：

> 已在 Spacemit X60 上以 ISA-equivalent FP32->FP16 单元素实验观察到 vfncvt.f.f.w 对动态 frm 的依赖；正式 vLLM C intrinsic 代码生成、BF16、vLLM 实际触发和用户可见数值影响尚未验证。

## 14. 必须整改项

在将本证据包视为完成前，至少应：

1. 补充 O3 完整运行日志，以及 O0/O3 编译日志和真实退出码；或删除所有未被证据支持的 O3 动态结论。
2. 修正 manual RNE 测试顺序，在非 RNE 外部模式下执行并记录调用前后 frm。
3. 将实验定位统一收紧为 ISA-equivalent，拆分 ISA、C intrinsic、vLLM 源码、实际触发和影响层结论。
4. 提交正确 LMUL 的 FP16 API 探针、命令、诊断和退出码；删除对全部 GCC 13 的泛化。
5. 将 BF16 状态收紧为 inventory only，除非补充独立可复现的 BF16 探针/运行证据。
6. 修正 aliyun Clang 描述。
7. 补齐或删除 `scripts/inventory.sh` 引用，并增加原始日志与 manifest。
8. 明确 manual 只恢复 frm、不恢复 fflags；收紧稳定性和边界覆盖措辞。

## 15. 可选后续验证

- 使用支持 RISC-V Vector C Intrinsic v1.0 FP16 类型的工具链，分别编译隐式舍入和显式 `_rm` 变体，并保存预处理、诊断和反汇编。
- 在正式 vLLM 使用的 m1/m2、VL=8/16 组合上做最小源级验证，而不是只测 e16,mf2、VL=1。
- 在确认具备 Zvfbfmin 的目标上单独验证 BF16；当前 X60 cpuinfo 记录不适合得出 BF16 运行结论。
- 增加真实次正规数、下溢、NaN 和 fflags 观察，但不要让这些扩展阻塞核心中点实验整改。
- 在证据链完整后再设计 vLLM 实际调用路径验证和数值影响测试。

## 16. 参考规范

- RISC-V Vector Extension 规范：https://github.com/riscv/riscv-v-spec
- RISC-V Vector C Intrinsic 规范 v1.0：https://github.com/riscv-non-isa/rvv-intrinsic-doc/tree/v1.0.x
- RISC-V Unprivileged ISA 浮点扩展：https://github.com/riscv/riscv-isa-manual
- GCC RISC-V Vector Intrinsics 文档：https://gcc.gnu.org/onlinedocs/gcc/RISC-V-Vector-Intrinsics.html
- GCC 优化选项 `-frounding-math` 文档：https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html

## 17. 最终审查意见

该第一轮实验成功抓住了 F001 的底层 ISA 机制，O0 结果与反汇编具有实质证据价值；它不是循环论证，也没有发现通过修改正式实现来制造预期结果的情况。但报告把这一 ISA 层证据扩展到了尚未验证的 manual 非 RNE 恢复、O3 运行、C intrinsic、BF16 和 vLLM 集成层。先完成上述最小整改，再决定是否推进源级和实际触发验证；在此之前，F001 应保持“机制高、缺陷中、仍需行为/语义验证”。
