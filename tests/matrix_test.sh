#!/usr/bin/env bash
# tests/matrix_test.sh — std/matrix.lyx (Vec3, Vec4, Mat3, Mat4 in f64).
#
# ZUR AUSSAGEKRAFT
#
# Eine Matrixbibliothek laesst sich leicht so testen, dass der Test immer gruen
# ist: Einheitsmatrix mal Einheitsmatrix bleibt Einheitsmatrix, egal wie falsch
# multipliziert wird. Deshalb wird hier gegen ASYMMETRISCHE Matrizen gerechnet,
# bei denen jede vertauschte Zeile und Spalte auffaellt, und es werden
# Eigenschaften geprueft, die eine kaputte Implementierung nicht zufaellig
# erfuellt:
#
#   - A * A^-1 == I               faengt jeden Fehler in Det, Adjunkte, Vorzeichen
#   - det(A*B) == det(A)*det(B)   faengt Fehler in Det, die sich sonst wegkuerzen
#   - (A*B)^T == B^T * A^T        faengt vertauschte Zeilen/Spalten in Mul
#   - A*B != B*A                  faengt eine Mul, die in Wahrheit symmetrisch ist
#   - Rotation bildet Achse auf Achse ab (Richtung, nicht nur Betrag)
#   - MulDir3 ignoriert Translation, MulPoint3 nicht  (der Weg, nicht das Ergebnis)
#
# ZWEITENS die Fehlerfaelle. Sie sind der eigentliche Grund fuer diesen Test:
# eine singulaere Matrix, eine Division durch w == 0, ein entarteter
# Sichtkegel. An jeder dieser Stellen waere ein stiller Default (Einheitsmatrix
# zurueckgeben, w auf 1 setzen) plausibel und wuerde jede Fehlbedienung in eine
# unbemerkte Fehlrechnung weiter hinten verwandeln. Geprueft wird deshalb, dass
# gemeldet wird.
#
# WAS DIESER TEST NICHT MISST: die Genauigkeit von SinF64/CosF64/TanF64 aus
# std.math. Die Winkelfaelle liegen bewusst auf 0, PI/2 und PI, wo die
# Sollwerte exakt sind; die Toleranz von 1e-9 deckt die Reihenentwicklung ab.
#
# HINWEIS ZU DEN OFFENEN COMPILERDEFEKTEN #1496/#1497/#1499: die Pruefprogramme
# vergleichen in Lyx und drucken nur OK/FALSCH. Ein Vergleich der formatierten
# Zahl wuerde #1497 (PrintLn auf f64-Binaerausdruck druckt Rohbits) mitmessen
# und den Fehler der Matrixunit anlasten.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(timeout 60 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# Gemeinsamer Kopf: Pruefhelfer und zwei asymmetrische, invertierbare Matrizen.
HDR='import std.matrix;
import std.math;

fn say(n: pchar, good: bool) {
  if (good) { PrintLn(n); } else { Print("FALSCH "); PrintLn(n); }
}

fn eps(): f64 { return 0.000000001; }

fn matA(): Mat4 {
  var r: Mat4;
  r.m00 := 1.0; r.m01 := 2.0; r.m02 := 3.0; r.m03 := 4.0;
  r.m10 := 5.0; r.m11 := 6.0; r.m12 := 8.0; r.m13 := 7.0;
  r.m20 := 9.0; r.m21 := 2.0; r.m22 := 4.0; r.m23 := 6.0;
  r.m30 := 3.0; r.m31 := 1.0; r.m32 := 7.0; r.m33 := 5.0;
  return r;
}

fn matB(): Mat4 {
  var r: Mat4;
  r.m00 := 2.0; r.m01 := 0.0; r.m02 := 1.0; r.m03 := 3.0;
  r.m10 := 1.0; r.m11 := 4.0; r.m12 := 2.0; r.m13 := 0.0;
  r.m20 := 0.0; r.m21 := 5.0; r.m22 := 3.0; r.m23 := 1.0;
  r.m30 := 6.0; r.m31 := 1.0; r.m32 := 0.0; r.m33 := 2.0;
  return r;
}

fn mat3A(): Mat3 {
  return Mat3New(2.0, 1.0, 3.0,
                 0.0, 4.0, 5.0,
                 6.0, 7.0, 1.0);
}
'

# ===========================================================================
# Mat4 — Algebra
# ===========================================================================

