# Android Backend — Fahrplan

## 1. Übersicht

Android basiert auf dem Linux-Kernel mit ARM64 (und x86_64 für Emulatoren).
Da Lyx bereits ein Linux-ARM64-Backend und einen ELF-Writer hat, ist der Abstand
zum lauffähigen Android-Backend deutlich kleiner als bei iOS. Der Hauptunterschied
liegt in der **Bionic-ABI**, der **JNI-Brücke** für App-Integration und dem
**APK-Packaging**.

```
Ziel-Architektur:  ARM64 (aarch64-linux-android)  ← Primär
                   x86_64 (x86_64-linux-android)   ← Emulator/Testing
```

---

## 2. Aktueller Stand

| Komponente | Status | Lücke |
|---|---|---|
| Linux ARM64 Backend | ✅ Vorhanden | Bionic-Abweichungen |
| ELF Writer | ✅ Vorhanden | Shared Library (.so) Ausgabe |
| Syscall-Tabelle | ✅ Linux ARM64 | Android-spezifische Syscalls |
| Calling Convention | ✅ AAPCS64 | Entspricht Android ABI |
| JNI-Unterstützung | ❌ Fehlt | Komplett neu |
| APK-Packaging | ❌ Fehlt | Komplett neu |
| Android-Stdlib | ❌ Fehlt | Komplett neu |
| Cross-Kompilierung | ⚠️ Teilweise | NDK-Toolchain-Integration |

---

## 3. Phasen-Übersicht

```
Phase 1: Native Binaries (adb push + run)          ← Schnellster Mehrwert
Phase 2: Shared Libraries (.so) + JNI              ← App-Integration
Phase 3: Android-Stdlib (Log, Asset, Sensor)       ← Developer UX
Phase 4: Vollständiger App-Rahmen                  ← Produktionsreif
Phase 5: APK-Packaging + Build-Pipeline            ← Distribution
```

---

## 4. Work Packages

### WP-AND-01: Android-Zielplattform registrieren ✅ (erledigt, Branch `feat/android-backend`)

**Ziel:** `--target=android-arm64` und `--target=android-x86_64` als gültige
Ziele im Compiler.

**Aufwand:** 2h (tatsächlich: ~30 min)

**Betroffene Dateien (aktualisiert nach Singularität):**
- `src/lyxc.lyx` — alle CLI/Target/Dispatch-Änderungen liegen jetzt zentral hier
  (FPC-Bootstrap `compiler/`/`bootstrap/` existiert seit 2026-03-30 nicht mehr).

**Tasks:**
- [x] Target-Konstanten `TARGET_ANDROID_ARM64 = 12`, `TARGET_ANDROID_X86_64 = 13` ergänzt
- [x] Target-String-Mapping: `android-arm64`, `android-x86_64`, `android` (Alias → ARM64)
- [x] Default-Architektur-Auswahl: `--target=android` → ARM64 (Android 5.0+ Pflicht)
- [x] Codegen-Dispatch: Android-ARM64 → `emitARM64`, Android-X86_64 → `emitX86_64`
      (Bionic-ABI-Anpassungen verschoben auf WP-AND-03)
- [x] ELF `e_machine = 183` (EM_AARCH64) für Android-ARM64
- [x] Help-Text + `--config` Targets-Liste ergänzt
- [x] `GetTargetName()` liefert `android-arm64` / `android-x86_64`
- [x] Singularität verifiziert (S3 == S4 bit-identisch)

**Verifikation:**
```bash
./lyxc --target=android-arm64   examples/basics/hello.lyx -o /tmp/and_arm
./lyxc --target=android-x86_64  examples/basics/hello.lyx -o /tmp/and_x86
./lyxc --target=android         examples/basics/hello.lyx -o /tmp/and_def
file /tmp/and_arm   # ELF 64-bit LSB executable, ARM aarch64
file /tmp/and_x86   # ELF 64-bit LSB executable, x86-64
file /tmp/and_def   # ELF 64-bit LSB executable, ARM aarch64  (Android default = ARM64)
```

---

### WP-AND-02: ELF Shared Library Ausgabe (.so)

**Ziel:** Lyx kann neben statischen Executables auch `libfoo.so`-Dateien erzeugen,
die von Android-Apps per `System.loadLibrary()` geladen werden.

**Aufwand:** 8h (Phase A erledigt: ~2h)

**Betroffene Dateien:**
- `src/lyxc.lyx` — neue Funktion `writeELFSharedLib`; `--output-type` CLI; Dispatch

**Phasen-Split:**

