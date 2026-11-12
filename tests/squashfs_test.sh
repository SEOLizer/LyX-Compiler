#!/usr/bin/env bash
# tests/squashfs_test.sh — baut SquashFS-Abbilder und liest sie gegen unsquashfs.
#
# `mksquashfs` legt an, `unsquashfs` liest — beides ohne Wurzelrechte, beides
# eine fremde Umsetzung desselben Formats. Damit steht diese Batterie auf der
# hoechsten Sprosse der Leiter, die die Schwester-Units aufgebaut haben:
# fremder Schreiber UND fremder Leser.
#
# ZWEI ABBILDER, weil SquashFS zwei sehr verschiedene Faelle kennt:
#   * `-noI -noD -noF -noX` legt alles UNKOMPRIMIERT ab. Damit ist die
#     Strukturdeutung pruefbar, ohne dass ein Entpackerfehler sie verdeckt.
#   * gzip komprimiert Metadaten UND Daten. Beide Abbilder tragen denselben
#     Inhalt, also muessen beide Laeufe dieselben Werte liefern — eine
#     Abweichung zwischen ihnen zeigt genau auf den Entpackpfad.
#
# GEPRUEFT WIRD DER WERT, nicht das Vorhandensein: der Inhalt der grossen Datei
# wird ueber eine Pruefsumme mit einer UNABHAENGIG in Python gerechneten
# Summe verglichen. "Es kam etwas an" waere auch von einem Leser erfuellt, der
# Nullen liefert.
#
# Die grosse Datei ist mit 400 000 Byte bewusst groesser als die Blockgroesse
# (131 072): erst damit entstehen mehrere Datenbloecke und die Blockgroessen-
# liste wird ueberhaupt benutzt. Dass sie entstanden sind, wird NACHGEMESSEN.
#
# Alle Laeufe stehen unter `ulimit -v`.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

finde() { for k in "/usr/sbin/$1" "/sbin/$1" "/usr/bin/$1" "$1"; do command -v "$k" >/dev/null 2>&1 && { echo "$k"; return 0; }; done; return 1; }

MKSQ="$(finde mksquashfs)" || { echo "UEBERSPRUNGEN std.fs.squashfs: mksquashfs fehlt (Paket squashfs-tools)"; exit 0; }
UNSQ="$(finde unsquashfs)" || { echo "UEBERSPRUNGEN std.fs.squashfs: unsquashfs fehlt — ohne fremden Leser gaebe es keinen Abgleich"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "UEBERSPRUNGEN std.fs.squashfs: python3 fehlt"; exit 0; }

echo "--- std.fs.squashfs: SquashFS 4.0 lesen ---"

# ── Quellbaum ──────────────────────────────────────────────────────────────
Q="$TMP/quelle"
mkdir -p "$Q/a/b/c"
printf 'HALLO SQUASHFS' > "$Q/hallo.txt"
printf 'TIEF GEFUNDEN'  > "$Q/a/b/c/tief.txt"
: > "$Q/leer.txt"
ln -s a/b/c/tief.txt "$Q/kurz.lnk"
python3 -c "open('$Q/gross.bin','wb').write(bytes((i*7+3)%251 for i in range(400000)))"

ERWARTET_SUMME="$(python3 -c "
d=bytes((i*7+3)%251 for i in range(400000))
s=0
for b in d: s=(s*31+b)%1000000007
print(s)")"

( ulimit -v 4194304
  "$MKSQ" "$Q" "$TMP/none.sqfs" -noI -noD -noF -noX -noappend >/dev/null 2>&1
  "$MKSQ" "$Q" "$TMP/gz.sqfs"   -comp gzip -noappend          >/dev/null 2>&1 )

[ -s "$TMP/none.sqfs" ] && [ -s "$TMP/gz.sqfs" ] || {
  echo "UEBERSPRUNGEN std.fs.squashfs: mksquashfs konnte kein Abbild anlegen"; exit 0; }

# ── Voraussetzungen nachmessen, nicht annehmen ─────────────────────────────
BS="$( ulimit -v 2097152; "$UNSQ" -s "$TMP/gz.sqfs" 2>/dev/null | grep -oP '^Block size \K[0-9]+' )"
if [ -n "$BS" ] && [ "$BS" -gt 0 ] && [ 400000 -gt "$BS" ]; then
  ok "die grosse Datei ueberschreitet die Blockgroesse ($BS) — mehrere Datenbloecke entstehen"
else
  nok "Blockgroesse nicht ermittelbar oder zu gross ($BS) — der Mehrblockfall waere ungeprueft"
fi

if ( ulimit -v 2097152; "$UNSQ" -s "$TMP/none.sqfs" 2>/dev/null | grep -q 'Inodes are uncompressed' ); then
  ok "das erste Abbild ist wirklich unkomprimiert"