out "Mat4: neutrales Element, Assoziativitaet, Nichtkommutativitaet" "$HDR"'
fn main(): int64 {
  var e: f64 := eps();
  var a: Mat4 := matA();
  var b: Mat4 := matB();
  var i: Mat4 := Mat4Identity();

  var ai: Mat4 := Mat4Mul(a, i);
  var ia: Mat4 := Mat4Mul(i, a);
  say("A*I == A"c, Mat4Equals(ai, a, e));
  say("I*A == A"c, Mat4Equals(ia, a, e));

  // Assoziativ, aber nicht kommutativ. Das zweite faengt eine Mul, die in
  // Wahrheit Zeilen und Spalten verwechselt und dadurch symmetrisch wird.
  var ab: Mat4 := Mat4Mul(a, b);
  var ba: Mat4 := Mat4Mul(b, a);
  var ab_c: Mat4 := Mat4Mul(ab, a);
  var b_a: Mat4 := Mat4Mul(b, a);
  var a_ba: Mat4 := Mat4Mul(a, b_a);
  say("(A*B)*A == A*(B*A)"c, Mat4Equals(ab_c, a_ba, e));
  say("A*B != B*A"c, !Mat4Equals(ab, ba, e));

  // Ein von Hand gerechnetes Element: Zeile 0 von A mal Spalte 0 von B
  // = 1*2 + 2*1 + 3*0 + 4*6 = 28. Faengt eine Mul, die konsequent
  // transponiert multipliziert.
  var got: f64 := ab.m00;
  var want: f64 := 28.0;
  var d: f64 := got - want;
  var ad: f64 := AbsF64(d);
  say("(A*B).m00 == 28"c, ad <= e);
  return 0;
}' 'A*I == A
I*A == A
(A*B)*A == A*(B*A)
A*B != B*A
(A*B).m00 == 28'

out "Mat4: Transposition und Determinante" "$HDR"'
fn main(): int64 {
  var e: f64 := eps();
  var a: Mat4 := matA();
  var b: Mat4 := matB();

  var tt: Mat4 := Mat4Transpose(a);
  var ttt: Mat4 := Mat4Transpose(tt);
  say("(A^T)^T == A"c, Mat4Equals(ttt, a, e));

  // (A*B)^T == B^T * A^T — faengt vertauschte Indizes in Mul UND Transpose,
  // die sich einzeln gegenseitig verdecken koennten.
  var ab: Mat4 := Mat4Mul(a, b);
  var abT: Mat4 := Mat4Transpose(ab);
  var aT: Mat4 := Mat4Transpose(a);
  var bT: Mat4 := Mat4Transpose(b);
  var bTaT: Mat4 := Mat4Mul(bT, aT);
  say("(A*B)^T == B^T*A^T"c, Mat4Equals(abT, bTaT, e));

  var i: Mat4 := Mat4Identity();
  var di: f64 := Mat4Det(i);
  var d1: f64 := di - 1.0;
  var ad1: f64 := AbsF64(d1);
  say("det(I) == 1"c, ad1 <= e);

  // det(A*B) == det(A)*det(B). Ein Vorzeichenfehler in der Entwicklung
  // faellt hier auf, bei det(I) nicht.
  var da: f64 := Mat4Det(a);
  var db: f64 := Mat4Det(b);
  var dab: f64 := Mat4Det(ab);
  var prod: f64 := da * db;
  var dd: f64 := dab - prod;
  var add: f64 := AbsF64(dd);
  var tol: f64 := 0.000001;
  say("det(A*B) == det(A)*det(B)"c, add <= tol);

  // det(A^T) == det(A)
  var dat: f64 := Mat4Det(aT);
  var d2: f64 := dat - da;
  var ad2: f64 := AbsF64(d2);
  say("det(A^T) == det(A)"c, ad2 <= tol);
  return 0;
}' '(A^T)^T == A
(A*B)^T == B^T*A^T
det(I) == 1
det(A*B) == det(A)*det(B)
det(A^T) == det(A)'

