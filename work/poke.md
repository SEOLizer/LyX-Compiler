# poke/peek-Refactoring — Fahrplan

**Konvention:** WP-POKE-NN · Status: ✅ Erledigt · 🔄 In Arbeit · ⬜ Offen

---

## Problem in Zahlen

| Muster | Stellen in `src/` | Hauptbetroffene |
|--------|-------------------|-----------------|
| `poke64`/`peek64` mit manuellen Offsets | ~1.275 | `lyxc.lyx` (526), `codegen_x86.lyx` (496) |
| `poke8` mit Dezimal-ASCII-Codes | ~408 | verteilt |
| Byte-Kopierschleifen (`poke8(…peek8(…))`) | ~159 | `lyxc.lyx`, `codegen_x86.lyx` |
| Fehlende Konstanten (Magic Numbers) | partiell | `sema.lyx`, `ir_lower.lyx` |

**Was die Sprache schon hat:** Structs, `StrCopy`/`StrSetChar`, dynamische Arrays
(`push`/`pop` als Stubs), `@packed`.  
**Was fehlt:** `memcpy`/`memset` als Builtins, funktionierende Heap-Arrays.

---

## Ursachen (kein Sprachdefizit, sondern historisch)

1. **Pascal-Erbe:** Compiler wurde in Pascal geschrieben und Stück für Stück portiert —
   Structs und Methoden kamen erst nach großen Teilen des Compiler-Codes.
2. **mmap als universeller Allocator:** Alle Datenstrukturen leben in `mmap`-Blöcken.
   Das erzwingt manuelle Offset-Arithmetik wie in C.
3. **Kein Refactoring:** Der Code funktioniert — und bei einem self-hosting Compiler
   hat Korrektheit Priorität vor Eleganz.

---

## Phasen

| Phase | Schwerpunkt | WPs |
|-------|-------------|-----|
| 1 | Sprachergänzungen (Voraussetzungen) | POKE-01, POKE-02, POKE-03 |
| 2 | Compiler-Cleanup (Low-Hanging Fruit) | POKE-04, POKE-05, POKE-06 |
| 3 | Struct-Refactoring (Großes Bild) | POKE-07, POKE-08 |

---

## Phase 1 — Sprachergänzungen

---

### WP-POKE-01: `memcpy` Builtin ⬜

**Ziel:** `memcpy(dst, src, len)` als Compiler-Builtin — ersetzt ~159 Byte-Kopierschleifen
und ist die Voraussetzung für effizientes Umkopieren in Phase 2.

**Implementierung** (codegen_x86.lyx + sema.lyx):

```asm
; memcpy(dst: int64, src: int64, len: int64)
; rdi=dst, rsi=src, rdx=len
mov rcx, rdx          ; 48 89 D1
cld                   ; FC
rep movsb             ; F3 A4
```

Analog für ARM64: `memcpy` über Schleife mit LDR/STR oder `bl memcpy` via PLT.

**Registrierung:** `_regBuiltin("memcpy")` in sema.lyx, `cg_seq("memcpy", 6)` in
codegen_x86.lyx nach `getdents64`.

**Akzeptanzkriterien:**
- `memcpy(dst, src, 1024)` kopiert korrekt, Singularität S3==S4 bestätigt
- `--compile-unit std/fs.lyx` nutzt intern memcpy wo sinnvoll

---

### WP-POKE-02: `memset` Builtin ⬜

**Ziel:** `memset(dst, val, len)` — füllt einen Speicherbereich mit einem Byte-Wert.
Ergänzt memcpy und eliminiert weitere Initialisierungs-Schleifen.

**Implementierung:**
```asm
; memset(dst: int64, val: int64, len: int64)
; rdi=dst, al=val (aus rsi), rdx=len
mov al, sil           ; 40 88 F0
mov rcx, rdx          ; 48 89 D1
cld                   ; FC
rep stosb             ; F3 AA
```

**Akzeptanzkriterien:**
- `memset(buf, 0, 4096)` nullt korrekt
- Singularität S3==S4 bestätigt

---

### WP-POKE-03: Heap-dynamisches `Array<T>` ⬜

**Ziel:** `push`/`pop`/`len`/`cap` als funktionierende Builtins für heap-allozierte
Arrays. Aktuell sind alle vier im Codegen No-Ops (`self.cg_zeroRax()`).

**Warum wichtig:** Ermöglicht erst den großen Struct-Refactor (WP-POKE-08).
Ohne wachsende Arrays müsste jede Datenstruktur weiterhin als mmap-Blob implementiert
werden.

**Datenstruktur eines Heap-Arrays (Fat-Pointer, 24 Bytes):**
```
[0..7]   ptr   — Zeiger auf Daten (mmap-Block)
[8..15]  len   — aktuelle Anzahl Elemente
[16..23] cap   — Kapazität (Elemente, nicht Bytes)
```

**push(arr, elem):** Wenn `len == cap` → `cap *= 2`, `mmap(neu)`, `memcpy`,
`munmap(alt)`. Dann `poke_T(arr.ptr + arr.len * sizeof(T), elem)`, `arr.len += 1`.

