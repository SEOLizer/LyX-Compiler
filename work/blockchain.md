# std/blockchain — Arbeitspakete

## Architektur-Kurzreferenz

```
[std/crypto]           ← Voraussetzung (WP-BL-01)
     │
[std/blockchain]
  ├── Serializer       ← WP-BL-02
  ├── Core-Models      ← WP-BL-03
  ├── Ledger           ← WP-BL-04
  └── Consensus        ← WP-BL-05
          │
[std/blockchain/p2p]   ← WP-BL-06 (optional)
```

**Kern-Invarianten (gelten für alle WPs):**
- Alle Geldbeträge sind `Int64` in Basis-Einheiten. `1 Coin = BASE_UNIT = 1_000_000`. Kein Float.
- Strings werden nie direkt gehasht. Immer: `sha256(Serializer.serialize(x))`.
- Big-Endian für alle Integer in der Serialisierung.
- Alle Hash-/Signatur-Eingaben sind `Bytes = Array<UInt8>`.

---

## WP-Übersicht

| WP | Titel | Abhängt von | Datei |
|---|---|---|---|
| WP-BL-01 | std/crypto | – | `std/crypto.lyx` |
| WP-BL-02 | Serializer | WP-BL-01 | `std/blockchain.lyx` |
| WP-BL-03 | Core-Models | WP-BL-02 | `std/blockchain.lyx` |
| WP-BL-04 | Ledger | WP-BL-03 | `std/blockchain.lyx` |
| WP-BL-05 | Consensus | WP-BL-04 | `std/blockchain.lyx` |
| WP-BL-06 | P2P-Networking | WP-BL-05 | `std/blockchain/p2p.lyx` |

---

---

# WP-BL-01: std/crypto

## Ziel

Bereitstellung kryptografischer Primitive, die von `std/blockchain` und zukünftigen Units benötigt werden. Dieses Paket liefert SHA-256-Hashing und ECDSA-Schlüsseloperationen auf der Kurve secp256k1. Alle Operationen arbeiten auf rohen Bytes, nie auf Strings.

## Abhängigkeiten

- **Extern (C-Bibliothek):** `libsecp256k1` muss auf dem Zielsystem installiert sein (`apt install libsecp256k1-dev`). ECDSA-Operationen werden via Lyx `extern fn`-FFI aufgerufen.
- **Syscall:** `getrandom` (SYS_getrandom = 318 auf x86-64) für kryptografisch sichere Zufallsdaten bei der Schlüsselgenerierung.
- **Syscall:** `socket`, `bind`, `accept`, `write`, `read` für den AF_ALG-Kernel-Crypto-Interface (SHA-256).
- **Stage-2-Build erforderlich**, falls `getrandom` noch nicht im Bootstrap-Compiler bekannt ist.

## Nicht im Umfang

- Andere Hash-Algorithmen (Keccak-256, SHA-3 etc.) — v2.0
- Ed25519 oder andere Kurven — v2.0
- Key-Derivation (BIP-32/HD-Wallets) — v2.0

## Zu implementierende Symbole

### Typen

```lyx
type Bytes      = Array<UInt8>
type Hash       = Bytes   // immer 32 Byte
type PublicKey  = Bytes   // immer 33 Byte (komprimierter secp256k1-Punkt)
type PrivateKey = Bytes   // immer 32 Byte (secp256k1-Skalar)
type Signature  = Bytes   // immer 64 Byte (ECDSA compact: r || s)

struct KeyPair
    privateKey: PrivateKey
    publicKey:  PublicKey
```

### Funktionen

```lyx
fn sha256(data: Bytes): Hash
fn getrandomBytes(n: Int32): Bytes
fn ecdsaGenKeyPair(): KeyPair
fn ecdsaSign(key: PrivateKey, data: Hash): Signature
fn ecdsaVerify(key: PublicKey, data: Hash, sig: Signature): Boolean
```

## Technische Implementierungshinweise

### SHA-256 via Linux AF_ALG

Der Linux-Kernel stellt über `AF_ALG = 38` einen Socket-basierten Crypto-Interface bereit. Keine externe Library notwendig.

```
// Pseudocode — Syscall-Sequenz
sockfd = socket(AF_ALG=38, SOCK_SEQPACKET=5, 0)

// sockaddr_alg: family=38, type="hash\0...", feat=0, mask=0, name="sha256\0..."
// Gesamtgröße: 2+14+4+4+64 = 88 Byte, alles little-endian für family, rest ASCII
bind(sockfd, sockaddr_alg_bytes, 88)

opfd = accept(sockfd, NULL, 0)
write(opfd, data, data_len)
read(opfd, result_buffer, 32)   // liest genau 32 Byte Hash

close(opfd)
close(sockfd)
```

`sockaddr_alg` Struct-Layout (Byte-genau für `bind`):
```
[0..1]   salg_family: UInt16 = 38  (AF_ALG)
[2..15]  salg_type:   14 Byte ASCII = "hash\0\0\0\0\0\0\0\0\0\0"
[16..19] salg_feat:   UInt32 = 0
[20..23] salg_mask:   UInt32 = 0
[24..87] salg_name:   64 Byte ASCII = "sha256\0\0..." (rest 0-padded)
```

### getrandom Syscall

```lyx
// SYS_getrandom = 318, flags = 0 (blockiert bis Entropy verfügbar)
fn getrandomBytes(n: Int32): Bytes
    buf = Array<UInt8>.alloc(n)
    syscall(318, buf.ptr, n, 0)
    return buf
```

### ECDSA via libsecp256k1 FFI

Die Bibliothek stellt C-Funktionen bereit, die via `extern fn` eingebunden werden.

```lyx
extern fn secp256k1_context_create(flags: UInt32): Ptr
extern fn secp256k1_ec_pubkey_create(ctx: Ptr, pubkey_out: Ptr, seckey: Ptr): Int32
extern fn secp256k1_ec_pubkey_serialize(ctx: Ptr, out: Ptr, outlen: Ptr, pubkey: Ptr, flags: UInt32): Int32
extern fn secp256k1_ecdsa_sign(ctx: Ptr, sig_out: Ptr, msghash: Ptr, seckey: Ptr, nonce_fn: Ptr, nonce_data: Ptr): Int32
extern fn secp256k1_ecdsa_signature_serialize_compact(ctx: Ptr, out: Ptr, sig: Ptr): Int32
extern fn secp256k1_ecdsa_verify(ctx: Ptr, sig: Ptr, msghash: Ptr, pubkey: Ptr): Int32
extern fn secp256k1_ec_pubkey_parse(ctx: Ptr, pubkey_out: Ptr, input: Ptr, inputlen: Int64): Int32
extern fn secp256k1_ecdsa_signature_parse_compact(ctx: Ptr, sig_out: Ptr, input: Ptr): Int32
```

Konstanten:
```
SECP256K1_CONTEXT_SIGN   = 0x0101
SECP256K1_CONTEXT_VERIFY = 0x0102
SECP256K1_EC_COMPRESSED  = 0x0102
```

`ecdsaGenKeyPair()` Algorithmus:
1. 32 Byte via `getrandomBytes(32)` holen
2. Prüfen, ob gültiger Skalar (muss > 0 und < Kurvenordnung sein; `secp256k1_ec_seckey_verify` verwenden)
3. Falls ungültig: wiederholen (Wahrscheinlichkeit ca. 1 in 2^128 — Schleife terminiert praktisch immer sofort)
4. `secp256k1_ec_pubkey_create` aufrufen → 64-Byte internen pubkey
5. `secp256k1_ec_pubkey_serialize` mit `SECP256K1_EC_COMPRESSED` → 33 Byte

