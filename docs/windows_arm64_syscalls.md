{
  Windows ARM64 Syscall-Nummern und API-Informationen

  WICHTIG: Diese Werte können sich je nach Windows-Version ändern!
  Die folgenden Werte sind für Windows 10/11 ARM64.

  ========================
  Windows ARM64 Syscall-Mechanismus
  ========================

  Windows ARM64 verwendet einen "Supervisor Call" (SVC) Mechanismus ähnlich wie Linux,
  aber mit einem anderen Dispatch-Mechanismus:

  - Der SVC-Opcode ist 0xD4000001 (SVC #0)
  - Die Syscall-Nummer wird in X16 (oder W16) übergeben
  - Die Parameter werden in X0-X5 übergeben (gemäß AAPCS64)
  - Der Return-Wert ist in X0

  ========================
  Wichtige Syscall-Nummern (Windows 11 ARM64)
  ========================

  Achtung: Diese Nummern sind nicht offiziell dokumentiert und können variieren!
  Die zuverlässigere Methode ist die Verwendung von kernel32.dll/ntdll.dll Imports.

  Häufig verwendete Funktionen:
  - NtExitProcess / RtlExitUserProcess: Prozess beenden
  - NtWriteFile / WriteFile: In Datei/Console schreiben
  - NtReadFile / ReadFile: Aus Datei/Console lesen
  - NtCreateFile / CreateFile: Datei erstellen/öffnen

  ========================
  Empfohlener Ansatz für Lyx
  ========================

  Statt direkte Syscalls zu verwenden (was instabil ist), sollten wir:

  1. Den PE-Import-Table nutzen, um Funktionen aus kernel32.dll zu importieren:
     - ExitProcess
     - WriteFile
     - ReadFile
     - CreateFileA/W
     - GetStdHandle
     - etc.

  2. Der PE64 ARM64 Writer (pe64_arm64_writer.pas) muss diese Imports
     korrekt in die Import Address Table (IAT) eintragen.

  3. Der ARM64-Code muss dann calls zu diesen importierten Funktionen
     anstelle von Syscalls verwenden.

  ========================
  Windows ARM64 Calling Convention
  ========================

  Parameter-Übergabe ( AAPCS64 ):
  - X0-X7: Parameter-Register
  - X0: Return-Wert
  - X16/X17: Scratch-Register (für Syscalls verwendet)
  - X30: Link Register (LR) für Rückkehr

  Stack-Alignment:
  - 16-Byte-Alignment erforderlich am Ende des Prologus

  ========================
  Beispiel: ExitProcess Aufruf
  ========================

  Der einfachste Weg für "exit(code)" ist:

  1. Importiere "ExitProcess" aus kernel32.dll
  2. Im Code:
     MOV  X0, code      ; Exit-Code in X0
     LDR  X16, [X16, #0]  ; Load Address of ExitProcess from IAT (X16 zeigt auf IAT)
     BLR  X16           ; Branch with Link to ExitProcess

  Oder einfacher mit direktem CALL:
     LDR  X16, [X16, #Offset]  ; Load ExitProcess Address from IAT
     BLR  X16

  Die IAT wird vom Loader zur Laufzeit mit den echten Adressen gefüllt.

  ========================
  Quellen
  ========================

  - https://github.com/ikermit/11Syscalls (Windows 11 Syscall-Tabellen)
  - https://gracefulbits.wordpress.com/2018/07/26/system-call-dispatching-for-windows-on-arm64/
  - Wine ARM64 Emulation Code
  - ReactOS/Wine Quellcode für ntdll

}
