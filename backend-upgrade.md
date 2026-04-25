# Backend Upgrade Plan

## 1. Übersicht

Dieses Dokument analysiert die Unterschiede zwischen dem **x86_64 Linux Backend** (am weitesten entwickelt) und den anderen Backends, und erstellt einen Plan, um sie anzugleichen.

## 2. Aktueller Stand der Backends

| Backend | Zeilen Code | IR-Ops | Float | SIMD | Status |
|---------|------------|--------|-------|------|-------|
| **x86_64** (Linux) | 8039 | ~40+ | ✅ Alle | ✅ SSE2/AVX | **Referenz** |
| x86_64 (Win64) | ~4500 | ~30+ | ✅ Alle | ⚠️ Teilweis | Aktuell |
| arm64 | 5422 | ~25+ | ⚠️ Teilwise | ❌ Fehlt | WP-5 |
| macosx64 | 3367 | ~20+ | ⚠️ Teilwise | ❌ Fehlt | WP-6 |
| riscv | 1595 | ~15+ | ❌ Fehlt | ❌ Fehlt | WP-7 |
| xtensa | 2194 | ~15+ | ❌ Fehlt | ❌ Fehlt | WP-8 |
| win_arm64 | ~3000 | ~20+ | ⚠️ Teilwise | ❌ Fehlt | WP-9 |

### 2.1 x86_64 (Linux) - Referenz-Backend

**Unterstützte IR-Ops:**
- Integer: irAdd, irSub, irMul, irDiv, irMod, irNeg, irNot
- Float: irFAdd, irFSub, irFMul, irFDiv, irFNeg, **irFSqrt**
- Bit: irAnd, irOr, irXor, irShl, irShr
- Vergleich: irCmp, irFCmp
- SIMD: irSIMDAdd, irSIMDSub, irSIMDMul
- Calls: irCall, irCallBuiltin
- Control: irJmp, irJe, irJne, irJl, irJle, irJg, irJge
- Memory: irLoad, irStore, irLea

**Unterstützte Funktionen:**
- SSE2: addsd, subsd, mulsd, divsd, sqrtsd
- AVX: vaddsd, vsubsd, vmulsd, vdivsd, vsqrtsd
- Float-Konvertierung: cvtsi2sd, cvttsd2si
- SysV Calling Convention

### 2.2 Delta-Analyse

| Funktion | x86_64 | arm64 | macosx64 | riscv | xtensa |
|----------|--------|------|----------|------|--------|
| **irFSqrt** (sqrt) | ✅ | ❌ | ❌ | ❌ | ❌ |
| **irFNeg** (negate) | ✅ | ❌ | ❌ | ❌ | ❌ |
| **SIMD Ops** | ✅ SSE | ❌ | ❌ | ❌ | ❌ |
| **Float-Konvert** | ✅ | ⚠️ | ⚠️ | ❌ | ❌ |
| **irLea** (address) | ✅ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |
| **AVX** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **irPopcnt** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **irBswap** | ✅ | ❌ | ❌ | ❌ | ❌ |

---

## 3. Work Packages (WPs)

### WP-1: Float-Grundlagen für alle Backends
**Ziel:** Float Ops (irFAdd, irFSub, irFMul, irFDiv, irFNeg) für alle Backends

| Backend | Ops | Aufwand |
|---------|-----|---------|
| arm64 | +5 | 2h |
| macosx64 | +5 | 2h |
| riscv | +5 | 4h |
| xtensa | +5 | 4h |
| win_arm64 | +5 | 2h |

**Tasks:**
- [ ] arm64: FADD, FSUB, FMUL, FDIV, FNEG implementieren
- [ ] macosx64: FADD, FSUB, FMUL, FDIV, FNEG implementieren  
- [ ] riscv: FADD, FSUB, FMUL, FDIV, FNEG implementieren
- [ ] xtensa: FADD, FSUB, FMUL, FDIV, FNEG implementieren
- [ ] win_arm64: FADD, FSUB, FMUL, FDIV, FNEG implementieren

---

### WP-2: Float-Konvertierung
**Ziel:** Integer ↔ Float Konvertierung (cvtsi2sd, cvttsd2si)

| Backend | Ops | Aufwand |
|---------|-----|---------|
| arm64 | +2 | 1h |
| macosx64 | +2 | 1h |
| riscv | +2 | 2h |
| xtensa | +2 | 2h |
| win_arm64 | +2 | 1h |

**Tasks:**
- [ ] arm64: FloatToInt, IntToFloat Konvertierung
- [ ] macosx64: FloatToInt, IntToFloat Konvertierung
- [ ] riscv: FloatToInt, IntToFloat Konvertierung
- [ ] xtensa: FloatToInt, IntToFloat Konvertierung
- [ ] win_arm64: FloatToInt, IntToFloat Konvertierung

---

### WP-3: Stack Frames & Calling Conventions
**Ziel:** Konsistente Calling Conventions für alle Backends

| Backend | CC | Aufwand |
|---------|-----|---------|
| x86_64_win64 | +1 | 2h |
| arm64 | APCS/Swift | 4h |
| macosx64 | +1 | 2h |
| riscv | +1 | 4h |
| xtensa | +1 | 4h |

