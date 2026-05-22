# iOS Backend — Fahrplan

## 1. Übersicht

iOS basiert auf dem XNU-Kernel und nutzt das **Mach-O**-Binärformat (gleich wie
macOS). Lyx hat bereits einen Mach-O-Writer und ein macOS-x64-Backend — das
ARM64-Mach-O-Backend ist der direkte Ausgangspunkt. Der entscheidende Unterschied
zu macOS liegt in den **iOS-spezifischen Frameworks** (UIKit statt AppKit),
der zwingenden **Code-Signierung** (kein Ausführen ohne Signatur) und dem
**Xcode/IPA-Packaging** für die Distribution.

```
Ziel-Architektur:  ARM64 (aarch64-apple-ios)       ← Primär (Gerät)
                   x86_64 / ARM64 Sim (Simulator)  ← Tests/Entwicklung
```

---

## 2. Aktueller Stand

| Komponente | Status | Lücke |
|---|---|---|
| macOS ARM64 Backend | ✅ Vorhanden | iOS-SDK-Pfade, iOS-Syscalls |
| Mach-O Writer | ✅ Vorhanden (`macho64_writer.pas`) | Load Commands für iOS |
| ARM64 Codegen | ✅ Vorhanden | iOS ABI-Abweichungen |
| iOS Syscall-Interface | ❌ Fehlt | Mach-Traps vs. BSD-Syscalls |
| Code-Signierung | ❌ Fehlt | Komplett neu |
| UIKit-Bindungen | ❌ Fehlt | Komplett neu |
| Xcode-Projektgenerierung | ❌ Fehlt | Komplett neu |
| IPA-Packaging | ❌ Fehlt | Komplett neu |

---

## 3. Phasen-Übersicht

```
Phase 1: iOS ARM64 Binaries (statisch, kein UI, Jailbreak/Simulator)
Phase 2: Framework-Linking (UIKit, Foundation, CoreFoundation)
Phase 3: Code-Signierung (Developer-Zertifikat, Entitlements)
Phase 4: Xcode-Projektgenerierung (.xcodeproj)
Phase 5: UIKit-Bindungen (Lyx iOS UI)
Phase 6: App Store Pipeline (IPA, Notarisierung)
```

---

## 4. Work Packages

### WP-IOS-01: iOS-Zielplattform registrieren

**Ziel:** `--target=ios-arm64` und `--target=ios-simulator-arm64` als gültige
Ziele im Compiler.

**Aufwand:** 2h

**Betroffene Dateien:**
- `compiler/backend/backend_types.pas` — neues `btIosArm64`, `btIosSimArm64`
- `compiler/lyxc.lpr` — CLI-Argument-Parsing
- `compiler/backend/macho/` — iOS Mach-O-Variante

**Tasks:**
- [ ] `TBackendTarget` Enum um `btIosArm64`, `btIosSimArm64` erweitern
- [ ] Target-Triple: `aarch64-apple-ios17.0`
- [ ] iOS-SDK-Pfad-Erkennung: `xcrun --sdk iphoneos --show-sdk-path`
- [ ] Plattform-Versions-LC: `LC_VERSION_MIN_IPHONEOS` (älteres SDK) oder
      `LC_BUILD_VERSION` mit Platform `IOS` (neuere SDKs)

---

### WP-IOS-02: Mach-O Load Commands für iOS

**Ziel:** Der Mach-O-Writer erzeugt iOS-kompatible Load Commands, die der
iOS-Linker/Loader akzeptiert.

**Aufwand:** 6h

**Betroffene Dateien:**
- `compiler/backend/macho/` — Mach-O-Writer
- `macho64_writer.pas`

**Unterschiede macOS ↔ iOS in Load Commands:**

| Load Command | macOS | iOS |
|---|---|---|
| Plattformversion | `LC_VERSION_MIN_MACOSX` | `LC_BUILD_VERSION` (platform=2) |
| min. Version | 10.9+ | 14.0+ |
| Simulator | Nein | `LC_BUILD_VERSION` (platform=7) |
| dyld-Info | `LC_DYLD_INFO_ONLY` | gleich |

**Tasks:**
- [ ] `LC_BUILD_VERSION` mit `platform=2` (iOS) statt `LC_VERSION_MIN_IPHONEOS`
- [ ] `LC_BUILD_VERSION` mit `platform=7` (iOS-Simulator)
- [ ] `minos`: iOS 14.0 als Mindestversion (format: `0x000E0000` = 14.0)
- [ ] `sdk`: Aktuelle SDK-Version aus `xcrun` auslesen
- [ ] `LC_SOURCE_VERSION` für Debug-Info
- [ ] Test: `otool -l` zeigt korrekte iOS-Load-Commands

