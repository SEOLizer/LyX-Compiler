#!/usr/bin/env bash
# tests/oop_vererbung_test.sh — #1624, #1621, #1622, #1619, #1606.
#
# Fuenf Befunde, eine Wurzel: was eine Ableitung von ihrer Basis uebernimmt und
# was sema im Rumpf einer Methode ueberhaupt nachschlaegt. Alle fuenf waren
# STILL — der Code uebersetzte, lief und rechnete falsch.
#
# Geprueft wird der WEG, nicht nur das Ergebnis: der Destruktor meldet sich mit
# einem Seiteneffekt, der Konstruktor an einem Feldwert, und die Diagnosefaelle
# an der Meldung selbst. Ein reiner Ergebnistest waere bei #1621 gruen gewesen
# (der Wert stimmte immer, nur der statische Typ fehlte).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# Uebersetzt und laeuft; vergleicht die Ausgabe.
lauf() {
  local name="$1" erwartet="$2" quelle="$3"
  printf '%s\n' "$quelle" > "$TMP/t.lyx"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" >"$TMP/c.log" 2>&1; then
    no "$name" "uebersetzt nicht: $(grep -m1 -iE 'sema error|codegen error' "$TMP/c.log")"
    return
  fi
  local got; got="$(timeout 30 "$TMP/t" 2>&1 | grep -vE '^$|Capabilities|^  |^=')"
  if [ "$got" = "$erwartet" ]; then ok "$name"; else
    no "$name" "erwartet [$(echo "$erwartet"|tr '\n' ' ')], bekam [$(echo "$got"|tr '\n' ' ')]"
  fi
}

# Muss abgewiesen werden, und zwar mit dieser Meldung.
weist_ab() {
  local name="$1" muster="$2" quelle="$3"
  printf '%s\n' "$quelle" > "$TMP/t.lyx"
  local msg; msg="$(timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" 2>&1)"
  if [ -z "$msg" ] || ! echo "$msg" | grep -q "$muster"; then
    no "$name" "nicht abgewiesen (Muster '$muster' fehlt)"
  else
    ok "$name"
  fi
}

# ===========================================================================
# #1624 — Create und Destroy werden vererbt
# ===========================================================================

# Der Destruktor meldet sich mit -111: an der ZAHL ist ablesbar, WESSEN
# Destruktor lief. Ein Test auf "kein Absturz" waere vorher gruen gewesen.
lauf "#1624: Ableitung ohne eigenen Konstruktor erbt Create und Destroy" \
'111
-111
111
-111
222
-111' 'import std.io;
type TBase = class {
  a: int64;
  fn Create(): void { self.a := 111; }
  fn Destroy(): void { PrintLn(0-111); }
}
type TSub = class extends TBase { b: int64; }
type TSub2 = class extends TBase {
  b: int64;
  fn Create(): void { self.a := 222; }   // eigener ctor, geerbter dtor
}
fn main(): int64 {
  var x: TBase := new TBase(); PrintLn(x.a); dispose x;
  var y: TSub  := new TSub();  PrintLn(y.a); dispose y;
  var z: TSub2 := new TSub2(); PrintLn(z.a); dispose z;
  return 0;
}'

# Ueber zwei Stufen — der Konstruktor steht beim Grossvater.
lauf "#1624: Create wird ueber zwei Stufen geerbt" '5' 'import std.io;
type A = class { v: int64; fn Create(): void { self.v := 5; } }
type B = class extends A { }
type C = class extends B { }
fn main(): int64 { var c: C := new C(); PrintLn(c.v); return 0; }'

# Die Stelligkeit des geerbten Konstruktors gilt weiter (#1236 bleibt scharf).
weist_ab "#1624: geerbter Konstruktor zaehlt seine Argumente" \
  "Argument-Anzahl fuer den Konstruktor" 'type A = class { v: int64; fn Create(x: int64): void { self.v := x; } }
type B = class extends A { }
fn main(): int64 { var b: B := new B(); return b.v; }'

# ===========================================================================
# #1621 — der Rueckgabetyp einer geerbten Methode bleibt erhalten
# ===========================================================================
lauf "#1621: geerbte Methode behaelt pchar und bool" \
'Hallo
false
Sub
true' 'import std.io;
type IP = interface { fn GetS(): pchar; fn GetB(): bool; }
type TBase = class implements IP {
  s: pchar;
  b: bool;
  fn GetS(): pchar { return self.s; }
  fn GetB(): bool  { return self.b; }
}
type TSub = class extends TBase { }
fn main(): int64 {
  var t: TBase := new TBase(); t.s := "Hallo"; t.b := false;
  PrintLn(t.GetS()); PrintLn(t.GetB());
  var d: TSub := new TSub(); d.s := "Sub"; d.b := true;
  PrintLn(d.GetS()); PrintLn(d.GetB());
  return 0;
}'

# ===========================================================================
# #1622 — im Methodenrumpf wird nachgeschlagen wie ueberall sonst
# ===========================================================================
weists() { weist_ab "$@"; }
weists "#1622: unbekannter Bezeichner im Methodenrumpf wird gemeldet" \
  "undefined symbol 'wert'" 'type T = class {
  fn M(Wert: int64): int64 { return wert; }
}
fn main(): int64 { var t: T := new T(); return t.M(1); }'

