/* bench/chacha_qr.c — Gegenstelle zu chacha_qr.lyx (#2195).
 *
 * Bewusst dieselbe Form: 64-Bit-Rechnung mit Maske auf 32 Bit und die
 * Rotation als Schieben/Verodern/Maskieren. So vergleicht die Messung zwei
 * Uebersetzungen DESSELBEN Programms und nicht zwei verschiedene Programme.
 *
 * Eine idiomatische C-Fassung wuerde uint32_t nehmen und die Maskierung dem
 * Typ ueberlassen; das ist schneller und maesse etwas anderes. Sie steht
 * seit #2322 als bench/chacha_qr_u32.c daneben und laeuft im Protokoll als
 * EIGENE Zeile ("gcc -O2 idiomatisch") mit.
 *
 * WICHTIG, gemessen am 2026-11-05 (gcc 15.2.0, i5-8250U): gcc zieht diese
 * gespiegelte Form NICHT zu `rol` zusammen — im Erzeugnis stehen shl/shr/or/
 * and, waehrend die uint32_t-Fassung vier `rol r32` bekommt. Die Zahl dieser
 * Datei ist deshalb kein Vergleich gegen "was C kann", sondern gegen "C in
 * unserer Schreibweise", und gemessen rund doppelt so langsam: 8,3 ns gegen
 * 4,1 ns je Viertelrunde. Wer aus dieser Zeile einen Gleichstand mit gcc
 * liest, liest sie falsch.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define M32 4294967295LL

static long long rotl32(long long x, int n) {
    long long l = (x << n) & M32;
    long long r = (x & M32) >> (32 - n);
    return (l | r) & M32;
}

int main(int argc, char **argv) {
    long long runden = 1000000;
    if (argc > 1) {
        long long v = atoll(argv[1]);
        if (v > 0) runden = v;
    }

    long long a = 285400596;
    long long b = 16843009;
    long long c = 2609191515LL;
    long long d = 20016;

    long long summe = 0;
    for (long long i = 0; i < runden; i++) {
        a = (a + b) & M32;  d = d ^ a;  d = rotl32(d, 16);
        c = (c + d) & M32;  b = b ^ c;  b = rotl32(b, 12);
        a = (a + b) & M32;  d = d ^ a;  d = rotl32(d, 8);
        c = (c + d) & M32;  b = b ^ c;  b = rotl32(b, 7);
        summe = (summe + a + b + c + d) & M32;
    }

    printf("checksum=%lld\n", summe);
    return 0;
}