---

### WP-IOS-03: iOS Syscall-Interface

**Ziel:** Lyx-Code auf iOS kann Systemfunktionen aufrufen (Datei-IO, Speicher,
Zeit) ohne Abstürze durch falsche Syscall-Konventionen.

**Aufwand:** 8h

**Hintergrund:** iOS nutzt XNU (Mach + BSD). Syscalls über `svc #0x80` (Mach-Trap)
oder `svc #0x0` (BSD-Syscall). iOS-Syscall-Nummern sind **nicht identisch** mit
macOS. Wichtiger Unterschied: iOS erlaubt `vm_allocate` (Mach), aber kein direktes
`mmap` von ausführbarem Code auf physischen Geräten (W^X-Policy).

**Neue Datei:** `std/net/internal/syscalls_ios_arm64.lyu`

**Tasks:**
- [ ] BSD-Syscall-Tabelle für iOS ARM64 (Nummern verifizieren via XNU Source)
- [ ] Mach-Trap-Tabelle: `task_self`, `vm_allocate`, `vm_deallocate`
- [ ] W^X-Einschränkung dokumentieren: kein `PROT_EXEC` auf `mmap` bei JIT-Code
- [ ] Speicher-Allokation: `mmap` für iOS verifizieren (funktioniert für Daten)
- [ ] `sysctl` für Geräteinformationen
- [ ] Test: Minimales Lyx-Binary läuft im iOS-Simulator

---

### WP-IOS-04: Code-Signierung Integration

**Ziel:** `lyxc` signiert erzeugte iOS-Binaries automatisch (Ad-hoc oder mit
Developer-Zertifikat), sodass iOS sie ausführt.

**Aufwand:** 10h

**Arten der Signierung:**

| Art | Verwendung | Tool |
|---|---|---|
| Ad-hoc (`-`) | Simulator, Jailbreak | `codesign -s -` |
| Development | Gerät mit Provisioning | `codesign -s "iPhone Developer"` |
| Distribution | App Store | `codesign -s "iPhone Distribution"` |

**Tasks:**
- [ ] `codesign`-Tool-Integration als Post-Build-Schritt
- [ ] `Info.plist` Generator: `CFBundleIdentifier`, `CFBundleExecutable`, `MinimumOSVersion`
- [ ] Entitlements-Datei Generator (`.entitlements` XML)
- [ ] Ad-hoc-Signierung: `lyxc --target=ios-arm64 --sign=adhoc`
- [ ] Developer-Signierung: `lyxc --target=ios-arm64 --sign="iPhone Developer:Name"`
- [ ] Provisioning Profile Einbetten: `embedded.mobileprovision` in App-Bundle
- [ ] Test: Signiertes Binary startet auf physischem Gerät (mit Dev-Profil)

---

### WP-IOS-05: Foundation Framework Bindungen

**Ziel:** Lyx-Code kann Foundation-Klassen nutzen (`NSString`, `NSArray`,
`NSDictionary`, `NSData`, `NSURL`, `NSFileManager`).

**Aufwand:** 16h

**Neue Datei:** `std/ios/foundation.lyu`

**Strategie:** Objc-Runtime-Aufrufe via `objc_msgSend` — kein Swift-Bridging,
kein Header-Include. Lyx ruft direkt `objc_msgSend` mit Selektoren auf.

```lyx
import std/ios/foundation

var str: NSString = NSString.stringWithUTF8String("Hallo iOS")
Println(str.UTF8String())
```

**Tasks:**
- [ ] `objc_msgSend` als extern-Funktion eintragen
- [ ] Selektor-Cache: `sel_registerName` Wrapper
- [ ] `NSString`: `alloc/init`, `stringWithUTF8String`, `UTF8String`, `length`
- [ ] `NSData`: `dataWithBytes`, `bytes`, `length`
- [ ] `NSArray` / `NSDictionary`: Basis-Operationen
- [ ] `NSFileManager`: `fileExistsAtPath`, `createFileAtPath`, `removeItemAtPath`
- [ ] `NSURL`: `fileURLWithPath`, `absoluteString`
- [ ] `NSBundle`: `mainBundle`, `resourcePath`, `pathForResource`

---

### WP-IOS-06: UIKit Framework Bindungen

**Ziel:** Lyx-Code kann eine einfache iOS-App mit echtem UI erstellen
(UIViewController, UIView, UILabel, UIButton).

