#include <foreign_answer.h>

#ifndef PENANCE_C_BIAS
#error "cc-options were not preserved in the Penance lock"
#endif

#ifdef PENANCE_BUILD_INPUT_PROBE
#include <penance_build_input.h>
#else
#define PENANCE_BUILD_INPUT_BIAS 1
#endif

int penance_foreign_answer(void) {
  return 40 + PENANCE_C_BIAS + PENANCE_BUILD_INPUT_BIAS;
}
