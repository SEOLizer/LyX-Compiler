# Vorkompilierte Units (.lyu) - Spezifikation

Dieses Dokument beschreibt das binäre Unit-Format `.lyu` für den Lyx-Compiler, das es ermöglicht, Units vorzukompilieren und in anderen Lyx-Programmen zu importieren, ohne den Quellcode (.lyx) bereitzustellen.

## Übersicht

| Eigenschaft | Wert |
|-------------|-------|
| **Dateiendung** | `.lyu` |
| **Format** | Binär (Little-Endian) |
| **Inhalt** | IR-Code + Interface-Signaturen + Debug-Info (optional) |
| **Portabilität** | Architektur-spezifisch |
| **Version** | 1 (siehe Header) |

## Motivation

Aktuell muss der Lyx-Compiler bei jedem `import` die Quellcode-Datei (.lyx) parsen und kompilieren. Dies führt zu:

- **Langsameren Build-Zeiten** bei vielen Imports
- **Quellcode-Offenlegung** (kein proprietärer Import möglich)
- **Redundanter Kompilierung** gleicher Units in verschiedenen Projekten

Mit `.lyu` können Units einmal kompiliert und dann als Binärdatei importiert werden.

## Zielgruppe

- **Bibliotheks-Entwickler**: Können proprietäre Units ausliefern
- **Große Projekte**: Schnellere Kompilierung durch Precompiled Units
- **Binary-Distribution**: Fertig kompilierte Programme ohne Quellcode

---

## Dateiformat

### Gesamtaufbau

```
┌─────────────────────────────────────┐
│ Header (fest: 32 Bytes)            │
├─────────────────────────────────────┤
│ Symbol Table (Export-Interface)        │
├─────────────────────────────────────┤
│ Type Info Section                   │
├─────────────────────────────────────┤
│ IR Code Section                   │
├─────────────────────────────────────┤
│ Debug Section (optional)             │
└─────────────────────────────────────┘
```

### Header (32 Bytes)

Feste Größe von 32 Bytes, Little-Endian-Kodierung:

| Offset | Größe | Feld | Beschreibung |
|--------|------|------|-------------|
| 0x00 | 4 | Magic | `"LYU\0"` (0x4C 0x59 0x55 0x00) |
| 0x04 | 2 | Version | Format-Version (1) |
| 0x06 | 1 | TargetArch | Ziel-Architektur (siehe Tabelle unten) |
| 0x07 | 1 | Flags | Bit-Flags (siehe unten) |
| 0x08 | 2 | UnitNameLen | Länge des Unit-Namens |
| 0x0A | * | UnitName | Unit-Name (UTF-8, ohne Null-Terminator) |
| 0x0A+X | 4 | SymbolCount | Anzahl exportierte Symbole |
| 0x0E+X | 4 | TypeInfoOffset | Offset zur Type Info Section |
| 0x12+X | 4 | IRCodeOffset | Offset zur IR Code Section |
| 0x16+X | 4 | DebugOffset | Offset zur Debug Section (0 wenn nicht vorhanden) |
| 0x1A+X | 4 | Reserved | Reserviert (muss 0 sein) |
| 0x1E+X | 2 | HeaderSize | Gesamtgröße Header (für zukünftige Erweiterungen) |

**TargetArch Werte:**

| Wert | Architektur |
|------|----------|
| 0 | x86_64 (Linux/SysV) |
| 1 | arm64 (Linux/AAPCS) |
| 2 | x86_64_win64 (Windows) |
| 3 | macosx64 (macOS) |
| 4 | riscv64 |
| 5 | xtensa |
| 6 | win_arm64 |
| 7 | arm_cm |

**Flags:**

| Bit | Bedeutung |
|-----|-----------|
| 0 | Debug-Symbole vorhanden |
| 1-7 | Reserviert |

### Symbol Table

Jedes exportierte Symbol (pub fn, pub var, pub let, pub con, pub struct, pub class, pub enum) wird serialisiert:

```
NameLen: UInt16
Name: NameLen Bytes (UTF-8)
Kind: UInt8 (siehe unten)
TypeHash: UInt32 (schneller Typ-Vergleich)
TypeInfoLen: UInt32
TypeInfo: TypeInfoLen Bytes (serialisiert)
```

**Kind-Werte:**

| Wert | Symbol-Typ |
|------|-----------|
| 0 | pub fn |
| 1 | pub var |
| 2 | pub let |
| 3 | pub con |
| 4 | pub struct |
| 5 | pub class |
| 6 | pub enum |
| 7 | pub extern fn |

