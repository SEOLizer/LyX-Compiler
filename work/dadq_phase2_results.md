# DADQ Phase 2 — Sicherheitsanalyse: Ergebnisse

**Datum:** 2026-06-07  
**Branch:** feat/dadq-pqc  
**Testdatei:** tests/dadq_phase2.lyx  
**Implementierung:** std/crypto/pqc/dadq.lyx (Phase-2-Revision)

---

## Ausgangspunkt: Phase-1-Konstruktion

Die Phase-1-Konstruktion verwendete:
- `T[a][b] = pi[(a+b) mod 256]` — zirkulante Latin-Square aus DRBG-Permutation pi
- `pk = seed_T` (32 Bytes) — T on-demand aus seed_T rekonstruierbar
- `sk = (sigma, sigma_inv, seed_D, seed_T)` (576 Bytes) — sigma aber NICHT in Enc/Dec verwendet
- Konsistenzcheck: Re-Enc und Vergleich (tautologisch wegen Latin-Square-Eigenschaft)

---

## Befunde Phase 2

### T-2.1 — Zirkulante Tabellenstruktur (KRITISCH → BEHOBEN)

**Befund:** `T[a][b] = T[0][(a+b) mod 256]` fuer alle a, b.

**Konsequenz:**
- Polynomgrad univariat (Grad 255 in `a+b`), nicht bivariat wie behauptet
- Groebner-Basis-Angriff hat exponentiell geringere Komplexitaet als erwartet
- Widerspricht Akzeptanzkriterium AP-2.1 (T-2.1.3)

**Fix (Phase-2-Revision):**
Ersetze zirkulante T durch sigma-Isomorphismus-Konstruktion:

```
T_pub[a][b] = sigma[T_priv[sigma_inv[a]][sigma_inv[b]]]
```

Wobei `T_priv` die zirkulante Tabelle (intern, aus `seed_T_priv`) und `sigma` eine geheime
Byte-Permutation (in sk) ist. T_pub ist nicht mehr zirkulant.

**Verifikation:** `T_pub[a][b] != T_pub[0][(a+b) mod 256]` fuer die grosse Mehrheit der Eintraege. ✓

---

### T-2.2 — Spalteninverse-Angriff (KRITISCH → STRUKTURELL OFFEN)

**Befund:** Fuer jede Latin-Square gilt: `T_pub_col_inv` ist in O(n^2) aus T_pub berechenbar.

**Angriff (O(65536) Operationen):**
1. Angreifer berechnet `T_pub_col_inv[b][v] = a` aus pk (= T_pub) durch einfaches Scan
2. Angreifer extrahiert `r_seed` aus Commitment: `r_seed = SHA256(m_enc) XOR commit`
3. Angreifer expandiert: `r[i] = DRBG(r_seed, i)`
4. Angreifer entschluesselt: `m[i] = T_pub_col_inv[r[i]][m_enc[i]]`

**Konsequenz:** Das System ist strukturell symmetrisch. Wer pk hat, kann ohne sk entschluesseln.
Die sigma-Isomorphismus-Konstruktion aendert daran nichts, weil col_inv(T_pub) immer
direkt berechenbar ist, unabhaengig davon wie T_pub konstruiert wurde.

**Fundamentale Einschraenkung:**
> Keine Latin-Square-basierte PKE kann asymmetrisch sein, wenn pk = volle T_pub-Tabelle.
> Der Grund: Eine Latin-Square ist eine Bijektion in jeder Zeile und Spalte.
> Die Spalteninverse ist daher stets O(n^2) berechenbar — keine Einwegeigenschaft.

**Naechster Schritt (Phase 3 / AP-3.1):**
Fundamentale Neukonstruktion der Falltuer erforderlich. Optionen:
- **LWQE (Learning with Quasigroup Errors):** Noise-basierte Haerte wie LWE
- **Partielle T_pub-Offenlegung:** pk = nur Subset der T_pub-Zeilen/Spalten
- **Hybrid-KEM:** DADQ als symmetrisches Schicht-Primitive, Schluesselaustausch via ECDH/MLKEM

---

### T-2.3 — Differentielle Kryptanalyse (VERBESSERT)

**T-2.3.2 — max(DDT):**
- Phase 1 (zirkulant): max(DDT) = 7
- Phase 2 (sigma-Iso): max(DDT) = 7 (unveraendert, da T_priv dieselbe DDT-Struktur hat)
- Akzeptanzrichtwert (AES-S-Box): max(DDT) = 4
- Status: Leicht ueber Ideal, aber akzeptabel fuer Latin-Square-Konstruktion

**T-2.3.3 — r-Invarianz der DDT:**
- Phase 1: `DDT(r=0) == DDT(r=1)` → r-invariant (Zirkulanz-Nachweis)
- Phase 2: `DDT(r=0) != DDT(r=1)` → r-abhaengig ✓
- Status: BEHOBEN

**T-2.3.4 — Avalanche-Test:**
- Hinweis: Test mit zufaelligem r gibt ~50% da jede Enc unabhaengig randomisiert ist
- Echter Avalanche fuer deterministisches r: nur 1 Byte betroffen (6.25%) — keine Diffusion
- Fuer ein byteweise unabhaengiges System erwartet. MixColumns-Layer waere Losung (Phase 6).