out "Mat4: Inverse beidseitig" "$HDR"'
fn main(): int64 {
  var tol: f64 := 0.000001;
  var a: Mat4 := matA();
  var i: Mat4 := Mat4Identity();

  var r: Mat4Inv := Mat4Inverse(a);
  say("Inverse gemeldet ok"c, r.ok);

  // Beidseitig pruefen: eine transponierte Adjunkte besteht nur eine Seite.
  var left: Mat4 := Mat4Mul(a, r.m);
  var right: Mat4 := Mat4Mul(r.m, a);
  say("A*A^-1 == I"c, Mat4Equals(left, i, tol));
  say("A^-1*A == I"c, Mat4Equals(right, i, tol));

  // Inverse der Inversen ist wieder A.
  var rr: Mat4Inv := Mat4Inverse(r.m);
  say("(A^-1)^-1 == A"c, Mat4Equals(rr.m, a, tol));
  return 0;
}' 'Inverse gemeldet ok
A*A^-1 == I
A^-1*A == I
(A^-1)^-1 == A'

# ===========================================================================
# Mat3
# ===========================================================================

out "Mat3: Inverse, Determinante, 2D-Transformationen" "$HDR"'
fn main(): int64 {
  var e: f64 := eps();
  var tol: f64 := 0.000001;
  var a: Mat3 := mat3A();
  var i3: Mat3 := Mat3Identity();

  var r: Mat3Inv := Mat3Inverse(a);
  say("Mat3-Inverse gemeldet ok"c, r.ok);
  var left: Mat3 := Mat3Mul(a, r.m);
  var right: Mat3 := Mat3Mul(r.m, a);
  say("A*A^-1 == I"c, Mat3Equals(left, i3, tol));
  say("A^-1*A == I"c, Mat3Equals(right, i3, tol));

  // det von Hand: 2*(4*1-5*7) - 1*(0*1-5*6) + 3*(0*7-4*6) = -62+30-72 = -104
  var d: f64 := Mat3Det(a);
  var want: f64 := 0.0 - 104.0;
  var diff: f64 := d - want;
  var ad: f64 := AbsF64(diff);
  say("det(A) == -104"c, ad <= tol);

  // 2D: Verschiebung wirkt auf einen Punkt (z == 1), nicht auf eine
  // Richtung (z == 0). Das prueft den Weg, nicht nur den Betrag.
  var t: Mat3 := Mat3Translate2D(3.0, 4.0);
  var p: Vec3 := Vec3New(1.0, 1.0, 1.0);
  var dir: Vec3 := Vec3New(1.0, 1.0, 0.0);
  var tp: Vec3 := Mat3MulVec3(t, p);
  var td: Vec3 := Mat3MulVec3(t, dir);
  var wantP: Vec3 := Vec3New(4.0, 5.0, 1.0);
  var wantD: Vec3 := Vec3New(1.0, 1.0, 0.0);
  say("Translate2D verschiebt den Punkt"c, Vec3Equals(tp, wantP, tol));
  say("Translate2D laesst die Richtung stehen"c, Vec3Equals(td, wantD, tol));

  // Drehung um 90 Grad bildet +x auf +y ab.
  var halfPi: f64 := 1.5707963267948966;
  var rot: Mat3 := Mat3Rotate2D(halfPi);
  var ux: Vec3 := Vec3New(1.0, 0.0, 1.0);
  var got: Vec3 := Mat3MulVec3(rot, ux);
  var wantR: Vec3 := Vec3New(0.0, 1.0, 1.0);
  say("Rotate2D(90) bildet +x auf +y"c, Vec3Equals(got, wantR, tol));
  return 0;
}' 'Mat3-Inverse gemeldet ok
A*A^-1 == I
A^-1*A == I
det(A) == -104
Translate2D verschiebt den Punkt
Translate2D laesst die Richtung stehen
Rotate2D(90) bildet +x auf +y'

# ===========================================================================
# Transformationen — die Richtung zaehlt, nicht der Betrag
# ===========================================================================

