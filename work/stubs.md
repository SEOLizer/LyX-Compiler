# std/ Stubs — Vollständiger Ausbaufahrplan

Dieses Dokument listet alle als Stub oder TODO markierten Stellen in den
`std/`-Units und beschreibt den Weg zur vollständigen Implementierung.

**Konvention:** WP-STB-NN. Status-Symbole: ✅ Erledigt, 🔄 In Arbeit, ⬜ Offen.

> **Pflicht:** Jeder WP wird in einem eigenen Feature-Branch bearbeitet und
> per PR auf `main` gemergt. Direkte Commits auf `main` sind nicht erlaubt.
> Branch-Schema: `feat/std-stubs-NN` (z. B. `feat/std-stubs-01`).

---

## 1. Übersicht

| WP | Datei(en) | Inhalt | Aufwand | Status |
|---|---|---|---|---|
| WP-STB-01 | `std/datetime.lyx` | 22 leere Funktionen: Format, Parse, Arithmetik, Timezone | L | ✅ |
| WP-STB-02 | `std/hash.lyx` | Echte BLAKE3-Implementierung (statt FNV-Stub) | M | ✅ |
| WP-STB-03 | `std/hash.lyx` | Echte SHA-3/Keccak-Sponge (statt FNV-Stub) | M | ✅ |
| WP-STB-04 | `std/url.lyx` | `GetQueryParam()` gibt immer `""` zurück | S | ✅ |
| WP-STB-05 | `std/net/socket.lyx` | `getPeerCredentials()` gibt immer `-1` zurück | S | ✅ |
| WP-STB-06 | `std/ini.lyx`, `std/yaml.lyx` | `LoadFile`/`SaveFile` (blockiert auf Syscalls) | S | ✅ |
| WP-STB-07 | `std/thread.lyx` | TLS: `TLSKeyCreate`, `TLSSet/GetValue` | M | ✅ |
| WP-STB-08 | `std/fasttext.lyx` | `SaveModel`/`LoadModel` + Vocab-Initialisierung | M | ✅ |
| WP-STB-09 | `std/lfd_parser.lyx` | Gesamte Datei ist Stub — Parser komplett fehlt | XL | ✅ |
| WP-STB-10 | `std/qt5_core.lyx` | 5 C++-Wrapper-Stubs (brauchen `libqtlyx.so`-Ergänzung) | M | ✅ |
| WP-STB-11 | `std/lyxvision/*.lyx` | 5 UI-TODOs (Event-Routing, StrLen, Buffer-Render, …) | M | ✅ |
| WP-STB-12 | `std/net/quic.lyx` | QUIC Verschlüsselungs-Längenfeld Placeholder | S | ✅ |
| WP-STB-13 | `std/svg/elements.lyx` | `_svgWinline` no-op Placeholder | XS | 🔄 |
| WP-STB-14 | `std/ini.lyx` | Set*/Delete*/GetSection* alle Stubs | M | ⬜ |
| WP-STB-15 | `std/db/mysql.lyx` | `MySQLPoolCreate/Destroy` Stubs | S | ⬜ |

Aufwand-Schätzung: XS < 1h · S = 1–2h · M = 3–6h · L = 1–2 Tage · XL = mehrere Tage

---

## 2. Work Packages

---

### WP-STB-01: `datetime.lyx` — Format / Parse / Arithmetik / Timezone ✅

**Branch:** `feat/std-stubs-01`
**Datei:** `std/datetime.lyx`

**Betroffene Funktionen (22 Stubs):**

| Gruppe | Funktionen |
|---|---|
| Formatierung | `Format()`, `FormatIso()`, `FormatRfc2822()`, `FormatLocale()` |
| Parsing | `ParseDate()`, `ParseTime()`, `ParseIso()`, `ParseRfc2822()`, `ParseFlexible()` |
| Relativ | `FormatRelative()` |
| Timezone | `GetTimezoneOffset()` |
| Kalender | `WeekNumber()` |
| Timestamp | `ToUnixTimestamp()`, `FromUnixTimestamp()`, `ToMilliseconds()`, `FromMilliseconds()` |
| Arithmetik | `AddSeconds()`, `AddDays()`, `AddMonths()`, `AddYears()`, `DiffSeconds()`, `DiffDays()` |

