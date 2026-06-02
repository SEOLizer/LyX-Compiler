# GPU- und SIMD-Unterstützung für Lyx – Fahrplan & Arbeitspakete

> **Dokumenttyp:** Konzept & Implementierungsfahrplan  
> **Bezug:** Ursprüngliches Konzeptpapier (gpu-support.md, v1) – "GPU-Unterstützung in Lyx"  
> **Stand:** 2026-05-31 (v2 – überarbeitet und erweitert)  
> **Autor:** Architekturanalyse auf Basis des Lyx-Projektstands v0.9.0A

---

## 1. Einordnung & Hintergrund

### 1.1 Das ursprüngliche Dokument

Das Konzeptpapier `gpu-support.md` (v1) skizzierte vier Kernbereiche für GPU-Unterstützung:

1. **Heterogene Kompilierung** (Single-Source: CPU + GPU in einer Datei via `gpu`/`kernel`-Attribute)
2. **Zero-Cost Abstractions für GPU-Pipelines** (typ-basierte State Machines für Vulkan)
3. **Explizites Speichermanagement** (`@device`, `@unified` – Memory Spaces)
4. **Native Unterstützung für Datenparallelismus** (Vektortypen `f32x4`, `gpu_parallel_for`)

Die Analyse hat gezeigt: Das Dokument war ein **ambitioniertes Brainstorming**, aber kein umsetzbarer Plan. Es vermischte Abstraktionsebenen, ignorierte den IST-Zustand und enthielt keine Plattformstrategie über x86-64 hinaus.

### 1.2 IST-Zustand: Was Lyx bereits hat

| Bereich | Status | Details |
|---------|--------|---------|
| **`ParallelArray<T>` (SIMD)** | ⚠️ Teilweise | Parser, Sema, IR-Opcodes (16 Stück) existieren – **aber kein einziger SSE/AVX-Befehl wird emittiert**. Codegen-Stubs sind leer. |
| **Native Vektortypen** | ❌ Nicht existent | Keine `f32x4`, `i32x4`, `u8x16` etc. |
| **GPU-Backend** | ❌ Nicht existent | Kein CUDA/NVPTX, kein Vulkan/SPIR-V, kein OpenCL |
| **Memory Spaces** | ❌ Nicht existent | `@device`/`@unified` nicht implementiert |
| **`gpu_parallel_for`** | ❌ Nicht existent | Keine Syntax, kein Parser, kein Codegen |
| **ML-Bibliothek** | 🟢 Vorhanden | 100 % CPU-skalar, kein SIMD/GPU |
| **ARM NEON** | ❌ Nicht existent | Kein SIMD-Codegen für ARM64-Backend |
| **RISC-V RVV** | ❌ Nicht existent | RISC-V Vector Extension nicht implementiert |
| **Xtensa SIMD** | ❌ Nicht existent | ESP32-S3 PIE/SIMD-Unit nicht implementiert |

**Kernerkenntnis:** Lyx hat **ein SIMD-IR-Gerüst für x86-64, aber keine funktionierende SIMD-Codegenerierung auf irgendeiner Plattform** und keinerlei GPU-Infrastruktur.

### 1.3 Zielsetzung

Dieser Fahrplan definiert **neun Arbeitspakete in drei Meilensteinen**. Die erste Ergänzung gegenüber v1: Die SIMD-Infrastruktur muss für **alle relevanten CPU-Backends** aufgebaut werden, nicht nur für x86-64.

```
Meilenstein 1 (3–5 Monate)          │  Meilenstein 2 (3–5 Monate)   │  Meilenstein 3 (>12 Monate)
─────────────────────────────────────┼───────────────────────────────┼────────────────────────────
WP1: SIMD-Codegen x86-64 reparieren  │  WP4: Native Vektortypen       │  WP7: GPU-Backend (SPIR-V)
WP2: CPU Feature Detection           │  WP5: Vektor-Stdlib            │  WP8: GPU-Laufzeit
WP3: ARM NEON                        │  WP6: Memory Spaces            │  WP9: Single-Source Offload
```

Das strategische Ziel bleibt ein **dreistufiger Ansatz**:

1. **Plattformbreite SIMD-Grundlage** – ParallelArray auf x86-64 und ARM64 tatsächlich vektorisieren
2. **Spracherweiterungen** – native Vektortypen + Memory Spaces
3. **GPU-Compute** – SPIR-V/LLVM-Backend + Single-Source-Offload

---

## 2. Fahrplan-Übersicht

```
Meilenstein 1 – SIMD-Fundament (3–5 Monate)
┌──────────────────────────────────────────────────────────────────────────┐
│ WP1: SIMD-Codegen x86-64    │  WP2: CPU Feature Detection  │  WP3: NEON  │
└──────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
Meilenstein 2 – Spracherweiterungen (3–5 Monate)
┌──────────────────────────────────────────────────────────────────────────┐
│  WP4: Native Vektortypen           │  WP5: Vektor-Stdlib                  │
│  WP6: Memory Spaces                │                                      │
└──────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
Meilenstein 3 – GPU-Compute (12–24 Monate)
┌──────────────────────────────────────────────────────────────────────────┐
│  WP7: GPU-Backend (SPIR-V/LLVM)    │  WP8: GPU-Laufzeit & Device-Mgmt   │
│  WP9: Single-Source + gpu_parallel_for                                   │
└──────────────────────────────────────────────────────────────────────────┘
```

| WP | Feature | Aufwand | Meilenstein |
|----|---------|---------|-------------|
| 1 | SIMD-Codegen x86-64 reparieren | 2–3 Wo | 1 |
| 2 | CPU Feature Detection & Runtime Dispatch | 2–3 Wo | 1 |
| 3 | ARM NEON SIMD | 3–4 Wo | 1 |
| 4 | Native Vektortypen | 4–6 Wo | 2 |
| 5 | Vektor-Standardbibliothek | 3–4 Wo | 2 |
| 6 | Memory Spaces (`@device`, `@unified`) | 4–6 Wo | 2 |
| 7 | GPU-Backend-Entscheidung & SPIR-V | 6–12 Mo | 3 |
| 8 | GPU-Laufzeit & Device-Management | 4–6 Mo | 3 |
| 9 | Single-Source + `gpu_parallel_for` | 6+ Mo | 3 |

---

## 3. Arbeitspakete

---

### WP1: SIMD-Codegenerierung x86-64 vervollständigen

#### Grund & Hintergrund

Lyx hat bereits eine überraschend vollständige SIMD-Infrastruktur im Frontend:

- **Parser** erkennt `parallel Array<T>(size)` → `NK_SIMD_NEW`-AST-Knoten
- **Sema** prüft Typ und Grösse
- **IR** definiert 16 SIMD-Operationen (ADD, SUB, MUL, DIV, CMP, LOAD/STORE_ELEM...)
- **IR_Lower** enthält Stubs (`lowerSIMDBinOp`, `lowerSIMDCmp`, etc.)
- **Codegen_x86** evaluiert die Grösse, **emittiert aber keine SIMD-Instruktionen**

**Das Problem:** Die Codegen-Stubs sind leer. Alle Operationen auf `ParallelArray<T>` werden skalar ausgeführt. Scope dieses WPs: x86-64 SSE2 + AVX2. Runtime-Feature-Detection (was passiert wenn ein AVX2-Binary auf SSE2-CPU läuft) ist WP2.

#### Ziel

