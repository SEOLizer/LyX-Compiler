# Lyx Compiler — Lizenzschlüssel-System

## Ziele

1. **Lizenzpflicht (optional):** Name + E-Mail → einzigartiger Schlüssel. Nur die korrekte Kombination bringt den Compiler in Betrieb.
2. **Binär-Wasserzeichen:** Jede mit lyxc erzeugte Binärdatei enthält einen aus dem Lizenzschlüssel abgeleiteten Fingerprint → Rückverfolgbarkeit.
3. **Optionale Aktivierung:** Compile-Time-Flag `LYXC_LICENSE_REQUIRED`. In Dev- und Open-Source-Builds deaktiviert; in Release-Builds aktiv.

---

## Sicherheitsmodell

Das System liefert **Abschreckung und Attributierung**, keine kryptographische Unumgehbarkeit. Ein Angreifer mit Binary-Analyse-Tools kann das Master-Secret extrahieren und selbst Schlüssel erzeugen. Das ist bewusst akzeptiert. Der Wert liegt in:

- Praktischer Hürde für nicht-technische Benutzer
- Rechtlicher Nachweisbarkeit (Wasserzeichen in Binaries)
- Klarer Lizenzvereinbarung beim Kompilieren

---

## Schlüsselformat

```
AAAAA-BBBBB-CCCCC-DDDDD-EEEEE
```

25 Zeichen, 5 Gruppen à 5, Crockford-Base32-Zeichensatz:  
`ABCDEFGHJKMNPQRSTVWXYZ23456789` (I, L, O, U, 0, 1 weggelassen → verwechslungssicher)

125 Bits Nutzlast aus 32-Byte HMAC-SHA256-Ausgabe (256 Bits → erste 125 Bits kodiert).

---

## Schlüssel-Ableitungsalgorithmus

```
masterSecret  = 32 Bytes, in der Binary gesplittet gespeichert (WP-LIC-13)
versionByte   = 0x01  (für spätere Formatmigrationen)

input  = toLower(trim(name)) + "|" + toLower(trim(email)) + "|" + versionByte
digest = HMAC-SHA256(masterSecret, input)   // 32 Bytes
key    = crockfordBase32(digest)[0..24]     // 25 Zeichen, in 5er-Gruppen formatiert
```

Bestehende Implementierung: `_qSHA256` und `_qHMACSHA256` aus `std/net/quic.lyx` werden in ein dediziertes Modul `src/crypto/lic_hmac.lyx` extrahiert (WP-LIC-02).

---

## Lizenz-Dateiformat (`~/.lyx/license.key`)

```ini
name=Andreas Röne
email=andreas.roene@seolizer.de
key=ABCDE-FGHIJ-KLMNO-PQRST-UVWXY
```

Parser: einfacher Key=Value-Scanner, kein Import externer Bibliotheken nötig (reine pchar-Operationen).

---

## Suchlogik beim Start (Priorität hoch → niedrig)

1. CLI-Flag `--license-file=<pfad>`
2. CLI-Flags `--license=KEY --name=NAME --email=EMAIL` (direkte Übergabe)
3. Umgebungsvariablen `LYX_LICENSE_FILE` / `LYX_LICENSE_KEY` + `LYX_LICENSE_NAME` + `LYX_LICENSE_EMAIL`
4. `~/.lyx/license.key`
5. `./license.key` (aktuelles Verzeichnis)

---

## Binär-Wasserzeichen

In jede erzeugte ELF-Datei wird ein ELF-Section-Header `.lyx_lic` eingebettet:

```
Offset  Größe  Inhalt
0       8      fingerprint = erste 8 Bytes von HMAC-SHA256(licenseKey, sha256(sourceCode))
8       4      keyChecksum = erste 4 Bytes von SHA256(licenseKey)
12      1      version     = 0x01
13      3      padding     = 0x00 0x00 0x00
```

