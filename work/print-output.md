# Lyx Print-Output — Fahrplan

Dieses Dokument beschreibt den Ausbau der Ausgabefunktionen in Lyx. Ziel ist,
dass `Print(...)` und `PrintLn(...)` gemischte Typen in einem Aufruf akzeptieren
— genau wie `print()` in Python oder `fmt.Println()` in Go.

**Konvention:** WP-OUT-NN. Status-Symbole: ✅ Erledigt, 🔄 In Arbeit, ⬜ Offen.

---

## Motivation

Aktueller Stand:

```lyx
// heute — umständlich, viele Funktionsaufrufe
PrintStr("x = ");
PrintInt(x);
PrintStr(", y = ");
PrintFloat(y);
PrintStr("\n");
```

Zielzustand nach diesem Fahrplan:

```lyx
// künftig — ein Aufruf, gemischte Typen
PrintLn("x = ", x, ", y = ", y);
```

`PrintLn` soll bis zu 6 Argumente beliebiger Typen (`pchar`, `int64`, `f64`,
`bool`) entgegennehmen und automatisch die richtige Ausgabe erzeugen.
`Print` ist identisch, aber ohne abschließendes `\n`.

---

## Architektur-Entscheidung

**Ansatz: Sema-Phase-Expansion** (compile-time, kein Laufzeit-Overhead)

Beim Typcheck in `sema.lyx` wird ein Aufruf wie `PrintLn("x =", x, y)` in
separate typenspezifische Aufrufe aufgelöst:

```
PrintLn("x =", x, y)
  → PrintStr("x =")
  → PrintInt(x)
  → PrintFloat(y)
  → PrintStr("\n")   ← nur bei PrintLn
```

Da `sema.lyx` den Typ jedes Arguments kennt, ist die Expansion rein
compile-time — kein Overhead, keine Typinformation zur Laufzeit nötig.

Alternative (verworfen): Variadics + Laufzeit-Dispatch — komplexer, langsamer,
erfordert zusätzliche IR-Felder für Typmarkierungen.

---

## Work Packages

---

### WP-OUT-01: Sema-Expansion für `Print` und `PrintLn` ✅

**Datei:** `src/sema.lyx`

**Beschreibung:**
`Print` und `PrintLn` werden als spezielle multi-arg Builtins registriert.
Beim Auflösen eines Calls prüft die Sema für jedes Argument den Typ und
generiert stattdessen N separate Aufrufe auf die existierenden Einzel-Builtins.

**Registrierung:**
```lyx
self._regBuiltinVariadic("Print");     // 1–6 args, beliebige Typen
self._regBuiltinVariadic("PrintLn");   // 1–6 args + "\n"
```

Alternativ: `Print`/`PrintLn` als bekannte Namen in der Call-Auflösung
behandeln (wie `exit`, `assert`, `panic`) ohne extra Registry-Eintrag.

**Expansion in `sema.lyx`, Funktion `resolveCall`:**
```
für jedes Argument arg_i mit Typ t_i:
  t_i = pchar/string  → Aufruf PrintStr(arg_i)
  t_i = int64/bool    → Aufruf PrintInt(arg_i)
  t_i = f64           → Aufruf PrintFloat(arg_i)
falls PrintLn:
  PrintStr("\n")  (Literal-String in das .data-Segment)
```

**Zu klären:**
- Typ-Lookup: `sema.InferExprType(arg_i)` gibt den Typ zurück — analog zu
  wie es heute bei `nkBinOp` für f64-Arithmetik genutzt wird.
- Die Expansion erzeugt N `nkCall`-Knoten die sequenziell in den AST eingefügt
  werden (ähnlich wie `StrConcat` bereits Hilfsvariablen einfügt).

**Akzeptanzkriterien:**
- `Print("hallo")` → schreibt `hallo` (kein `\n`)
- `PrintLn("hallo")` → schreibt `hallo\n`
- `Print("x = ", x)` mit `x: int64` → schreibt `x = 42`
- `PrintLn("pi = ", 3.14)` → schreibt `pi = 3.14\n` (f64-Literal)
- `PrintLn(true)` → schreibt `true\n`
- `Print("a=", a, " b=", b, " c=", c, " d=", d)` (6 Argumente) → OK
- 7 Argumente → Compiler-Fehler (über 6-Arg-Limit)

---

### WP-OUT-02: `EPrint` / `EPrintLn` (stderr) ⬜

**Datei:** `src/sema.lyx`

**Beschreibung:**
Identisch zu WP-OUT-01, aber Ausgabe auf `fd=2` (stderr).

Expansion: Jedes Argument wird auf `EPrintStr` / `EPrintInt` / `EPrintFloat`
umgeleitet (die als separate Einzel-Builtins bereits registriert sind bzw.
analog zu `PrintStr` auf `fd=2` schreiben).

**Fehlende Einzel-Builtins ergänzen falls nötig:**
- `EPrintFloat(v: f64)` — analog zu `PrintFloat`, aber fd=2
- `EPrintBool(b: int64)` — schreibt "true"/"false" auf fd=2

**Akzeptanzkriterien:**
- `EPrintLn("error: ", msg)` schreibt auf stderr
- `EPrint("code=", code)` schreibt auf stderr ohne `\n`