**Phase A — Strukturell valides ET_DYN ✅ (Branch `feat/android-backend`)**
- [x] CLI: `--output-type=executable|shared-lib`, `--shared` Alias
- [x] ELF-Header: `ET_DYN` (3) statt `ET_EXEC` (2)
- [x] `e_entry = 0` (kein Entry-Point für Shared Lib)
- [x] 3 Program-Header: PT_LOAD R-X (Code), PT_LOAD RW (Daten), PT_DYNAMIC
- [x] `.dynamic`-Sektion mit `DT_HASH`, `DT_STRTAB`, `DT_SYMTAB`, `DT_STRSZ`,
      `DT_SYMENT`, `DT_SONAME`, `DT_NULL`
- [x] `.dynsym` (1 UNDEF-Eintrag), `.dynstr` (NUL + soname), `.hash` (SysV-Klassik)
- [x] `DT_SONAME` aus Basename des Output-Pfads abgeleitet
- [x] x86_64 Fast-Path-Bypass bei `--output-type=shared-lib`
- [x] Singularität verifiziert (S3 == S4)

**Phase B — Symbol-Export ✅ (Branch `feat/android-backend`)**
- [x] Annotation-Infrastruktur: Parser konsumiert `@<name>(...)` nicht mehr
      stillschweigend, sondern speichert Flags im `iVal`-Slot der `NK_FUNC_DECL`
- [x] Konstanten `ANNO_EXPORT = 1`, `ANNO_JNI = 2` (Bitfeld, weitere Bits reserviert)
- [x] Annotation kann *vor* oder *nach* `pub` stehen (z.B. `pub @export fn` und
      `@export pub fn` beide gültig)
- [x] Helfer `_tokTextEq`, `_annoNameToFlag`, `NAnnoFlags`, `NHasAnno`
- [x] `buildExportList` in lyxc.lyx: läuft AST-Top-Level durch, sammelt
      24-Byte-Records {nameOff, nameLen, st_value}; funcId-Order entspricht
      der IR-Lower-Reihenfolge (top-level `NK_FUNC_DECL`)
- [x] `emitARM64` überspringt den 12-Byte `_start`-Stub bei `--shared`
      (sonst hätten alle Export-Adressen +12 Offset)
- [x] `writeELFSharedLib` erweitert: echte `.dynsym`-Einträge mit
      `STB_GLOBAL | STT_FUNC`, `st_shndx = 1`, korrekte `st_value`-Adressen
- [x] `.dynstr` enthält alle Export-Namen NUL-getrennt
- [x] SysV `.hash` mit `nbucket = 1`, `nchain = 1 + count` und linearer Chain
- [x] Singularität verifiziert (S3 == S4)
- [x] `@jni(class="…", method="…")` Annotation + `Java_<class>_<method>`-Mangling (Phase B2)
- [x] JNI-Side-Table am Parser (40-Byte-Records, gewachsen on demand)
- [x] `_parseJniArgs` parsed `class="..."` und `method="..."` — Args werden per
      Text-Match erkannt (TK_CLASS-Keyword-Konflikt umgangen)
- [x] `_mangleJniName` produziert `Java_<class>_<method>` mit `.`→`_` Substitution
- [x] Export-Records auf absolute name-Pointer umgestellt
      (statt nameOff in parser.src — nötig für Java_*-Strings im Mangle-Buffer)
- [ ] PIC-Code-Generierung (GOT/PLT) — auf Phase C verschoben
- [ ] `DT_NEEDED` für externe Abhängigkeiten — Phase C
- [ ] Erweiterte JNI-Escape-Regeln (`_`→`_1`, Sonderzeichen `_0XXXX`) — bei Bedarf

**Verifikation Phase B2:**
```bash
cat > /tmp/jnitest.lyx <<'LYX'
@jni(class="com.example.MyClass", method="nativeAdd")
fn nativeAdd(a: int64, b: int64): int64 { return a + b; }

@jni(class="com.example.MyClass", method="nativeMul")
fn nativeMul(a: int64, b: int64): int64 { return a * b; }

@export
fn helperRaw(x: int64): int64 { return x + 1; }

fn unexported(x: int64): int64 { return x; }
fn main(): int64 { return 0; }
LYX

./lyxc --target=android-arm64 --shared /tmp/jnitest.lyx -o /tmp/libjni.so
readelf -D --syms -W /tmp/libjni.so
#   1: 0x0    FUNC GLOBAL Java_com_example_MyClass_nativeAdd
#   2: 0x24   FUNC GLOBAL Java_com_example_MyClass_nativeMul
#   3: 0x48   FUNC GLOBAL helperRaw       (raw name, kein @jni)
```

**Verifikation Phase B:**
```bash
cat > /tmp/exporttest.lyx <<'LYX'
@export
fn AddInts(a: int64, b: int64): int64 { return a + b; }

fn HelperPrivate(x: int64): int64 { return x * 2; }

@export
fn MulInts(a: int64, b: int64): int64 {
  return HelperPrivate(a) + HelperPrivate(b);
}
fn main(): int64 { return 0; }
LYX

./lyxc --target=android-arm64 --shared /tmp/exporttest.lyx -o /tmp/libexport.so
readelf -D --syms /tmp/libexport.so
# Symbol table for image contains 3 entries:
#    Num:    Value          Size Type    Bind   Vis      Ndx Name
#      0: 0000000000000000     0 NOTYPE  LOCAL  DEFAULT  UND
#      1: 0000000000000000     0 FUNC    GLOBAL DEFAULT    1 AddInts
#      2: 0000000000000084     0 FUNC    GLOBAL DEFAULT    1 MulInts
# (HelperPrivate erscheint korrekt NICHT in der .dynsym.)
```

