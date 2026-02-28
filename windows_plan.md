# Plan zur Unterstützung von Lyx auf Windows ARM64 (PE32+)

## 1. Einführung und Ziele

Ziel dieses Plans ist es, den Lyx-Compiler so zu erweitern, dass er ausführbare PE32+-Dateien (Portable Executable) für die Windows ARM64-Plattform generieren kann. Dies umfasst die Anpassung des Backends, die Integration von Windows-spezifischen APIs und Syscalls sowie die Adressierung der Herausforderung, den Compiler selbst auf einer Windows-Umgebung zu kompilieren, da er derzeit stark von Linux-Bibliotheken abhängt.

## 2. Aktueller Status und Herausforderungen

*   Der Lyx-Compiler ist derzeit für Linux x86_64, ELF64 ausgelegt.
*   Es gibt ein bestehendes ARM64 Instruction Encoding (`arm64_emit.pas`).
*   Der Compiler verwendet FreePascal (FPC 3.2.2).
*   Die größte Herausforderung besteht darin, den Lyx-Compiler, der auf Linux-Bibliotheken angewiesen ist, auf Windows zu kompilieren und zu betreiben, um Windows ARM64-Binaries zu erstellen.

## 3. Strukturierter Plan

### Aufgabe 1: Neuer PE64 ARM64 Writer (`pe64_arm64_writer.pas`)

**Beschreibung**: Implementierung des Dateiformat-Writers für PE32+-Dateien, die auf Windows ARM64 ausgeführt werden können.

**Schritte**:
1.  **Analyse des PE32+-Formats**: Detaillierte Recherche der PE32+-Spezifikation für ARM64 (Header, Sektionen, Importe, Exporte, Relocations).
2.  **Erstellung der Unit**: Anlegen der Datei `backend/win_arm64/pe64_arm64_writer.pas`.
    *Anmerkung: Dies wurde von `backend/elf/` zu `backend/win_arm64/` geändert, um die plattformspezifische Trennung zu verbessern.*
3.  **Implementierung des Headers**: Schreiben der PE-Header, Optional Header (für PE32+) mit `IMAGE_FILE_MACHINE_ARM64 ($AA64)`.
4.  **Implementierung der Sektionen**: Behandlung der `.text`, `.data`, `.rdata` und anderer relevanter Sektionen.
5.  **Integration des ARM64 Instruction Encoding**: Nutzung der vorhandenen Funktionalitäten aus `backend/x86_64/x86_64_emit.pas` als Vorlage und Anpassung an `backend/arm64/arm64_emit.pas`.
6.  **Einstiegspunkt (`_start`)**: Implementierung des spezifischen Windows ARM64-Einstiegspunkts, der `main()` aufruft und dann `ExitProcess` (oder entsprechenden Syscall) verwendet.

**Abhängigkeiten**:
*   Verständnis des PE32+-Formats.
*   Vorhandensein des `arm64_emit.pas` für Instruktions-Encoding.
*   Zugriff auf die Syscall-Nummern für Windows ARM64 (siehe Aufgabe 3).

**Risiken**:
*   Komplexität des PE32+-Formats, insbesondere Relocations und Import/Export-Tabellen.
*   Fehler bei der Header-Konfiguration können zu nicht ausführbaren Binaries führen.

**Akzeptanzkriterien**:
*   Generierung einer validen, minimalen "Hello World"-PE32+-Datei für ARM64.
*   Die generierte Datei lässt sich auf einer Windows ARM64-Umgebung ausführen und liefert den erwarteten Output.

---

### Aufgabe 2: Windows API Adapter für ARM64

**Beschreibung**: Bereitstellung von Schnittstellen für Windows-spezifische APIs, die Lyx-Programme nutzen können.

**Schritte**:
1.  **Auswahl der API-Schnittstelle**:
    *   **Option A: Universal Windows Platform (UWP) APIs**: Moderne, aber möglicherweise komplexere Integration.
    *   **Option B: Direkte Nutzung von Kernel32/NTDLL Syscalls**: Näher am aktuellen "ohne libc"-Ansatz, erfordert aber tieferes Verständnis der Windows-Kernel-Interna.
    *   **Option C (Empfohlen): Minimaler Satz von `kernel32.dll` Importen**: Für grundlegende Operationen wie `ExitProcess`, `WriteConsoleW` (oder `WriteFile`). Dies bietet einen guten Kompromiss zwischen Komplexität und Funktionalität und orientiert sich am "ohne libc"-Prinzip.
