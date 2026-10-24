/* bench/arr_int.c — Gegenstelle zu arr_int.lyx (#2195).
 *
 * Aufruf: arr_int <breite 8|16|32> <op 1=add 2=mul 3=sum> <elemente> <wiederholungen>
 *
 * Dieselbe Rechnung auf uint8_t/uint16_t/uint32_t, vorzeichenlos modulo
 * 2^breite. Die Pruefsumme muss mit der Lyx-Fassung uebereinstimmen.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define KERNE(T, NAME)                                                        \
    static void add_##NAME(const T *a, const T *b, T *c, long long n) {       \
        for (long long i = 0; i < n; i++) c[i] = (T)(a[i] + b[i]);            \
    }                                                                         \
    static void mul_##NAME(const T *a, const T *b, T *c, long long n) {       \
        for (long long i = 0; i < n; i++) c[i] = (T)(a[i] * b[i]);            \
    }                                                                         \
    static long long sum_##NAME(const T *a, long long n) {                    \
        long long s = 0;                                                      \
        for (long long i = 0; i < n; i++) s += a[i];                          \
        return s;                                                             \
    }                                                                         \
    static long long lauf_##NAME(int op, long long n, long long wdh) {        \
        T *a = malloc((size_t)n * sizeof(T));                                 \
        T *b = malloc((size_t)n * sizeof(T));                                 \
        T *c = malloc((size_t)n * sizeof(T));                                 \
        if (!a || !b || !c) { fprintf(stderr, "malloc\n"); exit(1); }        \
        for (long long i = 0; i < n; i++) {                                   \
            a[i] = (T)((uint64_t)i * 2654435761u);                            \
            b[i] = (T)((uint64_t)i * 40503u + 12345u);                        \
        }                                                                     \
        long long summe = 0;                                                  \
        for (long long r = 0; r < wdh; r++) {                                 \
            long long k = r % n;                                              \
            a[k] = (T)(a[k] + 1);                                             \
            if (op == 3) { summe += sum_##NAME(a, n); continue; }             \
            if (op == 1) add_##NAME(a, b, c, n); else mul_##NAME(a, b, c, n); \
            summe += c[k];                                                    \
        }                                                                     \
        free(a); free(b); free(c);                                            \
        return summe;                                                         \
    }

KERNE(uint8_t, 8)
KERNE(uint16_t, 16)
KERNE(uint32_t, 32)

int main(int argc, char **argv) {
    int breite = 32, op = 1;
    long long n = 4096, wdh = 1000;
    if (argc > 1) breite = atoi(argv[1]);
    if (argc > 2) op = atoi(argv[2]);
    if (argc > 3) { long long v = atoll(argv[3]); if (v > 0) n = v; }
    if (argc > 4) { long long v = atoll(argv[4]); if (v > 0) wdh = v; }
    if (op < 1 || op > 3) { puts("op muss 1 (add), 2 (mul) oder 3 (sum) sein"); return 2; }
    long long s;
    if (breite == 8) s = lauf_8(op, n, wdh);
    else if (breite == 16) s = lauf_16(op, n, wdh);
    else if (breite == 32) s = lauf_32(op, n, wdh);
    else { puts("breite muss 8, 16 oder 32 sein"); return 2; }
    printf("checksum=%lld\n", s);
    return 0;
}
