# Plan: Arrays, Map<K,V> und Set<T> in Structs

Branch: `feat/arrays-maps-sets-in-structs`

## Ausgangslage

Die Typen `atArray`, `atDynArray`, `atMap`, `atSet` existieren bereits in `TAurumType` (ast.pas:29-32).
`TStructField` hat ein `ArrayLen`-Feld (0=scalar, >0=static, -1=dynamic), aber **kein** `ElemType`/`KeyType`/`ValType` —
d.h. die Elementtypen parameterisierter Felder sind aktuell nicht darstellbar.
Struct-Literals und Layout-Berechnung kennen diese Typen als Felder noch nicht.

---

## ✅ WP1 — TStructField: Parameterisierte Typ-Metadaten (ast.pas) `879381c`

**Ziel:** `TStructField` um Elementtyp-Info für Arrays, Maps, Sets erweitern.

**Änderungen:**
- `ast.pas` · `TStructField` record: neue Felder ergänzen
  ```pascal
  ElemType:  TAurumType;   // für []T, [N]T, Set<T>
  KeyType:   TAurumType;   // für Map<K,V>
  ValType:   TAurumType;   // für Map<K,V>
  ElemTypeName: string;    // falls benannter Typ (struct)
  KeyTypeName:  string;
  ValTypeName:  string;
  ```
- Standardwerte `atUnresolved` in allen Konstruktoren sicherstellen.

**Betroffene Dateien:** `compiler/frontend/ast.pas`

---

## ✅ WP2 — Parser: Feldtyp-Syntax für Collections (parser.pas) `852612b`

**Ziel:** Felder wie `items: []i32`, `data: [16]u8`, `cache: Map<string, i64>`, `tags: Set<string>` korrekt parsen.

**Änderungen:**
- `ParseStructField` / `ParseType`: vorhandene `ParseType`-Logik für Map/Set/Array-Typen
  (parser.pas:2789ff) auch in Struct-Felddeklarationen aktivieren.
- Ergebnis: `TStructField` mit gesetztem `FieldType` + `ElemType`/`KeyType`/`ValType`.
- Fehler ausgeben, wenn Typparameter fehlen: `Map<>` oder `Set` ohne `<T>`.

**Betroffene Dateien:** `compiler/frontend/parser.pas`

---

## ✅ WP3 — Sema: Typauflösung & Struct-Layout für Collection-Felder (sema.pas) `15960ab`

**Ziel:** Semantische Auflösung der Elementtypen; korrekte Bytegrößen im Layout.

**Änderungen in `ResolveStructLayout` (sema.pas:4455ff):**

| Feldtyp      | Größe im Struct | Alignment |
|--------------|-----------------|-----------|
| `[N]T`       | N × sizeof(T)   | sizeof(T) |
| `[]T`        | 16 Bytes (ptr + len) | 8     |
| `Map<K,V>`   | 8 Bytes (ptr)   | 8         |
| `Set<T>`     | 8 Bytes (ptr)   | 8         |

- Elementtypen in `TStructField.ElemType` / `KeyType` / `ValType` auflösen (benannte Typen via `FieldTypeName`).
- Validierung: Key-Typen für Map/Set müssen hashbar sein (Primitiv oder String).
- Validierung: `[N]T` mit N=0 → Fehler.

**Betroffene Dateien:** `compiler/frontend/sema.pas`

---

## ✅ WP4 — Sema: Struct-Literal-Typprüfung für Collection-Felder (sema.pas) `7b5ad4d`

**Ziel:** Typcheck bei Struct-Literals mit Array/Map/Set-Feldern.

**Änderungen in `CheckStructLit` (sema.pas:3690ff):**
- Feld `items` vom Typ `[]i32` + Initialisierung `[1, 2, 3]` → Elementtyp-Kompatibilität prüfen.
- Feld `cache` vom Typ `Map<string, i64>` + `{ "a" => 1 }` → Key/Val-Typen prüfen.
- Feld `tags` vom Typ `Set<string>` + `{ "x", "y" }` → Elementtyp prüfen.
- Fehlende Initialisierung für Collection-Felder → implizites Leer-Init erlauben (nil/0).
- Fehlermeldungen: `field 'items': expected []i32, got []string`.

**Betroffene Dateien:** `compiler/frontend/sema.pas`

---

## ✅ WP5 — IR-Lowering: Struct-Literal Initialisierung (lower_ast_to_ir.pas) `58daaf1`

**Ziel:** IR-Code für Struct-Literals mit Collection-Feldern generieren.

**Änderungen in `LowerStructLit` (lower_ast_to_ir.pas:4820ff):**

- **`[N]T` (static):** Inline in Struct-Speicher — jedes Element einzeln via `irStoreField` mit
  Offset = field_offset + i×sizeof(T).
- **`[]T` (dynamic):** `irAlloc` für Heap-Array; fat pointer (ptr, len) via zwei `irStoreField`
  am Feldoffset speichern.
- **`Map<K,V>`:** `irAlloc` für HashMap-Struktur; Pointer via `irStoreField` speichern;
  Einträge via Runtime-Calls initialisieren.
- **`Set<T>`:** analog Map.
- Leere Initialisierung → Nullpointer / len=0 schreiben.

**Betroffene Dateien:** `compiler/ir/lower_ast_to_ir.pas`

---

## ✅ WP6 — IR-Lowering: Feldzugriff & Element-Operationen (lower_ast_to_ir.pas) `be0d051`

**Ziel:** `obj.field[i]`, `obj.map.get(k)`, `obj.set.contains(x)` etc. lowern.

**Änderungen in `LowerFieldAccess` / `LowerIndex` / `LowerCall` (lower_ast_to_ir.pas:3998ff):**

