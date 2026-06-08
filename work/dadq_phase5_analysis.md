# DADQ Phase 5 — Performance und Skalierbarkeit

**Datum:** 2026-06-08  
**Branch:** feat/dadq-pqc  
**Vorgaenger:** work/dadq_phase4_analysis.md  
**Testdatei:** tests/dadq_phase5.lyx

---

## Ueberblick

Phase 5 misst die tatsaechliche Laufzeit und den Speicherbedarf von DADQ-FO auf
Produktivparametern und vergleicht die Ergebnisse mit dem NIST PQC Standard ML-KEM-768.
Alle Messwerte basieren auf `GetTimeMs()` (CLOCK_MONOTONIC, ms-Genauigkeit).

---

## AP-5.1 — Benchmark auf Produktivparametern

### Messaufbau

| Parameter   | Wert    | Begruendung                              |
|-------------|---------|------------------------------------------|
| N_keygen    | 200     | 200 × ~8ms = ~1600ms → ms-Aufloesung OK  |
| N_encdec    | 500     | 500 × ~8ms = ~4000ms → ms-Aufloesung OK  |
| N_scale     | 100     | 100 × ~9ms = ~900ms fuer Skalierungstest |
| MSG_LEN     | 32B     | 256-Bit Nachricht (NIST Referenzwert)    |
| Plattform   | x86_64  | Linux, CLOCK_MONOTONIC                   |

### AP-5.1.1–5.1.4: Laufzeitergebnisse

| Operation       | Avg (ms/Op) | Zielwert (ms) | Status |
|-----------------|-------------|---------------|--------|
| dadqFOKeyGen    | 7.740       | 100.000       | **OK** |
| dadqSymKeyGen   | 7.670       | 100.000       | **OK** |
| dadqFOEnc (32B) | 7.402       | 100.000       | **OK** |
| dadqFODec (32B) | 6.392       | 100.000       | **OK** |

Alle Werte liegen weit unter dem konservativen Akzeptanzkriterium von 100 ms/Op
(10× ML-KEM Grenzwert aus `work/dadq.md`).

### AP-5.1.5: Skalierungstest

| Operation        | Avg (ms/Op) | Zielwert (ms) | Status |
|------------------|-------------|---------------|--------|
| dadqFOEnc (256B) | 8.680       | 200.000       | **OK** |

Der Unterschied 32B vs. 256B betraegt nur +1.28 ms (+17%) — die Laufzeit skaliert
fast linear mit der Nachrichtenlaenge. Dominanter Kostentreiber ist die T_pub-Generierung
(O(n^2) = 65536 Lookups), nicht die eigentliche Verschluesselung.

### Laufzeit-Analyse

Der dominante Bottleneck in allen Operationen ist `dadqKeyGen`:

1. **T_pub-Generierung:** `sigma o T_priv o sigma_inv` ueber 256×256 Felder = 65536 Tabellenoperationen.
2. **SHA256-Aufrufe:** Mehrfach pro KeyGen (Ableitungskette seed_σ, seed_T, seed_mac, seed_fo).
3. **HMAC-SHA256 in FOEnc:** Zwei SHA256-Aufrufe pro Verschluesselung.

FODec ist schneller als FOEnc (~6.4 ms vs. ~7.4 ms), da im FODec-Pfad nach
FO-Prueflfehlschlag fruehzeitig abgebrochen werden kann (hier: kein Fehler, voller Pfad).

### Vergleich mit ML-KEM-768

| Metrik          | DADQ-FO | ML-KEM-768 | Faktor   |
|-----------------|---------|------------|----------|
| KeyGen (ms/Op)  | 7.74    | ~0.10      | ~77×     |
| Enc (ms/Op)     | 7.40    | ~0.15      | ~49×     |
| Dec (ms/Op)     | 6.39    | ~0.15      | ~43×     |

DADQ-FO ist ~50-80× langsamer als ML-KEM-768. Das ist fuer Einzel-Operationen
akzeptabel (< 100 ms Zielwert), aber fuer hochvolumige Applikationen relevant.

**Wurzel der Langsamkeit:** ML-KEM nutzt NTT (Number Theoretic Transform) mit
O(n log n) fuer Ring-Polynomial-Multiplikation. DADQ nutzt Latin-Square-Tabellenoperationen
mit O(n^2) fuer T_pub-Generierung. Optimierungspotenzial: T_pub cachen (einmalige
Generierung pro SK), dann nur noch DRBG + Lookups (~< 0.5 ms/Op geschaetzt).

---

## AP-5.2 — Speicherprofil und Schluesselgroessen

### AP-5.2.1: Schluesselgroessen

| Komponente   | Groesse    | Beschreibung                                     |
|--------------|------------|--------------------------------------------------|
| sk_fo        | 608 Bytes  | DADQ-FO Gesamtschluessel (sk + key_fo)           |
| sk_sym       | 576 Bytes  | DADQ-SYM Schluessel (σ + σ⁻¹ + seed_T + key_mac)|
| pk_pke       | 65536 B    | = 64 KB, T_pub (DADQ-PKE, strukturell gebrochen) |
| T_pub (RAM)  | 65536 B    | = 64 KB, ephemeral waehrend Enc/Dec              |
| CT-Overhead  | 64 Bytes   | commit (32B) + hash_mr (32B)                     |

