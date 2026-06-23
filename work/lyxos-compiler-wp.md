# LyxOS-Compiler-Arbeitspakete (emit_lyxos / natives LYX!)

Stand: V1.0.1C. Ziel: lyxos-Programme nativ (LYX!) korrekt + kernel-tauglich kompilieren.
Backend: `src/backend/lyxos/emit_lyxos.lyx` (x86-64 + lyxos-Syscall-ABI), Wrapper
`lyxc.lyx:emitLyxOS` → `src/tools/lbf/writer.lyx`. Format-Spec: `work/lbf-native-spec.md`.

Test-Harness: `lyxc --target=lyxos prog.lyx` → LYX!; Text-Section (Block 1, Datei-Offset
4160 = 1*4096+64) mit `objdump -D -b binary -m i386:x86-64` disassemblieren und auf erwartete
Instruktionen prüfen (lyxos-Code nutzt lyxos-Syscalls → NICHT auf POSIX ausführbar).

---

## LYXOS-WP-0 — Verifikation ✅ ERLEDIGT
**Befund:** `emitInstr` (emit_lyxos.lyx:688) behandelt nur ~10 IR-Ops:
CONST_INT(0), CONST_STR(1), LOAD_LOCAL(61), STORE_LOCAL(62), CALL_BUILTIN(80),
LOAD_ERRVAL(164), CALL(81), FUNC_EXIT(94), ALLOC(112), FREE(113).
**ALLE anderen werden STILL VERWORFEN** (Z.721: „all others: no code").
→ Fehlen: Arithmetik (ADD=10 …), Vergleiche, Control-Flow (JMP=90/BR_TRUE=91/BR_FALSE=92/
LABEL=93), Globals (LOAD_GLOBAL=64/STORE_GLOBAL=65), Fields (LOAD_FIELD/STORE_FIELD),
Index (LOAD_IDX/STORE_IDX), UNOP.
Konsequenz: nur `return <const>` + Builtins funktionieren; `a+b`, `if`, Schleifen, Globals,
Structs, Arrays erzeugen **lückenhaften Code** (verworfene Instruktionen).
Die ir_lower-Schicht produziert die IR korrekt (für arm64 bereits gehärtet) — es fehlt rein
die **Emission** in emit_lyxos. WP-Reihenfolge daher revidiert (Kern-Ops vor Multi-Section).

## LYXOS-WP-1 — Arithmetik + Vergleiche ✅ ERLEDIGT
emitInstr: ADD/SUB/MUL/DIV/MOD, AND/OR/XOR/BITAND/BITOR/BITXOR, SHL/SHR, CMP_EQ/NEQ/LT/LE/GT/GE,
NEG. rax=src1, rcx=src2 → op → dest; Vergleiche via CMP+SETcc+MOVZX. tests/lyxos_wp1_arith_test.sh.
**Verifiziert nativ ausgeführt** (siehe WP-2): add=12, mul=42, sub=15.

## LYXOS-WP-2 — Control-Flow ✅ ERLEDIGT
emitInstr: JMP(90)/BR_TRUE(91)/BR_FALSE(92)/LABEL(93). Dynamische labelAddrs + jmpPatch,
rel32 in applyJmpPatches() gepatcht. Bug behoben: Label-Id in IMMINT (nicht LABELOFF).
**Echte Ausführung** via lbf_run (lyxos sys_exit==Linux 60): if=1/7, while=10, nested=12.
tests/lyxos_wp2_controlflow_test.sh.

## LYXOS-WP-3 — Globals ✅ ERLEDIGT
emitGlobalsPool() hängt Globals-Pool (Init-Werte aus IR globalBuffer) ans Code, RIP-relativ.
LOAD_GLOBAL(64)/STORE_GLOBAL(65)/LOAD_GLOBAL_ADDR(66). **Echte Ausführung**: init=7, store=5,
rmw=14, accum=6, two=12. tests/lyxos_wp3_globals_test.sh.
Hinweis: Globals im (RWX) Code-Pool; getrennte .data-Section = WP-5.

## LYXOS-WP-4 — Fields + Index ✅ ERLEDIGT
LOAD_FIELD(108)/STORE_FIELD(109)(+HEAP 110/111), LOAD_IDX(86)/STORE_IDX(87). Encodings
MOV rax,[rax+off] / MOV [rcx+off],rax / MOV rax,[rax+rcx*8] / MOV [rdx+rcx*8],rax.
Disasm-verifiziert (Offsets 0x0/0x8 + SIB). tests/lyxos_wp4_fields_test.sh.
Hinweis: volle Heap/Array-Ausführung braucht lyxos-Kernel-alloc (lyxos-mmap-ABI ≠ POSIX).

## LYXOS-WP-5 — Multi-Section-Metadaten + entry_point ✅ ERLEDIGT (nach Kernel-Kontrakt)
Kernel-Antworten (Spec §11b) umgesetzt:
- **Q1 contiguous-in-VA @0x400000, keine Reloc:** Image bleibt EIN 4032-gepackter Byte-Stream;
  RIP-Offsets unverändert gültig. SECTION_MAP rein deskriptiv (per-Sektion-prot deferred,
  uniform RW), da Payloads 4032 (nicht page-aligned) → Grenzblöcke geteilt.
- **Q2 entry_point = volle VA 0x400000** (unverändert).
- **Q3 kein Lifecycle-Handler-Table** (nicht emittiert; kooperatives Syscall-Loop-Modell).

emit_lyxos: getTextLen/getRodataLen/getDataLen (rodataBase/globalsBase/codeLen).
writer: setSections + _spanBlocks → bis zu 3 SECTION_MAP (TEXT/RODATA/DATA + prot) +
Genesis text/rodata/data_blocks. loader: lädt ganzes Image via Dateigröße (robust gegen
Block-Range-Überlappung). tests/lyxos_wp5_sections_test.sh (5): Counts>0, entry=0x400000,
Ausführung korrekt.

**Noch offen (separat, nur wenn echtes W^X gewünscht):** Sektionen auf 4096 page-alignen
(padden) → erzwingbares RX/RO statt uniform RW. Kostet Contiguity; aktuell bewusst nicht.

---

## Status & Hinweis
WP-0..WP-5 ✅ erledigt + verifiziert. Self-compile zu nativem lyxos-LYX! valide.
ir_lower liefert korrekte IR; Arbeit war x86-Emission in emit_lyxos + Writer-Metadaten.
Obsidian: [[Compiler-Workpackages-LYXOS]], [[LBF-Native-Format-Spec]].
