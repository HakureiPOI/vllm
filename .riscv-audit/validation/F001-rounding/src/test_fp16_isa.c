#pragma STDC FENV_ACCESS ON

#include <fenv.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
    FRM_RNE = 0,
    FRM_RTZ = 1,
    FRM_RDN = 2,
    FRM_RUP = 3,
};

struct rounding_mode {
    int fe_mode;
    const char *name;
    uint32_t frm;
};

struct test_value {
    float value;
    uint32_t bits;
    const char *name;
    uint16_t expected[4];
};

static const struct rounding_mode modes[] = {
    {FE_TONEAREST, "RNE", FRM_RNE},
    {FE_TOWARDZERO, "RTZ", FRM_RTZ},
    {FE_DOWNWARD, "RDN", FRM_RDN},
    {FE_UPWARD, "RUP", FRM_RUP},
};

static const struct test_value tests[] = {
    {1.00048828125f, 0x3f801000, "positive midpoint",
     {0x3c00, 0x3c00, 0x3c00, 0x3c01}},
    {-1.00048828125f, 0xbf801000, "negative midpoint",
     {0xbc00, 0xbc00, 0xbc01, 0xbc00}},
    {1.000732421875f, 0x3f801800, "above positive midpoint",
     {0x3c01, 0x3c00, 0x3c00, 0x3c01}},
    {1.000244140625f, 0x3f800800, "below positive midpoint",
     {0x3c00, 0x3c00, 0x3c00, 0x3c01}},
    {0.00006103515625f, 0x38800000, "exact FP16 minimum normal",
     {0x0400, 0x0400, 0x0400, 0x0400}},
    {65504.0f, 0x477fe000, "FP16 maximum finite",
     {0x7bff, 0x7bff, 0x7bff, 0x7bff}},
    {65520.0f, 0x477ff000, "FP16 overflow threshold",
     {0x7c00, 0x7bff, 0x7bff, 0x7c00}},
    {0.0f, 0x00000000, "positive zero",
     {0x0000, 0x0000, 0x0000, 0x0000}},
    {-0.0f, 0x80000000, "negative zero",
     {0x8000, 0x8000, 0x8000, 0x8000}},
};

__attribute__((noinline))
uint16_t convert_fp16_ambient_isa(float value) {
    uint16_t result;
    __asm__ __volatile__(
        "li t0, 1\n\t"
        "vsetvli t0, t0, e32, m1, ta, ma\n\t"
        "vfmv.s.f v1, %1\n\t"
        "vsetvli t0, t0, e16, mf2, ta, ma\n\t"
        "vfncvt.f.f.w v2, v1\n\t"
        "vmv.x.s %0, v2\n\t"
        : "=r"(result)
        : "f"(value)
        : "t0", "v1", "v2");
    return result;
}

__attribute__((noinline))
uint16_t convert_fp16_manual_rne_isa(float value) {
    uint16_t result;
    __asm__ __volatile__(
        "li t0, 1\n\t"
        "vsetvli t0, t0, e32, m1, ta, ma\n\t"
        "vfmv.s.f v1, %1\n\t"
        "vsetvli t0, t0, e16, mf2, ta, ma\n\t"
        "frrm t1\n\t"
        "fsrmi 0\n\t"
        "vfncvt.f.f.w v2, v1\n\t"
        "fsrm t1\n\t"
        "vmv.x.s %0, v2\n\t"
        : "=r"(result)
        : "f"(value)
        : "t0", "t1", "v1", "v2");
    return result;
}

__attribute__((noinline))
uint32_t read_frm(void) {
    uint32_t value;
    __asm__ __volatile__("frrm %0" : "=r"(value));
    return value;
}

__attribute__((noinline))
void write_frm(uint32_t value) {
    __asm__ __volatile__("fsrm %0" : : "r"(value));
}

__attribute__((noinline))
uint32_t read_fflags(void) {
    uint32_t value;
    __asm__ __volatile__("frflags %0" : "=r"(value));
    return value;
}