out "Mat4: Drehachsen bilden Achsen aufeinander ab" "$HDR"'
fn main(): int64 {
  var tol: f64 := 0.000001;
  var halfPi: f64 := 1.5707963267948966;

  // Rechtshaendig: Z-Drehung um 90 Grad schickt +x nach +y,
  // X-Drehung schickt +y nach +z, Y-Drehung schickt +z nach +x.
  var rz: Mat4 := Mat4RotateZ(halfPi);
  var rx: Mat4 := Mat4RotateX(halfPi);
  var ry: Mat4 := Mat4RotateY(halfPi);

  var gx: Vec3 := Mat4MulDir3(rz, Vec3UnitX());
  var gy: Vec3 := Mat4MulDir3(rx, Vec3UnitY());
  var gz: Vec3 := Mat4MulDir3(ry, Vec3UnitZ());
  say("RotateZ(90): +x -> +y"c, Vec3Equals(gx, Vec3UnitY(), tol));
  say("RotateX(90): +y -> +z"c, Vec3Equals(gy, Vec3UnitZ(), tol));
  say("RotateY(90): +z -> +x"c, Vec3Equals(gz, Vec3UnitX(), tol));

  // Viermal 90 Grad ist die Identitaet.
  var acc: Mat4 := Mat4Mul(rz, rz);
  var acc2: Mat4 := Mat4Mul(acc, acc);
  say("RotateZ(90)^4 == I"c, Mat4Equals(acc2, Mat4Identity(), tol));

  // Die allgemeine Achsdrehung muss die spezielle reproduzieren.
  var axis: Mat4 := Mat4RotateAxis(Vec3UnitZ(), halfPi);
  say("RotateAxis(z,90) == RotateZ(90)"c, Mat4Equals(axis, rz, tol));

  // Eine Drehung erhaelt Laengen.
  var v: Vec3 := Vec3New(3.0, 4.0, 5.0);
  var rv: Vec3 := Mat4MulDir3(rz, v);
  var l1: f64 := Vec3Length(v);
  var l2: f64 := Vec3Length(rv);
  var dl: f64 := l1 - l2;
  var adl: f64 := AbsF64(dl);
  say("Drehung erhaelt die Laenge"c, adl <= tol);
  return 0;
}' 'RotateZ(90): +x -> +y
RotateX(90): +y -> +z
RotateY(90): +z -> +x
RotateZ(90)^4 == I
RotateAxis(z,90) == RotateZ(90)
Drehung erhaelt die Laenge'

out "Mat4: Verschiebung trifft Punkte, nicht Richtungen" "$HDR"'
fn main(): int64 {
  var tol: f64 := 0.000001;
  var t: Vec3 := Vec3New(10.0, 20.0, 30.0);
  var m: Mat4 := Mat4Translate(t);
  var p: Vec3 := Vec3New(1.0, 2.0, 3.0);

  var tp: Vec3 := Mat4MulPoint3(m, p);
  var want: Vec3 := Vec3New(11.0, 22.0, 33.0);
  say("MulPoint3 verschiebt"c, Vec3Equals(tp, want, tol));

  // Der eigentliche Punkt: eine Richtung darf sich NICHT verschieben.
  // Ein MulDir3, das intern w = 1 setzt, faellt genau hier auf.
  var td: Vec3 := Mat4MulDir3(m, p);
  say("MulDir3 verschiebt nicht"c, Vec3Equals(td, p, tol));

  // Skalierung und ihre Umkehrung heben sich auf.
  var s: Mat4 := Mat4ScaleXYZ(Vec3New(2.0, 4.0, 8.0));
  var inv: Mat4Inv := Mat4Inverse(s);
  var both: Mat4 := Mat4Mul(s, inv.m);
  say("Skalierung mal Umkehrung == I"c, Mat4Equals(both, Mat4Identity(), tol));

  // Reihenfolge zaehlt: erst drehen dann verschieben ist nicht dasselbe
  // wie erst verschieben dann drehen.
  var halfPi: f64 := 1.5707963267948966;
  var rz: Mat4 := Mat4RotateZ(halfPi);
  var tr: Mat4 := Mat4Mul(m, rz);
  var rt: Mat4 := Mat4Mul(rz, m);
  say("T*R != R*T"c, !Mat4Equals(tr, rt, tol));
  return 0;
}' 'MulPoint3 verschiebt
MulDir3 verschiebt nicht
Skalierung mal Umkehrung == I
T*R != R*T'