else
  nok "das erste Abbild ist doch komprimiert — der unkomprimierte Pfad waere ungeprueft"
fi

# Namen aus dem FREMDEN Leser. Der Lyx-Test muss jeden davon wiederfinden.
( ulimit -v 2097152; "$UNSQ" -l "$TMP/gz.sqfs" 2>/dev/null ) | sed -n 's|^squashfs-root/||p' | grep . | sort > "$TMP/fremd.txt"
if [ -s "$TMP/fremd.txt" ]; then
  ok "unsquashfs listet $(wc -l < "$TMP/fremd.txt") Eintraege als Vergleichsgrundlage"
else
  nok "unsquashfs liefert keine Liste — ohne sie gaebe es keinen Abgleich"
fi

# ── Lyx-Sonde ──────────────────────────────────────────────────────────────
cat > "$TMP/sonde.lyx" <<'EOF'
unit main;
import std.fs.squashfs;
import std.io;
import std.alloc;

fn summe(p: int64, n: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < n) { s := (s * 31 + (peek8(p + i) & 255)) % 1000000007; i := i + 1; }
  return s;
}

fn zeile(marke: pchar, schluessel: pchar, wert: pchar): void {
  PrintLn(StrConcat(StrConcat(StrConcat(marke, " "), StrConcat(schluessel, "=")), wert));
}

fn pruefe(pfad: pchar, marke: pchar): void {
  var fd: int64 := open(pfad, 0, 0);
  if (fd < 0) { zeile(marke, "fehler"c, "open"c); return; }
  var vol: SquashVolume;
  if (SquashMount(fd, 0, vol) == false) { zeile(marke, "fehler"c, "mount"c); close(fd); return; }

  zeile(marke, "blockgroesse"c, IntToStr(SquashBlockSize(vol)));
  zeile(marke, "inodes"c, IntToStr(SquashInodeCount(vol)));

  var root: SquashEntry;
  if (SquashInode(vol, SquashRootRef(vol), root) == false) { zeile(marke, "fehler"c, "root"c); close(fd); return; }
  zeile(marke, "rootdir"c, IntToStr(root.istDir as int64));

  var d: SquashDir;
  var name: int64 := alloc(300);
  var de: SquashDirEntry;
  if (SquashDirOpen(vol, root, d)) {
    while (SquashDirNext(d, de, name)) { zeile(marke, "eintrag"c, name as pchar); }
    SquashDirClose(d);
  }

  var r: int64 := SquashFindPath(vol, "/gross.bin"c as int64);
  var e: SquashEntry;
  if (r != 0 - 1 && SquashInode(vol, r, e)) {
    var buf: int64 := alloc(500000);
    var n: int64 := SquashReadFile(vol, e, buf, 500000);
    zeile(marke, "grossgroesse"c, IntToStr(e.groesse));
    zeile(marke, "grossgelesen"c, IntToStr(n));
    zeile(marke, "grossbloecke"c, IntToStr(e.blockAnzahl));
    zeile(marke, "grosssumme"c, IntToStr(summe(buf, n)));
  }

  var r2: int64 := SquashFindPath(vol, "/a/b/c/tief.txt"c as int64);
  var e2: SquashEntry;
  if (r2 != 0 - 1 && SquashInode(vol, r2, e2)) {
    var b2: int64 := alloc(256);
    var n2: int64 := SquashReadFile(vol, e2, b2, 255);
    poke8(b2 + n2, 0);
    zeile(marke, "tief"c, b2 as pchar);
  }

  var r3: int64 := SquashFindPath(vol, "/leer.txt"c as int64);
  var e3: SquashEntry;
  if (r3 != 0 - 1 && SquashInode(vol, r3, e3)) {
    var b3: int64 := alloc(16);
    zeile(marke, "leer"c, IntToStr(SquashReadFile(vol, e3, b3, 16)));
  }

  var r4: int64 := SquashFindPath(vol, "/kurz.lnk"c as int64);
  var e4: SquashEntry;
  if (r4 != 0 - 1 && SquashInode(vol, r4, e4)) {
    var b4: int64 := alloc(300);
    var n4: int64 := SquashReadLink(e4, b4, 299);
    poke8(b4 + n4, 0);
    zeile(marke, "link"c, b4 as pchar);
    zeile(marke, "linkart"c, IntToStr(e4.art));
  }

  zeile(marke, "fehltabgewiesen"c,
        IntToStr((SquashFindPath(vol, "/gibtsnicht"c as int64) == 0 - 1) as int64));

  var e5: SquashEntry;
  var r5: int64 := SquashFindPath(vol, "/hallo.txt"c as int64);
  if (r5 != 0 - 1 && SquashInode(vol, r5, e5)) {
    var b5: int64 := alloc(64);
    var n5: int64 := SquashReadFile(vol, e5, b5, 63);
    poke8(b5 + n5, 0);
    zeile(marke, "hallo"c, b5 as pchar);
    zeile(marke, "halloart"c, IntToStr(e5.art));
  }
  close(fd);
}

