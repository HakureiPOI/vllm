#include <stddef.h>
#include <riscv_vector.h>

vfloat16m1_t probe_fp16_m1(vfloat32m2_t source, size_t vl) {
    return __riscv_vfncvt_f_f_w_f16m1(source, vl);
}

vfloat16m2_t probe_fp16_m2(vfloat32m4_t source, size_t vl) {
    return __riscv_vfncvt_f_f_w_f16m2(source, vl);
}
