#include <stddef.h>
#include <riscv_vector.h>

vfloat16m1_t probe_fp16_m1_rm(vfloat32m2_t source, size_t vl) {
    return __riscv_vfncvt_f_f_w_f16m1_rm(source, __RISCV_FRM_RNE, vl);
}

vfloat16m2_t probe_fp16_m2_rm(vfloat32m4_t source, size_t vl) {
    return __riscv_vfncvt_f_f_w_f16m2_rm(source, __RISCV_FRM_RNE, vl);
}
