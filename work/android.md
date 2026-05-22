# Android Backend — Status & Fahrplan

## 1. Übersicht

Android läuft auf dem Linux-Kernel — ARM64 als Primärziel, x86_64 für
Emulatoren. Lyx hatte schon ein Linux-ARM64-Backend und einen ELF-Writer; die
Lücken zur lauffähigen `.so` waren **Bionic-ABI**, die **JNI-Brücke**, das
**APK-Packaging** und ein Reihe halbfertiger IR-Pipeline-Stubs, die
WP-AND-Verifikation aufdeckte.

```
Ziel-Architektur:  ARM64 (aarch64-linux-android)  ← Primär
                   x86_64 (x86_64-linux-android)  ← Emulator/Testing
Branch:            feat/android-backend           (22 commits, S3==S4)
```

---

## 2. Aktueller Stand

| Komponente | Status |
|---|---|
| `--target=android-arm64` / `android-x86_64` | ✅ |
| ET_DYN `.so` Output (`--shared`) | ✅ strukturell vollständig |
| Symbol-Export `@export` + JNI-Mangling `@jni(class=…, method=…)` | ✅ |
| Bionic-ABI-Compliance (Stack-Alignment, no x18, no TPIDR_EL0) | ✅ |
| `.note.android.ident` + `.eh_frame` + `.eh_frame_hdr` + PT_GNU_EH_FRAME | ✅ |
| `.rela.dyn` mit `R_AARCH64_RELATIVE` Relocations | ✅ |
| `.data`-Section mit globalen Variablen + Init-Werten | ✅ |
| `@export`-Funktionen aus `import std.android.jni` direkt aufrufbar | ✅ (User-Function-Call + Import-Body-Lowering) |
| `_indirect_call_N(fnPtr, …)` für JNIEnv-VTable-Calls | ✅ |
| Forward-References zwischen Top-Level-Funktionen | ✅ |
| Korrekte Codegen für `return a + b` (Param-Spill + retVal→x0) | ✅ |
| Android-Stdlib: `std/android/{log, jni, asset, sensor, input, native_window, looper, native_activity, app_glue, gles2, manifest_gen, random, restrictions, ioctl, zip_writer, apk_builder}` | ✅ |
| AndroidManifest.xml-Generator + Pure-Lyx ZIP-Writer + APK-Builder | ✅ |
| `make singularity` (S3 == S4 bit-identisch) | ✅ über alle 22 Commits |
| Externe Library-Calls via PLT (libandroid, libGLESv2, libEGL, …) | ❌ |
| String-Literals in `.rodata` der `.so` | ❌ |
| NDK / Emulator End-to-End-Loadtest | ❌ (Tooling nicht lokal) |

---

## 3. Branch-Inhalt

### Erledigte Work-Packages (WP-AND-01..08)

| Commit | Was |
|---|---|
| `fbaea30` | **WP-AND-01** Android-Targets registriert (`--target=android-arm64`/`-x86_64`/`-android`) |
| `5163b27` | **WP-AND-02 Phase A** ET_DYN `.so` mit `.dynamic`/`.dynsym`/`.dynstr`/`.hash`, SONAME, 3 PT_LOAD/PT_DYNAMIC headers |
| `14bb5ff` | **WP-AND-02 Phase B** `@export`-Annotation → echte `STB_GLOBAL\|STT_FUNC` Symbol-Tabelle |
| `74ed6f0` | **WP-AND-02 Phase B2** `@jni(class=…, method=…)` Annotation + `Java_<class>_<method>` Mangling |
| `2598046` | **WP-AND-02 Phase C** `R_AARCH64_RELATIVE` Infrastruktur, `_emitLoadGlobalPIC` Literal-Pool |
| `c1bf62e` | **WP-AND-03** Bionic-ABI-Audit + `.note.android.ident` + DWARF CFI in `.eh_frame` + `.eh_frame_hdr` + PT_GNU_EH_FRAME |
| `a68f11c` | **WP-AND-04** `std/net/internal/syscalls_android` + `std/android/restrictions` + `random` + `ioctl` Konstanten |
| `e9c8b37` | **WP-AND-05 Phase A** `std/android/jni.lyx`: 40+ Type-Aliases, JNIEnv-VTable-Slot-Katalog |
| `6f1b908` | **WP-AND-06** `std/android/log` (voll funktional via stderr) + asset/sensor/input/native_window (Konstanten + Struct-Layouts) |
| `d2d5362` | **WP-AND-07** NativeActivity-Scaffolding: looper/native_activity/app_glue + GLES2-Konstanten + Manifest-Generator |
| `60ce79b` | **WP-AND-08** Pure-Lyx `std/android/zip_writer` + `apk_builder` + End-to-End-Demo |

