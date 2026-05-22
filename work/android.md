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
- [ ] PIC-Code-Generierung (GOT/PLT) — auf Phase C verschoben
- [ ] `@jni(class="…", method="…")` Annotation + `Java_<class>_<method>`-Mangling — Phase B2
- [ ] `DT_NEEDED` für externe Abhängigkeiten — Phase C

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

**Phase C — Relocations + Real-World-Test (offen)**
- [ ] Relocations: `R_AARCH64_GLOB_DAT`, `R_AARCH64_JUMP_SLOT`, `R_AARCH64_RELATIVE`
- [ ] `.rela.dyn` / `.rela.plt` Sektionen
- [ ] Test: `aarch64-linux-android-readelf -d libtest.so` (NDK)
- [ ] Test: Lade `.so` in minimaler Android-App ohne Crash

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

### WP-AND-03: Bionic-ABI-Kompatibilität

**Ziel:** Vom Lyx-Compiler erzeugte Binaries und .so-Dateien sind zur Bionic-
Laufzeitbibliothek kompatibel (kein Absturz durch ABI-Unterschiede).

**Aufwand:** 4h

**Hintergrund:** Lyx nutzt reine Syscalls und braucht Bionic nicht als Libc.
Dennoch muss der Stack-Alignment, TLS-Zugriff und Exception-Frame (`.eh_frame`)
korrekt sein, damit das Android-Linker-Framework `.so`-Dateien lädt.

**Tasks:**
- [ ] Stack-Alignment prüfen: Android erfordert 16-Byte-Alignment beim Funktionsaufruf
- [ ] TLS-Register (TPIDR_EL0) nicht clobber
- [ ] `.eh_frame` / `.ARM.exidx` korrekte Ausgabe für Stack-Unwinding
- [ ] `__android_api__` Mindestversion als Compile-Zeit-Konstante definieren (API 21+)
- [ ] Test: Lade `.so` in minimaler Android-App ohne Crash

---

### WP-AND-04: Android-Syscall-Tabelle

**Ziel:** Vollständige Syscall-Tabelle für Android (API 21+, ARM64 und x86_64).

**Aufwand:** 3h

**Betroffene Dateien:**
- Neue Datei: `std/net/internal/syscalls_android_arm64.lyu`
- Neue Datei: `std/net/internal/syscalls_android_x86.lyu`

**Hinweis:** Android-ARM64-Syscall-Nummern sind identisch mit Linux ARM64.
Für x86_64 ebenfalls. Der Unterschied liegt in einigen fehlenden Syscalls
(z. B. `fork` ist auf Android eingeschränkt) und Android-spezifischen
`ioctl`-Konstanten.

**Tasks:**
- [ ] Android-eingeschränkte Syscalls dokumentieren und absichern (`fork`, `ptrace`)
- [ ] `binder`-Syscalls für Android IPC (optional, Phase 4)
- [ ] Android-spezifische `ioctl`-Konstanten für Kamera, Audio, Sensor
- [ ] `getrandom` (API 28+) vs. `/dev/urandom` Fallback

---

### WP-AND-05: JNI-Brücke (Code-Generator)

**Ziel:** Lyx-Funktionen können als JNI-Methoden exportiert werden, die von
Kotlin/Java aus aufgerufen werden.

**Aufwand:** 12h

**Neue Syntax (Vorschlag):**
```lyx
@jni(class="com.example.MyClass", method="nativeAdd")
fn nativeAdd(env: ^JNIEnv, obj: jobject, a: int64, b: int64): int64 {
    return a + b
}
```

**Tasks:**
- [ ] `@jni` Annotation im Parser erfassen
- [ ] JNI-Typ-Mapping: `int64 ↔ jlong`, `pchar ↔ jstring`, `bool ↔ jboolean`
- [ ] JNI-Symbol-Mangling: `Java_com_example_MyClass_nativeAdd` erzeugen
- [ ] `JNIEnv`-Struct als Built-in-Typ definieren (Funktionszeiger-Tabelle)
- [ ] `JNIEnv`-Hilfsfunktionen: `NewStringUTF`, `GetStringUTFChars`, `NewByteArray`
- [ ] Neue Stdlib: `std/android/jni.lyu` mit JNI-Typ-Definitionen
- [ ] Test: Kotlin-App ruft `nativeAdd` auf, erhält korrektes Ergebnis

---

### WP-AND-06: Android-Stdlib (Basis)

**Ziel:** Grundlegende Android-API-Bindungen als Lyx-Stdlib-Module.

**Aufwand:** 16h

**Neue Module:**

| Modul | Beschreibung | API |
|---|---|---|
| `std/android/log.lyu` | `__android_log_print` / Logcat | Log-API |
| `std/android/asset.lyu` | AAssetManager — App-Assets lesen | Asset-API |
| `std/android/sensor.lyu` | ASensorManager — Gyro, Accel, GPS | Sensor-API |
| `std/android/input.lyu` | AInputQueue — Touch/Key-Events | Input-API |
| `std/android/native_window.lyu` | ANativeWindow — Direkt-Rendering | Window-API |

**Tasks:**
- [ ] `std/android/log.lyu`: `logD/logI/logW/logE(tag, msg)` als JNI-Calls
- [ ] `std/android/asset.lyu`: `assetOpen`, `assetRead`, `assetClose`
- [ ] `std/android/native_window.lyu`: `ANativeWindow_fromSurface`, `lock`, `unlockAndPost`
- [ ] `std/android/sensor.lyu`: Grundlegende Sensor-Enumeration und Daten-Polling

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