`ecdsaSign(key, data)` — `data` muss ein 32-Byte-SHA-256-Hash sein (nicht der Klartext).

`ecdsaVerify(key, data, sig)` — `data` muss ebenfalls der 32-Byte-Hash sein.

### Wichtig: Lyx-spezifische Hinweise

- FFI-Aufrufe via `extern fn` benötigen die korrekte Linker-Reihenfolge (`-lsecp256k1` nach dem Objekt).
- Der `secp256k1_context` sollte einmalig beim Programmstart als globale Konstante erstellt werden, nicht pro Aufruf.
- Stage-2-Build: Falls `SYS_getrandom` (318) noch nicht im Bootstrap bekannt → zuerst `lyxc_new` bauen.

## Testfälle

### SHA-256 NIST-Testvektoren (FIPS 180-4)

| Input | Erwarteter SHA-256 Hash (hex) |
|---|---|
| `""` (leer, 0 Byte) | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `"abc"` (3 Byte ASCII) | `ba7816bf8f01cfea414140de5dae2ec73b00361bbef0469f96caf0571dc9b3f1` |
| `sha256(sha256(""))` (Verkettung) | muss deterministisch sein: gleicher Input → immer gleicher Output |

### ECDSA Round-Trip

```
key = ecdsaGenKeyPair()
msg = sha256("Testnachricht")
sig = ecdsaSign(key.privateKey, msg)
assert ecdsaVerify(key.publicKey, msg, sig) == true
assert ecdsaVerify(key.publicKey, sha256("andere Nachricht"), sig) == false
```

### Replay-Schutz (andere Nachricht, gleiche Signatur)

```
sig1 = ecdsaSign(key.privateKey, sha256("A"))
sig2 = ecdsaSign(key.privateKey, sha256("B"))
assert sig1 != sig2   // Signaturen müssen verschieden sein
```

## Akzeptanzkriterien

- [ ] `sha256("")` liefert exakt `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- [ ] `sha256("abc")` liefert exakt `ba7816bf8f01cfea414140de5dae2ec73b00361bbef0469f96caf0571dc9b3f1`
- [ ] `sha256(x)` ist deterministisch: gleicher Input liefert immer gleichen Output
- [ ] `sha256(x)` gibt exakt 32 Byte zurück
- [ ] `ecdsaGenKeyPair()` gibt `publicKey.length == 33` und `privateKey.length == 32` zurück
- [ ] ECDSA Round-Trip: `ecdsaVerify(pub, msg, ecdsaSign(priv, msg)) == true`
- [ ] Signatur-Verifikation mit falscher Nachricht gibt `false`
- [ ] Signatur-Verifikation mit falschem Public Key gibt `false`
- [ ] `getrandomBytes(32)` gibt exakt 32 Byte zurück
- [ ] Zwei aufeinanderfolgende `getrandomBytes(32)` liefern mit extrem hoher Wahrscheinlichkeit verschiedene Werte
- [ ] Laufzeit von `sha256` für 1 KB Input: unter 1 ms
- [ ] Kompiliert und linkt ohne Fehler mit `-lsecp256k1`

---

---

# WP-BL-02: Serializer

## Ziel

Implementierung eines kanonischen Binär-Serialisierers, der alle Blockchain-Datenstrukturen in `Bytes` umwandelt. Dieser Serialisierer ist die einzige erlaubte Schnittstelle zwischen Datenstrukturen und Hash-/Signieroperationen. Determinismus auf allen Plattformen ist die oberste Anforderung.

## Abhängigkeiten

- WP-BL-01 (`Bytes`-Typ muss bekannt sein)
- Die Typen `Transaction` und `Block` aus WP-BL-03 werden referenziert — beide WPs können parallel entwickelt werden, wenn die Struct-Layouts vorab festgelegt sind.

## Nicht im Umfang

- JSON- oder String-Serialisierung — niemals
- Deserialisierung (Bytes → Struct) — wird in WP-BL-06 für P2P benötigt, gehört aber in ein separates `Deserializer`-Modul

## Zu implementierende Symbole

```lyx
fn serializeInt32(v: Int32): Bytes          // 4 Byte big-endian
fn serializeInt64(v: Int64): Bytes          // 8 Byte big-endian
fn serializeBytes(b: Bytes): Bytes          // 4-Byte-Länge + b
fn serializeTxPayload(tx: Transaction): Bytes  // Signing-Payload (ohne signature)
fn serializeTxFull(tx: Transaction): Bytes     // Vollständige TX (inkl. signature, für Merkle)
fn serializeBlockHeader(b: Block): Bytes       // Nur Header-Felder (für calculateHash)
fn merkleRoot(txs: List<Transaction>): Hash    // Merkle-Root über txs
```

## Technische Implementierungshinweise

### Integer-Serialisierung (Big-Endian)

```
serializeInt64(v):
    bytes[0] = (v >> 56) & 0xFF
    bytes[1] = (v >> 48) & 0xFF
    bytes[2] = (v >> 40) & 0xFF
    bytes[3] = (v >> 32) & 0xFF
    bytes[4] = (v >> 24) & 0xFF
    bytes[5] = (v >> 16) & 0xFF
    bytes[6] = (v >>  8) & 0xFF
    bytes[7] = (v >>  0) & 0xFF
    return bytes  // 8 Byte
```

### serializeTxPayload — Feldfolge (wird signiert, ohne `signature`)

```
[4 Byte]  len(senderAddress)    (immer 32)
[32 Byte] senderAddress
[4 Byte]  len(senderPublicKey)  (immer 33)
[33 Byte] senderPublicKey
[4 Byte]  len(receiverAddress)  (immer 32)
[32 Byte] receiverAddress
[8 Byte]  amount                (Int64, big-endian)
[8 Byte]  fee                   (Int64, big-endian)
[8 Byte]  nonce                 (Int64, big-endian)
[8 Byte]  timestamp             (Int64, big-endian)
```

Gesamtgröße: 4+32 + 4+33 + 4+32 + 8+8+8+8 = **141 Byte** (fix)

### serializeTxFull — Feldfolge (für Merkle-Tree-Blätter)

Identisch mit `serializeTxPayload`, danach:
```
[4 Byte]  len(signature)  (immer 64 für normale TX, 0 für Coinbase)
[64 Byte] signature       (oder leer bei Coinbase)
```

Gesamtgröße normale TX: 141 + 4 + 64 = **209 Byte** (fix)

### serializeBlockHeader — Feldfolge (für `calculateHash`)

```
[8 Byte]  index           (Int64, big-endian)
[8 Byte]  timestamp       (Int64, big-endian)
[4 Byte]  len(previousHash) (immer 32)
[32 Byte] previousHash
[4 Byte]  len(merkleRoot)   (immer 32)
[32 Byte] merkleRoot
[8 Byte]  nonce           (Int64, big-endian)
[4 Byte]  difficulty      (Int32, big-endian)
```

Gesamtgröße: 8+8 + 4+32 + 4+32 + 8+4 = **100 Byte** (fix)

Das `hash`-Feld des Blocks und `transactions` fließen **nicht** in `serializeBlockHeader` ein.

### Merkle-Tree-Algorithmus

```
merkleRoot(txs):
    if txs.isEmpty():
        return sha256(Bytes.empty())

    // Blätter: jede TX wird vollständig gehasht
    leaves: List<Hash> = txs.map(tx => sha256(serializeTxFull(tx)))

    while leaves.length > 1:
        if leaves.length is odd:
            leaves.append(leaves.last())   // letztes Element duplizieren
        nextLevel: List<Hash> = []
        for i = 0 to leaves.length - 1 step 2:
            combined = leaves[i] || leaves[i+1]  // 64 Byte
            nextLevel.append(sha256(combined))
        leaves = nextLevel

    return leaves[0]
