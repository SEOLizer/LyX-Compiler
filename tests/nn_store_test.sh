#!/usr/bin/env bash
# tests/nn_store_test.sh — std.nn_store: Netze in SQLite ablegen und zurueckholen.
#
# Geprueft wird die STRECKE Lyx -> libsqlite3 -> Datei -> zurueck, die kein
# Compilertest abdeckt: dass die Bytefolge unveraendert durch die BLOB-Spalte
# geht und das zurueckgeholte Netz dieselben Ausgaben liefert.
#
# Zwei Punkte brauchen die Datenbank von aussen und stehen darum hier statt in
# einem .lyx-Test:
#   1. Die Nebenspalten werden mit dem sqlite3-Client gegengelesen -- nur der
#      sagt, was wirklich auf der Platte steht.
#   2. Eine VERDREHTE Bytefolge wird per UPDATE erzeugt. Dass ein unversehrter
#      Eintrag laedt, ist die eine Haelfte; dass der verdrehte abgewiesen wird,
#      die andere. Ohne beide Haelften wuerde auch eine Ablage bestehen, die
#      die Pruefsumme nie vergleicht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

if [ ! -e /lib/x86_64-linux-gnu/libsqlite3.so.0 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 ]; then
  echo "SKIP libsqlite3.so.0 nicht gefunden"
  echo "--- 0 PASS, 0 FAIL"; exit 0
fi

DBF="$TMP/nn.db"

# ===========================================================================
# Teil 1: Sichern, Angaben, Zurueckholen, Ersetzen, Loeschen
# ===========================================================================

cat > "$TMP/a.lyx" <<EOF
unit main;

import std.nn;
import std.nn_io;
import std.nn_store;
import std.db.sqlite;
import std.math;
import std.alloc;

fn SV(p: int64, i: int64, v: f64): void { pokef64(p + i * 8, v); }

fn buildNet(seed: int64): int64 {
  var net: int64 := NnNew(3, 2);
  NnSeed(net, seed);
  var ok: bool := NnAddDense(net, 5, NN_ACT_TANH);
  ok := NnAddDense(net, 2, NN_ACT_SOFTMAX);
  ok := NnInitXavier(net);
  ok := NnSetLoss(net, NN_LOSS_CE);
  ok := NnSetOptimizer(net, NN_OPT_ADAM);
  NnSetLearningRate(net, 0.04);
  return net;
}