### Upstream-Pipeline-Fixes (entdeckt + behoben während WP-AND-Arbeit)

| Commit | Was |
|---|---|
| `e30cfa8` | `_indirect_call_0..4` Builtin-Familie + JNI-Wrapper in `std/android/jni.lyx` (`JNI_GetVersion`, `JNI_NewStringUTF`, 17 weitere) |
| `a291f05` | User-Function-Call Lowering: `lowerCall` Inline-Lookup im `funcBuffer` + `_addFunc` mit echter Namens-Speicherung |
| `ba23ac2` | `lowerModule` walkt `NK_IMPORT`-Knoten, lädt+parsed Datei, swappt `src/nodes`, rekursiert |
| `b82acb0` | `NK_IDENT` (Parameter-Lookup über `curFunc`-Param-Chain) + `NK_BINOP` (echte `IRO_ADD`/`SUB`/`MUL`/`CMP_*`/…) |
| `43028bf` | `NK_VAR_DECL` allokiert Slot + `IRO_STORE_LOCAL` mit Init + per-function `localNameBuf` |
| `1060c98` | Top-Level `NK_VAR_DECL` → `globalNameBuf`; `NK_IDENT` Fallback auf Globals |
| `f43b519` | `IRO_LOAD_GLOBAL` end-to-end: `emit_arm64` emittiert PIC Literal-Pool mit `globalRelocBuf`-Tracking, `writeELFSharedLib` schreibt `.data`-Section + R_AARCH64_RELATIVE pro Slot, Cross-Module-Globals via IR-Stringtabelle |
| `eb19e5a` | `NK_UNOP`: `IRO_NEG`/`IRO_NOT`/`IRO_BITNOT` werden emittiert |
| `76de413` | Param-Spill im Prolog (x0..x7 → Slot 0..N-1) + `retValTemp` → x0 vor Epilog |
| `65128ad` | Slot-Allocator-Reordering: Params bekommen 0..N-1 sauber, retValTemp danach (war Slot-0 Kollision) |
| `13f6bb3` | Forward-References: `lowerModule`-Pre-Pass registriert alle Funcs vor Body-Pass, `emit_arm64.applyPatches` mit `labelId=-2` Marker + finalem Pass am Ende von `emit()` |

---

## 4. Offene Work-Packages

### 🔴 Echte Blocker für "läuft auf Android-Gerät"

#### WP-AND-09: PLT-Infrastruktur für externes Library-Linking

**Aufwand:** 8–15h. **Blockiert:** alle libandroid/libGLESv2/libEGL/liblog-Calls.

- ARM64-Codegen für `R_AARCH64_GLOB_DAT` (GOT-Einträge für externe Globals)
- ARM64-Codegen für `R_AARCH64_JUMP_SLOT` (PLT-Einträge für externe Funktionen)
- `.rela.plt` Sektion + GOT-Tabelle im `writeELFSharedLib`
- `.dynamic` Erweiterung: `DT_PLTREL`, `DT_JMPREL`, `DT_PLTGOT`, `DT_PLTRELSZ`
- `DT_NEEDED` Einträge pro extern verlinktes Lib
- Frontend: `@extern fn` Annotation oder Schlüsselwort, die das Frontend triggert,
  ein Symbol als unresolved zu markieren statt es zu lowern
- `_indirect_call_N` als Fallback bleibt; PLT ist nur die transparente Lösung

Mit PLT würden die TODO-Function-Wrapper in `std/android/asset.lyx`,
`std/android/sensor.lyx`, `std/android/input.lyx` und
`std/android/native_window.lyx` aktiviert werden — alle Konstanten + Struct-
Layouts dafür sind schon da.

#### WP-AND-10: String-Literals landen tatsächlich in der `.so`

**Aufwand:** 2–3h. **Blockiert:** `LogI("tag", "msg")`, `PrintStrLn("…")`,
jeden String-Output.

`PrintStrLn("Hello from Lyx")` produziert aktuell keine `Hello`-Bytes in der
`.so` (im IR-Modus). `NK_LIT_STR` emittiert zwar `IRO_CONST_STR` mit strOff
ins IR-String-Buffer, aber `emit_arm64` materialisiert daraus keine `.rodata`-
Section, und kein Codepfad gibt dem `IRO_CONST_STR` einen runtime-erreichbaren
Pointer.

- `writeELFSharedLib` schreibt eine `.rodata`-Section mit allen IR-strings
- `emit_arm64.emitConstStr` (neu) emittiert Literal-Pool-Sequenz analog zu
  `_emitLoadGlobalPIC`, slot = strOff + .rodata base, mit R_AARCH64_RELATIVE
- Wahrscheinlich auch Codegen-Eingriff: aktuell scheint NK_LIT_STR-Lowering
  unvollständig (nodeIVal(expr) für `strOff` ist möglicherweise nicht gesetzt
  weil Parser/Sema-Pipeline String-Pool-Konstruktion nicht vollständig macht)

