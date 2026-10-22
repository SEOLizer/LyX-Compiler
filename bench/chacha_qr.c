/* bench/chacha_qr.c — Gegenstelle zu chacha_qr.lyx (#2195).
 *
 * Bewusst dieselbe Form: 64-Bit-Rechnung mit Maske auf 32 Bit und die
 * Rotation als Schieben/Verodern/Maskieren. So vergleicht die Messung zwei
 * Uebersetzungen DESSELBEN Programms und nicht zwei verschiedene Programme.
 *
 * Eine idiomatische C-Fassung wuerde uint32_t nehmen und die Maskierung dem
 * Typ ueberlassen; das waere schneller und maesse etwas anderes. Wer die
 * Zahlen gegen "was C kann" halten will, uebersetzt zusaetzlich die
 * uint32_t-Form — dann aber als eigene Zeile im Protokoll, nicht als dieselbe.
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
