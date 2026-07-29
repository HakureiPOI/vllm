# F004 Cross-Compile Validation

动态验证 F004：RISC-V 交叉编译时 CMake 使用构建主机 `/proc/cpuinfo` 判断目标 FP16/BF16 能力。

## 环境要求

- x86_64 Linux（Ubuntu 24.04 验证通过）
- cmake >= 3.28
- ninja
- python3 + PyTorch（仓库要求版本，CPU 版本）
- `riscv64-linux-gnu-gcc` / `riscv64-linux-gnu-g++`
- jq

## 文件结构

```
F004-cross-compile/
├── README.md              本文件
├── REPORT.md              验证报告
├── environment/
│   ├── aliyun.txt         x86 host 环境
│   └── bianbu.txt         RISC-V 开发板只读环境
├── toolchains/
│   └── riscv64-linux-gnu.cmake
├── scripts/
│   ├── apply_instrumentation.sh
│   ├── run_matrix.sh
│   └── extract_evidence.sh
├── instrumentation/
│   └── f004-log-only.patch
└── results/
    └── <UTC timestamp>/
        ├── T0-scalar/      标量控制组
        ├── T1-vlen128/      核心可疑场景
        ├── T2-vlen128-bf16/ BF16 override 正向控制组
        └── T3-bf16-no-vlen/ BF16 无 VLEN
```

## 运行步骤

```bash
# 1. 进入仓库根目录
cd /path/to/vllm

# 2. 应用 instrumentation（只加日志，不改逻辑）
bash .riscv-audit/validation/F004-cross-compile/scripts/apply_instrumentation.sh

# 3. 运行测试矩阵
bash .riscv-audit/validation/F004-cross-compile/scripts/run_matrix.sh

# 4. 提取证据
bash .riscv-audit/validation/F004-cross-compile/scripts/extract_evidence.sh

# 5. 恢复正式文件
git restore cmake/cpu_extension.cmake
```

## 如何读取 T1/T2 的 -march

```bash
# 查看提取的 -march 值
cat results/<timestamp>/T1-vlen128/march-values.txt
cat results/<timestamp>/T2-vlen128-bf16/march-values.txt

# 或从 compile_commands.json 直接提取
jq -r '.[].command' results/<timestamp>/T1-vlen128/compile_commands.json \
  | grep -o -- '-march=[^ "]*' | sort -u
```

## 如何判断 blocked 与 not-reproduced

- **blocked**：配置未到达 `cpu_extension.cmake` 的 RISC-V 分支（如 PyTorch 缺失、toolchain 不工作）。检查 configure.log 中是否出现 `[F004]` 消息。
- **not-reproduced**：配置到达 RISC-V 分支，但 T1 的 `-march` 不是 `rv64gc`（如上层变量或 toolchain 覆盖了结果）。
- **confirmed**：T1 生成 `-march=rv64gc`，T2 生成 RVV `-march`，且所有 `[F004]` 变量值符合预期。
