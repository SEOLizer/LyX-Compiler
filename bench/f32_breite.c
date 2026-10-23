/* bench/f32_breite.c — lohnt sich 256 Bit gegenueber 128 Bit? (#2205)
 *
 * Dieselbe Schleife, zweimal uebersetzt: einmal auf SSE2 beschraenkt
 * (-msse2 -mno-avx), einmal mit AVX2 (-mavx2 -mno-avx512f). Gemessen wird
 * also NICHT, ob gcc schneller ist als lyxc, sondern ob die breiteren
 * Vektoren bei dieser Rechnung ueberhaupt etwas einbringen — und bei
 * welcher Groesse. Das ist die Frage, die #2205 vor dem Emittieren stellt.
 *
 * Aufruf: f32_breite <elemente> <runden> <op: 0=add 1=sub 2=mul 3=div>
 *
 * Drei Arrays je 4 Byte je Element, also 12 Byte Arbeitsmenge je Element.
 * Auf dem Messgeraet (i5-8250U: L1d 32 KiB, L2 256 KiB, L3 6 MiB) liegen
 * 2048 Elemente im L1, 16384 im L2 und 4194304 weit ueber dem L3.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void lauf(float *c, const float *a, const float *b, long n, int op) {
  switch (op) {
    case 0: for (long i = 0; i < n; i++) c[i] = a[i] + b[i]; break;
    case 1: for (long i = 0; i < n; i++) c[i] = a[i] - b[i]; break;
    case 2: for (long i = 0; i < n; i++) c[i] = a[i] * b[i]; break;
    default: for (long i = 0; i < n; i++) c[i] = a[i] / b[i]; break;
  }
}

int main(int argc, char **argv) {
  long n      = argc > 1 ? atol(argv[1]) : 2048;
  long runden = argc > 2 ? atol(argv[2]) : 10000;
  int  op     = argc > 3 ? atoi(argv[3]) : 0;

  float *a = aligned_alloc(64, (size_t)n * 4);
  float *b = aligned_alloc(64, (size_t)n * 4);
  float *c = aligned_alloc(64, (size_t)n * 4);
  if (!a || !b || !c) { fprintf(stderr, "alloc\n"); return 1; }

  for (long i = 0; i < n; i++) { a[i] = (float)(i % 997) + 1.0f; b[i] = (float)(i % 31) + 1.0f; }

  /* Die Pruefsumme haengt an c und wird AUSGEGEBEN: ohne sie darf der
   * Uebersetzer die ganze Schleife wegwerfen, und gemessen waere nichts. */
  double summe = 0.0;
  for (long r = 0; r < runden; r++) {
    lauf(c, a, b, n, op);
    summe += c[r % n];
  }
  printf("%.4f\n", summe);
  return 0;
}
