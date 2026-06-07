# DADQ — Formale Design-Entscheidungen (F-1 bis F-5)

**Datum:** 2026-06-07  
**Status:** Festgelegt — Basis für alle weiteren Arbeitspakete

---

## F-1 — Algebraische Struktur der Quasigruppe

**Entscheidung:** Die Quasigruppe Q operiert über **ℤ_{256}** (Bytes).

Konkret: Q = (M, ⊛) mit M = {0, …, 255}, wobei ⊛ durch eine pseudo-zufällig
generierte 256×256 Latin-Square-Tabelle T definiert wird:

```
a ⊛ b := T[a][b]       (a, b, T[a][b] ∈ {0,…,255})
```

**Begründung gegen GF(2⁸):** GF(2⁸) erzeugt Operationen, die als Polynome
niedrigen Grades über GF(2) darstellbar sind (maximal Grad 7 für Multiplikation).
Gröbner-Basis-Angriffe (MQQ-Angriff, Ding et al.) exploitieren genau das.
Eine zufällige Latin-Square-Tabelle hat im allgemeinen Fall Polynomgrad 255
über GF(2⁸) — exponentiell höher.

**Begründung gegen ℤ_{2^k} mit k>8:** Speichereffizient: eine 256×256 Byte-Tabelle
= 64 KB pro Quasigruppe. Für n=16 Bytes (128-bit Block) werden 16 unabhängige
Tabellen mit Mischungsschicht verwendet (→ AP-0.1).

**Sicherheitsstufen:**
| Stufe | Blockgröße n | Quasigruppen | Gesamtzustand |
|-------|-------------|-------------|--------------|
| 128 bit | 16 Bytes | 16 × 64 KB | 1 MB |
| 192 bit | 24 Bytes | 24 × 64 KB | 1.5 MB |
| 256 bit | 32 Bytes | 32 × 64 KB | 2 MB |

*Kompaktdarstellung (→ AP-5.2):* Tabellen werden nicht direkt übertragen, sondern
aus einem 256-bit Seed via ChaCha20-DRBG generiert. pk = seed (32 Bytes) + φ-Bild.

---

## F-2 — Bedeutung von "Dimension n"

**Entscheidung:** "Dimension n" ist die **Blockgröße in Bytes**.

Ein Block M_block ∈ {0,…,255}^n ist ein Vektor von n Bytes. Die Quasigruppen-
Operation wird blockweise angewendet:

```
Block_a ⊛_n Block_b := (a₀⊛b₀, mix(a₁⊛b₁, a₀⊛b₀), …)
```

Die Mischungsschicht verhindert komponentenweise Angriffe (jedes Ausgangsbyte
hängt von allen Eingangsbytes ab — Diffusion). Konkret: nach der komponenten-
weisen QG-Operation folgt eine lineare Mischung analog zur MixColumns-Stufe in AES,
definiert über GF(2⁸) mit dem AES-irreduziblen Polynom.

**Dimensionsfolge D = (n₁, n₂, …, n_t):** Für t Blöcke einer Nachricht kann n
pro Block variieren. Für n_i ∈ {16, 24, 32} wählt DimCtrl aus den drei
definierten Parametersätzen (→ F-4, AP-0.3).

---

## F-3 — Konstruktion des Isomorphismus φ

**Entscheidung:** φ ist ein **geheimnisabhängiger Byte-Permutations-Isomorphismus**.

```
φ    : Q_pub → Q_priv
φ(a) := σ[a]                    wobei σ ∈ Sym(256) eine geheime Permutation

Q_priv = φ-konjugiert von Q_pub:
Q_priv(a, b) := φ(Q_pub(φ⁻¹(a), φ⁻¹(b)))
              = σ[T_pub[σ⁻¹[a]][σ⁻¹[b]]]
```

**Q_priv-Struktur:** σ wird so gewählt, dass Q_priv eine Blockdiagonalstruktur hat:
Q_priv = L₁ ⊕ L₂ ⊕ … ⊕ Lₖ, wobei Lᵢ lineare Funktionen über GF(2⁴) sind
(4-Bit Nibble-Gruppen). Das erlaubt effiziente Entschlüsselung.