out "Mat4: LookAt und Projektionen" "$HDR"'
fn main(): int64 {
  var tol: f64 := 0.000001;

  // Kamera bei (0,0,5), Blick auf den Ursprung. Rechtshaendig blickt sie
  // entlang -z, der Ursprung liegt also 5 vor ihr: (0,0,-5).
  var eye: Vec3 := Vec3New(0.0, 0.0, 5.0);
  var ctr: Vec3 := Vec3Zero();
  var up: Vec3 := Vec3UnitY();
  var view: Mat4 := Mat4LookAt(eye, ctr, up);
  var o: Vec3 := Mat4MulPoint3(view, Vec3Zero());
  var wantO: Vec3 := Vec3New(0.0, 0.0, 0.0 - 5.0);
  say("LookAt: Ursprung liegt 5 vor der Kamera"c, Vec3Equals(o, wantO, tol));

  // Die Kamera selbst liegt im Ursprung ihres eigenen Systems.
  var camPos: Vec3 := Mat4MulPoint3(view, eye);
  say("LookAt: Kamera liegt im eigenen Ursprung"c, Vec3Equals(camPos, Vec3Zero(), tol));

  // Eine Blickmatrix ist orthonormal: V * V^T == I im 3x3-Anteil.
  var rot3: Mat3 := Mat4ToMat3(view);
  var rt3: Mat3 := Mat3Transpose(rot3);
  var prod: Mat3 := Mat3Mul(rot3, rt3);
  say("LookAt: Basis ist orthonormal"c, Mat3Equals(prod, Mat3Identity(), tol));

  // Perspektive: die nahe Ebene bildet auf -1 ab, die ferne auf +1.
  var fov: f64 := 1.0471975511965976;
  var pm: Mat4 := Mat4Perspective(fov, 1.0, 1.0, 100.0);
  var atNear: Vec3 := Vec3New(0.0, 0.0, 0.0 - 1.0);
  var atFar: Vec3 := Vec3New(0.0, 0.0, 0.0 - 100.0);
  var rn: Vec3Result := Mat4ProjectPoint3(pm, atNear);
  var rf: Vec3Result := Mat4ProjectPoint3(pm, atFar);
  say("Perspektive: nahe Ebene meldet ok"c, rn.ok);
  say("Perspektive: ferne Ebene meldet ok"c, rf.ok);
  var zn: f64 := rn.v.z;
  var zf: f64 := rf.v.z;
  var dn: f64 := zn + 1.0;
  var df: f64 := zf - 1.0;
  var adn: f64 := AbsF64(dn);
  var adf: f64 := AbsF64(df);
  say("Perspektive: nahe Ebene auf -1"c, adn <= tol);
  say("Perspektive: ferne Ebene auf +1"c, adf <= tol);

  // Ortho: die Ecken des Quaders landen auf den Ecken des Wuerfels.
  var om: Mat4 := Mat4Ortho(0.0 - 2.0, 2.0, 0.0 - 3.0, 3.0, 1.0, 5.0);
  var corner: Vec3 := Vec3New(2.0, 3.0, 0.0 - 5.0);
  var oc: Vec3 := Mat4MulPoint3(om, corner);
  var wantC: Vec3 := Vec3New(1.0, 1.0, 1.0);
  say("Ortho: ferne obere rechte Ecke auf (1,1,1)"c, Vec3Equals(oc, wantC, tol));

  // Frustum mit symmetrischen Raendern muss dasselbe liefern wie Perspective.
  var halfFov: f64 := fov / 2.0;
  var th: f64 := TanF64(halfFov);
  var top: f64 := th * 1.0;
  var bot: f64 := 0.0 - top;
  var fr: Mat4 := Mat4Frustum(bot, top, bot, top, 1.0, 100.0);
  say("Frustum(symmetrisch) == Perspective"c, Mat4Equals(fr, pm, tol));
  return 0;
}' 'LookAt: Ursprung liegt 5 vor der Kamera
LookAt: Kamera liegt im eigenen Ursprung
LookAt: Basis ist orthonormal
Perspektive: nahe Ebene meldet ok
Perspektive: ferne Ebene meldet ok
Perspektive: nahe Ebene auf -1
Perspektive: ferne Ebene auf +1
Ortho: ferne obere rechte Ecke auf (1,1,1)
Frustum(symmetrisch) == Perspective'

# ===========================================================================
# Vektoren
# ===========================================================================

