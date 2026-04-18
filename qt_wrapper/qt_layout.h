// qt_wrapper/qt_layout.h
#ifndef QT_LAYOUT_H
#define QT_LAYOUT_H

/* 
 * ================================================================
 * Layout Manager API (WP5) - Verantwortlich für Ownership!
 * ================================================================
 */
// ... [Funktionen qt_vbox, qt_hbox, qt_grid und qt_layout_delete] ...

/* 
 * ================================================================
 * Signals & Slots API (WP6)
 * ================================================================
 */

// --- Button Signale ---
long long qt_button_create(); // Muss zuerst aufgerufen werden, um ein Widget-Handle zu erhalten.
long long qt_button_on_clicked(long long button_handle, void (*callback)());
// ... (Weitere Buttons können hinzugefügt werden)

// --- LineEdit Signale ---
// Stellt die Verbindung zwischen einem Textfeld und einem Lyx-Callback her.
long long qt_lineedit_create(); 
long long qt_lineedit_on_textchanged(long long lineedit_handle, void (*callback)());
void qt_lineedit_on_returnpressed(long long lineedit_handle, void (*callback)());

// --- General Signal Handler ---
// Ein generischer Mechanismus für andere Signale (z.B. CheckBox::toggled)
// Dieser müsste in der Zukunft erweitert werden.
void qt_signal_connect(long long source_handle, const char* signal_name, void (*callback)());

#endif // QT_LAYOUT_H