```

## Testfälle

### Integer-Serialisierung

| Input | Erwartete Bytes (hex) |
|---|---|
| `serializeInt64(0)` | `00 00 00 00 00 00 00 00` |
| `serializeInt64(1)` | `00 00 00 00 00 00 00 01` |
| `serializeInt64(256)` | `00 00 00 00 00 00 01 00` |
| `serializeInt64(-1)` | `FF FF FF FF FF FF FF FF` |
| `serializeInt32(1)` | `00 00 00 01` |

### serializeTxPayload — Größenprüfung

```
tx = Transaction(senderAddress=zeros(32), senderPublicKey=zeros(33),
                 receiverAddress=zeros(32), amount=0, fee=0, nonce=0, timestamp=0)
assert serializeTxPayload(tx).length == 141
assert serializeTxFull(tx).length == 209
```

### serializeBlockHeader — Größenprüfung

```
b = Block(index=0, timestamp=0, previousHash=zeros(32), merkleRoot=zeros(32), nonce=0, difficulty=0)
assert serializeBlockHeader(b).length == 100
```

### Merkle-Tree-Testvektoren

```
// Leere Liste
assert merkleRoot([]) == sha256(Bytes.empty())

// Eine TX: Blatt wird mit sich selbst gehasht
hash1 = sha256(serializeTxFull(tx1))
assert merkleRoot([tx1]) == sha256(hash1 || hash1)

// Zwei TXs
h1 = sha256(serializeTxFull(tx1))
h2 = sha256(serializeTxFull(tx2))
assert merkleRoot([tx1, tx2]) == sha256(h1 || h2)

// Drei TXs (ungerade → tx3 dupliziert)
h1 = sha256(serializeTxFull(tx1))
h2 = sha256(serializeTxFull(tx2))
h3 = sha256(serializeTxFull(tx3))
p1 = sha256(h1 || h2)
p2 = sha256(h3 || h3)
assert merkleRoot([tx1, tx2, tx3]) == sha256(p1 || p2)
```

### Determinismus

```
assert serializeTxPayload(tx) == serializeTxPayload(tx)   // zwei Aufrufe, gleiches Ergebnis
assert serializeBlockHeader(b) == serializeBlockHeader(b)
```

## Akzeptanzkriterien

- [ ] `serializeInt64(0)` == `[0,0,0,0,0,0,0,0]`
- [ ] `serializeInt64(-1)` == `[0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF]`
- [ ] `serializeTxPayload` gibt exakt 141 Byte zurück (fix)
- [ ] `serializeTxFull` gibt exakt 209 Byte zurück für normale TX
- [ ] `serializeBlockHeader` gibt exakt 100 Byte zurück (fix)
- [ ] `merkleRoot([])` == `sha256([])`
- [ ] `merkleRoot([tx1, tx2])` == `sha256(sha256(full(tx1)) || sha256(full(tx2)))`
- [ ] `merkleRoot([tx1, tx2, tx3])` entspricht dem oben definierten 3-Element-Testvektor
- [ ] Gleicher Input liefert immer denselben Output (kein nicht-deterministisches Verhalten)
- [ ] Kein Feld enthält Padding oder optionale Bytes

---

---

# WP-BL-03: Core-Models

## Ziel

Definition der grundlegenden Datenstrukturen `Transaction`, `CoinbaseTransaction` und `Block` sowie der zugehörigen Konstruktor- und Hash-Methoden. Diese Strukturen sind der gemeinsame Datenvertrag zwischen Ledger, Consensus und P2P.

## Abhängigkeiten

- WP-BL-01 (`Hash`, `Bytes`, `PublicKey`, `PrivateKey`, `Signature`, `sha256`)
- WP-BL-02 (`serializeTxPayload`, `serializeTxFull`, `serializeBlockHeader`, `merkleRoot`)

## Nicht im Umfang

- Ledger-Logik (Guthaben, Nonce-Tracking) — WP-BL-04
- Mining / Konsens-Validierung — WP-BL-05
- Netzwerk-Serialisierung / Deserialisierung — WP-BL-06

## Zu implementierende Symbole

```lyx
const BASE_UNIT: Int64 = 1_000_000

struct Transaction
    senderAddress:   Address    // sha256(senderPublicKey), 32 Byte
    senderPublicKey: PublicKey  // komprimierter secp256k1-Punkt, 33 Byte
    receiverAddress: Address    // 32 Byte
    amount:          Int64      // >= 0, in BASE_UNITs
    fee:             Int64      // >= 0, in BASE_UNITs
    nonce:           Int64      // monoton steigend pro Sender
    timestamp:       Int64      // Unix-Zeit in Nanosekunden
    signature:       Signature  // 64 Byte; leer (zeros) bei Coinbase

fn newTransaction(senderPublicKey: PublicKey, receiverAddress: Address,
                  amount: Int64, fee: Int64, nonce: Int64): Transaction
fn signingPayload(tx: Transaction): Bytes
fn txHash(tx: Transaction): Hash              // sha256(serializeTxFull(tx))
fn isCoinbase(tx: Transaction): Boolean       // senderAddress == zeros(32)

fn newCoinbaseTx(receiverAddress: Address, amount: Int64, blockIndex: Int64): Transaction

struct Block
    index:        Int64
    timestamp:    Int64
    previousHash: Hash            // 32 Byte
    merkleRoot:   Hash            // 32 Byte
    nonce:        Int64
    difficulty:   Int32
    hash:         Hash            // 32 Byte; leer bis calculateHash() aufgerufen
    transactions: List<Transaction>

fn calculateHash(b: Block): Hash
fn newBlock(index: Int64, previousHash: Hash, txs: List<Transaction>, difficulty: Int32): Block
```

## Technische Implementierungshinweise

### newTransaction

```lyx
fn newTransaction(senderPublicKey, receiverAddress, amount, fee, nonce):
    senderAddress = sha256(senderPublicKey)
    return Transaction{
        senderAddress   = senderAddress,
        senderPublicKey = senderPublicKey,
        receiverAddress = receiverAddress,
        amount          = amount,
        fee             = fee,
        nonce           = nonce,
        timestamp       = currentTimeNanos(),
        signature       = Bytes.zeros(64)   // wird nach Erstellen gesetzt
    }
```

### newCoinbaseTx

Coinbase-Transaktionen haben keinen Sender. Sie werden durch `senderAddress == zeros(32)` identifiziert. Damit sie pro Block einzigartig sind (verhindert Hash-Kollisionen im Merkle-Tree), wird `nonce = blockIndex` gesetzt.

```lyx
fn newCoinbaseTx(receiverAddress, amount, blockIndex):
    return Transaction{
        senderAddress   = Bytes.zeros(32),
        senderPublicKey = Bytes.zeros(33),
        receiverAddress = receiverAddress,
        amount          = amount,
        fee             = 0,
        nonce           = blockIndex,
        timestamp       = currentTimeNanos(),
        signature       = Bytes.zeros(64)
    }

