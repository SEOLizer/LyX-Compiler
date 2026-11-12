#!/usr/bin/env bash
# tests/attribut_an_funktion_test.sh — Attribute vor einer Funktion (#1254).
#
# `iVal`-Bit 0 heisst an einer FREIEN FUNKTION "extern" (sema, WP-L5). Genau
# dieses Bit setzten aber auch `@volatile` (VAR_FLAG_VOLATILE == 1) und
# `@export` (ANNO_EXPORT == 1), wenn das Attribut vor einer Funktion stand:
#
#     @volatile
#     fn F(x: int64): int64 { return x + 1; }
#
#   -> sema error: extern fn: unbekanntes FFI-Symbol erfordert eine
#      Capability-Angabe (FFI-Sandbox Fail-Closed)
#
# Eine Meldung ueber FFI fuer ein Attribut, das mit FFI nichts zu tun hat.
# Dazu kam, dass die drei Stellen im Parser `iVal` ZUWIESEN statt das Bit zu
# ODERN — die @redundant-Zeile daneben machte es richtig.
#
# Aufgefallen bei der Doku-Erhebung zu #1254 (guides/rtos-embedded-concurrency).
#
# Der WICHTIGSTE Fall steht unten: die FFI-Sandbox muss weiterhin greifen. Wer
# hier nur prueft, dass `@volatile fn` meldet, wuerde nicht merken, wenn der
# Fix das Extern-Bit gleich mit abgeraeumt haette — und damit eine
# Sicherheitszusage.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

uebersetzt() {  # name, quelle
  printf '%s\n' "$2" > "$TMP/t.lyx"
  if timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" >"$TMP/t.log" 2>&1; then
    ok "$1"
  else
    no "$1" "$(grep -im1 'error' "$TMP/t.log")"
  fi
}

meldet() {  # name, quelle, erwarteter Meldungsteil
  printf '%s\n' "$2" > "$TMP/t.lyx"
  if timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" >"$TMP/t.log" 2>&1; then
    no "$1" "uebersetzte klaglos"
  else
    case "$(cat "$TMP/t.log")" in
      *"$3"*) ok "$1" ;;
      *) no "$1" "andere Meldung: $(grep -im1 'error' "$TMP/t.log")" ;;
    esac
  fi
}

# ── @volatile gehoert an eine VARIABLE ─────────────────────────────────────
meldet "volatile_an_funktion_meldet" \
  '@volatile
fn F(x: int64): int64 { return x + 1; }
fn main(): int64 { return F(1); }' "@volatile gilt nur fuer Variablen"

# Und die Meldung nennt NICHT die FFI-Sandbox — das war der irrefuehrende Teil.
printf '@volatile\nfn F(x: int64): int64 { return x + 1; }\nfn main(): int64 { return F(1); }\n' > "$TMP/v.lyx"
timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/v.lyx" -o "$TMP/v" >"$TMP/v.log" 2>&1
case "$(cat "$TMP/v.log")" in
  *"FFI-Sandbox"*) no "meldung_spricht_nicht_von_ffi" "nennt weiterhin die FFI-Sandbox" ;;
  *) ok "meldung_spricht_nicht_von_ffi" ;;
esac

# An einer Variablen wirkt es weiterhin — sonst waere die Regel nur eine Sperre.
printf '@volatile\nvar reg: int64 := 0;\nfn main(): int64 { reg := 5; return reg; }\n' > "$TMP/vv.lyx"
if timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/vv.lyx" -o "$TMP/vv" >"$TMP/vv.log" 2>&1; then
  timeout 20 "$TMP/vv" >/dev/null 2>&1
  [ $? -eq 5 ] && ok "volatile_an_variable_wirkt" || no "volatile_an_variable_wirkt" "falscher Rueckgabewert"
else
  no "volatile_an_variable_wirkt" "$(grep -im1 'error' "$TMP/vv.log")"
fi

# ── @export vor einer Funktion ist kein extern fn ──────────────────────────
uebersetzt "export_an_funktion_ist_kein_extern" \
  '@export
fn F(x: int64): int64 { return x + 1; }
fn main(): int64 { return F(1); }'

# Weitere Attribute, die schon vorher durchgingen — Gegenprobe, dass der Fix
# ihnen nichts genommen hat.
uebersetzt "redundant_an_funktion" \
  '@redundant
fn F(x: int64): int64 { return x + 1; }
fn main(): int64 { return F(1); }'
uebersetzt "flight_crit_an_funktion" \
  '@flight_crit
fn F(x: int64): int64 { return x + 1; }
fn main(): int64 { return F(1); }'

# ── Die FFI-Sandbox bleibt scharf ──────────────────────────────────────────
# Das ist der eigentliche Nachweis: Bit 0 wird an einer ECHTEN extern-Deklaration
# weiterhin gesetzt, und die Sandbox greift.
meldet "ffi_sandbox_greift_weiterhin" \
  'extern fn irgendwas(a: int64): int64 link "libfremd.so";
fn main(): int64 { return irgendwas(1); }' "FFI-Sandbox"

# Auch mit @export DAVOR — hier haette ein Zuweisen statt Odern das Bit
# geloescht und die Sperre still aufgehoben.
meldet "ffi_sandbox_greift_auch_mit_export" \
  '@export
extern fn irgendwas2(a: int64): int64 link "libfremd.so";
fn main(): int64 { return 0; }' "FFI-Sandbox"

# Mit Capability-Angabe geht es durch und ruft wirklich in die libc.
printf '@cap(system.exit)\nextern fn strlen(s: pchar): int64 link "libc.so.6";\nfn main(): int64 { return strlen("abcd"c); }\n' > "$TMP/c.lyx"
if timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >"$TMP/c.log" 2>&1; then
  timeout 20 "$TMP/c" >/dev/null 2>&1
  [ $? -eq 4 ] && ok "extern_mit_cap_ruft_libc" || no "extern_mit_cap_ruft_libc" "falscher Rueckgabewert"
else
  no "extern_mit_cap_ruft_libc" "$(grep -im1 'error' "$TMP/c.log")"
fi

echo "== attribut_an_funktion_test: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