`ParallelArray<T>` wird auf x86-64 in echte SSE2/AVX2-Instruktionen übersetzt.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `src/codegen_x86.lyx` | **Erweiterung** | SSE2/AVX2-Instruktionen emittieren |
| `src/ir_lower.lyx` | **Erweiterung** | Lowering-Stubs füllen |
| `src/ir.lyx` | **Erweiterung** | Ggf. neue IR-Opcodes (horizontale Operationen) |
| `tests/regression/simd/` | **Erweiterung** | Disassembly-Checks ergänzen |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 1.1 | **SSE2-Backend für ParallelArray füllen** | `emitSIMDAdd`, `emitSIMDSub`, `emitSIMDMul`, `emitSIMDDiv` – SSE2 (`addps`, `subps`, `mulps`, `divps`) und AVX2 (`vaddps`, ...). Codegen wählt AVX2 wenn aktives Feature-Flag gesetzt (WP2 liefert den Dispatch). |
| 1.2 | **SIMD-Load/Store implementieren** | `emitSIMDLoadElem` → `movss`/`movaps`. Alignment 16 Byte (SSE2) / 32 Byte (AVX2). Unaligned-Fallback (`movups`) wenn Alignment nicht garantiert. |
| 1.3 | **SIMD-Vergleiche emittieren** | `emitSIMDCmpEQ`, `CMPNE`, `CMPLT`, `CMPLE`, `CMPGT`, `CMPGE` → `cmpps` mit Predicate-Imm. |
| 1.4 | **SIMD-Bitoperationen** | `emitSIMDAnd`, `SIMDOr`, `SIMDXor` → `pand`, `por`, `pxor`. |
| 1.5 | **IR-Lowering für Constant Folding** | SIMD-Konstanten erkennen und falten, Alignment-Informationen propagieren. |
| 1.6 | **Registerspreizung für SIMD** | XMM/YMM-Register-Allokation (8–16 Register). Stack-Spilling wenn nötig. |
| 1.7 | **Unterstützte Element-Typen** | `f32`, `f64`, `int32`, `int64`, `uint8` (SSE2 `paddb`). Für nicht-unterstützte Typen: expliziter Compile-Fehler statt silentiesem Fallback. |
| 1.8 | **Compile-Zeit AVX2-Flag** | `--target-feature +avx2` aktiviert 256-Bit-Codegen. **Achtung:** Binaries mit diesem Flag sind nicht auf SSE2-CPUs lauffähig – das ist absichtlich, WP2 ergänzt den Runtime-Safety-Layer. |
| 1.9 | **Test-Suite** | Disassembly-Check via `objdump -d`: SSE/AVX-Instruktionen müssen nachweislich emittiert werden. Benchmark: SIMD-Addition ≥ 2× vs. skalare Schleife bei 256 Elementen f32 (nicht 4 – zu klein für aussagekräftige Messung). |

#### Abnahmekriterien

- [ ] `a + b` auf zwei `ParallelArray<f32>` emittiert `addps` (SSE2)
- [ ] `objdump -d output` zeigt SSE/AVX-Instruktionen
- [ ] SIMD-Vergleiche emittieren `cmpps` mit korrektem Predicate
- [ ] Benchmark: ≥ 2× Beschleunigung bei 256 f32-Elementen vs. skalare Schleife
- [ ] Compile-Fehler für nicht-unterstützte Element-Typen (kein stiller Fallback)

#### Aufwand

**2–3 Wochen**

#### Abhängigkeiten

Keine (IR-Opcodes und Parser sind vorhanden). WP2 (Feature Detection) wird parallel entwickelt.

---

### WP2: CPU Feature Detection & Runtime Dispatch

#### Grund & Hintergrund

WP1 erzeugt AVX2-Binaries via `--target-feature +avx2`. Das Problem: Eine AVX2-Instruktion auf einer SSE2-CPU erzeugt einen **Illegal Instruction SIGILL** – kein Compile-Fehler, kein Runtime-Fehler, sondern ein sofortiger Programmabsturz.

Für verteilbare Binaries (nicht nur für Entwickler-Builds) braucht Lyx einen **Runtime-Dispatch-Mechanismus**: Beim Programmstart wird via `cpuid` geprüft, welche SIMD-Fähigkeiten die CPU hat, und die optimierte Codepfad-Variante gewählt.

Dieser WP ist die **Voraussetzung dafür, dass WP1-Ergebnisse sicher ausgeliefert werden können**.

#### Ziel

Ein `cpuid`-basiertes Feature-Detection-System mit Dispatch-Tabellen, das zur Laufzeit den optimalen SIMD-Codepfad wählt.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `std/cpu/features.lyx` | **Neu** | CPU-Feature-Erkennung via `cpuid` |
| `std/cpu/dispatch.lyx` | **Neu** | Runtime-Dispatch-Tabellen |
| `src/codegen_x86.lyx` | **Erweiterung** | Multi-Version-Codegen (SSE2 + AVX2-Varianten) |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 2.1 | **`cpuid`-Wrapper implementieren** | `CpuFeatures.detect() -> CpuFeatureSet`. Erkennung: `SSE2` (immer auf x86-64), `SSE4_1`, `AVX2`, `AVX512F`. Linux: `cpuid`-Instruktion direkt. Windows: `__cpuid` via Inline-Asm oder Syscall. |
| 2.2 | **Feature-Cache** | `CpuFeatureSet` einmal beim Programmstart ermitteln, in einer globalen Variable cachen. Kein `cpuid` pro Operation. |
| 2.3 | **Dispatch-Tabellen generieren** | Compiler erzeugt bei Bedarf zwei Varianten einer SIMD-Funktion: `__fn_sse2` und `__fn_avx2`. Zur Laufzeit: Funktionszeiger auf die passende Variante setzen. |
| 2.4 | **`@target_feature`-Attribut** | `@target_feature("avx2") fn dot_avx2(...)` – Funktion wird nur unter AVX2-Annahme compiliert. Ohne das Attribut: portable SSE2-Variante. |
| 2.5 | **Graceful Degradation** | Fehlt AVX2 zur Laufzeit: SSE2-Codepfad wird verwendet (korrekt, langsamer). Fehlt SSE2 komplett (theoretisch, auf sehr alten x86-CPUs): Fehler mit Klartextmeldung statt SIGILL. |
| 2.6 | **ARM64: statisches Feature-Set** | NEON ist auf ARMv8-A garantiert (kein `cpuid` nötig). Feature-Set für ARM64: `NEON = true` (immer), `SVE = runtime-check` (optional, wenn Lyx-Compiler SVE unterstützt). |

#### Abnahmekriterien

- [ ] `CpuFeatures.detect()` gibt korrektes Feature-Set zurück (SSE2 immer true auf x86-64)
- [ ] Binary mit AVX2-Dispatch läuft auf SSE2-CPU ohne SIGILL (fällt auf SSE2-Pfad zurück)
- [ ] Dispatch-Overhead < 2 ns (Funktionszeiger-Aufruf, kein `cpuid` per Aufruf)
- [ ] ARM64: Feature-Set enthält NEON=true ohne `cpuid`

#### Aufwand

**2–3 Wochen** (parallel zu WP1 entwickelbar)

#### Abhängigkeiten

WP1 (braucht die SSE2-Varianten, die WP2 dispatcht)

---

### WP3: ARM NEON SIMD

#### Grund & Hintergrund

