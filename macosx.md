# Plan: Backend für macOS (Mach‑O 64‑Bit) implementieren

## Status: In Arbeit

### Abgeschlossene Arbeitspakete

- [x] **Arbeitspaket 1-5**: Mach-O Spezifikation studiert, Verzeichnisse erstellt, Datenstrukturen definiert
- [x] **Arbeitspaket 6**: Statischer Mach-O-Erzeuger implementiert (`backend/macho/macho64_writer.pas`)
- [x] **Arbeitspaket 7**: Syscall-Anpassungen (`backend/macho/syscalls_macos.pas`)
- [x] **x86_64 Emitter für macOS**: `backend/macosx64/macosx64_emit.pas`

### Noch ausstehend

- [ ] **Arbeitspaket 8**: Compiler-Frontend anpassen (--target=macosx64)
- [ ] **Arbeitspaket 9-10**: Build-Prozess und Output-Validierung testen
- [ ] **Arbeitspaket 11**: Dokumentation vervollständigen

---

## Ziel
Ein funktionierendes macOS‑Backend (Mach‑O 64‑Bit) für den Lyx‑Compiler schaffen, das statische ausführbare Dateien für die Zielplattformen **x86_64‑darwin** und **arm64‑darwin** erzeugen kann. Das Backend soll vorhandene Frontend‑ und IR‑Stufen unverändert verwenden und nur die Objektschreibung sowie syscall‑Anpassungen ergänzen.

## Voraussetzungen / Bestehende Basis
- Frontend/IR bereits funktioniert (Lexer, Parser, Semantik, IR‑Generierung, Optimierungen).  
- x86_64‑Emitter (`backend/x86_64/x86_64_emit.pas`) und ARM64‑Emitter (`backend/arm64/arm64_emit.pas`) liegen vor.  
- ELF64‑Writer (`backend/elf/elf64_writer.pas`) und PE64‑Writer (`backend/pe/pe64_writer.pas`) dienen als Referenz für das Objekt‑File‑Format.  
- Aufrufkonvention:  
  * x86_64‑macOS verwendet dieselbe System‑V‑ähnliche Convention wie Linux (Parameter in RDI, RSI, RDX, RCX, R8, R9, Return in RAX) – nur die Syscall‑Nummern unterscheiden sich.  
  * arm64‑macOS verwendet AAPCS64 (gleich wie Linux‑ARM64), ebenfalls andere Syscall‑Nummern.

## Arbeitspakete (chronologisch)

