#!/usr/bin/env bash
# tests/dtls13_record_2580_test.sh — #2580 Stufe 1 und 2: die Record-Schicht
# von DTLS 1.3 (RFC 9147 §4) und die Zusammensetzung der
# Handschlagnachrichten (§5.5).
#
# Geprueft wird mit ERZEUGTEN Paketen, ohne Netz und ohne Gegenstelle: die
# Stufen 1 und 2 aus #2580 sind genau deshalb die ersten, weil sie so
# prueffaehig sind.
#
# Der Punkt dieses Tests ist nicht "ein Record laesst sich wieder lesen".
# Das waere auch von einer Umsetzung erfuellt, die kein Fenster fuehrt, die
# Sequenznummer im Klartext schickt und bei umgeordneten Fragmenten den
# Inhalt verwuerfelt. Geprueft wird darum jedes Mal die WIRKUNG des Teils,
# auf den es ankommt:
#
#   * Die Sequenznummer im Kopf ist VERSCHLUESSELT (§4.2.3) -- belegt daran,
#     dass ein Kopf mit der KLARTEXT-Nummer das Tag bricht (der Kopf ist
#     AAD) und dass die Byte auf der Leitung nicht die Nummer sind.
#   * Das Wiederholungsfenster weist eine Doppelung ab, nimmt eine
#     UMORDNUNG aber an -- beide Richtungen, denn eine Umsetzung mit "nur
#     groesser als die letzte" wuerde die Doppelung auch abweisen und waere
#     im Netz unbrauchbar.
#   * Zusammengesetzt wird aus Fragmenten in BELIEBIGER Reihenfolge, mit
#     Doppelungen und Ueberlappung, und das Ergebnis wird BYTEWEISE
#     verglichen.
#
# Die Zaehler sind Teil des Nachweises: ohne sie liesse sich "abgewiesen"
# nicht von "nie angekommen" unterscheiden.
#
# ── Gegenproben, gefahren und beziffert ──────────────────────────────────
# Ein Test taugt nur, wenn er beim Weglassen des Geprueften rot wird. Beides
# ist gemessen:
#
#   Nummernverschleierung ausgebaut (das XOR im Schreiber entfernt):
#     nummer-im-klartext 8 statt 0 -- und zusaetzlich bricht die
#     Entschluesselung, weil der Leser die Klartextnummer fuer die AAD aus
#     der Maske zurueckrechnet. 20 von 26 Pruefungen rot.
#
#   Wiederholungsfenster ausgebaut (fensterPruefen gibt immer 0):
#     umordnung-abgewiesen 0 statt 1 (die Doppelung geht durch) und
#     "zu-alt" liefert 16 Byte statt -6 (ein 200 Records alter Record wird
#     angenommen). 5 Pruefungen rot.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/d.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
import std.alloc;
import std.net.dtls13;

// Zwei Zustaende, die ueber Puffer miteinander sprechen: einer schreibt,
// einer liest. Beide bekommen DASSELBE Geheimnis, aber in verschiedenen
// Richtungen -- genau so wie die zwei Seiten einer Verbindung.
fn paarBauen(secret: int64, keyLen: int64, aead: int64,
             schreiberOut: int64, leserOut: int64): bool {
  var w: int64 := DtlsNeu(0);
  var r: int64 := DtlsNeu(0);
  if (w == 0 || r == 0) { return false; }
  if (!DtlsSchluesselSetzen(w, DtlsSchreiben(), 2, secret, 32, keyLen, aead)) { return false; }
  if (!DtlsSchluesselSetzen(r, DtlsLesen(), 2, secret, 32, keyLen, aead)) { return false; }
  poke64(schreiberOut, w);
  poke64(leserOut, r);
  return true;
}

fn gleich(a: int64, b: int64, n: int64): int64 {
  var i: int64 := 0;
  while (i < n) {
    if (peek8(a + i) != peek8(b + i)) { return 0; }
    i := i + 1;
  }
  return 1;
}

