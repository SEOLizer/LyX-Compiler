// qt_wrapper/qt_layout.cpp
#include "qt_layout.h"
#include <iostream>
#include <map>
#include <vector> 
#include <string>

namespace MockQt {
    // Globaler Tracker: Layout-Handle -> Liste der zu löschenden Widget Handles.
    std::map<long long, std::vector<long long>> layout_ownership;
    
    // --- Callback Registry für WP6 (Vereinfacht) ---
    // Stellt das Prinzip dar: Handle -> Liste von Callbacks. 
    // Ein void* dient als Platzhalter für den komplexen Funktions-Pointer.
    std::map<long long, std::vector<void*>> widget_callbacks;
}

/* ==========================================
 * VBOX IMPLEMENTATION (Funktioniert) 
=========================================*/

// [qt_vbox_create] (Bleibt unverändert)
long long qt_vbox_create() {
    static long long next_handle = 2000;
    long long handle = next_handle++;
    MockQt::layout_ownership[handle] = {}; // Initiiere die Liste der Kind-Handles.
    std::cout << "[VBOX] Layout erstellt. Handle: " << handle << "\n";
    return handle;
}
// ... [qt_vbox_add_widget] (Bleibt unverändert)
long long qt_vbox_add_widget(long long layout_handle, long long widget_handle) {
    if (!MockQt::layout_ownership.count(layout_handle)) { 
        std::cerr << "[ERROR] VBox-Add fehlgeschlagen: Layout-Handle ist ungültig.\n";
        return -1;
    }
    // Ownership Transfer.
    MockQt::layout_ownership.at(layout_handle).push_back(widget_handle);
    std::cout << "[VBOX] Widget Handle " << widget_handle << " hinzugefügt und Ownership übernommen.\n";
    return 0;
}
// ... (Rest der VBox Funktionen bleiben unverändert)

/* ==========================================
 * HBOX IMPLEMENTATION (Wird implementiert) 
=========================================*/
long long qt_hbox_create() {
    static long long next_handle = 3000; 
    long long handle = next_handle++;
    MockQt::layout_ownership[handle] = {}; // Initiiere die Liste der Kind-Handles (Leeres Ownership)
    std::cout << "[HBOX] Layout erstellt. Handle: " << handle << "\n";
    return handle;
}
long long qt_hbox_add_widget(long long layout_handle, long long widget_handle) {
    if (!MockQt::layout_ownership.count(layout_handle)) { 
        std::cerr << "[ERROR] HBox-Add fehlgeschlagen: Layout-Handle ist ungültig.\n";
        return -1;
    }
    // Ownership Transfer.
    MockQt::layout_ownership.at(layout_handle).push_back(widget_handle);
    std::cout << "[HBOX] Widget Handle " << widget_handle << " hinzugefügt und Ownership übernommen.\n";
    return 0;
}

/* ==========================================
 * GRID IMPLEMENTATION (Wird implementiert) 
=========================================*/
long long qt_grid_create() {
    static long long next_handle = 4000; 
    long long handle = next_handle++;
    MockQt::layout_ownership[handle] = {}; // Initiiere die Liste der Kind-Handles (Leeres Ownership)
    std::cout << "[GRID] Layout erstellt. Handle: " << handle << "\n";
    return handle;
}
long long qt_grid_add_widget(long long grid_layout_handle, long long widget_handle, int row, int col) {
    if (!MockQt::layout_ownership.count(grid_layout_handle)) { 
        std::cerr << "[ERROR] Grid-Add fehlgeschlagen: Layout-Handle ist ungültig.\n";
        return -1;
    }
    // Ownership Transfer.
    MockQt::layout_ownership.at(grid_layout_handle).push_back(widget_handle);
    std::cout << "[GRID] Widget Handle " << widget_handle << " hinzugefügt (Row: " << row << ", Col: " << col << "). Ownership übernommen.\n";
    return 0;
}

/* ==========================================
 * LIFECYCLE & CLEANUP (Das Herzstück) 
=========================================*/
void qt_layout_delete(long long layout_handle) {
    if (!MockQt::layout_ownership.count(layout_handle)) { 
        std::cerr << "[ERROR] Versuch, ein unbekanntes Layout-Handle (" << layout_handle << ") zu löschen.\n";
        return;
    }

    // 1. Ownership: Kind-Widgets aufräumen (Die kritische Reihenfolge ist hier wichtig).
    std::vector<long long> widgets_to_delete = MockQt::layout_ownership[layout_handle];
    for (auto it = widgets_to_delete.rbegin(); it != widgets_to_delete.rend(); ++it) {
        // Hier wird die Zerstörung simuliert.
        std::cout << "[CLEANUP] Widget Handle " << *it << " wird zerstört (Ownership-Prinzip erfüllt).\n";
    }

    // 2. Cleanup: Das Layout selbst entfernen und Ressourcen freigeben.
    MockQt::layout_ownership.erase(layout_handle);
    std::cout << "[SUCCESS] Layout Handle " << layout_handle << " wurde erfolgreich gelöscht.\n";
}

/* ==========================================
 * SIGNAL/SLOTS IMPLEMENTATION (Placeholder) 
=========================================*/
long long qt_button_on_clicked(long long button_handle, void (*callback) {}) {
    // Hier müsste der echte Mechanismus zum Speichern von Callbacks implementiert werden.
    std::cout << "[CONNECT] Button-Signal erfolgreich auf Lyx Callback gemappt (Platzhalter).\n";
    return button_handle;
}
