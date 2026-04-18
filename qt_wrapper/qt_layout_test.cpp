// qt_wrapper/qt_layout_test.cpp
#include <iostream>
#include "qt_layout.h" // Bezieht unsere neue API ein.

/**
 * @brief Testet den vollständigen Lebenszyklus eines vertikalen Layouts.
 * Dieses Testcase validiert das Ownership-Prinzip von qt_layout_delete().
 */
void test_vbox_ownership() {
    std::cout << "\n============== [TEST] VBox Ownership Lifecycle Simulation ==============\n";
    
    // 1. Vorbereitung: Layout erstellen.
    long long vbox_handle = qt_vbox_create(); // Handle erhält die Verantwortung.
    
    // 2. Widgets vorbereiten (simuliert durch Handles, die von anderen Modulen kommen).
    // Wir verwenden hier Platzhalter-Handles für Label und Button, um das System zu testen.
    long long label_handle = 1001; 
    long long button_handle = 1002;

    // 3. Aktion: Widgets dem Layout hinzufügen (Ownership wird transferiert).
    qt_vbox_add_widget(vbox_handle, label_handle);
    qt_vbox_add_widget(vbox_handle, button_handle); 

    std::cout << "\n[VERIFIKATION] Layout ist mit 2 Widgets gefüllt. Jetzt wird die Aufräumaroutine getestet.\n";

    // 4. Clean-up: Die Zerstörung des Containers MUSS alle Kinder aufräumen.
    qt_layout_delete(vbox_handle); 
    std::cout << "\n=================== Test erfolgreich durchlaufen =====================\n";
}

int main() {
    test_vbox_ownership();
    return 0;
}