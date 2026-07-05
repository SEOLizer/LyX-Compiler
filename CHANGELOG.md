# Changelog - Lyx Compiler

## Version 1.0.8C (Juli 2026)

Operator-Overloading komplettiert (Stufen 2b, 2c, 3) + `!=`-Fallback. Basis V1.0.8B.

### Compiler
- **Verkettete Ausdrücke** (2b): `a + b + c`, `(a+b)*d` — `cg_exprClassName` löst
  die statische Klasse auch eines Arithmetik-Overloads auf (Result = Links-Klasse).
- **Voller Operator-Satz** (2b): `!=` Ne, `<` Lt, `<=` Le, `>` Gt, `>=` Ge; Index
  `a[i]` → `a.Get(i)` (neuer Zweig vor dem normalen CGN_INDEX-Pfad).
- **Call-Ergebnis-Operanden** (2c): `f() + g()` wenn eine freie Funktion einen
  class-Rückgabetyp hat (neue `fnRetList`-Registry: funcName → Rückgabetyp-Name,
  Klasse zur Lookup-Zeit via `cg_findClass`).
- **`!=`-Fallback**: eine Klasse mit nur `Eq` bekommt `!=` gratis (`a.Eq(b)` +
  logisches NOT, wenn kein `Ne` definiert).
- Trigger bleibt eng (nur class-Operanden) → int/f64/pchar-Binops, Vergleiche und
  normale Array/pchar-Indizierung unverändert.

### Standardbibliothek / Doku
- **`std.strtype.String`**: Operator-Methoden `Eq`/`Ne`/`Compare`/`Lt`/`Le`/`Gt`/
  `Ge`/`Get` ergänzt → String-Operatoren arbeiten **inhaltsbasiert** (vorher fiel
  `==` mangels `Eq` auf einen Pointer-Vergleich zurück).
- **`examples/basics/operator_overloading.lyx`**: Showcase (Vec-Klasse + String).
- **`ebnf.md` §15.3**: Semantik-Notiz zum Operator-Overloading (kein Grammatik-
  Zusatz — Overload-Resolution ist per §19 ohnehin außerhalb der EBNF).

Verifiziert je Stufe: Selbst-Host-Fixpunkt gen2==gen3; `make test` 20 PASS/0 FAIL.

## Version 1.0.8B (Juli 2026)

Operator-Overloading für User-Klassen (Stufe 2a). Basis V1.0.8A.

- **`a + b` → `a.Add(b)`** wenn der linke Operand ein Identifier mit class-Typ
  ist, dessen Klasse die Operator-Methode definiert. Generisch — jede Klasse
  mit passender Methode (String, Vec, BigInt …), kein String-Hardcode.
- Operator → Methode: `+` Add, `-` Sub, `*` Mul, `/` Div, `%` Mod, `==` Eq.
- Umsetzung im Codegen (x86): `cg_tryClassBinop` erkennt den class-Ident-Links-
  Operanden über `localTypes`, baut den mangled Namen `ClassName_Method`, prüft
  das Label und emittiert einen direkten Method-Call (Receiver→rdi/self,
  Arg→rsi, Ergebnis rax). Neuer Zweig im CGN_BINOP-Handler neben
  `pchar+pchar→StrConcat` und `parallel-Array→SIMD`. Trigger bewusst eng (nur
  Ident-Links-Operand) → int/f64/pchar-Binops unverändert.
- **Vertagt** (spätere Stufen): verkettete Ausdrücke `(a+b)+c` (Return-Typ-
  Inferenz), `!=`/`[]`/Vergleichs-Overloads, `Text`-Operatoren.

Verifiziert: `Vec{x,y}` mit Add — (1,2)+(10,20)=(11,22); `std.strtype.String`
"Hello, "+"World!" konkateniert (Länge 13, korrekte Bytes) + `c == c` → Eq;
int/f64/pchar-Binops unverändert; Selbst-Host-Fixpunkt gen2==gen3;
`make test` 20 PASS/0 FAIL.

## Version 1.0.8A (Juli 2026)

Vollständiger String- und Unicode-Stack. Basis V1.0.7D.

### String- und Text-Typen
- **`std.strtype.String`** — eigener, längentragender String-Wert als Klasse
  (mmap-basiert, libc-frei, embedded-NUL-sicher; Append/Substring/Equals/Add),
  Empfänger für das geplante Operator-Overloading (`a + b` → `a.Add(b)`).
- **`std.text.Text`** — UTF-8-Typ: validiert bei Konstruktion, codepoint-aware
  (`TextCodepointCount`/`At`, En-/Decode), Concat, Codepoint-Substring, Find/
  Contains, Trim, Replace, Split, ASCII-Case. Byte-Länge ≠ Codepoint-Zahl.

### Unicode (opt-in Units)
- **`std.unicode`** — Case-Folding (ASCII + Latin-1), Unicode-Whitespace-
  Klassifikation, Text-Level Upper/Lower, und **volle Normalisierung
  NFD/NFC/NFKD/NFKC**: kanonische + Kompatibilitäts-Dekomposition, Canonical-
  Ordering nach Combining-Class, Composition-mit-Blocking, Hangul algorithmisch
  (§3.12). `TextEqualsNormalized` (normalisierungs-insensitiver Vergleich).
- **`std.grapheme`** — UAX #29 erweiterte Grapheme-Cluster (`TextGraphemeCount`/
  `ByteOffset`/`At`): Regeln GB3–GB999 (Hangul, Extend/ZWJ, SpacingMark,
  Prepend, Emoji-ZWJ GB11, Regional-Indicator-Paare GB12/13).
- **`std.unicode_data` / `std.unicode_gbdata`** — aus UnicodeData.txt,
  GraphemeBreakProperty.txt und emoji-data.txt generierte Tabellen (2081
  kanonische + 5914 Kompatibilitäts-Dekompositionen, 968 Combining-Classes,
  961 Composition-Pairs, 1429 Grapheme-Break-Ranges, 451 Extended_Pictographic),
  sortiert + Binärsuche, Lazy-Init. Auf zwei Units gesplittet wegen lyxc-
  Größen-Grenze beim Kompilieren.

### Framework-Integration
- **`data.strbridge`** — String↔Text-Konversion, DataFrame-Utf8-Zelle ↔ Text,
  `DataFrameColumnAllValidUtf8` (UTF-8-Qualitätsprüfung) und
  `DataFrameNormalizeColumnNFC` → normalisierungs-insensitive Group-by/Join auf
  String-Spalten.

Verifiziert e2e (Latin/Greek/Cyrillic/CJK-compat/Hangul, Emoji-ZWJ/Flags,
Ligatur/Superscript/Fullwidth); Selbst-Host-Fixpunkt gen2==gen3.

## Version 1.0.7D (Juli 2026)

Rollout der Compound-Assignment-Operatoren in Standardbibliothek und Beispielen.
Basis V1.0.7C.

- **`std/`** — 3603 `x := x + y`-Muster auf `x += y` (bzw. `-= *= /= %=`)
  umgestellt (238 Units), rein mechanisch (Desugaring-äquivalent), Idempotenz-
  und Kompilier-verifiziert.
- **`examples/basics/`** — neues Showcase `compound_assign.lyx`; control_flow/
  variables/arrays modernisiert (inkl. `const`→`con`-Fix in variables.lyx).

## Version 1.0.7C (Juli 2026)

Rollout der Compound-Assignment-Operatoren in Compiler-Quelle und Daten-
Framework. Basis V1.0.7B.

- **Compiler-Quelle** (`src/`) auf `+=`/`-=` umgestellt und **Bootstrap-Seed
  neu verankert** (Seed kennt die neue Syntax).
- **`data/`-Framework**-Units auf die Compound-Operatoren umgestellt.

## Version 1.0.7B (Juli 2026)

Sprach-Feature: Compound-Assignment-Operatoren. Basis V1.0.7A.

- **`+= -= *= /= %=`** als Parser-Desugaring (`a += b` → `a := a + b`),
  backend-agnostisch. Neue Tokens im Lexer (`TK_PLUSEQ`…`TK_PERCENTEQ`),
  Desugaring nach dem `++`/`--`-Block im Parser, `CompoundAssignStmt` in
  `ebnf.md`. Fixpunkt gen2==gen3, 20 PASS.

## Version 1.0.7A (Juli 2026)

Standard-Daten-Framework: ein einheitliches, geschachteltes, spalten-
orientiertes Datenmodell (Arrow-inspiriert, Lyx-Eigenformat). Basis V1.0.6A.

### Schichten
- **L1 Kernel** (`data.kernel`) — DataType-Tags, wachsender Buffer, Null-Bitmap.
- **L2 Struktur** (`data.frame`) — Field/Column/DataFrame, typisierte Spalten
  Int64/Float64/Utf8, geschachtelte List- und Struct-Spalten (offset-basiert,
  grow-fest).
- **L3 Operationen** (`data.ops`) — Aggregate/Filter/Select/Slice, generischer
  und mehrspaltiger Sort (Merge-Sort), Group-by, Inner/Left/Right/Full-Join,
  Melt/Pivot, sowie **hash-basierte** Group-by/Join (int64 + Utf8, O(n),
  Open-Addressing/FNV-1a).

### IO / Formate
- **CSV** Reader (Typinferenz) + Writer; **JSON** Reader (flach + geschachtelt:
  Arrays→List-, Objekte→Struct-Spalten, mixed-type) + Writer; **natives
  Binärformat** (schnelles Save/Load, nested-aware); `DataFramePrint`
  (ausgerichtete ASCII-Tabelle).
- Robustheit (P0): Buffer-Grow + OOB/OOM-Guards.
- Codegen-Fix: `x as f64` wird als f64-Ausdruck behandelt (Integer-Division-Bug
  bei Doppel-Cast).

## Version 1.0.6A (Juli 2026)

WSP-07: `extern "asm"` externe Daten-Symbole + relocatable Objekt-Ausgabe (ET_REL).
Basis V1.0.5A.

### extern "asm" (WSP-07)
- **Syntax**: `extern "asm" name: Type;` — deklariert ein externes Daten-Symbol
  (neuer AST-Knoten `NK_EXTERN_DATA`). Der Bezeichner liefert an jeder Nutzung die
  ADRESSE des Symbols. Sema registriert es als adress-typisierte Variable ohne
  Initializer; IDENT-Auflösung + Typecheck laufen normal.
- **Auflösung zur Link-Zeit** durch `ld` (z.B. Linker-Skript-Symbole
  `__kernel_start`/`__kernel_end`), nicht durch einen Runtime-Loader.
