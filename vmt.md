# VMT Implementierung – Virtual Method Table

Dieses Dokument beschreibt die Implementierung von virtuellen Funktionen (VMT) im Lyx-Compiler.

## Aktueller Stand

### ✅ Implementiert: Linux x86_64

Die folgenden Features sind vollständig implementiert:

| Feature | Status | Datei |
|---------|--------|-------|
| Klassen mit Vererbung | ✅ | `frontend/sema.pas` |
| `virtual` Keyword | ✅ | `frontend/lexer.pas`, `parser.pas` |
| `override` Keyword | ✅ | `frontend/lexer.pas`, `parser.pas` |
| VMT-Tabelle im .rodata | ✅ | `backend/elf/elf64_writer.pas` |
| Virtual Calls via VMT | ✅ | `backend/x86_64/x86_64_emit.pas` |
| `new` mit VMT-Initialisierung | ✅ | `backend/x86_64/x86_64_emit.pas` |
| `super` Keyword | ✅ | `frontend/lexer.pas`, `parser.pas`, `sema.pas` |
| `abstract` Klassen | ✅ | `frontend/sema.pas` |
| TObject Basisklasse | ✅ | `frontend/tobject.pas` |
| Pascal-Syntax `TClass.Create()` | ✅ | `frontend/parser.pas` |

### ✅ Implementiert: Windows x86_64

| Feature | Datei | Status |
|---------|-------|--------|
| VMT-Tabelle im PE (.data) | `backend/x86_64/x86_64_win64.pas` | ✅ Implementiert |
| Virtual Calls | `backend/x86_64/x86_64_win64.pas` | ✅ Implementiert |
| `new` mit VMT | IR-Lowering | ✅ Bereits vorhanden |
| VMT-Patching | `backend/x86_64/x86_64_win64.pas` | ✅ Implementiert |
| RTTI (ClassName, ParentVMT) | `backend/x86_64/x86_64_win64.pas` | ✅ Implementiert |

### ❌ Nicht implementiert: Linux ARM64

| Feature | Datei | TODO |
|---------|-------|------|
| VMT-Tabelle im .rodata | `backend/elf/elf64_arm64_writer.pas` | VMT-Sektion hinzufügen |
| Virtual Calls | `backend/arm64/arm64_emit.pas` | `irCall` + `IsVirtualCall` handling |
| `new` mit VMT | `backend/arm64/arm64_emit.pas` | VMT-Ptr bei Allokation setzen |

---

## VMT-Speicherlayout

### Klassen-Instance (Heap)

```
┌─────────────────────────────────────────────────────────────┐
│ Klassen-Instance (Heap)                                     │
│ ┌─────────────┬──────────────────────────┬───────────────┐   │
│ │ VMT-Ptr (8B)│ Fields...               │               │   │
│ └─────────────┴──────────────────────────┴───────────────┘   │
│ Offset 0       8                    sizeof(instance)         │
└─────────────────────────────────────────────────────────────┘
```

- **VMT-Ptr:** 8-Byte Pointer auf die VMT-Tabelle (Offset 0)
- **Felder:** Normale Instanzvariablen ab Offset 8

### VMT-Tabelle (statisch)

```
┌─────────────────────────────────────────────────────────────┐
│ VMT (statisch im .rodata)                                   │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ _vmt_<ClassName>:                                       │ │
│ │   [Methoden-Pointer 0]  → _L_ClassName_method0         │ │
│ │   [Methoden-Pointer 1]  → _L_ClassName_method1         │ │
│ │   ...                                                   │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

Jeder Eintrag ist ein 8-Byte Funktionspointer.

---

## TObject Basisklasse

Alle Klassen erben automatisch von `TObject` (wenn keine explizite `extends` angegeben):

```lyx
type Player = class {
  // Erbt automatisch von TObject
};
```

### TObject Methoden

| Methode | VMT-Index | Beschreibung |
|---------|-----------|--------------|
| `Destroy` | 0 | Virtueller Destruktor |
| `Free` | 1 | Ruft Destroy auf + gibt Speicher frei |
| `ClassName` | 2 | Gibt Klassennamen als `pchar` zurück |
| `InheritsFrom` | 3 | Prüft Vererbungshierarchie |

---

## Sprachsyntax

```lyx
// Basisklasse: virtual Methode deklarieren
type Animal = class {
  name: pchar;
  
  // Virtual method
  fn virtual speak() {
    PrintStr("?\n");
  }
};