fn isCoinbase(tx):
    return tx.senderAddress == Bytes.zeros(32)
```

### signingPayload

```lyx
fn signingPayload(tx):
    return serializeTxPayload(tx)   // ohne signature-Feld
```

Der zurückgegebene Hash **muss** vor dem Signieren durch SHA-256 gejagt werden:
```lyx
payload = sha256(tx.signingPayload())   // 32-Byte-Hash
tx.signature = ecdsaSign(privateKey, payload)
```

### newBlock

`newBlock` setzt `hash` noch nicht — es wird nach dem PoW-Loop in `minePendingTransactions` gesetzt.

```lyx
fn newBlock(index, previousHash, txs, difficulty):
    root = merkleRoot(txs)
    return Block{
        index        = index,
        timestamp    = currentTimeNanos(),
        previousHash = previousHash,
        merkleRoot   = root,
        nonce        = 0,
        difficulty   = difficulty,
        hash         = Bytes.zeros(32),   // noch nicht gesetzt
        transactions = txs
    }
```

### calculateHash

```lyx
fn calculateHash(b: Block): Hash
    return sha256(serializeBlockHeader(b))
```

## Testfälle

### isCoinbase

```
cb = newCoinbaseTx(minerAddr, 50 * BASE_UNIT, 1)
assert isCoinbase(cb) == true

tx = newTransaction(pubKey, receiverAddr, 10 * BASE_UNIT, 1000, 0)
assert isCoinbase(tx) == false
```

### signingPayload-Größe

```
tx = newTransaction(pubKey33, addr32, 1_000_000, 0, 0)
assert sha256(tx.signingPayload()).length == 32
```

### calculateHash-Determinismus

```
b = newBlock(1, previousHash, [tx1], 4)
h1 = calculateHash(b)
h2 = calculateHash(b)
assert h1 == h2
assert h1.length == 32
```

### calculateHash-Sensitivität

```
b1 = newBlock(1, previousHash, [tx1], 4)
b2 = b1 with nonce = b1.nonce + 1
assert calculateHash(b1) != calculateHash(b2)

b3 = b1 with index = 2
assert calculateHash(b1) != calculateHash(b3)
```

### Coinbase-Einzigartigkeit pro Block

```
cb1 = newCoinbaseTx(minerAddr, 50 * BASE_UNIT, 1)
cb2 = newCoinbaseTx(minerAddr, 50 * BASE_UNIT, 2)
assert txHash(cb1) != txHash(cb2)   // blockIndex sorgt für Unterschied
```

## Akzeptanzkriterien

- [ ] `isCoinbase(newCoinbaseTx(...))` == `true`
- [ ] `isCoinbase(newTransaction(...))` == `false`
- [ ] `newTransaction(pk, ...)`.senderAddress == `sha256(pk)`
- [ ] `signingPayload(tx)` enthält **nicht** das `signature`-Feld
- [ ] `sha256(signingPayload(tx))` hat Länge 32
- [ ] `calculateHash(b)` hat Länge 32
- [ ] Zwei Blöcke mit verschiedener `nonce` haben verschiedene Hashes
- [ ] Zwei Blöcke mit verschiedenem `index` haben verschiedene Hashes
- [ ] Zwei Coinbase-TXs mit verschiedenem `blockIndex` haben verschiedene `txHash`-Werte
- [ ] `BASE_UNIT == 1_000_000`

---

---

# WP-BL-04: Ledger

## Ziel

Implementierung des Account-basierten Zustandsmodells. Der Ledger verwaltet Kontostände und Sender-Nonces für alle Adressen. Er ist die einzige Quelle der Wahrheit über aktuelle Guthaben. Alle Zustandsänderungen erfolgen immutabel: Jede Funktion gibt einen neuen Ledger zurück, anstatt in-place zu mutieren.

## Abhängigkeiten

- WP-BL-03 (`Transaction`, `isCoinbase`, `Address`, `Hash`)

## Nicht im Umfang

- UTXO-Modell — v2.0
- Persistenz (Speichern auf Disk) — v2.0
- State-Snapshots / Checkpoints — v2.0

## Zu implementierende Symbole

```lyx
struct AccountState
    balance: Int64   // in BASE_UNITs, immer >= 0
    nonce:   Int64   // nächste erwartete TX-Nonce; startet bei 0

struct Ledger
    accounts: Map<Address, AccountState>

fn newLedger(): Ledger
fn newLedgerWithBalances(initial: List<(Address, Int64)>): Ledger

fn getBalance(l: Ledger, addr: Address): Int64
fn getNonce(l: Ledger, addr: Address): Int64

fn applyTransaction(l: Ledger, tx: Transaction): Result<Ledger, String>
fn applyBlock(l: Ledger, b: Block): Result<Ledger, String>
```

## Technische Implementierungshinweise

### Immutabilität

Der Ledger darf nie in-place mutiert werden. `applyTransaction` gibt bei Erfolg einen neuen `Ledger`-Wert zurück. Falls ein Block mehrere Transaktionen enthält und eine mittendrin fehlschlägt, wird der gesamte Block abgelehnt — der ursprüngliche Ledger bleibt unverändert.

### getBalance / getNonce — Default für unbekannte Adressen

```lyx
fn getBalance(l, addr):
    state = l.accounts.get(addr)
    if state == null: return 0
    return state.balance

fn getNonce(l, addr):
    state = l.accounts.get(addr)
    if state == null: return 0
    return state.nonce
```

### applyTransaction — Validierungsreihenfolge

```lyx
fn applyTransaction(l, tx):
    if isCoinbase(tx):
        // Nur Receiver gutschreiben, kein Sender-Check
        return Ok(creditAccount(l, tx.receiverAddress, tx.amount))

    // 1. Nonce prüfen
    expectedNonce = getNonce(l, tx.senderAddress)
    if tx.nonce != expectedNonce:
        return Err("Nonce-Fehler: erwartet " + expectedNonce + ", erhalten " + tx.nonce)

    // 2. Beträge >= 0 (strukturelle Invariante, hier nochmals prüfen)
    if tx.amount < 0 or tx.fee < 0:
        return Err("Negativer Betrag")

    // 3. Guthaben prüfen
    required = tx.amount + tx.fee
    if getBalance(l, tx.senderAddress) < required:
        return Err("Ungenügendes Guthaben: hat " + getBalance(l, tx.senderAddress)
                   + ", benötigt " + required)

    // 4. Zustand aktualisieren (immutabel)
    l2 = debitAccount(l,  tx.senderAddress,   tx.amount + tx.fee)
    l3 = creditAccount(l2, tx.receiverAddress, tx.amount)
    l4 = incrementNonce(l3, tx.senderAddress)
    return Ok(l4)
