Lyx TUI Framework – Überarbeitetes
Architekturkonzept (MVP)
Dieses Dokument fasst die überarbeitete Architektur eines minimalen Terminal-UI-Frameworks für
die Programmiersprache Lyx zusammen. Der Fokus liegt auf einem stabilen, deterministischen
MVP für Linux x86_64 ohne Garbage Collector, mit explizitem Memory-Management und
datenorientiertem Design.
1. Designziele
   Das Framework verfolgt bewusst ein reduziertes Ziel: ein stabiles, deterministisches
   Core-TUI-Toolkit. Die Architektur vermeidet komplexe OOP-Hierarchien und setzt stattdessen auf
   datenorientierte Strukturen, explizite Ownership und vorhersehbare Laufzeitkosten. Kernziele: -
   deterministisches Memory-Management (kein GC) - minimaler Syscall-Footprint - effiziente
   Terminal-Ausgabe (Diff-Rendering) - stabile Widget-Hierarchie - klar getrennte Render-, Layoutund Event-Phasen
2. Architekturüberblick
   Die Architektur basiert auf drei zentralen Konzepten: 1. Datenorientierte Widget-Struktur 2.
   Parent-Owned Tree-Modell 3. Drei-Phasen-Laufzeitmodell Widgets bestehen aus: - Header
   (Framework-Teil) - Props (Konfiguration) - State (mutierbarer Zustand) Render-Operationen sind
   read-only, Events mutieren ausschließlich State.
3. Datenstrukturen
   Flache Datenstrukturen werden als Structs implementiert, um Cache-Lokalität zu erhalten.
   Beispiele: Rect – Position und Größe eines Widgets Cell – einzelne Terminal-Zelle Style – visuelle
   Darstellung Widget-spezifischer Zustand wird ebenfalls als Struct modelliert.
4. Dirty-System
   Zur effizienten Aktualisierung des Bildschirms wird ein abgestuftes Dirty-System verwendet. Level:
   CLEAN – keine Änderung VISUAL – nur visuelle Aktualisierung notwendig LAYOUT – Größe oder
   Position hat sich geändert CHILDREN – Struktur des Widget-Baums wurde verändert Dirty-Flags
   propagieren entlang des Parent-Pfads nach oben.
   Dirty-Level Bedeutung
   CLEAN Keine Änderung
   VISUAL Nur Render notwendig
   LAYOUT Layout muss neu berechnet werden
   CHILDREN Strukturänderung im Widget-Baum
5. Widget Ownership-Modell
   Widgets bilden einen Baum. Regeln: - jedes Widget hat maximal einen Parent - Parents besitzen
   ihre Kinder - Entfernen eines Widgets löst nur die Parent-Beziehung (Detach) - Zerstörung erfolgt
   explizit über dispose() Diese klare Ownership verhindert Dangling Pointer und Memory-Korruption.
6. Lifecycle
   Der Lebenszyklus eines Widgets folgt deterministischen Regeln. 1. Erstellung (new) 2. Einhängen
   in den Widget-Baum 3. Event-Verarbeitung 4. Layout-Berechnung 5. Rendering 6. Entfernen aus
   Baum (detach) 7. Freigabe des Speichers (dispose) Das Framework trennt bewusst
   Strukturänderung und Speicherfreigabe.
7. Drei-Phasen-Laufzeitmodell
   Der Main-Loop arbeitet in drei strikt getrennten Phasen: Event Phase Input wird verarbeitet und
   Widget-State wird aktualisiert. Layout Phase Widgets mit Layout-Dirty-Flag berechnen ihre Frames
   neu. Render Phase Widgets schreiben ihre Darstellung in den Cell-Buffer. Render darf keine
   Mutation durchführen.
8. Rendering-System
   Das Rendering basiert auf einem Double-Buffer-System. 1. Backbuffer wird neu berechnet 2. Diff
   gegen Frontbuffer wird erstellt 3. Nur veränderte Regionen werden geschrieben Ziel: Minimierung
   der Terminal-Bandbreite und der write()-Syscalls.
9. Unicode-Strategie für MVP
   Um Layout-Komplexität zu vermeiden unterstützt das MVP ausschließlich UTF■8 Zeichen mit
   Breite 1. Nicht unterstützt im MVP: - Emoji - CJK Zeichen - komplexe Grapheme Cluster Nicht
   unterstützte Zeichen werden durch ein Replacement-Zeichen ersetzt.
10. MVP Widget Set
    Der erste Release konzentriert sich auf ein extrem kleines Widget-Set. Widgets: Label Button Panel
    Window Layouts: Row Column
11. Systemabhängigkeiten
    Das Runtime-System verwendet ausschließlich minimale Linux-Syscalls: read() write() ioctl()
    nanosleep() Das Framework ist zunächst ausschließlich auf Linux x86_64 ausgelegt.
12. Entwicklungs-Roadmap
    Phase 1 – Core Runtime Memory-Layout, Syscall Layer, Cell Buffer Phase 2 – Widget Tree
    Ownership, Tree Mutationen, Dirty-System Phase 3 – Layout Engine Row/Column Layout Phase 4
    – Rendering Engine Diff Rendering und Region Tracking Phase 5 – Input System Keyboard und
    Maus Dispatch