**Phase C — Relocations (Infrastruktur erledigt, End-to-End-Test offen)**
- [x] `EmitARM64.relocBuf`: 24-Byte Elf64_Rela-Records mit dynamischem Wachstum
- [x] `setSharedLib(1)` aktiviert PIC-Pfad; `getRelocBuf` / `getRelocCount` exponieren
- [x] PIC-Variante von `emitLoadGlobal` / `emitStoreGlobal`: Inline-Literal-Pool
      mit `LDR x9, [pc+8]` / `B +12` / `.quad addr`-Slot — 24 Bytes, identisch zur
      MOVZ/MOVK-Variante in Größe
- [x] Jeder Slot bekommt einen `R_AARCH64_RELATIVE` (Type 1027) Eintrag;
      `r_offset = codeOff + slotPosInCodeBuf`, `r_addend = base-relative Adresse`
- [x] `.rela.dyn`-Sektion in der `.so` (8-byte aligned nach `.hash`), nur emittiert
      wenn `relocCount > 0`
- [x] `DT_RELA` / `DT_RELASZ` / `DT_RELAENT` in `.dynamic` (dynNum 7 → 10)
- [x] PT_LOAD #2 wächst automatisch um die neuen Bytes (`seg2Size = fileSize - dataOff`)
- [x] Singularität verifiziert (S3 == S4)

**Bekannte Limitierung (Upstream-Blocker):**
`ir.lyx:730 irLoadGlobal` setzt `src1=-1` und wird im aktuellen Frontend
**nirgends aufgerufen**. Die ARM64-Reloc-Codegenerierung ist deshalb
strukturell korrekt, aber für reale Lyx-Programme unerreichbar. Sobald die
IR-zu-Emit-Brücke für Globals repariert ist, emittiert die Pipeline
automatisch korrekte `R_AARCH64_RELATIVE`-Records. Test-Verifikation in
`readelf -r` zeigt "no relocations" für aktuelle Testfälle — erwartetes
Verhalten, kein Bug.

**Offen für eine spätere Session:**
- [ ] `IRO_LOAD_GLOBAL` / `IRO_STORE_GLOBAL` upstream im ir_lower-Pfad aktivieren
- [ ] `R_AARCH64_GLOB_DAT` / `R_AARCH64_JUMP_SLOT` für externe Symbole (`@extern`)
- [ ] `.rela.plt` Sektion + GOT-Tabelle für PLT-Calls
- [ ] `DT_NEEDED` Einträge für externe `.so`-Abhängigkeiten
- [ ] NDK-Echttest: `aarch64-linux-android-readelf -d/-r libtest.so`
- [ ] Emulator-Loadtest: `adb push` + Java-App ruft `Java_com_example_*` auf

**Verifikation Phase C:**
```bash
./lyxc --target=android-arm64 --shared /tmp/minimal_export.lyx -o /tmp/libmin.so
readelf -d /tmp/libmin.so | grep -E "RELA|HASH|STRTAB"
# 7 .dynamic-Einträge (keine RELA) — minimal_export.lyx hat keine Globals
readelf -r /tmp/libmin.so
# "There are no relocations in this file."  (erwartet)
```

**Verifikation Phase A:**
```bash
./lyxc --target=android-arm64  --shared      examples/basics/hello.lyx -o /tmp/libhello.so
./lyxc --target=android-x86_64 --output-type=shared-lib examples/basics/hello.lyx -o /tmp/libhello-x86.so
file     /tmp/libhello.so       # ELF 64-bit LSB shared object, ARM aarch64, dynamically linked
readelf -h /tmp/libhello.so     # Type: DYN (Shared object file)
readelf -l /tmp/libhello.so     # 3 program headers: LOAD R-E, LOAD RW, DYNAMIC
readelf -d /tmp/libhello.so     # HASH, STRTAB, SYMTAB, STRSZ, SYMENT, SONAME, NULL
```

---

### WP-AND-03: Bionic-ABI-Kompatibilität ✅ (Branch `feat/android-backend`)

**Ziel:** Vom Lyx-Compiler erzeugte Binaries und .so-Dateien sind zur Bionic-
Laufzeitbibliothek kompatibel (kein Absturz durch ABI-Unterschiede).

**Aufwand:** 4h (tatsächlich ~3.5h)

