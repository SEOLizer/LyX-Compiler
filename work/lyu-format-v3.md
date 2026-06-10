# LYU Format v3 — Erweiterung um 3 Metadaten-Felder

## Motivation

LYU v2 reserviert bereits drei String-Slots (description, author, copyright), die im
Writer leer bleiben und vom Reader stumm übersprungen werden. Mit v3 werden drei neue
Felder am Ende des Metadatenblocks ergänzt, die maschinell auswertbar sind.

---

## Neue Felder (Slots 4–6 im Header)

| # | Feldname           | Typ        | Beispiel                    | Zweck |
|---|--------------------|------------|-----------------------------|-------|
| 4 | `compilerBuild`    | u16-String | `lyxc 0.9.5B x86_64-linux` | Welcher Compiler-Build hat diese LYU erzeugt |
| 5 | `unitVersion`      | u16-String | `1.0.0`                     | Versionsnummer der Unit selbst (für Paketmanager / API-Stabilität) |
| 6 | `minCompilerVer`   | u16-String | `0.9.5B`                    | Mindest-Compiler-Version, die diese Unit lesen/nutzen kann |

> **compilerBuild** setzt sich zusammen aus: `lyxc <VERSION> <ARCH>-<OS>`  
> Quelle: der bestehende `--version`/`--build-info`-Pfad in `lyxc.lyx:1071`.

---

## Header-Layout v3 (vollständig)

```
Offset  Größe  Feld
──────  ─────  ────────────────────────────────────────
0       4      Magic: 'L' 'Y' 'U' 0x00
4       2      version: u16le  ← 3 (war 2)
6       1      arch: u8
7       1      flags: u8
8       var    unitName:      u16-prefixed string
+0      var    description:   u16-prefixed string  (v2, bleibt leer wenn ungenutzt)
+1      var    author:        u16-prefixed string  (v2)
+2      var    copyright:     u16-prefixed string  (v2)
+3      var    compilerBuild: u16-prefixed string  (v3, NEU)
+4      var    unitVersion:   u16-prefixed string  (v3, NEU)
+5      var    minCompilerVer:u16-prefixed string  (v3, NEU)
        4      symCount:      u32le
        4      TypeInfoOffset u32le  (reserved, 0)
        4      IRCodeOffset   u32le  (reserved, 0)
        4      DebugOffset    u32le  (reserved, 0)
        4      Reserved       u32le
        …      Symbol table
```

---

## Abwärtskompatibilität

- Reader mit `version < 3` überspringen die neuen Felder schlicht (sie existieren nicht).
- Reader mit `version >= 3` lesen/skippen alle 6 Metadaten-Strings.
- Vorhandene `.lyu`-Dateien (v2) bleiben gültig; der Reader brancht auf `version >= 3`.
- Alle Std-Units müssen neu kompiliert werden, sobald der Writer auf v3 umgestellt ist.

---

## Arbeits­pakete

### WP-LYU-03-A — Konstante & Format-Spezifikation (`lyu_writer.lyx`)

**Dateien:** `src/lyu_writer.lyx`

- `LYU_W_VER` von `2` auf `3` anheben
- Drei neue `_eStr`-Aufrufe im `Serialize()`-Block nach den bestehenden v2-Slots:
  ```lyx
  self._eStr(compilerBuild, StrLen(compilerBuild));
  self._eStr(unitVersion,   StrLen(unitVersion));
  self._eStr(minCompVer,    StrLen(minCompVer));
  ```
- Signatur von `Serialize()` um drei neue Parameter erweitern:
  ```lyx
  pub fn Serialize(inputPath: pchar, sema: Sema, arch: int64,
                   compilerBuild: pchar, unitVersion: pchar, minCompVer: pchar)
  ```

---

### WP-LYU-03-B — Reader-Erweiterung (`lyu_reader.lyx`)

**Dateien:** `src/lyu_reader.lyx`

- `LyrInit()`: bestehenden `if version >= 2`-Block um `if version >= 3` erweitern:
  ```lyx
  if (self.version >= 3) {
    self.compilerBuild    := self._skipStr(&self.compilerBuildLen);
    self.unitVersion      := self._skipStr(&self.unitVersionLen);
    self.minCompilerVer   := self._skipStr(&self.minCompilerVerLen);
  }
  ```
- Sechs neue `pub`-Felder in der `LyuReader`-Klasse deklarieren.
- `PrintInfo()`: neue Felder ausgeben wenn `version >= 3`.

---

### WP-LYU-03-C — Compiler-Integration (`lyxc.lyx`)

**Dateien:** `src/lyxc.lyx`

- Konstante für den Build-String definieren (analog zu `--version`-Ausgabe):
  ```lyx
  con LYXC_BUILD_STR: pchar := "lyxc 0.9.5B x86_64-linux"c;
  con LYXC_MIN_VER:   pchar := "0.9.5B"c;
  ```
- Alle `Serialize()`-Aufrufe auf die neue Signatur umstellen.
- `unitVersion` wird per CLI-Flag `--unit-version <ver>` übergeben (default: `""`).

---

### WP-LYU-03-D — Std-Units neu kompilieren

**Betroffen:** alle `.lyu` unter `lyx-compiler/usr/include/lyx/units/`

- Stage-2-Build via `/tmp/lyxc_new` (siehe Memory: Stage-2-Build für neue Builtins).
- Rebuild-Skript prüft, dass alle generierten LYUs `version == 3` im Header tragen
  (`xxd <file> | head -1` → Byte 4–5 = `03 00`).

---

### WP-LYU-03-E — CLI-Flag `--unit-version`

**Dateien:** `src/lyxc.lyx`

- Neues Flag `--unit-version <string>` parsen und an `Serialize()` durchreichen.
- Wird nicht angegeben → leerer String `""`.
- Doku in `--help`-Ausgabe ergänzen.

---

## Abhängigkeiten

```
WP-LYU-03-A  ←  WP-LYU-03-B  (Reader hängt an Writer-Format)
WP-LYU-03-A  ←  WP-LYU-03-C  (lyxc ruft Writer auf)
WP-LYU-03-C  ←  WP-LYU-03-E  (Flag muss vor Integration vorhanden sein)
WP-LYU-03-C  ←  WP-LYU-03-D  (Rebuild erst wenn lyxc fertig)
```

Empfohlene Reihenfolge: **A → E → C → B → D**

---

## Offene Fragen

- Soll `compilerBuild` den Target-String dynamisch aus dem `arch`-Parameter ableiten
  oder als feste Konstante pro Compiler-Build eingebaut werden?
- Format von `unitVersion`: freier String oder erzwungenes SemVer `MAJOR.MINOR.PATCH`?
- Soll der Reader bei `minCompilerVer > aktueller Version` eine Warnung ausgeben
  oder den Import hart abbrechen?