**Designannahme:**
Das `datetime`-Argument ist ein Unix-Timestamp (Sekunden seit Epoch) als `int64`.
`FromUnixTimestamp` / `ToUnixTimestamp` wandeln zwischen diesem und einem
internen packed struct um. Vor der Implementierung prüfen, ob `std.time` eine
`UnpackTime(ts) → {year, month, day, hour, min, sec}` Funktion hat — wenn ja,
darauf aufbauen.

**Implementierungshinweise:**

`Format(datetime, fmt, output)` — Zeichenweise durch `fmt` iterieren; bei `%`
den nächsten Buchstaben lesen und den entsprechenden Wert aus dem entpackten
Timestamp einsetzen. Bereits implementierte Helfer wie `FormatDate` und
`FormatTime` können intern aufgerufen werden.

`FormatIso(datetime, output)` — Schema `YYYY-MM-DDTHH:MM:SSZ` kann durch
Kombination von `FormatDate` + `FormatTime` aufgebaut werden.

`ParseDate(input, year, month, day)` — Achtung: `year`, `month`, `day` sind
Value-Parameter, keine Pointer. Die Signatur kann keine Out-Werte zurückgeben.
Entweder Signatur auf Pointer-Typ ändern (`year: int64` → Pointer via `poke64`)
oder den Parse-Ergebnis als gepackten int64 zurückgeben. Dieses Designproblem
**zuerst klären** bevor implementiert wird.

`GetTimezoneOffset()` — Via `clock_gettime(CLOCK_REALTIME)` und
`clock_gettime(CLOCK_REALTIME_COARSE)` lässt sich kein Offset ableiten.
Stattdessen: `getenv("TZ")` auswerten oder `/etc/localtime` Symlink auflesen.
Einfachster pragmatischer Ansatz: `gettimeofday()` (syscall 96) liefert
`struct timeval {tv_sec, tv_usec}` — kein TZ-Offset direkt. Alterntaiv:
syscall `settimeofday` nicht verwenden. Einfachste korrekte Lösung:
`localtime_r` via extern C, oder TZ-Variable via `StrSafeCharAt(getenv("TZ"))`.

`WeekNumber(year, month, day)` — ISO 8601: Tage seit 1. Januar berechnen,
dann Wochentag des 1. Januars bestimmen, ISO-Wochen-Arithmetik anwenden.

`AddDays/AddMonths/AddYears` — intern auf Unix-Timestamp-Level arbeiten:
`AddSeconds` ist trivial (`ts + n`); `AddDays` = `AddSeconds(ts, n*86400)`;
`AddMonths/AddYears` benötigt Entpacken → Monatsarithmetik → Wiederverpacken.

**Akzeptanzkriterien:**
- `FormatDate(2024, 1, 15, buf)` → `"2024-01-15"` (bereits implementiert ✅)
- `FormatIso(ts, buf)` → `"2024-01-15T14:30:00Z"`
- `FormatRfc2822(ts, buf)` → `"Mon, 15 Jan 2024 14:30:00 +0000"`
- `FormatRelative` für 3600s-alten TS → `"1 hour ago"`
- `AddDays(ts, 7)` → TS + 604800
- `DiffDays(2024,1,1, 2024,1,15)` → `14`
- `WeekNumber(2024, 1, 1)` → `1`
- `ToUnixTimestamp(FromUnixTimestamp(ts)) == ts`

---

### WP-STB-02: `hash.lyx` — Echte BLAKE3-Implementierung ✅

**Branch:** `feat/std-stubs-02`
**Datei:** `std/hash.lyx` (ab Zeile 584)

**Problem:** `HashBLAKE3`, `HashBLAKE3Bytes`, `HashBLAKE3Hex` benutzen intern
FNV-1a — kein kryptografischer Wert, falsche Hash-Länge (64 bit statt 256 bit).

**Implementierungshinweise:**
BLAKE3 basiert auf der ChaCha-Permutation. Kernbestandteile:
- G-Funktion (4 ARX-Runden über a/b/c/d)
- Compress-Funktion: 16-Wort-State, 7 Runden G
- Chaining Values (CV) aus 8× uint32 je Block
- Counter + Flags für Tree-Hashing

Lyx hat kein uint32 — alle Operationen auf `int64` mit `& 0xFFFFFFFF`-Masken.
Da Lyx keine Arrays von Locals unterstützt, den 16-Wort-State als explizite
Variablen `s0..s15` ausrollen (analog zu bestehenden SHA-256-Implementierungen
in der Codebase, falls vorhanden).