**Aufwand:** 30h

**Neue Datei:** `std/ios/uikit.lyu`

**App-Einstiegspunkt:**
```lyx
import std/ios/uikit

@ios_main
fn appMain(argc: int64, argv: ^^pchar): int64 {
    return UIApplicationMain(argc, argv, nil, "AppDelegate")
}
```

**Tasks:**
- [ ] `UIApplication` + `UIApplicationDelegate`-Protokoll
- [ ] `UIWindow` + `UIWindowScene` (iOS 13+)
- [ ] `UIViewController`: `viewDidLoad`, `viewWillAppear`
- [ ] `UIView`: `frame`, `bounds`, `addSubview`, `backgroundColor`
- [ ] `UILabel`: `text`, `font`, `textColor`, `textAlignment`
- [ ] `UIButton`: `setTitle`, `addTarget` (via `objc_msgSend`)
- [ ] `UIStackView`: `axis`, `distribution`, `spacing`, `addArrangedSubview`
- [ ] `CGRect` / `CGSize` / `CGPoint` als Lyx-Structs
- [ ] `UIColor`: `systemBackgroundColor`, `labelColor`, `RGB-Init`
- [ ] `UIFont`: `systemFontOfSize`, `boldSystemFontOfSize`
- [ ] Auto-Layout-Basics: `NSLayoutConstraint` aktivieren
- [ ] Test: Lyx-App zeigt "Hallo Welt" Label auf physischem iPhone

---

### WP-IOS-07: SwiftUI-Brücke (optional, fortgeschritten)

**Ziel:** Lyx-Code kann SwiftUI-Views als Host nutzen (Lyx-Logik + SwiftUI-UI).

**Aufwand:** 24h

**Strategie:** Lyx-Code als Swift Package (`.xcframework`) verpackt.
SwiftUI `UIViewRepresentable` wraps Lyx-Views.

**Tasks:**
- [ ] Lyx → Static Library (`.a`) Ausgabe für iOS
- [ ] C-Bridge-Header Generator: Lyx-Typen als C-kompatible API
- [ ] Swift Package Manifest Generator (`Package.swift`)
- [ ] `UIViewRepresentable` Wrapper-Template
- [ ] Xcode Framework Integration Guide

---

### WP-IOS-08: Xcode-Projekt-Generator

**Ziel:** `lyxc --target=ios-arm64 --gen-xcode` erzeugt ein vollständiges
`.xcodeproj`, das direkt in Xcode geöffnet und gebaut/deployed werden kann.

**Aufwand:** 20h

**Generierte Struktur:**
```
MyApp.xcodeproj/
├── project.pbxproj          (Xcode-Projektdatei)
├── xcshareddata/
│   └── xcschemes/
│       └── MyApp.xcscheme
MyApp/
├── Info.plist
├── MyApp-Bridging-Header.h  (optional)
└── Sources/
    └── main.lyx             (Lyx-Source)
```

**Tasks:**
- [ ] `project.pbxproj` Generator (PBX-Format, UUID-basiert)
- [ ] Build-Phase: "Run Script" → `lyxc` aufrufen
- [ ] Signing & Capabilities Konfiguration
- [ ] Scheme Generator (Debug/Release)
- [ ] `Info.plist` Template
- [ ] Test: Generiertes Projekt baut und deployt via Xcode ohne Änderungen

---

### WP-IOS-09: IPA-Packaging + App Store Pipeline

**Ziel:** `lyxc --target=ios-arm64 --package=ipa` erzeugt eine
App-Store-bereite `.ipa`-Datei.

**Aufwand:** 12h

**IPA-Struktur:**
```
MyApp.ipa
└── Payload/
    └── MyApp.app/
        ├── MyApp               (ARM64 Binary, signiert)
        ├── Info.plist
        ├── embedded.mobileprovision
        ├── _CodeSignature/
        │   └── CodeResources
        └── Base.lproj/
            └── LaunchScreen.storyboardc/
```

**Tasks:**
- [ ] `.app`-Bundle-Struktur erzeugen
- [ ] ZIP-Komprimierung: `Payload/` → `.ipa`
- [ ] `_CodeSignature/CodeResources` Generator (SHA256-Hashes aller Dateien)
- [ ] Distribution-Signierung via `altool` oder `notarytool`
- [ ] TestFlight Upload: `xcrun altool --upload-app -f MyApp.ipa`
- [ ] Test: IPA-Datei wird von TestFlight akzeptiert

---