| ID | Arbeitspaket | Beschreibung | Abhängigkeiten | Risiken |
|----|--------------|--------------|----------------|---------|
| 1 | **Mach‑O‑Spezifikation studieren** | Dokumentation zu `mach_header_64`, `load_command` (z. B. `LC_SEGMENT_64`, `LC_SYMTAB`, `LC_DYSYMTAB`, `LC_MAIN`), Section‑Aufbau (`__TEXT`, `__DATA`, `__LINKEDIT`). Dabei Fokus auf statische Ausführbare (keine dyld‑Abhängigkeiten). | – | Unterschätzung der erforderlichen Load‑Commands (z. B. `LC_MAIN` für Entry Point). |
| 2 | **Bestehende Writer analysieren** | Vergleich von `elf64_writer.pas` und `pe64_writer.pas` hinsichtlich: Struktur‑Aufbau, Alignment‑Handhabung, Abschnitt‑Erzeugung, Relocation/Platzhalter‑Mechanismus, Symboltabellen. | 1 | Falsche Annahmen über Mach‑O‑Äquivalente zu ELF‑Sektionen (z. B. kein direktes `.dynamic`). |
| 3 | **Verzeichnis schaffen** | `mkdir -p backend/macho` | 2 | – |
| 4 | **Mach‑O‑Writer‑Skeleton erstellen** | `macho64_writer.pas` mit Einheiten‑Header, Uses‑Klausel, Schnittstelle: <br>• `procedure WriteMachO64(const filename: string; const codeBuf, dataBuf: TByteBuffer; entryVA: UInt64);` <br>• (optional) `procedure WriteDynamicMachO64(...)` für spätere Erweiterungen. | 3 | Schnittstelle muss zu den bestehenden Emittern passen (Code‑ und Data‑Buffer). |
| 5 | **Mach‑O‑Datenstrukturen definieren** | Umsetzung der C‑Structs als `packed record` in Pascal: <br>• `mach_header_64` (magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved) <br>• `load_command` (cmd, cmdsize) <br>• `segment_command_64` (segname, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, flags) <br>• `section_64` (sectname, segname, addr, size, offset, align, reloff, nreloc, flags, reserved1, reserved2, reserved3) <br>Optional: Symtab‑Strukturen (`nlist_64`) für Symboltabelle (falls nötig für Debugging). | 4 | Bitfelder und Padding müssen genau dem ABI entsprechen (Endianness: little‑endian). |
| 6 | **Statischen Mach‑O‑Erzeuger implementieren** | Schreibt ein Minimal‑Mach‑O mit: <br>– Ein `LC_SEGMENT_64` für `__TEXT` (einzige Section `__text`, enthält Code,_FLAGS = `S_MOD_INIT_FUNC_POINTERS | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS`) <br>– Ein weiteres `LC_SEGMENT_64` für `__DATA` (Sections `__data`, `__bss` falls nötig) <br>– `LC_MAIN` (Entry‑Point, Stacksize) <br>– Keine Load‑Commands für Dynamic Linker (stattdessen allen Code/Data im jeweiligen Segment) <br>– Korrekte Filesize‑ und VMSIZE‑Berechnungen, Page‑Alignment (0x1000). | 5 | Falsche VM‑Addr‑Zuordnung führt zu einem Bad‑access beim Laden. |
| 7 | **Syscall‑Anpassungen für macOS ergänzen** | In den Emittern (x86_64 und ARM64) bzw. in den Builtin‑Stub‑Generierungen die macOS‑Spezifischen Syscall‑Nummern eintragen: <br>• `exit` → `0x2000001` (Unix‑ähnlich, aber andere Nummerierung) <br>• `write` → `0x2000004` <br>Zusätzlich: macOS verwendet für x86_64 den `syscall`‑Befehl genauso wie Linux (RAX = Nummer, RDI = Arg1 …). Für arm64 ist das ebenfalls gleich (svc #0). Bei Bedarf: Wrapper‑Funktion in `backend_types.pas` oder `energy_model.pas` zur Zentralisierung. | 6 | Verwirrung wegen anderer Nummern bei anderen Plattformen (z. B. FreeBSD). |
| 8 | **Compiler‑Frontend anpassen** | In `lyxc.lpr` (oder einer zentralen Konfigurationsstelle) einen neuen Target‑Wert hinzufügen, z. B. `--target=macosx64` bzw. `--target=darwin64` (oder separiert nach Arch: `--target=macosx-arm64`). Beim Erkennen dieses Targets wird der respective Mach‑O‑Writer ausgewählt anstelle von ELF/PE. | 4,6,7 | Beim Hinzufügen neuer Target‑Strings muss sichergestellt werden, dass bestehende Targets (linux, win64) unverändert bleiben. |
| 9 | **Build‑Prozess testen** | Kompiliere ein einfaches Lyx‑Programm (z. B. `PrintStr("Hello\n"); exit(0);`) mit dem neuen Target, prüfe ob eine macho64‑Datei entsteht. | 8 | Fehlende Symbole oder falsche Entry‑Adresse führen zu „Bad CPU type in executable“ oder „malformed mach‑o file“. |
|10| **Output‑Validierung** | Verwende `otool -hv <binary>` (Mach‑O Header), `otool -l <binary>` (Load Commands), `otool -tV <binary>` (Disassembly), `nm <binary>` (Symbole). Auf einem macOS‑System (oder einer VM/QEMU‑Umgebung, falls verfügbar) das Binary ausführen und auf korrette Ausgabe und Exit‑Code 0 prüfen. | 9 | Ohne echtes macOS‑System kann nur statische Struktur geprüft werden; Laufzeit‑Tests benötigen entweder echter Hardware oder Emulator (z. B. `qemu-system-aarch64` mit macOS‑Firmware – aufwendig, aber optional). |
|11| **Dokumentation & Nachbereitung** | Ergänze das `README.md` bzw. ein neues `BACKENDS.md` über das neue Target, aufgeführte Voraussetzungen und bekannte Beschränkungen (z. B. nur statische Binaries zunächst). | 10 | – |

## Akzeptanzkriterien (Definition of Done)

- Der Lyx‑Compiler akzeptiert das neue Target‑Flag (z. B. `--target=macosx64` bzw. `--target=darwin-arm64`) und erzeugt eine gültige Mach‑O‑64‑Bit‑Datei.
- Die Datei enthält korrekt:
  - Mach‑Header mit `magic = MH_MAGIC_64` (0xFEEDFACF) bzw. `MH_CIGAM_64` für Little‑Endian.
  - Mindestens ein `LC_SEGMENT_64` für `__TEXT` mit Section `__text` (enthält den Code) und ein weiteres für `__DATA` (mit `__data` und optional `__bss`).
  - Ein `LC_MAIN` Load‑Command, das den Entry‑Point auf das `_start` Symbol zeigt (oder direkt auf `main`, je nach Implementierung).
  - Keine undefinierten Symbole oder fehlenden Sections, die zu einem Laden‑Fehler führen würden.
- Beim Ausführen des generierten Binaries auf einem kompatiblen macOS‑System (oder geeignetem Emulator) wird:
  - Die Zeichenkette `Hello\n` auf stdout ausgegeben.
  - Das Programm mit Exit‑Code 0 beendet.
- Alle bestehenden Targets (linux‑x86_64, linux‑arm64, win64) funktionieren weiterhin unverändert.

## Risiken & Gegenmaßnahmen

| Risiko | Beschreibung | Gegenmaßnahme / Mitigation |
|--------|--------------|---------------------------|
| Falsche Ausrichtung/Padding | Mach‑O verlangt spezielle Ausrichtungsweisen für Segments und Sections (z. B. 0x1000 für Segment‑Start, 0x8 für Sect‑Offset innerhalb eines Segments). | Beim Schreiben stets `AlignUp`‑Hilfsfunktion verwenden (wie im ELF‑Writer); Unit‑Tests mit bekannten Beispielen (z. B. ein simples C‑Programm, das mit `clang` erzeugt wird) zur Validierung. |
| Verwirrung zwischen Flat‑Namespace und Two‑Level-Namespace | Beim dynamischen Linken unterscheiden sich die Namensauflösung. Da wir zunächst nur statische Binaries erzeugen, können wir diesen Schritt komplett auslassen. | Für dynamische Erweiterungen später klar getrennt halten; zunächst nur statischen Pfad implementieren. |
| Syscall‑Nummern unterscheiden sich zwischen macOS‑Versionen | Die Syscall‑Tabelle kann sich geringfügig ändern (aber die Grundnummern für `exit`, `write` sind stabil). | Konstanten in einer zentralen Datei (`backend_types.pas` oder neu `syscalls_macos.pas`) definieren und bei Bedarf einfach anpassen. |
| Abschnitts‑Überlappung wegen falscher File‑Offset‑Berechnung | Wenn `fileoff` nicht korrekt aufsummiert wird, überschreiben sich Sections oder lassen Lücken, die zum Laden führen. | Während des Schreibens den aktuellen Offset verfolgen und nach jedem Abschnitt die aktuelle Position prüfen; ein kurzer Test‑Block, der ein bekanntes Binary nachbaut und byteweise vergleicht, kann helfen. |
| Fehlende Symboltabelle führt zu Problemen bei Debuggern | Für ein Minimal‑Binary wird vielleicht keine Symboltabelle benötigt, aber für spätere Erweiterungen (Debug‑Info, dynamisches Linken) könnte sie nötig sein. | Beim ersten Schritt ohne Symtab auskommen; später optional `LC_SYMTAB`/`LC_DYSYMTAB` hinzufügen. |

## Ausblick / Weiterentwicklung

Nach erfolgreichem statischem Mach‑O‑Backend könnten folgende Schritte angestrebt werden:

- Unterstützung für dynamisch gebundene Mach‑O‑Binaries (Einbindung von `libSystem.B.dylib` bzw. `libc.dylib` über `LC_LOAD_DYLIB`, `LC_UUID` usw.).
- Einbindung von DWARF‑Debug‑Informationen (nach dem ELF‑Modell `DebugInfo` → Mach‑O‑`DWARF` Abschnitt).
- Zielplattform‑spezifische Optimierungen (z. B. Nutzung von macOS‑spezifischen System‑Calls für hautes Performance I/O).
- Trennung nach Architektur innerhalb eines Targets (`--target=darwin` + `--arch=x86_64|arm64`).

---

**Zusammenfassung:**  
Durch die schrittweise Anpassung des Objekt‑File‑Writers an das Mach‑O‑Format, ergänzt durch syscall‑Anpassungen und Target‑Selektion, kann ein funktionierendes macOS‑Backend für Lyx entstehen. Der Plan nutzt vorhandene Strukturen (ELF/PE‑Writer) als Vorbild, hält Abhängigkeiten gering und definiert klare Test‑ und Akzeptanzkriterien, um den Fortschritt objektiv zu messen.