weists "#1622: voellig unbekannter Name im Methodenrumpf wird gemeldet" \
  "undefined symbol 'gibtsNirgends'" 'type T = class {
  fn M(): int64 { return gibtsNirgends; }
}
fn main(): int64 { var t: T := new T(); return t.M(); }'

# Gegenprobe: eine gesunde Methode bleibt gesund — die Pruefung darf nicht
# pauschal alles abweisen, was ihr neu unter die Augen kommt.
lauf "#1622: gesunde Methode uebersetzt weiterhin" '42' 'import std.io;
type T = class {
  f: int64;
  fn Setze(w: int64): void { self.f := w; }
  fn Hol(): int64 { return self.f; }
}
fn main(): int64 { var t: T := new T(); t.Setze(42); PrintLn(t.Hol()); return 0; }'

# Und eine oeffentliche Methode ist keine externe Funktion: die FFI-Sandbox
# darf nicht ueber sie herfallen (iVal-Bit 0 heisst an der Methode `pub`).
lauf "#1622: pub-Methode wird nicht als extern fn behandelt" 'ok' 'import std.io;
type T = class {
  pub fn Sag(): void { PrintLn("ok"); }
}
fn main(): int64 { var t: T := new T(); t.Sag(); return 0; }'

# ===========================================================================
# #1619 — eine Klassenvariable laesst sich auf null setzen und ist es dann
# ===========================================================================
lauf "#1619: Lazy-Init ueber eine globale Klassenvariable" \
'null
gebaut
7' 'import std.io;
type T = class { tag: int64; }
var g: T := null;
fn Hol(): T {
  if (g == 0) { PrintLn("null"); g := new T(); g.tag := 7; PrintLn("gebaut"); }
  return g;
}
fn main(): int64 { var t: T := Hol(); PrintLn(t.tag); return 0; }'

lauf "#1619: lokale Klassenvariable mit null beginnt bei null" \
'lokal null' 'import std.io;
type T = class { tag: int64; }
fn main(): int64 {
  var l: T := null;
  if (l == 0) { PrintLn("lokal null"); } else { PrintLn("lokal NICHT null"); }
  return 0;
}'

# Gegenprobe: eine Globale OHNE Startwert behaelt ihren eigenen Speicher —
# daran haengt der Bestand, das darf der Fix nicht mitnehmen.
lauf "#1619: Struct-Globale ohne Startwert bleibt ein Wert" '3' 'import std.io;
type P = struct { x: int64; y: int64 };
var gp: P;
fn main(): int64 { gp.x := 3; PrintLn(gp.x); return 0; }'

# ===========================================================================
# #1606 — Struct-Parameter werden auch ueber Modulgrenzen geprueft
# ===========================================================================
mkdir -p "$TMP/mylib"
cat > "$TMP/mylib/box.lyx" <<'EOF'
unit mylib.box;
pub type Box = struct { fd: int64; flags: int64 };
pub fn BoxTake(b: Box): int64 { return b.fd; }
EOF

cat > "$TMP/falsch.lyx" <<'EOF'
unit main;
import std.io;
import mylib.box;
fn main(): int64 {
  var n: int64 := 42;
  return BoxTake(n);
}
EOF
msg="$(timeout 200 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/falsch.lyx" -o "$TMP/falsch" 2>&1)"
if echo "$msg" | grep -q "falschem Typ im Aufruf von 'BoxTake'"; then
  ok "#1606: int64 statt Struct wird ueber die Modulgrenze gemeldet"
else
  no "#1606: int64 statt Struct" "keine Meldung — $(echo "$msg" | head -1)"
fi

cat > "$TMP/richtig.lyx" <<'EOF'
unit main;
import std.io;
import mylib.box;
fn main(): int64 {
  var b: Box;
  b.fd := 7; b.flags := 0;
  PrintLn(IntToStr(BoxTake(b)));
  return 0;
}
EOF
if timeout 200 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/richtig.lyx" -o "$TMP/richtig" >"$TMP/r.log" 2>&1; then
  got="$("$TMP/richtig" 2>&1 | tail -1)"
  [ "$got" = "7" ] && ok "#1606: der richtige Aufruf geht weiterhin durch" \
                   || no "#1606: richtiger Aufruf" "Ausgabe '$got'"
else
  no "#1606: richtiger Aufruf" "$(grep -m1 -iE 'error' "$TMP/r.log")"
fi

