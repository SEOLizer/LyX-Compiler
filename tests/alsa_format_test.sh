#!/usr/bin/env bash
# #1930: std.audio.alsa — Fehlerkonvention, Formatwahl und echte Wiedergabe.
#
# ALSASetFormat lieferte auch bei vorhandener Soundkarte immer ALSA_ERROR.
# Ursache war NICHT die im Issue vermutete Zeigeruebergabe, sondern die
# Fehlerkonvention: ALSA meldet Fehler NEGATIV, ein positiver Rueckgabewert
# ist Erfolg mit Zusatzinformation. `snd_pcm_hw_params_any` liefert 1, und die
# vom Lader gebundene Standardfassung von `snd_pcm_hw_params_set_rate_near`
# (Symbolversion ALSA_0.9.0rc4, Rate als WERT) liefert die gesetzte Rate. Der
# Code prueft `!= 0` und hielt beides fuer einen Fehlschlag.
#
# Der Test misst die WIRKUNG, nicht das Vorhandensein: das Geraet muss die
# Daten tatsaechlich annehmen (Bytezahl), und die Formatwahl muss in BEIDE
# Richtungen stimmen — gueltige Breiten gehen durch, ungueltige werden
# abgewiesen. Ein Test, der nur das Durchgehen prueft, waere auch von einer
# Fassung erfuellt, die jede Breite annimmt und still S16_LE spielt.
#
# VORAUSSETZUNG wird gemessen, nicht vorausgesetzt (#1933): ohne Soundkarte
# laeuft der Geraeteteil nicht, und das wird laut gesagt statt als Defekt
# gemeldet. Die Konstanten werden immer geprueft — dafuer braucht es kein
# Geraet.
#
# Alle Laeufe stehen unter `ulimit -v`: neuer Code darf im Fehlerfall nicht
# den OOM-Killer auf einen fremden Prozess im System hetzen.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { echo "PASS $1"; PASS=$((PASS+1)); }
nok()  { echo "FAIL $1"; FAIL=$((FAIL+1)); }

echo "--- std.audio.alsa: Fehlerkonvention und Formatwahl (#1930) ---"

# --- Teil 1: Konstanten. Braucht kein Geraet. ---------------------------------
# S8 stand auf 1 und U8 auf 2 — U8 war damit gleich S16_LE, 8-Bit-Material lief
# still als 16 Bit. Die Werte stammen aus den C-Headern.
erwartet="S8=0 U8=1 S16_LE=2 S16_BE=3 U16_LE=4 U16_BE=5 S32_LE=10"
gemessen=""
for paar in S8:0 U8:1 S16_LE:2 S16_BE:3 U16_LE:4 U16_BE:5 S32_LE:10; do
  name="${paar%%:*}"
  wert="$(grep -oP "SND_PCM_FORMAT_${name}: int64 := \K-?[0-9]+" "$ROOT/std/audio/alsa.lyx" | head -1)"
  gemessen="$gemessen $name=$wert"
done
if [ "$(echo $gemessen)" = "$erwartet" ]; then
  ok "Formatkonstanten stimmen mit den C-Headern ueberein"
else
  nok "Formatkonstanten: erwartet [$erwartet], gemessen [$(echo $gemessen)]"
fi

# Keine Fehlerpruefung darf mehr auf Gleichheit mit 0 laufen: ein positiver
# Rueckgabewert ist Erfolg. Genau diese Zeile war der Defekt.
# Die Fassade std.audio.playback reicht ALSA-Rueckgabewerte ebenso durch —
# dieselbe Rechnung, zweite Stelle. Beide Dateien werden geprueft, damit die
# Konvention nicht in einer davon zurueckfaellt.
treffer="$(grep -l "!= ALSA_OK" "$ROOT/std/audio/alsa.lyx" "$ROOT/std/audio/playback.lyx" 2>/dev/null | tr '\n' ' ')"
if [ -n "$treffer" ]; then
  nok "Fehlerpruefung auf '!= ALSA_OK' zurueck in: $treffer (ALSA meldet negativ)"
else
  ok "beide Units pruefen durchgehend auf '< 0'"
fi

# Der Rueckgabewert von ALSAPrepare wurde im MP3-Zweig komplett verworfen:
# schlug das Vorbereiten fehl, schrieb die Schleife trotzdem weiter.
if grep -qE '^\s*ALSAPrepare\(handle\);\s*$' "$ROOT/std/audio/playback.lyx"; then
  nok "ALSAPrepare wird an einer Stelle ohne Pruefung des Rueckgabewerts aufgerufen"
else
  ok "kein ALSAPrepare mit verworfenem Rueckgabewert"
fi