```

**Hinweis zur Fee-Logik:** Die Coinbase-TX wird immer als **erste** Transaktion im Block gespeichert und als erstes angewendet. Sie gutschreibt dem Miner `miningReward + sum(fees)`. Die anschließenden normalen TXs buchen `amount + fee` vom Sender ab; `amount` geht an den Receiver, `fee` "verschwindet" (wurde bereits via Coinbase an den Miner gutgeschrieben). Netto: Geldmenge steigt pro Block genau um `miningReward`.

### applyBlock — Atomarität

```lyx
fn applyBlock(l, b):
    current = l
    for tx in b.transactions:
        match applyTransaction(current, tx):
            Ok(next) => current = next
            Err(msg) => return Err("Block " + b.index + " TX-Fehler: " + msg)
    return Ok(current)
```

### Hilfsfunktionen

```lyx
fn creditAccount(l, addr, amount):
    old = l.accounts.get(addr) ?? AccountState{balance=0, nonce=0}
    new = AccountState{balance = old.balance + amount, nonce = old.nonce}
    return Ledger{accounts = l.accounts.set(addr, new)}

fn debitAccount(l, addr, amount):
    old = l.accounts.get(addr)   // muss existieren (vorher Balance-Check)
    new = AccountState{balance = old.balance - amount, nonce = old.nonce}
    return Ledger{accounts = l.accounts.set(addr, new)}

fn incrementNonce(l, addr):
    old = l.accounts.get(addr)
    new = AccountState{balance = old.balance, nonce = old.nonce + 1}
    return Ledger{accounts = l.accounts.set(addr, new)}
```

## Testfälle

### Initialzustand

```
l = newLedger()
assert getBalance(l, anyAddr) == 0
assert getNonce(l, anyAddr) == 0
```

### Coinbase

```
l = newLedger()
l2 = applyTransaction(l, newCoinbaseTx(minerAddr, 50 * BASE_UNIT, 1)).unwrap()
assert getBalance(l2, minerAddr) == 50 * BASE_UNIT
assert getNonce(l2, minerAddr) == 0   // Coinbase ändert keine Nonce
```

### Normale Transaktion

```
// Setup: Alice hat 100 Coins
l = newLedgerWithBalances([(aliceAddr, 100 * BASE_UNIT)])
tx = Transaction{..., senderAddress=aliceAddr, receiverAddress=bobAddr,
                 amount=25*BASE_UNIT, fee=1000, nonce=0, ...}

l2 = applyTransaction(l, tx).unwrap()
assert getBalance(l2, aliceAddr) == 75 * BASE_UNIT - 1000   // 100 - 25 - fee
assert getBalance(l2, bobAddr)   == 25 * BASE_UNIT
assert getNonce(l2, aliceAddr)   == 1
```

### Nonce-Fehler (Replay-Angriff)

```
l = newLedgerWithBalances([(aliceAddr, 100 * BASE_UNIT)])
tx_nonce0 = Transaction{..., nonce=0, ...}
l2 = applyTransaction(l, tx_nonce0).unwrap()

// Dieselbe TX nochmals einreichen → Nonce jetzt falsch
result = applyTransaction(l2, tx_nonce0)
assert result.isErr()
assert result.errMsg contains "Nonce"
```

### Ungenügendes Guthaben

```
l = newLedgerWithBalances([(aliceAddr, 10 * BASE_UNIT)])
tx = Transaction{..., amount=50*BASE_UNIT, fee=0, nonce=0, ...}
result = applyTransaction(l, tx)
assert result.isErr()
assert result.errMsg contains "Guthaben"
```

### Atomarität von applyBlock

```
l = newLedgerWithBalances([(aliceAddr, 10 * BASE_UNIT)])
validTx   = Transaction{amount=5*BASE_UNIT, fee=0, nonce=0, ...}   // gültig
invalidTx = Transaction{amount=50*BASE_UNIT, fee=0, nonce=1, ...}  // zu wenig Guthaben

block = Block{transactions=[coinbase, validTx, invalidTx], ...}
result = applyBlock(l, block)
assert result.isErr()
assert getBalance(l, aliceAddr) == 10 * BASE_UNIT   // Original-Ledger unverändert
```

### Fee-Netto-Invariante

```
// Gesamtguthaben vor und nach einem Block: ändert sich nur um miningReward
totalBefore = getBalance(l, aliceAddr) + getBalance(l, bobAddr) + getBalance(l, minerAddr)
l2 = applyBlock(l, block).unwrap()
totalAfter  = getBalance(l2, aliceAddr) + getBalance(l2, bobAddr) + getBalance(l2, minerAddr)
assert totalAfter == totalBefore + miningReward
```

## Akzeptanzkriterien

- [ ] `getBalance(newLedger(), anyAddr)` == 0
- [ ] `getNonce(newLedger(), anyAddr)` == 0
- [ ] Coinbase: Receiver-Balance steigt um `amount`, Nonce unverändert
- [ ] Normale TX: Sender-Balance sinkt um `amount + fee`, Receiver steigt um `amount`, Sender-Nonce steigt um 1
- [ ] TX mit falscher Nonce gibt `Err("Nonce...")`
- [ ] TX mit ungenügendem Guthaben gibt `Err("Guthaben...")`
- [ ] TX mit negativem `amount` gibt `Err`
- [ ] `applyBlock` ist atomar: schlägt eine TX fehl, bleibt der Ledger unverändert
- [ ] Netto-Invariante: Gesamtguthaben steigt pro Block genau um `miningReward`
- [ ] Kein In-place-Mutieren: ursprünglicher Ledger nach `applyTransaction` unverändert

---

---

# WP-BL-05: Consensus

## Ziel

Implementierung der `Blockchain`-Klasse als zentralem Einstiegspunkt für Entwickler. Sie vereint Kette, Ledger und Mempool und stellt Methoden für Transaktionseinreichung, Mining, Difficulty-Anpassung und Kettenvalidierung bereit.

## Abhängigkeiten

- WP-BL-01 (`sha256`, `ecdsaVerify`, Typen)
- WP-BL-02 (`serializeTxPayload`)
- WP-BL-03 (`Transaction`, `Block`, `newBlock`, `newCoinbaseTx`, `calculateHash`, `isCoinbase`)
- WP-BL-04 (`Ledger`, `applyBlock`, `getNonce`, `getBalance`)

## Nicht im Umfang

- Netzwerkkommunikation — WP-BL-06
- Proof-of-Stake — v2.0
- Persistenz auf Disk — v2.0

## Zu implementierende Symbole

```lyx
const DIFFICULTY_ADJUSTMENT_INTERVAL: Int32 = 10
const BLOCK_TARGET_TIME_NS: Int64 = 10_000_000_000   // 10 Sekunden in Nanosekunden
const MIN_DIFFICULTY: Int32 = 1
const MAX_DIFFICULTY_FACTOR: Int32 = 4

struct BlockchainConfig
    difficulty:    Int32
    miningReward:  Int64
    maxTxPerBlock: Int32
    genesisBalances: List<(Address, Int64)>   // Initial Distribution; leer = OK

struct Blockchain
    chain:               List<Block>
    ledger:              Ledger
    pendingTransactions: List<Transaction>
    config:              BlockchainConfig

fn newBlockchain(cfg: BlockchainConfig): Blockchain