# ===========================================================================
# #1821 — eine Elternklasse, die es nicht gibt, wird gemeldet
# ===========================================================================
# Uebernommen aus regression/oop/test_tobject_explicit, der `extends TObject`
# benutzte. TObject als implizite Basisklasse ist ersatzlos entfallen; der Test
# dokumentierte damit eine Faehigkeit, die es nicht mehr gibt, und lag als
# "verrottet" in suite-broken.txt.
#
# Uebrig bleibt die Frage, die wirklich zaehlt: wird eine unbekannte
# Elternklasse GEMELDET? Sie war bis 1.1.11F durch keinen Test gedeckt — die
# Meldung gab es (sema.lyx, "unknown parent class"), niemand hat sie gemessen.
weist_ab "#1821 unbekannte Elternklasse wird gemeldet" "unknown parent class" \
'type MeineKlasse = class extends TObject {
  wert: int64;
  fn Setze(v: int64) { self.wert := v; }
};
fn main(): int64 { var o: MeineKlasse := new MeineKlasse(); o.Setze(42); return 0; }'

# Der gruene Zwilling ohne `extends` laeuft weiterhin: eine Klasse ohne
# ausdrueckliche Basis braucht keine.
lauf "#1821 Klasse ohne ausdrueckliche Basis laeuft" "42" \
'type OhneBasis = class {
  wert: int64;
  fn Setze(v: int64) { self.wert := v; }
  fn Hol(): int64 { return self.wert; }
};
fn main(): int64 { var o: OhneBasis := new OhneBasis(); o.Setze(42); PrintInt(o.Hol()); return 0; }'

# ===========================================================================
# #1748 — Feld eines Fremdtyps, dessen Methoden so heissen wie eigene
# ===========================================================================
# Gemeldet mit 1.1.6D: eine Klasse mit Feldern vom Typ TIntArray, die von einer
# Klasse mit VIRTUELLEN Methoden erbt, brach im Codegen ab —
# "undefined function 'Destroy'", also mit genau dem Namen, den die eigene
# Klasse UND der Feldtyp tragen. Ohne `virtual` in der Basis uebersetzte
# dieselbe Datei. vegagrid hat daraufhin die Felder durch rohe Speicherbloecke
# ersetzt.
#
# Mit 1.1.11E ist der Fall nicht mehr reproduzierbar — nachgemessen an der
# ORIGINALQUELLE (vegagrid/metrics.lyx, auf TIntArray zurueckgebaut): sie
# uebersetzt und rechnet richtig.
#
# EHRLICHKEIT ZUR AUSSAGEKRAFT: dieser Fall war beim Hinzufuegen GRUEN. Ob er
# vor dem Fix rot gewesen waere, laesst sich hier nicht zeigen — der aelteste
# verfuegbare Uebersetzer (src/lyxc_bootstrap) ist bereits 1.1.11B. Er sichert
# also die FORM gegen einen Rueckfall, er belegt keinen Fix.
lauf "#1748 Fremdtyp-Feld mit gleichnamigen Methoden unter virtueller Basis" "220" \
'import src.std.alloc;
type TZahlen = class {
  Data: int64;
  Length: int64;
  fn Create(n: int64): void {
    self.Data := 0; self.Length := 0;
    if (n <= 0) { return; }
    var p: int64 := alloc(n * 8);
    if (p == 0) { return; }
    self.Data := p; self.Length := n;
    var i: int64 := 0;
    while (i < n) { poke64(p + (i * 8), 0); i := i + 1; }
  }
  fn Destroy(): void { if (self.Data != 0) { free(self.Data, self.Length * 8); self.Data := 0; } }
  fn Resize(n: int64): void { self.Length := n; }
  fn Get(i: int64): int64 { if (i < 0) { return 0; } if (i >= self.Length) { return 0; } return peek64(self.Data + (i * 8)); }
  fn Put(i: int64, v: int64): void { if (i < 0) { return; } if (i >= self.Length) { return; } poke64(self.Data + (i * 8), v); }
};
type TBasis = class {
  Vorgabe: int64;
  Anzahl: int64;
  fn Create(): void { self.Vorgabe := 20; self.Anzahl := 0; }
  virtual fn Destroy(): void { }
  virtual fn Hoehe(r: int64): int64 { return self.Vorgabe; }
  virtual fn Gesamt(): int64 { return self.Anzahl * self.Vorgabe; }
};
type TAbleitung = class extends TBasis {
  _h: TZahlen;
  _cap: int64;
  fn Create(): void { self.Vorgabe := 20; self.Anzahl := 0; self._h := 0 as TZahlen; self._cap := 0; }
  override fn Destroy(): void { if (self._h != 0) { self._h.Destroy(); } }
  fn Resize(n: int64): void {
    if (self._h == 0) { self._h := new TZahlen(64); self._cap := 64; } else { self._h.Resize(64); }
    self.Anzahl := n;
  }
  override fn Hoehe(r: int64): int64 {
    var v: int64 := self._h.Get(r);
    if (v <= 0) { return self.Vorgabe; }
    return v;
  }
  fn SetzeHoehe(r: int64, h: int64): void { self._h.Put(r, h); }
  override fn Gesamt(): int64 {
    var s: int64 := 0; var i: int64 := 0;
    while (i < self.Anzahl) { s := s + self.Hoehe(i); i := i + 1; }
    return s;
  }
};
fn main(): int64 {
  var a: TAbleitung := new TAbleitung();
  a.Resize(10);
  a.SetzeHoehe(2, 40);
  PrintInt(a.Gesamt());
  a.Destroy();
  return 0;
}'

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
