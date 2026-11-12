#!/bin/bash
# #1726 — `make bootstrap` muss aus einem frischen Checkout heraus laufen.
#
# `bootstrap` haengt von `lyxc` ab, aber es gab keine Regel dieses Namens: das
# Ziel war die gebaute Binary im Wurzelverzeichnis, und die ist git-ignoriert.
# Wer den Baum klonte und `make bootstrap` rief, bekam
#   make: *** Keine Regel vorhanden, um das Ziel „lyxc" ... zu erstellen.
# obwohl der Seed unter src/lyxc_bootstrap versioniert danebenliegt.
#
# Im Arbeitsbaum faellt das NIE auf, weil dort immer eine Binary herumliegt —
# genau deshalb legt dieser Test einen eigenen Worktree an, in dem keine ist.
#
# Geprueft wird die Regel, nicht der ganze Bau: ein vollstaendiger Bootstrap
# dauert Minuten und braucht Ressourcen, die in einer CI knapp sind. Dass der
# Compiler baut, sagen die uebrigen Ziele ohnehin.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1${2:+ — $2}"; F=$((F+1)); }

if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "SKIP: kein Git-Baum — der Worktree-Fall ist hier nicht pruefbar"
  echo "Ergebnis: 0 PASS, 0 FAIL"
  exit 0
fi

WT="$(mktemp -d)/frisch"
if ! git -C "$ROOT" worktree add -q --detach "$WT" HEAD 2>/dev/null; then
  echo "SKIP: Worktree liess sich nicht anlegen"
  echo "Ergebnis: 0 PASS, 0 FAIL"
  rm -rf "$(dirname "$WT")"
  exit 0
fi
aufraeumen() { git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$(dirname "$WT")"; }
trap aufraeumen EXIT

# Geprueft wird der Makefile DIESES Baums, nicht der zuletzt eingecheckte —
# sonst misst der Test den Stand von HEAD und meldet gruen, waehrend die
# Aenderung im Arbeitsbaum noch kaputt ist (oder umgekehrt).
cp "$ROOT/Makefile" "$WT/Makefile"

# 1: im frischen Baum liegt keine Binary, aber der Seed
if [ -f "$WT/lyxc" ]; then
  bad "frischer Baum ohne ./lyxc" "es liegt doch eine da — der Test misst dann nichts"
elif [ ! -f "$WT/src/lyxc_bootstrap" ]; then
  bad "Seed im frischen Baum" "src/lyxc_bootstrap fehlt"
else
  ok "frischer Baum: keine Binary, Seed vorhanden"
fi

# 2: make findet eine Regel fuer lyxc — das war der eigentliche Defekt
log="$WT/mk.log"
if make -C "$WT" -n bootstrap >"$log" 2>&1; then
  if grep -qi 'Keine Regel\|No rule to make target' "$log"; then
    bad "make kennt eine Regel fuer lyxc" "$(grep -i 'Keine Regel\|No rule' "$log" | head -1)"
  else
    ok "make kennt eine Regel fuer lyxc"
  fi
else
  if grep -qi 'Keine Regel\|No rule to make target' "$log"; then
    bad "make kennt eine Regel fuer lyxc" "$(grep -i 'Keine Regel\|No rule' "$log" | head -1)"
  else
    bad "make -n bootstrap" "$(tail -1 "$log")"
  fi
fi

# 3: die Regel liefert wirklich eine lauffaehige Binary aus dem Seed
if make -C "$WT" lyxc >"$log" 2>&1 && [ -x "$WT/lyxc" ]; then
  if "$WT/lyxc" --version >/dev/null 2>&1; then
    ok "aus dem Seed entsteht ein lauffaehiges ./lyxc"
  else
    bad "aus dem Seed entsteht ein lauffaehiges ./lyxc" "laesst sich nicht ausfuehren"
  fi
else
  bad "make lyxc" "$(tail -1 "$log")"
fi

# 4: ein vorhandenes ./lyxc darf die Regel NICHT ueberschreiben — sonst waere
#    nach jedem Verankern des Seeds der gerade gebaute Compiler weg.
printf 'markierung' > "$WT/lyxc"; chmod +x "$WT/lyxc"
touch -d '1 hour ago' "$WT/lyxc"          # aelter als der Seed
make -C "$WT" lyxc >"$log" 2>&1
if [ "$(cat "$WT/lyxc")" = "markierung" ]; then
  ok "vorhandenes ./lyxc bleibt unangetastet, auch wenn der Seed neuer ist"
else
  bad "vorhandenes ./lyxc bleibt unangetastet" "wurde ueberschrieben"
fi

echo "Ergebnis: $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
