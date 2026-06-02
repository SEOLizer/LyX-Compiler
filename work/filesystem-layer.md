# Plattformübergreifender Dateipfad-Abstraktionslayer für Lyx

> **Dokumenttyp:** Konzept & Implementierungsfahrplan  
> **Bezug:** Ursprüngliches Konzeptpapier (filesystem-layer.md, v1)  
> **Stand:** 2026-05-31 (v2 – überarbeitet und erweitert)  
> **Autor:** Architekturanalyse auf Basis des Lyx-Projektstands v0.9.0A

---

## 1. Einordnung & Hintergrund

### 1.1 Das Problem

Lyx ist als **plattformübergreifende Systems Programming Language** konzipiert mit aktuell 7 Ziel-Backends (Linux x86-64, ARM64, Windows x86-64/ARM64, macOS x86-64/ARM64, RISC-V, ARM Cortex-M, Xtensa). Jede Plattform hat **eine andere Konvention für Dateipfade**:

| Merkmal | Windows | Linux/POSIX | macOS |
|---------|---------|-------------|-------|
| Trennzeichen | Backslash `\` | Slash `/` | Slash `/` |
| Root-Struktur | Laufwerksbuchstaben (`C:`, `D:`) + UNC (`\\server\share`) | Einzelnes Root `/` | Einzelnes Root `/` |
| Case-Sensitivity | Case-Insensitive (standardmäßig) | Case-Sensitive | Case-Insensitive (Dateisystem-abhängig) |
| Maximale Pfadlänge | 260 Zeichen (klassisch) / 32.767 (erweitert) | 4096 Zeichen | 1024 Zeichen |
| Symlinks | NTFS Reparse Points (eingeschränkt, erfordert Adminrechte) | Vollständig unterstützt | Vollständig unterstützt |
| Unicode-Normalisierung | NFC (NTFS) | keine Anforderung (in der Praxis meist NFC) | NFD (HFS+/APFS) |

Ein Lyx-Programm, das auf Linux einen Pfad wie `/home/user/file.txt` verwendet und auf Windows laufen soll, muss diesen Unterschied korrekt handhaben können. **Ohne Abstraktion ist portabler Code nicht zuverlässig realisierbar.**

### 1.2 Bestehende Lyx-Stdlib (IST-Zustand)

| Modul | Inhalt | Relevanz für Path-Layer |
|-------|--------|------------------------|
| `std/fs.lyx` | Low-Level-Datei-API: `open`, `read`, `write`, `close`, `lseek`, `unlink`, `rename` – direkte Syscall-Wrapper | **Niedrig** – arbeitet mit rohen `pchar`-Pfaden, kein Path-Objekt |
| `std/os.lyx` | OS-Utilities: `getenv`, `getcwd`, `chdir`, `access`, `getpid` | **Mittel** – `getcwd`/`chdir` sind relevant für PathResolver |
| `std/system.lyx` | System-Informationen | **Niedrig** |

**Der Path-Abstraktionslayer existiert noch nicht.** Die aktuelle Stdlib erwartet Pfade als rohe `pchar`- oder `string`-Parameter – das ist fehleranfällig und nicht portabel.

### 1.3 Zielsetzung

Dieser Fahrplan definiert Arbeitspakete zur Implementierung eines **typsicheren, plattformunabhängigen Path-Abstraktionslayers** für Lyx, bestehend aus:

1. Einem **unveränderlichen (immutable) Path-Objekt** mit einer **Einheitlichen Internen Pfadrepräsentation (UIP)**
2. **Typsicherer Trennung** von absoluten und relativen Pfaden
3. **Parser/Translator-Komponenten** für plattformspezifische Ein- und Ausgabe
4. **Symlink-Auflösung und Kanonisierung** durch Dateisystemzugriff
5. **Vollständiger Integration** in die Lyx-Standardbibliothek

---

## 2. Konzept: Einheitliche Interne Pfadrepräsentation (UIP)

### 2.1 Kernprinzip

Die UIP basiert auf POSIX-Konventionen und dient als **plattformneutrales Zwischenformat** zwischen Ein- und Ausgabe. Alle Pfadkomponenten werden als **NFC-normalisiertes UTF-8** gespeichert:

```
[Externer Pfad-String]          [Betriebssystem-Aufruf]
         │                                ▲
         ▼                                │
    PathParser ───► Path-Objekt ───► PathTranslator
                        │
                    (UIP-Format)