fn main(): int64 {
  var secret: int64 := alloc(48);
  var i: int64 := 0;
  while (i < 48) { poke8(secret + i, (i * 31 + 7) & 255); i := i + 1; }

  var typOut: int64 := alloc(8);
  var verbr: int64 := alloc(8);
  var rumpf: int64 := alloc(20480);
  var paket: int64 := alloc(20480);

  // ── Klartextform (Epoche 0) ────────────────────────────────────────
  var k: int64 := DtlsNeu(0);
  var kl: int64 := DtlsNeu(0);
  var nutz: pchar := "ClientHello-Ersatz"c;
  var n1: int64 := DtlsRecordSchreiben(k, 22, nutz as int64, StrLen(nutz), paket, 20480);
  Print("klartext-laenge "); PrintInt(n1); PrintLn("");
  var g1: int64 := DtlsRecordLesen(kl, paket, n1, typOut, rumpf, 20480, verbr);
  Print("klartext-gelesen "); PrintInt(g1);
  Print(" typ "); PrintInt(peek64(typOut));
  Print(" inhalt-gleich "); PrintInt(gleich(rumpf, nutz as int64, g1));
  PrintLn("");

  // ── Verschluesselt, drei AEAD-Arten ────────────────────────────────
  var wp: int64 := alloc(8);
  var rp: int64 := alloc(8);
  var arten: int64 := alloc(24);
  poke64(arten, 16); poke64(arten + 8, 32); poke64(arten + 16, 32);
  var aeads: int64 := alloc(24);
  poke64(aeads, 1); poke64(aeads + 8, 1); poke64(aeads + 16, 2);
  var a: int64 := 0;
  while (a < 3) {
    if (!paarBauen(secret, peek64(arten + a * 8), peek64(aeads + a * 8), wp, rp)) {
      PrintLn("SCHLUESSELFEHLER"); return 1;
    }
    var w: int64 := peek64(wp);
    var r: int64 := peek64(rp);
    var text: pchar := "DTLS 1.3 Nutzdaten"c;
    var nn: int64 := DtlsRecordSchreiben(w, 23, text as int64, StrLen(text), paket, 20480);
    var gg: int64 := DtlsRecordLesen(r, paket, nn, typOut, rumpf, 20480, verbr);
    Print("aead "); PrintInt(a);
    Print(" geschrieben "); PrintInt(nn);
    Print(" gelesen "); PrintInt(gg);
    Print(" typ "); PrintInt(peek64(typOut));
    Print(" gleich "); PrintInt(gleich(rumpf, text as int64, gg));
    Print(" verbraucht "); PrintInt(peek64(verbr));
    PrintLn("");
    DtlsFrei(w); DtlsFrei(r);
    a := a + 1;
  }

  // ── Sequenznummer im Kopf: verschleiert und durch AAD gedeckt ──────
  if (!paarBauen(secret, 16, 1, wp, rp)) { PrintLn("SCHLUESSELFEHLER"); return 1; }
  var w2: int64 := peek64(wp);
  var r2: int64 := peek64(rp);
  var klar: int64 := 0;
  var runde: int64 := 0;
  while (runde < 8) {
    var nx: int64 := DtlsRecordSchreiben(w2, 23, secret, 32, paket, 20480);
    // Im Kopf stehen Byte 1 und 2 fuer die Nummer. Steht dort die KLARTEXT-
    // Nummer, ist nichts verschleiert.
    var hoch: int64 := peek8(paket + 1) & 0xFF;
    var tief: int64 := peek8(paket + 2) & 0xFF;
    if (hoch == 0 && tief == runde) { klar := klar + 1; }
    DtlsRecordLesen(r2, paket, nx, typOut, rumpf, 20480, verbr);
    runde := runde + 1;
  }
  Print("nummer-im-klartext "); PrintInt(klar); PrintLn("");

  // Kopf mit der Klartextnummer ueberschreiben: der Kopf ist AAD, also MUSS
  // das Tag brechen (-4). Waere die Nummer nicht Teil der AAD, kaeme hier
  // ein gueltiger Record mit falscher Nummer durch.
  if (!paarBauen(secret, 16, 1, wp, rp)) { PrintLn("SCHLUESSELFEHLER"); return 1; }
  var w3: int64 := peek64(wp);
  var r3: int64 := peek64(rp);
  var n3: int64 := DtlsRecordSchreiben(w3, 23, secret, 32, paket, 20480);
  poke8(paket + 1, 0);
  poke8(paket + 2, 0);
  Print("kopf-verfaelscht "); PrintInt(DtlsRecordLesen(r3, paket, n3, typOut, rumpf, 20480, verbr)); PrintLn("");

  // ── Fenster: Doppelung ab, Umordnung an ───────────────────────────
  if (!paarBauen(secret, 16, 1, wp, rp)) { PrintLn("SCHLUESSELFEHLER"); return 1; }
  var w4: int64 := peek64(wp);
  var r4: int64 := peek64(rp);
  // Fuenf Records erzeugen und einzeln aufbewahren.
  var lagen: int64 := alloc(5 * 8);
  var laengen: int64 := alloc(5 * 8);
  var speicher: int64 := alloc(5 * 4096);
  var e: int64 := 0;
  while (e < 5) {
    var ort: int64 := speicher + e * 4096;
    var le: int64 := DtlsRecordSchreiben(w4, 23, secret, 16 + e, ort, 4096);
    poke64(lagen + e * 8, ort);
    poke64(laengen + e * 8, le);
    e := e + 1;
  }
  // Reihenfolge 2, 0, 4, 1, 3 -- und 0 danach ein zweites Mal.
  var folge: int64 := alloc(6 * 8);
  poke64(folge, 2); poke64(folge + 8, 0); poke64(folge + 16, 4);
  poke64(folge + 24, 1); poke64(folge + 32, 3); poke64(folge + 40, 0);
  var angenommen: int64 := 0;
  var abgewiesen: int64 := 0;
  var f: int64 := 0;
  while (f < 6) {
    var idx: int64 := peek64(folge + f * 8);
    var rc: int64 := DtlsRecordLesen(r4, peek64(lagen + idx * 8),
                                     peek64(laengen + idx * 8),
                                     typOut, rumpf, 20480, verbr);
    if (rc >= 0) { angenommen := angenommen + 1; } else { abgewiesen := abgewiesen + 1; }
    f := f + 1;
  }
  Print("umordnung-angenommen "); PrintInt(angenommen); PrintLn("");
  Print("umordnung-abgewiesen "); PrintInt(abgewiesen); PrintLn("");
  Print("zaehler-wiederholt "); PrintInt(DtlsZaehlerWiederholt(r4)); PrintLn("");
  Print("fenster-hoch "); PrintInt(DtlsFensterHoch(r4)); PrintLn("");

  // ── Fenster: zu alt ───────────────────────────────────────────────
  // Der Schreiber springt weit nach vorn, der Leser nimmt das an; der alte
  // Record von Nummer 0 ist danach links vom Fenster.
  if (!paarBauen(secret, 16, 1, wp, rp)) { PrintLn("SCHLUESSELFEHLER"); return 1; }
  var w5: int64 := peek64(wp);
  var r5: int64 := peek64(rp);
  var alt: int64 := alloc(4096);
  var altLen: int64 := DtlsRecordSchreiben(w5, 23, secret, 16, alt, 4096);
  var sprung: int64 := 0;
  while (sprung < 200) {
    DtlsRecordSchreiben(w5, 23, secret, 16, paket, 20480);
    sprung := sprung + 1;
  }
  var neu: int64 := DtlsRecordSchreiben(w5, 23, secret, 16, paket, 20480);
  Print("weit-vorn "); PrintInt(DtlsRecordLesen(r5, paket, neu, typOut, rumpf, 20480, verbr) >= 0); PrintLn("");
  Print("zu-alt "); PrintInt(DtlsRecordLesen(r5, alt, altLen, typOut, rumpf, 20480, verbr)); PrintLn("");
  Print("zaehler-ausserfenster "); PrintInt(DtlsZaehlerAusserFenster(r5)); PrintLn("");

  // ── Fragmentierung und Zusammensetzung ────────────────────────────
  if (!paarBauen(secret, 16, 1, wp, rp)) { PrintLn("SCHLUESSELFEHLER"); return 1; }
  var w6: int64 := peek64(wp);
  var r6: int64 := peek64(rp);
  var lang: int64 := alloc(3000);
  var q: int64 := 0;
  while (q < 3000) { poke8(lang + q, (q * 17 + 3) & 255); q := q + 1; }
  var flug: int64 := alloc(20480);
  var fl: int64 := DtlsHsSenden(w6, 11, lang, 3000, 400, flug, 20480);
  Print("flug-laenge "); PrintInt(fl > 0); PrintLn("");

  // Die Records des Flugs auftrennen -- ein Datagramm je Record, so wie sie
  // ueber UDP gingen.
  var rLagen: int64 := alloc(64 * 8);
  var rLaengen: int64 := alloc(64 * 8);
  var anz: int64 := 0;
  var pos: int64 := 0;
  while (pos < fl && anz < 64) {
    var ctl: int64 := ((peek8(flug + pos + 3) & 0xFF) << 8) | (peek8(flug + pos + 4) & 0xFF);
    poke64(rLagen + anz * 8, flug + pos);
    poke64(rLaengen + anz * 8, 5 + ctl);
    pos := pos + 5 + ctl;
    anz := anz + 1;
  }
  Print("fragmente-im-flug "); PrintInt(anz); PrintLn("");

  // RUECKWAERTS einspeisen, und das mittlere Fragment doppelt. Umordnung und
  // Doppelung in einem Durchgang -- genau die Lage, die auf einer
  // verlustfreien Schleife nie entsteht.
  var idx2: int64 := anz - 1;
  while (idx2 >= 0) {
    var gl: int64 := DtlsRecordLesen(r6, peek64(rLagen + idx2 * 8),
                                     peek64(rLaengen + idx2 * 8),
                                     typOut, rumpf, 20480, verbr);
    if (gl >= 0) { DtlsHsFragmentEinspeisen(r6, rumpf, gl); }
    if (idx2 == anz / 2) {
      // Dasselbe Fragment ein zweites Mal: der Record wird vom Fenster
      // abgewiesen, das Fragment also gar nicht mehr gesehen. Darum wird
      // hier der KLARTEXT noch einmal eingespeist -- so entsteht die
      // Doppelung auf der Nachrichtenebene, die §5.5 nennt.
      DtlsHsFragmentEinspeisen(r6, rumpf, gl);
    }
    idx2 := idx2 - 1;
  }
  Print("nachricht-fertig "); PrintInt(DtlsHsFertig(r6)); PrintLn("");
  Print("nachricht-typ "); PrintInt(DtlsHsTyp(r6)); PrintLn("");
  Print("nachricht-laenge "); PrintInt(DtlsHsLen(r6)); PrintLn("");
  Print("nachricht-gleich "); PrintInt(gleich(DtlsHsRumpf(r6), lang, 3000)); PrintLn("");
  Print("zaehler-doppelt-positiv "); PrintInt(DtlsZaehlerDoppelt(r6) > 0); PrintLn("");
  Print("verbrauchen "); PrintInt(DtlsHsVerbrauchen(r6)); PrintLn("");
  Print("zaehler-nachrichten "); PrintInt(DtlsZaehlerNachrichten(r6)); PrintLn("");

  // ── Nachricht der Laenge 0 ────────────────────────────────────────
  if (!paarBauen(secret, 16, 1, wp, rp)) { PrintLn("SCHLUESSELFEHLER"); return 1; }
  var w7: int64 := peek64(wp);
  var r7: int64 := peek64(rp);
  var fl0: int64 := DtlsHsSenden(w7, 5, secret, 0, 400, flug, 20480);
  var g0: int64 := DtlsRecordLesen(r7, flug, fl0, typOut, rumpf, 20480, verbr);
  DtlsHsFragmentEinspeisen(r7, rumpf, g0);
  Print("leere-nachricht-fertig "); PrintInt(DtlsHsFertig(r7)); PrintLn("");
  Print("leere-nachricht-typ "); PrintInt(DtlsHsTyp(r7)); PrintLn("");

  // ── Widerspruch zwischen zwei Fragmenten ──────────────────────────
  // Zwei Fragmente derselben message_seq nennen verschiedene Gesamtlaengen.
  var wid: int64 := alloc(64);
  poke8(wid, 11);
  poke8(wid + 1, 0); poke8(wid + 2, 0); poke8(wid + 3, 20);   // laenge 20
  poke8(wid + 4, 0); poke8(wid + 5, 7);                        // message_seq 7
  poke8(wid + 6, 0); poke8(wid + 7, 0); poke8(wid + 8, 0);     // offset 0
  poke8(wid + 9, 0); poke8(wid + 10, 0); poke8(wid + 11, 4);   // fragment 4
  poke8(wid + 12, 1); poke8(wid + 13, 2); poke8(wid + 14, 3); poke8(wid + 15, 4);
  var r8: int64 := DtlsNeu(0);
  Print("widerspruch-erstes "); PrintInt(DtlsHsFragmentEinspeisen(r8, wid, 16)); PrintLn("");
  poke8(wid + 3, 24);                                          // andere Laenge
  Print("widerspruch-zweites "); PrintInt(DtlsHsFragmentEinspeisen(r8, wid, 16)); PrintLn("");
  return 0;
}
LYXEOF

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/d.lyx" -o "$TMP/d" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht:"; grep -m5 -iE 'error|parse' "$TMP/log"; exit 1
fi
[ -x "$TMP/d" ] || { echo "FAIL kein Erzeugnis (#1682)"; exit 1; }
( ulimit -v 4000000 -c 0; "$TMP/d" ) > "$TMP/aus.txt" 2>&1
RC=$?
sed 's/^/    /' "$TMP/aus.txt"