**16 Bytes gesamt.** Enthält weder Name noch E-Mail noch den echten Schlüssel — nur abgeleitete Werte.

Mit `lyxc --check-binary <binary> --license-file=<key>` kann verifiziert werden, ob eine Binärdatei von einem bestimmten Lizenzschlüssel erzeugt wurde.

---

## Work Packages

### WP-LIC-01 — Datenstrukturen und Lizenz-Struct
**Ziel:** `LicenseInfo`-Struct in `lyxc.lyx` + Konstanten für Fehlercodes.
```
LicenseInfo {
  name:    pchar   // zeigt in gelesenen Puffer
  nameLen: int64
  email:   pchar
  emailLen: int64
  key:     pchar   // 25 Zeichen + Trennstriche = 29 Zeichen
  keyLen:  int64
  valid:   bool
}
```
**Abhängigkeiten:** keine  
**Geschätzte Komplexität:** klein

---

### WP-LIC-02 — Crypto-Modul `src/crypto/lic_hmac.lyx`
**Ziel:** SHA-256 und HMAC-SHA256 aus `std/net/quic.lyx` extrahieren und als öffentliche Funktionen in einem eigenständigen Modul bereitstellen.

```lyx
pub fn lic_sha256(input: int64, inLen: int64, out32: int64)
pub fn lic_hmacSha256(key: int64, keyLen: int64, msg: int64, msgLen: int64, out32: int64)
```

Keine Anpassung am Algorithmus — nur Sichtbarkeit von `fn` auf `pub fn` und Umbenennung der Präfixe.

**Abhängigkeiten:** keine (reines Lyx, keine Imports)  
**Geschätzte Komplexität:** klein (Copy + Umbenennen)

---

### WP-LIC-03 — Key-Derivation `lic_deriveKey`
**Ziel:** Aus Name + E-Mail + Master-Secret den Schlüssel ableiten.

```lyx
pub fn lic_deriveKey(name: pchar, nameLen: int64,
                     email: pchar, emailLen: int64,
                     outKey29: pchar)   // "AAAAA-BBBBB-..." null-terminiert
```

Schritte intern:
1. `toLower` + `trim` beider Strings
2. Konkatenation mit `|`-Trenner und Version-Byte `\x01`
3. `lic_hmacSha256(masterSecret, 32, input, inputLen, digest)`
4. `crockfordBase32Encode(digest, 32)` → 51 Zeichen, davon erste 25 nehmen
5. `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX` formatieren

**Abhängigkeiten:** WP-LIC-02, WP-LIC-13  
**Geschätzte Komplexität:** mittel

---

### WP-LIC-04 — Crockford-Base32-Encoder
**Ziel:** `lic_base32Encode(input: int64, inLen: int64, out: pchar): int64` — reiner Bit-Shifter über den Crockford-Zeichensatz.

**Abhängigkeiten:** keine  
**Geschätzte Komplexität:** klein

---

### WP-LIC-05 — Lizenz-Datei-Parser `lic_parseFile`
**Ziel:** `~/.lyx/license.key` einlesen und in `LicenseInfo` befüllen.

```lyx
pub fn lic_parseFile(path: pchar, out: LicenseInfo): bool
```

Einfacher Zeilen-Scanner: für jede Zeile `key=value` splitten, bekannte Keys befüllen.

**Abhängigkeiten:** WP-LIC-01  
**Geschätzte Komplexität:** klein

---

### WP-LIC-06 — CLI-Integration
**Ziel:** Neue CLI-Flags in `CompilerConfig`:

| Flag | Beschreibung |
|------|-------------|
| `--license-file=<pfad>` | Explizite Lizenzdatei |
| `--license=KEY` | Schlüssel direkt übergeben |
| `--name=NAME` | Name direkt übergeben |
| `--email=EMAIL` | E-Mail direkt übergeben |
| `--gen-key` | Schlüssel generieren (Name + Email nötig) |
| `--check-binary=<pfad>` | Wasserzeichen einer Binary prüfen |
| `--no-license` | Lizenzprüfung deaktivieren (nur in Dev-Builds) |