fn addTransaction(bc: Blockchain, tx: Transaction): Result<Blockchain, String>
fn minePendingTransactions(bc: Blockchain, minerAddress: Address): Result<(Blockchain, Block), String>
fn isValidChain(bc: Blockchain): Result<Ledger, String>
fn getBalance(bc: Blockchain, addr: Address): Int64
fn getNonce(bc: Blockchain, addr: Address): Int64
fn chainLength(bc: Blockchain): Int64
```

## Technische Implementierungshinweise

### newBlockchain — Genesis-Block

```lyx
fn newBlockchain(cfg):
    ledger = newLedgerWithBalances(cfg.genesisBalances)
    genesis = Block{
        index        = 0,
        timestamp    = 0,            // Timestamp 0 ist kanonisch für Genesis
        previousHash = Bytes.zeros(32),
        merkleRoot   = merkleRoot([]),
        nonce        = 0,
        difficulty   = cfg.difficulty,
        transactions = [],
        hash         = ?             // wird unten gesetzt
    }
    genesis.hash = calculateHash(genesis)
    return Blockchain{chain=[genesis], ledger=ledger, pendingTransactions=[], config=cfg}
```

### addTransaction — 6 Prüfschritte

```lyx
fn addTransaction(bc, tx):
    // 1. Public Key zur Adresse passend?
    if sha256(tx.senderPublicKey) != tx.senderAddress:
        return Err("PublicKey passt nicht zur Adresse")

    // 2. Signatur gültig?
    payload = sha256(serializeTxPayload(tx))
    if not ecdsaVerify(tx.senderPublicKey, payload, tx.signature):
        return Err("Ungültige Signatur")

    // 3. Nonce korrekt?
    if tx.nonce != getNonce(bc, tx.senderAddress):
        return Err("Falsche Nonce")

    // 4. Beträge nicht negativ?
    if tx.amount < 0 or tx.fee < 0:
        return Err("Negativer Betrag")

    // 5. Guthaben ausreichend?
    if getBalance(bc, tx.senderAddress) < tx.amount + tx.fee:
        return Err("Ungenügendes Guthaben")

    // 6. Noch nicht im Mempool (Deduplizierung via TX-Hash)?
    txH = txHash(tx)
    for p in bc.pendingTransactions:
        if txHash(p) == txH: return Err("Transaktion bereits im Mempool")

    return Ok(Blockchain{...bc, pendingTransactions = bc.pendingTransactions + [tx]})
```

### minePendingTransactions — PoW-Loop

```lyx
fn minePendingTransactions(bc, minerAddress):
    // 1. Transaktionen nach Fee sortiert auswählen
    selected = bc.pendingTransactions
                 .sortBy(tx => 0 - tx.fee)   // absteigend
                 .take(bc.config.maxTxPerBlock)

    // 2. Coinbase erstellen
    totalFees = selected.sum(tx => tx.fee)
    coinbase  = newCoinbaseTx(minerAddress,
                              bc.config.miningReward + totalFees,
                              bc.chain.last().index + 1)

    // 3. Block aufbauen
    allTxs   = [coinbase] + selected
    newIndex = bc.chain.last().index + 1
    newBlock = newBlock(newIndex, bc.chain.last().hash, allTxs, bc.config.difficulty)

    // 4. PoW-Loop
    while not meetsTarget(calculateHash(newBlock), newBlock.difficulty):
        newBlock.nonce = newBlock.nonce + 1
    newBlock.hash = calculateHash(newBlock)

    // 5. Ledger fortschreiben
    newLedger = applyBlock(bc.ledger, newBlock)?

    // 6. Kette anhängen, Mempool bereinigen
    newChain   = bc.chain + [newBlock]
    newMempool = bc.pendingTransactions.removeAll(selected)

    // 7. Difficulty anpassen
    newDifficulty = adjustDifficulty(newChain, bc.config)

    newConfig = BlockchainConfig{...bc.config, difficulty = newDifficulty}
    newBc = Blockchain{chain=newChain, ledger=newLedger,
                       pendingTransactions=newMempool, config=newConfig}
    return Ok((newBc, newBlock))
```

### meetsTarget — Definition

```lyx
fn meetsTarget(hash: Hash, difficulty: Int32): Boolean
    // difficulty = Anzahl führender Null-Bytes im Hash
    for i = 0 to difficulty - 1:
        if hash[i] != 0: return false
    return true
```

Beispiel: `difficulty=2` → `hash[0] == 0 AND hash[1] == 0`. Ein SHA-256-Hash mit 2 führenden Null-Bytes hat einen Erwartungswert von ~65536 Versuchen.

### adjustDifficulty

```lyx
fn adjustDifficulty(chain: List<Block>, cfg: BlockchainConfig): Int32
    if chain.length % DIFFICULTY_ADJUSTMENT_INTERVAL != 0:
        return cfg.difficulty   // noch kein Anpassungspunkt

    intervalStart = chain[chain.length - DIFFICULTY_ADJUSTMENT_INTERVAL]
    intervalEnd   = chain.last()
    timeTaken     = intervalEnd.timestamp - intervalStart.timestamp
    expectedTime  = BLOCK_TARGET_TIME_NS * DIFFICULTY_ADJUSTMENT_INTERVAL

    if timeTaken == 0: timeTaken = 1   // Division-by-Zero-Schutz

    // Ratio: < 1 = zu schnell → erhöhe Difficulty; > 1 = zu langsam → senke
    // new = old * expectedTime / timeTaken  (ganzzahlig)
    newDiff = (cfg.difficulty * expectedTime) / timeTaken

    // Clamp: max. Faktor 4 Änderung pro Intervall
    maxUp   = cfg.difficulty * MAX_DIFFICULTY_FACTOR
    maxDown = cfg.difficulty / MAX_DIFFICULTY_FACTOR
    if maxDown < MIN_DIFFICULTY: maxDown = MIN_DIFFICULTY

    newDiff = clamp(newDiff, maxDown, maxUp)
    if newDiff < MIN_DIFFICULTY: newDiff = MIN_DIFFICULTY
    return newDiff
```

### isValidChain

```lyx
fn isValidChain(bc):
    chain = bc.chain
    if chain.isEmpty(): return Err("Leere Kette")

    // Genesis-Block prüfen (rekonstruieren und vergleichen)
    expected = newBlockchain(bc.config).chain[0]
    if chain[0].hash != expected.hash:
        return Err("Ungültiger Genesis-Block")

    replayLedger = newLedgerWithBalances(bc.config.genesisBalances)

    for i = 1 to chain.length - 1:
        b    = chain[i]
        prev = chain[i - 1]

        // Hash-Integrität
        if b.hash != calculateHash(b):
            return Err("Hash-Mismatch Block " + i)

        // Kettenverbindung
        if b.previousHash != prev.hash:
            return Err("Broken Link Block " + i)

        // Merkle-Root
        if b.merkleRoot != merkleRoot(b.transactions):
            return Err("Merkle-Mismatch Block " + i)

        // PoW gegen im Block gespeicherte Difficulty
        if not meetsTarget(b.hash, b.difficulty):
            return Err("PoW-Violation Block " + i)

        // Ledger-State fortschreiben (prüft auch alle TX-Signaturen und Nonces)
        match applyBlock(replayLedger, b):
            Ok(next) => replayLedger = next
            Err(msg) => return Err("Ledger-Fehler Block " + i + ": " + msg)

    return Ok(replayLedger)