fn main(): int64 {
  pruefe("PFADNONE"c, "none"c);
  pruefe("PFADGZIP"c, "gzip"c);
  return 0;
}
EOF
sed -i "s|PFADNONE|$TMP/none.sqfs|; s|PFADGZIP|$TMP/gz.sqfs|" "$TMP/sonde.lyx"

if ! ( cd "$ROOT" && timeout 180 "$LYXC" --std-path="$ROOT" "$TMP/sonde.lyx" -o "$TMP/sonde" ) >"$TMP/build.log" 2>&1; then
  nok "die Sonde uebersetzt nicht"; sed -n '1,5p' "$TMP/build.log"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi

AUS="$( ulimit -v 2097152; timeout 120 "$TMP/sonde" 2>/dev/null )"; rc=$?
if [ "$rc" -ne 0 ]; then
  nok "die Sonde bricht ab (rc=$rc)"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "die Sonde laeuft durch"

hole() { printf '%s\n' "$AUS" | grep -oP "^$1 $2=\K.*" | head -1; }

# ── Beide Abbilder, dieselben Erwartungen ──────────────────────────────────
for m in none gzip; do
  case "$m" in
    none) was="unkomprimiert" ;;
    *)    was="gzip" ;;
  esac

  [ "$(hole $m blockgroesse)" = "131072" ] \
    && ok "$was: Blockgroesse 131072 gelesen" \
    || nok "$was: Blockgroesse ist '$(hole $m blockgroesse)', erwartet 131072"

  [ "$(hole $m rootdir)" = "1" ] \
    && ok "$was: die Wurzel ist ein Verzeichnis" \
    || nok "$was: die Wurzel gilt nicht als Verzeichnis"

  # Der Wertvergleich: unabhaengig in Python gerechnet.
  [ "$(hole $m grosssumme)" = "$ERWARTET_SUMME" ] \
    && ok "$was: der Inhalt der grossen Datei stimmt (Summe $ERWARTET_SUMME)" \
    || nok "$was: Inhaltssumme '$(hole $m grosssumme)', erwartet '$ERWARTET_SUMME'"

  [ "$(hole $m grossgelesen)" = "400000" ] \
    && ok "$was: 400000 Byte gelesen" \
    || nok "$was: '$(hole $m grossgelesen)' Byte gelesen, erwartet 400000"

  [ "$(hole $m grossgroesse)" = "400000" ] \
    && ok "$was: die Groesse im Inode ist 400000" \
    || nok "$was: Inode-Groesse '$(hole $m grossgroesse)'"

  # Ohne mehrere Bloecke waere die Blockgroessenliste ungeprueft geblieben.
  bl="$(hole $m grossbloecke)"
  if [ -n "$bl" ] && [ "$bl" -ge 3 ]; then
    ok "$was: die Datei belegt $bl Datenbloecke — die Blockliste wurde benutzt"
  else
    nok "$was: nur '$bl' Datenbloecke — der Mehrblockfall ist ungeprueft"
  fi

  [ "$(hole $m tief)" = "TIEF GEFUNDEN" ] \
    && ok "$was: /a/b/c/tief.txt ueber drei Ebenen aufgeloest" \
    || nok "$was: tiefer Pfad liefert '$(hole $m tief)'"

  [ "$(hole $m hallo)" = "HALLO SQUASHFS" ] \
    && ok "$was: kleine Datei (Fragment) korrekt gelesen" \
    || nok "$was: kleine Datei liefert '$(hole $m hallo)'"

  [ "$(hole $m leer)" = "0" ] \
    && ok "$was: die leere Datei liefert 0 Byte" \
    || nok "$was: leere Datei liefert '$(hole $m leer)' Byte"

  [ "$(hole $m link)" = "a/b/c/tief.txt" ] \
    && ok "$was: das Symlink-Ziel ist a/b/c/tief.txt" \
    || nok "$was: Symlink-Ziel '$(hole $m link)'"

  [ "$(hole $m linkart)" = "3" ] \
    && ok "$was: der Symlink traegt die Inode-Art 3" \
    || nok "$was: Symlink-Art '$(hole $m linkart)', erwartet 3"

  [ "$(hole $m halloart)" = "2" ] \
    && ok "$was: die Datei traegt die Inode-Art 2" \
    || nok "$was: Datei-Art '$(hole $m halloart)', erwartet 2"

  # Beide Seiten messen: ein Leser, der jeden Pfad annimmt, waere von den
  # Treffern oben ebenfalls erfuellt.
  [ "$(hole $m fehltabgewiesen)" = "1" ] \
    && ok "$was: ein nicht vorhandener Pfad wird abgewiesen" \
    || nok "$was: ein nicht vorhandener Pfad wurde NICHT abgewiesen"