**Hintergrund:** Lyx nutzt reine Syscalls und braucht Bionic nicht als Libc.
Dennoch muss Stack-Alignment, TLS-Zugriff und Exception-Frame (`.eh_frame`)
korrekt sein, damit das Android-Linker-Framework `.so`-Dateien lädt.

**Audit-Ergebnis (in Code-Kommentaren in `src/backend/arm64/emit_arm64.lyx`):**
- [x] 16-Byte-Stack-Alignment: schon korrekt — `STP x29, x30, [sp, #-16]!` mit
      pre-decrement um 16, `calcStackFrame` rundet auf 16, durch Funktionskörper
      kein SP-Touch (Locals über fp adressiert)
- [x] x18 (Android Platform Reg / Bionic TLS / Shadow Call Stack): nie angefasst —
      `ARM64_X*` Konstanten gehen nur bis x10
- [x] TPIDR_EL0 (TLS-System-Register): nie angefasst — keine MRS/MSR-Instruktionen
- [x] Callee-saved Regs x19..x28: nicht verwendet, keine Save-Restore nötig

**Implementierte Tasks:**
- [x] `--android-api=N` CLI-Flag (Default 26, validiert ≥ 21);
      Konstanten `ANDROID_API_MIN = 21`, `ANDROID_API_DEFAULT = 26`
- [x] `.note.android.ident` ELF-Note-Sektion (24 Bytes: header+name+desc)
      mit API-Level im descriptor; `PT_NOTE` Program-Header (phNum 3 → 4)
- [x] `.eh_frame` mit DWARF-CFI:
  - Eine gemeinsame CIE: version 1, augmentation "zR", code_align 1,
    data_align -8, return_reg 30 (LR), FDE-encoding 0x1B (PC-rel sdata4),
    initial CFI `DW_CFA_def_cfa(31, 0)` (CFA = sp am Funktionseingang)
  - Eine FDE pro Funktion: PC-relative pc_begin, pc_range, CFI-Sequenz
    `advance_loc(prologueLen)` + `def_cfa(29, 16)` + `offset(29, 2)` +
    `offset(30, 1)` → beschreibt CFA = fp+16 nach Prolog, x29 bei -16, x30 bei -8
- [x] `.eh_frame_hdr` mit Binary-Search-Tabelle (sortierte function→FDE pairs,
      datarel sdata4 encoding)
- [x] `PT_GNU_EH_FRAME` Program-Header (phNum 4 → 5) verweist auf `.eh_frame_hdr`,
      damit der Runtime-Unwinder die Tabelle findet (sonst läge sie tot herum,
      weil wir keine Section-Headers haben)
- [x] `EmitARM64.funcPrologueLen[]` Tabelle (parallel zu `funcAddrs[]`),
      gefüllt am Ende von `emitPrologue` für den FDE-`advance_loc`
- [x] `EmitARM64.funcCount` und `getFuncPrologueLen()` exponiert
- [x] Singularität verifiziert (S3 == S4 bit-identisch)
- [x] Manuelle Byte-Verifikation der CIE+FDE+hdr-Bytes (PC-relative Offsets,
      LEB128-Konstanten, NOP-Padding korrekt)

**Stolperstein (festgehalten):** `ParseInt(arg + 14)` als Direkt-Expression
crashte unter dem aktuellen Bootstrap-Seed. Workaround: digits inline parsen
mit `peek8`-Schleife (`while peek8(p) >= 48 && peek8(p) <= 57`).

**Verifikation Phase WP-AND-03:**
```bash
./lyxc --target=android-arm64 --shared --android-api=26 \
       /tmp/minimal_export.lyx -o /tmp/libeh.so
readelf --notes  /tmp/libeh.so  # Owner=Android, NT_VERSION, desc=0x1a (=26)
readelf -l       /tmp/libeh.so  # 5 program headers incl. PT_NOTE + GNU_EH_FRAME
# .eh_frame CIE+FDE+hdr bytes manually decoded; tools without section
# headers cannot pretty-print them, but the byte layout is verified.
```

**Offen (kein Blocker für die `.so`-Korrektheit):**
- [ ] Test: Lade `.so` in minimaler Android-App auf Emulator ohne Crash —
      benötigt Android SDK / NDK / Emulator, out-of-scope dieser Session
- [ ] `.ARM.exidx` (Cortex-A32 Unwind-Sections, nur 32-bit ARM relevant —
      auf ARM64 ist `.eh_frame` die Standardlösung, das ist erledigt)
- [ ] Section-Headers emittieren (würden GNU debuggern + readelf direktes
      Pretty-Printing von .eh_frame via `--debug-dump=frames` ermöglichen)

---

### WP-AND-04: Android-Syscall-Tabelle ✅ (Branch `feat/android-backend`)

**Ziel:** Vollständige Syscall-Tabelle für Android (API 21+, ARM64 und x86_64).

**Aufwand:** 3h (tatsächlich ~1h — Wrapper über vorhandene Linux-Syscalls)