```

## Testfälle

### Genesis-Block

```
bc = newBlockchain(BlockchainConfig{difficulty=1, miningReward=50*BASE_UNIT, ...})
assert chainLength(bc) == 1
assert bc.chain[0].index == 0
assert bc.chain[0].previousHash == zeros(32)
assert bc.chain[0].hash == calculateHash(bc.chain[0])
assert isValidChain(bc).isOk()
```

### Mining erzeugt gültigen Block

```
// Alice hat Guthaben, reicht TX ein, Bob mined
(bc2, block) = minePendingTransactions(bc, bobAddr).unwrap()
assert block.index == 1
assert block.previousHash == bc.chain[0].hash
assert meetsTarget(block.hash, block.difficulty) == true
assert block.hash == calculateHash(block)
assert block.merkleRoot == merkleRoot(block.transactions)
assert isValidChain(bc2).isOk()
```

### addTransaction — Replay wird abgelehnt

```
(bc2, _) = minePendingTransactions(bc_with_tx, minerAddr).unwrap()
// Dieselbe TX (gleiche Nonce) nochmals einreichen
result = addTransaction(bc2, originalTx)
assert result.isErr()   // Nonce falsch (wurde bereits inkrementiert)
```

### isValidChain erkennt Manipulation

```
// Block-Inhalt nachträglich ändern
bc2 = bc mit bc.chain[1].transactions[0].amount = 9999 * BASE_UNIT
// hash nicht neu berechnen → Mismatch
assert isValidChain(bc2).isErr()
```

### Difficulty-Anpassung

```
// 10 Blöcke sehr schnell hintereinander minen (simulierter Timestamp)
// → difficulty sollte nach Block 10 steigen
cfg = BlockchainConfig{difficulty=2, ...}
bc  = newBlockchain(cfg)
// ... mine 10 Blöcke mit sehr kleinen Timestamp-Abständen
assert bc_after_10.config.difficulty > 2
```

### Fee-Verteilung

```
tx = Transaction{amount=10*BASE_UNIT, fee=5000, nonce=0, ...}
bc2 = addTransaction(bc, tx).unwrap()
(bc3, _) = minePendingTransactions(bc2, minerAddr).unwrap()

// Miner hat: miningReward + fee
assert getBalance(bc3, minerAddr) == 50*BASE_UNIT + 5000
// Sender hat: initialBalance - amount - fee
assert getBalance(bc3, senderAddr) == initialBalance - 10*BASE_UNIT - 5000
// Receiver hat: amount
assert getBalance(bc3, receiverAddr) == 10*BASE_UNIT
```

## Akzeptanzkriterien

- [ ] Genesis-Block: `index=0`, `previousHash=zeros(32)`, `hash==calculateHash(genesis)`
- [ ] `isValidChain` auf frischer leerer Chain: `Ok`
- [ ] `minePendingTransactions` erzeugt Block, dessen Hash `meetsTarget(hash, difficulty)` erfüllt
- [ ] Gemintem Block: `hash == calculateHash(block)` und `merkleRoot` korrekt
- [ ] `addTransaction` mit falscher Signatur: `Err`
- [ ] `addTransaction` mit falscher Nonce: `Err`
- [ ] `addTransaction` mit ungenügendem Guthaben: `Err`
- [ ] `addTransaction` mit duplizierten TX (gleicher Hash): `Err`
- [ ] `isValidChain` nach Manipulation eines TX-Betrags: `Err("Hash-Mismatch...")`
- [ ] `isValidChain` nach Manipulation von `previousHash`: `Err("Broken Link...")`
- [ ] Fee-Netto-Invariante: Gesamtguthaben steigt pro Block genau um `miningReward`
- [ ] `adjustDifficulty` erhöht Difficulty bei zu schnellen Blöcken
- [ ] `adjustDifficulty` senkt Difficulty bei zu langsamen Blöcken
- [ ] `adjustDifficulty` ändert Difficulty nie um mehr als Faktor 4
- [ ] Difficulty fällt nie unter `MIN_DIFFICULTY = 1`

---

---

# WP-BL-06: std/blockchain/p2p (Optionales Modul)

## Ziel

Implementierung eines TCP-basierten P2P-Layers, der aus einer lokalen `Blockchain`-Instanz ein verteiltes Netzwerk macht. Dieses Modul ist optional — `std/blockchain` funktioniert vollständig ohne es. Das Modul definiert ein binäres Nachrichtenprotokoll, das denselben `Serializer` wie der Kern verwendet, um einen zweiten Serialisierungspfad zu vermeiden.

## Abhängigkeiten

- WP-BL-05 (vollständige `Blockchain`-Klasse)
- WP-BL-02 (`Serializer`, plus ein neues `Deserializer`-Submodul)
- **Syscalls:** `socket`, `bind`, `listen`, `accept`, `connect`, `send`, `recv`, `close`, `epoll_create1`, `epoll_ctl`, `epoll_wait` (Non-blocking I/O)

## Nicht im Umfang

- Peer-Discovery-Protokoll (DHT, DNS seeds) — v2.0
- TLS-Verschlüsselung der P2P-Verbindungen — v2.0
- NAT-Traversal — v2.0
- WebSocket-Transport — v2.0

## Zu implementierende Symbole

### Serializer-Erweiterung: Deserializer

```lyx
fn deserializeInt32(b: Bytes, offset: Int32): (Int32, Int32)   // (Wert, neuer Offset)
fn deserializeInt64(b: Bytes, offset: Int32): (Int64, Int32)
fn deserializeBytes(b: Bytes, offset: Int32): (Bytes, Int32)   // liest Länge-Präfix
fn deserializeTxFull(b: Bytes, offset: Int32): (Transaction, Int32)
fn deserializeBlockHeader(b: Bytes, offset: Int32): (Block, Int32)  // ohne transactions
fn deserializeBlock(b: Bytes, offset: Int32): (Block, Int32)
```

### P2P-Modul

```lyx
const MSG_QUERY_LATEST:   UInt8 = 0x01
const MSG_RESPONSE_LATEST: UInt8 = 0x02
const MSG_QUERY_CHAIN:    UInt8 = 0x03
const MSG_RESPONSE_CHAIN: UInt8 = 0x04
const MSG_BROADCAST_TX:   UInt8 = 0x05
const MSG_BROADCAST_BLOCK: UInt8 = 0x06

struct Node
    blockchain:  Blockchain
    peers:       List<String>    // "host:port"
    listenPort:  Int32
    connections: Map<String, Int32>   // peer -> file-descriptor

