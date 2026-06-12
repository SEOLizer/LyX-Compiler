# Fahrplan: Post-Quantum-Kryptographie (`std/crypto/pqc/`)

Stand: 2026-05-21

## Warum jetzt?

**Store Now, Decrypt Later (SNDL):** Angreifer speichern heute verschlüsselte Datenströme, die sie in 10–15 Jahren mit Quantencomputern entschlüsseln. Für langlebige Geheimnisse (Staatsgeheimnisse, IP, Gesundheitsdaten) gilt die Bedrohung als *jetzt aktiv*.

**NIST-Standards (2024):** Die drei finalisierten Algorithmen sind:
- **ML-KEM** (FIPS 203, ex-Kyber) – Key Encapsulation, ersetzt RSA/ECDH
- **ML-DSA** (FIPS 204, ex-Dilithium) – Digitale Signaturen, ersetzt RSA-Sign/ECDSA
- **SLH-DSA** (FIPS 205, ex-SPHINCS+) – Hash-basierte Signaturen (konservativste Option)

---

## Architekturprinzip

Alles wird **nativ in Lyx** implementiert – kein `extern link "libpqcrypto"` oder ähnliches.  
OpenSSL bleibt ausschließlich für TLS-Transport (`std/net/tls`). Die PQC-Primitiven sind reine Algorithmen.

```
┌────────────────────────────────────────────────────────────┐
│              Lyx-Anwendungscode                            │
│   PQCKeyGen / PQCEncap / PQCDecap / PQCSign / PQCVerify   │
└────────────────────────┬───────────────────────────────────┘
                         │
        ┌────────────────▼──────────────────┐
        │         High-Level API            │  WP-PQC-10
        │   std/crypto/pqc/pqc.lyx          │
        └───┬──────────┬────────────────────┘
            │          │
   ┌────────▼──┐  ┌────▼────────┐  ┌──────────────┐
   │  ML-KEM   │  │  ML-DSA     │  │  SLH-DSA     │
   │  FIPS 203 │  │  FIPS 204   │  │  FIPS 205    │
   │ WP-PQC-06 │  │ WP-PQC-07  │  │  WP-PQC-08   │
   └─────┬─────┘  └─────┬───────┘  └──────┬───────┘
         │              │                  │
         └──────┬────────┘                 │
                │                          │
   ┌────────────▼───────────┐  ┌──────────▼──────────────┐
   │  NTT / Polynom-Ring    │  │  SHA-256 multi-block     │
   │  Zq[X]/(X²⁵⁶+1)       │  │  WP-PQC-02              │
   │  WP-PQC-05             │  └─────────────────────────┘
   └────────────┬───────────┘
                │
   ┌────────────▼───────────────────────────────────────┐
   │  Keccak-1600 / SHA-3 / SHAKE-128 / SHAKE-256       │
   │  WP-PQC-01  (ersetzt Fake-Stubs in hash.lyx)       │
   └────────────┬───────────────────────────────────────┘
                │
   ┌────────────▼───────────────────────────────────────┐
   │  Constant-Time Utils  WP-PQC-04                    │
   │  ct_select, ct_eq, secure_zero                     │
   └────────────────────────────────────────────────────┘
```

---

## Bestandsaufnahme: Was existiert bereits

| Vorhanden | Zustand | Benötigt für |
|-----------|---------|-------------|
| `std/crypto/aes.lyx` | Vollständig (CBC) | AES-256-CTR für DRBG (WP-PQC-03) |
| `std/crypto/sha1.lyx` | Vollständig | — (SHA-1 reicht für PQC nicht) |
| `std/crypto/sha256.lyx` SHA-256 | ✅ Multi-Block (beliebige Länge) | WP-PQC-02 ✅ |
| `std/hash.lyx` SHA-3/SHAKE | ✅ Echter Keccak-1600 | WP-PQC-01 ✅ |

---

## Work Packages

---

### WP-PQC-01 — Keccak-1600 / SHA-3 / SHAKE (`std/crypto/keccak.lyx`)

**Ziel:** Die echte Keccak-1600-Permutation als natives Lyx-Modul. Ersetzt die Fake-Stubs in `hash.lyx`. Ist Pflicht-Fundament für ML-KEM, ML-DSA und SLH-DSA.

**Datei:** `std/crypto/keccak.lyx`

**Mathematischer Kern – die Keccak-f[1600]-Permutation:**

Der Zustand ist eine 5×5-Matrix aus 64-Bit-Lanes (1600 Bit gesamt). Jede der 24 Runden besteht aus fünf Schritten:

```
θ (Theta):   C[x] = A[x,0] ⊕ A[x,1] ⊕ A[x,2] ⊕ A[x,3] ⊕ A[x,4]
             D[x] = C[x-1] ⊕ ROT(C[x+1], 1)
             A[x,y] ^= D[x]

ρ (Rho):     A[x,y] = ROT(A[x,y], r[x,y])   // feste Rotationskonstanten

π (Pi):      B[y, 2x+3y] = A[x,y]

χ (Chi):     A[x,y] = B[x,y] ⊕ ((~B[x+1,y]) & B[x+2,y])

ι (Iota):    A[0,0] ⊕= RC[round]             // Rundenkonstante
```