Lyx hat vier ARM-Zielbackends: **ARM64 Linux, ARM64 Windows, ARM64 macOS (Apple Silicon), ARM Cortex-M**. Nach WP1 läuft `ParallelArray<T>` auf x86-64 vektorisiert – auf allen ARM-Targets weiterhin skalar.

**NEON (ARM Advanced SIMD)** ist auf ARMv8-A **mandatory** – alle ARM64-Targets haben es, kein Runtime-Check nötig. Die gleichen 16 SIMD-IR-Opcodes aus WP1 werden in NEON-Instruktionen übersetzt statt in SSE/AVX.

**ARM Cortex-M:** Cortex-M55+ hat Helium (M-Profile Vector Extension). Da Lyx Cortex-M generisch als Target hat und Helium nicht auf allen Cortex-M-Chips verfügbar ist, gilt: **Cortex-M-SIMD ist in diesem WP out-of-scope**. `ParallelArray<T>` bleibt auf Cortex-M skalar (dokumentiertes Known-Gap).

**RISC-V RVV:** Die RISC-V Vector Extension arbeitet mit variablen Vektoriängen (`vsetvli` setzt die Länge zur Laufzeit). Das ist fundamental inkompatibel mit den fixen `f32x4`-Semantiken aus WP4. RISC-V-SIMD ist ebenfalls out-of-scope für Meilenstein 1 und 2.

#### Ziel

`ParallelArray<T>` wird auf ARM64 in echte NEON-Instruktionen übersetzt, mit demselben IR-Satz wie WP1.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `src/codegen_arm64.lyx` | **Erweiterung** | NEON-SIMD-Instruktionen emittieren |
| `src/ir_lower.lyx` | **Erweiterung** | ARM64-Lowering-Pfade ergänzen |
| `tests/regression/simd_arm64/` | **Neu** | NEON-Tests (Disassembly-Checks) |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 3.1 | **NEON-Arithmetik** | `emitSIMDAdd` → `vaddq_f32`, `vaddq_s32` etc. `emitSIMDSub/Mul/Div` analog. `f32x4`-Division: NEON hat keine `vdivq_f32` in ARMv7; ARMv8-A hat sie → prüfen welche Instruktion. |
| 3.2 | **NEON-Load/Store** | `vld1q_f32` / `vst1q_f32`. Alignment ist bei NEON flexibler als bei SSE2 (kein Alignment-Fault bei `vld1q`). |
| 3.3 | **NEON-Vergleiche** | `vceqq_f32`, `vcltq_f32`, `vcleq_f32`, `vcgtq_f32`, `vcgeq_f32`. Ergebnis ist Masken-Vektor (uint32x4). |
| 3.4 | **NEON-Bitoperationen** | `vandq_u8`, `vorrq_u8`, `veorq_u8`. |
| 3.5 | **Register-Allokation für NEON** | 32 x 128-Bit NEON-Register (v0–v31) auf ARM64. Register-Allokator in `codegen_arm64.lyx` anpassen. |
| 3.6 | **Bekannte Lücken dokumentieren** | Im Compiler-Output: Warnung wenn `ParallelArray<T>` auf Cortex-M oder RISC-V verwendet wird: „SIMD not available for this target, falling back to scalar." |
| 3.7 | **Test-Suite** | Disassembly-Checks: NEON-Instruktionen müssen emittiert werden. Benchmark: ≥ 2× Beschleunigung auf Apple M-Series vs. skalare Schleife. |

#### Abnahmekriterien

- [ ] `a + b` auf zwei `ParallelArray<f32>` emittiert `vaddq_f32` auf ARM64
- [ ] Cross-Compilation für Apple Silicon (aarch64-apple-darwin) produziert NEON-Code
- [ ] Scalar-Fallback auf Cortex-M mit expliziter Compiler-Warnung
- [ ] Benchmark: ≥ 2× Beschleunigung auf ARM64 bei 256 f32-Elementen

#### Aufwand

**3–4 Wochen**

#### Abhängigkeiten

WP1 (IR-Opcodes und Lowering-Infrastruktur), WP2 (Feature-Detection-API, ARM64-Teil)

---

### WP4: Native Vektortypen

#### Grund & Hintergrund

`ParallelArray<T>` ist ein **Array von Vektoren** (heap-allokiert). Lyx hat **keine skalaren Vektortypen**. Ein Ausdruck wie:

```
var a: f32x4 = (1.0, 2.0, 3.0, 4.0);
var c: f32x4 = a + a;
```

ist nicht möglich – es gibt keinen Typ `f32x4`. Entwickler müssen auf `ParallelArray<f32>` ausweichen, was für einzelne Vektoren umständlich und heap-allokierend ist.

**Designentscheidungen (vor Implementierungsstart zu treffen):**

**1. `float3` als Alias für `f32x4`:** 3D-Vektoren werden in 4-Komponenten-Registern gespeichert (SIMD-Alignment). Die 4. Komponente (`w`) ist mit **0.0** initialisiert. Mathematische Funktionen (`dot`, `cross`, `length`, `normalize`) arbeiten explizit nur auf den ersten 3 Komponenten. Das muss in der Stdlib (WP5) durchgezogen werden – es ist keine implizite Konvention.

**2. Swizzle-Syntax:** `v.x`, `v.y`, `v.z`, `v.w` verwenden Member-Access-Syntax. Der Parser muss **type-directed** arbeiten: `.x` ist nur eine Swizzle wenn der Typ des linken Ausdrucks ein Vektortyp ist. Normaler Struct-Feldzugriff bleibt unverändert.

**3. Verhalten auf Nicht-AVX-Targets:** `f32x8` und `f64x4` erfordern AVX (256-Bit-Register). Auf einem SSE2-Target (oder ARM64 ohne SVE) → **Compile-Fehler** (kein stiller 2×128-Bit-Fallback, der Performance-Garantien bricht).

#### Ziel

Einführung von nativen Vektortypen als Builtin-Typen mit Operator-Unterstützung auf allen SIMD-fähigen Targets.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `ebnf.md` | **Erweiterung** | Vektortypen, Vektorliterale |
| `src/lexer.lyx` | **Erweiterung** | Tokens für Vektortyp-Namen |
| `src/parser.lyx` | **Erweiterung** | Type-directed Swizzle-Parsing |
| `src/sema.lyx` | **Erweiterung** | Typ-Prüfung, Operator-Resolution, Target-Check |
| `src/ir.lyx` | **Erweiterung** | IR-Knoten für Vektor-Ops |
| `src/codegen_x86.lyx` | **Erweiterung** | Direktes XMM/YMM-Register-Emitting |
| `src/codegen_arm64.lyx` | **Erweiterung** | Direktes NEON-Register-Emitting |
| `std/vectortypes.lyx` | **Neu** | Typaliase, Konstanten, Dokumentation |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 4.1 | **Vektortypen definieren** | `f32x2`, `f32x4`, `f64x2`, `i32x4`, `i16x8`, `i8x16`, `u8x16` – immer verfügbar (SSE2/NEON). `f32x8`, `f64x4`, `i32x8` – nur mit `+avx2` / später SVE. |
| 4.2 | **EBNF erweitern** | `VectorType = ScalarType "x" ("2"|"4"|"8"|"16")`. `VectorLiteral = TypeName "(" Expression {"," Expression} ")"`. |
| 4.3 | **Parser: type-directed Swizzle** | `v.x` ist Swizzle genau dann wenn `type(v)` ein Vektortyp ist. Kein Konflikt mit Struct-Feldzugriff. Swizzle-Prüfung erfolgt in Sema, nicht im Parser. |
| 4.4 | **Operatoren** | `+`, `-`, `*`, `/` → komponentenweise SIMD-Op. Vergleiche → Masken-Vektor. Skalarer Broadcast: `f32x4(1.0)` → `(1.0, 1.0, 1.0, 1.0)`. |
| 4.5 | **Swizzle-Codegen** | `v.xyzw` → `shufps` (x86) / `vtrn`/`vzip`/`vtbl` (ARM NEON). `v.x` (Einzelkomponente) → `movss xmm0, xmm1` (x86) / `vmov.s` (ARM). |
| 4.6 | **Konvertierungsregeln** | `f32x4` → `i32x4`: `cvttps2dq`. `f64x2` → `f32x4`: `cvtpd2ps` (verlustbehaftet). Skalar-auf-Vektor-Promotion: explizit via Konstruktor. |
| 4.7 | **Target-Verfügbarkeits-Check** | `f32x8` auf SSE2-Only-Target → Compile-Fehler: `"f32x8 requires AVX; compile with --target-feature +avx2"`. Kein stiller Fallback. |
| 4.8 | **Register-Allokation** | `f32x4`-Variable liegt in einem XMM/YMM/NEON-Register. Keine Memory-Operation für einfache Berechnungen. |