- **`obj.arr[i]` (static `[N]T`):**
  Basisadresse = struct_addr + field_offset; Index: `+i×sizeof(T)`;
  Bounds check gegen statische Länge N.

- **`obj.arr[i]` (dynamic `[]T`):**
  Lade ptr (field_offset), lade len (field_offset+8);
  Bounds check gegen len; Zugriff: `*(ptr + i×sizeof(T))`.

- **`obj.map.get(k)` / `.insert(k,v)` / `.remove(k)`:**
  Lade Map-ptr aus Feldoffset; generiere Runtime-Call mit ptr als erstem Argument.

- **`obj.set.contains(x)` / `.add(x)` / `.remove(x)`:**
  Lade Set-ptr; generiere Runtime-Call.

**Betroffene Dateien:** `compiler/ir/lower_ast_to_ir.pas`

---

## ✅ WP7 — Codegen: Statische Array-Felder inline (codegen_x86_64.pas) `5ec4688`

**Ziel:** x86-64 Codegen für inline-Array-Felder in Stack- und Heap-Structs.

**Änderungen:**
- **Stack-Structs** (negative Offsets): `obj.arr[i]` →
  `lea rax, [rbp - struct_slot*8]`; `mov rax, [rax + field_offset + i*elem_size]`.
- **Heap-Structs / Klassen** (positive Offsets): analog mit positiven Offsets.
- Bounds-Check: `cmp index, N; jae __bounds_fail`.
- Spill-Verhalten: statische Arrays belegen mehrere Slots im Stack-Frame —
  `slotsNeeded` in `LowerStructLit` muss um `(N×sizeof(T)+7)/8` erweitert werden.

**Betroffene Dateien:** `compiler/backend/codegen_x86_64.pas`, `compiler/ir/lower_ast_to_ir.pas`

---

## ✅ WP8 — Codegen: Fat-Pointer & Heap-Collection-Felder (codegen_x86_64.pas) `4882e89`

**Ziel:** x86-64 Codegen für `[]T`, `Map`, `Set` als Struct-Felder.

**Änderungen:**
- **`[]T`-Feld:** 16 Bytes im Struct (ptr bei offset, len bei offset+8).
  `mov rax, [struct_base + field_offset]` → Heap-Pointer; dann index.
- **`Map`/`Set`-Feld:** 8 Bytes (Pointer).
  `mov rdi, [struct_base + field_offset]` → erster Arg für Runtime-Call.
- Runtime-Dispatch: vorhandene Map/Set-Runtime-Calls aus `LowerCall` wiederverwenden,
  aber Receiver aus Struct-Feld laden statt aus lokalem Symbol.

**Betroffene Dateien:** `compiler/backend/codegen_x86_64.pas`

---

## ✅ WP9 — Memory Management: Structs mit Collection-Feldern (sema.pas, lower_ast_to_ir.pas)

**Ziel:** Heap-Speicher von Collection-Feldern korrekt freigeben.

**Änderungen:**
- **Struct-Destruktor / Scope-Ende:** Für jedes `[]T`, `Map`, `Set`-Feld → `irFree` des Heap-Pointers generieren.
- **Stack-Structs:** am Ende des Scopes automatisch Drop-Code einfügen.
- **Heap-Structs (Klassen):** im `dispose`-Pfad Collection-Felder zuerst freigeben.
- **Kopier-Semantik:** Struct-Zuweisung mit Collection-Feldern → vorerst Shallow Copy
  (Pointer-Kopie); Deep Copy als explizite `.clone()`-Methode (späteres Feature).
- Doppel-Free verhindern: nach Free → Feld auf nil setzen.

**Betroffene Dateien:** `compiler/frontend/sema.pas`, `compiler/ir/lower_ast_to_ir.pas`

---

## WP10 — Tests & Beispiele

**Ziel:** Korrektheit der Implementierung durch Tests absichern.

**Neue Dateien:**
- `examples/test_struct_array.lyx` — statisches und dynamisches Array-Feld
- `examples/test_struct_map.lyx` — Map<string, i64>-Feld mit get/insert/remove
- `examples/test_struct_set.lyx` — Set<string>-Feld mit add/contains/remove
- `examples/test_struct_collections_nested.lyx` — Struct mit mehreren Collection-Feldern
- Tests in `tests/` (falls Test-Framework vorhanden)

**Testfälle je Typ:**
1. Struct-Literal mit initialisiertem Feld
2. Leeres Feld (nil/leer), dann befüllen
3. Feldzugriff / Indizierung
4. Bounds-Check schlägt korrekt fehl
5. Struct geht out-of-scope → kein Memory Leak (via valgrind)
6. Struct als Funktionsparameter mit Collection-Feld

---

## Abhängigkeitsgraph

```
WP1 (AST) → WP2 (Parser) → WP3 (Layout)
                          → WP4 (StructLit-Check)
WP3 → WP5 (IR Init)
WP4 → WP5
WP5 → WP6 (IR Zugriff) → WP7 (Codegen static)
                        → WP8 (Codegen heap)
WP7, WP8 → WP9 (Memory)
WP9 → WP10 (Tests)
```

## Empfohlene Reihenfolge

1. WP1 → WP2 → WP3 (Fundament: Typen + Layout)
2. WP4 (Typcheck parallel zu WP3 möglich)
3. WP5 → WP7 (statische Arrays zuerst — einfacher, kein Heap)
4. WP5 → WP8 (dann dynamisch + Map/Set)
5. WP6 (Feldzugriff, baut auf WP5+WP7+WP8)
6. WP9 (Memory, wenn alles läuft)
7. WP10 (kontinuierlich, spätestens nach WP8)