Ausgabe: 32 Byte = 256 Bit; `HashBLAKE3Hex` gibt 64 Hex-Zeichen zurück.
Für den einfachsten korrekten Einstieg: Single-Block-Input (≤ 64 Byte) mit
einem CV-Niveau ist ausreichend für die meisten use-cases.

**Akzeptanzkriterien:**
- `HashBLAKE3("")` → bekannter Referenzwert (BLAKE3 von leerem String = `af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262` → als int64 nicht direkt vergleichbar, stattdessen Test über Hex-String)
- `HashBLAKE3Hex("abc")` → identisch mit `b3/openssl`-Referenz
- Kein FNV-Fallback mehr im Code

---

### WP-STB-03: `hash.lyx` — Echte SHA-3/Keccak-Sponge ✅

**Branch:** `feat/std-stubs-03`
**Datei:** `std/hash.lyx` (ab Zeile 621)

**Problem:** `HashSHA3_224/256/512` sind nur `HashBLAKE3(data) ^ magic_const` —
keine kryptografische Eigenschaft.

**Implementierungshinweise:**
Keccak-p[1600,24] Sponge:
- State: 5×5×64-Bit Lane-Array (25 × int64). In Lyx ohne Arrays: 25 explizite
  Variablen `lane00..lane44`. Das ist repetitiv aber unkompliziert.
- θ (Theta), ρ (Rho), π (Pi), χ (Chi), ι (Iota) Runden — standardisierte
  Rundungskonstanten (64-Bit Keccak-RC).
- SHA3-256: `rate=1088 bit`, `capacity=512 bit`, Padding `0x06`.

Da 25 explizite State-Variablen und 24 Runden × 5 Schritte pro Runde sehr
viel Code ergeben: zuerst nur SHA3-256 implementieren und SHA3-224/512 als
Varianten mit unterschiedlichen rate/capacity Werten ablegen.

**Akzeptanzkriterien:**
- `HashSHA3_256Hex("abc")` → `3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532`
- Kein XOR-Magic-Stub mehr

---

### WP-STB-04: `url.lyx` — `GetQueryParam()` Substring-Extraktion ✅

**Branch:** `feat/std-stubs-04`
**Datei:** `std/url.lyx` (Zeile 871)

**Problem:** `GetQueryParam(query, name)` findet den Start-Index des Wertes
korrekt via `findQueryParamValue()`, kopiert aber nie den Substring — gibt
immer `""` zurück.

**Implementierungshinweise:**
```
// Pseudocode
var start: int64 := findQueryParamValue(query, name, name_len);
if (start < 0) { return ""; }
var end: int64 := start;
while (end < StrLen(query) && StrSafeCharAt(query, end) != 38) {  // '&'
    end := end + 1;
}
var len: int64 := end - start;
var result: pchar := alloc(len + 1);
var i: int64 := 0;
while (i < len) {
    StrSetChar(result, i, StrSafeCharAt(query, start + i));
    i := i + 1;
}
StrSetChar(result, len, 0);
return result;
```

`alloc` aus `std.alloc` importieren. Alternativ `StrSubstring` aus `std.string`
nutzen, falls vorhanden.

**Akzeptanzkriterien:**
- `GetQueryParam("foo=bar&baz=42", "foo")` → `"bar"`
- `GetQueryParam("foo=bar&baz=42", "baz")` → `"42"`
- `GetQueryParam("foo=bar", "missing")` → `""`
- `HasQueryParam` weiterhin korrekt (nicht anfassen)

---

### WP-STB-05: `net/socket.lyx` — `getPeerCredentials()` ✅

**Branch:** `feat/std-stubs-05`
**Datei:** `std/net/socket.lyx` (Zeile 1316)

**Problem:** `getPeerCredentials(fd)` gibt immer `-1` zurück.

**Implementierungshinweise:**
Linux: `getsockopt(sockfd, SOL_SOCKET, SO_PEERCRED, &ucred, &len)`
Syscall-Nummer: `getsockopt = 55`
`struct ucred { pid_t pid; uid_t uid; gid_t gid; }` (3 × int32 = 12 Byte)

```lyx
// ucred-Buffer: 12 Byte via alloc oder Stack-Simulation mit poke
var ucred_ptr: int64 := alloc(16);
var len_ptr: int64 := alloc(8);
poke64(len_ptr, 12);
var SOL_SOCKET: int64 := 1;
var SO_PEERCRED: int64 := 17;
var ret: int64 := syscall6(55, fd, SOL_SOCKET, SO_PEERCRED, ucred_ptr, len_ptr, 0);
if (ret < 0) { return -1; }
return peek32(ucred_ptr);  // pid als Rückgabe, oder gepacktes pid/uid/gid
```