#### Abnahmekriterien

- [ ] `var v: f32x4 = f32x4(1.0, 2.0, 3.0, 4.0)` allokiert XMM-Register (kein heap)
- [ ] `v + v` emittiert `addps` (x86-64) / `vaddq_f32` (ARM64) – keine Memory-Op dazwischen
- [ ] `v.x` emittiert Einzelkomponenten-Extraktion, kein Struct-Zugriff-Konflikt
- [ ] `f32x8` auf SSE2-Only-Target → Compile-Fehler mit klarer Meldung
- [ ] `f32x4(1.0)` → alle vier Komponenten = 1.0 (Broadcast)

#### Aufwand

**4–6 Wochen**

#### Abhängigkeiten

WP1 (x86-64 SIMD-Primitives), WP3 (ARM NEON)

---

### WP5: Vektor-Standardbibliothek

#### Grund & Hintergrund

Native Vektortypen (WP4) brauchen ein Ökosystem aus mathematischen Funktionen und Konstanten. Zwei Designentscheidungen sind **vor der Implementierung verbindlich zu treffen**:

**1. `float3` vs. `f32x4`:** `type float3 = f32x4` ist korrekt für Speicherlayout, aber die Semantik muss explizit sein. Funktionen wie `cross` und `length` dürfen die w-Komponente nicht einbeziehen. `cross(a, b)` setzt `w = 0.0` explizit im Ergebnis. `length(v)` berechnet `sqrt(v.x*v.x + v.y*v.y + v.z*v.z)`. Das muss in jeder Funktion dokumentiert sein, die `float3` entgegennimmt.

**2. Matrix-Speicherlayout:** `Matrix4x4` wird **column-major** gespeichert (Spaltenvektor-Konvention). Begründung: SPIR-V und Vulkan (WP7) verwenden standardmäßig column-major; GLSL tut es ebenfalls. Eine spätere Anbindung an GPU-Shader würde bei row-major eine Transposition bei jedem Transfer erfordern. Explizite Dokumentation: `mat[col][row]`, **nicht** `mat[row][col]`.

#### Ziel

Eine vollständige Vektor-Bibliothek analog zu GLM mit klar dokumentierter `float3`-Semantik und column-major-Matrizen.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `std/vectortypes.lyx` | **Neu** | Typaliase + Konstanten |
| `std/vector_math.lyx` | **Neu** | Mathematische Funktionen |
| `std/vector_matrix.lyx` | **Neu** | Matrix-Typen und -Operationen (column-major) |
| `std/vector_geometry.lyx` | **Neu** | Geometrie (Quaternion, Rotation) |
| `examples/graphics/vector_demo.lyx` | **Neu** | Demo-Beispiel |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 5.1 | **Typaliase** | `type float2 = f32x2; type float3 = f32x4; type float4 = f32x4; type int4 = i32x4;`. Dokumentation: "float3 uses a 4-component register; w is always 0.0." |
| 5.2 | **Konstanten** | `VEC3_ZERO`, `VEC3_ONE`, `VEC3_X`, `VEC3_Y`, `VEC3_Z` (alle als `float3` mit w=0). |
| 5.3 | **`dot`, `length`, `normalize`** | Arbeiten auf den ersten 3 Komponenten von `float3`. `dot` → `dpps xmm0, xmm1, 0x7F` (SSE4.1) oder manuell (SSE2). `length(v) = sqrt(dot(v,v))`. `normalize(v) = v / length(v)`. |
| 5.4 | **`cross`** | `cross(a, b) -> float3`: Standardformel. Ergebnis hat `w = 0.0` (explizit gesetzt). Implementierung via Shuffle + Sub. |
| 5.5 | **`lerp`, `clamp`, `min`, `max`** | Komponentenweise auf `f32x4`. `lerp(a, b, t) = a + t*(b-a)`. |
| 5.6 | **`Matrix4x4`** | 4 × `f32x4`-Spaltenvektoren. `identity()`, `transpose()`, `multiply(a, b)`. `mat * vec` = Matrix-Vektor-Multiplikation. Explizite Dokumentation: column-major. |
| 5.7 | **`inverse()`** | Gauss-Jordan-Eliminierung mit SIMD-Operationen. Gibt `Option<Matrix4x4>` zurück (Singularitäts-Check). |
| 5.8 | **Quaternion** | `Quaternion = f32x4 (x, y, z, w)`. `multiply`, `rotate(v: float3)`, `slerp`. |
| 5.9 | **ParallelArray-Integration** | `to_vector_list(data: ParallelArray<f32>) -> List<f32x4>` für batch-weise Verarbeitung. |

#### Abnahmekriterien

- [ ] `dot(float3(1,0,0,0), float3(0,1,0,0)) == 0.0` (w-Komponente ignoriert)
- [ ] `cross(float3(1,0,0,0), float3(0,1,0,0))` → `float3(0,0,1,0)` mit w=0.0
- [ ] `length(float3(3,4,0,0))` → `5.0` (korrekte 3D-Länge)
- [ ] `Matrix4x4.identity() * v == v` für beliebiges `v: float4`
- [ ] Column-major: `mat.col[0]` ist die erste Spalte (nicht erste Zeile)
- [ ] Alle Funktionen sind vektorisiert – kein `for`-Loop über Komponenten

#### Aufwand

**3–4 Wochen**

#### Abhängigkeiten

WP4 (native Vektortypen)

---

### WP6: Memory Spaces im Typsystem

#### Grund & Hintergrund

GPUs haben ein heterogenes Speichermodell. Ohne Typsystem-Unterstützung schleichen sich fatale Fehler ein: CPU liest aus VRAM → Absturz. Das ist Lyx' potenziell stärkstes Alleinstellungsmerkmal im GPU-Bereich.

**`@unified` Memory-Semantik (präzisiert gegenüber v1):**

`@unified` garantiert **Korrektheit** – der Speicher ist von CPU und GPU zugreifbar. Die Performance-Charakteristik ist **plattformabhängig**:

| Plattform | `@unified`-Implementierung | Performance |
|-----------|---------------------------|-------------|
| NVIDIA Discrete (PCIe) | CUDA Managed Memory, Page-Migration | Langsam bei abwechselndem CPU/GPU-Zugriff |
| AMD Discrete (PCIe) | HIP Managed Memory | Analog NVIDIA |
| Intel/AMD Integrated GPU | Gemeinsamer physischer Speicher | Zero-Copy, schnell |
| Apple Silicon | Metal Managed Resources (LPDDR5) | Zero-Copy, schnell |

Für Performance-kritischen Code muss explizit `@host` + `@device` + `copy()` verwendet werden. `@unified` ist das sichere, portable Default – mit dokumentiertem Performance-Vorbehalt.

#### Ziel

Typsystem-Attribute `@host`, `@device`, `@unified`, die illegale Speicherzugriffe zur Compile-Zeit verhindern.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `ebnf.md` | **Erweiterung** | Attribute `@device`, `@unified` |
| `src/lexer.lyx` | **Erweiterung** | Tokens für Memory-Space-Attribute |
| `src/parser.lyx` | **Erweiterung** | Parsen der Attribute auf Typ- und Variablenebene |
| `src/sema.lyx` | **Erweiterung** | Zugriffsregeln |
| `src/ir.lyx` | **Erweiterung** | Memory-Space-Annotationen im IR |
| `std/memory_spaces.lyx` | **Neu** | Runtime-API für Allokation und Transfer |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 6.1 | **Memory-Space-Attribute definieren** | `@host` (Default, CPU-RAM), `@device` (VRAM, nur GPU-seitig zugreifbar), `@unified` (beide Seiten, Performance plattformabhängig). |
| 6.2 | **Typsystem-Integration** | `@device f32x4` ist ein **anderer Typ** als `f32x4` (= `@host f32x4`). Zuweisung ohne explizites `copy()` → Compile-Fehler. |
| 6.3 | **Zugriffsregeln** | CPU-Funktionen: `@host` und `@unified` erlaubt. `@device` → Fehler `LYX-M0301`. GPU-Kernel (WP9): `@device` und `@unified` erlaubt. `@host` → Fehler. |
| 6.4 | **Pointer-zu-Pointer-Regeln** | `@device`-Pointer darf nicht in Host-Datenstrukturen gespeichert werden (`var list: List<@device f32>` auf dem Host → Fehler `LYX-M0302`). |
| 6.5 | **Transfer-API** | `copy(dst: @device T*, src: @host T*, count: usize)` – generiert PCIe-Transfer. `copy(dst: @host T*, src: @device T*, count: usize)` – Rückrichtung. `copy(dst: @device T*, src: @device T*, count: usize)` – GPU-seitig. |
| 6.6 | **`@unified`-Performance-Hint** | `@unified(migrate)` für Managed-Memory (CUDA-Stil) und `@unified(shared)` für Zero-Copy-Plattformen. Optional – ohne Hint wählt die Runtime das Plattform-Beste. |
| 6.7 | **Fehlermeldungen** | `LYX-M0301`: CPU-Zugriff auf `@device`-Speicher. `LYX-M0302`: `@device`-Pointer in Host-Datenstruktur. `LYX-M0303`: fehlender `copy()`-Aufruf. |
| 6.8 | **AST-JSON-Erweiterung** | Memory-Space-Informationen im AST-JSON abbilden (für KI-Codegenerierung). |

#### Abnahmekriterien

- [ ] `var a: @device f32` auf Host deklarieren → Schreiben gibt Compile-Fehler `LYX-M0301`
- [ ] `copy(device_ptr, host_ptr, 1024)` compiliert, generiert Transfer
- [ ] `@unified f32` von CPU und GPU lesbar (kein Compile-Fehler auf beiden Seiten)
- [ ] `var list: List<@device f32>` auf Host → Fehler `LYX-M0302`
- [ ] Memory-Spaces in AST-JSON sichtbar

#### Aufwand

**4–6 Wochen**

#### Abhängigkeiten

WP4 (Vektortypen sind der primäre Nutzer von Memory Spaces)

---

### WP7: GPU-Backend-Entscheidung & SPIR-V-Emitter

#### Grund & Hintergrund

Der grösste Schritt: Lyx muss GPU-Code erzeugen. Dafür gibt es zwei fundamentale Wege.

#### Architektur-Entscheidung: Eigener SPIR-V-Emitter vs. LLVM

Diese Entscheidung muss **vor Beginn von WP7** final getroffen werden. Alle nachfolgenden WPs hängen davon ab.

| Kriterium | Eigener SPIR-V-Emitter | LLVM als GPU-Backend |
|-----------|----------------------|---------------------|
| GPU-Abdeckung | Vulkan (SPIR-V) | SPIR-V (LLVM ≥ 15) + NVPTX (Nvidia) + AMDGCN (AMD ROCm) |
| ARM64-Synergien | Keine | LLVM ist auf ARM64 bereits de-facto Standard |
| Aufwand | Sehr hoch (SPIR-V: 1.000+ Instruktionen, Capabilities) | Mittel (LLVM-IR erzeugen statt SPIR-V) |
| Laufzeit-Dependency | Keine neue | LLVM muss vorhanden sein |
| Kontrolle | Vollständig | Eingeschränkt (LLVM-Versionen, IR-Stabilität) |
| Wartungsaufwand | Sehr hoch (SPIR-V-Spec-Änderungen) | Mittel (LLVM-Upgrade-Aufwand) |

**Empfehlung:** Falls Lyx bereits für andere Targets LLVM nutzt oder planen wird – LLVM wählen. Falls Lyx seine Zero-Dependency-Philosophie beibehält – eigener SPIR-V-Emitter für den Compute-Subset.

**Scope der initialen SPIR-V-Implementierung:** Nicht das gesamte SPIR-V-Universum, sondern ein klar definierter Compute-Subset:

| SPIR-V-Capability | Benötigt für | Priorität |
|-------------------|-------------|-----------|
| `Shader` | Basis (alle Compute-Shader) | Pflicht |
| `Addresses` | Pointer-Arithmetik in Buffern | Pflicht |
| `Float64` | `f64x2`, `f64x4` | Hoch |
| `Int16` | `i16x8` | Mittel |
| `Int8` + `StorageBuffer8BitAccess` | `i8x16`, `u8x16` | Mittel |
| `StorageBuffer16BitAccess` | `i16`-Buffer | Niedrig |
| `Vector16` | 16-Element-Vektoren | Deferred |

**MLIR als Alternative:** MLIR (Multi-Level Intermediate Representation) hat sich als Standard-Infrastruktur für GPU-Compilation etabliert (Triton, JAX-XLA, TF). Die MLIR-Dialekte `linalg`, `gpu`, `spirv` könnten den WP7/WP8/WP9-Stack ersetzen. Evaluierung vor WP7-Start empfohlen, da MLIR den eigenen IR-Lowering-Aufwand erheblich reduzieren kann.

#### Ziel

Ein GPU-Compute-Backend (Eigenbau SPIR-V oder LLVM), das Lyx-IR in GPU-Code übersetzt.