__attribute__((noinline))
void write_fflags(uint32_t value) {
    __asm__ __volatile__("fsflags %0" : : "r"(value));
}

static int restore_state(int initial_round, uint32_t initial_frm,
                         uint32_t initial_fflags) {
    int failed = 0;
    if (fesetround(initial_round) != 0) {
        fprintf(stderr, "ERROR fesetround failed while restoring initial mode\n");
        write_frm(initial_frm);
        failed = 1;
    }
    write_fflags(initial_fflags);
    if (read_frm() != initial_frm || read_fflags() != initial_fflags) {
        fprintf(stderr, "ERROR final floating state restoration mismatch\n");
        failed = 1;
    }
    return failed;
}

static int run_matrix(int initial_round, uint32_t initial_frm,
                      uint32_t initial_fflags) {
    int failures = 0;

    puts("RESULT_COLUMNS requested_mode test_name f32_bits frm_before_ambient "
         "fflags_before_ambient ambient_result fflags_after_ambient "
         "frm_before_manual fflags_before_manual manual_result "
         "fflags_after_manual frm_after_manual frm_after_final_restore "
         "fflags_after_final_restore status");

    for (size_t test_index = 0; test_index < sizeof(tests) / sizeof(tests[0]);
         ++test_index) {
        for (size_t mode_index = 0;
             mode_index < sizeof(modes) / sizeof(modes[0]); ++mode_index) {
            const struct test_value *test = &tests[test_index];
            const struct rounding_mode *mode = &modes[mode_index];
            int row_failed = 0;

            if (fesetround(mode->fe_mode) != 0) {
                fprintf(stderr, "ERROR requested_mode=%s fesetround failed\n",
                        mode->name);
                ++failures;
                if (restore_state(initial_round, initial_frm,
                                  initial_fflags) != 0) {
                    ++failures;
                }
                continue;
            }

            int observed_fe_mode = fegetround();
            uint32_t frm_before_ambient = read_frm();
            write_fflags(0);
            uint32_t fflags_before_ambient = read_fflags();
            uint16_t ambient = convert_fp16_ambient_isa(test->value);
            uint32_t fflags_after_ambient = read_fflags();
            uint32_t frm_before_manual = read_frm();
            write_fflags(0);
            uint32_t fflags_before_manual = read_fflags();
            uint16_t manual = convert_fp16_manual_rne_isa(test->value);
            uint32_t fflags_after_manual = read_fflags();
            uint32_t frm_after_manual = read_frm();

            if (observed_fe_mode != mode->fe_mode ||
                frm_before_ambient != mode->frm ||
                fflags_before_ambient != 0 ||
                frm_before_manual != mode->frm ||
                fflags_before_manual != 0 ||
                frm_after_manual != mode->frm ||
                ambient != test->expected[mode_index] ||
                manual != test->expected[FRM_RNE]) {
                row_failed = 1;
                ++failures;
            }

            if (restore_state(initial_round, initial_frm,
                              initial_fflags) != 0) {
                row_failed = 1;
                ++failures;
            }
            uint32_t frm_after_final_restore = read_frm();
            uint32_t fflags_after_final_restore = read_fflags();

            printf("RESULT requested_mode=%s test_name=\"%s\" "
                   "f32_bits=0x%08x frm_before_ambient=%u "
                   "fflags_before_ambient=0x%02x ambient_result=0x%04x "
                   "fflags_after_ambient=0x%02x frm_before_manual=%u "
                   "fflags_before_manual=0x%02x manual_result=0x%04x "
                   "fflags_after_manual=0x%02x frm_after_manual=%u "
                   "frm_after_final_restore=%u "
                   "fflags_after_final_restore=0x%02x status=%s\n",
                   mode->name, test->name, test->bits, frm_before_ambient,
                   fflags_before_ambient, ambient, fflags_after_ambient,
                   frm_before_manual, fflags_before_manual, manual,
                   fflags_after_manual, frm_after_manual,
                   frm_after_final_restore, fflags_after_final_restore,
                   row_failed ? "FAIL" : "PASS");
        }
    }
    return failures;
}