**Hintergrund:** Android-ARM64-Syscall-Nummern sind identisch mit Linux ARM64,
für x86_64 ebenfalls. Der praktische Unterschied liegt in **SELinux/seccomp-
Filtern**, die bestimmte Syscalls für App-Prozesse blocken — nicht im
Kernel-ABI. WP-AND-04 liefert deshalb **Wrapper + Dokumentation**, kein
neues Codegen.

**Geliefert (4 neue Units):**

| Datei | Inhalt |
|---|---|
| `std/net/internal/syscalls_android.lyx` | `sca_*` Network-Wrapper (re-export von Linux) + `sca_*_unsupported`-Stubs für fork/vfork/ptrace/personality/reboot, die direkt -1 returnen |
| `std/android/restrictions.lyx` | Katalog der gesperrten/restringierten Syscall-Nummern (`SYS_AND_FORK_*`, `SYS_AND_PTRACE`, etc.) + API-Level-Konstanten (`ANDROID_API_GETRANDOM=23`, `…_MEMFD_CREATE=26`, `…_PIDFD_OPEN=30`) |
| `std/android/random.lyx` | `AndroidRandomBytes(buf, len)` und `AndroidRandomInt64()` via `/dev/urandom` — funktioniert seit Android 5.0; getrandom(2)-Pfad dokumentiert als Future-Improvement (braucht sys_getrandom-Builtin in lyxc) |
| `std/android/ioctl.lyx` | ioctl-Request-Nummern für ASHMEM (Android shared memory), ALSA PCM (Audio), V4L2 (Kamera), IIO (Sensoren). User-Code wired die direkt in den `ioctl()`-Builtin |

**Tasks:**
- [x] Android-eingeschränkte Syscalls dokumentieren und absichern (`fork`, `ptrace`, …)
- [x] Android-spezifische `ioctl`-Konstanten für Kamera (V4L2), Audio (ALSA), Sensor (IIO), ASHMEM
- [x] `/dev/urandom`-Fallback in `AndroidRandomBytes` (funktioniert ab API 21)
- [ ] `getrandom(2)` als nativer Syscall — verschoben (braucht `sys_getrandom`-Builtin in `src/codegen_x86.lyx` und `src/backend/arm64/emit_arm64.lyx`, eigener Codegen-Eingriff)
- [ ] `binder`-Syscalls für Android IPC — bewusst nicht in dieser WP (Komplexität, eigener Modul-Scope; siehe WP-AND-06 Phase 4)

**Verifikation:**
```bash
for f in std/net/internal/syscalls_android.lyx \
         std/android/restrictions.lyx \
         std/android/random.lyx \
         std/android/ioctl.lyx; do
  ./lyxc --compile-unit "$f" -o /tmp/check.lyu && echo "OK: $f"
done
# Alle 4 Units kompilieren clean (exit=0; sema-Warnings für sys_fcntl sind
# preexistent, betreffen auch syscalls_linux.lyx).
make singularity   # S3 == S4 (Hash unverändert: std-Units sind ohne
                   # Wirkung auf das lyxc-Binary, nur Userland-Code).
```

**Hinweis zum Naming:** Doc hatte `syscalls_android_arm64.lyu` /
`syscalls_android_x86.lyu` als zwei getrennte Dateien vorgesehen. Da die
Syscall-Nummern auf beiden Architekturen identisch sind und der einzige
Unterschied im SELinux-Filter liegt, wurde eine gemeinsame
`syscalls_android.lyx`-Datei gewählt; architekturspezifische Nummern in
`restrictions.lyx` getrennt aufgeführt (z.B. `SYS_AND_GETRANDOM_ARM64`
vs. `_X86_64`).

---

### WP-AND-05: JNI-Brücke (Code-Generator) — Phase A erledigt, Phase B blockiert

**Ziel:** Lyx-Funktionen können als JNI-Methoden exportiert werden, die von
Kotlin/Java aus aufgerufen werden.

**Aufwand:** 12h (Phase A tatsächlich ~1h; Phase B durch Upstream-Frontend blockiert)

**Tasks-Status:**
- [x] `@jni` Annotation im Parser erfassen — erledigt in **WP-AND-02 Phase B2**
- [x] JNI-Symbol-Mangling `Java_<class>_<method>` — erledigt in **WP-AND-02 Phase B2**
- [x] JNI-Typ-Aliase: `jboolean`, `jbyte`, `jchar`, `jshort`, `jint`, `jlong`,
      `jfloat`, `jdouble`, `jsize`, `jobject`, `jclass`, `jstring`, `jthrowable`,
      `j{boolean,byte,char,short,int,long,float,double,object}Array`,
      `jmethodID`, `jfieldID`, `jweak` — alle `pub type X = int64`