P=0; F=0
ok()  { echo "PASS $1"; P=$((P+1)); }
bad() { echo "FAIL $1${2:+ -- $2}"; F=$((F+1)); }
[ "$RC" = 0 ] || bad "Lauf" "Exitcode $RC"
zeile() {  # name, erwartete restliche Zeile
  ist="$(grep -m1 "^$1 " "$TMP/aus.txt" | cut -d' ' -f2-)"
  if [ "${ist:-fehlt}" = "$2" ]; then ok "$1: $2"; else bad "$1" "ist '${ist:-fehlt}', soll '$2'"; fi
}

# Klartextform: 13 Byte Kopf + 18 Byte Nutzlast
zeile klartext-laenge 31
zeile klartext-gelesen "18 typ 22 inhalt-gleich 1"

# Verschluesselt: 5 Byte Kopf + 18 Nutzlast + 1 Typbyte + 16 Tag = 40
# Drei AEAD-Arten, jede mit ihrer eigenen Zeile. Die Laenge 40 ist kein
# Richtwert, sondern gerechnet: 5 Byte Kopf + 18 Nutzlast + 1 Typbyte +
# 16 Tag. Weicht sie ab, hat sich der Kopf oder die Polsterung geaendert.
zeile aead "0 geschrieben 40 gelesen 18 typ 23 gleich 1 verbraucht 40"
ist2="$(grep -m1 '^aead 1 ' "$TMP/aus.txt" | cut -d' ' -f3-)"
[ "$ist2" = "geschrieben 40 gelesen 18 typ 23 gleich 1 verbraucht 40" ] \
  && ok "aead 1 (AES-256-GCM)" || bad "aead 1" "ist '$ist2'"