# --- Teil 2: Geraet. Voraussetzung zuerst messen. -----------------------------
if [ ! -e /dev/snd/controlC0 ]; then
  echo "UEBERSPRUNGEN Geraeteteil: keine Soundkarte (/dev/snd/controlC0 fehlt)"
  echo
  echo "Ergebnis: $PASS PASS, $FAIL FAIL"
  [ "$FAIL" -eq 0 ]; exit $?
fi

cat > "$TMP/t.lyx" <<'EOF'
unit main;
import std.audio.alsa;
import std.audio.playback;
import std.io;
import std.alloc;

fn probe(bits: int64): int64 {
  var h: int64 := ALSAAudioOpen();
  if (h == 0) { return -99; }
  var r: int64 := ALSASetFormat(h, 44100, 2, bits);
  ALSAClose(h);
  return r;
}

fn main(): int64 {
  PrintLn(StrConcat("fmt8=", IntToStr(probe(8))));
  PrintLn(StrConcat("fmt16=", IntToStr(probe(16))));
  PrintLn(StrConcat("fmt32=", IntToStr(probe(32))));
  PrintLn(StrConcat("fmt24=", IntToStr(probe(24))));
  PrintLn(StrConcat("fmt0=", IntToStr(probe(0))));

  // Echte Wiedergabe: 0,2 s leise Rechteckwelle, 16 Bit Stereo. Gemessen wird,
  // wie viele Bytes das GERAET angenommen hat.
  var h: int64 := ALSAAudioOpen();
  if (h == 0) { PrintLn("bytes=-99"); return 0; }
  if (ALSASetFormat(h, 44100, 2, 16) < 0) { PrintLn("bytes=-98"); ALSAClose(h); return 0; }
  if (ALSAPrepare(h) < 0) { PrintLn("bytes=-97"); ALSAClose(h); return 0; }
  var n: int64 := 44100 / 5;
  var buf: int64 := alloc(n * 4);
  var i: int64 := 0;
  while (i < n) {
    var v: int64 := 0;
    if ((i / 50) % 2 == 0) { v := 600; } else { v := 0 - 600; }
    poke16(buf + i * 4, v);
    poke16(buf + i * 4 + 2, v);
    i := i + 1;
  }
  PrintLn(StrConcat("bytes=", IntToStr(ALSAWrite(h, buf, n * 4))));
  PrintLn(StrConcat("erwartet=", IntToStr(n * 4)));
  ALSAClose(h);

  // Die Fassade oben drauf: sie war durch denselben Defekt unbenutzbar.
  var h2: int64 := ALSAAudioOpen();
  if (h2 == 0) { PrintLn("fassade=-99"); return 0; }
  PrintLn(StrConcat("fassade=", IntToStr(AudioPlayPCM(h2, buf, n * 4, 44100, 2, 16))));
  ALSAClose(h2);
  return 0;
}
EOF

if ! ( cd "$ROOT" && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" ) >"$TMP/build.log" 2>&1; then
  nok "Geraetefall uebersetzt nicht"; sed -n '1,5p' "$TMP/build.log"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi

out="$( ulimit -v 2097152; timeout 60 "$TMP/t" 2>/dev/null )"; rc=$?
if [ "$rc" -ne 0 ]; then
  nok "Geraetefall bricht ab (rc=$rc)"
else
  hole() { printf '%s\n' "$out" | grep -oP "^$1=\K-?[0-9]+" | head -1; }

  # Gueltige Breiten muessen durchgehen — vor dem Fix war jede -1.
  for b in 8 16 32; do
    v="$(hole "fmt$b")"
    if [ "$v" = "0" ]; then ok "$b Bit: ALSASetFormat gelingt"
    else nok "$b Bit: ALSASetFormat liefert $v (erwartet 0)"; fi
  done

  # ... und ungueltige muessen scheitern. Ohne diese Haelfte waere der Test
  # auch von einer Fassung erfuellt, die bitsPerSample weiter ignoriert.
  for b in 24 0; do
    v="$(hole "fmt$b")"
    if [ "$v" = "-1" ]; then ok "$b Bit: wird abgewiesen statt still ersetzt"
    else nok "$b Bit: liefert $v (erwartet -1)"; fi
  done

  f="$(hole fassade)"
  if [ "$f" = "0" ]; then ok "AudioPlayPCM (std.audio.playback) spielt"
  else nok "AudioPlayPCM liefert $f (erwartet 0)"; fi

  gesendet="$(hole bytes)"; sollte="$(hole erwartet)"
  if [ -n "$gesendet" ] && [ "$gesendet" = "$sollte" ]; then
    ok "das Geraet nimmt die Daten an ($gesendet Byte)"
  else
    nok "Wiedergabe: $gesendet Byte angenommen, erwartet $sollte"
  fi
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
