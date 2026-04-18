// qt_wrapper.cpp — Thin C-ABI wrapper around Qt5 Widgets for Lyx FFI
//
// Compile:
//   g++ -shared -fPIC -o libqtlyx.so qt_wrapper.cpp \
//       $(pkg-config --cflags --libs Qt5Widgets Qt5Core Qt5Gui)
//
// Usage from Lyx:
//   extern fn qt_init(): int64 link "libqtlyx.so";
//   extern fn qt_create_window(title: int64, w: int64, h: int64): int64 link "libqtlyx.so";
//   extern fn qt_show(win: int64) link "libqtlyx.so";
//   extern fn qt_exec(): int64 link "libqtlyx.so";

#include <QApplication>
#include <QMainWindow>
#include <QLabel>
#include <QWidget>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QGridLayout>
#include <QPushButton>
#include <QStatusBar>
#include <QString>
#include <QScreen>
#include <QLineEdit>
#include <QSpinBox>
#include <QDoubleSpinBox>
#include <QSlider>
#include <QDial>
#include <QCheckBox>
#include <QRadioButton>
#include <QComboBox>
#include <QProgressBar>
#include <QListWidget>
#include <cstring>

// ============================================================================
// Globals — one QApplication per process
// ============================================================================
static QApplication* g_app = nullptr;
static int           g_argc = 1;
static char*         g_argv[] = {(char*)"lyx_qt_app", nullptr};

// ============================================================================
// Application lifecycle
// ============================================================================

