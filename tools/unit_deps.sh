#!/usr/bin/env bash
# tools/unit_deps.sh — Make-Abhaengigkeiten der Vorkompilate aus den Importen (#2622)
#
# WARUM. Die Musterregel fuer ein .lyu nannte als Abhaengigkeiten nur die
# eigene .lyx und den Compiler. Aendert sich eine Unit, die viele andere
# importieren (std.net.tls13, std.crypto.hkdf, std.string), gelten deren
# Vorkompilate weiter als aktuell, und `make units-baeume` baut sie nicht neu.
# Gemessen in #2622: std/net/http.lyu und std/cloud/s3.lyu blieben nach einer
# Aenderung an tls13.lyx stehen -- die Drift war nicht am Rueckgabewert
# sichtbar, sondern erst am sha256 gegen einen Neubau.
#
# WAS DIE RICHTIGE ABHAENGIGKEIT IST -- gemessen, nicht angenommen. Der Bau
# ruft `lyxc --std-path=.`, und der Aufloeser bevorzugt .lyx vor .lyu: beim
# Uebersetzen von std/net/http.lyx oeffnet lyxc std/net/tls13.lyx und von dort
# weiter tls_config/tls_kern/tls12 -- also die QUELLEN, transitiv, und nicht
# die Vorkompilate daneben. Darum nennt dieses Werkzeug die transitive Huelle
# der importierten .lyx und NICHT die .lyu der Importe.
#   Nachmessen: strace -f -e trace=%file ./lyxc --std-path=. --compile-unit \
#               std/net/http.lyx -o /tmp/x.lyu   (tests/unit_deps_2622_test.sh
#               haelt die Huelle genau dagegen)
#
# AUSGABE. Make-Regeln, die auf $(UNITS_DST)/$(DATA_DST) verweisen. Die beiden
# Variablen haengen an LYU_ARCH und werden erst beim Einlesen aufgeloest --
# eine erzeugte Datei gilt damit fuer JEDEN Unit-Baum, nicht nur fuer den, bei
# dessen Bau sie entstand.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"

LC_ALL=C awk '
  # ---- Einsammeln: direkte Importe je Quelldatei -------------------------
  FNR == 1 { datei = FILENAME; alle[datei] = 1 }
  /^[[:space:]]*import[[:space:]]+[A-Za-z0-9_.]+[[:space:]]*;/ {
    zeile = $0
    sub(/^[[:space:]]*import[[:space:]]+/, "", zeile)
    sub(/[[:space:]]*;.*$/, "", zeile)
    gsub(/\./, "/", zeile)
    ziel = zeile ".lyx"
    if (!(datei SUBSEP ziel in kante)) {
      kante[datei, ziel] = 1
      n = ++anz[datei]
      imp[datei, n] = ziel
    }
  }
  # ---- Huelle bilden und ausgeben ----------------------------------------
  END {
    print "# erzeugt von tools/unit_deps.sh (#2622) -- nicht von Hand aendern."
    print "# Je Vorkompilat die TRANSITIVE Huelle der importierten Quellen."
    fehlt = 0
    for (d in alle) {
      # Breitensuche ueber die Importe; besucht[] bricht Zyklen ab.
      for (k in besucht) delete besucht[k]
      kopf = 1; schwanz = 0
      schwanz++; schlange[schwanz] = d; besucht[d] = 1
      liste = ""
      while (kopf <= schwanz) {
        akt = schlange[kopf]; kopf++
        for (i = 1; i <= anz[akt]; i++) {
          nxt = imp[akt, i]
          if (nxt in besucht) continue
          besucht[nxt] = 1
          if (!(nxt in alle)) {
            # Ein Import ohne Quelldatei ist keine Nachlaessigkeit, die man
            # ueberspringt: dann ist die Abbildung Modulname -> Pfad falsch
            # und die erzeugten Regeln sind unvollstaendig.
            print "unit_deps: Import ohne Quelldatei: " nxt " (aus " akt ")" > "/dev/stderr"
            fehlt++
            continue
          }
          schwanz++; schlange[schwanz] = nxt
          liste = liste " " nxt
        }
      }
      if (liste == "") continue
      rel = d
      if (rel ~ /^std\//)       { sub(/^std\//,  "", rel); var = "$(UNITS_DST)" }
      else if (rel ~ /^data\//) { sub(/^data\//, "", rel); var = "$(DATA_DST)"  }
      else { print "unit_deps: unerwarteter Pfad: " d > "/dev/stderr"; fehlt++; continue }
      sub(/\.lyx$/, ".lyu", rel)
      print var "/" rel ":" liste
    }
    if (fehlt > 0) exit 1
  }
' $(find std data -name '*.lyx' | sort)