**Akzeptanzkriterium:** pk_pke = 64 KB < 100 KB ✓

Fuer DADQ-SYM/FO ist `pk_size = 0` (T_pub wird nie veroeffentlicht, nur intern
als ephemerer Puffer genutzt). Das ist ein entscheidender Vorteil gegenueber
asymmetrischen Schemata.

### AP-5.2.2: Expansionsfaktor

`CT-Groesse = m_len + 64 Bytes` (fixer Overhead, unabhaengig von m_len).

| m_len  | CT-Groesse | Expansion |
|--------|------------|-----------|
| 16 B   | 80 B       | 5.00×     |
| 256 B  | 320 B      | 1.25×     |
| 1024 B | 1088 B     | 1.06×     |
| ∞      | ∞ + 64     | → 1.00×   |

Fuer grosse Nachrichten (> 1 KB) ist DADQ-FO praktisch overhead-frei.
Fuer kurze Nachrichten (< 64 B) dominiert der fixe 64-Byte-Overhead.

### AP-5.2.3: Kompaktdarstellung

T_pub (64 KB) kann durch `(sigma: 256B + seed_T_priv: 32B) = 288 Bytes`
beschrieben werden — eine **227×-Kompression**. Fuer DADQ-SYM/FO ist dies
irrelevant (T_pub ist stets ephemeral und wird nie uebertragen). Fuer ein
hypothetisches DADQ-PKE waere dies ein kompakter 288-Byte-Public-Key,
aber der strukturelle col_inv-Angriff (Phase 2) macht DADQ-PKE trotzdem unsicher.

### AP-5.2.4: Vergleich DADQ-FO vs. ML-KEM-768

```
+-----------------+----------+------------+
| Parameter       | DADQ-FO  | ML-KEM-768 |
+-----------------+----------+------------+
| pk-Groesse      | 0 Bytes  | 1184 Bytes |
| sk-Groesse      | 608 B    | 2400 Bytes |
| CT (32B msg)    | 96 B     | 1088 Bytes |
| Sicherheit      | IND-CCA2 | IND-CCA2   |
| Quantum-Sicher. | 128-bit  | 128-bit    |
| Asymmetrisch?   | Nein     | Ja         |
+-----------------+----------+------------+
```

**Fazit:** DADQ-FO hat kleinere Keys und kleinere Ciphertexte als ML-KEM-768,
aber ist **symmetrisch** — kein Schluesselaustausch ohne sicheren OOB-Kanal.
Fuer den Anwendungsfall "Symmetric Authenticated Encryption" (z.B. Datei-Verschluesselung
nach Key-Agreement) ist DADQ-FO kompakt und effizient.

**Hybrid-Modus:** `ML-KEM-768 (Key-Agreement) + DADQ-SYM (Payload-Encryption)`
ergibt ein hybrides PQC-Schema mit ML-KEM-pk (1184 B) + DADQ-sk (576 B) + CT-Overhead (64 B).

---

## Zusammenfassung Phase 5

| Arbeitspaket | Ergebnis | Status |
|---|---|---|
| AP-5.1.1 FOKeyGen Benchmark | 7.740 ms << 100 ms | **OK** |
| AP-5.1.2 SymKeyGen Benchmark | 7.670 ms << 100 ms | **OK** |
| AP-5.1.3 FOEnc Benchmark (32B) | 7.402 ms << 100 ms | **OK** |
| AP-5.1.4 FODec Benchmark (32B) | 6.392 ms << 100 ms | **OK** |
| AP-5.1.5 Skalierungstest (256B) | 8.680 ms << 200 ms | **OK** |
| AP-5.2.1 Schluesselgroessen | 608 B sk, 64 KB T_pub (ephemeral) | **OK** |
| AP-5.2.2 Expansionsfaktor | 1.06x bei 1KB, lim 1.0x | **OK** |
| AP-5.2.3 Kompaktdarstellung | 288B kompakter SK-Repr. (irrelevant fuer SYM) | **OK** |
| AP-5.2.4 NIST-Vergleich | kleiner sk/CT, langsamer (50-80x), symmetrisch | **OK** |

### Optimierungspotenzial (fuer Phase 6)

1. **T_pub-Caching:** Einmalige Generierung pro Session spart ~7 ms/Op → ~< 1 ms/Enc
2. **DRBG-Vektorisierung:** SHA256-basierter DRBG koennte via AVX2 beschleunigt werden
3. **Constant-Time HMAC:** Explizite Constant-Time-Garantien fuer side-channel-resistente Implementierung
4. **Stack-basierte Allokation:** Kleine Puffer (ipad/opad in HMAC) koennen stack-alloziert werden

---

## Vorbedingungen fuer Phase 6

Phase 5 ist abgeschlossen. Phase 6 (Implementierungs-Haertung) kann beginnen:

- T_pub-Caching-Optimierung (Laufzeit-Hauptbottleneck)
- Constant-Time-Verifikation (Seitenkanal-Analyse)
- Robustheitspruefung (Input-Validierung, Fehlerbehandlung)
- Formale Schnittstellendokumentation (API-Spec)