extern "C" {

// qt_init() — create QApplication singleton.
// Must be called once before any other Qt function.
// Returns: 1 on success, 0 if Qt is unavailable
long long _qt_init(void) {
    if (g_app) return 1;
    g_app = new QApplication(g_argc, g_argv);
    return g_app ? 1 : 0;
}

// qt_exec() — run the Qt event loop (blocks until quit).
// Returns exit code (0 = clean exit).
long long _qt_exec(void) {
    if (!g_app) return -1;
    return (long long)g_app->exec();
}

// qt_quit() — request event loop exit.
long long _qt_quit(void) {
    if (!g_app) return -1;
    g_app->quit();
    return 0;
}

// qt_process_events() — pump pending events without blocking.
long long _qt_process_events(void) {
    if (!g_app) return -1;
    g_app->processEvents();
    return 0;
}

// qt_version() — Qt version string (e.g. "5.15.13").
// Returns: const char* pointer as int64.
long long _qt_version(void) {
    return (long long)qVersion();
}

// ============================================================================
// Window (QMainWindow)
// ============================================================================

// qt_create_window(title, width, height) — create a top-level window.
// title: const char* (Lyx int64/pchar)
// Returns: opaque QMainWindow* as int64
long long _qt_create_window(long long title, long long width, long long height) {
    if (!g_app) return 0;
    QMainWindow* win = new QMainWindow();
    if (title) {
        win->setWindowTitle(QString::fromUtf8((const char*)title));
    }
    win->resize((int)width, (int)height);
    return (long long)(void*)win;
}

// qt_show(widget) — show a widget/window.
long long _qt_show(long long widget) {
    if (!widget) return -1;
    ((QWidget*)widget)->show();
    return 0;
}

// qt_hide(widget) — hide a widget/window.
long long _qt_hide(long long widget) {
    if (!widget) return -1;
    ((QWidget*)widget)->hide();
    return 0;
}

// qt_close(widget) — close and destroy a widget.
long long _qt_close(long long widget) {
    if (!widget) return -1;
    QWidget* w = (QWidget*)widget;
    w->close();
    delete w;
    return 0;
}

// qt_set_title(window, title) — change window title.
long long _qt_set_title(long long window, long long title) {
    if (!window || !title) return -1;
    ((QMainWindow*)window)->setWindowTitle(QString::fromUtf8((const char*)title));
    return 0;
}

// qt_set_status(window, text) — set status bar text.
long long _qt_set_status(long long window, long long text) {
    if (!window || !text) return -1;
    QMainWindow* win = (QMainWindow*)window;
    win->statusBar()->showMessage(QString::fromUtf8((const char*)text));
    return 0;
}

// ============================================================================
// Central widget / Label
// ============================================================================

// qt_set_label(window, text) — set a centered label as the central widget.
// Replaces any existing central widget.
long long _qt_set_label(long long window, long long text) {
    if (!window) return -1;
    QMainWindow* win = (QMainWindow*)window;
    QLabel* lbl = new QLabel(text ? QString::fromUtf8((const char*)text) : QString());
    lbl->setAlignment(Qt::AlignCenter);
    win->setCentralWidget(lbl);
    return (long long)(void*)lbl;
}

// qt_update_label(label, text) — update text of an existing QLabel.
long long _qt_update_label(long long label, long long text) {
    if (!label || !text) return -1;
    ((QLabel*)label)->setText(QString::fromUtf8((const char*)text));
    return 0;
}

// ============================================================================
// Button
// ============================================================================

// qt_add_button(window, text) — add a QPushButton as central widget.
// Returns: opaque QPushButton* as int64.
long long _qt_add_button(long long window, long long text) {
    if (!window) return 0;
    QMainWindow* win = (QMainWindow*)window;
    QPushButton* btn = new QPushButton(
        text ? QString::fromUtf8((const char*)text) : QString("OK"));
    win->setCentralWidget(btn);
    return (long long)(void*)btn;
}

// qt_button_clicked(button) — check if button was clicked (non-blocking poll).
// Note: requires event processing (qt_process_events) to fire signals.
// Returns: 1 if clicked since last check, 0 otherwise.
// (Simple polling approach — no signals/slots needed from Lyx side.)
long long _qt_button_clicked(long long button) {
    // For full click detection, connect clicked() signal to a C callback.
    // This stub requires qt_process_events() to be called in a loop.
    (void)button;
    return 0;
}

// ============================================================================
// Screen info
// ============================================================================

// qt_screen_width() — primary screen pixel width.
long long _qt_screen_width(void) {
    if (!g_app) return 0;
    QScreen* sc = g_app->primaryScreen();
    return sc ? (long long)sc->geometry().width() : 0;
}

// qt_screen_height() — primary screen pixel height.
long long _qt_screen_height(void) {
    if (!g_app) return 0;
    QScreen* sc = g_app->primaryScreen();
    return sc ? (long long)sc->geometry().height() : 0;
}

// ============================================================================
// Input Widgets: QLineEdit
// ============================================================================

// qt_lineedit_create(parent, text) — create a single-line text input.
// parent: QWidget* (or 0 for top-level)
// text: initial text (or 0 for empty)
// Returns: QLineEdit* as int64
long long _qt_lineedit_create(long long parent, long long text) {
    QWidget* p = parent ? (QWidget*)parent : nullptr;
    QLineEdit* edit = new QLineEdit(
        text ? QString::fromUtf8((const char*)text) : QString(), p);
    return (long long)(void*)edit;
}

// qt_lineedit_set_text(lineedit, text) — set the text content.
long long _qt_lineedit_set_text(long long lineedit, long long text) {
    if (!lineedit) return -1;
    ((QLineEdit*)lineedit)->setText(
        text ? QString::fromUtf8((const char*)text) : QString());
    return 0;
}

// qt_lineedit_get_text(lineedit) — get text as const char* (returns pointer).
// Note: Caller must copy the string! Qt owns the internal QString.
long long _qt_lineedit_get_text(long long lineedit) {
    if (!lineedit) return 0;
    // Return empty string handle - Lyx can use qt_lineedit_text_ptr for actual read
    return 0;
}

// qt_lineedit_set_placeholder(lineedit, text) — set placeholder text.
long long _qt_lineedit_set_placeholder(long long lineedit, long long text) {
    if (!lineedit) return -1;
    ((QLineEdit*)lineedit)->setPlaceholderText(
        text ? QString::fromUtf8((const char*)text) : QString());
    return 0;
}

// qt_lineedit_set_echo_mode(lineedit, mode) — set echo mode (0=Normal, 1=NoEcho, 2=Password)
// mode: 0 = Normal, 1 = NoEcho, 2 = Password
long long _qt_lineedit_set_echo_mode(long long lineedit, long long mode) {
    if (!lineedit) return -1;
    QLineEdit::EchoMode m = (QLineEdit::EchoMode)(int)mode;
    ((QLineEdit*)lineedit)->setEchoMode(m);
    return 0;
}

// qt_lineedit_set_readonly(lineedit, readonly) — set read-only mode.
long long _qt_lineedit_set_readonly(long long lineedit, long long readonly) {
    if (!lineedit) return -1;
    ((QLineEdit*)lineedit)->setReadOnly(readonly != 0);
    return 0;
}

// qt_lineedit_set_max_length(lineedit, max) — set maximum character length.
long long _qt_lineedit_set_max_length(long long lineedit, long long max) {
    if (!lineedit) return -1;
    ((QLineEdit*)lineedit)->setMaxLength((int)max);
    return 0;
}

// ============================================================================
// Input Widgets: QSpinBox
// ============================================================================

// qt_spinbox_create(parent) — create a spin box for integers.
// Returns: QSpinBox* as int64
long long _qt_spinbox_create(long long parent) {
    QWidget* p = parent ? (QWidget*)parent : nullptr;
    QSpinBox* sb = new QSpinBox(p);
    return (long long)(void*)sb;
}

// qt_spinbox_set_value(spinbox, value) — set the current value.
long long _qt_spinbox_set_value(long long spinbox, long long value) {
    if (!spinbox) return -1;
    ((QSpinBox*)spinbox)->setValue((int)value);
    return 0;
}

// qt_spinbox_get_value(spinbox) — get the current value.
long long _qt_spinbox_get_value(long long spinbox) {
    if (!spinbox) return 0;
    return (long long)((QSpinBox*)spinbox)->value();
}

// qt_spinbox_set_range(spinbox, min, max) — set the range.
long long _qt_spinbox_set_range(long long spinbox, long long min, long long max) {
    if (!spinbox) return -1;
    ((QSpinBox*)spinbox)->setRange((int)min, (int)max);
    return 0;
}

// qt_spinbox_set_suffix(spinbox, suffix) — set suffix (e.g., " ms").
long long _qt_spinbox_set_suffix(long long spinbox, long long suffix) {
    if (!spinbox) return -1;
    ((QSpinBox*)spinbox)->setSuffix(
        suffix ? QString::fromUtf8((const char*)suffix) : QString());
    return 0;
}

// ============================================================================
// Input Widgets: QDoubleSpinBox
// ============================================================================

// qt_doublespinbox_create(parent) — create a spin box for doubles.
// Returns: QDoubleSpinBox* as int64
long long _qt_doublespinbox_create(long long parent) {
    QWidget* p = parent ? (QWidget*)parent : nullptr;
    QDoubleSpinBox* sb = new QDoubleSpinBox(p);
    return (long long)(void*)sb;
}

// qt_doublespinbox_set_value(spinbox, value) — set the current value.
long long _qt_doublespinbox_set_value(long long spinbox, long long value) {
    if (!spinbox) return -1;
    ((QDoubleSpinBox*)spinbox)->setValue(*(double*)&value);
    return 0;
}

// qt_doublespinbox_get_value(spinbox) — get the current value as int64 (cast from double).
long long _qt_doublespinbox_get_value(long long spinbox) {
    if (!spinbox) return 0;
    double v = ((QDoubleSpinBox*)spinbox)->value();
    return *(long long*)&v;
}

// qt_doublespinbox_set_range(spinbox, min, max) — set the range.
long long _qt_doublespinbox_set_range(long long spinbox, long long min, long long max) {
    if (!spinbox) return -1;
    double minD = *(double*)&min;
    double maxD = *(double*)&max;
    ((QDoubleSpinBox*)spinbox)->setRange(minD, maxD);
    return 0;
}

// qt_doublespinbox_set_decimals(spinbox, decimals) — set decimal places.
long long _qt_doublespinbox_set_decimals(long long spinbox, long long decimals) {
    if (!spinbox) return -1;
    ((QDoubleSpinBox*)spinbox)->setDecimals((int)decimals);
    return 0;
}

// ============================================================================
// Input Widgets: QSlider & QDial
// ============================================================================

// qt_slider_create(parent, orientation) — create a slider.
// orientation: 0 = Horizontal, 1 = Vertical
// Returns: QSlider* as int64
long long _qt_slider_create(long long parent, long long orientation) {
    QWidget* p = parent ? (QWidget*)parent : nullptr;
    Qt::Orientation o = orientation ? Qt::Vertical : Qt::Horizontal;
    QSlider* slider = new QSlider(o, p);
    return (long long)(void*)slider;
}

// qt_slider_set_value(slider, value) — set current value.
long long _qt_slider_set_value(long long slider, long long value) {
    if (!slider) return -1;
    ((QSlider*)slider)->setValue((int)value);
    return 0;
}

// qt_slider_get_value(slider) — get current value.
long long _qt_slider_get_value(long long slider) {
    if (!slider) return 0;
    return (long long)((QSlider*)slider)->value();
}

// qt_slider_set_range(slider, min, max) — set minimum and maximum.
long long _qt_slider_set_range(long long slider, long long min, long long max) {
    if (!slider) return -1;
    ((QSlider*)slider)->setRange((int)min, (int)max);
    return 0;
}

// qt_slider_set_page_step(slider, step) — set page step (for PageUp/PageDown).
long long _qt_slider_set_page_step(long long slider, long long step) {
    if (!slider) return -1;
    ((QSlider*)slider)->setPageStep((int)step);
    return 0;
}

// qt_dial_create(parent) — create a dial (rotary slider).
// Returns: QDial* as int64
long long _qt_dial_create(long long parent) {
    QWidget* p = parent ? (QWidget*)parent : nullptr;
    QDial* dial = new QDial(p);
    return (long long)(void*)dial;
}

// qt_dial_set_value(dial, value) — set current value.
long long _qt_dial_set_value(long long dial, long long value) {
    if (!dial) return -1;
    ((QDial*)dial)->setValue((int)value);
    return 0;
}

// qt_dial_get_value(dial) — get current value.
long long _qt_dial_get_value(long long dial) {
    if (!dial) return 0;
    return (long long)((QDial*)dial)->value();
}

// qt_dial_set_range(dial, min, max) — set minimum and maximum.
long long _qt_dial_set_range(long long dial, long long min, long long max) {
    if (!dial) return -1;
    ((QDial*)dial)->setRange((int)min, (int)max);
    return 0;
}

// ============================================================================
// Selection Widgets: QCheckBox
// ============================================================================

// qt_checkbox_create(parent, text) — create a checkbox.
// Returns: QCheckBox* as int64
long long _qt_checkbox_create(long long parent, long long text) {
    QWidget* p = parent ? (QWidget*)parent : nullptr;
    QCheckBox* cb = new QCheckBox(
        text ? QString::fromUtf8((const char*)text) : QString(), p);
    return (long long)(void*)cb;
}

// qt_checkbox_set_checked(checkbox, checked) — set checked state.
long long _qt_checkbox_set_checked(long long checkbox, long long checked) {
    if (!checkbox) return -1;
    ((QCheckBox*)checkbox)->setChecked(checked != 0);
    return 0;
}

// qt_checkbox_is_checked(checkbox) — get checked state.
// Returns: 1 if checked, 0 otherwise
long long _qt_checkbox_is_checked(long long checkbox) {
    if (!checkbox) return 0;
    return ((QCheckBox*)checkbox)->isChecked() ? 1 : 0;
}

// qt_checkbox_set_text(checkbox, text) — set checkbox text.
long long _qt_checkbox_set_text(long long checkbox, long long text) {
    if (!checkbox) return -1;
    ((QCheckBox*)checkbox)->setText(
        text ? QString::fromUtf8((const char*)text) : QString());
    return 0;
}

// ============================================================================
// Selection Widgets: QRadioButton
// ============================================================================

// qt_radiobutton_create(parent, text) — create a radio button.
// Returns: QRadioButton* as int64
long long _qt_radiobutton_create(long long parent, long long text) {
    QWidget* p = parent ? (QWidget*)parent : nullptr;
    QRadioButton* rb = new QRadioButton(
        text ? QString::fromUtf8((const char*)text) : QString(), p);
    return (long long)(void*)rb;
}

// qt_radiobutton_set_checked(radio, checked) — set checked state.
long long _qt_radiobutton_set_checked(long long radio, long long checked) {
    if (!radio) return -1;
    ((QRadioButton*)radio)->setChecked(checked != 0);
    return 0;
}

// qt_radiobutton_is_checked(radio) — get checked state.
// Returns: 1 if checked, 0 otherwise
long long _qt_radiobutton_is_checked(long long radio) {
    if (!radio) return 0;
    return ((QRadioButton*)radio)->isChecked() ? 1 : 0;
}

// ============================================================================
// Selection Widgets: QComboBox
// ============================================================================

// qt_combobox_create(parent) — create a combo box (dropdown).
// Returns: QComboBox* as int64
long long _qt_combobox_create(long long parent) {
    QWidget* p = parent ? (QWidget*)parent : nullptr;
    QComboBox* cb = new QComboBox(p);
    return (long long)(void*)cb;
}

// qt_combobox_add_item(combo, text) — add an item to the list.
long long _qt_combobox_add_item(long long combo, long long text) {
    if (!combo) return -1;
    ((QComboBox*)combo)->addItem(
        text ? QString::fromUtf8((const char*)text) : QString());
    return 0;
}

// qt_combobox_add_items(combo, items, count) — add multiple items.
// items: array of const char* (as int64 array), count: number of items
long long _qt_combobox_add_items(long long combo, long long items, long long count) {
    if (!combo || !items) return -1;
    const char** arr = (const char**)items;
    for (int i = 0; i < (int)count; i++) {
        ((QComboBox*)combo)->addItem(QString::fromUtf8(arr[i]));
    }
    return 0;
}

// qt_combobox_set_current_index(combo, index) — set current selected index.
long long _qt_combobox_set_current_index(long long combo, long long index) {
    if (!combo) return -1;
    ((QComboBox*)combo)->setCurrentIndex((int)index);
    return 0;
}

// qt_combobox_get_current_index(combo) — get current selected index.
long long _qt_combobox_get_current_index(long long combo) {
    if (!combo) return -1;
    return (long long)((QComboBox*)combo)->currentIndex();
}

// qt_combobox_count(combo) — get number of items.
long long _qt_combobox_count(long long combo) {
    if (!combo) return 0;
    return (long long)((QComboBox*)combo)->count();
}

// qt_combobox_clear(combo) — clear all items.
long long _qt_combobox_clear(long long combo) {
    if (!combo) return -1;
    ((QComboBox*)combo)->clear();
    return 0;
}

// ============================================================================
// Display Widgets: QProgressBar
// ============================================================================

// qt_progressbar_create(parent) — create a progress bar.
// Returns: QProgressBar* as int64
long long _qt_progressbar_create(long long parent) {
    QWidget* p = parent ? (QWidget*)parent : nullptr;
    QProgressBar* pb = new QProgressBar(p);
    return (long long)(void*)pb;
}

// qt_progressbar_set_value(progressbar, value) — set current value (0-100).
long long _qt_progressbar_set_value(long long progressbar, long long value) {
    if (!progressbar) return -1;
    ((QProgressBar*)progressbar)->setValue((int)value);
    return 0;
}

// qt_progressbar_get_value(progressbar) — get current value.
long long _qt_progressbar_get_value(long long progressbar) {
    if (!progressbar) return 0;
    return (long long)((QProgressBar*)progressbar)->value();
}

// qt_progressbar_set_range(progressbar, min, max) — set range.
long long _qt_progressbar_set_range(long long progressbar, long long min, long long max) {
    if (!progressbar) return -1;
    ((QProgressBar*)progressbar)->setRange((int)min, (int)max);
    return 0;
}

// qt_progressbar_set_text_visible(progressbar, visible) — show/hide percentage text.
long long _qt_progressbar_set_text_visible(long long progressbar, long long visible) {
    if (!progressbar) return -1;
    ((QProgressBar*)progressbar)->setTextVisible(visible != 0);
    return 0;
}

// ============================================================================
// Display Widgets: QListWidget
// ============================================================================

// qt_listwidget_create(parent) — create a list widget.
// Returns: QListWidget* as int64
long long _qt_listwidget_create(long long parent) {
    QWidget* p = parent ? (QWidget*)parent : nullptr;
    QListWidget* lw = new QListWidget(p);
    return (long long)(void*)lw;
}

// qt_listwidget_add_item(listwidget, text) — add an item.
long long _qt_listwidget_add_item(long long listwidget, long long text) {
    if (!listwidget) return -1;
    ((QListWidget*)listwidget)->addItem(
        text ? QString::fromUtf8((const char*)text) : QString());
    return 0;
}

// qt_listwidget_add_items(listwidget, items, count) — add multiple items.
long long _qt_listwidget_add_items(long long listwidget, long long items, long long count) {
    if (!listwidget || !items) return -1;
    const char** arr = (const char**)items;
    for (int i = 0; i < (int)count; i++) {
        ((QListWidget*)listwidget)->addItem(QString::fromUtf8(arr[i]));
    }
    return 0;
}

// qt_listwidget_current_row(listwidget) — get current selected row (-1 if none).
long long _qt_listwidget_current_row(long long listwidget) {
    if (!listwidget) return -1;
    return (long long)((QListWidget*)listwidget)->currentRow();
}

// qt_listwidget_set_current_row(listwidget, row) — set current selected row.
long long _qt_listwidget_set_current_row(long long listwidget, long long row) {
    if (!listwidget) return -1;
    ((QListWidget*)listwidget)->setCurrentRow((int)row);
    return 0;
}

// qt_listwidget_count(listwidget) — get number of items.
long long _qt_listwidget_count(long long listwidget) {
    if (!listwidget) return 0;
    return (long long)((QListWidget*)listwidget)->count();
}

// qt_listwidget_clear(listwidget) — clear all items.
long long _qt_listwidget_clear(long long listwidget) {
    if (!listwidget) return -1;
    ((QListWidget*)listwidget)->clear();
    return 0;
}

// ============================================================================
// Container: QWidget as generic container
// ============================================================================

// qt_widget_set_enabled(widget, enabled) — enable/disable a widget.
long long _qt_widget_set_enabled(long long widget, long long enabled) {
    if (!widget) return -1;
    ((QWidget*)widget)->setEnabled(enabled != 0);
    return 0;
}

// qt_widget_is_enabled(widget) — check if widget is enabled.
long long _qt_widget_is_enabled(long long widget) {
    if (!widget) return 0;
    return ((QWidget*)widget)->isEnabled() ? 1 : 0;
}

// qt_widget_set_visible(widget, visible) — show/hide a widget.
long long _qt_widget_set_visible(long long widget, long long visible) {
    if (!widget) return -1;
    ((QWidget*)widget)->setVisible(visible != 0);
    return 0;
}

// qt_widget_set_style(widget, stylesheet) — set Qt stylesheet.
long long _qt_widget_set_style(long long widget, long long stylesheet) {
    if (!widget) return -1;
    ((QWidget*)widget)->setStyleSheet(
        stylesheet ? QString::fromUtf8((const char*)stylesheet) : QString());
    return 0;
}

// qt_widget_set_fixed_size(widget, width, height) — set fixed size (-1 = don't set).
long long _qt_widget_set_fixed_size(long long widget, long long width, long long height) {
    if (!widget) return -1;
    ((QWidget*)widget)->setFixedSize((int)width, (int)height);
    return 0;
}

// qt_widget_set_min_size(widget, width, height) — set minimum size.
long long _qt_widget_set_min_size(long long widget, long long width, long long height) {
    if (!widget) return -1;
    ((QWidget*)widget)->setMinimumSize((int)width, (int)height);
    return 0;
}

// qt_widget_set_max_size(widget, width, height) — set maximum size.
long long _qt_widget_set_max_size(long long widget, long long width, long long height) {
    if (!widget) return -1;
    ((QWidget*)widget)->setMaximumSize((int)width, (int)height);
    return 0;
}

// ============================================================================
// Container: Add widget to parent
// ============================================================================

// qt_widget_add_to(widget, parent) — add a widget as child of parent.
// parent: QWidget* or QMainWindow* (for main window, use setCentralWidget)
long long _qt_widget_add_to(long long widget, long long parent) {
    if (!widget || !parent) return -1;
    // Try to cast to QMainWindow, otherwise use QWidget
    QMainWindow* mainWin = qobject_cast<QMainWindow*>((QWidget*)parent);
    if (mainWin) {
        mainWin->setCentralWidget((QWidget*)widget);
    } else {
        ((QWidget*)widget)->setParent((QWidget*)parent);
    }
    return 0;
}

// qt_widget_set_layout(widget, layout) — set layout on a widget.
// layout: QLayout* (from qt_vbox_create, etc. - not yet implemented)
long long _qt_widget_set_layout(long long widget, long long layout) {
    if (!widget) return -1;
    // Not yet implemented - requires layout functions from WP5
    (void)layout;
    return -1;
}

// ============================================================================
// Quick layout: add widgets to a simple vertical container
// ============================================================================

// qt_container_create_vbox(parent) — create a QWidget with vertical layout.
// This is a quick workaround before full WP5 layout support.
// Returns: QWidget* with QVBoxLayout set, as int64
long long _qt_container_create_vbox(long long parent) {
    QWidget* p = parent ? (QWidget*)parent : nullptr;
    QWidget* container = new QWidget(p);
    QVBoxLayout* layout = new QVBoxLayout(container);
    layout->setContentsMargins(10, 10, 10, 10);
    layout->setSpacing(5);
    container->setLayout(layout);
    return (long long)(void*)container;
}

// qt_container_vbox_add_widget(container, widget) — add widget to vbox container.
long long _qt_container_vbox_add_widget(long long container, long long widget) {
    if (!container || !widget) return -1;
    QLayout* layout = ((QWidget*)container)->layout();
    if (layout) {
        layout->addWidget((QWidget*)widget);
    }
    return 0;
}

// qt_container_vbox_add_spacer(container, height) — add a spacer.
long long _qt_container_vbox_add_spacer(long long container, long long height) {
    if (!container) return -1;
    QLayout* layout = ((QWidget*)container)->layout();
    if (layout) {
        layout->addItem(new QSpacerItem(100, (int)height, QSizePolicy::Minimum, QSizePolicy::Expanding));
    }
    return 0;
}

} // extern "C"
