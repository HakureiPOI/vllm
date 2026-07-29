set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR riscv64)

set(CMAKE_C_COMPILER riscv64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER riscv64-linux-gnu-g++)

# 防止配置阶段为了检测工具链而尝试运行目标程序。
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
