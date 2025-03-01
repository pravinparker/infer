/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */
#include <stdlib.h>

int* global_pointer;

void free_global_pointer_impure() { free(global_pointer); }
// If Pulse raises an error, consider the function as impure.
void double_free_global_impure() {
  free_global_pointer_impure();
  free_global_pointer_impure();
}

int free_param_impure(int* x) {
  free(x);
  return 0;
}

struct Simple {
  int f;
};
void delete_param_impure(Simple* s) { delete s; }

void local_deleted_pure() {
  auto* s = new Simple{1};
  delete s;
}

Simple* reassign_impure(Simple* s) {
  s = new Simple{2};
  return s;
}