Rückgabetyp und -format mit bestehendem Aufrufkontext abstimmen.

**Akzeptanzkriterien:**
- Auf einem Unix-Domain-Socket gibt `getPeerCredentials` die PID des Peers zurück
- Kein `return -1` mehr als Default

---

### WP-STB-06: `ini.lyx` + `yaml.lyx` — File I/O ✅

**Branch:** `feat/std-stubs-06`
**Dateien:** `std/ini.lyx` (Zeilen 354, 361, 411), `std/yaml.lyx` (Zeilen 245, 251)

**Problem:** `LoadFile` und `SaveFile` in beiden Units sind leere Stubs.
Comments-Unterstützung in `ini.lyx` ist ein Placeholder.

**Implementierungshinweise:**
Beide Units benötigen Datei-Lesen/-Schreiben. Dafür `std.os` oder direkte
Syscalls nutzen (open/read/write/close sind in `std/net/syscalls.lyx` oder
`std/os.lyx` vorhanden — prüfen welcher Import passt).

`ini.LoadFile(path)`:
1. Datei öffnen (open-Syscall oder `std.os.ReadFile`)
2. Inhalt als String einlesen
3. `ParseString(content)` aufrufen (sollte bereits implementiert sein)
4. Resultat-Handle zurückgeben

`ini.SaveFile(doc, path)`:
1. `ToString(doc)` aufrufen (sollte bereits implementiert sein)
2. String in Datei schreiben

`yaml.LoadFile` / `yaml.SaveFile`: identisches Schema.

`ini` Comments-Placeholder (Zeile 411): Kommentar-Zeilen (`; ...` oder `# ...`)
beim Parsen überspringen (gängige INI-Semantik) oder in einem separaten
`comment`-Puffer speichern, falls Round-Trip gewünscht.

**Akzeptanzkriterien:**
- `ini.LoadFile("test.ini")` lädt und parst die Datei; `GetString(doc, "section", "key")` gibt korrekten Wert zurück
- `ini.SaveFile(doc, "out.ini")` schreibt lesbare INI-Datei
- `yaml.LoadFile` / `yaml.SaveFile` analog
- Keine `return 0` / `return false` Stubs mehr

---

### WP-STB-07: `thread.lyx` — Thread-Local Storage (TLS) ✅

**Branch:** `feat/std-stubs-07`
**Datei:** `std/thread.lyx` (Zeilen 67, 298–300)

**Problem:** `TLSKeyCreate()`, `TLSSetValue()`, `TLSGetValue()` sind leere Stubs.

**Implementierungshinweise:**
Auf x86_64 Linux: FS-Segment zeigt auf die TLS-Arena des aktuellen Threads
(`arch_prctl(ARCH_SET_FS, ptr)`). Der einfachste portable Ansatz in Lyx ohne
Assembler-Inline:

**Option A (einfach):** Pro Thread einen kleinen TLS-Slot-Array im `SharedMem`
verwalten, indiziert über die Thread-ID (`gettid` = Syscall 186). Kein
echtes FS-Register nötig.

```
// Key = Index in einer globalen Slot-Tabelle
// Tabelle: thread_id → [value_0, value_1, ...]
// TLSKeyCreate() gibt nächsten freien Index zurück
// TLSSetValue(key, val) → poke64(tls_table + tid*MAX_KEYS*8 + key*8, val)
// TLSGetValue(key) → peek64(tls_table + tid*MAX_KEYS*8 + key*8)
```

**Option B (korrekt):** `arch_prctl(ARCH_SET_FS)` = Syscall 158 mit
Konstante `0x1002`. Braucht eigenen TLS-Block pro Thread und
ARCH_GET_FS (0x1003) zum Lesen. Komplexer, aber korrekt für echten TLS.

Empfehlung: Option A für Einstieg, in Kommentar auf Option B hinweisen.

**Akzeptanzkriterien:**
- `var key: TLSKey := TLSKeyCreate();` gibt gültigen Key (> 0) zurück
- `TLSSetValue(key, 42); TLSGetValue(key) == 42`
- Zwei Threads mit gleichem Key sehen verschiedene Werte

---

### WP-STB-08: `fasttext.lyx` — SaveModel / LoadModel + Vocab ✅