#### WP-AND-11: NDK/Emulator End-to-End-Test

**Aufwand:** 1–2h (Setup) + Iteration. **Out-of-scope** für reine Compiler-Arbeit
ohne installierte Tooling — der Test-Loop selbst braucht Android-SDK/NDK auf
dem Build-Host.

- Android-NDK r25+ Toolchain installieren
- `lyxc --target=android-arm64 --shared` Output via
  `aarch64-linux-android-readelf` validieren (nicht nur system readelf)
- Emulator (`emulator -avd Pixel_API_34`) starten
- Minimal-Kotlin-App mit JNI-Bindings bauen, `.so` einbetten via APK-Build
- `adb install` + Logcat-Inspektion
- Bestätigt: `Java_com_example_MyClass_nativeAdd(3, 4) == 7`

### 🟡 Substantielle TODOs (jeder isoliert lieferbar)

#### WP-AND-12: `&x` Address-Of in `NK_UNOP`

**Aufwand:** 1–2h. Aktuell `&x` fällt durch zum `loaded value`-Stub.
Braucht `IRO_LOAD_LOCAL_ADDR`-Pfad in `ir_lower` + entsprechende
`emit_arm64`-Dispatch.

#### WP-AND-13: Non-literal Initializer für globale Variablen

**Aufwand:** 1–2h. `var x: int64 := compute()` defaultet aktuell auf 0,
weil die Pre-Pass-Init-Extraktion nur `NK_LIT_INT` erkennt. Optionen:
- Constructor-Code im `_init`-Block bei Loader-Time (braucht `DT_INIT`)
- Compile-Time-Constant-Evaluation für mehr Ausdrücke (Addition zweier Literals etc.)

#### WP-AND-14: `sys_getrandom` nativer Syscall

**Aufwand:** 1h. Aktuell macht `std/android/random.AndroidRandomBytes`
`/dev/urandom`-Fallback. Mit `sys_getrandom` (ARM64: 278, x86_64: 318)
als Builtin spart das einen FD-Roundtrip.

- `sys_getrandom` als Builtin-Name in `codegen_x86.lyx` und
  `src/backend/arm64/emit_arm64.lyx` erkennen, entsprechender Syscall emittieren
- Sema registriert den Namen
- `random.lyx` AndroidRandomBytes ruft `sys_getrandom` mit Fallback-Pfad

#### WP-AND-15: Section-Headers in `.so`

**Aufwand:** 2h. `readelf --debug-dump=frames` braucht Section-Headers um
`.eh_frame` zu finden. Aktuell `.so` hat `e_shnum=0`. Mit Section-Headers
funktionieren Standard-Debug-Tools direkt (GNU `addr2line`, `objdump -W`).

#### WP-AND-16: Pure-Lyx AXML-Encoder

**Aufwand:** 6h. Ersetzt `aapt2 compile && aapt2 link` für `.so`-only Apps.
Binary-AXML-Format: String-Pool + Resource-Map + XML-Tree mit Namespace-
Handling. Eigenes Modul `std/android/axml_encoder.lyx` parsed
`AndroidManifest.xml`-Text und produziert die Binärform.

#### WP-AND-17: Pure-Lyx classes.dex Stub-Generator

**Aufwand:** 5h. Ersetzt `javac + d8`. Minimal-Dex mit einer leeren
Stub-Klasse, mit korrektem Dex-Header (magic, checksum, sha1, sizes),
String-Pool, Type-IDs, Method-IDs, Class-Defs. Modul `std/android/dex_gen.lyx`.

#### WP-AND-18: Pure-Lyx APK-Signing