**Datenstruktur:**
```lyx
pub type KeccakState = struct {
    lanes: int64;   // Pointer auf 25 × int64 = 200 Bytes (via mmap)
};
```

**Speicher-Layout:** 25 × 8 Bytes = 200 Bytes. Lane `A[x,y]` liegt bei Offset `(x + 5*y) * 8`.

**Funktionen:**
```lyx
pub fn KeccakInit(state: int64): void;
// Setzt alle 25 Lanes auf 0

pub fn KeccakAbsorb(state: int64, data: int64, len: int64, rate: int64, pad: int64): void;
// Absorbiert beliebig lange Daten mit gegebenem Rate (in Bytes) und Padding-Byte
// pad = 0x1F für SHA-3, pad = 0x1F für SHAKE (multi-rate padding)

pub fn KeccakSqueeze(state: int64, out: int64, outLen: int64, rate: int64): void;
// Gibt outLen Bytes Ausgabe aus

// Fertige High-Level-Funktionen (bauen auf Absorb/Squeeze auf):
pub fn SHA3_256(data: int64, len: int64, out: int64): void;   // out = 32 Bytes
pub fn SHA3_512(data: int64, len: int64, out: int64): void;   // out = 64 Bytes
pub fn SHAKE128(data: int64, len: int64, out: int64, outLen: int64): void;
pub fn SHAKE256(data: int64, len: int64, out: int64, outLen: int64): void;
```

**Parameter:**
| Funktion | Rate (Bytes) | Cap (Bytes) | Padding |
|----------|-------------|-------------|---------|
| SHA3-256 | 136 | 64 | 0x06 |
| SHA3-512 | 72 | 128 | 0x06 |
| SHAKE-128 | 168 | 32 | 0x1F |
| SHAKE-256 | 136 | 64 | 0x1F |

**Implementierungsschritte:**
1. Rundenkonstanten RC[0..23] als `con`-Array hartcodieren (bekannte Werte)
2. Rotationskonstanten r[x,y] als 5×5-Tabelle
3. `keccak_f1600`: 24 Runden, jeweils θ→ρ→π→χ→ι
4. `KeccakAbsorb`: XOR data in State (rate Bytes pro Block), dann `keccak_f1600`
5. `KeccakSqueeze`: Lanes aus State lesen, bei Bedarf weiteres `keccak_f1600`
6. Multi-Rate-Padding: letztes Byte vor Rate-Grenze OR-kombinieren mit `pad`

**Testvektor (SHA3-256 von leerem String):**
```
SHA3-256("") = a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a
```

**Akzeptanzkriterium:** Alle NIST-Testvektoren für SHA3-256, SHA3-512, SHAKE-128, SHAKE-256 passieren.

---

### WP-PQC-02 — SHA-256 Multi-Block ✅

**Implementiert in:** `std/crypto/sha256.lyx` (canonical multi-block), `std/hash.lyx` (Streaming-API)

**API:**
```lyx
// std/crypto/sha256.lyx
pub fn SHA256(data: int64, len: int64, out: int64): void;        // beliebige Länge
pub fn SHA256Hex(data: int64, len: int64, out: int64): void;
pub fn HashSHA256Bytes(data: int64, len: int64, out: int64): void; // alias

// std/hash.lyx (Streaming)
pub fn SHA256Init(ctx: int64): void;
pub fn SHA256Update(ctx: int64, data: int64, len: int64): void;
pub fn SHA256Final(ctx: int64, out: int64): void;
```

**Test:** `tests/pqc02_sha256_multiblock_test.lyx` — 7 NIST FIPS 180-4 Vektoren bestanden
(leer, "abc", 56-Byte 2-Block-Padding, 112-Byte 3-Block, inkrementell, HashSHA256Bytes, SHA256Hex)

---

### WP-PQC-03 — AES-256-CTR (`std/crypto/aes.lyx` Erweiterung)

**Ziel:** CTR-Modus als deterministischer Pseudozufallsgenerator (DRBG) für ML-KEM und ML-DSA. In den NIST-Testvektoren der PQC-Algorithmen wird AES-256-CTR-DRBG als Referenz-RNG genutzt.

**Datei:** `std/crypto/aes.lyx`

**Funktionen:**
```lyx
pub fn AES256CTREncrypt(key: pchar, nonce: pchar, counter: int64,
                        input: pchar, input_len: int64, output: pchar): int64;
// Nonce: 12 Bytes, Counter: 4 Bytes big-endian (Standard) oder 8+8

// DRBG-Wrapper:
pub fn AES256CTR_DRBG_Init(key: pchar, nonce: pchar, state: int64): void;
pub fn AES256CTR_DRBG_Generate(state: int64, out: int64, outLen: int64): void;
```