**Branch:** `feat/std-stubs-08`
**Datei:** `std/fasttext.lyx` (Zeilen 46, 342, 348)

**Problem:**
- `InitVocab()` (Zeile 46): Placeholder, würde Corpus tokenisieren
- `SaveModel(model, path)` (Zeile 342): Stub
- `LoadModel(path)` (Zeile 348): Stub

**Implementierungshinweise:**
FastText-Modell-Persistenz: Das Modell besteht aus dem Vokabular und den
Word-Vektoren. Binäres Format empfohlen (einfacher als FastText-nativer
`.bin`-Header).

`SaveModel`:
1. `open(path, O_WRONLY|O_CREAT|O_TRUNC)` via Syscall
2. Header schreiben: Vokabular-Größe + Embedding-Dimension (je int64, 8 Byte)
3. Für jeden Vokab-Eintrag: Länge + Wort + Vektor-Daten schreiben
4. Datei schließen

`LoadModel`:
1. Datei öffnen und Header lesen
2. Speicher allokieren (Vokabular-Array + Float-Matrix)
3. Einträge einlesen
4. Model-Handle zurückgeben

`InitVocab`: Corpus-String per Leerzeichen/Newline tokenisieren, Wörter in
Hashtabelle einpflegen, Frequenzen zählen, Seltenheiten mit `<UNK>` ersetzen.

**Akzeptanzkriterien:**
- Train → SaveModel → LoadModel → identische Vorhersagen
- `InitVocab("hello world hello")` → Vokabular mit 2 Einträgen, `hello` freq=2

---

### WP-STB-09: `lfd_parser.lyx` — Vollständige Parser-Implementierung ✅

**Branch:** `feat/std-stubs-09`
**Datei:** `std/lfd_parser.lyx`

**Problem:** Die Datei enthält nur Token-Kind-Konstanten und Typ-Definitionen —
alle Parser-Funktionen fehlen vollständig.

**Bestehende Struktur (vorhanden):**
- Token-Kind-Konstanten `LFD_TK_*` (0–30+)
- Node-Typ-Konstanten `LFD_NK_*`
- Struct-Definitionen: `LFDToken`, `LFDNode`, `LFDParser`
- Funktionssignaturen (ohne Body)

**Zu implementieren:**

1. **Lexer** (`lfdLex`): Eingabe-String zeichenweise scannen, Token erzeugen.
   LFD ist eine text-basierte DSL mit `form`, `layout`, `button` etc. als
   Keywords. Whitespace überspringen, String-Literals parsen, Zahlen parsen.

2. **Parser** (`lfdParse`): Recursive-Descent über Token-Stream.
   - Top-Level: `form { ... }`
   - Layout-Direktiven: `vertical/horizontal/grid { ... }`
   - Widget-Deklarationen: `button "label" { ... }`
   - Properties: `id: "foo"`, `width: 200`, etc.

3. **AST-Builder**: `LFDNode` erzeugen (Heap-alloziert), Kind-Listen via
   verkettete Liste (da Lyx keine Arrays von Structs unterstützt).

4. **Public API:**
   - `LFDParseString(input: pchar): int64` — gibt Root-Node-Pointer zurück
   - `LFDGetNodeType(node: int64): int64`
   - `LFDGetNodeChild(node: int64, index: int64): int64`
   - `LFDGetNodeText(node: int64): pchar`

**Hinweis:** Das ist das größte WP. Ggf. in Phasen aufteilen:
Phase A = Lexer + einfacher Parser (form/layout/button), Phase B = vollständige Property-Unterstützung.

**Akzeptanzkriterien:**
- `LFDParseString("form { button \"OK\" { } }")` → Root-Node mit Kind `LFD_TK_FORM`
- `LFDGetNodeType` / `LFDGetNodeChild` funktionieren korrekt
- Fehlerhafte Eingabe → `-1` statt Crash

---

### WP-STB-10: `qt5_core.lyx` — C++ Wrapper für STUBS-Block ✅

**Branch:** `feat/std-stubs-10`
**Dateien:** `std/qt5_core.lyx` (Zeile 451), `libqtlyx.so` (C++-Wrapper)

**Problem:** 5 Funktionen sind als Stubs markiert, weil sie Qt-C++-Objekte
benötigen die nicht über einen einfachen Syscall erreichbar sind:
- `QCoreApplicationExists()` — braucht `QCoreApplication::instance() != nullptr`
- `QCoreApplicationQuit()` — braucht `QCoreApplication::quit()`
- `QCoreApplicationProcessEvents()` — braucht `QCoreApplication::processEvents()`
- `QStringFromUtf8(ptr)` — QString ist C++-Klasse
- `QStringToUtf8(qs)` — dto.

