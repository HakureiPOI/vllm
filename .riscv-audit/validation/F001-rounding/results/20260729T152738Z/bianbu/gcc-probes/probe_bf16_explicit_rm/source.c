#include <stddef.h>
#include <riscv_vector.h>

vbfloat16m1_t probe_bf16_m1_rm(vfloat32m2_t source, size_t vl) {
    return __riscv_vfncvtbf16_f_f_w_bf16m1_rm(source, __RISCV_FRM_RNE, vl);
}

vbfloat16m2_t probe_bf16_m2_rm(vfloat32m4_t source, size_t vl) {
    return __riscv_vfncvtbf16_f_f_w_bf16m2_rm(source, __RISCV_FRM_RNE, vl);
}