fn main(): int64 {
  var db: int64 := SQLiteOpen("$DBF"c);
  if (db == 0) { PrintStr("OPENFAIL\n"c); return 1; }
  if (NnStoreInit(db) == false) { PrintStr("INITFAIL\n"c); return 1; }

  var net: int64 := buildNet(2026);
  var x: int64 := alloc(3 * 8);
  SV(x, 0, 0.4);
  SV(x, 1, 0.9);
  SV(x, 2, 0.2);
  // ein paar Schritte, damit der Optimiererzustand nicht null ist
  var Y: int64 := alloc(2 * 8);
  SV(Y, 0, 1.0);
  SV(Y, 1, 0.0);
  var lv: f64 := NnTrain(net, x, Y, 1, 1, 25);
  var o: int64 := NnForward(net, x);

  if (NnStoreSave(db, "modell-a"c, net, true) == false) {
    PrintStr("SAVEFAIL "c); PrintInt(NnStoreError()); PrintStr("\n"c);
    return 1;
  }
  // zweites Netz, anderer Name, ohne Optimiererzustand
  var net2: int64 := buildNet(777);
  var ok2: bool := NnStoreSave(db, "modell-b"c, net2, false);

  PrintStr("COUNT "c); PrintInt(NnStoreCount(db)); PrintStr("\n"c);
  PrintStr("EXISTS "c); PrintInt(NnStoreExists(db, "modell-a"c) as int64);
  PrintStr(" "c); PrintInt(NnStoreExists(db, "modell-x"c) as int64); PrintStr("\n"c);
  PrintStr("META "c);
  PrintInt(NnStoreInputDim(db, "modell-a"c)); PrintStr(" "c);
  PrintInt(NnStoreOutputDim(db, "modell-a"c)); PrintStr(" "c);
  PrintInt(NnStoreLayerCount(db, "modell-a"c)); PrintStr(" "c);
  PrintInt(NnStoreParamCount(db, "modell-a"c)); PrintStr(" "c);
  PrintInt(NnStoreByteCount(db, "modell-a"c)); PrintStr(" "c);
  PrintInt(NnStoreHasOptState(db, "modell-a"c)); PrintStr(" "c);
  PrintInt(NnStoreHasOptState(db, "modell-b"c)); PrintStr("\n"c);
  PrintStr("METAMISSING "c);
  PrintInt(NnStoreOutputDim(db, "modell-x"c)); PrintStr(" "c);
  PrintInt(NnStoreError()); PrintStr("\n"c);
  PrintStr("NAMES "c);
  PrintStr(NnStoreNameAt(db, 0)); PrintStr(" "c);
  PrintStr(NnStoreNameAt(db, 1)); PrintStr(" "c);
  PrintInt(NnStoreNameAt(db, 2) as int64); PrintStr("\n"c);

  // Zurueckholen: dieselbe Ausgabe auf derselben Eingabe
  var back: int64 := NnStoreLoad(db, "modell-a"c);
  if (back == 0) {
    PrintStr("LOADFAIL "c); PrintInt(NnStoreError()); PrintStr("\n"c);
    return 1;
  }
  var o2: int64 := NnForward(back, x);
  PrintStr("OUT "c);
  PrintInt(((NnOutputAt(net, 0) - NnOutputAt(back, 0)) == 0.0) as int64);
  PrintStr(" "c);
  PrintInt((NnStepCount(back) == NnStepCount(net)) as int64);
  PrintStr("\n"c);
  // Gewichte feldweise
  var worst: f64 := 0.0;
  var k: int64 := 0;
  while (k < 2) {
    var r: int64 := 0;
    while (r < NnLayerOutDim(net, k)) {
      var c: int64 := 0;
      while (c < NnLayerInDim(net, k)) {
        var d: f64 := AbsF64(NnGetWeight(net, k, r, c) - NnGetWeight(back, k, r, c));
        if (d > worst) { worst := d; }
        c := c + 1;
      }
      var db2: f64 := AbsF64(NnGetBias(net, k, r) - NnGetBias(back, k, r));
      if (db2 > worst) { worst := db2; }
      r := r + 1;
    }
    k := k + 1;
  }
  PrintStr("WORST "c); PrintInt((worst == 0.0) as int64); PrintStr("\n"c);

  // Ersetzen unter demselben Namen: ein Eintrag bleibt, Inhalt ist der neue
  var fresh: int64 := buildNet(31415);
  var ok3: bool := NnStoreSave(db, "modell-a"c, fresh, false);
  PrintStr("REPLACE "c); PrintInt(ok3 as int64);
  PrintStr(" "c); PrintInt(NnStoreCount(db));
  var back2: int64 := NnStoreLoad(db, "modell-a"c);
  PrintStr(" "c);
  PrintInt((NnGetWeight(back2, 0, 0, 0) == NnGetWeight(fresh, 0, 0, 0)) as int64);
  PrintStr(" "c);
  PrintInt(NnStoreHasOptState(db, "modell-a"c));
  PrintStr("\n"c);

  // Loeschen
  PrintStr("DELETE "c); PrintInt(NnStoreDelete(db, "modell-b"c) as int64);
  PrintStr(" "c); PrintInt(NnStoreDelete(db, "modell-b"c) as int64);
  PrintStr(" "c); PrintInt(NnStoreError());
  PrintStr(" "c); PrintInt(NnStoreCount(db));
  PrintStr("\n"c);
  PrintStr("LOADGONE "c); PrintInt(NnStoreLoad(db, "modell-b"c));
  PrintStr(" "c); PrintInt(NnStoreError()); PrintStr("\n"c);
  // Nullargumente
  PrintStr("ARGS "c); PrintInt(NnStoreLoad(db, 0 as pchar));
  PrintStr(" "c); PrintInt(NnStoreError());
  PrintStr(" "c); PrintInt(NnStoreSave(0, "x"c, net, true) as int64);
  PrintStr("\n"c);

  SQLiteClose(db);
  return 0;
}
EOF

if ! "$LYXC" --std-path="$ROOT" "$TMP/a.lyx" -o "$TMP/a" >"$TMP/a.log" 2>&1; then
  no "std.nn_store uebersetzt" "$(tail -3 "$TMP/a.log" | tr '\n' ' ')"
  echo "--- $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "std.nn_store uebersetzt"

OUT="$(ulimit -c 0; timeout 120 "$TMP/a" 2>&1)"
get() { printf '%s\n' "$OUT" | grep "^$1 " | head -1 | cut -d' ' -f2-; }

