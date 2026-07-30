# BUG: `TypeName.Method()` erzeugt zur Laufzeit einen SIGSEGV

**Compiler:** lyxc 1.0.8C (self-hosting, `src/`)
**Target:** ELF x86-64 (weitere Targets ungeprüft)
**Schwere:** Hoch — betrifft benutzten Code in `src/std/`
**Gefunden:** 2026-07-30, beim Nachprüfen des 0.9.9B-Reports (`work/compiler-bugs.md`, BUG-6)

---

## Kurzfassung

Ein Methodenaufruf über den **Typnamen** statt über eine Instanz kompiliert
fehlerfrei, crasht aber beim Ausführen — auch dann, wenn die Methode `self`
überhaupt nicht anfasst und damit inhaltlich als statische Factory gemeint ist.

Das ist **nicht** der alte `e8 cc`-Platzhalter-CALL aus BUG-2; der ist gefixt und
bricht heute mit `error: undefined function … no codegen implementation found`
ab. Hier wird ein echter Call emittiert, der zur Laufzeit fehlschlägt.

## Repro

```lyx
// über eine Unit hinweg — so wird das Muster real benutzt
import src.std.string;

fn main(): int64 {
  var sb: int64 := StringBuilder.Create(64);   // kompiliert sauber
  if (sb != 0) { return 55; }
  return 1;
}
```

**Beobachtet:** SIGSEGV (exit 139).
**Erwartet:** 55 — oder ein Compile-Fehler, falls das Muster nicht unterstützt
werden soll.

`StringBuilder.Create` (`src/std/string.lyx:29`) benutzt kein `self`: es
alloziert selbst und liefert ein `int64`-Handle zurück.

Gegenprobe: eine **normale** `pub fn` aus derselben Unit funktioniert
(`StrTrim(...)` → 55). Es liegt also nicht am Import der Unit, sondern am
statischen Methodenaufruf selbst.

## Nicht neu

Mit dem Vorgänger-Compiler (Stand `develop` vor dieser Änderung) ist das
Verhalten identisch — der Bug ist vorbestehend und wurde nur bisher nicht
isoliert beschrieben.

## Betroffene Aufrufstellen im Repo

Alle folgenden Stellen sind damit latente Crashes, sobald der Pfad ausgeführt
wird:

| Datei | Stellen |
|---|---|
| `src/std/string.lyx` | 6× (`StrJoin`, `StrReplace`, `StrFormat`, …) |
| `src/std/json.lyx` | 2× (Zeile 218, 462) |
| `src/std/time.lyx` | 3× (Zeile 275, 318, 373) |
| `src/tests/singularity_test.lyx` | 3× (Zeile 126, 143, 158) |

## Abgrenzung zum sema-Check

Seit dieser Änderung lehnt sema den Fall ab, in dem die statisch aufgerufene
Methode `self` **benutzt** — dort fehlt der Empfänger nachweislich und die
Methode würde an einer beliebigen Adresse arbeiten. Methoden ohne `self`-Zugriff
bleiben erlaubt, weil das Static-Factory-Muster in `src/std/` verbreitet ist und
ein Verbot dort einen Umbau aller Aufrufstellen erzwingen würde.

Genau diese erlaubte Restmenge ist die, die hier zur Laufzeit crasht.

## Mögliche Richtungen

1. **Codegen reparieren:** statischen Aufruf als gewöhnlichen Call auf das
   gemangelte `ClassName_Method` emittieren, ohne self-Argument. Dann wird das
   Static-Factory-Muster zu dem, was es zu sein vorgibt.
2. **Sprachlich verbieten** und die vier Dateien oben auf Modul-Level-Funktionen
   umbauen (`StringBuilderCreate(...)`) — das ist laut `work/compiler-bugs.md`
   ohnehin das kanonische Lyx-Pattern.

Richtung 1 erhält bestehenden Code, Richtung 2 ist die klarere Sprachregel.
Die Entscheidung gehört vor die Umsetzung.

## Reproduktions-Harness

```bash
printf 'import src.std.string;\nfn main(): int64 { var sb: int64 := StringBuilder.Create(64); if (sb != 0) { return 55; } return 1; }' > /tmp/sb.lyx
./lyxc --std-path=std /tmp/sb.lyx -o /tmp/sb && /tmp/sb; echo "exit=$?"
```