- [x] `JNIEnv` / `JavaVM` als opake `int64`-Aliase
- [x] JNI-Konstanten: `JNI_FALSE/TRUE`, `JNI_OK`, `JNI_ERR`, `JNI_EDETACHED`,
      `JNI_EVERSION`, `JNI_ENOMEM`, `JNI_EEXIST`, `JNI_EINVAL`, `JNI_COMMIT`,
      `JNI_ABORT`, `JNI_VERSION_1_1..1_8`
- [x] `JNI_SLOT_*`-Konstanten (60+ Slot-Offsets der `JNINativeInterface` VTable)
      — GetVersion, FindClass, GetMethodID, NewStringUTF, GetStringUTFChars,
      NewByteArray, RegisterNatives, ExceptionCheck, GetJavaVM, etc.
- [x] Neue Stdlib: `std/android/jni.lyx` (kompiliert clean via `--compile-unit`)
- [x] End-to-End-Beispiel: `examples/android/jni_native_add.lyx` produziert
      eine `.so` mit `Java_com_example_MyClass_nativeAdd` / `_nativeMul` /
      `_nativeDouble` in der `.dynsym`
- [ ] `JNIEnv`-Hilfsfunktionen `NewStringUTF` / `GetStringUTFChars` /
      `NewByteArray` — **upstream blockiert**, siehe Stolperstein
- [ ] Test: Kotlin-App ruft `nativeAdd` auf — out-of-scope ohne Android-SDK

**Stolperstein (Upstream-Blocker, Frontend):**
Helper-Wrapper für `JNIEnv`-VTable-Calls würden so aussehen:
```lyx
fn JNI_GetVersion(env: JNIEnv): jint {
  var vtable: int64 := peek64(env);
  var fnPtr:  int64 := peek64(vtable + JNI_SLOT_GetVersion * 8);
  var fn:     fn(JNIEnv): jint := fnPtr as fn(JNIEnv): jint;  // <-- Parse error
  return fn(env);
}
```
Aktuelle Frontend-Lücken:
1. **Parser** akzeptiert keine `var x: fn(T): R` Variable-Decl (nur als Typ-
   Annotation in einigen Kontexten). Reproduziert: `var f: fn(int64): int64 := 0;`
   → `Parse error at line N: expected expression`.
2. **`as fn(...): ...` Cast-Syntax** ist nicht in `ParseUnary` verdrahtet.
3. **`ir_lower`** emittiert `IRO_CALL_INDIRECT` **nirgends** — der Backend-
   Codegen (`emitCallIndirect` in `emit_arm64.lyx` / `codegen_x86.lyx`) ist
   da, wird aber nie getriggert.

Fix-Aufwand grob: 4-6h durchgängiger Frontend-Eingriff (Parser-Production für
Function-Pointer-Variables und `as fn(...)`-Casts, plus Sema-Type-Inferenz,
plus `ir_lower`-Pfad für `NK_CALL` mit dynamischem Callee).

**Verifikation Phase A:**
```bash
./lyxc --compile-unit std/android/jni.lyx -o /tmp/jni.lyu     # exit 0
./lyxc --target=android-arm64 --shared --android-api=26 \
       examples/android/jni_native_add.lyx -o /tmp/libnative_add.so
readelf -D --syms -W /tmp/libnative_add.so
#   1: 0x0    FUNC GLOBAL Java_com_example_MyClass_nativeAdd
#   2: 0x24   FUNC GLOBAL Java_com_example_MyClass_nativeMul
#   3: 0xA8   FUNC GLOBAL Java_com_example_MyClass_nativeDouble
make singularity   # S3 == S4 (Hash unverändert: nur Userland-Code)
```

**Was Phase A bereitstellt:** Reine Compute-`@jni`-Funktionen (Argumente
rein, Werte raus) lassen sich heute kompilieren und exportieren. Funktionen,
die zurück nach Java rufen (Strings erzeugen, Methoden aufrufen, Arrays
allozieren), brauchen Phase B + Frontend-Reparatur.

---

### WP-AND-06: Android-Stdlib (Basis) — Konstanten + Log voll, andere blockiert

**Ziel:** Grundlegende Android-API-Bindungen als Lyx-Stdlib-Module.

**Aufwand:** 16h (tatsächlich ~2h für realistisch lieferbaren Scope)

**Geliefert (5 neue Units in `std/android/`):**