- **Neuer Ausgabemodus `--emit=obj` (bzw. `-c`)**: relocatable ELF-Objekt (ET_REL)
  statt Executable (x86_64). Eine Section `.ltext` = code||data (interne Refs sind
  RIP-relativ → reloc-invariant). Erzeugt `.symtab`/`.strtab`/`.rela.text`:
  - `R_X86_64_64` gegen das `.ltext`-Section-Symbol für interne absolute Referenzen
    (Klassen-VMTs/Methoden-Zeiger, aus dem bestehenden baseReloc-Set).
  - `R_X86_64_PC32` gegen ein `UNDEF`-Symbol je `extern "asm"`-Nutzung.
  - Globales `_start`-Symbol als Entry (`ld -T script.ld obj.o stub.o`).
- **Fail-closed**: `extern "asm"` ohne `--emit=obj` ist ein Compile-Fehler (kein
  Linker → nicht auflösbar), kein stilles Falschergebnis.
- **Grammatik**: `ExternDataDecl` in `ebnf.md` ergänzt.
- Verifiziert: e2e mit `ld` gegen Assembly-Stub (Symbol-Byte 42 → Exit 42);
  Klassen-Programm mit virtueller Dispatch (R_X86_64_64) + extern (R_X86_64_PC32)
  → Exit 49; `readelf` bestätigt ET_REL/UNDEF-Symbol/Relocs; Selbst-Host-Fixpunkt
  gen2==gen3; `make test` 20 PASS/0 FAIL.

## Version 1.0.5A (Juli 2026)

Inline-Assembly `asm { }` (WSP-05) auf alle funktionalen Backends erweitert — jetzt
architektur-spezifisch statt nur x86 + LyxOS. Basis V1.0.4A.

### asm{} Multi-Backend (arch-spezifisch)
- **Modell**: Jede Ziel-Architektur akzeptiert nur ihre eigenen Mnemonics; ein Mnemonic
  einer fremden Arch ist ein harter Compile-Fehler (wie C-Inline-Assembly). `ir_lower`
  wählt die Mnemonic→Id-Tabelle über das neue `target`-Feld (VMT-sicher: Feld, keine
  neue IRLower-Methode).
- **Neue Backend-Handler** (`IRO_ASM`, op==167):
  - `emit_arm64.lyx` (arm64/macos-arm64/win-arm64/android-arm64): nop, wfi, wfe, sev,
    sevl, yield, isb, dsb, dmb, svc, brk, hlt, ret, eret.
  - `riscv_linux.lyx` (linux-riscv64): nop, wfi, fence, fence.i, ecall, ebreak, mret, sret.
  - `arm_cm_backend.lyx` (arm-cm4/arm-cm33, Thumb-2): nop, wfi, wfe, sev, yield, isb, dsb,
    dmb, svc, bkpt, cpsid i, cpsie i (32-bit-Thumb: höheres Halbwort zuerst).
  - `xtensa.lyx` (esp32/esp32s3): nop (weitere Mnemonics fail-closed, da Byte-Konvention
    nicht gegen einen Assembler verifizierbar).
- **Bestehend unverändert**: x86-64/macos-x86/win-x86 (AST-Pfad `codegen_x86`), LyxOS
  (`emit_lyxos`).
- **Grammatik**: `AsmStmt` + Abschnitt „12.2 Inline-Assembly Rule" in `ebnf.md` ergänzt
  (Soft-Keyword, arch-spezifische Mnemonic-Sets, Fail-closed-Semantik).
- **Vertagt** (pre-existing, ganzer Backend fehlt/hohl, nicht asm-spezifisch): android-x86_64
  (`emitX86_64`-Stub), riscv64-non-linux + arm_cm-non-cm4 (leere `emit()`).
- Verifiziert: Byte-Encodings je Arch, Cross-Arch-Fail-closed, x86/LyxOS-Regression grün,
  Selbst-Host-Fixpunkt gen2==gen3, `make test` 20 PASS/0 FAIL.

## Version 1.0.4A (Juni 2026)

Funktionszeiger + Method-Pointer (Vega-VCL-Event-System) sprachseitig komplett, ELF + LyxOS.
Basis V1.0.3E.

### Funktionszeiger-Felder A1 (#885)
- **fn-Typ-Alias als Klassenfeld**: `type TNE = fn(TControl): int64; type TB = class { on_click: TNE; }`.
  `b.on_click := h` (fn-Name → Adresse), Null-Check, `b.on_click(arg)` (indirekter Call). Zwei
  Wurzeln gefixt: fn-Name-als-Wert lieferte 0 (cg_isDeclaredFunc + lea-Adresse / IRO_FUNC_ADDR);
  `obj.field(args)` wurde als Methode gemangled (Feld-Load + plain indirekter Call).

### Method-Pointer B2 (#886)
- **`method`-Typ = fat pointer {code, data}** mit self-Bindung. `button.on_click := form.Handle`
  bindet `form` als self; `button.on_click(arg)` ruft `form.Handle` mit self=form. Design:
  heap-fat-ptr (Feld = 8B-Pointer → heap{code,data}; kein Klassen-Layout-Umbau). Parser-Befund:
  Typ-Alias-Target wurde verworfen → jetzt gespeichert (TYPE_DECL c0 + iv-Bit1) + method-Alias-Registry.