**Implementierung:** Keystream-Blöcke durch `AESEncryptBlockWithKey(counter_block, expanded_key)` erzeugen, Counter inkrementieren, XOR mit Plaintext. Bereits vorhandener Key-Schedule (`AES256KeyExpand`) wird wiederverwendet.

**Akzeptanzkriterium:** NIST ACVP AES-CTR-Testvektoren passen.

---

### WP-PQC-04 — Constant-Time Utilities (`std/crypto/ct.lyx`)

**Ziel:** Timing-Side-Channel-freie Basisfunktionen. Ohne diese könnte ein Angreifer durch Messung der Ausführungszeit Schlüsselbits ableiten (Timing-Angriff). **Muss vor allen PQC-Algorithmen fertig sein.**

**Datei:** `std/crypto/ct.lyx`

**Warum wichtig:** Normale `if`-Verzweigungen in Lyx werden zu bedingten Sprüngen kompiliert, die je nach Daten unterschiedlich lang dauern. PQC braucht *immer gleich lange* laufende Vergleiche.

**Funktionen:**
```lyx
// Wählt a wenn mask=0xFFFFFFFFFFFFFFFF, b wenn mask=0
pub fn CTSelect(a: int64, b: int64, mask: int64): int64;
// Implementierung: (a & mask) | (b & ~mask)  – kein Branch

// Gibt 0xFFFF...FFFF wenn a==b, sonst 0  (kein Branch)
pub fn CTEqual(a: int64, b: int64): int64;
// Implementierung: ~((a - b | b - a) >> 63) + 1  o.ä.

// Vergleicht zwei Byte-Arrays in konstanter Zeit
pub fn CTMemEqual(a: int64, b: int64, len: int64): int64;
// XOR aller Bytes akkumulieren, am Ende prüfen ob == 0

// Überschreibt Speicher mit Nullen (Compiler darf das nicht wegoptimieren)
pub fn SecureZero(ptr: int64, len: int64): void;
// via poke8-Loop (Compiler kann volatile-Semantik nicht wegoptimieren)

// Modular-Reduktion ohne Branch (für NTT)
pub fn CTBarrettReduce(a: int64, q: int64): int64;
// Barrett-Reduktion: r = a - q * floor(a * m / 2^k)
pub fn CTMontgomeryReduce(a: int64, q: int64, qinv: int64): int64;
```

**Akzeptanzkriterium:** `CTMemEqual` gibt dasselbe Ergebnis wie ein naiver Byte-Vergleich, aber Ausführungszeit ist konstant für gleiche `len` unabhängig vom Inhalt.

---

### WP-PQC-05 — NTT: Polynomring-Arithmetik (`std/crypto/ntt.lyx`)

**Ziel:** Number Theoretic Transform (NTT) – das Herzstück der gitterbasierten Kryptographie. Ermöglicht Polynom-Multiplikation in O(n log n) statt O(n²).

**Datei:** `std/crypto/ntt.lyx`

**Mathematischer Hintergrund:**

Beide NIST-Lattice-Algorithmen arbeiten im Ring:
```
R_q = Z_q[X] / (X^256 + 1)
```

Ein Polynom hat 256 Koeffizienten, jeder eine ganze Zahl modulo q.

| Algorithmus | q | ω (Primitive Wurzel) |
|-------------|---|---------------------|
| ML-KEM | 3329 | 17 (primitive 256. Einheitswurzel mod q) |
| ML-DSA | 8380417 | 1753 (primitive 256. Einheitswurzel mod q) |

Die NTT wandelt ein Polynom in den "NTT-Bereich" um, wo Multiplikation punkt-weise statt faltungsweise funktioniert:
```
NTT(a · b) = NTT(a) ⊙ NTT(b)   (⊙ = komponentenweise Multiplikation)
```

**Butterfly-Netzwerk (vereinfacht, für q=3329, n=256):**
```
for len in [128, 64, 32, ..., 2, 1]:
    for start in 0..256 step 2*len:
        ζ = zeta_table[start / (2*len)]    // vorberechnete Torsionseinheiten
        for j in 0..len:
            t = ζ * f[start + len + j]     // mod q
            f[start + len + j] = f[start + j] - t   // mod q
            f[start + j]      = f[start + j] + t   // mod q
```

**Datenstrukturen:**
```lyx
// Polynom: 256 Koeffizienten, jeder int64 (Wert ∈ [0, q))
// Gespeichert als 256 * 8 = 2048 Bytes (mmap-alloziert)
pub con POLY_SIZE: int64 := 256;
pub con KYBER_Q:   int64 := 3329;
pub con DILITH_Q:  int64 := 8380417;

pub fn NTTPolyNew(): int64;              // alloziert 2048 Bytes, gibt Pointer zurück
pub fn NTTPolyFree(poly: int64): void;
```