#### Dateien (bei eigener SPIR-V-Implementierung)

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `src/backend/spirv/spirv_spec.lyx` | **Neu** | SPIR-V-Header, Capabilities-Tabelle |
| `src/backend/spirv/emit_spirv.lyx` | **Neu** | SPIR-V-Instruktionen emittieren |
| `src/backend/spirv/spirv_types.lyx` | **Neu** | Typ-System (OpTypeFloat, OpTypeVector etc.) |
| `src/backend/spirv/spirv_decorations.lyx` | **Neu** | Decorations (BuiltIn, Location, DescriptorSet) |
| `src/codegen_gpu.lyx` | **Neu** | GPU-Codegen-Dispatcher |
| `src/ir_lower_gpu.lyx` | **Neu** | Lyx-IR → GPU-IR |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 7.0 | **Architektur-Entscheidung treffen** | LLVM vs. eigener Emitter evaluieren. Entscheidungskriterien: Lyx' bestehende LLVM-Nutzung, Team-Kapazität, Langzeit-Wartungsaufwand. Ergebnis dokumentieren. |
| 7.1 | **SPIR-V-Typen abbilden** | `OpTypeFloat`, `OpTypeVector`, `OpTypeArray`, `OpTypePointer` (mit StorageClass), `OpTypeFunction`. |
| 7.2 | **IR-Lowering für GPU** | Lyx-IR → SPIR-V Structured CFG. Vektortypen → `OpTypeVector`. Memory Spaces → `StorageClass` (`StorageBuffer`, `Private`, `Workgroup`). |
| 7.3 | **Compute-Shader-Einstiegspunkt** | `OpEntryPoint GLCompute`. `OpExecutionMode LocalSize`. `@kernel`-Attribut für Lyx-Funktionen. |
| 7.4 | **GPU-Builtins** | `gl_GlobalInvocationID`, `gl_LocalInvocationID`, `gl_WorkGroupSize` als Compiler-Builtins mit SPIR-V-`BuiltIn`-Decoration. |
| 7.5 | **Capability-Subset implementieren** | Nur die Capabilities aus der Tabelle oben (Pflicht zuerst). Jede Capability wird einzeln aktiviert und getestet. |
| 7.6 | **SPIR-V-Binary-Ausgabe** | `.spv`-Datei. `spirv-val` (Vulkan SDK) muss das Ergebnis ohne Fehler validieren. |

#### Abnahmekriterien

- [ ] Architektur-Entscheidungsdokument (LLVM vs. eigener Emitter) liegt vor WP7-Start vor
- [ ] `@kernel fn add(@device f32x4*, @device f32x4*, @device f32x4*)` → gültiges SPIR-V
- [ ] SPIR-V-Binary wird von `spirv-val` ohne Fehler validiert
- [ ] `OpEntryPoint GLCompute` mit korrekten `DescriptorSet`-Bindings vorhanden
- [ ] `f32x4` → `OpTypeVector %float 4`
- [ ] `@device` → `StorageClass StorageBuffer`

#### Aufwand

**6–12 Monate** (stark abhängig von LLVM- vs. Eigenbau-Entscheidung)

#### Abhängigkeiten

WP4 (Vektortypen), WP6 (Memory Spaces)

---

### WP8: GPU-Laufzeit & Device-Management

#### Grund & Hintergrund

Ein GPU-Compute-Shader nützt nichts ohne Laufzeit-Infrastruktur: Device-Erkennung, Speicher-Allokation, Dispatch, Synchronisation.

**CI-Test-Strategie ohne echte GPU:** Vulkan `swiftshader` (Software-Rasterizer) und `llvmpipe` können Compute-Shader auf der CPU ausführen. Das reicht für Korrektheitstests. Performance-Benchmarks erfordern echte Hardware und werden nicht im Standard-CI ausgeführt. Konkret:
- Standard-CI: `swiftshader` via `VK_ICD_FILENAMES`
- Nightly-Performance-CI: dedizierter Build-Agent mit GPU (Hardware-Anforderung für WP8+)

#### Ziel

Eine plattformunabhängige GPU-Laufzeit-Bibliothek (`std/gpu/`).

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `std/gpu/device.lyx` | **Neu** | GPU-Device-Erkennung |
| `std/gpu/memory.lyx` | **Neu** | GPU-Speicher-Allokation |
| `std/gpu/compute.lyx` | **Neu** | Compute-Pipeline |
| `std/gpu/buffer.lyx` | **Neu** | Buffer-Typen |
| `std/gpu/sync.lyx` | **Neu** | Fences, Semaphoren, Barriers |
| `examples/gpu/compute_add.lyx` | **Neu** | End-to-End-Beispiel |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 8.1 | **Device-Erkennung** | `GPUDevice.enumerate() -> List<GPUDevice>`. Name, VRAM, Compute-Units, supported Capabilities. |
| 8.2 | **GPU-Kontext** | `GPUContext` – kapselt Device + Command Queues. `GPUContext.create(device)`. |
| 8.3 | **Speicher-Allokation** | `allocate_device<T>(count) -> @device T*`. `allocate_unified<T>(count, hint?) -> @unified T*`. `free_device(ptr)`. |
| 8.4 | **Transfer-API** | `copy_host_to_device`, `copy_device_to_host`, `copy_device_to_device`. Asynchrone Varianten mit `Fence`. |
| 8.5 | **Compute-Pipeline** | `ComputePipeline.create(ctx, spirv_bytes)`. `pipeline.dispatch(x, y, z)`. |
| 8.6 | **Descriptor-Set-Management** | `DescriptorSet.bind(binding: u32, buffer: GPUBuffer)`. Falscher Typ → Compile-Fehler (typsicher). |
| 8.7 | **Synchronisation** | `queue.submit(cmdbuf)`, `queue.wait_idle()`, `fence.wait(timeout_ns)`. |
| 8.8 | **CI-Setup** | `Makefile`-Target `test-gpu-swiftshader`: setzt `VK_ICD_FILENAMES` auf `swiftshader_icd.json` und führt GPU-Tests aus. Kein echter GPU required. |
| 8.9 | **Beispiel** | `examples/gpu/compute_add.lyx` – Vektor-Addition mit vollständigem Pipeline-Setup. |

#### Abnahmekriterien

- [ ] `GPUDevice.enumerate()` gibt Ergebnis zurück (auf Swiftshader-CI: mind. 1 Software-Device)
- [ ] `compute_add.lyx` addiert zwei Vektoren korrekt (verifiziert via `copy_device_to_host`)
- [ ] Roundtrip `copy_host_to_device` + `copy_device_to_host` ist verlustfrei
- [ ] Alle Speicher-Allokationen werden bei `free_device` korrekt freigegeben
- [ ] CI-Tests laufen auf Swiftshader ohne echte GPU

#### Aufwand

**4–6 Monate**

#### Abhängigkeiten

WP7 (SPIR-V-Backend), WP6 (Memory Spaces)

---

### WP9: Single-Source Heterogene Compilation + `gpu_parallel_for`

#### Grund & Hintergrund

Das ursprüngliche Dokument sah Single-Source als Kernfeature. Dieser WP ist das **Fernziel**.

**Realistische Einschätzung der Komplexität:** `gpu_parallel_for` sieht syntaktisch einfach aus, ist aber compilertechnisch außerordentlich komplex:

```
gpu_parallel_for(0..N) |idx| {
    data[idx] = data[idx] * 2.0;
}
```