**Implementierungshinweise:**
Alle 5 Funktionen als `extern fn ... link "libqtlyx.so"` deklarieren und die
C-Wrapper in der `libqtlyx.so` Quelle (C++-Datei) implementieren:

```cpp
extern "C" int64_t QCoreApplicationExists() {
    return QCoreApplication::instance() != nullptr ? 1 : 0;
}
extern "C" void QCoreApplicationQuit() {
    if (QCoreApplication::instance()) QCoreApplication::quit();
}
// usw.
```

`QStringFromUtf8` / `QStringToUtf8`: Da `QString` ein C++-Objekt ist, am
einfachsten als opaker Pointer (int64 = Heap-Adresse) mit
`new QString(str)` / `delete (QString*)ptr` behandeln.

**Akzeptanzkriterien:**
- `QCoreApplicationExists()` gibt `1` zurück wenn QApp läuft
- `QCoreApplicationQuit()` beendet die Event-Loop
- `QStringFromUtf8("hello")` → opaker Pointer, `QStringToUtf8(ptr)` → `"hello"`

---

### WP-STB-11: `lyxvision/` — Offene UI-TODOs ✅

**Branch:** `feat/std-stubs-11`
**Dateien:**
- `std/lyxvision/app.lyx:103`
- `std/lyxvision/tapplication.lyx:338`
- `std/lyxvision/terminal.lyx:162, 280`
- `std/lyxvision/window.lyx:103`

**Problem-Details:**

| Datei | Zeile | TODO |
|---|---|---|
| `app.lyx:103` | Event an aktuellen View weiterleiten fehlt |
| `tapplication.lyx:338` | Desktop-Children-Liste nicht befüllt |
| `terminal.lyx:162` | `// TODO: String-Length Funktion fehlt noch` |
| `terminal.lyx:280` | `// TODO: Buffer-Zeichen vom Hintergrund holen und anzeigen` |
| `window.lyx:103` | `// TODO: Alte Position wiederherstellen` |

**Implementierungshinweise:**

`app.lyx:103` — Event-Weiterleitung: Den aktuell fokussierten View via
`GetCurrentView()` holen und dessen `handleEvent(event)` aufrufen.

`tapplication.lyx:338` — Desktop-Children: beim Hinzufügen eines Fensters
das Fenster-Handle in eine verkettete Liste des Desktop-Objekts eintragen.

`terminal.lyx:162` — `StrLen` ist in `std.string` vorhanden: `import std.string`
ergänzen und `StrLen(s)` verwenden.

`terminal.lyx:280` — Buffer-Char-Render: Aus dem internen Zeichen-Buffer
(falls vorhanden) die Hintergrundfarbe und das Zeichen an Position (x,y) lesen
und zur Anzeige bringen.

`window.lyx:103` — Alte Position: `prev_x` / `prev_y` Felder im Window-Struct
ergänzen, vor dem Move speichern, im Restore-Branch wiederherstellen.

**Akzeptanzkriterien:**
- Kein TODO-Kommentar mehr in den genannten Zeilen
- `terminal.lyx` kompiliert ohne `StrLen`-Fehler
- Einfaches lyxvision-Demo läuft ohne Regression

---

### WP-STB-12: `net/quic.lyx` — QUIC Payload-Länge bei Verschlüsselung ✅

**Branch:** `feat/std-stubs-12`
**Datei:** `std/net/quic.lyx` (Zeile 320)

**Problem:** Das Längenfeld im QUIC-Paket-Header wird als Placeholder auf 0
gesetzt — statt die tatsächliche verschlüsselte Payload-Länge einzusetzen.

**Implementierungshinweise:**
QUIC (RFC 9000) Long-Header: das Längenfeld kodiert `Payload Length` als
variable-length integer (VarInt). Bei AES-AEAD-Verschlüsselung: Klartextlänge
+ 16 Byte AEAD-Tag.

Kurzfristig (ohne echte AEAD): Länge = Plaintextlänge, Feld korrekt als
VarInt einschreiben (1 Byte wenn < 64, 2 Byte wenn < 16384 mit `0x40`-Prefix).

Mittelfristig: AEAD-Integration (AES-128-GCM via `std/crypto/aes.lyu` prüfen
ob vorhanden).

