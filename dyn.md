# Dynamisches Linking – Fehlersuche

## Erkenntnisse

*   Das generierte ELF-Binary `test_dynlink` stürzt mit einem "Ungültiger Maschinenbefehl" (Exit Code 132) ab. Dies deutet auf eine fehlerhafte Instruktionssequenz im ausgeführten Code hin.
*   `readelf -s --dyn-syms` liefert keine dynamischen Symbolinformationen. Dies könnte darauf hindeuten, dass die `.dynsym`-Sektion entweder nicht korrekt befüllt oder nicht richtig in den ELF-Strukturen referenziert wird.
*   `objdump -d -j .plt` und `objdump -d -j .text` schlagen fehl, da die Sektionen `.plt` und `.text` nicht gefunden werden. Obwohl dies bei PIE-Executables ohne explizite Sektionstabellen normal sein kann, erschwert es die Analyse des generierten Maschinencodes erheblich.
*   Die `readelf -d` Ausgabe zeigt, dass `DT_NEEDED` für `libc.so.6` korrekt in der Dynamic Section vorhanden ist.
*   Die `readelf -r --use-dynamic` Ausgabe zeigt zwei Relocation-Einträge, die auf den ersten Blick korrekt erscheinen:
    *   `0x000000002078 R_X86_64_RELATIVE 20c8`: Dies ist die Relocation für GOT[0], die auf die `.dynamic`-Sektion (bei Offset `0x20c8`) verweist.
    *   `0x000000002090 000100000007 R_X86_64_JUMP_SLO 0000000000000000 strlen + 0`: Dies ist die Relocation für `strlen` im `.got.plt` (GOT-Eintrag 3). Der Offset `0x2090` scheint passend, da GOT[3] bei `gotOff + 24` beginnt und `strlen` das erste externe Symbol ist (Index 0).
*   Das Problem liegt sehr wahrscheinlich im generierten Maschinencode der PLT-Stubs, in der Initialisierung oder Auflösung der GOT-Einträge durch den Dynamic Linker oder im Übergang vom `_start`-Symbol zur `main`-Funktion. Ein fehlerhafter `pchar`-Zugriff oder String-Literal-Handling kann ebenfalls die Ursache sein.

## TODOs

1.  **Sektionstabellen für Debugging aktivieren:** Temporär Sektionstabellen im `elf64_writer.pas` generieren. Dies würde `objdump` und andere Analyse-Tools ermöglichen, `.plt` und `.text` Sektionen korrekt zu finden und zu disassemblieren, was die Fehlersuche erheblich vereinfachen würde.
2.  **Manuelle Disassemblierung des PLT- und Code-Bereichs:**
    *   Die genauen Offsets des PLT0 und des `strlen`-PLT-Stubs innerhalb des generierten Binaries ermitteln.
    *   Den Code-Bereich im `.text`-Abschnitt lokalisieren, der die Funktion `strlen` aufruft.
    *   Die relevanten Bytes aus diesen Bereichen mit `dd` extrahieren und dann manuell disassemblieren (z.B. mit `ndisasm` oder durch `xxd` und anschließende Analyse des Hex-Codes).
    *   Besonderes Augenmerk auf die korrekte Struktur der `jmp`- und `push`-Instruktionen in den PLT-Stubs sowie auf die korrekte Adressierung der GOT-Einträge legen.
3.  **Überprüfung der GOT-Einträge im Binary:** Die initialen Werte der Global Offset Table (GOT)-Einträge im erzeugten Binary direkt mit `hexdump` überprüfen. Sicherstellen, dass GOT[0], GOT[1] und GOT[2] sowie die Einträge für `strlen` korrekt initialisiert sind (insbesondere der Eintrag für `strlen` sollte initial auf PLT0 verweisen, bevor der Dynamic Linker ihn auflöst).
4.  **Validierung des Entry Points (`e_entry`):** Sicherstellen, dass der `e_entry` im ELF-Header (derzeit `0x1000`) korrekt ist und auf den tatsächlichen Start des Codes (`_start`) im Binary zeigt. Dies ist entscheidend für den Programmstart.
5.  **Handling von `pchar` und String-Literalen:** Überprüfen, wie der String "Hello World" im `.data`-Abschnitt gespeichert wird und ob der `pchar`-Typ korrekt in die entsprechenden Adressen aufgelöst wird. Ein fehlerhafter String-Pointer könnte zu einem ungültigen Speicherzugriff führen.