---

### WP-OUT-03: Alle std-Units auf `Print`/`PrintLn` umstellen ⬜

**Dateien:** alle `std/*.lyx` und `std/**/*.lyx`

**Beschreibung:**
Alle bestehenden Ausgabe-Sequenzen aus getrennten `PrintStr` + `PrintInt` +
`PrintFloat` Aufrufen werden auf den einheitlichen `Print`/`PrintLn`-Stil
umgeschrieben. Dies ist der primäre Output-Stil ab jetzt.

**Vorgehen:**
```bash
# Beispiel: vorher
PrintStr("value = ");
PrintInt(v);
PrintStr("\n");

# nachher
PrintLn("value = ", v);
```

**Scope:**
- `std/io.lyx` (falls vorhanden)
- `std/os.lyx` (debug-Prints in exec)
- Alle anderen Units mit mehreren Print-Aufrufen in Folge

**Hinweis:** Gleichzeitig FIX-10 aus `fix-units.md` erledigen (Debug-PrintStr
aus `exec()` in os.lyx entfernen).

---

### WP-OUT-04: Print als primärer Stil in Code-Generierung (Claude) ✅

**Beschreibung:**
Nach Umsetzung von WP-OUT-01 ist `Print`/`PrintLn` der bevorzugte Output-Stil
für alle neu geschriebenen Lyx-Dateien. Die alten Einzel-Builtins
(`PrintStr`, `PrintInt`, `PrintFloat`, `PrintBool`) bleiben verfügbar
(für explizite typenspezifische Ausgaben oder Performance-sensitiven Code),
sind aber nicht mehr der Default.

**Neue Code-Richtlinie:**
```lyx
// ✅ bevorzugt
PrintLn("result = ", result, " (took ", ms, " ms)");

// ⚠️ nur noch für explizite Fälle
PrintStr(buffer);   // roher pchar-Puffer ohne Newline
PrintInt(errno);    // ein einziger Wert ohne Text
```

---

## Meilensteine

| Meilenstein | WPs | Ergebnis |
|-------------|-----|---------|
| M1: Kern-Feature | WP-OUT-01 ✅ | `Print`/`PrintLn` kompilierbar |
| M2: Stderr | WP-OUT-02 ✅ | `EPrint`/`EPrintLn` |
| M3: Migration | WP-OUT-03+04 ✅ | Alle std-Units aktualisiert |

---

## Technische Details: Sema-Expansion (WP-OUT-01)

### Typ-Dispatch-Tabelle

| Lyx-Typ | Ausgabe-Builtin | Bemerkung |
|---------|----------------|-----------|
| `pchar` | `PrintStr` | NUL-terminated string |
| `int64` | `PrintInt` | dezimale Ausgabe |
| `bool`  | `PrintInt` | 0/1 oder besser: `PrintBool` |
| `f64`   | `PrintFloat` | Dezimalpunkt-Ausgabe |
| anderes | `PrintInt` | Fallback (Pointer-Wert) |

### AST-Transformation

Aus einem einzelnen `nkCall(Print, [e1, e2, e3])` wird:
```
nkBlock:
  nkCall(PrintStr, [e1])   ← wenn Typ(e1) = pchar
  nkCall(PrintInt, [e2])   ← wenn Typ(e2) = int64
  nkCall(PrintFloat, [e3]) ← wenn Typ(e3) = f64
```

Diese Transformation findet in `sema.lyx` in der Funktion statt, die
`nkCall`-Knoten auflöst (analog zu wie `StrConcat` Hilfsvariablen anlegt).

### Literal-Handling

String-Literale in `Print("text", x)` sind bereits `pchar` — kein
Sonderfall nötig. Zahl-Literale (`42`, `3.14`) bekommen vom Sema den
passenden Typ (`int64` bzw. `f64`) und werden entsprechend expandiert.

---

## Offene Fragen

| # | Frage | Empfehlung |
|---|-------|------------|
| 1 | Separator zwischen Argumenten? | Kein Separator (wie Python `print(..., sep='')`) — Text explizit in Strings |
| 2 | `Print` mit 0 Argumenten? | Erlaubt, tut nichts (kein Error) |
| 3 | `bool` via `PrintBool` (true/false) oder `PrintInt` (0/1)? | `PrintBool` — lesbarerer Output |
| 4 | `int64` als Hex ausgeben? | Später: `PrintHex(n)` Einzel-Builtin, nicht Teil von Print |

---

## Changelog

| Datum | Änderung |
|-------|---------|
| 2026-05-23 | Initiale Spezifikation |
| 2026-05-23 | WP-OUT-01 ✅ Print/PrintLn multi-arg compile-time dispatch implementiert |
| 2026-05-23 | WP-OUT-02 ✅ EPrint/EPrintLn (stderr) — _lyx_eprint_int Infinite-Loop-Bug gefixt |
| 2026-05-23 | WP-OUT-03 ✅ std-Units migriert; FIX-10 (Debug-Prints in os.lyx) erledigt |
| 2026-05-23 | WP-OUT-04 ✅ Print/PrintLn als primärer Stil etabliert |