2.  **Erstellung der API-Unit**: Anlegen einer Unit (z.B. `backend/win_arm64/win_api.pas`) zur Deklaration externer Funktionen.
3.  **Import-Mechanismus**: Implementierung des Import-Mechanismus in den PE64 ARM64 Writer, um die benötigten Funktionen aus `kernel32.dll` oder `ntdll.dll` zu importieren.
4.  **Anpassung der Builtins**: Modifikation der Lyx-Builtins (`PrintStr`, `PrintInt`, `exit`) zur Nutzung der Windows API-Aufrufe.

**Abhängigkeiten**:
*   Der PE64 ARM64 Writer muss in der Lage sein, Imports zu verarbeiten.

**Risiken**:
*   Auswahl der falschen API-Strategie kann zu hohem Implementierungsaufwand oder Einschränkungen führen.
*   Unterschiede in den Calling Conventions zwischen Linux (SysV) und Windows (Microsoft x64 Calling Convention, angepasst für ARM64) müssen beachtet werden.

**Akzeptanzkriterien**:
*   Lyx-Builtins wie `PrintStr` und `exit` funktionieren unter Windows ARM64 korrekt.
*   Ein einfaches Lyx-Programm kann Text auf der Konsole ausgeben und mit einem bestimmten Exit-Code beenden.

---

### Aufgabe 3: Windows ARM64 Syscall-Nummern

**Beschreibung**: Ersetzen der x64-Syscall-Nummern durch die entsprechenden Windows ARM64-Syscall-Nummern.

**Schritte**:
1.  **Recherche der ARM64 Syscall-Tabelle**: Ermittlung der Syscall-Nummern für die wichtigsten Operationen (z.B. Prozessbeendigung, Schreiben auf Konsole). Diese sind oft nicht öffentlich dokumentiert und müssen ggf. durch Analyse von Windows-Kernel-Binaries oder Wine-Quellcode gefunden werden. Dies ist der "ohne libc"-Ansatz und die anspruchsvollere Variante.
2.  **Alternative (Empfohlen): Nutzung von `ntdll.dll` und `kernel32.dll`**: Statt direkter Syscalls die Funktionen aus `ntdll.dll` (wie `NtWriteFile`, `NtExitProcess`) oder `kernel32.dll` (wie `ExitProcess`, `WriteFile`) über den PE-Importmechanismus aufrufen. Dies ist robuster und weniger fehleranfällig, da die genauen Syscall-Nummern und -Konventionen oft variieren können und von der Windows-Version abhängen. Der Lyx-Compiler kann dann statische Imports für diese Funktionen generieren.
3.  **Implementierung in `backend/win_arm64/`**: Anpassung des Code-Generierungs-Backends, um die korrekten Syscall-Instruktionen oder API-Aufrufe für ARM64 zu emittieren.

**Abhängigkeiten**:
*   Entscheidung für eine API-Strategie (direkte Syscalls vs. `kernel32.dll`/`ntdll.dll` Imports).

**Risiken**:
*   Direkte Syscalls sind nicht stabil über Windows-Versionen hinweg und können zu Kompatibilitätsproblemen führen.
*   Fehlerhafte Syscall-Nummern oder Aufrufkonventionen führen zu Abstürzen.

**Akzeptanzkriterien**:
*   Der Lyx-Compiler kann grundlegende Programme kompilieren, die korrekte Windows ARM64 Syscalls oder API-Aufrufe verwenden.

---

### Aufgabe 4: Testen auf Windows ARM64 Hardware oder QEMU

**Beschreibung**: Sicherstellen der Funktionalität der generierten Binaries auf der Zielplattform.

**Schritte**:
1.  **Bereitstellung der Testumgebung**:
    *   **Option A: Physische Windows ARM64 Hardware**: Optimal für reale Tests.
    *   **Option B: QEMU mit Windows ARM64 Gastsystem**: Virtuelle Umgebung, einfacher einzurichten.