ist3="$(grep -m1 '^aead 2 ' "$TMP/aus.txt" | cut -d' ' -f3-)"
[ "$ist3" = "geschrieben 40 gelesen 18 typ 23 gleich 1 verbraucht 40" ] \
  && ok "aead 2 (ChaCha20-Poly1305)" || bad "aead 2" "ist '$ist3'"

# Die Nummer darf in KEINEM der acht Koepfe im Klartext stehen.
zeile nummer-im-klartext 0
# Kopf mit Klartextnummer: Tag bricht (-4).
zeile kopf-verfaelscht -4

# Fuenf umgeordnete Records werden angenommen, die Doppelung nicht.
zeile umordnung-angenommen 5
zeile umordnung-abgewiesen 1
zeile zaehler-wiederholt 1
zeile fenster-hoch 4

# Weit vorn angenommen, der alte Record danach zu alt (-6).
zeile weit-vorn 1
zeile zu-alt -6
zeile zaehler-ausserfenster 1

# 3000 Byte bei MTU 400: mehrere Fragmente, rueckwaerts eingespeist, eines
# doppelt -- und am Ende stimmt jedes Byte.
zeile flug-laenge 1
zeile nachricht-fertig 1
zeile nachricht-typ 11
zeile nachricht-laenge 3000
zeile nachricht-gleich 1
zeile zaehler-doppelt-positiv 1
zeile verbrauchen 0
zeile zaehler-nachrichten 1

# Eine Nachricht der Laenge 0 hat GENAU EIN Fragment.
zeile leere-nachricht-fertig 1
zeile leere-nachricht-typ 5

# Zwei Fragmente mit verschiedener Gesamtlaenge: -10, nicht zusammengesetzt.
zeile widerspruch-erstes 0
zeile widerspruch-zweites -10

echo "--- $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
echo "ALL PASS"