[ "$(get COUNT)" = "2" ] && ok "zwei Eintraege nach zwei Namen" \
  || no "zwei Eintraege nach zwei Namen" "COUNT='$(get COUNT)'"
[ "$(get EXISTS)" = "1 0" ] && ok "NnStoreExists trennt vorhanden und fehlend" \
  || no "NnStoreExists trennt vorhanden und fehlend" "'$(get EXISTS)'"
# 3 Eingaenge, 2 Ausgaenge, 2 Schichten, 3*5+5 + 5*2+2 = 32 Parameter,
# Bytefolge: (5 + 4 + 11 + 32 + 1 + 64 + 1) * 8 = 942 ... nachgerechnet:
# Felder = 5 Kopf + 2*2 Schichten + 11 Schwanz + 32 Parameter
#          + 1 Zaehler + 64 Optimiererwerte + 1 Pruefsumme = 118 -> 944 Byte
[ "$(get META)" = "3 2 2 32 944 1 0" ] && ok "Nebenspalten beschreiben das Netz" \
  || no "Nebenspalten beschreiben das Netz" "'$(get META)' erwartet '3 2 2 32 944 1 0'"
[ "$(get METAMISSING)" = "-1 3" ] && ok "fehlender Name: -1 und NNSTORE_E_NOTFOUND" \
  || no "fehlender Name: -1 und NNSTORE_E_NOTFOUND" "'$(get METAMISSING)'"
[ "$(get NAMES)" = "modell-a modell-b 0" ] && ok "NnStoreNameAt zaehlt den Bestand auf" \
  || no "NnStoreNameAt zaehlt den Bestand auf" "'$(get NAMES)'"
[ "$(get OUT)" = "1 1" ] && ok "zurueckgeholtes Netz: gleiche Ausgabe, gleicher Schrittzaehler" \
  || no "zurueckgeholtes Netz: gleiche Ausgabe, gleicher Schrittzaehler" "'$(get OUT)'"
[ "$(get WORST)" = "1" ] && ok "alle Gewichte und Biase bitgleich" \
  || no "alle Gewichte und Biase bitgleich" "'$(get WORST)'"
[ "$(get REPLACE)" = "1 2 1 0" ] && ok "gleicher Name ersetzt den Eintrag" \
  || no "gleicher Name ersetzt den Eintrag" "'$(get REPLACE)' erwartet '1 2 1 0'"
[ "$(get DELETE)" = "1 0 3 1" ] && ok "Loeschen einmal wahr, dann NNSTORE_E_NOTFOUND" \
  || no "Loeschen einmal wahr, dann NNSTORE_E_NOTFOUND" "'$(get DELETE)'"
[ "$(get LOADGONE)" = "0 3" ] && ok "geloeschtes Netz laedt nicht mehr" \
  || no "geloeschtes Netz laedt nicht mehr" "'$(get LOADGONE)'"
[ "$(get ARGS)" = "0 1 0" ] && ok "Nullargumente werden gemeldet" \
  || no "Nullargumente werden gemeldet" "'$(get ARGS)'"

# ===========================================================================
# Teil 2: gegengelesen mit dem sqlite3-Client -- nur der sagt, was auf der
# Platte steht
# ===========================================================================

if command -v sqlite3 >/dev/null 2>&1; then
  COLS="$(sqlite3 "$DBF" "SELECT name, input_dim, output_dim, layers, params, length(state) FROM nn_models ORDER BY name" 2>/dev/null)"
  if [ "$COLS" = "modell-a|3|2|2|32|424" ]; then
    ok "Client liest Zeile und BLOB-Laenge des ersetzten Netzes"
  else
    no "Client liest Zeile und BLOB-Laenge des ersetzten Netzes" "'$COLS'"
  fi
  TYP="$(sqlite3 "$DBF" "SELECT typeof(state) FROM nn_models LIMIT 1" 2>/dev/null)"
  [ "$TYP" = "blob" ] && ok "Spalte state ist ein BLOB" \
    || no "Spalte state ist ein BLOB" "typeof='$TYP'"
else
  echo "SKIP sqlite3-Client nicht vorhanden -- Gegenlesen entfaellt"
fi

# ===========================================================================
# Teil 3: verdrehte Bytefolge wird abgewiesen
#
# Erst wird belegt, dass der unversehrte Eintrag LAEDT; dann wird ein Byte
# mitten in der Spalte gekippt und belegt, dass derselbe Eintrag NICHT mehr
# laedt. Nur beide Haelften zusammen messen die Pruefsumme.
# ===========================================================================

