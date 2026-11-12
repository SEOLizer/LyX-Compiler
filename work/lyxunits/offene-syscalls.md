# Drei Syscalls, die noch keine Unit kapselt

Stand: 2026-08-27 · Compiler: lyxc 1.1.11A · Bezug: aurum#1810
Empfänger: `lyx-lyxunits` (`~/PhpstormProjects/lyx-lyxunits`)

## Worum es geht

Beim Aufräumen von aurum#1810 habe ich abgeglichen, welche Kernel-Syscalls der
Compiler emittiert, welche `lyx-lyxunits` kapselt, und welche **weder noch**.

Grundlage ist die aus `kernel/ring3.lyx` erzeugte Tabelle (`tools/sync_syscalls.py`,
Stand 2026-08-25, Commit `fac87bc`, 197 belegte Nummern).

Das Ergebnis spricht für die Units: von den 122 Nummern, die der Compiler nicht
emittiert, sind **118 in `lyx-lyxunits` bereits gekapselt**. Übrig bleiben vier,
davon gehören **drei hierher** — die vierte ist Absicht.

(Korrigierte Zahlen, Stand 1.1.11B. Eine frühere Fassung nannte 132/123/neun;
dabei war der dritte Emissionsweg des Compilers — `emitBlockSyscall`, für
Nummern außerhalb der SYSCALL-Whitelist des Bootloaders — nicht mitgezählt.)

## Die drei

| Nr | Aufruf | Signatur (aus `kernel/ring3.lyx`) | passende Unit |
|---:|---|---|---|
| 125 | `sys_fb_map_user` | `()` — bildet die GOP-Framebuffer-Seiten user-zugänglich in die PML4 des Prozesses ab | `lyxos/win.lyx` oder eigene `fb` |
| 327 | `sys_frame_submit` | `(rec_uva)` → Bildnummer | neue `lyxos/frame.lyx` |
| 328 | `sys_frame_stats` | `(out_uva, want)` → Satzzahl | dieselbe |

**327/328 sind neu**: sie kamen am 2026-08-25 mit Commit `a760fd3` in den Kernel
(Frame-Timeline), also nach dem Stand der Units. Die Tabelle vermerkt sie als
Änderung gegenüber der Fassung vom 24.08.

**125** ist älter und dürfte schlicht übersehen worden sein — `lyxos/win.lyx`
deckt 110–115, 130 und 148–152 ab, aber nicht 125.

## Erreichbarkeit — bitte vor dem Kapseln prüfen

Die Pfad-Spalte der erzeugten Tabelle sagt, aus welchem Dispatcher eine Nummer
erreichbar ist:

* **125** — `HW` (`handle_r3_syscall` + `sched_win_dispatch`): aus einem
  Ring-3-Programm wie aus einem Scheduler-Kind erreichbar.
* **327/328** — nur `P` (`posix_ext`). Das ist ein anderer Weg als bei den
  übrigen Fenster-Aufrufen. Ob ein gewöhnliches Programm sie über den
  Block-Mechanismus (`mmap(-5)`/`mmap(-6)`) erreicht, habe ich **nicht**
  gemessen — das gehört vor dem Kapseln geprüft, sonst entsteht eine Funktion,
  die still nichts tut.

Das ist keine Formalie: bei `sys_notify_wait` (239) hat genau diese Spalte
gezeigt, dass der Aufruf nur in `SchedVfsStep` steht und aus Ring 3 gar nicht
erreichbar ist.

## Was NICHT hierher gehört

Zur Vollständigkeit, damit die Liste nicht doppelt bearbeitet wird:

* **92, 93, 94, 133** (`setenv`, `getenv`, `envlist`, `envlistbuf`) — Umgebungs-
  variablen gibt es unter POSIX. Nach eurer Aufnahmeregel ausgeschlossen; sie
  gehören hinter `std.env` und damit in den Compiler. **Erledigt** mit 1.1.11B.
* **140** (`sys_utime_fd`) — war in einer früheren Fassung dieser Liste als offen
  geführt. Das war falsch: der Compiler bindet ihn längst (Builtin-ID 215 über
  `emitBlockSyscall`).
* **516** (`sys_seek`) — **bewusst nichts.** Der Kernel behandelt `0x0204` und
  `8` im selben Zweig (`nr == 0x0204 || nr == 8`), ausdrücklich beabsichtigt.
  Der Compiler emittiert `8`. Siehe aurum#1794.

## Nebenbefund, der euch betrifft

`hardware.i2c/usb/gpio/spi` setzen im Manifest das CAPS-TLV-Bit `0x100`, aber
`lbf_map_caps` (`kernel/lbf_exec.lyx`) bildet nur 1, 2, 4, 8, 0x40 und 0x80 ab.
Das Bit wird ignoriert, `PLEDGE_DEVICE` wird nie aus dem Manifest gesetzt — ein
Programm mit `@capabilities([hardware.i2c])` bekommt das Recht nicht. Erfasst
als aurum#1815; die Zeile gehört in den Kernel, nicht in die Units.

Wer `lyxos/driver.lyx` benutzt, sollte das wissen: die Unit ruft 230–255, aber
die Berechtigung dafür kommt derzeit nicht aus dem Manifest.