**Tasks:**
- [ ] x86_64_win64: Windows x64 ABI verifizieren
- [ ] arm64: APCS/Swift CC verifizieren
- [ ] macosx64: macOS ABI verifizieren
- [ ] riscv: RISC-V CC verifizieren
- [ ] xtensa: Xtensa CC verifizieren

---

### WP-4: Bit-Ops Erweiterung
**Ziel:** irPopcnt, irBswap, ir Rol/Ror für alle Backends

| Backend | Ops | Aufwand |
|---------|-----|---------|
| arm64 | +3 | 2h |
| macosx64 | +3 | 2h |
| riscv | +3 | 3h |
| xtensa | +3 | 3h |

**Tasks:**
- [ ] arm64: POPCNT, BSWAP, ROR/ROL
- [ ] macosx64: POPCNT, BSWAP, ROR/ROL
- [ ] riscv: POPCNT, BSWAP, ROR/ROL
- [ ] xtensa: POPCNT, BSWAP, ROR/ROL

---

### WP-5: arm64 Float & SIMD
**Priorität:** Hoch - ARM64 ist wichtig für macOS/Apple Silicon

| Funktion | Opcode | Aufwand |
|----------|--------|---------|
| irFSqrt | FSQRT | 1h |
| irFNeg | FNEG | 0.5h |
| SIMD | ADVsimd | 8h |

**Tasks:**
- [ ] irFSqrt: FADD, FSUB, FMUL, FDIV implementieren
- [ ] irFNeg: FNEG implementieren
- [ ] SIMD: NEON-basierte SIMD Ops

---

### WP-6: macOS x64 Float & SIMD
**Priorität:** Mittel

| Funktion | Opcode | Aufwand |
|----------|--------|---------|
| irFSqrt | SSE | 1h |
| SIMD | SSE2 | 4h |

**Tasks:**
- [ ] Float: SSE sqrt implementieren
- [ ] SIMD: SSE2 SIMD Ops

---

### WP-7: riscv64 Float
**Priorität:** Niedrig - RISC-V F-Extension optional

| Funktion | Aufwand |
|----------|---------|
| irFSqrt | 4h |

**Note:** Benötigt RISC-V mit F-Extension (FDU Hardware)

---

### WP-8: xtensa Float
**Priorität:** Niedrig - Xtensa hat keine Hardware-FPU

| Funktion | Aufwand |
|----------|---------|
| irFSqrt | Softfloat (8h) |

**Note:** Xtensa braucht Softfloat-Lib

---

### WP-9: win_arm64 Float
**Priorität:** Mittel

| Funktion | Aufwand |
|----------|---------|
| irFSqrt | 1h |
| SIMD | 4h |

**Tasks:**
- [ ] Float: SQRT implementieren
- [ ] SIMD: NEON-basierte SIMD

---

## 4. Abhängigkeiten

```
WP-1 (Float Basics)
    ↓
WP-2 (Float Konvertierung)
    ↓
WP-3 (Calling Conventions)
    ↓
WP-4 (Bit Ops)
    ↓
WP-5-9 (Backend-spezifisch)
```

---

## 5. Prioritäten

### Phase 1: Essentials (In Produktion brauchen wir)
1. **WP-1**: Float Ops für alle Backends
2. **WP-2**: Float-Konvertierung

### Phase 2: Stabilität
3. **WP-3**: Calling Conventions verifizieren

### Phase 3: Erweiterungen
4. **WP-4**: Bit-Ops
5. **WP-5**: ARM64 Float & SIMD

### Phase 4: Backend-spezifisch
6. **WP-6-9**: Individual

---

## 6. Schätzung

| Phase | Zeit | WPs |
|-------|------|-----|
| Phase 1 | 16h | WP-1, WP-2 |
| Phase 2 | 12h | WP-3 |
| Phase 3 | 8h | WP-4 |
| Phase 4 | 24h | WP-5-9 |
| **Total** | **~60h** | 9 WPs |

---

## 7. Test-Anforderungen

Für jedes WP müssen Tests erstellt werden:

```bash
# Test Float Ops für alle Backends
./lyxc tests/float/irFAdd.x86_64 -o /tmp/test --target x86_64
./lyxc tests/float/irFAdd.arm64 -o /tmp/test --target arm64
./lyxc tests/float/irFAdd.riscv -o /tmp/test --target riscv

# Test SIMD für alle Backends
./lyxc tests/simd/basic.x86_64 -o /tmp/test --target x86_64
./lyxc tests/simd/basic.arm64 -o /tmp/test --target arm64
```

---

## 8. Siehe auch

- `SPEC.md` - Compilerspezifikation
- `ebnf.md` - Sprachsyntax
- IR-Opcodes: `ir/ir.pas`

---

## 9. Aktueller Status

- [x] x86_64 (Linux): Vollständig
- [ ] arm64: WP-5 pending
- [ ] macosx64: WP-6 pending
- [ ] riscv: WP-7 pending
- [ ] xtensa: WP-8 pending
- [ ] win_arm64: WP-9 pending