### Type Info Section

Serialisierte Typ-Informationen für alle exportierten Strukturen:

**TAstStructDecl:**
```
NameLen: UInt16
Name: NameLen Bytes
FieldCount: UInt32
Für jedes Field:
  FieldNameLen: UInt16
  FieldName: ...
  FieldType: serialisiert (TAurumType)
  FieldOffset: Int32
  FieldSize: Int32
```

**TAstClassDecl:**
```
NameLen: UInt16
Name: NameLen Bytes
BaseClassNameLen: UInt16
BaseClassName: (falls vorhanden)
MethodCount: UInt32
Für jede Methode:
  MethodNameLen: UInt16
  MethodName: ...
  ReturnType: serialisiert
  ParamCount: UInt32
  ParamTypes: serialisiert
  IsVirtual: Boolean
  VMTIndex: Int32
```

**TAstEnumDecl:**
```
NameLen: UInt16
Name: NameLen Bytes
ValueCount: UInt32
Für jeden Wert:
  NameLen: UInt16
  Name: ...
  Value: Int64
```

### IR Code Section

Serialisierte TIRModule-Daten:

```
FunctionCount: UInt32
Für jede Funktion:
  NameLen: UInt16
  Name: NameLen Bytes
  ParamCount: UInt16
  LocalCount: UInt16
  EnergyLevel: UInt8
  SafetyPragmas: serialisiert
  InstructionCount: UInt32
  Instructions[]: serialisiert (pro Instruction die Felder Op, Dest, Src1, Src2, Src3, ImmInt)
Special Fields (für bestimmte Ops):
  - ImmStr (für irConstStr, irLoadGlobal, etc.)
  - LabelName (für irLabel, irJmp)
  - CallMode (für irCall)
  - VMTIndex (für virtuelle Aufrufe)
```

**Strings Pool:**
```
StringCount: UInt32
Für jeden String:
  Len: UInt16
  Data: Len Bytes
```

**Global Vars:**
```
GlobalCount: UInt32
Für jede Globalvariable:
  NameLen: UInt16
  Name: ...
  InitValue: Int64 (falls HasInitValue)
  HasInitValue: Boolean
  IsArray: Boolean
  ArrayLen: UInt32 (falls IsArray)
```

### Debug Section (optional)

Nur vorhanden wenn Flags.Bit 0 = 1:

```
SourceFileCount: UInt32
Für jede Source-Datei:
  Len: UInt16
  Path: Len Bytes
  StringTableIndex: UInt32 (verweist auf Strings Pool)

InstructionDebugCount: UInt32
Pro Instruction:
  InstructionIndex: UInt32
  SourceFileIdx: UInt32
  SourceLine: UInt32
  SourceCol: UInt16
```

---

## Serialisierung von TAurumType

TAurumType wird serialisiert mit einem Type-Tag + typspezifischen Daten:

| Tag | Typ | Serialisierung |
|-----|-----|-------------|
| 0 | atInt64 | keine weiteren Daten |
| 1 | atBool | keine weiteren Daten |
| 2 | atVoid | keine weiterendaten |
| 3 | atPChar | keine weiteren Daten |
| 4 | atPCharNull | keine weiteren Daten |
| 5 | atF32 | keine weiteren Daten |
| 6 | atF64 | keine weiteren Daten |
| 7 | atDynArray | TypeTag + ElementType serialisiert |
| 8 | atArray | TypeTag + ElementType + Count (UInt32) |
| 9 | atStruct | TypeTag + StructName (serialisiert) |
| 10 | atClass | TypeTag + ClassName (serialisiert) |
| 11 | atEnum | TypeTag + EnumName (serialisiert) |
| 12 | atMap | TypeTag + KeyType + ValueType |
| 13 | atSet | TypeTag + ElementType |
| 14 | atParallelArray | TypeTag + ElementType |
| 15 | atUnit | TypeTag + UnitName |

---

## Bedienung

### Unit kompilieren

```bash
# Basis-Kompilierung (ohne Debug-Info)
./lyxc --compile-unit std/io.lyx -o std/io.lyu

# Mit Debug-Symbolen
./lyxc --compile-unit std/io.lyx -o std/io.lyu --debug-symbols

# Explizit für Ziel-Architektur (optional, Standard: aktuelle)
./lyxc --compile-unit std/io.lyx -o std/io.lyu -t x86_64
./lyxc --compile-unit std/io.lyx -o std/io.lyu -t arm64
```

