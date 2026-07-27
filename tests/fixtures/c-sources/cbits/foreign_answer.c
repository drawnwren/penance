#include <foreign_answer.h>

#ifndef PENANCE_C_BIAS
#error "cc-options were not preserved in the Penance lock"
#endif

int penance_foreign_answer(void) {
  return 41 + PENANCE_C_BIAS;
}