**Funktionen:**
```lyx
// Vorwärts-NTT (Poly → NTT-Bereich) für ML-KEM (q=3329)
pub fn KyberNTT(f: int64): void;

// Inverse NTT (NTT-Bereich → Poly) für ML-KEM
pub fn KyberINTT(f: int64): void;

// Punktweise Multiplikation im NTT-Bereich (f = f ⊙ g mod q)
pub fn KyberPolyMul(f: int64, g: int64, out: int64): void;

// Polynom-Addition mod q
pub fn KyberPolyAdd(f: int64, g: int64, out: int64): void;

// Polynom-Subtraktion mod q
pub fn KyberPolySub(f: int64, g: int64, out: int64): void;

// Koeffizientenreduktion auf [0, q)
pub fn KyberPolyReduce(f: int64): void;

// Analoge Funktionen für ML-DSA (q=8380417):
pub fn DilithiumNTT(f: int64): void;
pub fn DilithiumINTT(f: int64): void;
// ...

// Sampling: uniforme Koeffizienten via SHAKE-128 (für Matrix A in ML-KEM)
pub fn KyberSampleNTT(seed: int64, x: int64, y: int64, out: int64): void;

// CBD-Sampling: zentrierte Binomialverteilung (für Fehlerterm e)
pub fn KyberSampleCBD(prf_out: int64, eta: int64, out: int64): void;
```

**Wichtige Implementierungsdetails:**
- **Zeta-Tabellen** (ζ^brv(i) mod q für i=0..127): Als `con`-Arrays hartcodieren. Für ML-KEM sind 128 Werte nötig; für ML-DSA 256. Werte einmalig berechnen (bekannt aus Spezifikation).
- **Barrett-Reduktion:** Für mod 3329 – statt Division `a % q` (langsam) die Barrett-Formel: vorberechnete Reziproke-Konstante `m = floor(2^k / q)` nutzen.
- **NTT-Bit-Reversal:** Koeffizienten nach Butterfly in bit-reversal-Reihenfolge – Standardtechnik.

**Akzeptanzkriterium:** `KyberNTT` gefolgt von `KyberINTT` auf einem Testpolynom ergibt das ursprüngliche Polynom zurück (mod q). Übereinstimmung mit Kyber-Referenzimplementierung für bekannte Testvektoren.

---

### WP-PQC-06 — ML-KEM (CRYSTALS-Kyber, NIST FIPS 203)

**Datei:** `std/crypto/pqc/mlkem.lyx`

**Was es tut:** Key Encapsulation Mechanism – ersetzt ECDH/RSA-OAEP für asymmetrischen Schlüsselaustausch. Zwei Parteien etablieren einen gemeinsamen geheimen Schlüssel, ohne ihn übertragen zu müssen.

**Mathematisches Fundament:** Module Learning With Errors (MLWE). Die Sicherheit beruht darauf, dass es praktisch unmöglich ist, aus `(A, t = A·s + e)` das Geheimnis `s` zurückzurechnen, wenn `e` ein kleiner Fehlervektor ist.

**Drei Sicherheitsstufen:**

| Parameter | k | η₁ | η₂ | dᵤ | dᵥ | PK-Größe | SK-Größe | CT-Größe | Äquiv. |
|-----------|---|-----|-----|----|----|----------|----------|----------|--------|
| ML-KEM-512 | 2 | 3 | 2 | 10 | 4 | 800 B | 1632 B | 768 B | AES-128 |
| ML-KEM-768 | 3 | 2 | 2 | 10 | 4 | 1184 B | 2400 B | 1088 B | AES-192 |
| ML-KEM-1024 | 4 | 2 | 2 | 11 | 5 | 1568 B | 3168 B | 1568 B | AES-256 |

**Protokollablauf:**

```
KeyGen(seed: 64 Bytes):
  (ρ, σ) = G(seed)                    // G = SHA3-512
  A ∈ R_q^{k×k} = SampleNTT(ρ)       // Matrix aus SHAKE-128
  (s, e) ∈ R_q^k = SampleCBD(σ, η₁)  // Geheimnis + Fehler
  t = NTT(A) · NTT(s) + NTT(e)
  PublicKey  = (t, ρ)
  SecretKey  = (s, t, ρ, H(pk), z)   // H=SHA3-256

Encapsulate(pk, randomness: 32 Bytes):
  m = H(randomness)
  (K̄, r) = G(m ∥ H(pk))
  (r₁, e₁, e₂) = SampleCBD(r, η₁, η₂)
  u = INTT(A^T · NTT(r₁)) + e₁      // k Polynome
  v = INTT(t^T · NTT(r₁)) + e₂ + ⌊q/2⌋·m   // 1 Polynom
  Ciphertext = (Compress(u, dᵤ), Compress(v, dᵥ))
  SharedKey  = KDF(K̄ ∥ H(ciphertext))

Decapsulate(sk, ciphertext):
  m' = INTT(s^T · NTT(u)) - v        // Annäherung an m
  (K̄', r') = G(m' ∥ H(pk))
  Ciphertext' = re-encrypt(r')        // implizite Prüfung
  b = CTMemEqual(c, c')               // constant-time Vergleich!
  SharedKey = CTSelect(KDF(K̄', H(c)), KDF(z, H(c)), b)
```