### fn-ptr/method-ptr Polish (#887)
- **lokaler plain-fn-ptr-Call** `var f := fn; f(args)` crashte (ELF WP-02-Closure-Fehlinterpretation;
  LyxOS „unbekannte Funktion") → thin-call / _findLocalSlot+CALL_INDIRECT.
- **benannte Params** in fn/method-Typ (`fn(s: T)`, `method(s: T)`) parsen jetzt.
- **cross-module method-Felder** (importierte Klasse) auf LyxOS (_treg-Context-Swap).

### sema (#884)
- **Arity-Check**: Argument-Anzahl bei Funktionsaufrufen wird geprüft (vorher KEINE Prüfung →
  `add(5)` für `fn add(a,b)` kompilierte → Garbage/Crash). Konservativ (same-module, nicht extern/variadic).

## Version 1.0.3E (Juni 2026)

Windows-Backend-Korrektheit. Basis V1.0.3D.

### Windows PE32+ (win64)
- **Beschreibbare Globals + argc/argv (#882)**: win64 hatte keine beschreibbaren globalen
  Variablen — Daten/Globals liegen im single-section-Design am `.text`-Ende, aber `.text` war
  nur CODE|EXECUTE|READ → jeder globale Schreibzugriff (`g := x`) page-faultete. Zusätzlich
  speicherte `_start` argc/argv nicht in die Globals (GetArgC/GetArgV lasen 0). Fix: `.text` →
  +MEM_WRITE; `_start` schreibt argc/argv nach CG_ARGC/CG_ARGV (rip-relativer Store, disp gepatcht).
  Wine-verifiziert: globale Writes, GetArgC/GetArgV/ArgvGet korrekt.

Verifiziert: wine (global-write, GetArgC 1/4/2, ArgvGet); ELF-Pfad unberührt; Singularität S3==S4.

## Version 1.0.3D (Juni 2026)

LyxOS-Kernel-Systemprimitive (WSP). Basis V1.0.3C.

### LyxOS — WSP-Systemprimitive
- **cpu-ctrl / Fences / Atomics (#877)**: Builtins für Kernel-Treiber — cpu_pause/hlt/cli/sti/rdmsr/wrmsr,
  fence_sfence/lfence/mfence, atomic_load/store(xchg)/cas(lock cmpxchg)/fetch_add(lock xadd).
- **@volatile (#879)**: volatile-Loads von DCE ausgenommen (MMIO/Hardware-Register-Reads bleiben
  erhalten; callmode-Sentinel-Markierung).
- **@align(n) (#880)**: array/heap-backed Locals N-Byte-aligned alloziert (über-alloc + round-up;
  DMA/MMIO/SIMD/Page-Buffer). Neues Var-Attribut, ebnf.md ergänzt.

Verifiziert: Atomics runtime (store_load/fetch_add/cas), @volatile (Load überlebt DCE), @align
(Disasm over-alloc+round); intrinsics 70/70, call_args 8/8, wp4 4/4; Singularität S3==S4
(3c0068e2); voll-lyxc→LBF baut (3.85 MB). ELF-Pfad unberührt. Offen (WSP): asm{}-Block,
extern/FFI echte Linkage (Reloc-Consumer).

## Version 1.0.3C (Juni 2026)

LyxOS-SIMD vervollständigt. Basis V1.0.3B.

### LyxOS — SIMD-Reste (#875)
- **AND/OR/XOR** auf parallel Array<f32> → `andps`/`orps`/`xorps` (vektorisierte SSE2-Loop).
- **NEG** (`-vec`) → packed Vorzeichenbit-Flip (`pcmpeqd`+`pslld 31`+`xorps`).
- **CMP_EQ/NE/LT/LE/GT/GE** → `cmpps` mit Prädikat-Imm (Masken-Vektor pro Lane).
- Damit ist SIMD vollständig: Allokation, f32-Element-Zugriff, Arithmetik (ADD/SUB/MUL/DIV, #873)
  und nun Bitwise/Negation/Vergleich.

Verifiziert: NEG runtime (-5→5), AND/OR/XOR/CMP Disasm; intrinsics 62/62, call_args 8/8;
Singularität S3==S4; voll-lyxc→LBF baut (3.83 MB). ELF-Pfad unberührt. Offen: WSP-System-
primitiven, Kernel-Runtime-Bestätigung (uidemo/lyxc-LBF).

## Version 1.0.3B (Juni 2026)

LyxOS-Sprach-Features: Adresse-von, korrekter f64-Vergleich, SIMD. Basis V1.0.3A.

### LyxOS (#872, #873)
- **@local Adresse-von (#872)**: `@x` (TK_AT) liefert auf lyxos jetzt die Slot-Adresse
  (lowerUnOp op==111 → IRO_LOAD_LOCAL_ADDR, lea); ELF konnte es bereits.
- **ucomisd-f64-Vergleich (#872)**: f64-Vergleich nutzt jetzt `ucomisd` (IRO_FCMP_*) statt
  Integer-CMP der IEEE-Bits → korrekt auch für negative f64 (vorher Ordering kaputt).
- **SIMD parallel Array<f32> (#873)**: aligned-mmap-Allokation (count @ ptr-8), f32-Element-
  Zugriff (movss + f32↔f64-Konvertierung), vektorisierte SSE2-Binops (addps/subps/mulps/divps).
  Runtime-verifiziert (lbf_run). SIMD AND/OR/XOR/NEG/CMP weiter offen (kontrollierter Abbruch).

Verifiziert: intrinsics 61/61, call_args 8/8; Singularität S3==S4; voll-lyxc→LBF baut (3.82 MB).
ELF-Pfad unberührt. Offen: WSP-Systemprimitiven, Kernel-Runtime-Bestätigung (uidemo/lyxc-LBF).

## Version 1.0.3A (Juni 2026)

Minor-Release: LyxOS-Codegen-Kern abgeschlossen — vollständige OOP, alle reachable IR-Opcodes,
f64-Pipeline. Basis V1.0.2I.

### LyxOS — cross-module OOP (#866)
- Globales Type-Registry: jeder `NK_TYPE_DECL` aller Module bekommt eine stabile globale type-id
  (modul-unabhängig). Behebt importierte Klassen: `new` mit korrekter Größe/VMT/type-id,
  Feld-Zugriff, virtuelle Dispatch über Modulgrenzen. Damit ist die OOP-Kette komplett
  (geerbte Felder #856, virtuelle Dispatch #857, importierte Methoden #861, Konstruktor-Args #864,
  cross-module #866).

### LyxOS — Opcode-Reste (#867)
- Div/Mod durch 0 → kontrollierter Panic (Exit 1) statt SIGFPE (ASSERT_NOT_ZERO).
- FSQRT (sqrtsd), Diagnostik-Ops (INSPECT/PROFILE) → expliziter NOP, SIMD → expliziter Abbruch,
  LOAD_LOCAL_ADDR-Infra (&local; Parser-Support ausstehend). Kein reachable Opcode mehr im
  INT3-Catch-all.

### LyxOS — f64-Pipeline (#868)
- f64-Literale (Quelltext → IEEE-754 via `_parseFloatBits`), Arithmetik (FADD/FSUB/FMUL/FDIV →
  addsd/subsd/mulsd/divsd), Casts f64↔int (ITOF/FTOI → cvtsi2sd/cvttsd2si), sqrt end-to-end.
  Runtime-verifiziert (lbf_run): add/mul/div/sub/sqrt/casts/Vergleich. f64-Bits liegen als int64
  im Slot, xmm-Ops laden via movsd.

Verifiziert: intrinsics 53/53, call_args 8/8, wp4 4/4; Singularität S3==S4; voll-lyxc→LBF baut
(3.81 MB). ELF-Pfad unberührt. Offene Folge-Items: Parser unary-`&`, ucomisd-f64-Vergleich
(negative Ordering), xmm-Vektor-SIMD; Kernel-Runtime-Bestätigung (uidemo/VUI, lyxc-als-LBF).

## Version 1.0.2I (Juni 2026)

Patch-Release auf Basis von V1.0.2H. LyxOS-Backend: unbehandelte IR-Opcodes, Konstruktor-Args.

### LyxOS-Nativ (emit_lyxos / ir_lower)
- **Unbehandelte IR-Opcodes emittiert + Catch-all gehärtet (#863)**: emit_lyxos verwarf reachable
  Opcodes STILL (kein Code) → stilles Falschverhalten. Jetzt emittiert: NOT(50)/BITNOT(58),
  ASSERT_NOT_NULL/NOT_ZERO/TRUE(158-160)+BOUNDS(157)→`emitPanicExit`, PANIC(121), CALL_INDIRECT(85)→
  `emitCallIndirect`, CALL_EXTERN(84)→dest=0 (kein lyxos-Linkage), POOL_ALLOC/FREE(115/116)→no-op.
  STUB-00: Catch-all → INT3 (lauter Runtime-Trap) statt stillem Drop. Sicherheit: ASSERT_*-Checks
  wirken jetzt. (Offen, nun INT3-Trap: FSQRT(155), SIMD(122-131), INSPECT(153), PROFILE(161-163).)
- **Konstruktor-Args (#864)**: `lowerNew` allozierte Objekt + type-id, rief den Konstruktor GAR NICHT
  → `new C(11)` ließ Felder 0 (Args ignoriert). Fix: lowerNew ruft nach alloc+type-id
  `ClassName_Create(self, args...)` falls definiert (Konvention wie ELF #683; cross-module via
  `_findFuncByName` → auch importierte Ctors). Behebt die TForm.Create-Kaskade (frm.Root()=null → #PF).

Verifiziert: lbf_run `~240&0xFF`=15/`!0`=1/`!5`=0/ctor_0arg=5; Konstruktor-Disasm zeigt Arg + `call
Class_Create` (ELF-Referenz=11); intrinsics 41/41, call_args 8/8, wp4 4/4, imported-dispatch 1/1;
Singularität S3==S4; voll-lyxc→LBF baut (3.75 MB). ELF-Pfad unberührt. OOP-Runtime am echten Kernel.

## Version 1.0.2H (Juni 2026)

Patch-Release auf Basis von V1.0.2G. LyxOS-Backend: Array-Store-DCE-Bug, sema-Builtins, importierte OOP-Methoden.

### LyxOS-Nativ (ir_optimize / ir_lower / sema)
- **STORE_IDX DCE-Bug (#859)**: `IRO_STORE_IDX` fehlte in `ir_optimize.hasSideEffect` → DCE eliminierte
  ALLE Array-Element-Stores (`a[i] := v`) auf dem lyxos-IR-Pfad (dest=idx-temp galt als tot → NOP).
  Fix: STORE_IDX in hasSideEffect. wp4_fields jetzt 4/4.
- **pipe/truncate sema-Registrierung (#859)**: `_regBuiltin("pipe"/"truncate")` — die lowerCall/emit-
  Einträge (id 231/232) lagen bereit, waren aber unerreichbar.
- **Methoden-Dispatch importierter Klassen (#861)**: eine Methode einer importierten Klasse (z.B.
  TForm.Run aus vui) kehrte sofort zurück statt zu laufen — (a) `_findTypeDecl` scannte nur das aktuelle
  Modul → unauflösbar am Call-Site → kein Dispatch; (b) der transitive Import-Pre-Pass registrierte
  Methoden importierter Klassen nicht. Fix: `_baseTypeNode` liefert den Klassennamen auch ohne lokales
  decl (statische Mangle `Class_method`, cross-module); Pre-Pass registriert importierte Methoden mangled.

Verifiziert: wp4 4/4, intrinsics 37/37, call_args 8/8, neuer importierte-Klassen-Dispatch-Test;
importierte Methode loopt korrekt (lbf_run exit 124, vorher 2). Singularität S3==S4; voll-lyxc→LBF
baut (3.74 MB). ELF-Pfad unberührt (nutzt ir_optimize/ir_lower nicht). OOP-Runtime am echten Kernel.

## Version 1.0.2G (Juni 2026)

Patch-Release auf Basis von V1.0.2F. LyxOS-OOP: geerbte Feld-Offsets + virtuelle Methoden-Dispatch.

### LyxOS-Nativ (ir_lower)
- **OOP Bug #1 — geerbte Feld-Offsets (#856)**: `_fieldOffsetIn`/`_typeSizeOf` ignorierten geerbte
  Basis-Klassen-Felder (extends, c2). `D extends A{val}`: `new D()` alloc(0) + Offset -1 → Garbage
  (d.val=0, self.val=1016). Fix: Basis-Felder flach voranstellen (rekursiv), wie ELF. Am Kernel
  bestätigt: d.val=41, d.S()=42.
- **OOP Bug #2 — virtuelle Methoden-Dispatch (#857)**: ir_lower machte nur statische Dispatch
  (deklarierter Typ) → `a.S()` (a:A hält D) rief A.S() statt D.S(). Fix: switch-dispatch über eine
  type-id @ Objekt-Offset 0 (Klassen mit virtueller Methode; Felder ab +8), closed-world-
  Vergleichskette über Subklassen-Overrides. Kein Daten-VMT/Adress-Patching — nur vorhandene IR-Ops.

Verifiziert: ELF-Referenz a.S()=42; Disasm new D() alloc 16; Tests intrinsics 35/35, call_args 8/8,
wp3 5/5. Singularität S3==S4; voll-lyxc→LBF baut weiter (3.65 MB). OOP-Runtime auf echtem LyxOS-
Kernel zu verifizieren (new→mmap nr9 ≠ Linux). ELF-Pfad unberührt (nutzt ir_lower nicht).

## Version 1.0.2F (Juni 2026)

Patch-Release auf Basis von V1.0.2E. **Meilenstein: lyxc compiliert vollständig zu einem LyxOS-LBF.**
`lyxc --target=lyxos src/lyxc.lyx` erzeugt ein vollständiges natives LBF (~3.6 MB, Magic LYX!) ohne
unaufgelöste Builtins.

### LyxOS-Nativ (ir_lower / emit_lyxos)
- **Transitiver Import-Funktions-Pre-Pass**: globaler Pre-Pass in `lowerModule` registriert alle
  (transitiv) importierten Top-Level-Funktionen im funcBuffer vor dem Body-Lowering. Behebt
  „unbekannter Builtin: StrLen" (lyxc importiert std.string nur transitiv). Iterative Work-Queue
  mit Pfad-Dedup, keine neue IRLower-Methode (Seed-vtable-Schutz). funcId bleibt namensbasiert
  konsistent.
- **0x0200-VFS-Block** (kernel-adoptiert, Commit 6e02a6f): `lseek`(0x0204), `stat`/`lstat`(0x0205
  ±NOFOLLOW), `symlink`(0x0213), `rmdir`(0x0208+UNLINK_DIR), `nanosleep`(0x000A sleep_ns,
  timespec→ns). dir_fd(AT_CWD=-1)/flags via CONST_INT-Injektion in den argBase-Block.
- **Intrinsics/Diagnostik**: `EPrintInt`→stderr (`emitPrintIntFd`), `ArgvGet` (lea+deref),
  `getdents64`→read-on-dirfd, `clock_gettime`→sys_time_ns+timespec-Split, `chmod`/`chown`→no-op.
- **Gruppe D** `sys_fork`/`sys_execve`/`sys_wait4` → return -1 (LyxOS hat kein fork/exec/wait-
  Prozessmodell, nur sys_spawn_child; einzige Nutzer self_test/lbf_loader laufen nicht auf LyxOS).

Verifiziert: voll-lyxc→LBF baut blockerfrei (lbfdump 1.1: arch=x86-64); funcId-Konsistenz
lyxos_call_args 8/8; intrinsics 33/33, strength 12/12, caps_tlv 6/6, wp3 5/5. Singularität S3==S4.
Offen (Runtime, kein Compile-Blocker): on-device-Test durch Kernel-Team (LyxOS-Syscall-Nrn ≠ Linux).

## Version 1.0.2E (Juni 2026)

Patch-Release auf Basis von V1.0.2D. lyxc→LyxOS: Kat-B/C-Builtins (kein Kernel-Bedarf).

### LyxOS-Nativ (ir_lower / emit_lyxos)
- **getdents64(fd,buf,n)** → read-on-dirfd (`sys_read`=0; §10.4 liefert DirEntry-Array bei Verzeichnis-FD).
- **clock_gettime(clk_id, ts)** → id 211: `sys_time_ns`(117) + timespec-Split (tv_sec=ns/1e9, tv_nsec=ns%1e9
  via cqo/idiv); clk_id ignoriert.
- **chmod/chown** → no-op return 0 (LyxOS ist capability-basiert, keine POSIX-Permission-Bits).

Verifiziert: alle vier compilieren auf `--target=lyxos` (kein Catch-all). Runtime der Syscall-Adapter nicht
via lbf_run testbar (LyxOS-Nrn ≠ Linux) → Disasm. Tests: intrinsics 22/22, caps_tlv 6/6. Singularität S3==S4
erhalten. Nächstes Gate für lyxc-self-hosting: StrLen (transitive Import-Resolution).

## Version 1.0.2D (Juni 2026)

Patch-Release auf Basis von V1.0.2C. Schwerpunkt: lyxc self-hosting auf LyxOS — Builtin-Lowering + CAPS-TLV.

### LyxOS-Nativ (ir_lower / emit_lyxos / writer)
- **Gruppe C — Memory-Intrinsics** (ids 200–210): `peek16`/`poke16`/`memcpy` gelowert (argBase-Konvention,
  `movzx`/`mov`/`rep movsb`).
- **Gruppe A — POSIX-File-Builtins** (ids 220–227): `open`/`close`/`read`/`write`/`rename`/`unlink`/`mkdir`/`exit`
  → flache §10.4-Syscalls (kein dir_fd — implementierter Kernel ist flach). Neuer `emitVfsSyscallAB` mit
  argBase statt fester Slots (vermeidet Caller-Local-Aliasing).
- **sizeof(Type)** compile-time fold in lowerCall (via `_findTypeDecl`+`_typeSizeOf`) — entblockt std.string.
- **@capabilities → LBF CAPS-TLV-Mapping**: `writer.lyx` schrieb CAPS-TLV hart als 0 → @capabilities
  wirkungslos, Kernel-Pledge-Gate erlaubte nur STDIO. Jetzt scannt lyxc `NK_CAPABILITY_DECL`, mappt
  Pfad→`LBF_CAP_*`-Bit (fs.read=1/fs.write=2/network=4/process=8/ki.graph=32/ki.embed=16/audio=128),
  OR-Union → `writer.setCapabilities`. CAPS-TLV trägt nun die echten FS-Caps.

Verifiziert: CAPS-TLV [fs.read,fs.write]=3; Syscall-Nrn + Intrinsics disasm-/lbf_run-verifiziert.
Neue Tests: `lyxos_builtin_intrinsics` (22), `lyxos_strength_reduction` (12), `lyxos_caps_tlv` (6) — alle
in `make test`. Singularität S3==S4 erhalten.

## Version 1.0.2C (Juni 2026)

Patch-Release auf Basis von V1.0.2B. Verifizierter Kombi-Build (peek/poke + strength-reduction) und CI-Härtung.

### CI / Test-Infrastruktur
- **`make test` ruft die neuen LyxOS-Regressionssuites auf**: `tests/lyxos_builtin_intrinsics_test.sh`
  (peek/poke/StrCharAt, 10 Tests) und `tests/lyxos_strength_reduction_test.sh` (`*2^k`/`÷2^k`, 12 Tests)
  liefen bisher nicht im `test`-Target. Genau diese Lücke ließ eine gemeldete „peek/poke-Regression"
  in einer stale Zwischen-Binary (ohne den V1.0.2A-ir_lower-Fix) unbemerkt — die develop-Quelle war
  immer korrekt. Beide Suites jetzt im `test`-Target: ein Build kann keinen der beiden LyxOS-Codegen-Fixes
  mehr verlieren, ohne dass `make test` rot wird.

### Verifikation (develop-HEAD, frischer Build)
- peek8("Z")=90, peek8(var s)=90 (Disasm `movzx`, kein PrintStr-Fehldispatch).
- x*4=20, (y*w+x)*4=48 (strength-reduction korrekt).
- Beide Regressionssuites grün (10/10, 12/12); Singularität S3==S4 erhalten.

## Version 1.0.2B (Juni 2026)

Patch-Release auf Basis von V1.0.2A. LyxOS-IR-Optimizer-Korrektheit: Strength-Reduction-Shift-Bug behoben (lbfwin Bug #4).

### IR-Optimizer (ir_optimize)
- **strength-reduction `*2^k` / `/2^k` Shift-Count korrigiert**: `strengthReduction()` setzte beim
  Umbau `MUL`→`SHL` / `DIV`→`SHR` den Shift-Count (`power`) als **rohen Integer** in `src2`
  (`setInstrSrc2(i, power)`). IR-Backends (`emit_lyxos`) lesen `src2` als Temp-/Slot-Referenz →
  `shl rax, cl` lud `cl` aus Slot `#power` (fremde Variable) statt dem Shift-Betrag. Symptom:
  `x*2/4/8/16` → Garbage (oft 0), `x/4/8` → Garbage; non-pow2 (×3,×5,÷3) + expliziter `x<<2` ok.
  lbfwin-Crash: `DrawChar buf+(y*w+x)*4` (BGRA) → wilder Shift → `#PF`. Fix: den Wert des bereits
  von `src2` referenzierten `CONST_INT`-Temps auf `power` ändern (Helper `setConstDefValue`); die
  `src2`-Referenz bleibt — exakt die Form die ein expliziter `x << 2` erzeugt.
  ELF-Prod-Codegen (`codegen_x86`, AST-direkt) nutzt das IR nicht → nur IR-Backends betroffen.

Verifiziert nativ via lbf_run (x*4=20, x/4=5, (y*w+x)*4=48, a*4+b*2=22).
Neuer Test `tests/lyxos_strength_reduction_test.sh` (12/12). Singularität S3==S4 erhalten.

## Version 1.0.2A (Juni 2026)

Minor-Release auf Basis von V1.0.1E. LyxOS-Codegen-Korrektheit: Memory-Intrinsics-Misdispatch behoben.

### LyxOS-Nativ (ir_lower / emit_lyxos)
- **peek/poke/StrCharAt/StrSetChar Misdispatch behoben (Wurzel des fb-Garblings)**: `ir_lower.lowerCall`
  hatte einen stillen Catch-all der jeden nicht explizit gelowerten Builtin auf `IRO_CALL_BUILTIN imm=1`
  (= **PrintStr**) abbildete. `peek8/32/64`, `poke8/32/64`, `StrCharAt`, `StrSetChar` fehlten in der
  lowerCall-Tabelle (anders als im ELF-Pfad) → wurden `write(1,ptr,strlen)`-Syscalls statt Byte-Load/Store.
  Symptom: lbfwin `DrawString` (liest Glyphen via peek8) + `FillWinFb` (schreibt via poke64) scribbelten
  über den Framebuffer. Fix: acht Intrinsics mit echten CALL_BUILTIN-ids (200–207) gelowert; `emit_lyxos`
  emittiert `movzx`/`mov`. Args in hohen argBase-Block gespillt (nicht Slots 0..2, die Caller-Locals aliasen).
- **lowerCall-Catch-all gehärtet**: kein stiller `id=1=PrintStr`-Default mehr → harter Compile-Fehler
  `"unbekannter Builtin/Funktion: <name>"`. Der stille Default versteckte den Bug; ~150 ELF-Builtins fehlen
  noch in lowerCall und werden jetzt laut statt still gemeldet.

Verifiziert nativ via lbf_run (peek8=90, peek64&0xFF=65, StrCharAt=90/67); Store-Encoding disasm-verifiziert.
Neuer Test `tests/lyxos_builtin_intrinsics_test.sh` (10/10). Singularität S3==S4 erhalten; `make test` grün.

## Version 1.0.1E (Juni 2026)

Patch-Release auf Basis von V1.0.1D. Drei Optimizer-Bugs im lyxos-Backend behoben.

### IR-Optimizer (ir_optimize)
- **getInstrCount-Division**: `instrLen / IR_INSTR_SIZE` (93/80=1) ließ DCE nur eine Instruktion
  sehen → LOAD_LOCAL für Param `a` wurde genoppt → Param `a` immer 0. Behoben via `fnEnd - fnStart`.
- **Cross-Function-Register-Kollision**: Alle Optimizer-Passes scannten den gesamten Instruktions-
  puffer über Funktionsgrenzen hinweg. IR-Register-Nummern starten pro Funktion neu bei 0 →
  `isConstInt(reg)` / `getConstValue()` fanden Konstanten aus einer *anderen* Funktion und falteten
  lebendige Arithmetik falsch (z. B. `f(1,2,3,4,5)` → 7 statt 15). Fix: `fnStart`/`fnEnd`-Felder
  gesetzt pro Funktion in `optimize()`; alle Scan-Loops auf `[fnStart, fnEnd)` eingeschränkt.
- **DCE eliminiert Rückgabe-Register**: `LOAD_LOCAL(dest=0, src1=retValTemp)` — die letzte
  Instruktion die rax vor dem Epilog lädt — wurde von DCE geNOPpt wenn kein anderer Befehl
  Register 0 als Quelle hatte. Das NOP wurde zu `CONST_INT(imm=0)` → rax=0.
  Fix: DCE-Guard `dest > 0` (Register 0 = lyxos-Rückgabe-Register, nie tot).

Wurzel-Symptom: `add5(10,20,30,40,50)` via globaler Variable lieferte 140 statt 150.
Zwei Regressionstests in `tests/lyxos_call_args_test.sh` ergänzt (8/8 grün).

## Version 1.0.1D (Juni 2026)

Patch-Release auf Basis von V1.0.1C. Zwei LyxOS-Codegen-Bugs an der Wurzel behoben.

### LyxOS-Nativ (emit_lyxos / ir_lower)
- **pchar-Variable an PrintStr — echte Wurzel**: `lowerExpr` für `NK_LIT_STR` nutzte
  `nodeIVal` (Parser-Offset) statt des IR-strBuf-Offsets → der Pointer zeigte in die
  Symbol-/Namen-Tabelle ("main"/"gv") statt auf das rodata-Literal. Jetzt via `irAddString`
  interniert (null-terminiert, Escapes verarbeitet). Betrifft alle String-Literale auf
  IR-Backends.
- **user-Funktions-Calls implementiert**: `emit_lyxos.emitCall` war ein Stub (`CALL rel32=0`,
  keine Args/Result) → alle user-fn-Calls kaputt (`g := f(...)` → 0). Jetzt: Args via
  System-V-Register (rdi,rsi,rdx,rcx,r8,r9), CALL-rel32-Patch auf Funktions-Offset,
  Result rax→dest, Callee-Param-Spill Register→Slots.

Verifiziert nativ via lbf_run (call→global=42, 5-arg=15, nested=16, pchar x[0]='H').
Singularität S3==S4 erhalten; `make test` grün.

## Version 1.0.1C (Juni 2026)

Patch-Release auf Basis von V1.0.1B. LyxOS-Nativ-Backend kernel-tauglich (Multi-Section)
und pchar-Fix; Repo-Hygiene.

### LyxOS-Nativ (emit_lyxos / writer / loader)
- **LYXOS-WP-5 — Multi-Section-Metadaten** nach Kernel-Kontrakt (LX-34): natives `LYX!`
  trägt bis zu 3 SECTION_MAP-TLVs (TEXT/RODATA/DATA + prot) + Genesis text/rodata/data_blocks.
  Image bleibt contiguous-4032 @ VA 0x400000 (RIP-Offsets unverändert, uniform RW, per-Sektion-
  prot kernelseitig deferred). entry_point = volle VA; kein Lifecycle-Handler-Table.
  Loader lädt das ganze Image über die Dateigröße (robust gegen Block-Range-Überlappung).
- **pchar-Variable an PrintStr behoben**: `var x: pchar := "..."; PrintStr(x)` lieferte einen
  falschen rodata-Pointer (null-flood). ir_lower hat jetzt einen PrintStr(non-literal)-Pfad
  (slot0=ptr, slot1=-1 Sentinel); emitPrintStr berechnet strlen zur Laufzeit bei len<0.

### Repo-Hygiene
- Fehlende LBF-Quelldateien (`src/tools/lbf/genesis.lyx`, `tlv.lyx`) + referenzierte Tests
  ins Repo aufgenommen — frischer Checkout baut sonst nicht (`undefined function 'tlv_append'`).

Singularität S3==S4 erhalten; `make test` grün.

## Version 1.0.1B (Juni 2026)

Patch-Release auf Basis von V1.0.1A. Schwerpunkt: nativer LyxOS-Backend (emit_lyxos)
von einem ~10-Op-Skelett zu echtem Codegen ausgebaut (LYXOS-WP-0..4).

### LyxOS-Nativ-Backend (emit_lyxos)
- **WP-1 Arithmetik/Vergleiche**: ADD/SUB/MUL/DIV/MOD, AND/OR/XOR/BITAND/BITOR/BITXOR,
  SHL/SHR, CMP_EQ/NEQ/LT/LE/GT/GE, NEG (x86-64, rax/rcx, CMP+SETcc+MOVZX).
- **WP-2 Control-Flow**: JMP/BR_TRUE/BR_FALSE/LABEL mit dynamischer Label-Tabelle +
  rel32-Patching. Fix: Label-Id steht in IMMINT, nicht LABELOFF.
- **WP-3 Globals**: LOAD/STORE_GLOBAL + LOAD_GLOBAL_ADDR über RIP-relativen Daten-Pool
  (Init-Werte aus IR globalBuffer).
- **WP-4 Fields/Index**: LOAD/STORE_FIELD (+HEAP), LOAD/STORE_IDX für structs/arrays.
- Verifikation: lyxos sys_exit==Linux 60 → compute-only LYX! via lbf_run nativ ausgeführt;
  Heap-Pfade Disasm-verifiziert. Tests in `make test` (lyxos_wp1..4).
- LX-30: nativer `--target=lyxos` LYX!-Emit dokumentiert/getestet; lyxc self-compiliert
  zu validem nativem lyxos-LYX!.

### Offen
- LYXOS-WP-5 (Multi-Section W^X, entry_point-Konvention, Lifecycle-Events) — wartet auf
  Kernel-Loader-Kontrakt-Abstimmung (Spec §11b).

Singularität S3==S4 erhalten; `make test` grün.

## Version 1.0.1A (Juni 2026)

Patch-Release auf Basis von V1.0.0A. Schwerpunkt: Sicherheits-Härtung, Korrektheit
und Erweiterung der Backend-/Nativ-Unterstützung.

### Security (Audit-Verifikationspass)
- FFI-Sandbox **fail-closed**: unbekannte Externs erfordern `@cap(...)`; PROCESS-Klasse
  + no-link-Pfad gehärtet (`FFI_CLASS_UNKNOWN`, TCB-Modell std.*/src.*).
- `calloc()` Integer-Overflow-Guard; alle `read()`-Pfade (inkl. `cg_readFile`) OOB-gehärtet.
- DNS-rdata-Doku-Hazard (64- vs 128-Byte-Puffer) behoben; TLS-Hostname-Verifikation
  per CI verankert. RandInt64 silent-0 → `exit(1)`.
- Jeder Fix mit CI-Regressionstest (sec_*-Suite).

### Korrektheit
- `--std-path=` Off-by-one (lieferte `=PATH`) behoben.
- Makefile-Paketversion synchronisiert.

### Backend / Nativ
- **ARM64-Backend wiederbelebt**: con-Namens-Kollision (Target-Routing), `_start`→main,
  lokales/nested Assignment, PrintInt, Arrays, Globals, plain structs + statische Methoden
  (qemu-verifiziert). x86 unverändert.
- **Nativer LYX!-Loader/Runtime** (`lbf_run`): LYX!-Datei laden + in-process ausführen
  (mmap RWX + Sprung). `_indirect_call_0/_1` im x86-Codegen.

Singularität S3==S4 erhalten; `make test` grün.

## Version 1.0.0A (Juni 2026)

Erste Alpha-Version (V1.0.0A) — vollständiger Sprachkern, self-hosting (Singularität),
echte OOP-Vererbung und Backend-Parität inkl. vollständigem Windows-PE32+-Target.
Enthält lyxc-Fix-Backlog L1–L6, WP-A2 (Windows), WP-28..37 (Security), V-1..3 und
BUG-1..8.

### OOP / Vererbung

- **L1 — Feld-Layout-Vererbung**: Felder einer Basisklasse werden in das Layout der abgeleiteten Klasse flach vorangestellt; geerbte Felder erhalten korrekte Offsets (`cg_buildClassLayout`/`cg_buildStructLayout`).
- **L2 — virtuelle Dispatch über Basis-Pointer**: `extends`-Parent korrekt erfasst (Parser `_sc2`-Setter-Bug); `override`/`abstract` implizieren `virtual`; virtuelle Methoden werden dynamisch über die vtable aufgerufen (`cg_genCall`); abgeleitete Klassen erben die vtable, `override` ersetzt den Slot, geerbte nicht-überschriebene Slots werden base→derived propagiert.

### Parser

- **L4 — `[N]T` Prefix-Array-Felder**: `kids: [4]Node;` wird geparst (führendes Integer-Literal nach `[` disambiguiert gegen Tuple-Typen); erzeugt denselben Array-Knoten wie die Suffix-Form `T[N]`.
- **L5 — `form` als Soft-Keyword**: `form` ist überall als normaler Bezeichner nutzbar; das Top-Level-`form`-Konstrukt wird kontextuell per Text erkannt.
- **L6 — lesbare Diagnostik**: Parse-Fehler nennen Token-Namen und das tatsächliche Lexem statt roher Token-IDs (z. B. „expected IDENT, got form 'form'").

### Windows PE32+ — vollständiges OOP & Funktionen (WP-A2)

- **A2.1**: Trampolin-Zone exakt auf die `CG_H_*`-Helper-Offsets ausgerichtet — `wine hello.exe` gibt korrekt aus (vorher Müll, weil PrintStr-Calls in den PrintInt-Helper durchfielen).
- **A2.2**: Unified Base-Relocation — Codegen registriert absolute VMT-Pointer; PE-Backend emittiert echte `.reloc`-Blöcke (`IMAGE_REL_BASED_DIR64`) + rebased die Werte → ASLR-tauglich.
- **A2.3**: `new`/alloc nutzt `VirtualAlloc` statt Linux-`mmap`-syscall.
- **A2.4**: `_start`→`main`-Aufruf korrigiert (`relMain + 14`) — alle user-Funktions-/Methoden-Calls funktionieren.
- Verifiziert unter wine: Funktionen, Rekursion, virtuelle Dispatch, Vererbung, Felder, Heap, Output.

### Security (WP-28..37)

- **WP-28**: Kernel-Mode-Guard Allowlist — `@kernel_mode` Attribut blockiert unsichere Imports
- **WP-29**: Ed25519-Lizenzverifikation — asymmetrische Signaturprüfung ohne RSA-Overhead
- **WP-30**: HTTP Custom-Header CRLF-Injection-Schutz — `\r\n` in Header-Werten wird abgelehnt
- **WP-31**: `FileReadAll` 256-MB-Limit — schützt vor OOM-Angriffen via überdimensionale Dateien; explizite Größenprüfung auch in lyxc selbst (Seed-Binary-Invarianz)
- **WP-32**: TOCTOU-Schutz `ms_appendMetaSafe` — atomares Append mit POSIX-Locks
- **WP-33**: String-Library Bounds-Hardening — alle Slice/Sub-Operationen prüfen Grenzen
- **WP-34**: Codegen-Buffer-Größenlimit — verhindert Stack-Overflow bei pathologischen Inputs
- **WP-35**: LYU-Parser symCount-Limit — begrenzt Symboltabellengröße in Precompiled Units
- **WP-36**: `SecureZero` Compiler-Barriere — `poke8`-basiertes Nullen verhindert Dead-Store-Elimination
- **WP-37**: `RandInt64` Fehlerbehandlung — `getrandom`-Fehler werden propagiert, kein Silent-Fail

### V1-Blocker (LyxOS Self-Hosting)

- **V-1**: `--target=lyxos` Segfault bei großen Programmen — behoben
- **V-2**: LyxOS Builtin-I/O falsche Syscall-Nummern — `sys_open=0x200`, `sys_read=0x202`, `sys_write=0x203` korrekt gesetzt
- **V-3**: `lyxc` dynamisch gelinkt via `explicit_bzero` — ersetzt durch `poke8`-Loop (PR #789); `lyxc` ist jetzt vollständig statisch

### P0-Blocker (V1.0.0A Milestone)

- **WP-A2**: Windows PE32+ `.reloc`-Section + ASLR (PR #791) — `win_x86.lyx` und `win_arm64.lyx` emittieren jetzt eine gültige `.reloc`-Section mit leerem `IMAGE_BASE_RELOCATION`-Block; BaseReloc-DataDir korrekt verdrahtet; `DllCharacteristics=0x8160` (DYNAMIC_BASE|NX_COMPAT|HIGH_ENTROPY_VA)

### Security Audit Fixes (PR #790)

- **SEC-BUG-05**: `PathNormalize` — segment-stack-basierter Algorithmus ersetzt fehlerhaften one-pass `..`-Handler; 80-Byte Buffer-Overflow gefixt; sicherer gegen path-traversal-Angriffe

### Compiler-Bugs (BUG-1..8)

- BUG-1: Importierte Konstanten im Bootstrap — behoben
- BUG-2: VMT-Kollision bei identischen Methodennamen — behoben
- BUG-3: Klassen-Instanz-Parameter — behoben
- BUG-4: 7-Argument-Overflow — behoben
- BUG-5: `break` als NOP in verschachtelten Schleifen — behoben
- BUG-6: r8/r9 werden nicht gespillt — behoben
- BUG-7: `BUG-1`-Typenfeld-Offset — behoben (PR #769)
- BUG-8: TypeName.field Offset immer 0 — behoben

### Test Suite

- `make test` grün: alle Tests PASS (LX-25..36, net_frame 45 Tests, WP-28..37 je 20 Tests)
- sec_wp37 in Makefile eingetragen

### P1-Status (86% ✅, Kriterium ≥80%)

C1 TmpFile, C2 Trig-Funktionen, C4 StrFormat, C5 URL-Encode/Build/Resolve, C6 HTTP PUT/DELETE/PATCH/HEAD, C8 log_info_kv — alle implementiert.
A4 (`@big_endian` ARM64 REV-Emission) bleibt offen.

---

## Unreleased

### Parser
- **Multi-import syntax**: `import a, b, c;` expandiert direkt in drei `NK_IMPORT`-Knoten — kein neuer AST-Knoten, Sema/Lowering/Codegen unverändert. Beide Formen sind gültig.

## Version 0.7.0-aerospace (April 2026) 🎉

### 🚀 **DO-178C Compliance**

#### **Tool Qualification (TQL-5)**
- `--version` flag (TOR-001): SemVer + TQL level output
- `--build-info` flag (TOR-002): Build hash, host, FPC version, determinism
- `--config` flag (TOR-003): All configuration parameters documented
- TOR-010: Deterministic code generation validated (SHA-256 comparison)
- TOR-011: 100% IR coverage in all 6 backends
- TOR-012: Error messages with source positions
- TOR-040: Reproducible builds (10x stress test passed)
- TOR-041: No hidden dependencies (static binary, no libc)
- TOR-042: Deterministic optimization

#### **MC/DC Instrumentation (DAL A)**
- `--mcdc` flag for coverage instrumentation
- `--mcdc-report` for coverage report generation
- `__mcdc_record` builtin in all 7 backends
- Coverage report: Decision | Function | Line | T | F | Status

#### **Static Analysis (7 Passes)**
- `--static-analysis` flag
- **Data-Flow Analysis**: Def-Use chains with use-location tracking
- **Live Variable Analysis**: Detects unused variables (warnings)
- **Constant Propagation**: Tracks known constants through irAdd/irSub/irMul
- **Null Pointer Analysis**: Tracks potentially null pointers from ConstStr
- **Array Bounds Analysis**: Static index safety verification
- **Termination Analysis**: Detects unbounded loops and recursive calls
- **Stack Usage Analysis**: Worst-case stack calculation per function

#### **Test Generation**
- **Fuzzing**: 50 random Lyx programs, 0 crashes, 50 unique inputs
- **Boundary-Value Analysis**: 28 tests across 4 categories (all passed)
- **Mutation Testing**: 3 mutations generated, 1 killed (33% score)
- **Symbolic Execution**: 15 paths explored through if/else trees

### 🌐 **New Backends**

#### **RISC-V RV64GC** (`--target=riscv`)
- Full RV64I emitter with LP64D ABI
- PMP configuration (16 regions, NAPOT/NA4/TOR modes)
- CSR access (read/write/set/clear)
- ECALL/EBREAK, Fence/WFI
- Machine Mode support (mret, get_mhartid, get_mcycle)
- ELF64 writer for RISC-V (EM_RISCV=243)

#### **ARM Cortex-M** (`compiler/backend/arm_cm/`)
- MPU configuration (8 regions, 6 AP modes)
- Fault handlers (HardFault, MemManage, BusFault, UsageFault)
- Stack canary detection ($DEADBEEF pattern)
- Privileged/Unprivileged mode switching
- TrustZone stubs (M33+)

### 🛡️ **Safety Features**

#### **ESP32 Safety**
- Watchdog: `watchdog_init()`, `watchdog_feed()`, `wdt_reset()`
- Brownout: `brownout_check()`, `brownout_config()`
- Flash: `flash_verify()`, `secure_boot()`
- MPU: `mpu_config()`, `pmp_lock()`
- Stack: `stack_canary_check()`
- Cache: `cache_flush()`
- Coredump: `coredump_save()`

#### **ARM Cortex-M Safety**
- MPU: `mpu_enable()`, `mpu_config()`
- Fault: `get_fault_status()`, `get_fault_address()`, `clear_fault_status()`
- Stack: `stack_canary_check()`
- Mode: `set_unprivileged()`, `set_privileged()`
- Debug: `bkpt()`

#### **RISC-V Safety**
- PMP: `pmp_config()`, `pmp_lock()`
- CSR: `csr_read()`, `csr_write()`, `csr_set()`, `csr_clear()`
- Control: `ebreak()`, `fence()`, `fence_i()`, `wfi()`, `mret()`, `sret()`
- Info: `get_mhartid()`, `get_mcycle()`, `get_time()`

### 📊 **IR Coverage**
- **100% IR coverage** in all 7 backends (113/113 operations)
- x86_64: ✅ 100% · x86_64_win64: ✅ 100% · arm64: ✅ 100%
- macosx64: ✅ 100% · xtensa: ✅ 100% · win_arm64: ✅ 100% · riscv: ✅ 100%

### 📚 **Documentation**
- **COMPILER_MANUAL.md**: Complete compiler documentation
- **USER_GUIDE.md**: User-facing guide with examples
- **VERIFICATION_REPORT.md**: DO-178C verification report (111/111 tests passed)
- **aerospace-todo.md**: Updated with completed items
- **README.md**: Updated with new features

---

## Version 0.5.7 (April 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **String-Bibliothek (std.string) v0.5.7**

Erweiterte String-Manipulationsfunktionen:

```lyx
import std.string;

fn main(): int64 {
    // StringBuilder für effizientes Konkatenieren
    var sb: StringBuilder := new StringBuilder();
    sb.Init(64);
    sb.Append("Hello");
    sb.Append(", ");
    sb.Append("World");
    sb.AppendChar(33);     // '!'
    sb.AppendInt(42);
    
    var result: pchar := sb.ToString();
    PrintStr(result);       // Hello, World!42
    StrFree(result);
    
    sb.FreeBuffer();
    dispose sb;
    return 0;
}
```

- **StringBuilder**: Klasse für effizientes String-Building
- **StrTrim**: Entfernt führende/nachfolgende Leerzeichen
- **StrSplit**: Splitst Strings nachDelimiter

#### **Data Library (Pandas-like) v0.5.7**

Umfassende Data-Frame-Bibliothek für Datenanalyse:

```lyx
import std.data.core;
import std.data.io;

fn main(): int64 {
    // CSV einlesen
    var df: DataFrame := ReadCSV("data.csv", true, ",");
    
    // Spalten-Operationen
    var sum: int64 := SeriesSum(df, "sales");
    var avg: f64 := SeriesMeanF64(df, "price");
    
    // Gruppierung
    var grouped: DataFrame := DataFrameGroupBy(df, "category");
    var counts: DataFrame := GroupByCount(grouped, "category");
    
    DataFrameFree(df);
    return 0;
}
```

- **DataFrame**: 2D-Tabellen mit benannten Spalten
- **Series**: 1D-Arrays mit Labels
- **CSV I/O**: ReadCSV, WriteCSV
- **GroupBy**: Gruppierung und Aggregation
- **Filter/Slice**: Daten-Teilmengen
- **Statistik**: Sum, Mean, Min, Max, StdDev, etc.

#### **Validation Library (std.validate) v0.5.7**

Business-Identifier Validierung:

```lyx
import std.validate.ean;
import std.validate.iban;
import std.validate.luhn;
import std.validate.vat;

fn main(): int64 {
    // EAN/ISBN Validation
    var valid: bool := EAN13Validate("4006381333931");
    var isbn: bool := ISBN13Validate("978-3-16-148410-0");
    
    // IBAN Validation
    var ibanValid: bool := IBANValidate("DE89370400440532013000");
    
    // Credit Card
    var cardType: int64 := CreditCardType("4111111111111111");
    var isValid: bool := CreditCardValidate("4111111111111111", 12, 25);
    
    // VAT ID
    var vatValid: bool := VATValidate("DE123456789");
    
    return 0;
}
```

- **EAN/UPC**: EAN-13, EAN-8, EAN-14, ISBN-13/10, UPC-A
- **IBAN**: ISO 13616 Mod 97, 50+ Länder
- **Credit Card**: Luhn-Algorithmus, 8 Kartentypen
- **VAT**: EU 27 Länder mit länderspezifischen Regeln

#### **Statistics Library (std.stats) v0.5.7**

Array-Aggregatfunktionen und Statistik:

```lyx
import std.stats;

fn main(): int64 {
    var arr: array := [3, 1, 4, 1, 5, 9, 2, 6];
    
    var sum: int64 := ArraySum(arr);
    var avg: f64 := ArrayAvg(arr);
    var min: int64 := ArrayMin(arr);
    var max: int64 := ArrayMax(arr);
    var median: f64 := ArrayMedian(arr);
    
    // Sorting
    ArraySort(arr);
    
    // Variance/StdDev
    var variance: f64 := ArrayVariance(arr);
    var stddev: f64 := ArrayStdDev(arr);
    
    return 0;
}
```

- **Aggregates**: Sum, Min, Max, Avg, Median, Count, Product
- **Sorting**: ArraySort, ArrayReverse
- **Filtering**: ArrayFilterGt, ArrayFilterLt, ArrayFilterRange
- **Statistical**: Variance, StdDev, Range, SumSquares

---

## Version 0.5.7 (März 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Enum-Typen (v0.5.7)**

Native Aufzählungstypen mit typsicheren Konstanten:

```lyx
enum Direction { North, South, East, West }
enum Color { Red = 1, Green = 2, Blue = 4 }

fn main(): int64 {
    var d: int64 := Direction::North;
    var c: int64 := Color::Green;
    PrintInt(d);  // 0
    PrintInt(c);  // 2
    return 0;
}
```

- `enum Name { Val, Val = N, ... }` Syntax
- Werte mit optionalem explizitem Integer-Wert
- Zugriff via `EnumName::Wert` (Namespace-Syntax)
- Werden intern als `int64`-Konstanten lowered

#### **Exception Handling: try/catch/throw (v0.5.7)**

Strukturierte Fehlerbehandlung:

```lyx
fn riskyOp(x: int64): int64 {
    if (x < 0) { throw "negative value"; }
    return x * 2;
}

fn main(): int64 {
    try {
        var r: int64 := riskyOp(-1);
    } catch (e) {
        PrintStr("Caught: "); PrintStr(e); PrintStr("\n");
    }
    return 0;
}
```

- `try { ... } catch (varname) { ... }` Syntax
- `throw expr` wirft eine Exception (pchar-Nachricht)
- Nested try/catch vollständig unterstützt
- Implementiert via `irPushHandler`/`irPopHandler`/`irThrow` IR-Opcodes

#### **Multi-Return / Tuple-Rückgabe (v0.5.7)**

Funktionen können mehrere Werte zurückgeben:

```lyx
fn divmod(a: int64, b: int64): (int64, int64) {
    return (a / b, a % b);
}

fn main(): int64 {
    var q, r := divmod(17, 5);
    PrintInt(q);  // 3
    PrintInt(r);  // 2
    return 0;
}
```

- Rückgabetyp `(T1, T2)` Syntax
- `return (expr1, expr2)` Tupel-Literal
- `var a, b := f()` Tupel-Destrukturierung
- Implementierung: RAX/RDX Register-Paar (16-Byte Struct Return)

#### **Generics mit Monomorphisierung (v0.5.7)**

Echte generische Funktionen mit Compile-Time-Spezialisierung:

```lyx
fn max[T](a: T, b: T): T {
    if (a > b) { return a; }
    return b;
}

fn main(): int64 {
    var x: int64 := max[int64](10, 20);  // spezialisiert zu _G_max__int64
    PrintInt(x);  // 20
    return 0;
}
```

- `fn name[T](...)` Syntax für generische Typparameter
- `func[int64](...)` Aufruf-Syntax mit konkreten Typen
- Monomorphisierung: jede Typen-Kombination erzeugt eine eigene Funktion `_G_name__type`
- Mehrere Typparameter möglich: `fn zip[A, B](...)`

#### **Pattern Matching mit match/case (v0.5.7)**

Ausdrucksstärkere Alternative zu `switch`:

```lyx
fn classify(n: int64): int64 {
    match n {
        case 0 => { PrintStr("zero\n"); }
        case 1 | 2 | 3 => { PrintStr("small\n"); }
        case 10 | 20 | 30 => { PrintStr("tens\n"); }
        default => { PrintStr("other\n"); }
    }
    return 0;
}
```

- `match expr { ... }` — kein Klammern um den Ausdruck nötig
- `case val => body` — `=>` statt `:`
- OR-Patterns: `case 1 | 2 | 3 =>` — mehrere Werte pro Case
- `default =>` Fallback
- Bestehender `switch`-Syntax bleibt vollständig kompatibel

#### **Dynamische String-Builtins (v0.5.7)**

7 neue Built-in-Funktionen für mmap-basierte dynamische Strings:

```lyx
var s: pchar := StrNew(64);          // Allokiere String-Buffer
StrSetChar(s, 0, 72);               // s[0] = 'H'
StrSetChar(s, 1, 105);              // s[1] = 'i'
StrSetChar(s, 2, 0);                // Null-Terminator
PrintStr(s);                         // "Hi"

var s2: pchar := StrAppend(s, " World");
PrintStr(s2);                        // "Hi World"

var ns: pchar := StrFromInt(-42);
PrintStr(ns);                        // "-42"

PrintInt(StrLen("Hello"));           // 5  (funktioniert auch auf Literalen)
PrintInt(StrCharAt("ABC", 1));       // 66 ('B')

StrFree(s2);
StrFree(ns);
```

| Funktion | Signatur | Beschreibung |
|----------|----------|-------------|
| `StrNew(cap)` | `(int64) → pchar` | mmap-Allokation mit Header |
| `StrFree(s)` | `(pchar) → void` | munmap via Header |
| `StrLen(s)` | `(pchar) → int64` | Strlen (Null-Scan, kompatibel mit Literalen) |
| `StrCharAt(s, i)` | `(pchar, int64) → int64` | Byte-Zugriff (zero-extended) |
| `StrSetChar(s, i, c)` | `(pchar, int64, int64) → void` | Byte schreiben |
| `StrAppend(dest, src)` | `(pchar, pchar) → pchar` | Konkatenation mit Reallokation |
| `StrFromInt(n)` | `(int64) → pchar` | Integer → Dezimalstring |

**String-Header-Layout:** 16 Byte vor dem Daten-Pointer: `[capacity:8][length:8][data...]`. Der zurückgegebene `pchar` zeigt auf `data` und ist direkt mit `PrintStr` kompatibel.

---

### 🔧 **Bugfixes**

- **Generics arr[i] Regression**: Heuristik für Typarg-Parsing war zu breit — `arr[idx]` wurde fälschlicherweise als generischer Typarg geparst. Fix: `IsKnownTypeIdent()` prüft ob der Token ein bekannter Primitiv-Typ oder deklarierter Typparameter ist.
- **Generics Commit Unvollständig**: `TAstFuncDecl.TypeParams` Feld und `savedTypeParams`/`typeParams` Variablen fehlten im Commit. Der Branch `fix/generics` enthält den Fix.

---

## Version 0.5.1 (März 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Linux ARM64 Backend: VMT Support (v0.5.1)**

Vollständige Virtual Method Table (VMT) Unterstützung für Linux ARM64:

```lyx
// Virtual methods on ARM64
type Animal = class {
    fn virtual speak() {
        PrintStr("?\n");
    }
};

type Dog = class extends Animal {
    fn override speak() {
        PrintStr("Woof!\n");
    }
};

fn main(): int64 {
    var a: Animal := new Dog();
    a.speak();  // Dynamischer Aufruf → "Woof!"
    dispose a;
    return 0;
}
```

**Implementierung:**
- `backend/elf/elf64_arm64_writer.pas`: VMT-Tabelle im .rodata Segment
- `backend/arm64/arm64_emit.pas`: Virtual Call via VMT (LDR + BLR)
- `backend/arm64/arm64_emit.pas`: VMT-Pointer bei `new` gesetzt
- `tests/test_arm64_vmt.pas`: Unit-Tests für ARM64 VMT

#### **ARM64 Backend: 100% IR Opcode Coverage (v0.5.1)**

Alle 93 IR-Opcodes sind jetzt für ARM64 implementiert:

**Neu implementierte Opcodes:**
- `irCast`: Type casting (int↔float)
- `irVarCall`: Indirekte Funktionsaufrufe via BLR
- `irCallStruct`: Struct-by-value calls (AAPCS64 ABI)
- `irReturnStruct`: Struct return mit Memory-Copy
- `irIsType`: VMT-basierte Type-Prüfung
- `irPanic`: Panic/Abort mit stderr + exit
- `irPushHandler/irPopHandler/irThrow`: Exception-Handling
- `irInspect`: Debug Visualizer

**ARM64 SIMD/NEON Operationen:**
- `WriteAddSimd`, `WriteSubSimd`, `WriteMulSimd`
- `WriteAndSimd`, `WriteOrSimd`, `WriteXorSimd`
- `WriteNegSimd`, `WriteNotSimd`
- `WriteCmeqSimd`, `WriteCmhiSimd`, `WriteCmgeSimd`

**ARM64 DynArray Support:**
- `irDynArrayPush`: Element hinzufügen mit auto-growth
- `irDynArrayPop`: Element entfernen
- `irDynArrayLen`: Länge abrufen
- `irDynArrayFree`: Speicher freigeben

#### **IR Bugfix: Float Arithmetic (v0.5.1)**

Korrigierte Float-Operationen im IR-Generator:

```lyx
// Vorher: verwendet irSub/irMul/irDiv (Integer)
var z: f64 := x - y;  // ❌ Falscher Opcode

// Jetzt: verwendet irFSub/irFMul/irFDiv
var z: f64 := x - y;  // ✅ Korrekter Opcode
```

---

## Version 0.4.3 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **IR-Level Inlining (v0.4.3)**

Automatische Inlining-Optimierung auf IR-Ebene für bessere Performance:

```lyx
// Funktionen mit ≤12 IR-Anweisungen werden automatisch inlined
fn add(a: int64, b: int64): int64 {
    return a + b;
}

fn main(): int64 {
    var x: int64 := add(10, 20);  // Wird zu: var x: int64 := 10 + 20;
    return x;
}
```

**Implementierung:**
- `ir_inlining.pas`: Vollständiger Inlining-Pass
- Rekursionserkennung vermeidet selbstreferenzielle Inlinings
- Korrektes Argument-Mapping zwischen Caller/Callee
- Return-Statements werden durch Jumps ersetzt
- Mehrere Pässe für verschachtelte Funktionen

#### **Naming Conventions: PascalCase (v0.4.3)**

Alle stdlib-Funktionen verwenden jetzt PascalCase gemäß AGENTS.md:

```lyx
// Vorher (lowercase/snake_case)
printf("Hello %d\n", 42);
clrscr();
gotoxy(10, 5);

// Jetzt (PascalCase)
Printf("Hello %d\n", 42);
ClrScr();
GoToXY(10, 5);
```

**Umbenannte Funktionen:**
- `std/crt`: `TextColor`, `TextBackground`, `TextAttr`, `ClrScr`, `ClrEol`, `GoToXY`, `HideCursor`, `ShowCursor`, `WriteStrAt`, `ReadChar`
- `std/io`: `Printf`
- `std/env`: `Init`, `Arg`
- `std/string`: `StrCmp`, `StrCpy`
- `std/time`: `Now`

---

## Version 0.2.2 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **SIMD / ParallelArray (v0.2.2)**

SIMD-optimierte Arrays mit element-weisen Operationen:

```lyx
var vec: parallel Array<Int64> := parallel Array<Int64>(1000);
vec[0] := 42;
var first: int64 := vec[0];
var sum: parallel Array<Int64> := vec + vec;  // element-weise Addition
```

**Frontend (Lexer/Parser/AST/Sema):**
- `parallel` und `simd` als Keywords im Lexer
- Parser: `parallel Array<T>(size)` Syntax
- AST: `TAstSIMDNew`, `TAstSIMDBinOp`, `TAstSIMDUnaryOp`, `TAstSIMDIndexAccess`
- Sema: Typprüfung, SIMDKind-Propagierung, Operator-Validierung

**IR-Lowering (vollständig):**
- `nkSIMDNew` → `irAlloc` (Heap-Allokation mit Element-Größe)
- `nkSIMDBinOp` → `irSIMDAdd/Sub/Mul/Div/And/Or/Xor` + Vergleiche
- `nkSIMDUnaryOp` → `irSIMDNeg`
- `nkSIMDIndexAccess` → `irLoadElem` mit korrekter Element-Größe aus SIMDKind
- VarDecl für `atParallelArray`: Heap-Pointer als einzelner Stack-Slot
- Index-Assignment (`vec[i] := value`): Pointer via `irLoadLocal` statt `irLoadLocalAddr`

**Element-Typen:** Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64, F32, F64

**SIMD-Operatoren:** `+`, `-`, `*`, `/`, `&&`, `||`, `^`, `==`, `!=`, `<`, `<=`, `>`, `>=`

### ⚠️ **Noch offen (Backend)**
- x86_64 Backend: SSE2/AVX-Instruktionen für `irSIMD*`-Opcodes
- Bounds-Checks bei ParallelArray Index-Zugriff
- Reduce-Operationen (`irSIMDAddReduce`, etc.)

---

## Version 0.4.2 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Regex-Literale und Regex-Funktionen (v0.4.2)**

Native Unterstützung für reguläre Ausdrücke:

```lyx
var email: pchar := r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$";
var phone: pchar := r"\d{3}-\d{4}";

// Regex-Funktionen
if (RegexMatch(r"abc", "abcdef")) {
    IO.PrintStr("Match!\n");
};
var pos: int64 := RegexSearch(r"\d+", "abc123def");
var count: int64 := RegexReplace(r"old", "text", "new");
```

**Syntax:** `r"pattern"` - Präfix `r` gefolgt von Anführungszeichen

**Funktionen:**
- `RegexMatch(pattern, text)` -> bool: Prüft ob Pattern in Text vorkommt
- `RegexSearch(pattern, text)` -> int64: Position oder -1
- `RegexReplace(pattern, text, replacement)` -> int64: Anzahl Ersetzungen

**Namespace:** `Regex.Match`, `Regex.Search`, `Regex.Replace`

**Compile-Time-Validierung:** Der Compiler prüft die Regex-Syntax

#### **Namespaces für Builtins (empfohlen, rückwärtskompatibel)**

Funktionen können jetzt über Namespaces aufgerufen werden:
```lyx
// Direkter Aufruf (Rückwärtskompatibilität)
PrintStr("Hallo");

// Namespace-Aufruf (empfohlen)
IO.PrintStr("Hallo");
OS.exit(0);
Math.Random();
```

**Verfügbare Namespaces:**
- `IO`: PrintStr, PrintInt, open, read, write, close, etc.
- `OS`: exit, getpid
- `Math`: Random, RandomSeed

#### **Panic und Assert - Fehlerbehandlung zur Laufzeit**

- **`panic(message)`**: Bricht das Programm mit einer Fehlermeldung ab
  - Expression, die nie zurückkehrt
  - Argument muss ein String sein
  - Nachricht wird auf stderr ausgegeben
  - Exit-Code: 1

- **`assert(cond, msg)`**: Runtime-Assertion für Invariantenprüfung
  - `cond` muss ein Boolean sein
  - `msg` muss ein String sein
  - Wenn `cond` false ist, wird `panic(msg)` aufgerufen

**Beispiel:**
```lyx
fn divide(a: int64, b: int64) -> int64 {
    if b == 0 {
        panic("Division by zero!");
    };
    return a / b;
}

fn setAge(age: int64) -> void {
    assert(age >= 0 && age < 150, "Age must be between 0 and 149");
}
```

---

## Version 0.4.1 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Access Control (Sichtbarkeit) für Klassen-Member**
Private, Protected und Public Member für Klassen und Structs:

- **`pub`**: Überall zugänglich (Standard)
- **`private`**: Nur innerhalb der eigenen Klasse zugänglich
- **`protected`**: In der eigenen Klasse und in abgeleiteten Klassen zugänglich

**Beispiel:**
```lyx
type MyClass = class {
  pub pubField: int64;           // Überall zugänglich
  private privField: int64;       // Nur in der Klasse
  protected protField: int64;    // In Klasse und Subklassen
  
  pub fn pubMethod() { }
  private fn privMethod() { }
};
```

---

## Version 0.4.0 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Option Types / Nullable Pointer**
Statische Typprüfung für Pointer-Sicherheit zur Kompilierzeit:

- **Nullable Typen**: `pchar?` kann `null` sein
- **Non-nullable Typen**: `pchar` darf nicht `null` sein (Standard)
- **Null-Coalescing**: `??` Operator für sichere Dereferenzierung
- **null Keyword**: Explizite Null-Zuweisung

**Beispiel:**
```lyx
var p: pchar? := null;    // nullable Pointer
var q: pchar;              // non-nullable Pointer (Standard)
var r: pchar := p ?? "default";  // sicherer Zugriff
```

#### **CLI-Argumente im statischen ELF**
Statische ELF-Binaries unterstützen jetzt CLI-Argumente:

- `main(argc: int64, argv: pchar)` wird nach SysV ABI aufgerufen
- argc: Anzahl der Argumente (inkl. Programmname)
- argv: Array der Argument-Strings

---

## Version 0.3.1 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **std.io: Direkte Syscalls (statisches ELF)**
Die I/O-Funktionen werden jetzt als **direkte Linux-Syscalls** generiert:
- Keine libc-Abhängigkeit
- Statisches ELF ohne externe Symbole
- Funktioniert auf x86-64 und ARM64

**Unterstützte Funktionen:**
| Funktion | x86-64 | ARM64 |
|----------|--------|-------|
| `open` | Syscall 2 | Syscall 56 |
| `read` | Syscall 0 | Syscall 63 |
| `write` | Syscall 1 | Syscall 64 |
| `close` | Syscall 3 | Syscall 57 |
| `lseek` | Syscall 8 | Syscall 62 |
| `unlink` | Syscall 87 | Syscall 87 |
| `rename` | Syscall 82 | Syscall 82 |
| `mkdir` | Syscall 83 | Syscall 83 |
| `rmdir` | Syscall 84 | Syscall 84 |
| `chmod` | Syscall 90 | Syscall 90 |

### 📊 **Getestete Funktionalität**
- ✅ `tests/lyx/io/test_syscall.lyx`: Alle I/O-Tests bestanden
- ✅ Unit-Tests: Alle bestanden

---

## Version 0.3.0 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **std.io: fd-basierte I/O via libc Wrappers**
- `open(path: pchar, flags: int64, mode: int64): int64` – Datei öffnen
- `read(fd: int64, buf: pchar, count: int64): int64` – von File-Descriptor lesen
- `write(fd: int64, buf: pchar, count: int64): int64` – auf File-Descriptor schreiben
- `close(fd: int64): int64` – File-Descriptor schließen

Die Funktionen sind als Builtins registriert und werden als externe libc-Calls
via PLT/GOT generiert (dynamic ELF mit `-rdynamic` Linker-Flag).

### 🔧 **Behobene Bugs**
- Keine neuen Bugs in dieser Version

### 📊 **Getestete Funktionalität**
- ✅ `tests/lyx/io/test_syscall.lyx`: open/write/read/close funktionieren
- ✅ Unit-Tests: 157+ Tests bestanden

---

## Version 0.1.4 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Vollständiges Module System**
- **Import/Export Syntax**: `import std.math;`, `pub fn` Deklarationen
- **Cross-Unit Symbol Resolution**: Importierte Funktionen werden automatisch gefunden
- **Standard Library Support**: `std/math.lyx` mit mathematischen Funktionen
- **Dynamic ELF Generation**: Unterstützung für externe Symbole und Libraries

#### **Robuste Parser-Architektur**
- **Flexible While-Syntax**: `while condition` UND `while (condition)` funktionieren beide
- **Einheitliche If-Syntax**: `if (condition)` - Klammern sind erforderlich für Eindeutigkeit
- **Unary-Expressions**: `return -x` und `var y := -x` funktionieren korrekt
- **Function-In-Function**: If-Statements in Funktionen vollständig unterstützt

### 🔧 **Behobene kritische Bugs**
- **Parser-Rekursion**: Unary-Operator Parsing führte zu unendlicher Rekursion
- **Context-Confusion**: If-Statements wurden fälschlicherweise als Struct-Literale interpretiert
- **Import-Parsing**: Units mit komplexen Control-Flow-Konstrukten parsen korrekt

### 📊 **Getestete Funktionalität**
- ✅ `tests/lyx/control/for_loop.lyx`: While-Schleifen (Output: 15, 15)
- ✅ `tests/lyx/stdlib/use_math.lyx`: Module Import mit dynamischem ELF
- ✅ `std/math.lyx`: Standard Library kompiliert erfolgreich
- ✅ Complex Functions: `Abs64()`, `Min64()`, `Max64()` Implementierungen
- ✅ Cross-File Compilation: Multi-Unit Projekte funktionieren

### 🎯 **Standard Library (std/)**
```lyx
import std.math;

fn main(): int64 {
    let x: int64 := Abs64(-42);      // 42
    let smaller: int64 := Min64(x, 100);  // 42
    PrintInt(times_two(smaller));   // 84
    return 0;
}
```

### ⚠️ **Bekannte Einschränkungen**
- **Cross-Unit Function Calls**: Werden erkannt und gelinkt, aber nicht ausgeführt (Backend-Bug)
- **Verschachtelte Unary-Ops**: `--x` temporär deaktiviert für Parser-Stabilität
- **If-Syntax**: Klammern sind jetzt erforderlich (Breaking Change von flexibler Syntax)

### 📈 **Performance & Stabilität**
- **Compiler-Geschwindigkeit**: ~1.0-1.2s für komplexe Multi-Unit Projekte
- **Memory Management**: Robuste AST/IR Speicherverwaltung ohne Leaks
- **Error Handling**: Präzise Fehlermeldungen mit Zeilen/Spalten-Angaben

### 🔄 **Migration Guide**
```diff
// Alte Syntax (funktioniert nicht mehr)
- if x < 0 { return -x; }
- while i < 10 { i := i + 1; }

// Neue Syntax (erforderlich)
+ if (x < 0) { return -x; }
+ while i < 10 { i := i + 1; }  // oder while (i < 10)
```

---

**Status**: Der Lyx-Compiler ist von *"grundlegend defekt"* zu *"weitgehend produktiv"* geworden und unterstützt nun professionelle Multi-Module Projekte.