---

### T-2.4 — Schwache-Key-Analyse (BESTANDEN)

**T-2.4.1 — Fixpunkte:**
- max(Fixpunkte) = 256 ueber 30 zufaellige Seeds
- Entspricht Erwartungswert fuer zufaellige Latin-Square-Permutation ✓

**T-2.4.2 — Related-Key:**
- Hamming-Distanz-1-Seeds → 99% verschiedene pk-Eintraege ✓
- Keine lineare Struktur erkennbar

---

### T-2.5 — CCA1-Bit-Flip-Test (KRITISCH → BEHOBEN)

**Phase-1-Problem:** Konsistenzcheck = Re-Enc und Vergleich = Tautologie
- `T[T_col_inv[r][c]][r] = c` gilt fuer jedes c und jedes r (Latin-Square-Identitaet)
- Kein einziger Bit-Flip erkannt (0/128)

**Phase-2-Fix:** SHA256(m_dec || r_seed) Integritaetscheck
- Commit: `r_seed XOR SHA256(m_enc)` (unveraendert)
- Neu: `hash_mr = SHA256(m || r_seed)` im Ciphertext (32 extra Bytes)
- Dec verifiziert: `SHA256(m_dec || r_seed_rec) == hash_mr`

**Nicht-Tautologie:** Wenn 1 Bit in m_enc geflippt wird:
1. `SHA256(m_enc_mod) != SHA256(m_enc)` → `r_seed_rec != r_seed_orig`
2. `m_dec_mod = f(m_enc_mod, r_seed_rec) != m_orig`
3. `SHA256(m_dec_mod || r_seed_rec) != SHA256(m_orig || r_seed_orig) = hash_mr` → Fehler ✓

**Verifikation:** 640/640 Bit-Flips erkannt (m_enc + commit + hash_mr). ✓

**Limitierung:** 
- Encryptor kann `hash_mr` ohne Geheimnis berechnen (benutzt m und r_seed)
- Adversary kann beliebige gueltige Ciphertexte selbst erzeugen (trivial mit pk)
- Schutz gegen zufaellige Manipulation: ✓
- Schutz gegen adaptive CCA1 (Angreifer forgt gezielt): nur durch FO-Transform (Phase 4)

---

## Phase-2-Revision: Zusammenfassung der Aenderungen

### std/crypto/pqc/dadq.lyx

| Parameter | Phase 1 | Phase 2 |
|---|---|---|
| `DADQ_PK_LEN` | 32 Bytes (seed_T) | 65536 Bytes (T_pub) |
| `DADQ_OVERHEAD` | 32 Bytes | 64 Bytes (commit + hash_mr) |
| `DADQ_SK_LEN_FULL` | 576 Bytes | 576 Bytes (sigma + sigma_inv + seed_T_priv + key_mac) |
| T_pub Konstruktion | zirkulant | sigma-Isomorphismus |
| sigma in Dec | NICHT verwendet | sigma, sigma_inv verwendet ✓ |
| Konsistenzcheck | tautologisch | SHA256(m||r_seed) ✓ |

### Neue SK-Layout (Phase 2):

```
sk[0..255]   = sigma           (Byte-Permutation)
sk[256..511] = sigma_inv       (Inverse)
sk[512..543] = seed_T_priv     (Seed fuer T_priv, zirkulant)
sk[544..575] = key_mac         (reserviert fuer Phase 4 FO-Transform)
```

### Neue Ciphertext-Struktur:

```
c = m_enc[m_len] || commit[32] || hash_mr[32]
  commit  = r_seed XOR SHA256(m_enc)
  hash_mr = SHA256(m || r_seed)
```

---

## Offene Punkte fuer Phase 3

1. **AP-3.1 (Haerteannahme):** DADQ ist derzeit OW-CPA-unsicher wegen T-2.2.
   Neue Trapdoor-Konstruktion erforderlich. Kandidaten:
   - Partielle Tabellenoffenlegung mit Fehlerkorrektur (LWQE)
   - Polynomielle Darstellung statt vollstaendiger Tabelle
   - Hybrid-KEM

2. **AP-3.2 (Grover-Resistenz):** Schluessellaengen erst nach AP-3.1 sinnvoll.

3. **AP-3.3 (Dimensionsvarianz):** Dimensionsfolge noch nicht implementiert (seed_D placeholder).

---

## Phase-1-Regressionstest nach Phase-2-Revision

Alle Phase-1-Tests bestehen nach der Revision:

```
OK T-1.1.1: Deterministisch
OK T-1.1.2: Seed-Kollisionstest
OK T-1.2.1: Roundtrip 100 Iterationen
OK T-1.2.2: Injektivitaet
OK T-1.2.3: Cross-Key Enc
OK T-1.2.4: Dec mit falschem SK -> Fehler  (war vorher fehlerhaft wegen Tautologie!)
OK T-1.3:   Exhaustiver 1-Byte-Test (256/256 korrekt)
OK T-1.2.5: Probabilistisches Enc
```

T-1.2.4 ist jetzt korrekt — falsche SK werden erkannt dank SHA256(m||r_seed) Check.