Der Compiler muss leisten:
1. **Escape-Analyse:** Welche Variablen aus dem umgebenden Scope berührt der Kernel? (`data`)
2. **Memory-Space-Verifikation:** Sind alle captures `@device` oder `@unified`? (zur Compile-Zeit)
3. **Descriptor-Set-Synthese:** Aus dem Capture-Set werden automatisch DescriptorSet-Bindings generiert
4. **Workgroup-Optimierung:** Device-abhängige Workgroup-Grösse ermitteln
5. **Host-Wrapper-Synthese:** CPU-seitiger Dispatch-Code wird automatisch generiert

Das ist konzeptuell identisch mit dem, was Numba, Triton und JAX-XLA tun – und diese Projekte waren jeweils mehrjährige Vorhaben mit dedizierten Teams. **`gpu_parallel_for` sollte erst nach mehreren Jahren stabiler WP7/WP8-Erfahrung angegangen werden.**

**Empfehlung für den Start:** `@kernel fn` (explizite Kernel-Deklaration) ist die primäre API. `gpu_parallel_for` ist **syntaktischer Zucker** darüber und wird *nach* vollständiger `@kernel`-Stabilisierung hinzugefügt.

#### Ziel

Single-Source-Kompilierung: `@kernel fn` wird automatisch als GPU-Compute-Shader compiliert. `gpu_parallel_for` als spätere High-Level-Abstraktion.

#### Dateien

| Datei | Status | Beschreibung |
|-------|--------|--------------|
| `ebnf.md` | **Erweiterung** | `@kernel`-Attribut, `gpu_parallel_for`-Syntax |
| `src/parser.lyx` | **Erweiterung** | `@kernel fn` und `gpu_parallel_for` |
| `src/sema.lyx` | **Erweiterung** | Kernel-Validierung: nur GPU-erlaubte Typen/Aufrufe |
| `src/codegen_gpu.lyx` | **Erweiterung** | Automatische GPU-Compilierung + Host-Wrapper |
| `src/escape_analysis.lyx` | **Neu** | Closure-Capture-Analyse für `gpu_parallel_for` |
| `std/gpu/parallel.lyx` | **Neu** | `gpu_parallel_for`-Laufzeit |

#### Aufgaben

| # | Aufgabe | Beschreibung |
|---|---------|--------------|
| 9.1 | **`@kernel`-Attribut** | `@kernel fn add(a: @device f32x4*, b: @device f32x4*, out: @device f32x4*)` – Compiler generiert SPIR-V-Kernel + CPU-Wrapper in einem Durchlauf. |
| 9.2 | **`@kernel`-Validierung** | Nur erlaubt: GPU-Typen, Vektoroperationen, `@device`/`@unified`-Zugriffe. Verboten: System-Calls, Datei-I/O, dynamische Allokation, Rekursion. Alles andere → Compile-Fehler. |
| 9.3 | **Host-Wrapper-Synthese** | Aus `@kernel fn foo(a: @device f32x4*)` generiert der Compiler automatisch `fn foo_dispatch(ctx: GPUContext, a: @device f32x4*, workgroups: u32)`. |
| 9.4 | **Escape-Analyse für `gpu_parallel_for`** | Bestimmt welche Variablen aus dem Closure-Scope im Kernel benötigt werden. Nur nach vollständiger `@kernel`-Stabilisierung. |
| 9.5 | **`gpu_parallel_for`-Lowering** | Schleife → `@kernel fn __auto_kernel` + `dispatch(N / workgroup_size)`. Descriptor-Set-Bindings werden aus dem Escape-Set generiert. |
| 9.6 | **Workgroup-Optimierung** | Compiler wählt Workgroup-Grösse via `GPUDevice.preferred_workgroup_size()` oder explizites `@workgroup_size(256)`. |
| 9.7 | **Fehlerbehandlung** | GPU-Fehler (Device Lost, OOM, Kernel Hang) → `Result<(), GPUError>`. Kein panic. |
| 9.8 | **CPU-Fallback-Warnung** | `gpu_parallel_for` ohne verfügbare GPU → CPU-Ausführung mit Compiler-Warnung. |
| 9.9 | **Beispiele** | `examples/gpu/saxpy.lyx` (SAXPY), `examples/gpu/matrix_mul.lyx` (Matrixmultiplikation). |

#### Abnahmekriterien

- [ ] `@kernel fn` compiliert zu CPU-Wrapper + SPIR-V in einem Compiler-Durchlauf
- [ ] `@kernel fn` mit Datei-I/O → Compile-Fehler
- [ ] `gpu_parallel_for(0..N) |i| { ... }` compiliert und dispatcht korrekt
- [ ] SAXPY: ≥ 10× Beschleunigung vs. CPU bei N ≥ 1 Mio. (auf echter GPU)
- [ ] CPU-Fallback-Warnung bei fehlender GPU

#### Aufwand

**`@kernel fn` (Aufgaben 9.1–9.3):** 3–4 Monate  
**`gpu_parallel_for` (Aufgaben 9.4–9.9):** 6+ Monate, erst nach WP7/WP8-Stabilisierung

#### Abhängigkeiten

WP7 (SPIR-V), WP8 (GPU-Laufzeit), WP4 (Vektortypen), WP6 (Memory Spaces)

---

## 4. Abhängigkeitsgraph

```
WP1 (SIMD x86-64) ──┐
                     ├── WP2 (CPU Feature Detection)
                     └── WP3 (ARM NEON)
                              │
                    WP1 + WP3 ▼
                         WP4 (Native Vektortypen)
                              │
                    ┌─────────┴─────────┐
                    ▼                   ▼
              WP5 (Vektor-Stdlib)  WP6 (Memory Spaces)
                    │                   │
                    └────────┬──────────┘
                             ▼
                       WP7 (GPU-Backend)
                             │
                    ┌────────┴─────────┐
                    ▼                  ▼
              WP8 (GPU-Laufzeit)      │
                    │                 │
                    └────────┬────────┘
                             ▼
                       WP9 (Single-Source)
```

**Parallelisierbar:**
- WP1 + WP2 können parallel entwickelt werden
- WP3 beginnt nach WP1
- WP5 + WP6 können parallel zu WP4 entwickelt werden (sobald WP4-API stabil)
- WP8 kann beginnen sobald WP7 eine erste stabile API bietet

---

## 5. Zeitplan (Schätzung)

| WP | Feature | Aufwand | Start (relativ) |
|----|---------|---------|-----------------|
| 1 | SIMD-Codegen x86-64 | 2–3 Wo | Monat 1 |
| 2 | CPU Feature Detection | 2–3 Wo | Monat 1 (parallel zu WP1) |
| 3 | ARM NEON | 3–4 Wo | Monat 2 (nach WP1) |
| 4 | Native Vektortypen | 4–6 Wo | Monat 3 (nach WP1+WP3) |
| 5 | Vektor-Stdlib | 3–4 Wo | Monat 4 (parallel zu WP6) |
| 6 | Memory Spaces | 4–6 Wo | Monat 4 (parallel zu WP5) |
| 7 | GPU-Backend (nach Architektur-Entscheidung) | 6–12 Mo | Monat 6 |
| 8 | GPU-Laufzeit & Device-Mgmt | 4–6 Mo | nach WP7-Stabilisierung |
| 9a | `@kernel fn` | 3–4 Mo | nach WP7+WP8 |
| 9b | `gpu_parallel_for` | 6+ Mo | nach 9a-Stabilisierung |

**Kritischer Pfad:** WP1 → WP3 → WP4 → WP7 → WP8 → WP9  
**Gesamtdauer WP1–WP6:** **4–5 Monate** (1–2 Entwickler)  
**Gesamtdauer WP1–WP9:** **2–3 Jahre** (1 Entwickler) / **12–18 Monate** (3 Entwickler)