**Funktionen:**
```lyx
pub fn MLKEMKeyGen(seed: int64, k: int64, pk: int64, sk: int64): int64;
// seed: 64 Bytes Zufallsdaten, k: 2/3/4 für 512/768/1024
// pk/sk: Caller-allozierte Puffer (Größe abhängig von k)

pub fn MLKEMEncapsulate(pk: int64, k: int64, randomness: int64,
                         ciphertext: int64, sharedKey: int64): int64;
// sharedKey: 32 Bytes Output

pub fn MLKEMDecapsulate(sk: int64, k: int64, ciphertext: int64,
                         sharedKey: int64): int64;
// sharedKey: 32 Bytes Output (immer gleiche Länge, auch bei Fehler)
```

**Interne Hilfsfunktionen:**
```lyx
fn mlkem_compress(x: int64, d: int64, q: int64): int64;  // ⌊2^d/q · x⌋ mod 2^d
fn mlkem_decompress(x: int64, d: int64, q: int64): int64; // ⌊q/2^d · x⌉
fn mlkem_encode(poly: int64, d: int64, out: int64): void;  // d Bits/Koeffizient packen
fn mlkem_decode(data: int64, d: int64, poly: int64): void; // d Bits/Koeffizient entpacken
```

**Akzeptanzkriterium:**
1. KAT (Known Answer Tests) der NIST FIPS 203-Referenz passen für alle drei Parametersätze
2. `Decapsulate(sk, Encapsulate(pk, m))` == `m` für 1000 zufällige Schlüsselpaare
3. Manipulation des Ciphertexts liefert anderen (pseudozufälligen) SharedKey – kein Absturz

---

### WP-PQC-07 — ML-DSA (CRYSTALS-Dilithium, NIST FIPS 204)

**Datei:** `std/crypto/pqc/mldsa.lyx`

**Was es tut:** Digitale Signaturen – ersetzt RSA-Sign / ECDSA. Beweist Authentizität und Integrität von Nachrichten.

**Mathematisches Fundament:** Module Short Integer Solution (MSIS) + MLWE. Sicherheit basiert darauf, dass kurze Polynome schwer zu finden sind.

**Drei Sicherheitsstufen:**

| Parameter | k | l | γ₁ | τ | SK-Größe | PK-Größe | Sig-Größe | Äquiv. |
|-----------|---|---|-----|---|----------|----------|-----------|--------|
| ML-DSA-44 | 4 | 4 | 2¹⁷ | 39 | 2528 B | 1312 B | 2420 B | AES-128 |
| ML-DSA-65 | 6 | 5 | 2¹⁹ | 49 | 4000 B | 1952 B | 3293 B | AES-192 |
| ML-DSA-87 | 8 | 7 | 2¹⁹ | 60 | 4864 B | 2592 B | 4595 B | AES-256 |

**Protokollablauf (vereinfacht):**

```
KeyGen(seed: 32 Bytes):
  (ρ, ρ', K) = H(seed)
  A ∈ R_q^{k×l} = SampleNTT(ρ)
  (s₁, s₂) = SampleEta(ρ')               // kleine Koeffizienten
  t = A·NTT(s₁) + s₂
  (t₁, t₀) = Power2Round(t, 13)          // Aufteilung
  PublicKey = (ρ, t₁)
  SecretKey = (ρ, K, tr, s₁, s₂, t₀)   // tr = H(pk)

Sign(sk, message):
  μ = H(tr ∥ message)
  loop:
    y = SampleGamma1(K, κ)              // Maske
    w = A · NTT(y)
    w₁ = HighBits(w, 2γ₂)
    c̃ = H(μ ∥ w₁)
    c = SampleInBall(c̃, τ)             // dünnbesetztes Polynom
    z = y + c·s₁
    if ||z||∞ ≥ γ₁ - β: retry          // Rejection Sampling
    h = MakeHint(-c·t₀, w - c·s₂ + c·t₀)
    if ||h||₁ > ω: retry
    break
  return (c̃, z, h)

Verify(pk, message, signature):
  μ = H(H(pk) ∥ message)
  c = SampleInBall(c̃, τ)
  w' = A·NTT(z) - c·NTT(t₁·2¹³)
  w₁' = UseHint(h, w')
  return c̃ == H(μ ∥ w₁') AND ||z||∞ < γ₁ - β
```

**Funktionen:**
```lyx
pub fn MLDSAKeyGen(seed: int64, level: int64, pk: int64, sk: int64): int64;
// level: 44, 65 oder 87

pub fn MLDSASign(sk: int64, level: int64, msg: int64, msgLen: int64,
                  sig: int64, sigLen: int64): int64;
// Gibt tatsächliche Signaturlänge zurück

pub fn MLDSAVerify(pk: int64, level: int64, msg: int64, msgLen: int64,
                    sig: int64, sigLen: int64): bool;
```