fn newNode(bc: Blockchain, listenPort: Int32, peers: List<String>): Node
fn startNode(node: Node): Node           // startet TCP-Server, verbindet zu Peers
fn stopNode(node: Node)
fn broadcastTransaction(node: Node, tx: Transaction): Node
fn broadcastBlock(node: Node, b: Block): Node
fn connectToPeer(node: Node, address: String): Result<Node, String>
```

## Technische Implementierungshinweise

### Nachrichtenformat (binär, length-prefixed)

```
[1 Byte]  Nachrichtentyp (MSG_*)
[4 Byte]  Payload-Länge in Bytes (Big-Endian UInt32)
[N Byte]  Payload (serialisiert via Serializer)
```

Minimale Nachrichtengröße: 5 Byte (Type + Length, Payload-Länge 0).

### Payload-Format pro Nachrichtentyp

| Typ | Payload |
|---|---|
| `MSG_QUERY_LATEST` | leer (0 Byte) |
| `MSG_RESPONSE_LATEST` | `serializeBlockHeader(lastBlock)` |
| `MSG_QUERY_CHAIN` | `serializeInt64(fromIndex)` |
| `MSG_RESPONSE_CHAIN` | `serializeInt32(count)` + N × `serializeBlock(block)` |
| `MSG_BROADCAST_TX` | `serializeTxFull(tx)` |
| `MSG_BROADCAST_BLOCK` | `serializeBlock(block)` = Header + `serializeInt32(txCount)` + N × `serializeTxFull(tx)` |

### TCP-Server (Non-Blocking via epoll)

```lyx
fn startNode(node):
    // Listening-Socket öffnen
    serverFd = socket(AF_INET=2, SOCK_STREAM=1, 0)
    // SO_REUSEADDR setzen
    setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, 1)
    bind(serverFd, sockaddr_in{port=node.listenPort})
    listen(serverFd, backlog=128)

    // epoll für non-blocking I/O
    epollFd = epoll_create1(0)
    epoll_ctl(epollFd, EPOLL_CTL_ADD, serverFd, EPOLLIN)

    // Zu bekannten Peers verbinden
    for peer in node.peers:
        connectToPeer(node, peer)

    // Event-Loop (läuft in separatem Thread / blockiert)
    loop:
        events = epoll_wait(epollFd, maxEvents=64, timeout=-1)
        for event in events:
            if event.fd == serverFd:
                clientFd = accept(serverFd, ...)
                epoll_ctl(epollFd, EPOLL_CTL_ADD, clientFd, EPOLLIN)
            else:
                handleIncomingData(node, event.fd)
```

### Konsensregeln bei eingehenden Nachrichten

**MSG_BROADCAST_BLOCK empfangen:**
```lyx
fn handleBroadcastBlock(node, b):
    last = node.blockchain.chain.last()

    // Direkt anschließend?
    if b.index == last.index + 1 and b.previousHash == last.hash:
        if not meetsTarget(b.hash, b.difficulty): return   // PoW ungültig
        if b.hash != calculateHash(b): return              // Hash manipuliert
        if b.merkleRoot != merkleRoot(b.transactions): return
        match applyBlock(node.blockchain.ledger, b):
            Ok(newLedger):
                node.blockchain = appendBlock(node.blockchain, b, newLedger)
                broadcastBlock(node, b)   // weiterleiten
            Err(_): return

    // Empfangener Block liegt weiter vorne → Chain anfordern
    else if b.index > last.index + 1:
        sendTo(node, sender, MSG_QUERY_CHAIN, serializeInt64(last.index))
```

**MSG_RESPONSE_CHAIN empfangen:**
```lyx
fn handleResponseChain(node, receivedChain):
    if receivedChain.length <= node.blockchain.chain.length: return   // nicht länger

    match isValidChain(receivedChain):
        Ok(replayedLedger):
            node.blockchain = replaceChain(node.blockchain, receivedChain, replayedLedger)
        Err(_): return   // ungültige Kette stillschweigend ignorieren
```

**MSG_BROADCAST_TX empfangen:**
```lyx
fn handleBroadcastTx(node, tx):
    match addTransaction(node.blockchain, tx):
        Ok(bc2):
            node.blockchain = bc2
            broadcastTransaction(node, tx)   // weiterleiten an andere Peers
        Err(_): return   // ungültige TX ignorieren
```

### Wichtig: Lyx-spezifische Hinweise

- `epoll_create1`, `epoll_ctl`, `epoll_wait` sind Linux-spezifische Syscalls — Stage-2-Build prüfen.
- Der Event-Loop muss entweder in einem separaten Lyx-Thread laufen oder als kooperatives Polling implementiert werden, je nach Thread-Support im Compiler zum Zeitpunkt der Implementierung.
- Alle Socket-Operationen sind blocking bis der epoll-Layer fertig ist; zunächst darf ein blocking TCP-Server als vereinfachte Variante implementiert werden.

## Testfälle

### Deserializer Round-Trip

```
tx = newTransaction(...)
bytes = serializeTxFull(tx)
(tx2, _) = deserializeTxFull(bytes, 0)
assert tx2.amount == tx.amount
assert tx2.fee    == tx.fee
assert tx2.nonce  == tx.nonce
assert tx2.senderAddress == tx.senderAddress
assert tx2.signature     == tx.signature
```

### Block Round-Trip

```
block = minedBlock
bytes = serializeBlock(block)
(block2, _) = deserializeBlock(bytes, 0)
assert block2.index       == block.index
assert block2.hash        == block.hash
assert block2.merkleRoot  == block.merkleRoot
assert block2.transactions.length == block.transactions.length
```

### Zwei-Node-Konsens (Integration)

```
nodeA = newNode(newBlockchain(cfg), port=9001, peers=[])
nodeB = newNode(newBlockchain(cfg), port=9002, peers=["127.0.0.1:9001"])

// A mined einen Block
(bcA, _) = minePendingTransactions(nodeA.blockchain, minerAddrA).unwrap()
nodeA.blockchain = bcA
broadcastBlock(nodeA, bcA.chain.last())

// Nach kurzer Zeit: B hat denselben Chain-State
// (bei synchronem Test: handleBroadcastBlock direkt aufrufen)
assert nodeB.blockchain.chain.length == 2
assert nodeB.blockchain.chain.last().hash == nodeA.blockchain.chain.last().hash
```

### Longest-Chain-Rule

```
// nodeB hat längere gültige Kette
// nodeA erhält RESPONSE_CHAIN mit B's Kette
// → nodeA ersetzt seine kürzere Kette
assert nodeA.blockchain.chain.length == nodeB.blockchain.chain.length
assert isValidChain(nodeA.blockchain).isOk()
```

### Ungültige Kette wird abgelehnt

```
// Manipulierte Kette: Block-Hash stimmt nicht
invalidChain = nodeB.blockchain.chain
invalidChain[1].transactions[0].amount = 9999 * BASE_UNIT
// hash NICHT neu berechnen

handleResponseChain(nodeA, invalidChain)
// nodeA behält seine eigene Kette
assert nodeA.blockchain.chain.length == originalLength
```

## Akzeptanzkriterien

- [ ] `deserializeTxFull(serializeTxFull(tx))` reproduziert alle Felder von `tx` exakt
- [ ] `deserializeBlock(serializeBlock(b))` reproduziert alle Header-Felder und alle TXs
- [ ] Zwei Nodes synchronisieren sich nach `broadcastBlock` auf denselben Chain-Zustand
- [ ] Node akzeptiert längere gültige Kette und ersetzt die eigene
- [ ] Node akzeptiert nicht-längere Kette **nicht** (gleich lang oder kürzer)
- [ ] Node akzeptiert manipulierte Kette (Hash-Mismatch) **nicht**
- [ ] `MSG_BROADCAST_TX`: ungültige TX wird nicht weitergeleitet
- [ ] `MSG_BROADCAST_BLOCK`: Block mit invalider PoW wird abgelehnt
- [ ] Nachrichtenformat: 1 Byte Type + 4 Byte Length-Prefix + Payload
- [ ] Verbindung zu nicht erreichbarem Peer gibt `Err`, kein Absturz

---

## Geplante Reihenfolge

```
WP-BL-01  →  WP-BL-02  →  WP-BL-03  →  WP-BL-04  →  WP-BL-05
                                                              ↓
                                                         WP-BL-06 (optional)
```

WP-BL-02 und WP-BL-03 können teilweise parallel entwickelt werden, wenn die Struct-Layouts vor Beginn beider WPs schriftlich fixiert werden (was dieses Dokument tut).