## 5. Abhängigkeiten

```
WP-IOS-01 (Target registrieren)
    ↓
WP-IOS-02 (Mach-O Load Commands) ←── WP-IOS-03 (Syscalls)
    ↓
WP-IOS-04 (Code-Signierung)
    ↓
WP-IOS-05 (Foundation)
    ↓
WP-IOS-06 (UIKit)
    ↓
WP-IOS-07 (SwiftUI, optional) ──┐
WP-IOS-08 (Xcode-Generator)   ──┤
WP-IOS-09 (IPA-Packaging)     ──┘
```

---

## 6. Zeitschätzung

| Phase | WPs | Aufwand |
|---|---|---|
| Phase 1: Grundlagen | WP-IOS-01..03 | ~16h |
| Phase 2: Signing | WP-IOS-04 | ~10h |
| Phase 3: Frameworks | WP-IOS-05..06 | ~46h |
| Phase 4: Tooling | WP-IOS-07..09 | ~56h |
| **Gesamt** | **9 WPs** | **~128h** |

---

## 7. Technische Besonderheiten

### W^X (Write XOR Execute) Policy
iOS erzwingt strikt: Speicherseiten können nicht gleichzeitig schreibbar und
ausführbar sein. Kein JIT-Code möglich (außer mit `com.apple.security.cs.allow-jit`
Entitlement, nur für privilegierte Apps). Lyx-AOT-Kompilierung ist nicht betroffen.

### Objective-C Runtime
Alle UIKit/Foundation-Calls gehen über `objc_msgSend`. Lyx muss keine
Objective-C-Syntax kennen — reiner C-API-Aufruf über `libobjc.A.dylib`.

```
objc_msgSend(receiver, sel_registerName("methodName:"), arg1)
```

### Simulator vs. Gerät
- Simulator läuft auf macOS x86_64 oder ARM64 — nutzt macOS-Syscalls, nicht iOS
- Physisches Gerät: iOS-Syscalls, W^X, Code-Signierung zwingend
- Strategie: Simulator-Target nutzt macOS-Backend mit iOS-Frameworks

### Bitcode (veraltet)
Apple hat Bitcode ab Xcode 14 abgeschafft. Kein Bitcode-Support nötig.

---

## 8. Entwicklungs-Testfälle

```bash
# Phase 1: Simulator-Test (kein Gerät nötig)
./lyxc hello.lyx --target=ios-simulator-arm64 -o hello.app/hello
codesign -s - hello.app/hello
xcrun simctl install booted hello.app
xcrun simctl launch booted com.example.hello

# Phase 2: Gerät-Test (Developer-Profil nötig)
./lyxc hello.lyx --target=ios-arm64 -o hello.app/hello --sign="iPhone Developer"
ios-deploy --bundle hello.app

# Phase 3: IPA erstellen
./lyxc hello.lyx --target=ios-arm64 --package=ipa -o hello.ipa
```

---

## 9. Mindestversionen

| iOS-Version | Grund |
|---|---|
| iOS 13.0 | `UIWindowScene`, Dark Mode, Swift-UI 1.0 |
| iOS 14.0 | Widgets, App Clips |
| iOS 16.0 | `UIHostingController` verbessert, Lock Screen Widgets |
| **iOS 15.0** | **Empfohlenes Minimum** (96% Marktanteil) |

---

## 10. Unterschiede Android vs. iOS

| Merkmal | Android | iOS |
|---|---|---|
| Kernel | Linux | XNU (Mach + BSD) |
| Binärformat | ELF (.so) | Mach-O |
| Syscalls | Linux ARM64 | Mach-Traps + BSD |
| Signing | Optional (Debug) | **Zwingend** |
| JIT-Code | Erlaubt | Eingeschränkt (W^X) |
| UI-Framework | NDK / NativeActivity | UIKit via ObjC-Runtime |
| Store-Distribution | APK / AAB | IPA / App Store Connect |
| Aufwand (gesamt) | ~81h | **~128h** |

---

## 11. Siehe auch

- `backend-upgrade.md` — Bestehende Backend-Upgrade-Roadmap
- `android.md` — Android-Backend-Fahrplan (verwandter, einfacherer Pfad)
- `compiler/backend/macosx64/` — macOS x64-Backend (Basis)
- `compiler/backend/arm64/` — ARM64-Backend
- `compiler/backend/macho/` — Mach-O-Writer
- `macho64_writer.pas` — Bestehender Mach-O-Writer
- `syscalls_macos.pas` — macOS-Syscall-Referenz