In `printHelp()` nur ausgeben wenn `LYXC_LICENSE_REQUIRED` aktiv.

**Abhängigkeiten:** WP-LIC-01, WP-LIC-05  
**Geschätzte Komplexität:** mittel

---

### WP-LIC-07 — Umgebungsvariablen
**Ziel:** Lizenz-Lookup über Env-Variablen via `lyx_getEnvVar` (bereits vorhanden).

| Variable | Entspricht |
|----------|-----------|
| `LYX_LICENSE_FILE` | `--license-file=` |
| `LYX_LICENSE_KEY` | `--license=` |
| `LYX_LICENSE_NAME` | `--name=` |
| `LYX_LICENSE_EMAIL` | `--email=` |

**Abhängigkeiten:** WP-LIC-06 (vorhandene `lyx_getEnvVar`)  
**Geschätzte Komplexität:** klein

---

### WP-LIC-08 — Verifikationslogik in `lyxc.lyx`
**Ziel:** Beim Start (nach `parseCLI`, nach Env-Var-Lesen, vor Compilation):

```
1. Lizenzinfo laden (Reihenfolge aus "Suchlogik")
2. lic_deriveKey(name, email) → expectedKey
3. constantTimeCompare(providedKey, expectedKey) → valid
4. Bei Fehler: Fehlermeldung + exit(1)
   "lyxc: ungültiger Lizenzschlüssel.
    Lizenz erwerben: https://..."
5. Bei fehlendem Schlüssel:
   "lyxc: keine Lizenz gefunden.
    Erstelle ~/.lyx/license.key mit name=, email=, key=
    Lizenz erwerben: https://..."
```

Constant-Time-Vergleich (kein Early-Exit → verhindert Timing-Angriffe).

**Abhängigkeiten:** WP-LIC-03, WP-LIC-05, WP-LIC-06, WP-LIC-07  
**Geschätzte Komplexität:** mittel

---

### WP-LIC-09 — Key-Generator `--gen-key`
**Ziel:** Schlüssel für einen Kunden erzeugen.

```bash
lyxc --gen-key --name="Andreas Röne" --email="andreas.roene@seolizer.de"
# Ausgabe:
# lyxc License Key Generator
# Name:  Andreas Röne
# Email: andreas.roene@seolizer.de
# Key:   ABCDE-FGHIJ-KLMNO-PQRST-UVWXY
#
# Speichern als ~/.lyx/license.key:
#   name=Andreas Röne
#   email=andreas.roene@seolizer.de
#   key=ABCDE-FGHIJ-KLMNO-PQRST-UVWXY
```

Nutzt denselben `lic_deriveKey` wie die Verifikation.

**Abhängigkeiten:** WP-LIC-03, WP-LIC-06  
**Geschätzte Komplexität:** klein

---

### WP-LIC-10 — Binär-Wasserzeichen (ELF)
**Ziel:** In jede erzeugte ELF-Datei eine `.lyx_lic`-Section einbetten.

In `codegen_x86.lyx` (`cg_writeELF`):
1. `licFingerprint[8]` = erste 8 Bytes von `HMAC-SHA256(licenseKey, SHA256(sourceCode))`
2. `keyChecksum[4]`    = erste 4 Bytes von `SHA256(licenseKey)`
3. `version[1]`        = `0x01`
4. `padding[3]`        = `0x00`

ELF Section-Header für `.lyx_lic` hinzufügen (Typ `SHT_NOTE = 7`, 16 Bytes, nicht ausführbar).

`licenseKey` wird von `lyxc.lyx` nach erfolgreicher Verifikation an `Codegen` übergeben (neues Feld `licenseKey: pchar`).

