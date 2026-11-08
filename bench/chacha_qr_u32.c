/* bench/chacha_qr_u32.c — die IDIOMATISCHE C-Fassung der Viertelrunde (#2322).
 *
 * Gegenstueck zu bench/chacha_qr.c, das bewusst die Form von chacha_qr.lyx
 * nachbaut (64-Bit-Rechnung, Maske auf 32 Bit, Rotation aus Schieben/
 * Verodern/Maskieren). Diese Fassung nimmt uint32_t und ueberlaesst die
 * Maskierung dem Typ -- das, was ein C-Programmierer schreiben wuerde.
 *
 * Warum sie als EIGENE Zeile dazugehoert: gcc zieht die gespiegelte Form
 * NICHT zu `rol` zusammen. Gemessen am 2026-11-05 mit gcc 15.2.0 auf
 * i5-8250U (Erzeugnisse disassembliert):
 *
 *   bench/chacha_qr.c      -O2  -> 0 x rol, stattdessen shl/shr/or/and
 *   bench/chacha_qr_u32.c  -O2  -> 4 x rol r32 (eine je Rotation)
 *
 * Die gespiegelte Fassung ist damit kein Vergleich gegen "was C kann",
 * sondern gegen "C in unserer Schreibweise". Beide Zeilen gehoeren ins
 * Protokoll, sonst sieht unser Erzeugnis besser aus, als es ist (#2322).
 *
 * Die Pruefsumme ist dieselbe wie in beiden anderen Fassungen -- es wird
 * dieselbe Arbeit gerechnet, nur anders geschrieben.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

static inline uint32_t rotl32u(uint32_t x, int n) {
    return (uint32_t)((x << n) | (x >> (32 - n)));
}

int main(int argc, char **argv) {
    long long runden = 1000000;
    if (argc > 1) {
        long long v = atoll(argv[1]);
        if (v > 0) runden = v;
    }

    uint32_t a = 285400596u;      /* 0x11111111 */
    uint32_t b = 16843009u;       /* 0x01020304 */
    uint32_t c = 2609191515u;     /* 0x9b8d6f43 */
    uint32_t d = 20016u;          /* 0x01234567 */

    uint32_t summe = 0;
    for (long long i = 0; i < runden; i++) {
        a += b;  d ^= a;  d = rotl32u(d, 16);
        c += d;  b ^= c;  b = rotl32u(b, 12);
        a += b;  d ^= a;  d = rotl32u(d, 8);
        c += d;  b ^= c;  b = rotl32u(b, 7);
        summe = summe + a + b + c + d;
    }

    printf("checksum=%llu\n", (unsigned long long)summe);
    return 0;
}
