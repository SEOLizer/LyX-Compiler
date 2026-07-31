# free(): verbleibende einargumentige Aufrufstellen (Issue #995)

Stand nach der Vorbereitung. Alle uebrigen Aufrufe im Projekt nutzen bereits
die Form `free(ptr, size)`. Solange diese Liste nicht leer ist, darf das
`free`-Builtin in src/codegen_x86.lyx NICHT auf munmap umgestellt werden --
bei einer einargumentigen Stelle stuende dann Muell als Laenge in rsi.
**67 Stellen offen.**


| Datei | Zeile | Aufruf | Groesse woher? |
|---|---|---|---|
| `std/zstd.lyx` | 168 | `free(tab)` | offen |
| `std/zstd.lyx` | 252 | `free(symArr)` | offen |
| `std/zstd.lyx` | 252 | `free(symNext)` | offen |
| `std/zstd.lyx` | 353 | `free(probs)` | offen |
| `std/zstd.lyx` | 362 | `free(probs)` | offen |
| `std/zstd.lyx` | 371 | `free(probs)` | offen |
| `std/zstd.lyx` | 484 | `free(peek64(t + 392))` | offen |
| `std/zstd.lyx` | 679 | `free(lens)` | offen |
| `std/zstd.lyx` | 854 | `free(wbr)` | offen |
| `std/zstd.lyx` | 887 | `free(litBuf)` | offen |
| `std/zstd.lyx` | 927 | `free(rbr1)` | offen |
| `std/zstd.lyx` | 927 | `free(rbr2)` | offen |
| `std/zstd.lyx` | 927 | `free(rbr3)` | offen |
| `std/zstd.lyx` | 927 | `free(rbr4)` | offen |
| `std/zstd.lyx` | 976 | `free(probs)` | offen |
| `std/zstd.lyx` | 1093 | `free(litBuf)` | offen |
| `std/zstd.lyx` | 1116 | `free(litBuf)` | offen |
| `std/zstd.lyx` | 1144 | `free(litBuf)` | offen |
| `std/brotli.lyx` | 331 | `free(syms)` | offen |
| `std/brotli.lyx` | 415 | `free(lens)` | offen |
| `std/brotli.lyx` | 469 | `free(lens)` | offen |
| `std/brotli.lyx` | 665 | `free(win)` | offen |
| `std/brotli.lyx` | 799 | `free(modes)` | offen |
| `std/brotli.lyx` | 803 | `free(cmL)` | offen |
| `std/brotli.lyx` | 804 | `free(cmD)` | offen |
| `std/brotli.lyx` | 822 | `free(tL)` | offen |
| `std/brotli.lyx` | 833 | `free(tI)` | offen |
| `std/brotli.lyx` | 843 | `free(tD)` | offen |
| `std/iso.lyx` | 270 | `free(raw)` | offen |
| `std/iso.lyx` | 274 | `free(raw)` | offen |
| `std/iso.lyx` | 280 | `free(raw)` | offen |
| `std/iso.lyx` | 329 | `free(dirPath2)` | offen |
| `std/iso.lyx` | 339 | `free(peek64(queue + bfsi2 * 24 + 16))` | offen |
| `std/iso.lyx` | 345 | `free(queue)` | offen |
| `std/iso.lyx` | 358 | `free(name)` | offen |
| `std/iso.lyx` | 361 | `free(entries)` | offen |
| `std/iso.lyx` | 362 | `free(peek64(handle))` | offen |
| `std/iso.lyx` | 637 | `free(image)` | offen |
| `std/iso.lyx` | 638 | `free(lbaArr)` | offen |
| `std/iso.lyx` | 651 | `free(name)` | offen |
| `std/iso.lyx` | 654 | `free(entries)` | offen |
| `std/zip.lyx` | 133 | `free(raw)` | offen |
| `std/zip.lyx` | 138 | `free(raw)` | offen |
| `std/zip.lyx` | 143 | `free(raw)` | offen |
| `std/zip.lyx` | 148 | `free(raw)` | offen |
| `std/zip.lyx` | 149 | `free(raw)` | offen |
| `std/zip.lyx` | 217 | `free(name)` | offen |
| `std/zip.lyx` | 220 | `free(entries)` | offen |
| `std/zip.lyx` | 221 | `free(peek64(handle))` | offen |
| `std/zip.lyx` | 590 | `free(buf)` | offen |
| `std/zip.lyx` | 590 | `free(offsets)` | offen |
| `std/zip.lyx` | 590 | `free(compBuf)` | offen |
| `std/zip.lyx` | 603 | `free(peek64(entry))` | offen |
| `std/zip.lyx` | 604 | `free(peek64(entry + 8))` | offen |
| `std/zip.lyx` | 607 | `free(entries)` | offen |
| `std/tar.lyx` | 161 | `free(raw)` | offen |
| `std/tar.lyx` | 228 | `free(entries)` | offen |
| `std/tar.lyx` | 229 | `free(peek64(handle))` | offen |
| `std/tar.lyx` | 428 | `free(buf)` | offen |
| `std/tar.lyx` | 441 | `free(peek64(entry))` | offen |
| `std/tar.lyx` | 442 | `free(peek64(entry + 8))` | offen |
| `std/tar.lyx` | 445 | `free(entries)` | offen |
| `std/rar.lyx` | 103 | `free(raw)` | offen |
| `std/rar.lyx` | 115 | `free(raw)` | offen |
| `std/rar.lyx` | 235 | `free(name)` | offen |
| `std/rar.lyx` | 238 | `free(entries)` | offen |
| `std/rar.lyx` | 239 | `free(peek64(handle))` | offen |