**Abhängigkeiten:** WP-LIC-02, WP-LIC-08  
**Geschätzte Komplexität:** mittel–groß

---

### WP-LIC-11 — `--check-binary`
**Ziel:** Prüfen ob eine Binary von einem bestimmten Lizenzschlüssel erzeugt wurde.

```bash
lyxc --check-binary ./a.out --license-file=~/.lyx/license.key
# Ausgabe:
# Binary: ./a.out
# .lyx_lic: vorhanden
# Fingerprint-Match: JA / NEIN
# Key-Checksum:      JA / NEIN
```

Liest `.lyx_lic`-Section aus dem ELF, reberechnet Werte aus Lizenzschlüssel.

**Abhängigkeiten:** WP-LIC-10  
**Geschätzte Komplexität:** mittel

---

### WP-LIC-12 — Compile-Time-Flag `LYXC_LICENSE_REQUIRED`
**Ziel:** Makefile-Variable steuert ob Lizenzprüfung aktiv ist.

```makefile
LYXC_LICENSE_REQUIRED ?= 0   # Dev-Default: aus
# LYXC_LICENSE_REQUIRED = 1  # Release: an
```

In `lyxc.lyx`:
```lyx
con LYXC_LICENSE_REQUIRED: int64 := 0;  // durch Build gesetzt
```

Wenn `0`: Lizenzprüfung komplett übersprungen, kein Wasserzeichen.  
Wenn `1`: Vollständige Prüfung, Wasserzeichen immer eingebettet.

**Abhängigkeiten:** WP-LIC-08  
**Geschätzte Komplexität:** klein

---

### WP-LIC-13 — Master-Secret-Obfuskation
**Ziel:** Das 32-Byte-Master-Secret nicht als zusammenhängendes Literal in der Binary speichern.

Strategie:
- Secret in 4 × 8-Byte-Teile aufteilen
- Jeder Teil an anderer Stelle im Code als `con`-Konstante (XOR-maskiert)
- Zur Laufzeit: alle Teile XOR-demaskieren, zusammensetzen, nur für die Dauer der Schlüsselberechnung im Stack halten (kein globaler Puffer)
- Stackpuffer direkt nach Verwendung mit Nullen überschreiben

Kein vollständiger Schutz gegen Reverse Engineering, aber erhöhter Aufwand.

**Abhängigkeiten:** keine  
**Geschätzte Komplexität:** klein

---

## Empfohlene Implementierungsreihenfolge

```
WP-LIC-13  (Secret)
WP-LIC-04  (Base32)
WP-LIC-02  (HMAC)
WP-LIC-03  (Key-Derivation)
WP-LIC-01  (Structs)
WP-LIC-05  (File-Parser)
WP-LIC-12  (Build-Flag)
WP-LIC-06  (CLI)
WP-LIC-07  (Env-Vars)
WP-LIC-08  (Verifikation)
WP-LIC-09  (gen-key)
WP-LIC-10  (Wasserzeichen ELF)
WP-LIC-11  (check-binary)
```

---

## Offene Fragen / Entscheidungen

| # | Frage | Optionen |
|---|-------|---------|
| F-1 | Soll `--gen-key` in `lyxc` selbst oder in einem separaten `lyxc-keygen`-Binary liegen? | In lyxc einfacher; separates Binary schützt besser gegen Schlüsselmissbrauch |
| F-2 | Wasserzeichen auch in Mach-O (macOS) und PE (Windows)? | PE hat Debug-Directories, Mach-O hat `__TEXT,__lyx_lic` LC — empfohlen für v2 |
| F-3 | Soll ein abgelaufener/gesperrter Schlüssel erkannt werden? | Erfordert Online-Check oder Revocation-List — Scope für v2 |
| F-4 | Grace-Period bei fehlendem Schlüssel (z. B. 30 Tage Testbetrieb)? | Machbar mit Build-Timestamp im Binary — Scope nach Bedarf |
