# Dynamisches Linking – Debugging

## Aktueller Stand (März 2026)

### ✅ Funktioniert

Dynamisches Linking mit `extern fn` funktioniert korrekt:

```lyx
extern fn strlen(str: pchar): int64;

fn main(): int64 {
  var msg: pchar := "Hello Dynamic!";
  var len: int64 := strlen(msg);
  return 0;
}
```

Kompilierung:
```bash
./lyxc test_dynlink.lyx -o test_dynlink
/tmp/test_dynlink: ELF 64-bit LSB shared object, x86-64, dynamically linked
```

Ausführung:
```
Length: 14
Exit code: 0
```

### ✅ PLT/GOT Struktur

Die dynamisch gelinkten Binaries haben eine korrekte PLT/GOT-Struktur:

```
Dynamic section at offset 0x2168 contains 16 entries:
  Tag       Typ                          Name/Wert
  NEEDED    Gemeinsame Bibliothek        [libc.so.6]
  HASH      0x2104
  STRTAB    0x20f0
  SYMTAB    0x20c0
  STRSZ     18 (Bytes)
  SYMENT    24 (Bytes)
  PLTGOT    0x2118
  PLTRELSZ  24 (Bytes)
  PLTREL    RELA
  JMPREL    0x2138
  RELA      0x2150
  RELASZ    24 (Bytes)
  RELAENT   24 (Bytes)
  BIND_NOW  (eager symbol resolution)
  DEBUG     0x0
```

## Vergangene Probleme (behoben)

### Exit Code 132 (Ungültiger Maschinenbefehl)

**Ursache:** Ein fehlerhafter PLT-Stub oder ein falscher GOT-Eintrag.

**Lösung:** Das Problem wurde in einer früheren Version behoben. Die aktuelle Implementierung:
- PLT0 mit korrektem `push` + `jmp` Sequenz
- PLTn Stubs mit korrekter Adressierung
- GOT-Einträge werden korrekt initialisiert

### readelf -s zeigt keine dynamischen Symbole

**Ursache:** Die `.dynsym` Sektion war nicht korrekt formatiert.

**Lösung:** Der ELF64-Writer generiert jetzt korrekte `.dynsym` und `.dynstr` Sektionen.

## Sektionstabellen für dynamisches ELF

### Implementiert

Die `WriteDynamicElf64WithPatches` Funktion generiert jetzt Sektionstabellen für dynamisch gelinkte Binaries:

```pascal
// ELF Header
elfHdr.e_shoff := shdrsOff;
elfHdr.e_shentsize := SizeOf(TElf64Shdr);
elfHdr.e_shnum := numShdrs;
elfHdr.e_shstrndx := shStrTabIdx;
```

### Sektionen für dynamisches ELF

| Sektion | Typ | Beschreibung |
|---------|-----|--------------|
| .interp | PROGBITS | Pfad zum Dynamic Linker |
| .text | PROGBITS | Code |
| .data | PROGBITS | Daten |
| .bss | NOBITS | Uninitialisierte Daten |
| .dynsym | DYNSYM | Dynamische Symbole |
| .dynstr | STRTAB | Dynamische String-Tabelle |
| .hash | HASH | Hash-Tabelle für Symbol-Lookup |
| .got.plt | PROGBITS | Global Offset Table (PLT) |
| .rela.plt | RELA | Relokationen für PLT |
| .rela.dyn | RELA | Relokationen für .dynsym |
| .dynamic | DYNAMIC | Dynamic Linker-Informationen |
| .shstrtab | STRTAB | Sektions-Header String-Tabelle |

## Offene Aufgaben

### 1. ~~Sektionstabellen für statisches ELF~~ ✅ Erledigt

Die `WriteElf64` Funktion generiert jetzt `.text` und `.shstrtab` Sektionstabellen.
`objdump -d` und `readelf -S` funktionieren für statische Binaries.

### 2. macOS Dynamic Linking

Das macOS Backend (`macho64_writer.pas`) unterstützt noch kein dynamisches Linking.

**Aufwand:** Mittel (~4h)
**Priorität:** Niedrig

### 3. ARM64 Dynamic Linking

Das ARM64 Backend gibt derzeit eine Warnung aus:
```
Note: ARM64 dynamic linking not yet fully implemented
External symbols found: X (will be ignored for now)
```

**Aufwand:** Mittel (~3h)
**Priorität:** Mittel

## Testing

### Test-Dateien

- `tests/lyx/arm64/test_dynamic_link.lyx` - ARM64 dynamisches Linking Test
- `tests/lyx/io/test_getpid.lyx` - Externer Systemaufruf Test

### Manuelle Tests

```bash
# Dynamisches Binary erstellen
./lyxc tests/lyx/arm64/test_dynamic_link.lyx -o /tmp/test_dyn

# Prüfen ob dynamisch gelinkt
file /tmp/test_dyn
ldd /tmp/test_dyn

# Prüfen der PLT/GOT Struktur
readelf -d /tmp/test_dyn
readelf -r /tmp/test_dyn

# Disassemblieren (Sektionstabellen jetzt verfügbar)
objdump -d /tmp/test_dyn
```

## Historische Notizen

### Frühere Probleme

1. **PLT-Stub Kodierung**: Die PLT-Stubs verwendeten falsche Offset-Berechnungen
2. **GOT-Initialisierung**: GOT-Einträge zeigten auf falsche Adressen
3. **Dynamic Section**: Die DT_HASH und DT_STRTAB waren nicht korrekt
4. **Relokationen**: R_X86_64_RELATIVE und R_X86_64_JUMP_SLOT waren falsch
