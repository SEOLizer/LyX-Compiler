/* bench/arr_add_f32.c — Gegenstelle zu arr_add_f32.lyx (#2195).
 *
 * Dieselbe Rechnung: zwei f32-Felder elementweise addieren, das Ergebnis in
 * ein drittes, und je Wiederholung ein Element in die Pruefsumme. Die
 * Pruefsumme muss mit der Lyx-Fassung uebereinstimmen.
 *
 * Das Zielfeld wird HIER EINMAL angelegt, waehrend die Lyx-Fassung je
 * Wiederholung ein neues anlegt (`a + b` auf `parallel Array<f32>` liefert
 * eine frische Ablage). Das ist ein echter Unterschied im Verhalten, kein
 * Messfehler: er gehoert ins Protokoll, denn er erklaert einen Teil der
 * Differenz. Wer die reine Rechenleistung vergleichen will, misst die
 * C-Fassung zusaetzlich mit malloc je Wiederholung.
 */
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    long long n = 4096, wdh = 1000;
    if (argc > 1) { long long v = atoll(argv[1]); if (v > 0) n = v; }
    if (argc > 2) { long long v = atoll(argv[2]); if (v > 0) wdh = v; }

    float *a = malloc((size_t)n * sizeof(float));
    float *b = malloc((size_t)n * sizeof(float));
    float *c = malloc((size_t)n * sizeof(float));
    if (!a || !b || !c) { fprintf(stderr, "malloc\n"); return 1; }

    for (long long i = 0; i < n; i++) {
        a[i] = (float)(i % 1000);
        b[i] = (float)((i * 7) % 1000);
    }

    long long summe = 0;
    for (long long r = 0; r < wdh; r++) {
        for (long long i = 0; i < n; i++) c[i] = a[i] + b[i];
        summe += (long long)c[r % n];
    }

    printf("checksum=%lld\n", summe);
    free(a); free(b); free(c);
    return 0;
}