**Schlüsselfunktionen intern:**
```lyx
fn mldsa_power2round(r: int64, d: int64, r0: int64, r1: int64): void;
fn mldsa_highbits(r: int64, alpha: int64): int64;
fn mldsa_lowbits(r: int64, alpha: int64): int64;
fn mldsa_make_hint(z: int64, r: int64, alpha: int64): int64;
fn mldsa_use_hint(h: int64, r: int64, alpha: int64): int64;
fn mldsa_sample_in_ball(seed: int64, tau: int64, out: int64): void;
```

**Besonderheit: Rejection Sampling**  
`Sign` kann mehrfach iterieren (im Durchschnitt ~4–7 Mal). Das ist korrekt und normal.

**Akzeptanzkriterium:** NIST FIPS 204 KAT-Vektoren für alle drei Stufen passen.

---

### WP-PQC-08 — SLH-DSA (SPHINCS+, NIST FIPS 205)

**Datei:** `std/crypto/pqc/slhdsa.lyx`

**Was es tut:** Hash-basierte digitale Signaturen. Keine Gitter, keine NTT – nur SHA-256 und SHAKE als Primitive. Konservativste Sicherheitsannahme aller NIST-PQC-Algorithmen.

**Warum zuerst implementieren:** Einfachere Mathematik, trotzdem sofort produktionsreif. Gut als Einstieg und um die Hash-Fundamente (WP-PQC-01, WP-PQC-02) zu testen.

**Mathematisches Fundament:** Binärer Hypertree aus XMSS-Bäumen (eXtended Merkle Signature Scheme). Jede Signatur nutzt einen einmaligen WOTS+-Schlüssel (Winternitz One-Time Signature) und beweist dessen Zugehörigkeit zur Wurzel via Merkle-Pfad.

**Struktur:**
```
Hypertree (d Ebenen, jede Ebene h' Stufen hoch)
    └── XMSS-Baum (Blätter = WOTS+-Schlüssel)
             └── FORS (Forest of Random Subsets, für den Nachrichten-Index)
```

**Parameter (Auswahl):**

| Variante | n | h | d | a | k | PK | SK | Sig | Äquiv. |
|----------|---|---|---|---|---|----|----|-----|--------|
| SPHINCS+-SHA2-128s | 16 | 63 | 7 | 12 | 14 | 32 B | 64 B | 7856 B | 128 Bit |
| SPHINCS+-SHA2-256s | 32 | 64 | 8 | 14 | 22 | 64 B | 128 B | 29792 B | 256 Bit |

**Funktionen:**
```lyx
pub fn SLHDSAKeyGen(sk_seed: int64, sk_prf: int64, pk_seed: int64,
                     n: int64, pk: int64, sk: int64): void;

pub fn SLHDSASign(sk: int64, msg: int64, msgLen: int64,
                   randomize: int64, sig: int64): int64;
// Gibt Signaturlänge zurück

pub fn SLHDSAVerify(pk: int64, msg: int64, msgLen: int64,
                     sig: int64, sigLen: int64): bool;

// Interne Bausteine:
fn slh_wots_sign(msg: int64, sk_seed: int64, pk_seed: int64, adrs: int64, sig: int64): void;
fn slh_wots_pk_from_sig(sig: int64, msg: int64, pk_seed: int64, adrs: int64, pk: int64): void;
fn slh_xmss_sign(msg: int64, sk_seed: int64, idx: int64, pk_seed: int64, adrs: int64, sig: int64): void;
fn slh_fors_sign(md: int64, sk_seed: int64, pk_seed: int64, adrs: int64, sig: int64): void;
```

**Akzeptanzkriterium:** NIST FIPS 205 KAT-Vektoren passen für SPHINCS+-SHA2-128s und SPHINCS+-SHA2-256s.

---

### WP-PQC-09 — Hybrid-Modus: Klassisch + PQC (`std/crypto/pqc/hybrid.lyx`)

**Ziel:** Übergangs-API die klassische und PQC-Algorithmen kombiniert. Schützt auch wenn einer der beiden Algorithmen kompromittiert wird.

**Datei:** `std/crypto/pqc/hybrid.lyx`

**Warum Hybrid?**
- PQC-Algorithmen sind jung (< 10 Jahre intensiver Krypto-Analyse)
- Klassische Algorithmen sind in den nächsten ~10 Jahren noch sicher
- Apple PQ3, Google Chrome, Signal nutzen alle Hybrid-Ansätze

**Benötigte Vorarbeit:** X25519 (Diffie-Hellman auf Curve25519) nativ in Lyx. Benötigt:
- 255-Bit-Modular-Arithmetik über Z_p (p = 2²⁵⁵ − 19)
- Montgomery-Leiter für Scalar Multiplication (constant-time)
- Eigenständiges WP empfohlen: `std/crypto/x25519.lyx`

