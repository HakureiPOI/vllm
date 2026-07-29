#include <stddef.h>
#include <riscv_vector.h>

vbfloat16m1_t probe_bf16_m1(vfloat32m2_t source, size_t vl) {
    return __riscv_vfncvtbf16_f_f_w_bf16m1(source, vl);
}

vbfloat16m2_t probe_bf16_m2(vfloat32m4_t source, size_t vl) {
    return __riscv_vfncvtbf16_f_f_w_bf16m2(source, vl);
}