static int run_stability(int initial_round, uint32_t initial_frm,
                         uint32_t initial_fflags) {
    const struct test_value *midpoint = &tests[0];
    int failures = 0;

    puts("STABILITY_SCOPE single-process 10-iteration stability check "
         "for each optimization-level x rounding-mode x test-path");
    for (size_t mode_index = 0;
         mode_index < sizeof(modes) / sizeof(modes[0]); ++mode_index) {
        const struct rounding_mode *mode = &modes[mode_index];
        for (int iteration = 0; iteration < 10; ++iteration) {
            int row_failed = 0;
            if (fesetround(mode->fe_mode) != 0) {
                fprintf(stderr,
                        "ERROR stability requested_mode=%s fesetround failed\n",
                        mode->name);
                ++failures;
                continue;
            }

            uint32_t frm_before = read_frm();
            write_fflags(0);
            uint32_t fflags_before_ambient = read_fflags();
            uint16_t ambient = convert_fp16_ambient_isa(midpoint->value);
            uint32_t fflags_after_ambient = read_fflags();
            write_fflags(0);
            uint32_t fflags_before_manual = read_fflags();
            uint16_t manual =
                convert_fp16_manual_rne_isa(midpoint->value);
            uint32_t fflags_after_manual = read_fflags();
            uint32_t frm_after = read_frm();

            if (frm_before != mode->frm || frm_after != mode->frm ||
                fflags_before_ambient != 0 ||
                fflags_before_manual != 0 ||
                ambient != midpoint->expected[mode_index] ||
                manual != midpoint->expected[FRM_RNE]) {
                row_failed = 1;
                ++failures;
            }
            if (restore_state(initial_round, initial_frm,
                              initial_fflags) != 0) {
                row_failed = 1;
                ++failures;
            }
            uint32_t fflags_after_final_restore = read_fflags();

            printf("STABILITY requested_mode=%s iteration=%d "
                   "frm_before=%u fflags_before_ambient=0x%02x "
                   "ambient_result=0x%04x fflags_after_ambient=0x%02x "
                   "fflags_before_manual=0x%02x manual_result=0x%04x "
                   "fflags_after_manual=0x%02x frm_after=%u "
                   "fflags_after_final_restore=0x%02x status=%s\n",
                   mode->name, iteration + 1, frm_before,
                   fflags_before_ambient, ambient, fflags_after_ambient,
                   fflags_before_manual, manual, fflags_after_manual,
                   frm_after, fflags_after_final_restore,
                   row_failed ? "FAIL" : "PASS");
        }
    }
    return failures;
}

int main(void) {
    int initial_round = fegetround();
    uint32_t initial_frm = read_frm();
    uint32_t initial_fflags = read_fflags();
    int failures = 0;

    if (initial_round == -1) {
        fputs("ERROR fegetround failed at program start\n", stderr);
        return 2;
    }

    puts("TEST_SCOPE ISA-equivalent FP32-to-FP16 bare ISA instruction");
    puts("AMBIENT_PATH uses current frm");
    puts("MANUAL_PATH saves frm, sets RNE, converts, and restores frm");
    puts("FFLAGS_BOUNDARY manual path does not restore fflags");
    printf("COMPILER %s\n", __VERSION__);
#ifdef __OPTIMIZE__
    puts("OPTIMIZATION optimized");
#else
    puts("OPTIMIZATION unoptimized");
#endif
    printf("INITIAL_STATE fe_round=%d frm=%u fflags=0x%02x\n",
           initial_round, initial_frm, initial_fflags);

    failures += run_matrix(initial_round, initial_frm, initial_fflags);
    failures += run_stability(initial_round, initial_frm, initial_fflags);
    failures += restore_state(initial_round, initial_frm, initial_fflags);

    printf("SUMMARY failures=%d status=%s final_frm=%u final_fflags=0x%02x\n",
           failures, failures == 0 ? "PASS" : "FAIL", read_frm(),
           read_fflags());
    return failures == 0 ? 0 : 1;
}