| Modul | Konstanten | Funktionen |
|---|---|---|
| `std/android/log.lyx` | `ANDROID_LOG_VERBOSE..FATAL` | **voll funktional**: `LogV/D/I/W/E/F(tag, msg)`, `LogPrio(prio, …)` schreiben Logcat-Format auf stderr |
| `std/android/asset.lyx` | `AASSET_MODE_*`, `AASSET_DIR_*` | nur Typen + TODOs (blockiert) |
| `std/android/sensor.lyx` | `ASENSOR_TYPE_*` (25+), `ASENSOR_STATUS_*`, `AREPORTING_MODE_*`, `ASENSOR_DELAY_*`; structs `ASensorVector`, `ASensorEvent` | nur Typen + TODOs (blockiert) |
| `std/android/input.lyx` | `AINPUT_EVENT_TYPE_*`, `AKEY_EVENT_ACTION_*`, `AKEY_EVENT_FLAG_*`, `AMOTION_EVENT_ACTION_*`, `AINPUT_SOURCE_*` (24+), `AKEYCODE_*` (Auswahl ~25), `AMETA_*` | nur Typen + TODOs (blockiert) |
| `std/android/native_window.lyx` | `WINDOW_FORMAT_*`, `ANATIVEWINDOW_TRANSFORM_*`, `…_FRAME_RATE_COMPATIBILITY_*`; structs `ANativeWindow_Buffer`, `ARect` | nur Typen + TODOs (blockiert) |

**Tasks-Status:**
- [x] `std/android/log.lyx`: `LogD/I/W/E(tag, msg)` — schreiben Format
      `"P/tag: msg\n"` auf stderr; Android-Runtime captured stderr von
      debuggable Apps automatisch in logcat → echte Logcat-Ausgabe ohne
      liblog-Linkung
- [x] `std/android/asset.lyx`: Konstanten + opake Typdefs
- [x] `std/android/sensor.lyx`: Konstanten + opake Typdefs + Event-Struct
- [x] `std/android/input.lyx`: Konstanten + opake Typdefs
- [x] `std/android/native_window.lyx`: Konstanten + Buffer/ARect-Struct
- [ ] Aktive Funktionen für asset/sensor/input/native_window — **blockiert**:
      benötigen `DT_NEEDED libandroid.so` + PLT + `IRO_CALL_INDIRECT` aus
      `ir_lower` (gleicher Frontend-Block wie WP-AND-05 Phase B)

**Warum nicht alles funktional?**
Die NDK-C-APIs (`AAssetManager_open`, `ASensorEventQueue_*`,
`ANativeWindow_lock`, etc.) leben in `libandroid.so`. Sie aufzurufen
braucht: (1) `DT_NEEDED`-Einträge in der `.dynamic` (kein Codegen-Support
für externe Libs), (2) eine PLT-Sektion mit Stubs (in WP-AND-02 Phase C
infrastruktur-vorbereitet, aber nicht End-to-End), (3) Lyx-Frontend, das
`IRO_CALL_INDIRECT` aus dynamischem Lookup emittiert. Selbst eine
JNI-Brücke (via `JNIEnv`-VTable) wäre eine Option, scheitert aber an der
gleichen Frontend-Lücke wie WP-AND-05 Phase B. Die Konstanten und Typdefs
sind trotzdem nützlich (z.B. um Sensor-Daten aus rohen IIO-sysfs-Reads zu
interpretieren, Input-Events aus eigener Pipeline zu kategorisieren etc.).

**Verifikation:**
```bash
for f in std/android/log.lyx std/android/asset.lyx \
         std/android/sensor.lyx std/android/input.lyx \
         std/android/native_window.lyx; do
  ./lyxc --compile-unit "$f" -o /tmp/x.lyu && echo "OK: $f"
done

# log e2e:
cat > /tmp/log_test.lyx <<'LYX'
import std.android.log;
fn main(): int64 {
  LogI("LyxApp", "Hello from Lyx on Android");
  LogE("LyxApp", "And an error");
  return 0;
}
LYX
./lyxc /tmp/log_test.lyx -o /tmp/log_test && /tmp/log_test
# stderr:
#   I/LyxApp: Hello from Lyx on Android
#   E/LyxApp: And an error
# (debuggable App: erscheint in logcat unter Tag "LyxApp")

make singularity   # S3 == S4 (Hash unverändert, std/ ohne Wirkung auf lyxc)
```

**Aufwand-Vergleich:** Doc 16h, tatsächlich ~2h. Differenz hauptsächlich
durch upstream-Blocker: die "richtige" Implementierung (PLT-Stubs, JNI-
Vtable-Helpers) ist 12h+ Frontend-Arbeit, davon nichts in WP-AND-06-Scope.

---

### WP-AND-07: Android Activity + NativeActivity

**Ziel:** Vollständige Lyx-App als `NativeActivity` ohne Java/Kotlin-Wrapper.

**Aufwand:** 20h

**Konzept:** Android `NativeActivity` ermöglicht eine reine C/C++ (hier: Lyx) App
über die `ANativeActivity`-Callbacks ohne Java-Code.

**Tasks:**
- [ ] `android_native_app_glue`-Äquivalent in Lyx implementieren
- [ ] `ANativeActivity` Struct + Callback-Funktionszeiger definieren
- [ ] Event-Loop: `ALooper_pollAll` für App-Events und Input
- [ ] `AndroidManifest.xml` Generator (minimal für NativeActivity)
- [ ] OpenGL ES 2.0 Bindungen: `std/android/gles.lyu`
- [ ] Vulkan Bindungen (optional): `std/android/vulkan.lyu`
- [ ] Test: Lyx-App rendert ein farbiges Dreieck auf Android