**Aufwand:** 3–5h. v1 JAR Signing oder v2 (APK Signature Scheme v2).
- v1: SHA-1 jeder Entry, MANIFEST.MF + CERT.SF + CERT.RSA (PKCS#7)
- v2: SHA-256 + Signing-Block zwischen ZIP-Entries und Central Directory
- Crypto: SHA-1/SHA-256 sind in `std/crypto/` schon vorhanden; RSA-Signing
  braucht neue Module (asn.1 encoding für PKCS#7)

#### WP-AND-19: `adb install` Wrapper + CLI-Integration

**Aufwand:** 1–2h. Pure-Lyx, nur `exec("adb", ["install", "-r", path])`.
- `std/android/adb.lyx` mit `AdbInstall(path)`, `AdbUninstall(pkg)`,
  `AdbLogcat(filter)`, `AdbShell(cmd)`
- `lyxc --install` Flag der die fertige APK direkt aufs Gerät schiebt

#### WP-AND-20: Binder IPC

**Aufwand:** 5–8h. Android-spezifisches Protokoll für Service-Calls.
- `/dev/binder` Open + `ioctl` für BINDER_WRITE_READ
- Parcel-Format für Method-Arguments
- Service-Manager-Lookup (via Binder-Handle 0)
- `std/android/binder.lyx` Modul; zusätzliche `BINDER_*` Konstanten in
  `std/android/ioctl.lyx` schon vorbereitet

#### WP-AND-21: Vulkan-Bindings

**Aufwand:** 5h. Hunderte Konstanten + Struct-Layouts.
Wartet auf WP-AND-09 (PLT) damit `libvulkan.so` callbar wird.

### 🟢 Polishing

| WP | Beschreibung | Aufwand |
|---|---|---|
| WP-AND-22 | `IRO_FUNC_EXIT` als bewusste IR-Op statt impliziter Epilogue | 30 min |
| WP-AND-23 | Import-Deduplizierung in `ir_lower.lowerModule` | 30 min |
| WP-AND-24 | Forward-Refs im nested-scope (nicht nur top-level) | 1–2h |
| WP-AND-25 | `IRO_LOAD_GLOBAL` für **executable**-Mode (aktuell nur Shared-Lib funktional) | 1h |
| WP-AND-26 | DT_INIT/DT_FINI in `.dynamic` für Modul-Init-Hooks | 1–2h |

---

## 5. Cross-Kompilierungs-Toolchain

Für native Tests auf dem Entwicklungsrechner (nicht auf Gerät):

```bash
# Android NDK r25+
export ANDROID_NDK=~/Android/Sdk/ndk/25.2.9519653
export TOOLCHAIN=$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64

# Lyx kompiliert für Android ARM64
./lyxc hello.lyx --target=android-arm64 --shared --android-api=26 -o libhello.so

# Prüfen mit NDK-readelf (bisher unsererseits noch nicht getestet)
$TOOLCHAIN/bin/llvm-readelf -d libhello.so
$TOOLCHAIN/bin/llvm-readelf -r --use-dynamic libhello.so
$TOOLCHAIN/bin/llvm-readelf -W --syms libhello.so

# Komplette APK-Pipeline (Phase A funktional)
./lyxc --target=android-arm64 --shared --android-api=26 myapp.lyx -o libmyapp.so
./lyxc -o gen_manifest examples/android/manifest_demo.lyx
./gen_manifest > AndroidManifest.xml
aapt2 link -o myapp.unsigned.apk --manifest AndroidManifest.xml \
  -I $ANDROID_SDK/platforms/android-34/android.jar
# WP-AND-08 ApkBuilder kann die APK auch direkt zusammenstellen
apksigner sign --ks debug.keystore --ks-pass pass:android \
  --out myapp.apk myapp.unsigned.apk
adb install -r myapp.apk
```

---

## 6. Mindestversionsstrategie

| API-Level | Android-Version | Grund |
|---|---|---|
| API 21 | Android 5.0 | 64-Bit ARM64 Pflicht |
| API 23 | Android 6.0 | `getrandom` Syscall verfügbar |
| API 26 | **Android 8.0** | **Empfohlenes Minimum**, Default für `--android-api` |
| API 28 | Android 9.0 | `memfd_create` verfügbar |
| API 30 | Android 11 | `pidfd_open` verfügbar |
| API 34 | Android 14 | Target-SDK in `manifest_gen` Default |

---

## 7. Siehe auch

- `src/lyxc.lyx` — zentraler ELF-Header-Writer + `writeELFSharedLib`
- `src/backend/arm64/emit_arm64.lyx` — ARM64-Codegen mit Bionic-ABI-Audit-Kommentaren
- `src/ir_lower.lyx` — IR-Pipeline (NK_IDENT/BINOP/UNOP/VAR_DECL/CALL/LOAD_GLOBAL nach den Upstream-Fixes funktional)
- `std/android/` — 16 Lyx-Module: JNI-Typen, Logger, Asset/Sensor/Input/Window-Konstanten, NativeActivity-Scaffolding, Looper, GLES2, Manifest-Generator, ZIP/APK-Writer
- `std/net/internal/syscalls_android.lyx` — Android-Netzwerk-Syscall-Wrapper + Restriction-Stubs
- `examples/android/` — `jni_native_add.lyx`, `jni_callback_inline.lyx`,
  `jni_callback_local.lyx`, `manifest_demo.lyx`, `build_apk_demo.lyx`

> **Hinweis:** Seit Singularität (2026-03-30) ist der FPC-Bootstrap
> (`compiler/`, `bootstrap/`) Geschichte. Sämtlicher Compilercode liegt in
> `src/` als Lyx-Quellen; gebaut wird durch `src/lyxc_bootstrap` (das
> singularitäts-verifizierte Seed-Binary).
