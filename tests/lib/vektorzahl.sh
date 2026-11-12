# tests/lib/vektorzahl.sh — Vektorbefehle im Erzeugnis zaehlen, ueber
# BEFEHLSGRENZEN statt ueber Bytes (#1370, #2335).
#
# Warum es diese Datei gibt: drei Tests (#2194, #2334, #2335) brauchen
# dieselbe Auskunft, und ein Zaehler ueber rohe Bytes beantwortet sie FALSCH.
# Zweimal am 2026-10-31 passiert, beide Male derselbe `call rel32`:
#
#     e8 c5 d1 fe ff        call  <ziel>
#        ^^          ^^
#        C5          FE (PADDD)
#
# Die Verschiebung beginnt mit C5, und das Folgebyte erfuellt auch noch die
# VEX-Strukturpruefung (pp == 01). Eine Codegen-Aenderung, die nur eine
# SPRUNGWEITE verschiebt, macht so einen Test rot oder gruen — er war vorher
# gruen durch Zufall, wie #2244.
#
# `objdump -d` auf das fertige Programm hilft nicht: ein Lyx-Erzeugnis hat
# KEINE ELF-Sektionen ("Es gibt keine Sektionen in dieser Datei"), objdump
# disassembliert daran gar nichts und meldet 0 — auch dort, wo die Befehle
# nachweislich stehen. Ein so gebauter Zaehler ist immer gruen.
#
# Der Ausweg ist `--emit=obj`: das Objekt TRAEGT Sektionen, `objdump -d`
# dekodiert `.text` von einer echten Befehlsgrenze aus, und eine
# Sprungweite kann keinen Befehl mehr vortaeuschen. So macht es
# tests/register_kandidaten_test.sh seit #2114.
#
# Verwendung — EINE Zeile nach der LYXC-Zuweisung:
#
#     . "$ROOT/tests/lib/vektorzahl.sh"
#
# Dann:
#     n=$(vek_zahl "$TMP/werte.lyx" 'padd[bwd]|vpadd[bwd]')
#     n=$(vek_zahl "$TMP/mul.lyx" 'pmulld|vpmulld' --target-cpu=sse4)
#
# Erwartet wird die QUELLE, nicht das Programm — das Objekt entsteht hier neu,
# und die Schalter muessen deshalb MITGEGEBEN werden. Wer sie vergisst,
# uebersetzt mit der Vorgabe-CPU und bekommt bei einer Gating-Pruefung eine
# Null, die nach "nicht emittiert" aussieht.
#
# Rueckgabe -1, wenn das Objekt nicht entsteht — ein Fehlschlag, keine Null,
# sonst verbucht der Aufrufer "nicht uebersetzbar" als "kein Vektorbefehl".

# Die Ressourcengrenze aus #1294 gilt auch hier: `vek_zahl` ruft den Compiler
# auf, und ein Lauf ohne Deckel kann den Rechner leerfressen. Eingebunden wird
# sie HIER, nicht nur beim Aufrufer — dann stimmt der Schutz unabhaengig von
# der Einbindereihenfolge, und `lyxc_guard_coverage_test.sh` sieht ihn auch.
# Die Bibliothek ist idempotent (_LYXC_GUARD_ACTIVE), ein zweites Einbinden
# beim Aufrufer bleibt also wirkungslos.
_vz_g="$(dirname "${BASH_SOURCE[0]}")/lyxc_guard.sh"
[ -f "$_vz_g" ] && . "$_vz_g"

vek_zahl() {   # <lyx-Quelle> <Mnemonik-Regex> [Schalter...] -> Anzahl, -1 bei Fehler
  local _src="$1"
  local _pat="$2"
  shift 2
  local _o="${TMP:-/tmp}/vekzahl_$$.o"
  rm -f "$_o"
  (cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$@" --emit=obj "$_src" -o "$_o" >/dev/null 2>&1)
  if [ ! -s "$_o" ]; then echo "-1"; return; fi
  objdump -d -z --no-show-raw-insn "$_o" 2>/dev/null | grep -cE "[[:space:]](${_pat})[[:space:]]"
  rm -f "$_o"
}