---

### WP-AND-08: APK-Packaging-Integration

**Ziel:** `lyxc --target=android-arm64 --package=apk` erzeugt eine installierbare
`.apk`-Datei direkt.

**Aufwand:** 16h

**APK-Struktur:**
```
MyApp.apk
├── AndroidManifest.xml    (kompiliertes AXML)
├── classes.dex            (Stub-Java, nur für NativeActivity)
├── lib/arm64-v8a/
│   └── libmain.so         (Lyx-kompilierte Bibliothek)
├── res/                   (Ressourcen, optional)
└── META-INF/
    ├── CERT.RSA           (Debug-Signatur)
    └── MANIFEST.MF
```

**Tasks:**
- [ ] ZIP-Writer in Lyx (oder Aufruf von `zip` als externem Tool)
- [ ] AXML-Encoder für `AndroidManifest.xml`
- [ ] `classes.dex` Stub-Generator (minimales Dex für NativeActivity)
- [ ] Debug-Keystore-Signierung (via `apksigner` oder eigene Implementierung)
- [ ] `adb install` Wrapper: `lyxc --install` deployt direkt aufs Gerät
- [ ] Test: `adb install MyApp.apk` funktioniert, App startet

---

## 5. Abhängigkeiten

```
WP-AND-01 (Target registrieren)
    ↓
WP-AND-02 (ELF Shared Lib)  ←─── WP-AND-03 (Bionic ABI)
    ↓
WP-AND-04 (Syscall-Tabelle)
    ↓
WP-AND-05 (JNI-Brücke)
    ↓
WP-AND-06 (Android-Stdlib)
    ↓
WP-AND-07 (NativeActivity)
    ↓
WP-AND-08 (APK-Packaging)
```

---

## 6. Zeitschätzung

| Phase | WPs | Aufwand |
|---|---|---|
| Phase 1: Grundlagen | WP-AND-01..04 | ~17h |
| Phase 2: JNI + Stdlib | WP-AND-05..06 | ~28h |
| Phase 3: App-Rahmen | WP-AND-07 | ~20h |
| Phase 4: Distribution | WP-AND-08 | ~16h |
| **Gesamt** | **8 WPs** | **~81h** |

---

## 7. Prioritäten

### Schnellster Mehrwert (Phase 1)
Lyx-Binary per `adb push` auf Gerät kopieren und direkt ausführen (Shell-Tool,
kein App-Store nötig). Benötigt nur WP-AND-01 + WP-AND-03 + WP-AND-04.

### App-Integration (Phase 2)
JNI `.so` in bestehende Kotlin/Java-App einbinden. Benötigt WP-AND-02 + WP-AND-05.

### Vollständige App (Phase 3+4)
Reines Lyx ohne Java/Kotlin. Langfristiges Ziel.

---

## 8. Cross-Kompilierungs-Toolchain

Für native Tests auf dem Entwicklungsrechner (nicht auf Gerät):

```bash
# Android NDK r25+
export ANDROID_NDK=~/Android/Sdk/ndk/25.2.9519653
export TOOLCHAIN=$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64

# Lyx kompiliert für Android ARM64
./lyxc hello.lyx --target=android-arm64 -o libhello.so --output-type=shared-lib

# Prüfen mit NDK-readelf
$TOOLCHAIN/bin/llvm-readelf -d libhello.so

# Direkt auf Gerät testen
adb push libhello /data/local/tmp/
adb shell chmod +x /data/local/tmp/libhello
adb shell /data/local/tmp/libhello
```

---

## 9. Mindestversionsstrategie

| API-Level | Android-Version | Grund |
|---|---|---|
| API 21 | Android 5.0 | 64-Bit ARM64 Pflicht |
| API 23 | Android 6.0 | Runtime Permissions |
| API 28 | Android 9.0 | `getrandom` Syscall |
| **API 26** | **Android 8.0** | **Empfohlenes Minimum** |

---

## 10. Siehe auch

- `backend-upgrade.md` — Bestehende Backend-Upgrade-Roadmap
- `src/backend/arm64/emit_arm64.lyx` — ARM64-Backend (Basis für Android)
- `src/backend/elf/` — ELF-Writer (Basis für .so-Ausgabe)
- `src/lyxc.lyx` — zentraler ELF-Header-Writer (z.B. `e_machine`-Dispatch)
- `std/net/internal/syscalls_linux.lyu` — Linux-Syscall-Referenz

> **Hinweis:** Seit Singularität (2026-03-30) ist der FPC-Bootstrap (`compiler/`,
> `bootstrap/`) Geschichte. Sämtlicher Compilercode liegt in `src/` als Lyx-Quellen
> und wird von `src/lyxc_bootstrap` (singularitätsverifiziertes Seed-Binary) kompiliert.