cat > "$TMP/b.lyx" <<EOF
unit main;

import std.nn;
import std.nn_store;
import std.db.sqlite;
import std.alloc;

fn main(): int64 {
  var db: int64 := SQLiteOpen("$DBF"c);
  var net: int64 := NnStoreLoad(db, "modell-a"c);
  PrintStr("LOAD "c);
  PrintInt((net != 0) as int64);
  PrintStr(" "c);
  PrintInt(NnStoreError());
  PrintStr("\n"c);
  SQLiteClose(db);
  if (net == 0) { return 1; }
  return 0;
}
EOF

if ! "$LYXC" --std-path="$ROOT" "$TMP/b.lyx" -o "$TMP/b" >"$TMP/b.log" 2>&1; then
  no "Pruefprogramm uebersetzt" "$(tail -3 "$TMP/b.log" | tr '\n' ' ')"
  echo "--- $PASS PASS, $FAIL FAIL"; exit 1
fi

INTACT="$(ulimit -c 0; timeout 60 "$TMP/b" 2>&1 | grep '^LOAD ')"
[ "$INTACT" = "LOAD 1 0" ] && ok "unversehrter Eintrag laedt" \
  || no "unversehrter Eintrag laedt" "'$INTACT'"

# Verdreht wird mit einem eigenen Programm, nicht mit dem Client: `||` in
# SQLite macht aus zwei BLOBs TEXT und schneidet am ersten Nullbyte ab -- die
# Spalte war danach 9 Byte lang und die Pruefung haette das Abschneiden
# gemessen, nicht die Pruefsumme.
cat > "$TMP/c.lyx" <<EOF
unit main;

import std.db.sqlite;
import std.alloc;

fn main(): int64 {
  var db: int64 := SQLiteOpen("$DBF"c);
  var sel: int64 := SQLiteStmtPrepare(db, "SELECT state FROM nn_models WHERE name = ?"c);
  var ok: bool := SQLiteBindStr(sel, 1, "modell-a"c);
  if (SQLiteStmtStep(sel) != SQLITE_ROW) { PrintStr("NOROW\n"c); return 1; }
  var ptr: int64 := SQLiteColumnBlob(sel, 0);
  var len: int64 := SQLiteColumnBytes(sel, 0);
  var buf: int64 := alloc(len);
  var i: int64 := 0;
  while (i < len) {
    poke8(buf + i, peek8(ptr + i));
    i := i + 1;
  }
  SQLiteStmtFinalize(sel);
  // ein Byte mitten in den Gewichten kippen -- Laenge bleibt gleich
  poke8(buf + 200, peek8(buf + 200) ^ 1);
  var upd: int64 := SQLiteStmtPrepare(db, "UPDATE nn_models SET state = ? WHERE name = ?"c);
  ok := SQLiteBindBlob(upd, 1, buf, len);
  ok := SQLiteBindStr(upd, 2, "modell-a"c);
  var rc: int64 := SQLiteStmtStep(upd);
  SQLiteStmtFinalize(upd);
  PrintStr("FLIPPED "c);
  PrintInt((rc == SQLITE_DONE) as int64);
  PrintStr(" "c);
  PrintInt(len);
  PrintStr("\n"c);
  SQLiteClose(db);
  return 0;
}
EOF

if "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >"$TMP/c.log" 2>&1; then
  FLIP="$(ulimit -c 0; timeout 60 "$TMP/c" 2>&1 | grep '^FLIPPED ')"
  if [ "$FLIP" = "FLIPPED 1 424" ]; then
    ok "ein Byte gekippt, Laenge unveraendert"
  else
    no "ein Byte gekippt, Laenge unveraendert" "'$FLIP'"
  fi
  BROKEN="$(ulimit -c 0; timeout 60 "$TMP/b" 2>&1 | grep '^LOAD ')"
  if [ "$BROKEN" = "LOAD 0 5" ]; then
    ok "verdrehte Bytefolge wird mit NNSTORE_E_CORRUPT abgewiesen"
  else
    no "verdrehte Bytefolge wird mit NNSTORE_E_CORRUPT abgewiesen" "'$BROKEN'"
  fi
else
  no "Verdrehprogramm uebersetzt" "$(tail -3 "$TMP/c.log" | tr '\n' ' ')"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