// Abgeleitete Klasse: override
type Dog = class extends Animal {
  breed: pchar;
  
  // Override
  fn override speak() {
    PrintStr("Woof!\n");
  }
  
  // Neue virtual Methode
  fn virtual fetch() {
    PrintStr("Fetching!\n");
  }
};

// Pascal-Syntax für Konstruktor
fn main(): int64 {
  var a: Animal := Dog.Create();  // entspricht: new Dog()
  a.speak();  // Dynamischer Aufruf → "Woof!"
  dispose a;
  return 0;
}
```

### Regeln

1. **`virtual`**: Deklariert eine Methode als virtuell mit VMT-Eintrag
2. **`override`**: Überschreibt eine virtuelle Methode der Basisklasse
3. **`static` + `virtual`**: Nicht erlaubt (Compile-Fehler)
4. **`override` ohne Basisklasse**: Compile-Fehler
5. **`override` mit falscher Signatur**: Compile-Fehler
6. **`abstract`**: Methode ohne Implementierung, muss in abgeleiteter Klasse überschrieben werden

---

## Windows x86_64 Backend (Implementiert)

### VMT-Tabelle im .data Segment

**Datei:** `backend/x86_64/x86_64_win64.pas`

Die VMT-Tabelle wird im `.data` Segment emittiert mit folgendem Layout:

```
_classname_ClassName:   ; Null-terminierter Klassenname (für RTTI)
  db "ClassName", 0

_vmt_parent_ClassName:  ; Pointer auf Parent-VMT (für InheritsFrom)
  dq <dataRVA + parentOffset>

_vmt_classname_ptr_ClassName:  ; Pointer auf Klassennamen
  dq <dataRVA + classNameOffset>

_vmt_ClassName:         ; VMT-Basis (hierhin zeigt der VMT-Ptr in Instanzen)
  dq <textRVA + method0_offset>  ; Methode 0
  dq <textRVA + method1_offset>  ; Methode 1
  ...
```

### Virtual Call Codegen

```asm
; obj.speak() mit virtual call
; RCX = obj (erstes Argument / self für Windows x64)
; VirtualTableIndex = N

mov rax, [rcx]           ; RAX = VMT-Ptr (erstes 8 Bytes der Instance)
mov rax, [rax + N*8]     ; RAX = Methoden-Pointer aus VMT[N]
call rax                 ; Indirect call
```

### VMT-Patching (TDataRefPatch)

Die VMT-Adressen werden dynamisch im PE-Writer gepatcht, da `dataRVA` von der Code-Größe abhängt:

```pascal
// pe64_writer.pas
type
  TDataRefPatch = record
    DataOffset: Integer;    // Position im Data-Buffer
    TargetOffset: Integer;  // Ziel-Offset
    IsCodeRef: Boolean;     // true = .text, false = .data
  end;
```

Beim Schreiben der PE-Datei werden die Patches mit korrekten RVAs angewendet:
- Code-Referenzen: `textRVA + TargetOffset`
- Data-Referenzen: `dataRVA + TargetOffset`

---

## TODO: Linux ARM64 Backend

### 1. VMT-Tabelle emittieren

**Datei:** `backend/elf/elf64_arm64_writer.pas`

### 2. Virtual Call generieren

**Datei:** `backend/arm64/arm64_emit.pas`

Das ARM64 Backend muss `IsVirtualCall` in `irCall` behandeln:

```pascal
// Aktuell fehlt:
irCall:
  // ... normaler Call ...
  // FEHLT: IsVirtualCall handling
```

**ARM64 (Linux) Virtual Call:**
```asm
; obj.speak() mit virtual call
; X0 = obj (erstes Argument / self)
; Angenommen: VirtualTableIndex = 0