```

### 2.2 Abbildungsregeln

| Externer Pfad (Original) | Interne Repräsentation (UIP) | Bemerkung |
|---------------------------|------------------------------|-----------|
| `C:\Users\User\file.txt` | drive=`C`, components=`['Users','User','file.txt']`, is_absolute=`true` | Drive als dediziertes Feld, nicht in components eingebettet |
| `\\server\share\data.csv` | server=`server`, share=`share`, components=`['data.csv']`, is_unc=`true` | UNC-Felder separat |
| `/home/user/document.pdf` | components=`['home','user','document.pdf']`, is_absolute=`true` | POSIX → direkte Übernahme |
| `relative/path` | components=`['relative','path']`, is_absolute=`false` | Relativ → keine Änderung |
| `~/documents/file.txt` | Wird aufgelöst zu AbsolutePath via `home_dir()` | Tilde-Expansion in WP2 |
| `./foo/../bar/` | (nach Normalisierung) | Wird zu `['bar']` aufgelöst |

> **Wichtige Designentscheidung – Namespace-Trennung:** Windows-Laufwerksbuchstaben (`drive`) und UNC-Felder (`server`, `share`) werden als **dedizierte Struct-Felder** gespeichert – **nicht** als Segmente in der `components`-Liste eingebettet. Damit entfällt das Namespace-Kollisionsproblem: Ein Linux-Verzeichnis `/C` würde bei eingebetteter Darstellung fälschlich als Windows-Laufwerk interpretiert, und `/UNC` würde mit dem UNC-Namespace kollidieren. Der PathTranslator rekonstruiert den plattformspezifischen String ausschließlich aus den Struct-Feldern.

### 2.3 Kernkomponenten (Architektur)

```
┌───────────────────────────────────────────────────────────────────┐
│                    Path-Abstraktionslayer                          │
│                                                                    │
│  ┌──────────────┐   ┌────────────────────┐   ┌──────────────────┐ │
│  │  PathParser   │   │  PathNormalizer     │   │  PathTranslator  │ │
│  │  (Ingress)    │──▶│  + PathResolver     │──▶│  (Egress)        │ │
│  └──────────────┘   └────────────────────┘   └──────────────────┘ │
│         │                       │                       │          │
│         ▼                       ▼                       ▼          │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │                  Path-Objekt (UIP)                           │ │
│  │  components: List<String>  (geordnet, NFC-UTF-8)             │ │
│  │  is_absolute: bool                                           │ │
│  │  drive:  String?  (Windows-Laufwerksbuchstabe, z.B. "C")     │ │
│  │  server: String?  (UNC-Server, nur wenn is_unc=true)         │ │
│  │  share:  String?  (UNC-Share, nur wenn is_unc=true)          │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │  Typhierarchie (WP6):                                         │ │
│  │  Path = AbsolutePath | RelativePath                          │ │
│  │  AbsolutePath = PosixPath | WindowsDrivePath | UncPath       │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │  Erweiterungsmodul (WP8):                                     │ │
│  │  PathCanonicalizer – Symlink-Auflösung, realpath             │ │
│  └──────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────┘
```

### 2.4 Auto-Detection-Einschränkung

Der Auto-Detection-Modus (`PathParser.parse(input)` ohne Plattform-Angabe) ist ein **Heuristik-Modus** und kann in Grenzfällen falsch liegen:

- `/C/Users` sieht ohne Kontext wie ein Windows-Pfad aus, ist aber auf Linux ein valider POSIX-Pfad.
- `foo\bar` könnte Windows-Stil oder ein ungewöhnlicher POSIX-Dateiname sein.

**Empfehlung:** In portablem Code immer `PathParser.parse_as(input, Platform.current())` verwenden. Auto-Detection (`parse`) ist nur für interaktive Tools geeignet, die Pfade aus Benutzereingaben lesen und die Plattform nicht kennen.

### 2.5 Unicode & Normalisierung

macOS verwendet NFD (Decomposed) als Dateisystem-Normalisierung, Linux keine, Windows NFC. Pfade mit Umlauten (`ä`, `ö`, `ü`) oder anderen kombinierten Zeichen unterscheiden sich auf Byte-Ebene zwischen NFD und NFC, obwohl sie visuell identisch sind.

| Plattform | Dateisystem-Normalisierung | Behandlung im Layer |
|-----------|---------------------------|---------------------|
| Linux | Keine (rohe Bytes) | Input wird zu NFC normalisiert |
| macOS (HFS+/APFS) | NFD | Input wird von NFD → NFC konvertiert |
| Windows (NTFS) | NFC | Keine Konvertierung nötig |

Alle Path-Komponenten im UIP-Struct werden **immer als NFC-UTF-8** gespeichert. Vergleiche sind NFC-basiert. Nicht-UTF-8-Bytes auf Linux → `PathParseError.InvalidEncoding`.

---

## 3. Arbeitspakete (WPs)

---

### WP1: Path-Kern-Datenstruktur

#### Grund & Hintergrund

Das Herzstück des Abstraktionslayers ist das **Path-Objekt**. Es kapselt die UIP als unveränderliche Datenstruktur und stellt die primäre API für alle Pfadoperationen bereit. Anders als ein roher String bietet es:

- Strukturierten Zugriff auf Pfadkomponenten (inkl. separater `drive`/`server`/`share`-Felder)
- Typsichere Operationen (`join`, `parent`, etc.)
- Plattformunabhängigkeit (UIP ist immer NFC-UTF-8 mit POSIX-Struktur)
- Vergleichbarkeit und Hashbarkeit für Verwendung in Collections

#### Ziel

Definition und Implementierung des zentralen `Path`-Typs und seiner Kernmethoden in Lyx.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `std/path/path.lyx` | **Neu** | Kern-Datenstruktur + Methoden |
| `std/path/types.lyx` | **Neu** | Typhierarchie (AbsolutePath, RelativePath, etc.) |
| `spec/path-spec.md` | **Neu** | Vollständige API-Spezifikation |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 1.1 | **API-Spezifikation erstellen** | Vollständige Liste aller Path-Methoden (siehe Abschnitt 4). Für jede Methode: Name, Parameter, Rückgabetyp, Semantik, Plattformverhalten, Fehlerfälle. |
| 1.2 | **Path-Struktur definieren** | Lyx-Struct mit Feldern: `components: List<String>` (geordnet, NFC), `is_absolute: bool`, `drive: String?` (nullable, nur Windows-Laufwerk), `server: String?` (nullable, nur UNC), `share: String?` (nullable, nur UNC). |
| 1.3 | **Konstruktoren implementieren** | `Path.new(components, is_absolute, drive, server, share)` – primärer Konstruktor. `Path.from_parts(parts: List<String>)` – erzeugt relativen Pfad aus Segmenten. `Path.from_string(s)` ist ein Convenience-Wrapper um `PathParser.parse(s)` (kein eigener Parser). |
| 1.4 | **`join(other: RelativePath)` implementieren** | Hängt `other` an `self` an und normalisiert das Ergebnis. Compile-Zeit-Fehler wenn `other` absolut ist (WP6). Für dynamischen Dispatch: `join_path(other: Path)` – absolutes `other` ersetzt `self` vollständig (Python-Semantik). |
| 1.5 | **`parent()` implementieren** | Gibt den übergeordneten Pfad zurück. Root-Pfade (`/`, `C:\`, `\\server\share`) geben sich selbst zurück – kein Absturz. |
| 1.6 | **`name()` / `filename()` implementieren** | Letztes Segment. Leere `components` → `""`. |
| 1.7 | **`stem()` / `suffix()` / `suffixes()` implementieren** | `stem()` = Name ohne letzte Erweiterung (`file` bei `file.tar.gz`). `suffix()` = letzte Erweiterung inkl. Punkt (`.gz`). `suffixes()` = alle Erweiterungen (`['.tar', '.gz']`). |
| 1.8 | **`components()` / `parts()` implementieren** | `components()` = rohe Segmentliste. `parts()` = Segmente inkl. Root-Indikator als erstes Element (`/`, `C:\`, `//server/share`). |
| 1.9 | **`ancestors()` implementieren** | Iterator über alle übergeordneten Pfade vom direkten Eltern bis Root (inkl. Root). |
| 1.10 | **`with_name(name)` / `with_suffix(suffix)` implementieren** | Ersetzt letzten Komponenten-Namen bzw. letzte Erweiterung; gibt neues Path-Objekt zurück (immutable). |
| 1.11 | **`relative_to(base: AbsolutePath)` implementieren** | Berechnet relativen Pfad von `self` bezogen auf `base`. Gibt `Result<RelativePath, PathError>` zurück. |
| 1.12 | **`is_relative_to(base: AbsolutePath)` implementieren** | Prüft, ob `self` relativ zu `base` ist (bool). |
| 1.13 | **`as_uri()` implementieren** | Konvertiert Pfad in `file://`-URI gemäß RFC 8089. Windows: `file:///C:/Users/...`. Leerzeichen und Sonderzeichen werden percent-encoded. |
| 1.14 | **`is_valid()` implementieren** | Validiert den Pfad: keine Null-Bytes, keine Steuerzeichen (U+0000–U+001F), nicht überlang für die Zielplattform. |
| 1.15 | **`is_reserved()` implementieren** | Erkennt alle 22 Windows-reservierten Namen (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`) – auch mit Erweiterung (`CON.txt`). Gibt `false` auf Nicht-Windows-Pfaden ohne `drive`-Feld. |
| 1.16 | **`to_string()` implementieren** | Gibt den Pfad als lesbaren Debug-String zurück (POSIX-Format, UIP). |
| 1.17 | **Gleichheit & Vergleich implementieren** | `eq(other: Path) -> bool` – NFC, case-sensitive (kanonischer Vergleich). `eq_case_insensitive(other: Path) -> bool` – für Windows-Semantik. `hash() -> u64` – stabile Hash-Funktion, konsistent mit `eq` (d.h. `eq(a,b)` impliziert `hash(a) == hash(b)`). |
| 1.18 | **`join_str(s: String)` implementieren** | Convenience: parst `s` via `PathParser.parse(s)` und ruft `join_path` auf. Gibt `Result<Path, PathParseError>` zurück. |

#### Abnahmekriterien

- [ ] `Path` ist ein immutable Struct – alle „ändernden" Operationen geben ein neues Objekt zurück
- [ ] Alle Kernmethoden (1.4–1.18) sind implementiert und getestet
- [ ] `join(absolute)` → Compile-Fehler (WP6); `join_path(absolute)` → gibt `absolute` zurück
- [ ] `parent()` aller Root-Pfade gibt den Root-Pfad zurück (kein Absturz)
- [ ] `suffix()` von `file.tar.gz` → `.gz`; `suffixes()` → `['.tar', '.gz']`
- [ ] `eq` ist case-sensitive; `eq_case_insensitive` normalisiert Groß-/Kleinschreibung
- [ ] `hash(a) == hash(b)` wenn `eq(a, b)` (Hash-Konsistenz)
- [ ] `is_reserved()` erkennt alle 22 reservierten Namen inkl. Erweiterungsvarianten
- [ ] API-Spezifikation (1.1) liegt als separates Dokument vor

#### Aufwand

**3 Wochen** (bei 1 Entwickler)

#### Abhängigkeiten

Keine – WP1 ist die Basis für alle folgenden WPs.

---

### WP2: PathParser (Ingress)

#### Grund & Hintergrund

Ein Lyx-Programm erhält Pfade typischerweise als Strings:
- Von der Kommandozeile (`argv`)
- Aus Konfigurationsdateien
- Von Benutzereingaben (inkl. `~/`-Pfaden)
- Von Dateisystem-Aufrufen (`readdir`, `getcwd`)

Der **PathParser** wandelt diese plattformspezifischen Strings in das UIP-Path-Objekt um.

#### Beziehung zu `Path.from_string`

`Path.from_string(s)` ist ein Convenience-Wrapper, der intern `PathParser.parse(s)` aufruft. Für explizite Plattformkontrolle und Fehlerbehandlung sollte `PathParser` direkt verwendet werden.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `std/path/parser.lyx` | **Neu** | PathParser-Dispatcher |
| `std/path/parser_win.lyx` | **Neu** | Windows-spezifische Parsing-Logik |
| `std/path/parser_posix.lyx` | **Neu** | POSIX-spezifische Parsing-Logik |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 2.1 | **Plattformerkenner implementieren** | Heuristik: Windows wenn `[A-Za-z]:` am Anfang oder `\\` am Anfang. POSIX wenn `/` am Anfang. Relativ sonst. Achtung: Nur Heuristik – `parse_as` ist die empfohlene Variante. |
| 2.2 | **Windows-Parser implementieren** | `C:\Users\file.txt` → drive=`C`, components=`['Users','file.txt']`, is_absolute=`true`. Trennzeichen `\` wird intern zu `/` normalisiert. |
| 2.3 | **UNC-Parser implementieren** | `\\server\share\path` → server=`server`, share=`share`, components=`['path']`, is_unc=`true`, is_absolute=`true`. |
| 2.4 | **POSIX-Parser implementieren** | `/home/user/file.txt` → components=`['home','user','file.txt']`, is_absolute=`true`. |
| 2.5 | **Relativ-Parser implementieren** | `relative/path/./to/../file.txt` → Rohkomponenten (ohne Normalisierung), is_absolute=`false`. |
| 2.6 | **Fehlerbehandlung implementieren** | Leere Strings, Null-Bytes (`\0`), Steuerzeichen (U+0000–U+001F), überlange Pfade. Rückgabe via `Result<Path, PathParseError>`. |
| 2.7 | **Auto-Detection-Modus** | `PathParser.parse(input: String) -> Result<Path, PathParseError>` – Heuristik, nur für interaktive Tools. Dokumentiert als „nicht für portablen Code". |
| 2.8 | **Expliziter Plattform-Modus** | `PathParser.parse_as(input: String, platform: Platform) -> Result<Path, PathParseError>` – kanonischer Weg für portablen Code. |
| 2.9 | **Tilde-Expansion** | `PathParser.parse_with_home(input: String, home: AbsolutePath) -> Result<Path, PathParseError>`: `~/foo` → `<home>/foo`. `~user/foo` (benutzerspezifische Expansion) wird **explizit abgelehnt** (`PathParseError.TildeUserExpansionNotSupported`) – sie erfordert Datenbankzugriff und ist ein potenzielles Sicherheitsrisiko. |
| 2.10 | **Unicode-Normalisierung** | Nach dem Parsen alle Komponenten zu NFC normalisieren (NFD-Eingaben von macOS werden korrekt konvertiert). Nicht-UTF-8-Bytes → `PathParseError.InvalidEncoding`. |

#### Abnahmekriterien

- [ ] `C:\Users\file.txt` → drive=`C`, components=`['Users','file.txt']`, is_absolute
- [ ] `\\server\share\data.csv` → server=`server`, share=`share`, components=`['data.csv']`, is_unc
- [ ] `/home/user/doc.pdf` → POSIX-Komponenten, is_absolute
- [ ] `~/documents` + home=`/home/user` → AbsolutePath `/home/user/documents`
- [ ] `~user/foo` → `PathParseError.TildeUserExpansionNotSupported`
- [ ] NFD-String `ä` (a + Combining Diaeresis) → NFC `ä`
- [ ] Leerer String → `PathParseError.EmptyPath`
- [ ] String mit Null-Byte → `PathParseError.InvalidCharacter('\0')`
- [ ] Parser ist stabil bei 10.000+ zufälligen Pfaden (Fuzz-Test)

#### Aufwand

**2 Wochen**

#### Abhängigkeiten

WP1 (Path-Objekt muss existieren)

---

### WP3: PathNormalizer

#### Grund & Hintergrund

Pfade enthalten oft Redundanzen:
- Doppelte Trennzeichen (`//` → `/`)
- `.` (aktuelles Verzeichnis) kann entfernt werden
- `..` (übergeordnetes Verzeichnis) muss syntaktisch aufgelöst werden

**Abgrenzung:** Die Normalisierung ist **rein syntaktisch und dateisystem-unabhängig** – sie greift nie auf die Festplatte zu und löst keine Symlinks auf. Symlink-Auflösung ist Aufgabe von WP8.

#### Ziel

Normalizer-Komponente, die ein Path-Objekt bereinigt und konsistent macht.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `std/path/normalizer.lyx` | **Neu** | PathNormalizer-Implementierung |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 3.1 | **Leere Segmente entfernen** | Leere Einträge in `components` (entstehen durch doppelte Trennzeichen) werden entfernt. Da `server`/`share` dedizierte Felder sind, gibt es keinen UNC-Sonderfall mehr. |
| 3.2 | **`.` (Aktuell-Verzeichnis) entfernen** | Alle `.`-Segmente streichen. |
| 3.3 | **`..` (Übergeordnet) auflösen** | Bei **absolutem** Pfad: `..` entfernt das vorhergehende Segment; `..` an Root-Grenze wird ignoriert (verhindert Over-Root). Bei **relativem** Pfad: `..` bleibt erhalten, wenn kein vorhergehendes Segment vorhanden (`../../foo` bleibt `../../foo`). |
| 3.4 | **Trailing-Leersegment entfernen** | Abschließendes leeres Segment (von `path/`) entfernen. Root-Pfade bleiben unverändert. |
| 3.5 | **Case-Normalisierung (optional)** | `PathNormalizer.normalize_case(path) -> Path`: Alle Komponenten zu Lowercase. Nicht standardmäßig aktiv; nur für Windows-Pfadvergleiche sinnvoll. |

#### Abnahmekriterien

- [ ] `/foo//bar` → `/foo/bar`
- [ ] `/foo/./bar` → `/foo/bar`
- [ ] `/foo/bar/../baz` → `/foo/baz`
- [ ] `./relative/path` → `relative/path`
- [ ] `/../foo` → `/foo` (Root-Grenze, absoluter Pfad)
- [ ] `/foo/bar/../../../../baz` → `/baz` (mehrfacher Over-Root)
- [ ] `../../foo` (relativ) → `../../foo` (kein Fehler, `..` bleibt)
- [ ] Normalisierung ist **idempotent**: `normalize(normalize(p)) == normalize(p)`
- [ ] Normalisierung ist **rein** (kein Dateisystemzugriff, keine Seiteneffekte)

#### Aufwand

**1 Woche**

#### Abhängigkeiten

WP1 (Path-Objekt)

---

### WP4: PathResolver

#### Grund & Hintergrund

Relative Pfade sind erst dann nützlich, wenn sie zu einem absoluten Bezugspunkt aufgelöst werden. Der PathResolver kombiniert einen relativen Pfad mit einem Basis-Pfad und normalisiert das Ergebnis.

> **Sicherheitshinweis:** `strict_resolve` ist eine **Pflichtimplementierung**, keine optionale Erweiterung. Directory-Traversal-Angriffe (`../../etc/passwd`) zählen zu den häufigsten Sicherheitslücken in Dateisystem-Code. Jede Anwendung, die Benutzereingaben als Pfade verarbeitet, muss `strict_resolve` verwenden.

#### Ziel

Resolver-Komponente, die relative Pfade gegen einen bekannten absoluten Pfad auflöst.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `std/path/resolver.lyx` | **Neu** | PathResolver-Implementierung |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 4.1 | **`resolve(base: AbsolutePath, relative: RelativePath) -> AbsolutePath`** | Kombiniert `base` + `relative` und normalisiert. Aus `/home/user` + `docs/file.txt` → `/home/user/docs/file.txt`. |
| 4.2 | **`resolve_against_cwd(path: RelativePath) -> Result<AbsolutePath, ResolveError>`** | Ruft `getcwd()` auf und verwendet das Ergebnis als Basis. Fehler: `ResolveError.CwdNotAvailable` bei Syscall-Fehler. |
| 4.3 | **`strict_resolve(base: AbsolutePath, relative: RelativePath) -> Result<AbsolutePath, ResolveError>`** | Wie `resolve`, schlägt aber mit `ResolveError.PathAboveBase` fehl, wenn das normalisierte Ergebnis nicht unterhalb von `base` liegt. **Pflicht für alle User-Input-Pfade.** |
| 4.4 | **`try_resolve(base: AbsolutePath, relative: RelativePath) -> Result<AbsolutePath, ResolveError>`** | Wie `resolve`, gibt `Result` statt zu panicken. |

#### Abnahmekriterien

- [ ] `resolve('/home/user', 'file.txt')` → `/home/user/file.txt`
- [ ] `resolve('/home/user', '../other')` → `/home/other`
- [ ] `resolve('/home/user', '../../../etc/passwd')` → `/etc/passwd` (erlaubt – Sicherheitsprüfung obliegt dem Aufrufer)
- [ ] `strict_resolve('/home/user', '../../etc/passwd')` → `Err(PathAboveBase)` (**Pflicht, nicht optional**)
- [ ] `strict_resolve('/home/user', 'subdir/file.txt')` → `/home/user/subdir/file.txt` (Erfolg)
- [ ] `resolve_against_cwd(...)` verwendet das tatsächliche CWD
- [ ] Ergebnis von `resolve` und `strict_resolve` ist immer absolut und normalisiert

#### Aufwand

**1 Woche**

#### Abhängigkeiten

WP1 (Path-Objekt), WP3 (Normalizer)

---

### WP5: PathTranslator (Egress)

#### Grund & Hintergrund

Bevor ein Path-Objekt an das Betriebssystem übergeben wird (an `open()`, `stat()`, `mkdir()` etc.), muss es in den plattformspezifischen String zurückübersetzt werden. Der PathTranslator liest die dedizierten `drive`/`server`/`share`-Felder aus dem Struct und baut den nativen String daraus.

#### Ziel

Translator-Komponente, die ein UIP-Path-Objekt in einen plattformspezifischen Pfad-String übersetzt.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `std/path/translator.lyx` | **Neu** | PathTranslator-Dispatcher |
| `std/path/translator_win.lyx` | **Neu** | Windows-spezifische Übersetzung |
| `std/path/translator_posix.lyx` | **Neu** | POSIX-spezifische Übersetzung |
| `std/path/translator_wsl.lyx` | **Neu** | WSL-spezifische Übersetzung |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 5.1 | **Konfiguration: Zielplattform** | Per Compile-Zeit-Konstante (Target-Triple) oder `Platform`-Enum zur Laufzeit. |
| 5.2 | **POSIX-Translator** | Kein `drive`/`server`/`share`: `/` + components.join(`/`). Hat `drive`-Feld: `/` + drive + `/` + components.join(`/`) (POSIX-kompatible Darstellung ohne Backslash). |
| 5.3 | **Windows-Translator** | `drive`=`C` → `C:\` + components.join(`\`). `server`/`share` gesetzt → `\\server\share\` + components.join(`\`). |
| 5.4 | **WSL-Translator** | `drive`=`C` → `/mnt/c/` + components.join(`/`). Kein `drive` → POSIX-Pfad unverändert. Konfigurierbares Mount-Präfix (Standard: `/mnt/`). |
| 5.5 | **macOS-Translator** | Wie POSIX-Translator. Optional: Case-Normalisierung als zusätzlicher Pass. |
| 5.6 | **Fallback-Logik für POSIX-Pfade auf Windows** | Pfad ohne `drive` auf Windows-Zielplattform: Mapping auf konfigurierbares `default_drive` (Standard: `C`), z.B. `/home/user` → `C:\home\user`. Alternativ: `TranslatorError.NoDriveForPosixPath` wenn kein Mapping konfiguriert. |
| 5.7 | **`to_platform_string(path: Path, platform: Platform) -> Result<String, TranslatorError>`** | Explizite Plattform-Angabe. |
| 5.8 | **`to_native_string(path: Path) -> Result<String, TranslatorError>`** | Verwendet die Plattform des aktuellen Systems. |

#### Abnahmekriterien

- [ ] drive=`C`, components=`['Users','User','file.txt']` → Windows `C:\Users\User\file.txt`
- [ ] server=`server`, share=`share`, components=`['data.csv']` → Windows `\\server\share\data.csv`
- [ ] components=`['home','user','doc.pdf']`, is_absolute → Linux `/home/user/doc.pdf`
- [ ] drive=`C`, components=`['Users','User','file.txt']` → WSL `/mnt/c/Users/User/file.txt`
- [ ] Ausgabe enthält keine gemischten Trennzeichen
- [ ] Roundtrip-Invarianz: `parse_as(translate(path, plat), plat) == path` für alle unterstützten Plattformen

#### Aufwand

**2 Wochen**

#### Abhängigkeiten

WP1 (Path-Objekt)

---

### WP6: Typsicherheit – Absolute/Relative-Trennung

#### Grund & Hintergrund

Eine der größten Fehlerquellen bei Pfadoperationen ist das falsche Kombinieren von Pfaden. Das Lyx-Typsystem soll diese Fehler **zur Compile-Zeit** abfangen.

#### API-Vereinheitlichung: `join` vs. `join_path`

Es gibt zwei Varianten mit unterschiedlichem Sicherheitsniveau:

| Methode | Signatur | Sicherheit | Verwendung |
|---------|----------|------------|------------|
| `join` | `(self: AbsolutePath, other: RelativePath) -> AbsolutePath` | Compile-Zeit | Typsicherer Code (Standardfall) |
| `join_path` | `(self: Path, other: Path) -> Path` | Laufzeit | Dynamischer Dispatch, Interop mit unbekannten Pfad-Typen |

`join_path` mit absolutem `other` ersetzt `self` vollständig (Python-Semantik). `join` mit absolutem `other` ist ein Compile-Fehler.

#### Ziel

Eine Typhierarchie, die verschiedene Pfad-Arten als unterschiedliche Typen modelliert.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `std/path/types.lyx` | **Neu** | Vollständige Typhierarchie |
| `std/path/type_assertions.lyx` | **Neu** | Typkonvertierungs-Funktionen |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 6.1 | **Typhierarchie definieren** | `Path = AbsolutePath | RelativePath`. `AbsolutePath = PosixPath | WindowsDrivePath | UncPath`. **Fallback** falls Lyx-Generics nicht ausreichen: Wrapper-Struct mit `PathKind`-Runtime-Tag + Compile-Zeit-Assertions via Makros oder Konvention. |
| 6.2 | **Typkonvertierung implementieren** | `RelativePath.to_absolute(base: AbsolutePath) -> AbsolutePath`. `AbsolutePath.to_relative(base: AbsolutePath) -> Option<RelativePath>`. |
| 6.3 | **Typsichere Methoden-Signaturen** | `join(self: AbsolutePath, other: RelativePath) -> AbsolutePath` + `join_path(self: Path, other: Path) -> Path` für Laufzeit-Dispatch. |
| 6.4 | **Pattern-Matching-Unterstützung** | `match path { case p: AbsolutePath => ... case p: RelativePath => ... }` – typsicherer Dispatch. |
| 6.5 | **`as_absolute()` / `as_relative()` Casts** | Explizite Laufzeit-Konvertierung: `Result<AbsolutePath, PathError>` bzw. `Result<RelativePath, PathError>`. |
| 6.6 | **Integration mit PathParser** | Parser gibt je nach Eingabe `AbsolutePath` oder `RelativePath` zurück. |

#### Abnahmekriterien

- [ ] `join(a: AbsolutePath, b: AbsolutePath)` → Compile-Fehler
- [ ] `join(a: AbsolutePath, b: RelativePath)` → `AbsolutePath`
- [ ] `join_path(a: AbsolutePath, b: AbsolutePath)` → `b` (absoluter Pfad ersetzt Basis, Laufzeit)
- [ ] Pattern-Matching auf Path-Typen funktioniert
- [ ] Fallback-Implementierung (Runtime-Tag) liegt als dokumentierte Alternative bereit
- [ ] Bestehender Lyx-Code mit rohen `pchar`-Pfaden bleibt vollständig abwärtskompatibel

#### Aufwand

**2–3 Wochen** (stark abhängig von Lyx' aktuellem Generics-/Typsystem-Support)

#### Abhängigkeiten

WP1, Lyx-Generics (müssen für Summentyp `Path` geeignet sein)

---

### WP7: Integration in die Lyx-Standardbibliothek

#### Grund & Hintergrund

Ein Abstraktionslayer ist nur dann nützlich, wenn er mit der bestehenden Stdlib und den Dateisystem-Operationen zusammenspielt. Aktuell arbeiten `std/fs.lyx` und `std/os.lyx` mit rohen `pchar`-Pfaden. Ziel ist es, Path-Objekte als First-Class-Citizen in der Stdlib zu etablieren.

#### Ziel

Integration des Path-Layers in die bestehende Stdlib: Erweiterungen für `std/fs.lyx`, `std/os.lyx` und neue Convenience-Funktionen.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `std/path/package.lyx` | **Neu** | Paket-Index (exportiert alle Submodule) |
| `std/fs.lyx` | **Erweiterung** | Neue Funktionen mit Path-Parametern (zusätzlich zu pchar) |
| `std/os.lyx` | **Erweiterung** | `getcwd_path()`, `chdir_path()`, `home_dir()` |
| `std/path/fs_integration.lyx` | **Neu** | Bridge zwischen Path-Objekt und Syscall-Ebene |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 7.1 | **`Path.to_native()` implementieren** | Konvertiert Path → plattformspezifischer `pchar`-String via PathTranslator. Intern von allen fs-Wrappern verwendet. |
| 7.2 | **`fs.open(path: Path, flags: int64) -> Result<fd>`** | Wrapper um existierenden Syscall. Intern: `Path.to_native()`. |
| 7.3 | **`fs.exists(path: Path) -> bool`** | Via `access()` aus `std/os.lyx`. |
| 7.4 | **`fs.is_dir(path: Path) -> bool`** | Via `stat()`. |
| 7.5 | **`fs.is_file(path: Path) -> bool`** | Via `stat()`. |
| 7.6 | **`fs.read_dir(path: Path) -> Result<List<Path>>`** | Liest Verzeichnis aus, gibt Liste von Path-Objekten zurück (nicht Strings). |
| 7.7 | **`os.getcwd_path() -> Result<AbsolutePath, ResolveError>`** | Wrapper für `getcwd()`, gibt Path-Objekt zurück. |
| 7.8 | **`os.chdir_path(path: AbsolutePath) -> Result`** | Wrapper für `chdir()`, akzeptiert Path-Objekt. |
| 7.9 | **`os.home_dir() -> Result<AbsolutePath, OsError>`** | Liest `HOME` (POSIX) bzw. `USERPROFILE` oder `HOMEDRIVE`+`HOMEPATH` (Windows). Wird von WP2 Tilde-Expansion intern verwendet. |
| 7.10 | **Dokumentation** | Stdlib-Referenz für das neue `std/path/`-Modul schreiben. |

#### Abnahmekriterien

- [ ] `fs.open(path, O_RDONLY)` funktioniert mit Path-Objekt (nicht nur pchar)
- [ ] `fs.read_dir(path)` gibt `List<Path>` zurück (nicht `List<String>`)
- [ ] `os.getcwd_path()` gibt `AbsolutePath` zurück
- [ ] `os.home_dir()` gibt korrekte Home-Directory auf Linux und Windows zurück
- [ ] Alle alten `pchar`-basierten Funktionen bleiben vollständig abwärtskompatibel
- [ ] Beispiel `examples/filesystem/path_demo.lyx` compiliert und läuft auf Linux und Windows

#### Aufwand

**2–3 Wochen**

#### Abhängigkeiten

WP1–WP6

---

### WP8: Symlink-Handling & Canonicalization

#### Grund & Hintergrund

Alle bisherigen WPs arbeiten **rein syntaktisch** – sie greifen nie auf das Dateisystem zu. Symlinks können dazu führen, dass zwei syntaktisch verschiedene Pfade auf dieselbe Datei zeigen. Für Anwendungen, die damit umgehen müssen (Sicherheitsprüfungen, Build-Systeme, Dateisystem-Watches), wird eine eigene Komponente benötigt.

**Abgrenzung zum PathNormalizer (WP3):** WP3 löst `.` und `..` rein syntaktisch auf, ohne das Dateisystem zu berühren. WP8 löst zusätzlich **Symlinks** auf und liefert den echten kanonischen Pfad durch `realpath`-Semantik.

**Embedded-Targets:** Cortex-M und Xtensa haben kein Dateisystem. WP8-Funktionen geben auf diesen Targets `CanonicalizeError.NotSupported` zurück – kein Crash.

#### Ziel

Canonicalization-Komponente, die den echten absoluten Pfad einer Datei durch Dateisystemzugriff ermittelt.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `std/path/canonicalizer.lyx` | **Neu** | PathCanonicalizer-Implementierung |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 8.1 | **`canonicalize(path: AbsolutePath) -> Result<AbsolutePath, CanonicalizeError>`** | POSIX: Wrapper um `realpath(3)`. Windows: Wrapper um `GetFinalPathNameByHandle`. Ergebnis ist normalisiert, symlink-frei und existiert auf dem Dateisystem. |
| 8.2 | **`read_link(path: AbsolutePath) -> Result<Path, CanonicalizeError>`** | Liest das direkte Symlink-Ziel (ein Hop, kein vollständiges Auflösen). POSIX: `readlink(2)`. |
| 8.3 | **`is_symlink(path: AbsolutePath) -> Result<bool, OsError>`** | Via `lstat()` auf POSIX; Reparse-Point-Prüfung auf Windows. |
| 8.4 | **`try_canonicalize(path: AbsolutePath) -> Result<AbsolutePath, CanonicalizeError>`** | Wie `canonicalize`, immer `Result`, nie panic. |
| 8.5 | **Fehlertyp `CanonicalizeError` definieren** | `NoSuchFile`, `PermissionDenied`, `TooManySymlinks` (ELOOP), `NotSupported` (Embedded-Targets). |
| 8.6 | **Windows-Einschränkungen und Embedded-Stubs dokumentieren** | Windows: `GetFinalPathNameByHandle` erfordert `GENERIC_READ`. Embedded: Stub gibt `NotSupported` zurück. |

#### Abnahmekriterien

- [ ] `canonicalize('/home/user/link')` gibt echten Ziel-Pfad zurück (wenn `link` ein Symlink ist)
- [ ] `read_link('/home/user/link')` gibt das direkte Symlink-Ziel zurück (1 Hop)
- [ ] `is_symlink('/regular/file')` → `false`
- [ ] `is_symlink('/path/to/symlink')` → `true`
- [ ] `canonicalize('/nonexistent')` → `Err(CanonicalizeError.NoSuchFile)`
- [ ] Zirkuläre Symlinks → `Err(CanonicalizeError.TooManySymlinks)` (kein Hang)
- [ ] Embedded-Target: alle WP8-Funktionen → `Err(CanonicalizeError.NotSupported)` statt Crash

#### Aufwand

**1 Woche**

#### Abhängigkeiten

WP1 (Path-Objekt), WP7 (`stat`/`lstat` müssen über Stdlib verfügbar sein)

---

### WP9: Test-Suite & Validierung

#### Grund & Hintergrund

Ein Path-Abstraktionslayer ist eine Querschnittskomponente, die von allen Dateisystem-Operationen genutzt wird. Fehler führen zu korrupten Dateipfaden, Sicherheitslücken (Directory-Traversal) und Datenverlust. Eine umfassende Test-Suite ist zwingend erforderlich.

#### Ziel

Automatisierte Test-Suite, die alle Path-Operationen auf Korrektheit, Stabilität und Plattformkompatibilität prüft.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `tests/path/test_core.lyx` | **Neu** | Tests für Path-Kern (WP1) |
| `tests/path/test_parser.lyx` | **Neu** | Tests für PathParser (WP2) |
| `tests/path/test_normalizer.lyx` | **Neu** | Tests für PathNormalizer (WP3) |
| `tests/path/test_resolver.lyx` | **Neu** | Tests für PathResolver (WP4) |
| `tests/path/test_translator.lyx` | **Neu** | Tests für PathTranslator (WP5) |
| `tests/path/test_types.lyx` | **Neu** | Tests für Typsicherheit (WP6) |
| `tests/path/test_integration.lyx` | **Neu** | Integrationstests (WP7) |
| `tests/path/test_symlinks.lyx` | **Neu** | Tests für Symlink-Handling (WP8) |
| `tests/path/test_fuzz.lyx` | **Neu** | Fuzz-Tests mit zufälligen Pfaden |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 9.1 | **Kern-Tests (WP1)** | Jede Methode mit Normal-, Grenz- und Fehlerfällen. Mindestens 5 Tests pro Methode. Einschließlich: Gleichheit, Hash-Konsistenz, `is_reserved()` für alle 22 reservierten Namen. |
| 9.2 | **Parser-Tests (WP2)** | Matrix: Jede Plattform × Korrektheit × Fehlerfälle × Grenzfälle. Tilde-Expansion. NFD→NFC-Konvertierung. `~user/`-Ablehnung. |
| 9.3 | **Normalizer-Tests (WP3)** | Idempotenz-Tests, `..`-Auflösung mit Over-Root, relative `..`-Erhaltung. |
| 9.4 | **Resolver-Tests (WP4)** | Korrekte Auflösung, `strict_resolve` gegen OWASP Directory-Traversal-Muster (`../`, `..%2F`, `..%5C` etc.), CWD-Abhängigkeit. |
| 9.5 | **Translator-Tests (WP5)** | Roundtrip für alle Plattformkombinationen (Linux↔Windows↔WSL↔macOS). Fallback-Logik. |
| 9.6 | **Type-Tests (WP6)** | Compile-Zeit-Fehler für falsche `join`-Kombination. Laufzeit-Konvertierungen. `join_path`-Semantik bei absolutem Argument. |
| 9.7 | **Integrationstests (WP7)** | `fs.open(path)` → Datei lesen → Inhalt prüfen. `os.home_dir()` auf Linux + Windows. |
| 9.8 | **Symlink-Tests (WP8)** | Symlink erstellen → `canonicalize` → prüfen. Zirkuläre Symlinks → kein Hang. `read_link` gibt 1-Hop-Ziel zurück. |
| 9.9 | **Fuzz-Tests** | 10.000+ zufällige Pfad-Strings: parsen, normalisieren, übersetzen – keine Abstürze, Endlosschleifen oder Panicken. |
| 9.10 | **Snapshot-Tests** | Vordefinierte Pfad-Strings → erwartete UIP-Repräsentation → erwartete plattformspezifische Ausgabe. Versioniert und bei Änderungen explizit zu aktualisieren. |
| 9.11 | **Plattform-Matrix (CI)** | Gleiche Test-Suite auf Linux + Windows ausführen (CI-Pipeline). |

#### Abnahmekriterien

- [ ] Alle Kern-Tests (9.1) 100 %
- [ ] Fuzz-Tests (9.9) laufen 1 Stunde ohne Absturz
- [ ] Roundtrip-Invarianz: `parse_as(translate(p, plat), plat) == p` für Linux, Windows, macOS
- [ ] `strict_resolve`-Tests decken alle gängigen Directory-Traversal-Muster ab
- [ ] Snapshot-Tests (9.10) sind versioniert
- [ ] Code-Coverage des Path-Layers > 90 %

#### Aufwand

**2–3 Wochen** (parallel zu WP1–WP8, Schwerpunkt nach Abschluss der Implementierung)

#### Abhängigkeiten

WP1–WP8

---

## 4. Vollständige API-Referenz (Spezifikation)

### 4.1 Path-Kern-Methoden

```
Path = {
  // Konstruktoren
  new(components, is_absolute, drive?, server?, share?) -> Path,
  from_string(s: String) -> Result<Path, ParseError>,              // Convenience-Wrapper um PathParser.parse
  from_parts(parts: List<String>) -> RelativePath,

  // Abfragen (rein syntaktisch)
  components() -> List<String>,
  parts() -> List<String>,                                         // inkl. Root-Indikator als erstes Element
  is_absolute() -> bool,
  is_relative() -> bool,
  is_root() -> bool,
  has_root() -> bool,

  // Abfragen (mit Dateisystem-I/O)
  exists() -> bool,
  is_dir() -> bool,
  is_file() -> bool,
  is_symlink() -> bool,                                            // via lstat

  // Navigation
  join(other: RelativePath) -> AbsolutePath,                       // Compile-Zeit-sicher (WP6)
  join_path(other: Path) -> Path,                                  // Laufzeit; absolutes other ersetzt self
  join_str(s: String) -> Result<Path, PathParseError>,             // Convenience
  parent() -> Path,
  ancestors() -> List<Path>,
  relative_to(base: AbsolutePath) -> Result<RelativePath, PathError>,
  is_relative_to(base: AbsolutePath) -> bool,

  // Extraktion
  name() -> String,
  stem() -> String,
  suffix() -> String,                                              // letzte Erweiterung (z.B. .gz bei file.tar.gz)
  suffixes() -> List<String>,                                      // alle Erweiterungen (['.tar', '.gz'])
  with_name(name: String) -> Path,
  with_suffix(suffix: String) -> Path,

  // Konvertierung
  to_string() -> String,                                           // UIP-Debug-String
  to_native() -> String,                                           // plattformspezifisch via PathTranslator
  as_uri() -> String,                                              // file://-URI gemäß RFC 8089
  to_absolute(base: AbsolutePath) -> AbsolutePath,
  to_relative(base: AbsolutePath) -> Result<RelativePath, PathError>,

  // Validierung
  is_valid() -> bool,
  is_reserved() -> bool,                                           // Windows CON/PRN/AUX/NUL/COM*/LPT*

  // Gleichheit & Hashing
  eq(other: Path) -> bool,                                         // NFC, case-sensitive
  eq_case_insensitive(other: Path) -> bool,                        // für Windows-Semantik
  hash() -> u64,                                                   // konsistent mit eq
}
```

### 4.2 PathParser

```
PathParser = {
  parse(input: String) -> Result<Path, PathParseError>,
    // Heuristik-Erkennung; nur für interaktive Tools

  parse_as(input: String, platform: Platform) -> Result<Path, PathParseError>,
    // Empfohlen für portablen Code

  parse_with_home(input: String, home: AbsolutePath) -> Result<Path, PathParseError>,
    // Tilde-Expansion: ~/foo wird zu <home>/foo aufgelöst
    // ~user/foo wird mit PathParseError.TildeUserExpansionNotSupported abgelehnt
}
```

### 4.3 PathCanonicalizer (WP8)

```
PathCanonicalizer = {
  canonicalize(path: AbsolutePath) -> Result<AbsolutePath, CanonicalizeError>,
    // Löst Symlinks vollständig auf (realpath-Semantik)

  try_canonicalize(path: AbsolutePath) -> Result<AbsolutePath, CanonicalizeError>,
    // Wie canonicalize, aber immer Result statt panic

  read_link(path: AbsolutePath) -> Result<Path, CanonicalizeError>,
    // Liest Symlink-Ziel (1 Hop, kein vollständiges Auflösen)

  is_symlink(path: AbsolutePath) -> Result<bool, OsError>,
    // Prüft ob path ein Symlink ist (via lstat)
}
```

### 4.4 Typhierarchie

```
Path = AbsolutePath | RelativePath

AbsolutePath = PosixPath | WindowsDrivePath | UncPath

PosixPath = {
  // is_absolute=true, drive=null, server=null, share=null
  // Beispiel: /home/user/file.txt
}

WindowsDrivePath = {
  // is_absolute=true, drive="C" (o.ä.), server=null, share=null
  // Beispiel extern: C:\Users\file.txt
  // Intern:          drive="C", components=["Users","file.txt"]
  drive: String,
}

UncPath = {
  // is_absolute=true, drive=null, server="srv", share="shr"
  // Beispiel extern: \\server\share\path
  // Intern:          server="server", share="share", components=["path"]
  server: String,
  share: String,
}

RelativePath = {
  // is_absolute=false
  // Beispiel: relative/path/to/file.txt  oder  ../../parent/file.txt
}
```

### 4.5 Fehlertypen

```
PathParseError = {
  EmptyPath,
  InvalidCharacter(char),
  InvalidEncoding,                               // Nicht-UTF-8-Bytes
  TooLong(max_length: int64),
  MixedSeparators,
  ReservedName(String),                          // Windows: CON, PRN, AUX, NUL, COM*, LPT*
  TildeUserExpansionNotSupported,                // ~user/... wird nicht unterstützt
}

PathResolveError = {
  BaseIsRelative,
  PathAboveBase,                                 // strict_resolve: Ergebnis liegt oberhalb der Basis
  CannotBeRelative,                              // to_relative fehlgeschlagen
  CwdNotAvailable,
  IOError(int64),                                // errno bei getcwd-Fehler
}

CanonicalizeError = {
  NoSuchFile,
  PermissionDenied,
  TooManySymlinks,                               // ELOOP – zirkuläre Symlinks
  NotSupported,                                  // Embedded-Targets ohne Dateisystem
  IOError(int64),
}

TranslatorError = {
  NoDriveForPosixPath,                           // POSIX-Pfad ohne Laufwerksbuchstabe auf Windows
}
```

---

## 5. Abhängigkeitsgraph

```
WP1 (Path-Kern) ──────────────────────────────────────────────────────────────┐
  │                                                                            │
  ├── WP2 (PathParser) ──── benötigt Path-Struct ──────────────────────────────┤
  ├── WP3 (Normalizer) ──── benötigt Path-Struct ──────────────────────────────┤
  ├── WP5 (Translator) ──── benötigt Path-Struct ──────────────────────────────┤
  └── WP6 (Typsicherheit) ── benötigt Lyx-Generics ───────────────────────────┤
                                                                               │
WP2 + WP3 + WP5 + WP6 ──────────────────────────────────────────────────────── ┤
  │                                                                              ├─▶ WP7 (Stdlib-Integration)
  └── WP4 (Resolver) ──── benötigt WP1 + WP3 ────────────────────────────────── ┘
                                                                   │
                                                                   ▼
                                                         WP8 (Symlinks) ── benötigt WP1 + WP7

WP1 + WP2 + WP3 + WP4 + WP5 + WP6 + WP7 + WP8 ──────────────────────────────▶ WP9 (Tests)
```

**Kritischer Pfad:** WP1 → WP2 → WP4 → WP7 → WP8  
**Parallelisierbar nach WP1:** WP2 + WP3 + WP5 + WP6

---

## 6. Zeitplan (Schätzung)

| WP | Feature | Aufwand | Start (relativ) | Dauer |
|----|---------|---------|-----------------|-------|
| 1 | Path-Kern (inkl. Gleichheit, Hash) | 3 MW | Monat 1 | 3 Wochen |
| 2 | PathParser (inkl. Tilde, Unicode) | 2 MW | Monat 1 (nach WP1) | 2 Wochen |
| 3 | PathNormalizer | 1 MW | Monat 1 (parallel zu WP2) | 1 Woche |
| 4 | PathResolver (`strict_resolve` Pflicht) | 1 MW | Monat 2 (nach WP1+3) | 1 Woche |
| 5 | PathTranslator (Egress) | 2 MW | Monat 2 (nach WP1) | 2 Wochen |
| 6 | Typsicherheit | 2–3 MW | Monat 2–3 | 3 Wochen |
| 7 | Stdlib-Integration (inkl. `home_dir`) | 2–3 MW | Monat 3–4 | 3 Wochen |
| 8 | Symlink-Handling & Canonicalization | 1 MW | Monat 4 (nach WP7) | 1 Woche |
| 9 | Test-Suite | 2–3 MW | Parallel zu WP1–8 | 4 Wochen |

**Kritischer Pfad:** WP1 → WP2 → WP4 → WP7 → WP8  
**Parallelisierbar:** WP2 + WP3 + WP5 + WP6 (nach WP1)  
**Gesamtdauer:** **4–5 Monate** bei 1 Entwickler, **2–3 Monate** bei 2 Entwicklern

---

## 7. Risiken & Annahmen

| Risiko | Eintrittswahrsch. | Impact | Maßnahme |
|--------|-------------------|--------|----------|
| **Lyx' Generics reichen für Summentyp `Path` nicht aus** | Mittel | Hoch | Fallback: Wrapper-Struct + `PathKind`-Runtime-Tag. Compile-Zeit-Sicherheit über Lyx-Makros oder Konvention statt Typsystem. Fallback muss vor WP6-Start entschieden werden. |
| **Plattform-Testing auf Windows nicht möglich** | Niedrig | Mittel | CI mit Cross-Compilation + Wine-Testing; ggf. manuelle Tests. Translator-Roundtrip-Tests können auch auf Linux ausgeführt werden. |
| **Performance: Path-Operationen allokieren Heap** | Mittel | Mittel | Für Embedded: `Path<N>` mit stack-allociertem Array fixer Länge (z.B. `Path<256>`) als optionales Future-Feature vormerken. In v1 nicht implementieren – erst bei konkretem Bedarf. |
| **Inkompatibilität mit bestehendem Code** | Mittel | Mittel | Neue Path-API ist additiv – alte `pchar`-Funktionen bleiben. Kein Breaking Change. |
| **Nicht-UTF-8-Pfade auf Linux (rohe Bytes)** | Mittel | Mittel | `PathParseError.InvalidEncoding` für Nicht-UTF-8. Opt-in „Raw Path"-Modus (binäre Pfade ohne Unicode-Garantie) als Future-Feature vormerken, nicht in v1. |
| **macOS NFD-Normalisierung** | Niedrig | Niedrig | In WP2.10 als Pflicht definiert. NFC-Normalisierung erfolgt beim Parsen – kein Runtime-Overhead danach. |
| **Zirkuläre Symlinks (ELOOP)** | Niedrig | Hoch | Kernel propagiert ELOOP bereits. Im Lyx-Layer: `CanonicalizeError.TooManySymlinks` weiterreichen. |
| **Windows Symlinks erfordern Adminrechte** | Mittel | Mittel | `is_symlink`/`canonicalize` geben `CanonicalizeError.PermissionDenied` zurück. Explizit in Dokumentation und im Fehlertyp. |
| **Embedded-Targets ohne Dateisystem (Cortex-M, Xtensa)** | Hoch (für diese Targets) | Niedrig | WP1–WP6 sind rein syntaktisch und vollständig embedded-kompatibel. WP7-Stdlib-Funktionen und WP8-Canonicalization bekommen `NotSupported`-Stubs. Explizite Dokumentation: „Path-Kern ist embedded-kompatibel; fs-Integration und Canonicalization sind auf Bare-Metal nicht verfügbar." |

---

## 8. Messbarkeit & Erfolgskriterien

### Quantitative Metriken

| Metrik | Zielwert | Messung |
|--------|----------|---------|
| Test-Coverage Path-Layer | > 90 % | Code-Coverage-Analyse |
| Fuzz-Test-Stabilität | 1 Stunde ohne Crash | Automatisierter Fuzz-Lauf |
| Roundtrip-Invarianz | 100 % | `parse_as(translate(p, plat), plat) == p` |
| Plattform-Unterstützung | ≥ 3 (Linux, Windows, macOS) | CI-Pipeline |
| API-Vollständigkeit | 100 % | Abgleich mit Spezifikation (4.1) |
| `strict_resolve` Sicherheitsabdeckung | 100 % der gängigen Traversal-Muster | Manuell definierte OWASP-Angriffsmuster |

### Qualitative Erfolgskriterien

- Ein Lyx-Programm kann **ohne `#if PLATFORM`-Bedingungen** portable Pfadoperationen durchführen
- Der Path-Layer wird in der Lyx-Stdlib als **das primäre Pfad-Interface** verwendet (nicht mehr rohe `pchar`)
- Einsteiger nutzen `Path.from_string(...)`, ohne Plattform-Unterschiede verstehen zu müssen
- Fortgeschrittene nutzen `AbsolutePath`/`RelativePath` für Compile-Zeit-Sicherheit
- Sicherheitsbewusste Entwickler nutzen `strict_resolve` als Standard für User-Input-Pfade
- Embedded-Entwickler können **WP1–WP5 vollständig** ohne Dateisystemzugriff nutzen

---

## 9. Zusammenfassung

Der plattformübergreifende Path-Abstraktionslayer ist eine fundamentale Infrastruktur-Komponente für Lyx' Anspruch, eine portable Systems Programming Language zu sein.

### Die vier strategischen Empfehlungen

1. **Zuerst: WP1 + WP2 + WP3** – Path-Objekt (mit dedizierten `drive`/`server`/`share`-Feldern), Parser und Normalizer sind das Fundament. Aufwand: **4–6 Wochen**.

2. **Parallel: WP5 + WP6** – Translator und Typsicherheit machen den Layer praktisch nutzbar und robust. Können parallel zu WP2+WP3 entwickelt werden.

3. **Abschließend: WP4 + WP7** – Resolver (mit `strict_resolve` als Pflicht) und Stdlib-Integration sind der größte Nutzen für Endanwender.

4. **Erweiterung: WP8** – Symlink-Handling ist ein separates Modul, das Dateisystemzugriff benötigt. Es kann nach WP7 ergänzt werden, ohne die syntaktische Basis zu destabilisieren.

### Abgrenzung zu ki-lang.md

Dieser Path-Layer hat **Überschneidungen mit der KI-native-Strategie** aus `work/ki-lang.md`:
- **Typsicherheit** (WP6) liefert Compile-Zeit-Feedback für KI-generierten Code
- **Strukturierte Fehler** (`PathParseError`, `PathResolveError`) können im `--error-json`-Format ausgegeben werden
- Die Path-API ist **deterministisch und eindeutig** – ideal für KI-Codegenerierung
- **`strict_resolve`** schützt KI-generierten Code automatisch vor Directory-Traversal-Fehlern

> **Fazit:** Mit der überarbeiteten Architektur (dedizierte `drive`/`server`/`share`-Felder statt Namespace-Einbettung, NFC-Pflicht, `~`-Expansion, `suffixes()`, typsicheres `join`/`join_path`, `strict_resolve` als Pflicht, Gleichheit/Hash-API und WP8 für Symlinks) ist der Path-Layer vollständig und produktionsreif. Die Umsetzung ist in 4–5 Monaten bei einem Entwickler realistisch.