**Hybrid-KEM (X25519 + ML-KEM-768, wie Signal/Google):**
```
HybridKeyGen():
  (pk_x, sk_x) = X25519KeyGen()
  (pk_k, sk_k) = MLKEMKeyGen(768)
  return (pk_x ∥ pk_k), (sk_x ∥ sk_k)

HybridEncapsulate(pk):
  (ct_x, ss_x) = X25519Encapsulate(pk_x)
  (ct_k, ss_k) = MLKEMEncapsulate(pk_k, 768)
  ss = HKDF-SHA256(ss_x ∥ ss_k ∥ ct_x ∥ ct_k)
  return (ct_x ∥ ct_k), ss
```

**Funktionen:**
```lyx
pub fn X25519KeyGen(sk_seed: int64, pk: int64, sk: int64): void;
pub fn X25519Encapsulate(pk: int64, ct: int64, ss: int64): void;
pub fn X25519Decapsulate(sk: int64, ct: int64, ss: int64): void;

pub fn HybridKEMKeyGen(pk: int64, sk: int64): void;
pub fn HybridKEMEncapsulate(pk: int64, ct: int64, sharedKey: int64): void;
pub fn HybridKEMDecapsulate(sk: int64, ct: int64, sharedKey: int64): void;
```

**Akzeptanzkriterium:** Shared Keys stimmen überein; Korrektheit für 1000 zufällige Paare.

---

### WP-PQC-10 — High-Level PQC API (`std/crypto/pqc/pqc.lyx`)

**Ziel:** Einheitliche, benutzerfreundliche Fassade über alle PQC-Algorithmen.

**Datei:** `std/crypto/pqc/pqc.lyx`

**Algorithmus-Konstanten:**
```lyx
pub con PQC_ALG_MLKEM_512:    int64 := 1;
pub con PQC_ALG_MLKEM_768:    int64 := 2;
pub con PQC_ALG_MLKEM_1024:   int64 := 3;
pub con PQC_ALG_MLDSA_44:     int64 := 4;
pub con PQC_ALG_MLDSA_65:     int64 := 5;
pub con PQC_ALG_MLDSA_87:     int64 := 6;
pub con PQC_ALG_SLHDSA_128S:  int64 := 7;
pub con PQC_ALG_SLHDSA_256S:  int64 := 8;
pub con PQC_ALG_HYBRID_768:   int64 := 9;   // X25519 + ML-KEM-768
```

**API:**
```lyx
pub type PQCKeyPair = struct {
    algorithm: int64;
    pkPtr:     int64;
    pkLen:     int64;
    skPtr:     int64;
    skLen:     int64;
};

pub fn PQCKeyGen(algorithm: int64): PQCKeyPair;

// KEM (Schlüsselaustausch)
pub fn PQCEncapsulate(kp: PQCKeyPair, ctOut: int64, ssOut: int64): int64;
pub fn PQCDecapsulate(kp: PQCKeyPair, ct: int64, ctLen: int64, ssOut: int64): int64;

// Signaturen
pub fn PQCSign(kp: PQCKeyPair, msg: int64, msgLen: int64, sigOut: int64): int64;
pub fn PQCVerify(kp: PQCKeyPair, msg: int64, msgLen: int64, sig: int64, sigLen: int64): bool;

// Schlüssel serialisieren (raw bytes)
pub fn PQCExportPublicKey(kp: PQCKeyPair, out: int64): int64;
pub fn PQCExportSecretKey(kp: PQCKeyPair, out: int64): int64;
pub fn PQCImportPublicKey(algorithm: int64, data: int64, len: int64): PQCKeyPair;

pub fn PQCFreeKeyPair(kp: PQCKeyPair): void;
```

---

### WP-PQC-11 — Demo: PQC-geschütztes Nachrichtensystem (`test_pqc.lyx`)

**Ziel:** Zeigt alle drei NIST-Algorithmen in einem realistischen Szenario.

**Datei:** `test_pqc.lyx`

**Szenario:** Alice und Bob tauschen eine verschlüsselte, signierte Nachricht aus – mit post-quantum-sicherer Kryptographie.

```
Alice                                  Bob
  │                                     │
  ├─ MLKEMKeyGen(768) → (pk_A, sk_A)   │
  ├─ MLDSAKeyGen(65)  → (sig_A, vk_A)  │
  │                                     ├─ MLKEMKeyGen(768) → (pk_B, sk_B)
  │                                     ├─ MLDSAKeyGen(65)  → (sig_B, vk_B)
  │                                     │
  │◄─────────────── pk_B, vk_B ─────────┤
  │                                     │
  ├─ Encapsulate(pk_B) → (ct, ss)      │
  ├─ msg = AES-256-CTR(ss, "Geheimtext")│
  ├─ sig = MLDSASign(sig_A, ct ∥ msg)  │
  │─────────── ct, msg, sig ───────────►│
  │                                     ├─ Decapsulate(sk_B, ct) → ss
  │                                     ├─ MLDSAVerify(vk_A, sig)
  │                                     ├─ AES-256-CTR(ss, msg) → "Geheimtext"
```