ldr x1, [x0]            ; X1 = VMT-Ptr
ldr x1, [x1, #0]       ; X1 = Methoden-Pointer aus VMT[0]
blr x1                  ; Indirect call
```

### 3. VMT-Ptr bei `new` setzen

```asm
; Nach alloc:
; X0 = allokierter Speicher

adrp x1, _vmt_Dog       ; Page-Adresse der VMT
ldr x1, [x1, :lo12:_vmt_Dog]  ; Offset-Adresse
str x1, [x0]           ; [instance + 0] = VMT-Ptr
```

---

## Implementierungsdetails: x86_64 Linux

### VMT-Tabelle Generierung

**Datei:** `backend/elf/elf64_writer.pas`

```pascal
procedure TELF64Writer.EmitVMTs;
var
  cd: TAstClassDecl;
  methodAddr: UInt64;
  i: Integer;
begin
  for cd in FClassDecls do
  begin
    if Length(cd.VirtualMethods) = 0 then Continue;
    
    // VMT-Label
    FDataBuffer.WriteLabel(cd.VMTName);
    
    // Methoden-Pointer
    for i := 0 to High(cd.VirtualMethods) do
    begin
      methodAddr := GetMethodAddress(cd.VirtualMethods[i]);
      FDataBuffer.WriteU64LE(methodAddr);
    end;
  end;
end;
```

### Virtual Call Codegen

**Datei:** `backend/x86_64/x86_64_emit.pas`

```pascal
irCall:
  // ...
  if instr.IsVirtualCall and (instr.VMTIndex >= 0) then
  begin
    // 1. VMT-Ptr laden
    WriteMovRegMem(FCode, RAX, RDI, 0);  // RAX = [obj]
    
    // 2. Methoden-Pointer aus VMT laden
    WriteMovRegMem(FCode, RAX, RAX, instr.VMTIndex * 8);  // RAX = VMT[idx]
    
    // 3. Indirect call
    WriteCallReg(FCode, RAX);
  end
  else
  begin
    // Normaler direkter Call
    // ...
  end;
```

---

## Tests

### Bestehende Tests (Linux x86_64)

```
tests/lyx/oop/
├── oop_simple.lyx       # Basis OOP
├── oop_super.lyx        # super Keyword
├── test_abstract.lyx    # Abstract Klassen
├── test_abstract_full.lyx
└── test_vmt.lyx         # Virtual Method Table
```

### Fehlende Tests

- [ ] Virtual Calls auf Windows x86_64
- [ ] Virtual Calls auf Linux ARM64
- [ ] TObject Methoden (ClassName, Free, etc.)

---

## Geschätzter Aufwand

| Backend | Teilaufgabe | Aufwand |
|---------|-------------|---------|
| Windows x86_64 | VMT-Tabelle emittieren | ~2h |
| Windows x86_64 | Virtual Call Codegen | ~2h |
| Windows x86_64 | VMT-Ptr bei new | ~1h |
| Windows x86_64 | Tests | ~2h |
| Linux ARM64 | VMT-Tabelle emittieren | ~2h |
| Linux ARM64 | Virtual Call Codegen | ~3h |
| Linux ARM64 | VMT-Ptr bei new | ~1h |
| Linux ARM64 | Tests | ~2h |
| **Gesamt** | | **~15h** |

---

## Abhängigkeiten

```
Windows x86_64:
  1. VMT-Tabelle emittieren (PE Writer)
        ↓
  2. Virtual Call im x86_64_win64.pas
        ↓
  3. VMT-Ptr bei new
        ↓
  4. Tests

Linux ARM64:
  1. VMT-Tabelle emittieren (ELF Writer)
        ↓
  2. Virtual Call im arm64_emit.pas
        ↓
  3. VMT-Ptr bei new
        ↓
  4. Tests
```

---

## Checkliste

### Vor Merge (Linux x86_64)

- [x] Alle Phasen implementiert
- [x] `make test` läuft ohne Fehler
- [x] Integrationstests `tests/lyx/oop/` funktionieren
- [x] VMT in ebnf.md dokumentiert

### Windows x86_64

- [x] VMT-Tabelle in PE emittieren (.data Sektion)
- [x] Virtual Call Codegen (x86_64_win64.pas)
- [x] VMT-Ptr bei new setzen (via irLoadGlobalAddr + irStoreFieldHeap)
- [x] RTTI-Pointer patchen (ClassName, ParentVMT)
- [ ] Tests auf echter Windows-Hardware

### Linux ARM64

- [ ] VMT-Tabelle in ELF64-ARM emittieren
- [ ] Virtual Call Codegen (arm64_emit.pas)
- [ ] VMT-Ptr bei new setzen
- [ ] Tests auf ARM64 Hardware/Emulator
