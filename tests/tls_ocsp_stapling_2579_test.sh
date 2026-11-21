#!/usr/bin/env bash
# #2579: OCSP-Stapling — beilegen und pruefen.
#
# Der Widerruf hing an einem Hook der Anwendung (TlsConfigWiderrufHook): die
# Unit ruft ihn mit dem Zertifikat der Gegenseite auf, und was er tut,
# entscheidet die Anwendung. Tragfaehig, aber ein Hook, den niemand einhaengt,
# prueft nichts. Dieser Gegenstand baut den Weg, der ohne Netz auf der
# Pruefseite auskommt: der Server legt eine frische OCSP-Antwort bei (RFC 6066
# status_request, in TLS 1.3 am CertificateEntry), der Client prueft sie.
#
# GEPRUEFT WIRD DIE WIRKUNG AN SECHS FAELLEN, und zwar ZWEISEITIG in beiden
# Bedeutungen des Wortes:
#   - beide AUSGAENGE: good verbindet, revoked beendet;
#   - beide VORGABEN: `hart` weist ab, wo `weich` verbindet, und `aus` prueft
#     gar nicht. Ohne den aus-Fall waere der Test auch von einer Umsetzung
#     erfuellt, die IMMER prueft -- und das waere eine andere Zusage als die
#     dokumentierte.
#
# Die CA wird HIER erzeugt, nicht aus den Fixtures genommen: eine OCSP-Antwort
# muss mit dem Schluessel des Ausstellers signiert sein, und den haben die
# eingecheckten Testketten nicht. Ohne eigenen Schluessel waere nur die
# Ablehnung pruefbar, nicht die Annahme.
#
# NICHT geprueft wird hier das Drahtformat gegen eine fremde Umsetzung. Unser
# Leser koennte unsere eigene falsche Kodierung annehmen; dieser Teil gehoert
# in den openssl-Interop-Test (dort laeuft `s_client -status` gegen unseren
# Server) und ist als eigener Punkt im Issue benannt.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-$ROOT/lyxc}"
case "$LYXC" in /*) ;; *) LYXC="$PWD/${LYXC#./}";; esac
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294

if [ ! -x "$LYXC" ]; then
  echo "SKIP: kein $LYXC -- make bootstrap"
  echo "Ergebnis: 0 PASS, 0 FAIL"
  exit 0
fi
if ! command -v openssl >/dev/null 2>&1 || ! openssl ocsp -help >/dev/null 2>&1; then
  echo "SKIP: openssl ocsp nicht verfuegbar -- die Antworten sind nicht erzeugbar"
  echo "Ergebnis: 0 PASS, 0 FAIL"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

# ── CA, Blatt, zweites Blatt, OCSP-Antworten ───────────────────────────────
openssl ecparam -name prime256v1 -genkey -noout -out ca.key 2>/dev/null
openssl req -new -x509 -key ca.key -out ca.pem -days 30 -subj "/CN=OCSP Test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out leaf.key 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in leaf.key -out leafkey8.pem 2>/dev/null
openssl req -new -key leaf.key -out leaf.csr -subj "/CN=ocsp.example" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out leaf2.key 2>/dev/null
openssl req -new -key leaf2.key -out leaf2.csr -subj "/CN=zweites.example" 2>/dev/null

mkdir -p db; : > db/index.txt; echo 1000 > db/serial
cat > ca.cnf <<'EOF'
[ca]
default_ca = CA_default
[CA_default]
dir = .
database = ./db/index.txt
serial = ./db/serial
new_certs_dir = ./db
certificate = ./ca.pem
private_key = ./ca.key
default_md = sha256
policy = pol
default_days = 30
unique_subject = no
copy_extensions = none
[pol]
commonName = supplied
EOF
# Das Blatt braucht serverAuth, sonst weist die Kettenpruefung es ab (#2096).
cat > leaf.ext <<'EOF'
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:ocsp.example
EOF
openssl ca -config ca.cnf -batch -extfile leaf.ext -in leaf.csr -out leaf.pem -notext 2>/dev/null
openssl ca -config ca.cnf -batch -extfile leaf.ext -in leaf2.csr -out leaf2.pem -notext 2>/dev/null

ocspFuer() {   # zertifikat, zieldatei
  openssl ocsp -index db/index.txt -CA ca.pem -issuer ca.pem \
     -rsigner ca.pem -rkey ca.key -cert "$1" -respout "$2" \
     -noverify -ndays 7 >/dev/null 2>&1
}
ocspFuer leaf.pem resp_good.der
ocspFuer leaf2.pem resp_anderes.der
openssl ca -config ca.cnf -revoke leaf.pem >/dev/null 2>&1
ocspFuer leaf.pem resp_revoked.der

for f in ca.pem leaf.pem leafkey8.pem resp_good.der resp_revoked.der resp_anderes.der; do
  if [ ! -s "$f" ]; then
    echo "SKIP: $f wurde nicht erzeugt -- openssl-Umgebung taugt nicht fuer diesen Test"
    echo "Ergebnis: 0 PASS, 0 FAIL"
    exit 0
  fi
done

JETZT="$(date +%s)"

# ── Das Pruefprogramm ──────────────────────────────────────────────────────
cat > p.lyx <<'LYXEOF'
import std.io;
import std.fs;
import std.alloc;
import std.crypto.der;
import std.net.tls13;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var n: int64 := FileSize(pfad);
  if (n <= 0) { return -1; }
  var pem: pchar := FileReadAll(pfad);
  if ((pem as int64) == 0) { return -1; }
  return PemDekodiere(pem as int64, n, label as int64, StrLen(label), derOut, 4096);
}

fn ladeRoh(pfad: pchar, lenOut: int64): int64 {
  var n: int64 := FileSize(pfad);
  if (n <= 0) { return 0; }
  var p: pchar := FileReadAll(pfad);
  if ((p as int64) == 0) { return 0; }
  poke64(lenOut, n);
  return p as int64;
}

// Ein Handschlag zwischen zwei Zustaenden im selben Programm. Liefert 0 oder
// den Fehlercode der Seite, die scheitert -- dieselbe Mechanik wie in
// tests/tls13_handschlag_test.sh.
// Wie handschlag, schreibt aber den ERSTEN Flug des Servers mit. Damit laesst
// sich pruefen, dass die beigelegte Antwort im GESCHUETZTEN Teil liegt.
fn handschlagMitFlug(sv: int64, cl: int64, pfad: pchar): int64 {
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  var gespeichert: int64 := 0;
  while (runden < 40) {
    var rcC: int64 := TlsSchritt(cl);
    if (rcC < 0) { free(puf, 32768); return rcC; }
    var n: int64 := TlsAusgabe(cl, puf, 32768);
    if (n > 0) { TlsFuetter(sv, puf, n); }
    var rcS: int64 := TlsSchritt(sv);
    if (rcS < 0) { free(puf, 32768); return rcS; }
    var m: int64 := TlsAusgabe(sv, puf, 32768);
    if (m > 0) {
      if (gespeichert == 0) { FileWriteAll(pfad, puf, m); gespeichert := 1; }
      TlsFuetter(cl, puf, m);
    }
    if (TlsFertig(cl) && TlsFertig(sv)) { free(puf, 32768); return 0; }
    if (n == 0 && m == 0) { free(puf, 32768); return -99; }
    runden := runden + 1;
  }
  free(puf, 32768);
  return -98;
}

fn handschlag(sv: int64, cl: int64): int64 {
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (runden < 40) {
    var rcC: int64 := TlsSchritt(cl);
    if (rcC < 0) { free(puf, 32768); return rcC; }
    var n: int64 := TlsAusgabe(cl, puf, 32768);
    if (n > 0) { TlsFuetter(sv, puf, n); }
    var rcS: int64 := TlsSchritt(sv);
    if (rcS < 0) { free(puf, 32768); return rcS; }
    var m: int64 := TlsAusgabe(sv, puf, 32768);
    if (m > 0) { TlsFuetter(cl, puf, m); }
    if (TlsFertig(cl) && TlsFertig(sv)) { free(puf, 32768); return 0; }
    if (n == 0 && m == 0) { free(puf, 32768); return -99; }
    runden := runden + 1;
  }
  free(puf, 32768);
  return -98;
}

fn main(): int64 {
  var dCa: int64 := alloc(4096);   var lCa: int64 := ladeDer("ca.pem"c, "CERTIFICATE"c, dCa);
  var dLf: int64 := alloc(4096);   var lLf: int64 := ladeDer("leaf.pem"c, "CERTIFICATE"c, dLf);
  var dKy: int64 := alloc(4096);   var lKy: int64 := ladeDer("leafkey8.pem"c, "PRIVATE KEY"c, dKy);
  if (lCa <= 0 || lLf <= 0 || lKy <= 0) { PrintLn("LADEFEHLER"c); return 1; }

  var lg: int64 := alloc(8);  var good: int64 := ladeRoh("resp_good.der"c, lg);
  var lr: int64 := alloc(8);  var revo: int64 := ladeRoh("resp_revoked.der"c, lr);
  var la: int64 := alloc(8);  var ande: int64 := ladeRoh("resp_anderes.der"c, la);
  if (good == 0 || revo == 0 || ande == 0) { PrintLn("ANTWORTFEHLER"c); return 1; }

  // Die KETTE traegt Blatt und Aussteller: die CertID bindet an den
  // Aussteller, und der Pruefer nimmt ihn aus der Kette, nicht aus dem
  // certs-Feld der Antwort (das kommt von der Gegenseite).
  var kette: int64 := alloc(32);
  poke64(kette, dLf);      poke64(kette + 8, lLf);
  poke64(kette + 16, dCa); poke64(kette + 24, lCa);
  var trust: int64 := alloc(16); poke64(trust, dCa); poke64(trust + 8, lCa);

  var host: pchar := "ocsp.example"c;

  // fall(beilage, beilageLen, modus) -> Fehlercode des Handschlags
  var i: int64 := 0;
  while (i < 6) {
    var beilage: int64 := 0;
    var beilageLen: int64 := 0;
    var modus: int64 := 0;
    var name: pchar := "?"c;
    if (i == 0) { beilage := good; beilageLen := peek64(lg); modus := 2; name := "hart-good           "c; }
    if (i == 1) { beilage := revo; beilageLen := peek64(lr); modus := 2; name := "hart-revoked        "c; }
    if (i == 2) { beilage := 0;    beilageLen := 0;          modus := 2; name := "hart-ohne-beilage   "c; }
    if (i == 3) { beilage := 0;    beilageLen := 0;          modus := 1; name := "weich-ohne-beilage  "c; }
    if (i == 4) { beilage := ande; beilageLen := peek64(la); modus := 2; name := "hart-fremde-certid  "c; }
    if (i == 5) { beilage := revo; beilageLen := peek64(lr); modus := 0; name := "aus-revoked-beigelegt"c; }

    var cfgS: int64 := alloc(TlsConfigGroesse());
    var cfgC: int64 := alloc(TlsConfigGroesse());
    TlsConfigNeu(cfgS, 1);
    TlsConfigKette(cfgS, kette, 2, dKy, lKy);
    TlsConfigZeit(cfgS, JETZTMARKER);
    if (beilage != 0) { TlsConfigOcspAntwort(cfgS, beilage, beilageLen); }
    TlsConfigNeu(cfgC, 2);
    TlsConfigTrust(cfgC, trust, 1);
    TlsConfigHost(cfgC, host as int64, StrLen(host));
    TlsConfigZeit(cfgC, JETZTMARKER);
    TlsConfigOcspModus(cfgC, modus);

    var sv: int64 := TlsNeu(cfgS);
    var cl: int64 := TlsNeu(cfgC);
    var rc: int64 := 0;
    if (i == 0) { rc := handschlagMitFlug(sv, cl, "flug.bin"c); }
    else { rc := handschlag(sv, cl); }
    Print(name); Print(" "c); PrintInt(rc); PrintLn(""c);
    i := i + 1;
  }
  return 0;
}
LYXEOF
sed -i "s/JETZTMARKER/$JETZT/g" p.lyx

if ! "$LYXC" --std-path="$ROOT" p.lyx -o p >bau.log 2>&1; then
  echo "FAIL Pruefprogramm uebersetzt nicht"
  grep -m3 -iE 'error|sema error' bau.log | sed 's/^/  /'
  echo ""
  echo "Ergebnis: 0 PASS, 1 FAIL"
  exit 1
fi

./p > ist.txt 2>&1
cat > soll.txt <<'SOLLEOF'
hart-good            0
hart-revoked         -15
hart-ohne-beilage    -20
weich-ohne-beilage   0
hart-fremde-certid   -20
aus-revoked-beigelegt 0
SOLLEOF

PASS=0; FAIL=0
# Zeilenweise vergleichen, damit der Bericht die FALSCHE Zeile nennt und nicht
# nur "weicht ab".
zeile=0
while IFS= read -r soll; do
  zeile=$((zeile+1))
  ist="$(sed -n "${zeile}p" ist.txt | tr -s ' ' ' ' | sed 's/ *$//')"
  sollN="$(printf '%s' "$soll" | tr -s ' ' ' ' | sed 's/ *$//')"
  if [ "$ist" = "$sollN" ]; then
    echo "PASS $sollN"; PASS=$((PASS+1))
  else
    echo "FAIL Zeile $zeile"; echo "  ist:  $ist"; echo "  soll: $sollN"; FAIL=$((FAIL+1))
  fi
done < soll.txt

# ── Die Beilage liegt im GESCHUETZTEN Teil ────────────────────────────────
# In TLS 1.3 steht das Certificate hinter EncryptedExtensions, die Antwort
# gehoert also nicht in den Klartext. Stuende sie dort, waere der Flug nicht
# geschuetzt -- ein viel groesserer Befund als ein Kodierungsfehler.
#
# WAS DAMIT NICHT GEPRUEFT IST, und das steht auch im Issue: die KODIERUNG der
# Erweiterung (Typ 5, status_type 1, 3-Byte-Laenge). Unser Leser koennte die
# eigene falsche Kodierung annehmen, und von aussen ist sie hier nicht lesbar,
# weil der Teil verschluesselt ist. Dafuer braucht es eine fremde Umsetzung --
# `openssl s_client -status` gegen unseren Server. Als offener Punkt gefuehrt.
if [ -s flug.bin ]; then
  if python3 -I -c "
import sys
flug = open('flug.bin','rb').read()
der = open('resp_good.der','rb').read()
sys.exit(0 if der not in flug else 1)
"; then
    echo "PASS die beigelegte Antwort steht nicht im Klartext des Serverflugs"
    PASS=$((PASS+1))
  else
    echo "FAIL die DER-Antwort steht im KLARTEXT im Serverflug"
    FAIL=$((FAIL+1))
  fi
else
  echo "FAIL der Serverflug wurde nicht mitgeschrieben"
  FAIL=$((FAIL+1))
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