---

## 6. Risiken & Annahmen

| Risiko | Wahrsch. | Impact | Maßnahme |
|--------|----------|--------|----------|
| **SPIR-V-Eigenbau zu komplex** | Mittel | Sehr hoch | LLVM-Alternative vor WP7-Start entscheiden. MLIR evaluieren. Architekturentscheid-Dokument ist WP7-Vorbedingung. |
| **Vektortypen passen nicht ins Typsystem** | Mittel | Hoch | Vektortypen als Builtins (wie `bool`/`pchar`), keine generischen Typen. Operator-Overloading muss für Builtins explizit gehärtet werden. |
| **AVX2-Binary auf SSE2-CPU crasht (SIGILL)** | Hoch (ohne WP2) | Hoch | WP2 löst das. WP1-Ergebnisse dürfen nicht ohne WP2 ausgeliefert werden. |
| **ARM NEON unvollständig (Cortex-M / RISC-V)** | Hoch | Niedrig | Explizit out-of-scope dokumentiert. Scalar-Fallback mit Compiler-Warnung. Nicht als Bug behandeln. |
| **`gpu_parallel_for`-Closure-Capture ist Research-Level** | Sehr hoch | Hoch | `@kernel fn` als primäre API zuerst stabilisieren. `gpu_parallel_for` erst als Folge-WP nach 1+ Jahr Erfahrung mit `@kernel`. |
| **Keine GPU-Hardware für CI** | Hoch | Mittel | Swiftshader/llvmpipe für Korrektheitstests. Dedizierter Nightly-Build-Agent mit GPU für Performance-Tests (Hardware-Anforderung für WP8+, explizit planen). |
| **`float3 = f32x4` Semantik-Fehler** | Mittel | Mittel | Alle float3-Funktionen haben expliziten Kommentar und Test: w-Komponente muss 0.0 sein. Sema-Lint-Rule: `float3`-Variablen mit w≠0 → Warnung. |
| **MLIR als verpasste Alternative** | Mittel | Mittel | Vor WP7-Start: 2-Wochen-MLIR-Evaluierung. Ergebnis in Architekturentscheid-Dokument festhalten. |
| **RISC-V RVV fundamentale Inkompatibilität** | Hoch (trifft ein) | Niedrig | RVV hat variable Vektoriängen (kein fixes f32x4). Out-of-scope für alle Meilensteine. RISC-V ParallelArray bleibt skalar. Dokumentiert. |

---

## 7. Abgrenzung zu anderen Dokumenten

### 7.1 Bezug zu `ki-lang.md`

- **Memory Spaces (WP6)** liefern strukturierte Fehler (`LYX-M0301`) statt Laufzeitabstürzen
- **Vektortypen (WP4)** sind deterministisch und eindeutig – ideal für KI-Codegenerierung
- **AST-JSON** bildet `@kernel`-Attribute und Memory-Space-Informationen ab

### 7.2 Bezug zu `filesystem-layer.md`

Keine direkte Abhängigkeit. Gemeinsame Infrastruktur: `--error-json` für GPU-Compiler-Fehler.

### 7.3 MLIR-Bezug

[Multi-Level IR](https://mlir.llvm.org) hat sich als Standard-Stack für GPU-Compilation etabliert (Triton, JAX-XLA, TF nutzen es). Die MLIR-Dialekte `linalg`, `gpu`, `spirv` könnten den WP7/WP9-IR-Lowering-Aufwand drastisch reduzieren. Evaluierung ist **Pflicht vor WP7-Start** – entweder als Grundlage übernehmen oder bewusst ablehnen (mit Begründung).

---

## 8. Messbarkeit & Erfolgskriterien

### Quantitative Metriken

| Metrik | WP | Zielwert | Messung |
|--------|----|----------|---------|
| SIMD-Beschleunigung x86-64 | 1 | ≥ 2× bei 256 f32 vs. skalar | Benchmark |
| SIMD-Beschleunigung ARM64 | 3 | ≥ 2× bei 256 f32 vs. skalar | Benchmark auf Apple M-Series |
| AVX2-auf-SSE2-Absturz | 2 | 0 SIGILL (Dispatch-Fallback) | Test auf SSE2-VM |
| Vektortyp-Coverage | 4 | 7 Typen (f32x4, f64x2, i32x4, i16x8, i8x16, u8x16, f32x2) | Compiler-Test |
| `float3.w` nach Operationen | 5 | immer 0.0 | Automatisierte Invarianz-Tests |
| SPIR-V-Validierung | 7 | 100 % via `spirv-val` | CI nach jedem Codegen-Commit |
| GPU-Beschleunigung | 9 | ≥ 10× CPU bei N ≥ 1 Mio. | SAXPY-Benchmark auf echter GPU |

### Qualitative Erfolgskriterien

- `ParallelArray<f32>` auf x86-64 **und** ARM64 emittiert nachweislich SIMD-Instruktionen
- Ein Lyx-Entwickler kann eine `@kernel fn` schreiben ohne GPU-Internals zu kennen
- Der Compiler fängt **alle** `@device`-Zugriffsfehler zur Compile-Zeit ab
- Verteilbare Binaries mit AVX2-Optimierung crashen nicht auf SSE2-CPUs (WP2)

---

## 9. Zusammenfassung

Das ursprüngliche Dokument hatte eine ambitionierte Vision. Dieser Fahrplan operationalisiert sie in **neun Arbeitspaketen in drei Meilensteinen** – und ergänzt zwei kritische Lücken aus v1: plattformbreites SIMD (WP2, WP3) und eine ehrliche Einschätzung der `gpu_parallel_for`-Komplexität (WP9).

### Die vier strategischen Empfehlungen

1. **Sofort: WP1 + WP2 parallel** – SIMD-Codegen und CPU-Feature-Detection gehören zusammen. WP1 ohne WP2 darf nicht ausgeliefert werden (SIGILL-Risiko). Aufwand: **4–6 Wochen**.

2. **Danach: WP3 + WP4** – ARM NEON und native Vektortypen. Erst wenn SIMD auf x86-64 und ARM64 stabil funktioniert, macht WP4 Sinn. Aufwand: **2–3 Monate**.

3. **Parallel zu WP4: WP5 + WP6** – Vektor-Stdlib und Memory Spaces. WP6 ist Lyx' potenziell stärkstes Alleinstellungsmerkmal im GPU-Bereich. Aufwand: **2–3 Monate parallel**.

4. **Langfristig: WP7-Entscheidung zuerst** – Vor WP7-Beginn: 2-Wochen-Evaluierung LLVM vs. SPIR-V-Eigenbau vs. MLIR. Das Ergebnis bestimmt den gesamten weiteren Stack. `gpu_parallel_for` (WP9b) kommt **nach** 1+ Jahr stabilem `@kernel fn`-Betrieb.

---

> **Fazit:** GPU-Support in Lyx ist kein "Alles oder Nichts". Meilenstein 1 (WP1–WP3) liefert  
> messbare SIMD-Performance auf allen CPU-Targets in wenigen Monaten. Meilenstein 2 (WP4–WP6)  
> etabliert die Sprachgrundlage für GPU-Code. Meilenstein 3 (WP7–WP9) ist ein  
> mehrjähriges Vorhaben – und beginnt mit einer Architekturentscheidung, nicht mit Code.
