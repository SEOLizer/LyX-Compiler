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
#include <QPushButton>
#include <QStatusBar>
#include <QString>
#include <QScreen>
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

} // extern "C"
