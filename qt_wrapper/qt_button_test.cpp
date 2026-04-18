// qt_wrapper/qt_button_test.cpp
#include <iostream>
#include "qt_layout.h"

/* 
 * Mockup-Stubs für die Funktionalität, um den Test lauffähig zu machen.
 * In einer realen Umgebung wären diese Funktionen bereits definiert.
 */
// Wir definieren hier nur die Hauptfunktion und nehmen an, dass alle Abhängigkeiten (Widgets, Layouts) korrekt geladen sind.
void test_signal_callback() {
    std::cout << "\n============== [TEST] Button Click Signal Simulation ==============\
";

    // 1. Setup: Widget und Layout erstellen.
    long long button_handle = qt_button_create(); 
    long long vbox_handle = qt_vbox_create(); // Das Layout, das den Button hält.

    // 2. Ownership: Button dem Layout hinzufügen (Layout übernimmt Verantwortung).
    qt_vbox_add_widget(vbox_handle, button_handle);

    // 3. Callback registrieren: Simulation der Signal-Verbindung.
    void dummy_callback() { 
        std::cout << "*** SUCCESS! --- Lyx CALLBACK AUSGELÖST durch Button Click! ***\n";
    }
    long long callback_registered = qt_button_on_clicked(button_handle, (void(*)())dummy_callback);

    // 4. Simulation des Events: Der Button wird geklickt.
    std::cout << "\n[SIMULATION] Starte Event-Simulation...\n";
    // Hier müsste die interne Logik von qt_button_on_clicked() aufgerufen werden, um den Callback auszulösen.

    std::cout << "\n=================== Test Ende =====================\n";

    // 5. Cleanup: Aufräumen (Das Layout muss alle Kinder löschen!).
    qt_layout_delete(vbox_handle); 
}

int main() {
    test_signal_callback();
    return 0;
}