out "Vec3/Vec4: Kreuzprodukt, Normale, Spiegelung" "$HDR"'
fn main(): int64 {
  var tol: f64 := 0.000001;

  // Rechtshaendig: x cross y == z. Ein vertauschtes Vorzeichen ergibt -z
  // und faellt hier auf, bei einem Laengenvergleich nicht.
  var c: Vec3 := Vec3Cross(Vec3UnitX(), Vec3UnitY());
  say("x x y == z"c, Vec3Equals(c, Vec3UnitZ(), tol));
  var c2: Vec3 := Vec3Cross(Vec3UnitY(), Vec3UnitX());
  var negZ: Vec3 := Vec3New(0.0, 0.0, 0.0 - 1.0);
  say("y x x == -z"c, Vec3Equals(c2, negZ, tol));

  // Das Kreuzprodukt steht senkrecht auf beiden Faktoren.
  var a: Vec3 := Vec3New(1.0, 2.0, 3.0);
  var b: Vec3 := Vec3New(4.0, 5.0, 6.0);
  var ab: Vec3 := Vec3Cross(a, b);
  var d1: f64 := Vec3Dot(ab, a);
  var d2: f64 := Vec3Dot(ab, b);
  var ad1: f64 := AbsF64(d1);
  var ad2: f64 := AbsF64(d2);
  say("a x b steht senkrecht auf a"c, ad1 <= tol);
  say("a x b steht senkrecht auf b"c, ad2 <= tol);

  // Normieren ergibt Laenge 1 und behaelt die Richtung.
  var n: Vec3 := Vec3Normalize(a);
  var ln: f64 := Vec3Length(n);
  var dl: f64 := ln - 1.0;
  var adl: f64 := AbsF64(dl);
  say("Normalize ergibt Laenge 1"c, adl <= tol);
  var back: Vec3 := Vec3Scale(n, Vec3Length(a));
  say("Normalize behaelt die Richtung"c, Vec3Equals(back, a, tol));

  // 3-4-5-Dreieck: die Laenge ist exakt 5.
  var t345: Vec3 := Vec3New(3.0, 4.0, 0.0);
  var l345: f64 := Vec3Length(t345);
  var d345: f64 := l345 - 5.0;
  var ad345: f64 := AbsF64(d345);
  say("Laenge(3,4,0) == 5"c, ad345 <= tol);

  // Spiegelung an der xz-Ebene kehrt nur y um.
  var v: Vec3 := Vec3New(1.0, 0.0 - 1.0, 0.0);
  var refl: Vec3 := Vec3Reflect(v, Vec3UnitY());
  var wantR: Vec3 := Vec3New(1.0, 1.0, 0.0);
  say("Reflect kehrt nur die Normalenrichtung um"c, Vec3Equals(refl, wantR, tol));

  // Lerp trifft die Endpunkte und die Mitte.
  var p0: Vec3 := Vec3Zero();
  var p1: Vec3 := Vec3New(10.0, 20.0, 30.0);
  var mid: Vec3 := Vec3Lerp(p0, p1, 0.5);
  var wantM: Vec3 := Vec3New(5.0, 10.0, 15.0);
  say("Lerp(0.5) trifft die Mitte"c, Vec3Equals(mid, wantM, tol));
  var end: Vec3 := Vec3Lerp(p0, p1, 1.0);
  say("Lerp(1) trifft den Endpunkt"c, Vec3Equals(end, p1, tol));
  return 0;
}' 'x x y == z
y x x == -z
a x b steht senkrecht auf a
a x b steht senkrecht auf b
Normalize ergibt Laenge 1
Normalize behaelt die Richtung
Laenge(3,4,0) == 5
Reflect kehrt nur die Normalenrichtung um
Lerp(0.5) trifft die Mitte
Lerp(1) trifft den Endpunkt'

# ===========================================================================
# Die Fehlerfaelle — hier entscheidet sich, ob die Unit meldet oder raet
# ===========================================================================