2.  **Automatisierte Testskripte**: Erstellung von Skripten, die die generierten Lyx-Binaries auf der Windows ARM64-Umgebung ausführen und deren Exit-Codes und Ausgaben überprüfen.
3.  **Integrationstests**: Erweiterung des bestehenden Test-Frameworks (`tests/test_codegen.pas`, `tests/lyx/`) um Windows ARM64-spezifische Tests.

**Abhängigkeiten**:
*   Funktionierender PE64 ARM64 Writer.
*   Funktionierende API-Adapter und Syscalls.
*   Zugang zu Windows ARM64 Hardware oder einer QEMU-Installation.

**Risiken**:
*   Kompatibilitätsprobleme mit verschiedenen Windows ARM64-Versionen.
*   Schwierigkeiten bei der Einrichtung und Automatisierung der Testumgebung.

**Akzeptanzkriterien**:
*   Alle relevanten Tests für Windows ARM64 bestehen erfolgreich.
*   Lyx-Programme, die mit dem neuen Backend kompiliert wurden, funktionieren wie erwartet auf Windows ARM64.

---

### Aufgabe 5: Umgang mit Linux-Bibliotheken im Lyx-Compiler

**Beschreibung**: Der Lyx-Compiler selbst verwendet viele Linux-Bibliotheken und kann nicht direkt unter Windows mit FPC kompiliert werden.

**Lösungsansatz (Empfohlen): Cross-Kompilierung auf Linux**

**Strategie**: Wir werden den Lyx-Compiler weiterhin unter Linux entwickeln und kompilieren. Für die Erzeugung von Windows ARM64-Binaries nutzen wir die Cross-Kompilierungsfähigkeiten von FreePascal.

**Schritte**:
1.  **Einrichtung der Cross-Kompilierungsumgebung auf Linux**:
    *   Installation von FPC für das Ziel `i386-win32` und `x86_64-win64`.
    *   **Manuelle Einrichtung des FPC-Cross-Compilers für `aarch64-win64` ist erforderlich**, da kein direktes `apt`-Paket verfügbar ist. Dies beinhaltet in der Regel:
        *   Herunterladen des FPC 3.2.2 Quellcodes.
        *   Installation notwendiger Build-Abhängigkeiten.
        *   Kompilieren des FPC-Compilers mit den entsprechenden Cross-Kompilierungsoptionen für `aarch64-win64`.
    *   `fpc -i` zeigt die installierten Ziele an. Wenn `aarch64-win64` nach der manuellen Einrichtung nicht auftaucht, kann es dennoch über `fpc -Twin64 -Parm64` verwendet werden, falls die Toolchain korrekt konfiguriert ist.
2.  **Anpassung des Build-Prozesses**:
    *   Erweiterung des `Makefile` (oder des Build-Skripts) um ein Ziel für Windows ARM64.
    *   Der Befehl würde in etwa so aussehen: `fpc -Twin64 -Parm64 -O2 -Mobjfpc -Sh lyxc.lpr -olyxc.exe` (Prüfen der genauen FPC-Parameter für ARM64-Windows).
    *   Bedingte Kompilierung: Falls bestimmte Linux-spezifische Units im Lyx-Compiler (`aurumc.lpr` oder andere Frontend-/IR-Units) verwendet werden, müssen diese durch plattformunabhängige oder Windows-spezifische Implementierungen ersetzt oder mit `{$IFDEF LINUX}` / `{$IFDEF MSWINDOWS}`-Direktiven umhüllt werden.
        *   **Annahme**: Der Lyx-Compiler selbst ist größtenteils plattformunabhängig, abgesehen vom Backend. Wenn es Abhängigkeiten zu Linux-Systembibliotheken im Frontend/IR gibt, müssen diese identifiziert und abstrahiert werden.
        *   **Erste Prüfung**: Wir sollten `grep` verwenden, um nach `uses` von offensichtlichen Linux-spezifischen Units wie `cthreads`, `unix` etc. im Frontend/IR-Bereich zu suchen.
3.  **Isolierung plattformspezifischer Code-Pfade**:
    *   Alle plattformspezifischen Logiken (z.B. Syscall-Aufrufe, Dateipfade) sollten in separaten Units gekapselt werden, die dann je nach Zielplattform ausgewählt werden.
    *   Beispiel: `util/platform.pas` mit Implementierungen für Linux und Windows, die über Conditional Defines ausgewählt werden.

