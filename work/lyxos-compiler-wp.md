# LyxOS-Compiler-Arbeitspakete (emit_lyxos / natives LYX!)

Stand: V1.0.1A. Ziel: lyxos-Programme nativ (LYX!) korrekt + kernel-tauglich kompilieren.
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

## LYXOS-WP-1 — Arithmetik + Vergleiche
**Prio P0.** emitInstr: IRO_ADD(10), SUB, MUL, DIV, MOD, bitwise (AND/OR/XOR/SHL/SHR),
Vergleiche (EQ/NEQ/LT/LE/GT/GE → 0/1). x86-64-Encoding, Operanden aus Slots → rax/rcx → Slot.
**Abnahme:** `return a+b` (a=5,b=7) → Text-Disasm enthält `add`; analog für sub/mul; ein
Vergleich (`a < b`) emittiert cmp+setcc. Disasm-Test grün.

## LYXOS-WP-2 — Control-Flow
**Prio P0.** IRO_JMP(90), BR_TRUE(91), BR_FALSE(92), LABEL(93). Label-Adressen + rel32-Patching
(wie emit_arm64/codegen_x86). **Abnahme:** `if`/`while`-Programm → Disasm enthält jmp/jz/jnz +
Label-Ziele korrekt gepatcht; Struktur einer Zählschleife erkennbar.

## LYXOS-WP-3 — Globals + .data-Section
**Prio P1.** IRO_LOAD_GLOBAL(64)/STORE_GLOBAL(65); writer: getrennte `.data`-Section +
Genesis `data_blocks` + SECTION_MAP-Eintrag (prot RW). **Abnahme:** Programm mit `var g`
(read+write) → Genesis data_blocks>0, SECTION_MAP enthält DATA(RW); Global-Zugriff im Disasm.

## LYXOS-WP-4 — Fields + Index (structs/arrays)
**Prio P1.** IRO_LOAD_FIELD/STORE_FIELD, IRO_LOAD_IDX/STORE_IDX, NEW/ALLOC-Layout.
**Abnahme:** struct-Feld + Array-Index → Disasm enthält die Lade/Speicher-Sequenzen.

## LYXOS-WP-5 — Multi-Section W^X + entry_point + Lifecycle-Events
**Prio P1 (kernel-facing).** .text(RX)/.rodata(R)/.data(RW)/.bss(RW) getrennt mit korrektem
prot; rodata (Strings) raus aus TEXT; entry_point-Konvention mit Kernel abstimmen;
LIFECYCLE-TLV mit Event→Handler-VA für REACTIVE/EVENT_LOOP. **Abnahme:** Programm mit
RW-Global + RO-String → getrennte Sektionen + prot in SECTION_MAP; entry_point dokumentiert.

---

## Reihenfolge & Hinweis
WP-1 → WP-2 → WP-3 → WP-4 → WP-5. ir_lower liefert bereits korrekte IR; die Arbeit ist die
x86-64-Emission in emit_lyxos (analog emit_arm64-Handler, aber x86 + lyxos-ABI). Commit nach
jedem WP. Obsidian: [[Compiler-Workpackages-LYXOS]], [[LBF-Native-Format-Spec]].
