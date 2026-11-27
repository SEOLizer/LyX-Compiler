# tests/lib/lastwache.sh — #2666: eine Zeitmessung urteilt nur auf einer
# ruhigen Maschine.
#
# Der Anlass: neun Tests im `test`-Ziel urteilen auf Zeit, Takte oder
# Codelayout, und der Lauf erzeugt selbst die Last, gegen die sie urteilen.
# Gemessen am 2026-11-26 (lyxc 1.2.50B, i5-8250U): zwei aufeinanderfolgende
# `make test` mit DEMSELBEN Compiler, zwei VERSCHIEDENE rote Tests
# (strlen_schleifen_2352 mit 950 % gegen Schwelle 800 %, cpu_clock_2401 mit
# 30,3 % Abweichung). Einzeln auf ruhiger Maschine waren beide gruen, auch
# gegen den Vorstand. Eine Coderegression haette denselben Test getroffen.
#
# Warum nicht aus dem Ziel heraus: ein Ziel, das selten gefahren wird,
# verrottet (#1112). Ein SKIP MIT GRUND haelt den Test im Lauf und sagt
# ausserdem, warum er nicht geurteilt hat — das ist die Form, die dieses
# Projekt bei fehlender Hardware schon benutzt.
#
# Verwendung — nach den eigenen Zaehlern, vor der ersten Messung:
#
#     . "$(dirname "$0")/lib/lastwache.sh"
#     if ! lastwache_ruhig; then
#       echo "SKIP: $LASTWACHE_GRUND"
#       echo "=== PASS=0 FAIL=0"      # eigene Erfolgskonvention
#       exit 0
#     fi
#
# Stellschrauben:
#   LASTWACHE_AUS=1             urteilen erzwingen (Fehlersuche, Nachmessen)
#   LASTWACHE_MAX_LAUFBEREIT    Vorgabe 6
#   LASTWACHE_MIN_ANTEIL        Vorgabe 80 (Prozent des Hoechsttakts)

# Zwei Signale, beide gemessen, beide unmittelbar:
#
# 1. LAUFBEREITE PROZESSE (4. Feld von /proc/loadavg, Zaehler). Gemessen auf
#    dieser Maschine: ruhig 3, unter sechs Rechenlastprozessen 10.
#    Die Schranke steht auf 6 und nicht auf 4: die Wache beschaeftigt fuer
#    die Taktmessung selbst einen Kern und zaehlt sich mit, 4 waere also die
#    Kante gewesen. 6 liegt weit unter dem belasteten Fall.
#    `loadavg[0]` ist dafuer UNBRAUCHBAR und wurde verworfen: es braucht 25 s
#    Anlauf und bleibt nach dem Ende der Last minutenlang hoch — gemessen
#    4,32 im ruhigen Zustand gegen 3,87 im belasteten, also das falsche
#    Vorzeichen.
#
# 2. ERREICHTER TAKT UNTER LAST gegen cpuinfo_max_freq. Das ist das Signal
#    fuer den eigentlich gemeldeten Fall: der i5-8250U ist ein 15-W-Mobilteil,
#    nach stundenlanger Volllast drosselt er. Im roten Lauf rechnete
#    cpu_clock_2401 mit 1,78 GHz, nominal sind 3,4 GHz — 52 %. Gemessen hier:
#    ruhig 97-100 %, unter Last 61 %. Die Schranke steht auf 80 und nicht auf
#    90: beim Lauf der ganzen Messsuite hintereinander erwaermt sich das Teil
#    und ein Test urteilte bei gemessenen 85 % — also noch gutartig. Der
#    gemeldete Schadfall lag bei 52 %.
#
# Der Takt wird UNTER LAST gelesen, nicht im Leerlauf: ein ruhender Kern steht
# im Energiesparzustand und saehe wie gedrosselt aus. Darum beschaeftigt die
# Wache fuer die Dauer der Messung selbst einen Kern.
lastwache_messen() {
  LASTWACHE_LAUFBEREIT=0
  LASTWACHE_TAKT_MHZ=0
  LASTWACHE_MAX_MHZ=0
  LASTWACHE_ANTEIL=0

  local proben=() i c v best ende
  ende=$((SECONDS + 2))
  ( while [ "$SECONDS" -lt "$ende" ]; do :; done ) &
  local bp=$!

  best=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    proben+=("$(cut -d' ' -f4 /proc/loadavg | cut -d/ -f1)")
    for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
      [ -r "$c" ] || continue
      v=$(cat "$c" 2>/dev/null) || continue
      case "$v" in ''|*[!0-9]*) continue ;; esac
      [ "$v" -gt "$best" ] && best="$v"
    done
    sleep 0.1
  done
  kill "$bp" 2>/dev/null
  wait "$bp" 2>/dev/null

  LASTWACHE_LAUFBEREIT=$(printf '%s\n' "${proben[@]}" \
    | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')

  local maxf
  maxf=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
  case "$maxf" in ''|*[!0-9]*) maxf=0 ;; esac
  LASTWACHE_MAX_MHZ=$((maxf / 1000))
  LASTWACHE_TAKT_MHZ=$((best / 1000))
  if [ "$maxf" -gt 0 ] && [ "$best" -gt 0 ]; then
    LASTWACHE_ANTEIL=$((best * 100 / maxf))
  else
    LASTWACHE_ANTEIL=-1    # nicht bestimmbar (kein cpufreq, z. B. in einer VM)
  fi
}