**pop(arr):** `arr.len -= 1`, gibt `peek_T(arr.ptr + arr.len * sizeof(T))` zurück.

**Herausforderungen:**
- Typgröße `sizeof(T)` muss zur Compile-Zeit bekannt sein
- Codegen muss den Elementtyp aus der Typdefinition ableiten
- push/pop mit dem richtigen Typ-Stride emittieren

**Akzeptanzkriterien:**
- `var arr: Array<int64>; push(arr, 42); push(arr, 99); PrintLn(pop(arr));` → 99
- Array wächst korrekt über Kapazitätsgrenzen hinaus
- `len(arr)` gibt korrekte Länge zurück

---

## Phase 2 — Compiler-Cleanup

---

### WP-POKE-04: Konstanten vollständig — Alle Magic Offsets benennen ⬜

**Ziel:** Alle manuellen numerischen Offsets in `src/` durch benannte Konstanten
ersetzen. Teilweise schon vorhanden (`SEMA_SYM_SIZE`, `SEMA_SYM_NAME`), aber
inkonsistent eingesetzt.

**Vorgehen:** Audit aller `poke64(x + N, ...)` und `peek64(x + N)` wo N eine
Literal-Zahl ist. Für jede Struct-Familie eine Konstantengruppe anlegen:

```lyx
// Beispiel: Symbol-Record in sema.lyx
con SYM_OFF_NAME:     int64 := 0;
con SYM_OFF_NAMELEN:  int64 := 8;
con SYM_OFF_KIND:     int64 := 16;
con SYM_OFF_TYPEID:   int64 := 24;
con SYM_OFF_NODEIDX:  int64 := 32;
con SYM_OFF_VOLATILE: int64 := 40;
con SYM_RECORD_SIZE:  int64 := 48;
```

**Betroffene Struct-Familien** (identifiziert aus dem Codebase):
- Symbol-Records (sema.lyx)
- Function-Records (codegen_x86.lyx)
- IR-Instructions (ir.lyx, ir_lower.lyx)
- AST-Nodes (parser.lyx, codegen_x86.lyx)
- ELF-Struct-Offsets (lyxc.lyx)

**Akzeptanzkriterien:**
- Kein `poke64(x + N, ...)` / `peek64(x + N)` mit N > 0 als Literal-Zahl in `src/`
- Singularität S3==S4 nach jeder Datei

---

### WP-POKE-05: String-Konstruktion — ASCII-Codes → String-Builtins ⬜

**Ziel:** Alle Muster wie `poke8(buf + i, 46); poke8(buf + i+1, 108); ...`
durch `StrCopy` oder `StrSetChar` ersetzen.

**Typische Muster und ihre Ersetzung:**

```lyx
// Vorher: ".lyx" Buchstabe für Buchstabe
poke8(pathBuf + modLen,     46);   // '.'
poke8(pathBuf + modLen + 1, 108);  // 'l'
poke8(pathBuf + modLen + 2, 121);  // 'y'
poke8(pathBuf + modLen + 3, 120);  // 'x'
poke8(pathBuf + modLen + 4, 0);

// Nachher:
StrCopy(pathBuf + modLen, ".lyx");
```

```lyx
// Vorher: einzelnes Zeichen
poke8(buf + pos, 58);  // ':'

// Nachher:
StrSetChar(buf, pos, 58);   // oder besser: StrSetChar(buf, pos, ':')
                             // (wenn Char-Literale unterstützt)
```

**Voraussetzung:** WP-POKE-04 (erst Konstanten, dann String-Migration, um
Kontext zu verstehen).

**Akzeptanzkriterien:**
- Keine `poke8(…, [32-126])` mehr als reine ASCII-Konstruktion in `src/`
- Singularität bestätigt

---

### WP-POKE-06: Byte-Schleifen → `memcpy` ⬜

**Ziel:** Die ~159 `while (i < N) { poke8(dst+i, peek8(src+i)); i += 1; }`-Muster
durch `memcpy(dst, src, N)` ersetzen.

**Voraussetzung:** WP-POKE-01 (memcpy Builtin)

**Erkennungsmuster:** Jede while-Schleife der Form:
```lyx
while (i < count) {
  poke8(dst + i, peek8(src + i));
  i := i + 1;
}
```
wird zu `memcpy(dst, src, count)`.

**Sonderfall — Resize-Muster:**
```lyx
// Vorher:
while (i < oldSize) { poke8(newBuf + i, peek8(oldBuf + i)); i += 1; }
munmap(oldBuf, oldSize);

// Nachher:
memcpy(newBuf, oldBuf, oldSize);
munmap(oldBuf, oldSize);
```

**Akzeptanzkriterien:**
- Keine manuellen Byte-Kopierschleifen mehr in `src/` (grep liefert 0 Treffer)
- Singularität S3==S4 — memcpy ist semantisch identisch zur Schleife