**Ausgabe-Beispiel:**
```
[PQC Demo] Schlüsselerzeugung...
  Alice ML-KEM-768: pk=1184B sk=2400B
  Alice ML-DSA-65:  pk=1952B sk=4000B
  Bob   ML-KEM-768: pk=1184B sk=2400B

[PQC Demo] Alice → Bob (verschlüsselt + signiert)...
  KEM Ciphertext:  1088 Bytes
  Nachricht:       16 Bytes (verschlüsselt)
  Signatur:        3293 Bytes
  Shared Secret:   32 Bytes

[PQC Demo] Bob entschlüsselt und verifiziert...
  Signatur: OK
  Nachricht: "Hallo Post-Quantum!"

[PQC Demo] Timings:
  MLKEMKeyGen:      0.8ms
  MLKEMEncapsulate: 0.9ms
  MLKEMDecapsulate: 1.1ms
  MLDSASign:        2.4ms (inkl. ~5 Rejection-Sampling-Iterationen)
  MLDSAVerify:      1.0ms
```

---

## Implementierungsreihenfolge

```
WP-PQC-04  Constant-Time Utils         ← Voraussetzung für alle anderen
    │
WP-PQC-01  Keccak/SHA-3/SHAKE          ← Fundament für ML-KEM, ML-DSA, SLH-DSA
    │
WP-PQC-02  SHA-256 Multi-Block         ← Fundament für SLH-DSA + HMAC
    │
WP-PQC-08  SLH-DSA (SPHINCS+)          ← Einstieg: nur Hashes, kein NTT
    │                                     Validiert WP-PQC-01 + WP-PQC-02
    │
WP-PQC-03  AES-256-CTR                 ← DRBG für ML-KEM/DSA KAT-Tests
    │
WP-PQC-05  NTT / Polynom-Ring          ← Herzstück der Gitter-Kryptographie
    │
WP-PQC-06  ML-KEM                      ← NIST FIPS 203
    │
WP-PQC-07  ML-DSA                      ← NIST FIPS 204
    │
WP-PQC-09  X25519 + Hybrid-KEM         ← Übergangs-Modus
    │
WP-PQC-10  High-Level API
    │
WP-PQC-11  Demo
```

---

## Schlüsselgrößen und Leistungserwartungen (Referenz)

| Algorithmus | KeyGen | Encap/Sign | Decap/Verify | PK | SK | CT/Sig |
|-------------|--------|-----------|-------------|----|----|--------|
| ML-KEM-768 | ~1ms | ~1ms | ~1ms | 1184B | 2400B | 1088B |
| ML-DSA-65 | ~1ms | ~2ms | ~1ms | 1952B | 4000B | 3293B |
| SLH-DSA-128s | ~5ms | ~100ms | ~5ms | 32B | 64B | 7856B |
| RSA-2048 (Ref) | ~50ms | ~1ms | ~50ms | 256B | 256B | 256B |

SLH-DSA hat deutlich größere Signaturen und langsameres Signieren – dafür hängt die Sicherheit nur von der Kollisionsresistenz der Hash-Funktion ab (konservativste Annahme).

---

## Testvektoren-Quellen

| Algorithmus | Quelle |
|-------------|--------|
| Keccak/SHA-3/SHAKE | https://csrc.nist.gov/projects/cryptographic-standards-and-guidelines (SHA-3 Known Answer Tests) |
| SHA-256 | FIPS 180-4 Appendix B |
| AES-CTR | NIST SP 800-38A |
| ML-KEM | NIST FIPS 203 Appendix C (KAT) |
| ML-DSA | NIST FIPS 204 Appendix C (KAT) |
| SLH-DSA | NIST FIPS 205 Appendix D (KAT) |

---

## Risiken

| # | Risiko | Mitigation |
|---|--------|-----------|
| R1 | Timing-Seitenkanal in NTT-Implementierung | `CTBarrettReduce` konsequent nutzen, keine Branches auf geheimen Daten |
| R2 | Falsche Keccak-Rundenkonstanten (typo) | SHA-3 KAT als ersten Test laufen lassen |
| R3 | Rejection Sampling in ML-DSA endlos-Loop | Maximale Iterationsanzahl (z.B. 1000) als Sicherheitsabbruch |
| R4 | ML-KEM Decapsulate gibt falschen Key bei Manipulation | CTMemEqual-Test zwingend, nicht optional |
| R5 | SLH-DSA sehr langsam für 256-Bit-Variante (~1s) | Zuerst 128s-Variante implementieren und vermarkten |
| R6 | X25519 Scalar-Multiplication anfällig für Side-Channels | Montgomery-Leiter strikt constant-time (WP-PQC-09) |