**Alternative Lösungsansätze**:

*   **Windows Subsystem for Linux (WSL)**: Der Lyx-Compiler könnte unter WSL entwickelt und ausgeführt werden. Dies würde die Linux-Abhängigkeiten beibehalten, aber die Erstellung der Windows ARM64-Binaries würde weiterhin die Cross-Kompilierung erfordern oder einen Mechanismus, um die generierten Binaries aus WSL auf das Host-Windows zu transferieren. Dies löst nicht direkt das Problem, den Compiler *unter nativem Windows* zu kompilieren.
*   **Minimalportierung des Compilers auf Windows**: Nur die absoluten Minimalanforderungen des Lyx-Compilers (ohne Linux-Bibliotheken, die nur für den Compiler-Betrieb benötigt werden) werden portiert. Dies wäre ein erheblicher Aufwand und würde die Wartbarkeit erschweren.

**Abhängigkeiten**:
*   Verfügbarkeit des FPC-Cross-Compilers für `aarch64-win64`.
*   Identifizierung und ggf. Abstraktion von Linux-spezifischen Abhängigkeiten im Lyx-Compiler-Code.

**Risiken**:
*   Komplexität bei der Einrichtung der Cross-Kompilierungsumgebung für ein eher exotisches Ziel wie `aarch64-win64`.
*   Unvorhergesehene Linux-spezifische Abhängigkeiten im Frontend oder IR des Lyx-Compilers, die eine größere Refaktorierung erfordern.

**Akzeptanzkriterien**:
*   Der Lyx-Compiler kann unter Linux erfolgreich kompilieren, um PE32+-Dateien für Windows ARM64 zu erzeugen.
*   Der gesamte Build-Prozess ist über ein `Makefile` oder Skript automatisiert und reproduzierbar.

## 4. Grober Zeitplan (Schätzung)

1.  **Analyse & Planung (aktuell)**: 1-2 Tage
2.  **PE64 ARM64 Writer Implementierung**: 3-5 Tage
3.  **Windows API Adapter & Syscalls**: 3-4 Tage
4.  **Cross-Kompilierungsumgebung & Build-Anpassung**: 2-4 Tage
5.  **Testframework & Tests**: 2-3 Tage
6.  **Fehlerbehebung & Iteration**: Laufend

## 5. Nächste Schritte

1.  ~~Bestätigung des Plans durch den Benutzer.~~
2.  ~~Einrichtung der Cross-Kompilierungsumgebung unter Linux.~~
3.  ~~Erstellung der Unit `pe64_arm64_writer.pas`.~~

## 6. Aktueller Status

### Erledigt

1.  **PE64 ARM64 Writer** (`backend/win_arm64/pe64_arm64_writer.pas`)
    - PE32+ Header mit IMAGE_FILE_MACHINE_ARM64 ($AA64)
    - Section Headers (.text, .data, .idata)
    - Import-Table für kernel32.dll (ExitProcess)
    - Kompiliert erfolgreich

2.  **Windows ARM64 Recherche**
    - Dokumentation der Windows ARM64 Syscall-Mechanismen (`docs/windows_arm64_syscalls.md`)
    - Unterschiede zwischen Linux ARM64 und Windows ARM64

3.  **Backend-Types erweitert**
    - IObjectWriter Interface hinzugefügt
    - TExternalSymbol und TPLTGOTPatch

### Offene Aufgaben

1.  **Windows ARM64 Emitter**
    - Grundgerüst erstellt (`backend/win_arm64/win_arm64_emit.pas`)
    - IR-Operationen müssen noch vollständig implementiert werden
    - Windows API-Aufrufe (WriteFile, ExitProcess) müssen integriert werden

2.  **Cross-Kompilierung**
    - FPC unterstützt nativ kein `aarch64-win64`
    - Muss manuell eingerichtet werden (FPC aus Quellen bauen)
    - Alternativ: Binutils-Cross-Compiler (aarch64-linux-gnu, aarch64-w64-mingw32) verwenden

3.  **Testen**
    - QEMU mit Windows ARM64 oder physische Hardware erforderlich
