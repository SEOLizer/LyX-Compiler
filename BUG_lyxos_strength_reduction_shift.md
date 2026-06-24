# BUG: strength-reduction encodes shift amount as a temp ref → `* 2^k` / `/ 2^k` wrong

**Compiler:** lyxc 1.0.2A (self-hosting, aurum/src)
**Target:** `--target=lyxos` (and any IR-based backend: arm64, xtensa…). ELF is correct.
**Severity:** High — every multiply/divide by a power-of-2 constant produces garbage.
Common in array/pixel indexing (`*8`, `*4`). This is the current `vega/lbfwin`
blocker: `DrawChar`/`FillWinFb` compute `buf + (y*w + x) * 4` → wild pointer → #PF.

Status note: the earlier peek/poke→PrintStr mis-dispatch is **FIXED** in 1.0.2A.
This is the next, separate bug found after that fix.

---

## TL;DR

`IRLower`/optimizer strength-reduction rewrites `MUL by 2^k` → `SHL`, but writes
the shift amount into the **src2 operand field** with `setInstrSrc2(i, power)`.
src2 is an SSA/temp reference, so the backend emits `shl rax, cl` with `cl`
loaded from **temp #power** (an unrelated slot), not the immediate `power`.
Same bug for `DIV by 2^k` → `SHR`.

---

## Symptom (x = 19)

| expr | ELF | lyxos | note |
|------|----:|------:|------|
| `x * 2`  | 38  | **0**  | pow2 → broken |
| `x * 3`  | 57  | 57     | non-pow2 → ok |
| `x * 4`  | 76  | **0**  | pow2 → broken |
| `x * 5`  | 95  | 95     | ok |
| `x * 8`  | 152 | **0**  | broken |
| `x * 16` | 48  | **0**  | broken |
| `x * 32` | 96  | **19** | broken (returns x) |
| `x / 4`  | 20  | **0**  | broken |
| `x / 8`  | 10  | **0**  | broken |
| `x / 3`  | 26  | 26     | ok |
| `x << 2` (explicit) | 76 | 76 | **ok** — only strength-reduced form breaks |
| `x << s` (var)      | 76 | 76 | ok |

`* 1` (2^0) is also reduced and mis-encoded — it surfaced as an off-by-one in a
6-arg call (`a*1` term returned 2 instead of 1).

## Disassembly — `fn main(): int64 { var x: int64 := 19; return x * 4; }` (lyxos)

```
mov rax, 0x13            ; x = 19
mov [rbp-0x18], rax      ; x slot
...
mov rax, [rbp-0x20]      ; rax = x (value to shift)   ✓
mov rcx, [rbp-0x18]      ; rcx = [x slot] = 19         ✗ should be the shift count 2
shl rax, cl              ; 19 << 19  → &0xFF = 0
```

The shift count is loaded from a stack slot (here x's slot) instead of being the
immediate `2 = log2(4)`. Compare the explicit `x << 2`, which is correct because
its src2 references a real const-temp holding 2.

---

## Root cause — `aurum/src/ir_optimize.lyx`, `strengthReduction()`

```lyx
// Multiplication by power of 2 → shift           (line ~535)
if (op == IRO_MUL) {
  if (self.isConstInt(src2)) {
    var c2: int64 := self.getConstValue(src2);
    var power: int64 := self.isPowerOfTwo(c2);
    if (power >= 0) {
      self.setInstrOp(i, IRO_SHL);
      self.setInstrSrc2(i, power);     // <-- BUG: 'power' written into the src2
      self.changed := self.changed + 1; //     OPERAND field, which is a temp ref,
    }                                    //     not an immediate.
    ...
```

`setInstrSrc2(i, power)` overwrites src2 (previously the temp holding the
constant `c2`) with the raw integer `power`. The backend then reads src2 as a
temp index → loads `cl` from temp #power (garbage), emitting `shl rax, cl` with
the wrong count.

The **same bug** is in the `DIV → SHR` arm (line ~586):

```lyx
if (op == IRO_DIV) {
  ...
  if (power >= 0) {
    self.setInstrOp(i, IRO_SHR);
    self.setInstrSrc2(i, power);       // same mis-encoding
  }
}
```

Why ELF is unaffected: the ELF path is AST → `codegen_x86.lyx` directly and does
not run this IR optimizer pass; it lowers `x * 4` with its own (correct) emit.
The IR optimizer only feeds the IR-based backends (lyxos, arm64, …).

---

## Suggested fix

Make the shift count reach the backend the same way an explicit `x << 2` does:
src2 must reference a const-temp whose value is `power` (not the literal `power`
stuffed into the operand field). Options:

1. **Rewrite the existing const's value in place.** src2 already points at the
   const-temp that produced `c2` (= 4). Change that producing `IRO_CONST_INT`'s
   immediate from `c2` to `power` (via `setInstrImmInt` on the defining instr),
   and leave src2 pointing at it. Now `SHL`'s src2 references a temp holding 2.
2. **Allocate a fresh const-temp for `power`** and point src2 at it.
3. If the IR has an immediate-form shift (count in `immInt`), set
   `setInstrImmInt(i, power)` + `setInstrSrc2(i, -1)` **and** make the IRO_SHL/SHR
   backend read the count from `immInt` when src2 == -1 (mirroring how the
   MUL-by-0 → CONST_INT case already uses `setInstrImmInt`).

Also: skip the rewrite for `c2 == 1` (`* 1` / `/ 1` are identities — currently
reduced to a `<< 0` that hits the same mis-encoding).

Apply the identical fix to both the MUL→SHL and DIV→SHR arms.

---

## Repro harness

Compile each snippet twice (`lyxc x.lyx -o e`; `lyxc x.lyx --target=lyxos -o
x.lbf`), run the ELF directly; run the `.lbf` by extracting its SECTION_MAP
blocks into a flat image and `CFUNCTYPE`-calling the entry (LBF code is
position-independent, so any mmap base works). `x * 4` returns 0 on lyxos, 76 on
ELF.

After this lands: `vega/lbfwin` should finally render (its draw path is just
`peek8`/`poke`/`*4` pixel math, all now exercised). lyx-os already honours the
LBF manifest stack request (commit pending) so the 128 KB lyxos frames fit.