### Normales Kompilieren mit automatischer .lyu-Auflösung

```bash
# main.lyx
import std.io;

fn main(): int64 {
  PrintStr("Hallo Welt\n");
  return 0;
}

# Kompilierung - lädt automatisch std/io.lyu falls vorhanden
./lyxc main.lyx -o main

# Debug-Mode: .lyu bevorzugen, aber .lyx parsen falls Debug
./lyxc main.lyx -o main --debug-source
```

### Unit-Informationen anzeigen

```bash
# Info über .lyu-Datei anzeigen
./lyxc --unit-info std/io.lyu
# Ausgabe:
# Unit: std.io
# Version: 1
# Target: x86_64
# Exportierte Symbole: 5
#   pub fn PrintStr(msg: pchar): int64
#   pub fn PrintInt(n: int64): int64
#   ...
```

---

## Import-Logik

### Auflösung-Reihenfolge

Bei `import std.io` sucht der Compiler in folgender Reihenfolge:

```
1. std/io.lyx (Quellcode)
2. std/io.lyu (Vorkompilierte Unit)
3. Suchpfade (-I Optionen)
4. Standard-Bibliothek (./std/, LYX_STD_PATH)
```

**Priorität:**
- Im Debug-Mode (`--debug-source`): .lyx bevorzugen
- Im Release-Mode: .lyu bevorzugen (falls vorhanden und kompatibel)

### Kompatibilitätsprüfung

Beim Laden einer .lyu wird geprüft:

1. **Magic**: "LYU\0" → sonst Fehler
2. **Version**: Header.Version = unterstützte Version
3. **TargetArch**: Stimmt mit aktueller Ziel-Architektur überein
4. **TypeHash**: Für jedes importierte Symbol wird TypeHash verglichen

**Bei Inkompatibilität:**
```
Error: Unit 'std.io' ist fürarm64 kompiliert, aber Programm verwendet x86_64
Error: Unit 'std.io' verwendet inkompatible Typ-Definition
```

---

## IR-Merge-Prozess

Beim Import einer .lyu wird das IR in das Haupt-IR gemergt:

```
1. Symbol-Tabelle laden
2. Types registrieren (StructDecl, ClassDecl, EnumDecl)
3. IR-Functions hinzufügen (mit Prefix: _L_<UnitName>_)
4. StringsPool mergen (deduplizieren)
5. GlobalVars hinzufügen
6. ClassDecls registrieren (für VMT)
```

**Funktions-Namens-Mangling:**
-Exportierte Funktionen behalten ihren Namen
-Interne Hilfsfunktionen: `_L_<UnitName>_<OriginalName>`

---

## Fehlerbehandlung

| Fehlercode | Bedeutung |
|-----------|-----------|
| E_LYU_INVALID | Keine gültige .lyu-Datei |
| E_LYU_VERSION | Inkompatible Version |
| E_LYU_ARCH | Falsche Ziel-Architektur |
| E_LYU_NOUNIT | Unit nicht gefunden |
| E_LYU_NOSYM | Symbol nicht gefunden |
| E_LYU_TYPE | Type-Konflikt |

---

## Einschränkungen

1. **Keine Cross-Compilation standardmäßig**: -t Option für andere Architektur
2. **Keine dynamischen Features**: Nur pub-Symbole exportierbar
3. **IR-Version**: Bei IR-Änderungen müssen .lyu neu kompiliert werden
4. **Kein Hot-Reload**: .lyu ist statisch

---

## Zukünftige Erweiterungen

| Feature | Beschreibung |
|---------|-------------|
| Unit-Cache | .lyu-Cache im Home-Verzeichnis |
| Unit-Registry | Zentrale Registrierung von Units |
| Incremental Linking | Nur geänderte Units neu kompilieren |
| LTO | Link-Time Optimization über .lyu-Grenzen |
| Signierte Units | Kryptographische Signaturen |

---

## Siehe auch

- [SPEC.md](./SPEC.md) - Gesamtspezifikation
- [ebnf.md](./ebnf.md) - Grammatik
- [COMPILER_MANUAL.md](./COMPILER_MANUAL.md) - Compiler-Handbuch
- [AGENTS.md](./AGENTS.md) - Build-Anleitung

---

## Changelog

| Version | Datum | Änderung |
|---------|-------|---------|
| 1.0.0 | 2026-04-20 | Initiale Spezifikation |