---

## Phase 3 — Struct-Refactoring

---

### WP-POKE-07: Accessor-Funktionen für mmap-Blobs ⬜

**Ziel:** Als Vorstufe zum vollständigen Struct-Refactor (WP-POKE-08): Für
jede Struct-Familie typsichere Accessor-Funktionen anlegen, die die
Offset-Arithmetik kapseln.

**Warum:** Vollständiger Struct-Refactor ist risikoreich. Accessor-Funktionen
verbessern sofort die Lesbarkeit ohne große Umstrukturierung.

```lyx
// Beispiel: Symbol-Record Accessors in sema.lyx
fn sym_getName(symOff: int64): pchar {
  return peek64(symOff + SYM_OFF_NAME) as pchar;
}
fn sym_getKind(symOff: int64): int64 {
  return peek64(symOff + SYM_OFF_KIND);
}
fn sym_setVolatile(symOff: int64, val: int64): void {
  poke64(symOff + SYM_OFF_VOLATILE, val);
}
```

**Statt:**
```lyx
peek64(self.syms + si * SEMA_SYM_SIZE + SEMA_SYM_KIND)
// wird zu:
sym_getKind(self.syms + si * SEMA_SYM_SIZE)
```

**Voraussetzung:** WP-POKE-04 (vollständige Konstanten)

**Akzeptanzkriterien:**
- Alle direkten `peek64/poke64` auf Struct-Felder in sema.lyx und ir.lyx
  durch Accessor-Funktionen ersetzt
- Singularität S3==S4

---

### WP-POKE-08: Compiler-Internals — mmap-Blobs → Lyx-Structs ⬜

**Ziel:** Die fundamentale Umstellung: Compiler-Datenstrukturen werden als
echte Lyx-Structs mit Methoden modelliert. Dies ist der größte Einzelschritt
und lohnt sich erst wenn WP-POKE-03 (Heap-Arrays) fertig ist.

**Voraussetzung:** WP-POKE-01, WP-POKE-02, WP-POKE-03, WP-POKE-07

**Priorität der Umstellung:**

| Datenstruktur | Datei | Komplexität |
|---------------|-------|-------------|
| Symbol-Table (`self.syms`) | `sema.lyx` | Mittel |
| Lokale Variablen-Table | `codegen_x86.lyx` | Mittel |
| IR-Instructions (`funcBuffer`) | `ir.lyx` | Hoch |
| AST-Nodes | `parser.lyx` | Sehr hoch |
| ELF-Binary-Writer | `lyxc.lyx` | Niedrig* |

*ELF-Writer muss exaktes Byte-Layout halten → `@packed` statt normaler Struct.

**Beispiel (Symbol-Table):**
```lyx
// Vorher:
var syms: int64 := mmap(0, cap * SEMA_SYM_SIZE, 3, 34, -1, 0);
// Zugriff:
peek64(syms + si * SEMA_SYM_SIZE + SYM_OFF_NAME)

// Nachher:
type SymRecord = struct {
  name:      pchar;
  nameLen:   int64;
  kind:      int64;
  typeId:    int64;
  nodeIdx:   int64;
  isVolatile: int64;
};
var syms: Array<SymRecord>;
syms[si].name
```

**Hinweis für `@packed`-Structs:** ELF-Header, Wire-Protokolle und andere
Binärformate, die exaktes Memory-Layout brauchen, bleiben als mmap-Blobs
mit `@packed`-Annotationen — das ist korrektes Lyx-Idiom.

**Akzeptanzkriterien:**
- Symbol-Table in sema.lyx als `Array<SymRecord>`
- Zugriff ausschließlich über `.`-Operator
- Alle Tests grün, Singularität S3==S4

---

## Zusammenfassung

| WP | Titel | Aufwand | Voraussetzung |
|----|-------|---------|---------------|
| POKE-01 | `memcpy` Builtin | Klein (~2h) | — |
| POKE-02 | `memset` Builtin | Klein (~1h) | — |
| POKE-03 | Heap-Array `push`/`pop` | Groß (~2 Tage) | POKE-01 |
| POKE-04 | Konstanten vollständig | Mittel (~1 Tag) | — |
| POKE-05 | String-Konstruktion bereinigen | Mittel (~1 Tag) | POKE-04 |
| POKE-06 | Byte-Schleifen → `memcpy` | Mittel (~1 Tag) | POKE-01, POKE-04 |
| POKE-07 | Accessor-Funktionen | Mittel (~2 Tage) | POKE-04 |
| POKE-08 | mmap-Blobs → Lyx-Structs | Sehr groß (~1 Woche) | POKE-01–03, POKE-07 |

**Empfohlene Reihenfolge:** POKE-01 → POKE-02 → POKE-04 → POKE-05 → POKE-06
(Phase 1+2 komplett, je Singularitätsprüfung pro Datei). Dann POKE-03 als
isoliertes Sprachfeature. Dann POKE-07 → POKE-08 wenn Zeit und Risikobereitschaft
vorhanden.