out "Fehlerfaelle werden gemeldet, nicht geraten" "$HDR"'
fn main(): int64 {
  var tol: f64 := 0.000001;

  // Singulaere Mat4: Zeile 2 ist das Doppelte von Zeile 0.
  var s: Mat4 := Mat4Zero();
  s.m00 := 1.0; s.m01 := 2.0; s.m02 := 3.0; s.m03 := 4.0;
  s.m10 := 5.0; s.m11 := 6.0; s.m12 := 7.0; s.m13 := 8.0;
  s.m20 := 2.0; s.m21 := 4.0; s.m22 := 6.0; s.m23 := 8.0;
  s.m30 := 1.0; s.m31 := 1.0; s.m32 := 1.0; s.m33 := 1.0;
  var r: Mat4Inv := Mat4Inverse(s);
  say("singulaere Mat4 meldet ok == false"c, !r.ok);

  // Singulaere Mat3: zwei gleiche Zeilen.
  var s3: Mat3 := Mat3New(1.0, 2.0, 3.0,
                          1.0, 2.0, 3.0,
                          4.0, 5.0, 6.0);
  var r3: Mat3Inv := Mat3Inverse(s3);
  say("singulaere Mat3 meldet ok == false"c, !r3.ok);

  // Die regulaere Matrix daneben meldet weiterhin ok — sonst wuerde der
  // Test auch bei einer Inverse bestehen, die immer false liefert.
  var good: Mat4Inv := Mat4Inverse(matA());
  say("regulaere Mat4 meldet weiter ok == true"c, good.ok);

  // w == 0 ist eine Richtung im Unendlichen, kein Punkt.
  var inf: Vec4 := Vec4New(1.0, 2.0, 3.0, 0.0);
  var pd: Vec3Result := Vec4PerspectiveDivide(inf);
  say("w == 0 meldet ok == false"c, !pd.ok);
  var fine: Vec4 := Vec4New(2.0, 4.0, 6.0, 2.0);
  var pd2: Vec3Result := Vec4PerspectiveDivide(fine);
  var wantD: Vec3 := Vec3New(1.0, 2.0, 3.0);
  say("w != 0 teilt und meldet ok"c, pd2.ok && Vec3Equals(pd2.v, wantD, tol));

  // Entartete Sichtkegel ergeben die Nullmatrix — auffaellig, nicht beinahe
  // richtig. far == near, near == 0 und aspect == 0 einzeln geprueft.
  var z: Mat4 := Mat4Zero();
  var fov: f64 := 1.0471975511965976;
  var p1: Mat4 := Mat4Perspective(fov, 1.0, 5.0, 5.0);
  var p2: Mat4 := Mat4Perspective(fov, 1.0, 0.0, 100.0);
  var p3: Mat4 := Mat4Perspective(fov, 0.0, 1.0, 100.0);
  say("Perspective(far == near) ist die Nullmatrix"c, Mat4Equals(p1, z, tol));
  say("Perspective(near == 0) ist die Nullmatrix"c, Mat4Equals(p2, z, tol));
  say("Perspective(aspect == 0) ist die Nullmatrix"c, Mat4Equals(p3, z, tol));
  var o1: Mat4 := Mat4Ortho(1.0, 1.0, 0.0, 1.0, 1.0, 2.0);
  say("Ortho(left == right) ist die Nullmatrix"c, Mat4Equals(o1, z, tol));

  // Der gueltige Sichtkegel daneben ist es nicht.
  var pOk: Mat4 := Mat4Perspective(fov, 1.0, 1.0, 100.0);
  say("gueltige Perspective ist nicht die Nullmatrix"c, !Mat4Equals(pOk, z, tol));

  // LookAt ohne eindeutige Basis: up parallel zur Blickrichtung.
  var eye: Vec3 := Vec3New(0.0, 0.0, 5.0);
  var bad: Mat4 := Mat4LookAt(eye, Vec3Zero(), Vec3UnitZ());
  say("LookAt(up parallel) bleibt die Einheitsmatrix"c, Mat4Equals(bad, Mat4Identity(), tol));
  var same: Mat4 := Mat4LookAt(eye, eye, Vec3UnitY());
  say("LookAt(eye == center) bleibt die Einheitsmatrix"c, Mat4Equals(same, Mat4Identity(), tol));

  // Der Nullvektor hat keine Richtung und bleibt der Nullvektor (kein NaN).
  var nz: Vec3 := Vec3Normalize(Vec3Zero());
  say("Normalize(0) bleibt 0"c, Vec3Equals(nz, Vec3Zero(), tol));
  return 0;
}' 'singulaere Mat4 meldet ok == false
singulaere Mat3 meldet ok == false
regulaere Mat4 meldet weiter ok == true
w == 0 meldet ok == false
w != 0 teilt und meldet ok
Perspective(far == near) ist die Nullmatrix
Perspective(near == 0) ist die Nullmatrix
Perspective(aspect == 0) ist die Nullmatrix
Ortho(left == right) ist die Nullmatrix
gueltige Perspective ist nicht die Nullmatrix
LookAt(up parallel) bleibt die Einheitsmatrix
LookAt(eye == center) bleibt die Einheitsmatrix
Normalize(0) bleibt 0'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