done

# ── Abgleich gegen den fremden Leser ───────────────────────────────────────
fehlend=""
while IFS= read -r n; do
  case "$n" in */*) continue ;; esac      # nur die Wurzelebene vergleichen
  printf '%s\n' "$AUS" | grep -qx "gzip eintrag=$n" || fehlend="$fehlend $n"
done < "$TMP/fremd.txt"
if [ -z "$fehlend" ]; then
  ok "jeder von unsquashfs gelistete Wurzeleintrag wurde auch hier gefunden"
else
  nok "von unsquashfs gelistet, hier nicht gefunden:$fehlend"
fi

# ... und umgekehrt: nichts erfinden.
erfunden=""
while IFS= read -r z; do
  n="${z#gzip eintrag=}"
  grep -qx "$n" "$TMP/fremd.txt" || erfunden="$erfunden $n"
done < <(printf '%s\n' "$AUS" | grep '^gzip eintrag=')
if [ -z "$erfunden" ]; then
  ok "kein Eintrag gefunden, den unsquashfs nicht kennt"
else
  nok "hier gefunden, unsquashfs kennt sie nicht:$erfunden"
fi

# Beide Abbilder tragen denselben Inhalt — jede Abweichung zwischen ihnen
# zeigt genau auf den Entpackpfad.
if [ "$(hole none grosssumme)" = "$(hole gzip grosssumme)" ]; then
  ok "unkomprimiert und gzip liefern denselben Inhalt"
else
  nok "die beiden Abbilder liefern verschiedene Inhalte — Fehler im Entpackpfad"
fi

# ── Nicht unterstuetzte Kompression: LAUT scheitern, nicht still raten ─────
#
# Der Gegenbeweis zu allem oben: ein Abbild mit einem Verfahren, fuer das es
# hier keinen Entpacker gibt, darf nicht "irgendetwas" liefern. Ohne diese
# Pruefung waere die Unit auch dann gruen, wenn sie Rohdaten als Inhalt
# durchreichte.
if ( ulimit -v 4194304; "$MKSQ" "$Q" "$TMP/zstd.sqfs" -comp zstd -noappend >/dev/null 2>&1 ) \
   && [ -s "$TMP/zstd.sqfs" ]; then
  cat > "$TMP/zs.lyx" <<'ZEOF'
unit main;
import std.fs.squashfs;
import std.io;
fn main(): int64 {
  var fd: int64 := open("ZPFAD"c, 0, 0);
  var vol: SquashVolume;
  if (SquashMount(fd, 0, vol) == false) { PrintLn("mount=0"); return 0; }
  PrintLn(StrConcat("comp=", IntToStr(SquashCompression(vol))));
  PrintLn(StrConcat("unterstuetzt=", IntToStr(SquashCompressionUnterstuetzt(vol) as int64)));
  var e: SquashEntry;
  PrintLn(StrConcat("root=", IntToStr(SquashInode(vol, SquashRootRef(vol), e) as int64)));
  return 0;
}
ZEOF
  sed -i "s|ZPFAD|$TMP/zstd.sqfs|" "$TMP/zs.lyx"
  if ( cd "$ROOT" && timeout 180 "$LYXC" --std-path="$ROOT" "$TMP/zs.lyx" -o "$TMP/zs" ) >/dev/null 2>&1; then
    ZAUS="$( ulimit -v 2097152; timeout 60 "$TMP/zs" 2>&1 )"
    printf '%s' "$ZAUS" | grep -q '^comp=6' \
      && ok "zstd-Abbild: die Kennung wird als 6 gelesen" \
      || nok "zstd-Abbild: Kennung nicht erkannt"
    printf '%s' "$ZAUS" | grep -q '^unterstuetzt=0' \
      && ok "zstd-Abbild: die Unit sagt vorab, dass sie es nicht entpacken kann" \
      || nok "zstd-Abbild: die Unit behauptet, zstd zu koennen"
    printf '%s' "$ZAUS" | grep -q 'nicht entpackt' \
      && ok "zstd-Abbild: der Fehlschlag wird LAUT gemeldet (nennt das Verfahren)" \
      || nok "zstd-Abbild: kein Hinweis auf die fehlende Unterstuetzung"
    printf '%s' "$ZAUS" | grep -q '^root=0' \
      && ok "zstd-Abbild: die Inode wird abgewiesen statt Muell zu liefern" \
      || nok "zstd-Abbild: es kam ein Ergebnis zurueck, obwohl nichts entpackt werden konnte"
  else
    echo "UEBERSPRUNGEN zstd-Gegenprobe: die Sonde uebersetzt nicht"
  fi
else
  echo "UEBERSPRUNGEN zstd-Gegenprobe: mksquashfs kann kein zstd"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