**Akzeptanzkriterien:**
- QUIC Initial Packet hat korrektes Längenfeld
- Kein Placeholder-Kommentar mehr an Zeile 320

---

### WP-STB-13: `svg/elements.lyx` — `_svgWinline` no-op 🔄

**Branch:** `feat/std-stubs-13`
**Datei:** `std/svg/elements.lyx` (Zeile 459)

**Problem:** `_svgWinline(doc, SVG_FILL)` ist als `// no-op placeholder` markiert.

**Kontext prüfen:** Was soll `_svgWinline` tun? Wahrscheinlich ein
Inline-Style-Attribut (`fill: …`) in den SVG-Output schreiben. Falls SVG_FILL
eine Farbe oder ein Enum-Wert ist, den entsprechenden `fill="..."` Attribute-String
emittieren.

**Akzeptanzkriterien:**
- `_svgWinline` emittiert den korrekten SVG-Attribut-String
- Bestehende SVG-Output-Tests unverändert grün

---

---

### WP-STB-14: `ini.lyx` — Set* / Delete* / GetSection* Funktionen ⬜

**Branch:** `feat/std-stubs-14`
**Datei:** `std/ini.lyx` (ab Zeile 382)

**Problem:** 9 Funktionen sind leere Stubs mit `// Would ...`-Kommentaren:

| Funktion | Stub-Kommentar |
|---|---|
| `SetString(doc, section, key, value)` | `// Would add/update in internal structure` |
| `SetInt(doc, section, key, value)` | `// TODO: implement in-place text mutation` |
| `SetBool(doc, section, key, value)` | `// Would set "true" or "false"` |
| `SetFloat(doc, section, key, value)` | `// Would convert to string and set` |
| `DeleteKey(doc, section, key)` | `// Would delete from internal structure` |
| `DeleteSection(doc, section)` | `// Would delete section from internal structure` |
| `GetSectionNames(doc, out)` | `// Would write section names to output` |
| `GetSectionCount(doc)` | `// Would return count from internal structure` |
| `GetKeyNames(doc, section, out)` | `// Would write key names to output` |

**Implementierungshinweise:**
Das ini-Dokument wird als Raw-Text-Buffer (mmap) gespeichert. `SetString` muss
den Schlüssel im Buffer suchen (via `_iniFindKeyValue`) und entweder den Wert
in-place ersetzen (wenn gleich lang) oder den Buffer neu aufbauen (wenn die
Länge sich ändert). Einfachster Ansatz: Buffer-Rebuild — neuen mmap allozieren,
Abschnitt für Abschnitt kopieren und den geänderten Wert einsetzen.

`SetInt/SetBool/SetFloat`: Wert in pchar umwandeln (via IntToStr / "true"/"false" / float-Konvertierung) und dann `SetString` aufrufen.

`DeleteKey` / `DeleteSection`: Buffer-Rebuild ohne die betreffende Zeile/Sektion.

`GetSectionNames` / `GetKeyNames`: Linearer Scan durch den Buffer, Sektionsnamen (`[name]`) oder Schlüsselnamen in den `out`-Buffer schreiben.

`GetSectionCount`: Linearer Scan, Anzahl `[`-Zeilen zählen.

**Akzeptanzkriterien:**
- `SetString(doc, "db", "host", "localhost")` → `GetString(doc, "db", "host")` == `"localhost"`
- `SetInt(doc, "server", "port", 8080)` → `GetString(...)` == `"8080"`
- `DeleteKey(doc, "db", "host")` → `HasKey(doc, "db", "host")` == false
- `GetSectionCount(doc)` gibt korrekte Anzahl zurück

---

### WP-STB-15: `db/mysql.lyx` — Connection Pool ⬜

**Branch:** `feat/std-stubs-15`
**Datei:** `std/db/mysql.lyx` (ab Zeile 1786)

**Problem:** `MySQLPoolCreate` gibt immer 0 zurück, `MySQLPoolDestroy` ist leer.

**Implementierungshinweise:**
Ein Connection Pool hält eine Liste vorverbundener MySQL-Handles.
Minimale Implementierung:

```
// Pool-Layout im mmap-Block:
//   [0..7]   maxConnections (int64)
//   [8..15]  connCount (int64)
//   [16..]   connHandle[0..max-1] (int64 each)
MySQLPoolCreate(max):
  buf := mmap(0, 16 + max * 8, ...)
  poke64(buf, max)
  poke64(buf + 8, 0)
  return buf

MySQLPoolDestroy(pool):
  count := peek64(pool + 8)
  i := 0; while i < count: MySQLClose(peek64(pool + 16 + i*8)); i++
  munmap(pool, 16 + max * 8)
```

Zusätzlich `MySQLPoolAcquire(pool)` und `MySQLPoolRelease(pool, conn)` sinnvoll, falls noch nicht vorhanden.

**Akzeptanzkriterien:**
- `MySQLPoolCreate(5)` gibt gültigen Handle zurück (nicht 0)
- `MySQLPoolDestroy(pool)` schließt alle Verbindungen und gibt Speicher frei
- Kein `return 0` mehr als Stub

---

## 3. Meilensteine

| Meilenstein | WPs | Ergebnis |
|---|---|---|
| M1: Core stdlib vollständig | WP-STB-01, 04, 05, 06 | datetime, url, socket, ini/yaml funktional |
| M2: Crypto korrekt | WP-STB-02, WP-STB-03 | BLAKE3 + SHA-3 kein FNV-Stub mehr |
| M3: System-Features | WP-STB-07, WP-STB-08 | TLS + FastText I/O |
| M4: LFD-Parser | WP-STB-09 | lfd_parser vollständig |
| M5: UI & Qt | WP-STB-10, WP-STB-11 | lyxvision TODOs + Qt5-Wrapper |
| M6: Net & SVG | WP-STB-12, WP-STB-13 | QUIC-Länge + SVG inline |
| M7: Mutating I/O & DB | WP-STB-14, WP-STB-15 | ini Set/Delete + MySQL Pool |

---

## 4. Branch-Konvention

```
# Erstellen
git checkout -b feat/std-stubs-NN

# Abschluss
git push -u origin feat/std-stubs-NN
gh pr create --title "feat(std): WP-STB-NN — <kurze Beschreibung>"
```

Jeder Branch enthält **genau einen WP**. Mehrere WPs in einem Branch sind nur
erlaubt wenn sie strikt abhängig voneinander sind (z. B. WP-STB-02 + 03
können zusammengehen, da beide `hash.lyx` betreffen).

---

## 5. Changelog

| Datum | Änderung |
|---|---|
| 2026-05-23 | Initiale Erstellung — 13 WPs aus Stub-Audit |
| 2026-05-23 | WP-STB-01 ✅ — datetime.lyx vollständig. Zwei Bugs entdeckt: Off-by-one Jan/Feb (Hinnant-Algorithmus), negative Division in Lyx unsigned behandelt |
| 2026-05-23 | WP-STB-06 ✅ — ini.lyx + yaml.lyx: doc-Handle als Raw-Text-Buffer (mmap). _iniFindSection/_iniFindKeyValue Scanner. LoadFile/SaveFile über open/read/write/close Builtins. GetString/HasSection/HasKey/GetSectionCount real implementiert. |
| 2026-05-23 | WP-STB-07 ✅ — thread.lyx TLS: globale mmap-Tabelle (64 Slots × 32 Keys × 264 Bytes). _tlsInit/_tlsFindSlot. TLSKeyCreate/TLSSetValue/TLSGetValue via sys_gettid() + Slot-Lookup. |
| 2026-05-24 | WP-STB-11 ✅ — lyxvision: TerminalWriteStr/WriteAnsi mit peek8, TerminalDraw mit FillRect, TWindow prevX/Y/W/H + WindowZoom Save/Restore, AppInsertWindow via GroupInsert, Tab-Focus in ProgramRun. Struct-Literal-Init auf var+Feldzuweisungen umgestellt. |
| 2026-05-24 | WP-STB-12 ✅ — quic.lyx: Length-Feld in QUICBuildInitialPacket: 2-Byte-VarInt-Placeholder reserviert, nach Payload-Assembly rückwärts gefüllt (RFC 9000 §17.2). |
| 2026-05-24 | WP-STB-13 🔄 — svg/elements.lyx: veraltetes _svgWinline-Relikt in SvgSetFillGradient entfernt. _svgWinline ist in xml.lyx vollständig implementiert; die Zeile war ein no-op aus einer früheren Halbimplementierung. |
| 2026-05-24 | Stub-Audit erweitert: 2 neue WPs (STB-14, STB-15) aus zweitem Scan. LDAP-Placeholders als korrekt back-gefülltes Pattern identifiziert (kein Stub). |