**KeyGen:**
```
KeyGen(seed):
  σ     ← ChaCha20(seed || 0x01)  als Fisher-Yates-Shuffle über {0,…,255}
  T_pub ← build_pub_table(σ, seed)  // so dass Q_priv = σ∘T_pub∘σ⁻¹ Blockdiag hat
  pk := (seed_pub, T_pub_compressed)
  sk := (σ, σ⁻¹)
```

**Härteannahme (Vorversion):** Aus T_pub (256×256 Tabelle) auf σ schließen
ist das Quasigruppen-Isomorphismus-Problem (QIP). QIP ist für generische Latin
Squares coGRAPH-schwer (Booth, Colbourn 1979). DADQ-Annahme: auch für die
eingeschränkte Klasse "σ-konjugierte Latin Squares" ist QIP schwer.

---

## F-4 — Sichtbarkeit der Dimensionsfolge D

**Entscheidung:** D ist **privat** — Teil des geheimen Schlüssels.

**Begründung:** Wäre D öffentlich, könnte ein Angreifer jeden Block separat
angreifen. Da n_i ∈ {16, 24, 32} nur 3 Möglichkeiten hat, würde die Sicherheit
auf das schwächste Block-Format reduziert. Mit privatem D muss ein Angreifer
alle Blockformate simultan berücksichtigen.

**DimCtrl:**
```
DimCtrl(seed_d, num_blocks):
  stream ← ChaCha20(seed_d || 0x02)
  for i in 0..num_blocks:
    byte ← stream[i] & 0x03
    D[i] := if byte == 0 then 16
             elif byte == 1 then 24
             else 32
```

**seed_d** ist Teil von sk und wird nicht aus pk ableitbar (→ AP-0.3).

---

## F-5 — PKE oder KEM

**Entscheidung:** DADQ ist primär **PKE** (Public-Key Encryption).

Daraus wird KEM per Fujisaki-Okamoto-Transform (FO) abgeleitet (→ AP-4.3).

**PKE-Schema:**
```
Enc(pk, m):
  r ← random_bytes(32)           // Ephemeral-Randomness
  c₁ := QG_encrypt(pk, m ⊕ H(r))  // Quasigruppen-Verschlüsselung
  c₂ := r ⊕ H2(QG_encrypt(pk, m)) // Randomness-Commitment
  return (c₁, c₂)

Dec(sk, c₁, c₂):
  m' := QG_decrypt(sk, c₁)
  r'  := c₂ ⊕ H2(c₁)
  if QG_encrypt(pk, m' ⊕ H(r')) != c₁: return ⊥
  return m' ⊕ H(r')
```

H, H2 sind SHA3-256 Instanzen (→ std/crypto/keccak.lyx).

**KEM (via FO):**
```
Encaps(pk):
  m ← random_bytes(32)
  (c₁, c₂) := Enc(pk, m)
  K := H3(m || c₁ || c₂)
  return (K, (c₁, c₂))

Decaps(sk, c):
  m := Dec(sk, c)
  if m == ⊥: return H3(z || c)   // z = rejection randomness aus sk
  return H3(m || c)
```

---

## Zusammenfassung der Entscheidungen

| # | Entscheidung |
|---|---|
| F-1 | Q über ℤ_{256}: zufällige Latin-Square-Tabelle (kein GF) |
| F-2 | n = Blockgröße in Bytes; D = Folge aus {16, 24, 32} |
| F-3 | φ = geheime Byte-Permutation σ; Q_priv = σ∘Q_pub∘σ⁻¹ mit Blockdiag-Struktur |
| F-4 | D ist privat (Teil von sk, per ChaCha20 aus seed_d) |
| F-5 | PKE primär; KEM via FO-Transform |

Diese Entscheidungen sind die Eingabe für AP-0.1 bis AP-0.4.