# rc 0: ruhig, es darf geurteilt werden. rc 1: nicht ruhig, LASTWACHE_GRUND
# nennt die GEMESSENE Zahl — eine Auslassung ohne Zahl waere nicht
# nachprueftbar.
lastwache_ruhig() {
  LASTWACHE_GRUND=""
  lastwache_messen

  # Erzwungenes Urteilen MISST trotzdem: die Zahlen gehoeren auch dann ins
  # Protokoll, sonst steht im Nachhinein ein Messwert ohne Bedingungen da.
  if [ "${LASTWACHE_AUS:-0}" = "1" ]; then
    return 0
  fi

  local maxlb="${LASTWACHE_MAX_LAUFBEREIT:-6}"
  local minant="${LASTWACHE_MIN_ANTEIL:-80}"

  if [ "$LASTWACHE_LAUFBEREIT" -gt "$maxlb" ]; then
    LASTWACHE_GRUND="Maschine nicht ruhig: $LASTWACHE_LAUFBEREIT laufbereite Prozesse (Schranke $maxlb) — eine Zeitmessung urteilt hier nicht (#2666)"
    return 1
  fi

  # Nicht bestimmbar heisst nicht "in Ordnung": gemeldet wird, dass dieses
  # Signal fehlt, und geurteilt wird trotzdem — sonst wuerde die Wache auf
  # jeder Maschine ohne cpufreq (VM) alle neun Tests still abschalten.
  if [ "$LASTWACHE_ANTEIL" -lt 0 ]; then
    echo "    (lastwache: kein cpufreq lesbar — Drosselung ungeprueft, laufbereit=$LASTWACHE_LAUFBEREIT)" >&2
    return 0
  fi

  if [ "$LASTWACHE_ANTEIL" -lt "$minant" ]; then
    LASTWACHE_GRUND="CPU gedrosselt oder belegt: ${LASTWACHE_TAKT_MHZ} MHz von ${LASTWACHE_MAX_MHZ} MHz = ${LASTWACHE_ANTEIL} % (Schranke ${minant} %) — eine Zeitmessung urteilt hier nicht (#2666)"
    return 1
  fi

  return 0
}

# Fuer den Bericht im gruenen Fall: die Zahlen gehoeren ins Protokoll, sonst
# ist hinterher nicht entscheidbar, unter welchen Bedingungen gemessen wurde.
lastwache_bericht() {
  echo "    (lastwache: laufbereit=$LASTWACHE_LAUFBEREIT, Takt=${LASTWACHE_TAKT_MHZ}/${LASTWACHE_MAX_MHZ} MHz = ${LASTWACHE_ANTEIL} %)"
}
