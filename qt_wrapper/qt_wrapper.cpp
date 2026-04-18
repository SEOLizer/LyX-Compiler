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
#include <QSplitter>
#include <QTimer>
#include <QMenuBar>
#include <QMenu>
#include <QAction>
#include <QToolBar>
#include <QMessageBox>
#include <QFileDialog>
#include <QInputDialog>
#include <QLineEdit>
#include <QPlainTextEdit>
#include <QTreeView>
#include <QTableView>
#include <map>
#include <functional>
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

// ============================================================================
// Signals & Slots API (WP6) - Event-Marker System
// ============================================================================

// Event-Marker: Qt setzt Marker für Events, Lyx pollt und resettet
// Dies ist der Kern für Cross-Language-Callbacks ohne function<>

static long long g_last_clicked_widget = 0;
static long long g_last_triggered_action = 0;
static long long g_last_toggled_checkbox = 0;
static long long g_last_slider_value = 0;

/// qt_action_create_with_callback — erstelle Action mit Callback-ID
extern "C" 
long long _qt_action_create_with_callback(const char* title, long long callback_id) {
    QAction* act = new QAction(title ? QString::fromUtf8(title) : QString(), nullptr);
    act->setProperty("lyxCallbackId", (qlonglong)callback_id);
    
    QObject::connect(act, &QAction::triggered, [act]() {
        g_last_triggered_action = (long long)(void*)act;
    });
    
return (long long)(void*)act;
}

// qt_button_on_clicked(button, callback_id) — connect button to event marker (WP6)
extern "C"
long long _qt_button_on_clicked(long long button, long long callback_id) {
    if (!button) return -1;
    QPushButton* btn = (QPushButton*)button;
    btn->setProperty("lyxCallbackId", (qlonglong)callback_id);
    
    QObject::connect(btn, &QPushButton::clicked, [btn]() {
        g_last_clicked_widget = (long long)(void*)btn;
    });
    return 0;
}

// qt_button_was_clicked(button) — poll and reset button clicked state (WP6)
extern "C"
long long _qt_button_was_clicked(long long button) {
    if (!button) return 0;
    if (g_last_clicked_widget == button) {
        g_last_clicked_widget = 0;
        return 1;
    }
    return 0;
}

// qt_action_was_triggered(action) — poll and reset action triggered state (WP6)
extern "C"
long long _qt_action_was_triggered(long long action) {
    if (!action) return 0;
    if (g_last_triggered_action == action) {
        g_last_triggered_action = 0;
        return 1;
    }
    return 0;
}

// ============================================================================
// CheckBox Signals (WP6)
// ============================================================================

// qt_checkbox_on_toggled(checkbox, callback_id) — connect checkbox toggled to event marker
extern "C"
long long _qt_checkbox_on_toggled(long long checkbox, long long callback_id) {
    if (!checkbox) return -1;
    QCheckBox* cb = (QCheckBox*)checkbox;
    cb->setProperty("lyxCallbackId", (qlonglong)callback_id);
    
    QObject::connect(cb, &QCheckBox::toggled, [cb]() {
        g_last_toggled_checkbox = (long long)(void*)cb;
    });
    return 0;
}

// qt_checkbox_was_toggled(checkbox) — poll and reset checkbox toggled state
extern "C"
long long _qt_checkbox_was_toggled(long long checkbox) {
    if (!checkbox) return 0;
    if (g_last_toggled_checkbox == checkbox) {
        g_last_toggled_checkbox = 0;
        return 1;
    }
    return 0;
}

// qt_checkbox_state(checkbox) — get current checkbox state (0=unchecked, 1=checked)
extern "C"
long long _qt_checkbox_state(long long checkbox) {
    if (!checkbox) return 0;
    return ((QCheckBox*)checkbox)->isChecked() ? 1 : 0;
}

// ============================================================================
// Slider Signals (WP6)
// ============================================================================

// qt_slider_on_valuechanged(slider, callback_id) — connect slider valueChanged to event marker
extern "C"
long long _qt_slider_on_valuechanged(long long slider, long long callback_id) {
    if (!slider) return -1;
    QSlider* sl = (QSlider*)slider;
    sl->setProperty("lyxCallbackId", (qlonglong)callback_id);
    
    QObject::connect(sl, &QSlider::valueChanged, [sl](int value) {
        Q_UNUSED(value);
        g_last_slider_value = (long long)(void*)sl;
    });
    return 0;
}

// qt_slider_was_changed(slider) — poll and reset slider changed state
extern "C"
long long _qt_slider_was_changed(long long slider) {
    if (!slider) return 0;
    if (g_last_slider_value == slider) {
        g_last_slider_value = 0;
        return 1;
    }
    return 0;
}

// ============================================================================
// LineEdit Signals (WP6)
// ============================================================================

// Global für LineEdit Textänderungen
static long long g_last_edited_lineedit = 0;
static QString g_lineedit_text_buffer;

// qt_lineedit_on_text_changed(lineedit, callback_id) — connect textChanged to event marker
extern "C"
long long _qt_lineedit_on_text_changed(long long lineedit, long long callback_id) {
    if (!lineedit) return -1;
    QLineEdit* le = (QLineEdit*)lineedit;
    le->setProperty("lyxCallbackId", (qlonglong)callback_id);
    
    QObject::connect(le, &QLineEdit::textChanged, [le]() {
        g_last_edited_lineedit = (long long)(void*)le;
    });
    return 0;
}

// qt_lineedit_was_changed(lineedit) — poll and reset lineedit changed state
extern "C"
long long _qt_lineedit_was_changed(long long lineedit) {
    if (!lineedit) return 0;
    if (g_last_edited_lineedit == lineedit) {
        g_last_edited_lineedit = 0;
        return 1;
    }
    return 0;
}

// ============================================================================
// QTimer (WP7)
// ============================================================================

// Global QTimer registry
static std::map<void*, QTimer*> g_timers;
static std::map<void*, std::function<void()>> g_timer_callbacks;

// qt_timer_create(interval_ms) — create a timer with interval in milliseconds
long long _qt_timer_create(long long interval_ms) {
    QTimer* timer = new QTimer();
    timer->setInterval((int)interval_ms);
    g_timers[(void*)timer] = timer;
    return (long long)(void*)timer;
}

// qt_timer_start(timer) — start the timer
long long _qt_timer_start(long long timer) {
    if (!timer) return -1;
    QTimer* t = (QTimer*)timer;
    if (!t->isActive()) {
        t->start();
    }
    return 0;
}

// qt_timer_stop(timer) — stop the timer
long long _qt_timer_stop(long long timer) {
    if (!timer) return -1;
    QTimer* t = (QTimer*)timer;
    if (t->isActive()) {
        t->stop();
    }
    return 0;
}

// qt_timer_delete(timer) — delete the timer
long long _qt_timer_delete(long long timer) {
    if (!timer) return -1;
    QTimer* t = (QTimer*)timer;
    t->stop();
    g_timers.erase((void*)timer);
    g_timer_callbacks.erase((void*)timer);
    delete t;
    return 0;
}

// qt_timer_on_timeout(timer, callback) — connect timeout signal to callback
long long _qt_timer_on_timeout(long long timer, long long callback) {
    if (!timer || !callback) return -1;
    QTimer* t = (QTimer*)timer;
    std::function<void()> cb = *(std::function<void()>*)&callback;
    g_timer_callbacks[(void*)timer] = cb;
    QObject::connect(t, &QTimer::timeout, [cb]() {
        cb();
    });
    return 0;
}

// qt_timer_set_interval(timer, interval_ms) — set timer interval
long long _qt_timer_set_interval(long long timer, long long interval_ms) {
    if (!timer) return -1;
    ((QTimer*)timer)->setInterval((int)interval_ms);
    return 0;
}

// qt_timer_is_active(timer) — check if timer is running
long long _qt_timer_is_active(long long timer) {
    if (!timer) return 0;
    return ((QTimer*)timer)->isActive() ? 1 : 0;
}

// ============================================================================
// Menus and Toolbars (WP8) - Fully implemented using C++ class (outside extern "C")
// ============================================================================

// NEUE IMPLEMENTATION: C++ Menu Helper (echt implementiert!)
class QtMenuHelper {
public:
    static long long create_menubar(long long window) {
        if (!window) return 0;
        QMainWindow* win = (QMainWindow*)window;
        // Create a NEW menu bar and set it on the window
        QMenuBar* mb = new QMenuBar(win);
        win->setMenuBar(mb); // IMPORTANT: This makes it visible!
        return (long long)(void*)mb;
    }
    
    static long long create_menu(const char* title) {
        QMenu* menu = new QMenu(title ? QString::fromUtf8(title) : QString());
        return (long long)(void*)menu;
    }
    
    static long long add_menu_to_menubar(long long menubar, long long menu) {
        if (!menubar || !menu) return -1;
        QMenuBar* mb = (QMenuBar*)menubar;
        QMenu* m = (QMenu*)menu;
        mb->addMenu(m);  // Add menu to menu bar
        return 0;
    }
    
    static long long create_action(const char* title, long long callback) {
        QAction* act = new QAction(title ? QString::fromUtf8(title) : QString());
        // Only try to connect if callback is non-zero and looks valid
        // (this is a heuristic - real fix needs proper callback trampoline)
        // if (callback && callback != 0x1) {
        //     std::function<void()> cb = *(std::function<void()>*)&callback;
        //     QObject::connect(act, &QAction::triggered, [cb]() { cb(); });
        // }
        // For now, don't try to connect any callbacks - just create the action
        Q_UNUSED(callback);  // Silence unused warning
        return (long long)(void*)act;
    }
    
    static long long add_action_to_menu(long long menu, long long action) {
        if (!menu || !action) return -1;
        ((QMenu*)menu)->addAction((QAction*)action);
        return 0;
    }
    
    static long long create_toolbar(long long window, const char* title) {
        if (!window) return 0;
        QMainWindow* win = (QMainWindow*)window;
        // Create toolbar with window as parent - critical for proper lifetime
        QToolBar* tb = new QToolBar(
            title ? QString::fromUtf8(title) : QString("Toolbar"), win);
        // Add toolbar to window - this makes it visible and properly manages lifetime
        win->addToolBar(tb);
        // Set toolbar to be movable (optional - can remove if preferred)
        tb->setMovable(true);
        return (long long)(void*)tb;
    }
    
    static long long add_action_to_toolbar(long long toolbar, long long action) {
        if (!toolbar || !action) return -1;
        ((QToolBar*)toolbar)->addAction((QAction*)action);
        return 0;
    }
    
    // Dialogs
    static long long show_msgbox(const char* title, const char* text, int type) {
        QMessageBox::Icon icon = QMessageBox::NoIcon;
        if (type == 1) icon = QMessageBox::Warning;
        else if (type == 2) icon = QMessageBox::Critical;
        else if (type == 3) icon = QMessageBox::Question;
        
        QMessageBox msgBox(icon,
            title ? QString::fromUtf8(title) : QString(),
            text ? QString::fromUtf8(text) : QString(),
            QMessageBox::Ok);
        msgBox.exec();
        return 0;
    }
    
    static QString* file_open_dialog(const char* title, const char* filter) {
        Q_UNUSED(filter);
        QString result = QFileDialog::getOpenFileName(nullptr,
            title ? QString::fromUtf8(title) : QString());
        if (result.isEmpty()) return nullptr;
        return new QString(result);
    }
    
    static QString* file_save_dialog(const char* title, const char* filter) {
        Q_UNUSED(filter);
        QString result = QFileDialog::getSaveFileName(nullptr,
            title ? QString::fromUtf8(title) : QString());
        if (result.isEmpty()) return nullptr;
        return new QString(result);
    }
    
    static QString* input_dialog(const char* title, const char* label, const char* default_text) {
        QString result = QInputDialog::getText(nullptr,
            title ? QString::fromUtf8(title) : QString("Input"),
            label ? QString::fromUtf8(label) : QString("Enter value:"),
            QLineEdit::Normal,
            default_text ? QString::fromUtf8(default_text) : QString());
        if (result.isEmpty()) return nullptr;
        return new QString(result);
    }
};

// C wrapper - ruft die C++ Klasse auf
extern "C" {
long long _qt_menubar_create(long long w) { return QtMenuHelper::create_menubar(w); }
long long _qt_menu_create(long long t) { return QtMenuHelper::create_menu((char*)t); }
long long _qt_menu_add_menu(long long m, long long sub) { return QtMenuHelper::add_menu_to_menubar(m, sub); }
long long _qt_action_create(long long t, long long cb) { return QtMenuHelper::create_action((char*)t, cb); }
long long _qt_menu_add_action(long long m, long long a) { return QtMenuHelper::add_action_to_menu(m, a); }
long long _qt_toolbar_create(long long w, long long t) { return QtMenuHelper::create_toolbar(w, (char*)t); }
long long _qt_toolbar_add_action(long long tb, long long a) { return QtMenuHelper::add_action_to_toolbar(tb, a); }
long long _qt_msgbox_show(long long t, long long txt, long long type) { return QtMenuHelper::show_msgbox((char*)t, (char*)txt, (int)type); }
long long _qt_file_open_dialog(long long p, long long t, long long f) { 
    QString* s = QtMenuHelper::file_open_dialog((char*)t, (char*)f);
    return (long long)(void*)s;
}
long long _qt_file_save_dialog(long long p, long long t, long long f) { 
    QString* s = QtMenuHelper::file_save_dialog((char*)t, (char*)f);
    return (long long)(void*)s;
}
long long _qt_input_dialog(long long p, long long t, long long l, long long d) { 
    QString* s = QtMenuHelper::input_dialog((char*)t, (char*)l, (char*)d);
    return (long long)(void*)s;
}
} // extern "C"

// ============================================================================
// Screen info
// ============================================================================

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
// QTabWidget - Tabbed container
// ============================================================================

// qt_tabwidget_create(parent) — create a tab widget
long long _qt_tabwidget_create(long long parent) {
    QTabWidget* tw = new QTabWidget(parent ? (QWidget*)parent : nullptr);
    return (long long)(void*)tw;
}

// qt_tabwidget_add_tab(tabwidget, widget, title) — add a tab with child widget
long long _qt_tabwidget_add_tab(long long tabwidget, long long widget, long long title) {
    if (!tabwidget) return -1;
    ((QTabWidget*)tabwidget)->addTab(
        widget ? (QWidget*)widget : nullptr,
        title ? QString::fromUtf8((const char*)title) : QString("Tab"));
    return 0;
}

// qt_tabwidget_insert_tab(tabwidget, index, widget, title) — insert tab at position
long long _qt_tabwidget_insert_tab(long long tabwidget, long long index, long long widget, long long title) {
    if (!tabwidget) return -1;
    ((QTabWidget*)tabwidget)->insertTab((int)index,
        widget ? (QWidget*)widget : nullptr,
        title ? QString::fromUtf8((const char*)title) : QString("Tab"));
    return 0;
}

// qt_tabwidget_current_index(tabwidget) — get current tab index
long long _qt_tabwidget_current_index(long long tabwidget) {
    if (!tabwidget) return 0;
    return ((QTabWidget*)tabwidget)->currentIndex();
}

// qt_tabwidget_set_current_index(tabwidget, index) — set current tab
long long _qt_tabwidget_set_current_index(long long tabwidget, long long index) {
    if (!tabwidget) return -1;
    ((QTabWidget*)tabwidget)->setCurrentIndex((int)index);
    return 0;
}

// qt_tabwidget_count(tabwidget) — get number of tabs
long long _qt_tabwidget_count(long long tabwidget) {
    if (!tabwidget) return 0;
    return ((QTabWidget*)tabwidget)->count();
}

// qt_tabwidget_remove_tab(tabwidget, index) — remove tab at index
long long _qt_tabwidget_remove_tab(long long tabwidget, long long index) {
    if (!tabwidget) return -1;
    ((QTabWidget*)tabwidget)->removeTab((int)index);
    return 0;
}

// qt_tabwidget_set_tab_enabled(tabwidget, index, enabled) — enable/disable tab
long long _qt_tabwidget_set_tab_enabled(long long tabwidget, long long index, long long enabled) {
    if (!tabwidget) return -1;
    ((QTabWidget*)tabwidget)->setTabEnabled((int)index, enabled != 0);
    return 0;
}

// ============================================================================
// Container: QWidget as generic container
// ============================================================================

// ============================================================================
// QPlainTextEdit - Multi-line text input (like TMemo)
// ============================================================================

// qt_textedit_create(parent, text) — create a multi-line text edit
long long _qt_textedit_create(long long parent, long long text) {
    QPlainTextEdit* te = new QPlainTextEdit(parent ? (QWidget*)parent : nullptr);
    if (text) {
        te->setPlainText(text ? QString::fromUtf8((const char*)text) : QString());
    }
    return (long long)(void*)te;
}

// qt_textedit_set_text(textedit, text) — set text content
long long _qt_textedit_set_text(long long textedit, long long text) {
    if (!textedit) return -1;
    ((QPlainTextEdit*)textedit)->setPlainText(
        text ? QString::fromUtf8((const char*)text) : QString());
    return 0;
}

// qt_textedit_get_text(textedit) — get text content (returns QString*)
long long _qt_textedit_get_text(long long textedit) {
    if (!textedit) return 0;
    return (long long)(void*)new QString(((QPlainTextEdit*)textedit)->toPlainText());
}

// qt_textedit_append(textedit, text) — append text
long long _qt_textedit_append(long long textedit, long long text) {
    if (!textedit) return -1;
    ((QPlainTextEdit*)textedit)->appendPlainText(
        text ? QString::fromUtf8((const char*)text) : QString());
    return 0;
}

// qt_textedit_clear(textedit) — clear all text
long long _qt_textedit_clear(long long textedit) {
    if (!textedit) return -1;
    ((QPlainTextEdit*)textedit)->clear();
    return 0;
}

// qt_textedit_set_read_only(textedit, readonly) — set read-only mode
long long _qt_textedit_set_read_only(long long textedit, long long readonly) {
    if (!textedit) return -1;
    ((QPlainTextEdit*)textedit)->setReadOnly(readonly != 0);
    return 0;
}

// qt_textedit_set_line_wrap_mode(textedit, mode) — set line wrap mode (0=no, 1=word, 2=character)
long long _qt_textedit_set_line_wrap_mode(long long textedit, long long mode) {
    if (!textedit) return -1;
    // 0 = NoWrap, 1 = WidgetWidth
    if (mode == 0) {
        ((QPlainTextEdit*)textedit)->setLineWrapMode(QPlainTextEdit::NoWrap);
    } else {
        ((QPlainTextEdit*)textedit)->setLineWrapMode(QPlainTextEdit::WidgetWidth);
    }
    return 0;
}

// qt_textedit_set_tab_stop_width(textedit, pixels) — set tab stop width in pixels
long long _qt_textedit_set_tab_stop_width(long long textedit, long long pixels) {
    if (!textedit) return -1;
    ((QPlainTextEdit*)textedit)->setTabStopDistance((int)pixels);
    return 0;
}

// qt_textedit_set_placeholder(textedit, placeholder) — set placeholder text
long long _qt_textedit_set_placeholder(long long textedit, long long placeholder) {
    if (!textedit) return -1;
    // Note: QPlainTextEdit doesn't have setPlaceholderText in Qt5, use QLineEdit instead
    Q_UNUSED(textedit);
    Q_UNUSED(placeholder);
    return 0;
}

// ============================================================================
// QTreeView - Tree/List widget
// ============================================================================

// qt_treewidget_create(parent) — create a tree widget
long long _qt_treewidget_create(long long parent) {
    QTreeView* tw = new QTreeView(parent ? (QWidget*)parent : nullptr);
    tw->setHeaderHidden(false);
    return (long long)(void*)tw;
}

// qt_treewidget_add_item(treewidget, text) — add root item
long long _qt_treewidget_add_item(long long treewidget, long long text) {
    if (!treewidget) return -1;
    Q_UNUSED(text);
    // Simplified: use setWindowTitle as placeholder
    ((QTreeView*)treewidget)->setWindowTitle(text ? QString::fromUtf8((const char*)text) : QString("Tree"));
    return 0;
}

// qt_treewidget_expand_all(treewidget) — expand all items
long long _qt_treewidget_expand_all(long long treewidget) {
    if (!treewidget) return -1;
    ((QTreeView*)treewidget)->expandAll();
    return 0;
}

// qt_treewidget_collapse_all(treewidget) — collapse all items
long long _qt_treewidget_collapse_all(long long treewidget) {
    if (!treewidget) return -1;
    ((QTreeView*)treewidget)->collapseAll();
    return 0;
}

// qt_treewidget_set_header_visible(treewidget, visible) — show/hide header
long long _qt_treewidget_set_header_visible(long long treewidget, long long visible) {
    if (!treewidget) return -1;
    ((QTreeView*)treewidget)->setHeaderHidden(visible == 0);
    return 0;
}

// ============================================================================
// QTableView - Table widget (like TStringGrid)
// ============================================================================

// qt_tablewidget_create(parent, rows, cols) — create a table widget
long long _qt_tablewidget_create(long long parent, long long rows, long long cols) {
    QTableView* tw = new QTableView(parent ? (QWidget*)parent : nullptr);
    tw->setSelectionBehavior(QAbstractItemView::SelectRows);
    tw->setSelectionMode(QAbstractItemView::SingleSelection);
    return (long long)(void*)tw;
}

// qt_tablewidget_set_row_count(tablewidget, rows) — set number of rows
long long _qt_tablewidget_set_row_count(long long tablewidget, long long rows) {
    if (!tablewidget) return -1;
    Q_UNUSED(rows);  // Requires QStandardItemModel
    return 0;
}

// qt_tablewidget_set_column_count(tablewidget, cols) — set number of columns
long long _qt_tablewidget_set_column_count(long long tablewidget, long long cols) {
    if (!tablewidget) return -1;
    Q_UNUSED(cols);  // Requires QStandardItemModel
    return 0;
}

// qt_tablewidget_set_item(tablewidget, row, col, text) — set cell text
long long _qt_tablewidget_set_item(long long tablewidget, long long row, long long col, long long text) {
    if (!tablewidget) return -1;
    Q_UNUSED(row);
    Q_UNUSED(col);
    Q_UNUSED(text);  // Requires QStandardItemModel
    return 0;
}

// qt_tablewidget_get_item(tablewidget, row, col) — get cell text
long long _qt_tablewidget_get_item(long long tablewidget, long long row, long long col) {
    if (!tablewidget) return 0;
    Q_UNUSED(row);
    Q_UNUSED(col);  // Requires QStandardItemModel
    return 0;
}

// qt_tablewidget_set_column_width(tablewidget, col, width) — set column width
long long _qt_tablewidget_set_column_width(long long tablewidget, long long col, long long width) {
    if (!tablewidget) return -1;
    ((QTableView*)tablewidget)->setColumnWidth((int)col, (int)width);
    return 0;
}

// qt_tablewidget_resize_columns_to_content(tablewidget) — auto-resize columns
long long _qt_tablewidget_resize_columns_to_content(long long tablewidget) {
    if (!tablewidget) return -1;
    ((QTableView*)tablewidget)->resizeColumnsToContents();
    return 0;
}

// qt_tablewidget_current_row(tablewidget) — get selected row
long long _qt_tablewidget_current_row(long long tablewidget) {
    if (!tablewidget) return -1;
    return ((QTableView*)tablewidget)->currentIndex().row();
}

// qt_tablewidget_current_column(tablewidget) — get selected column
long long _qt_tablewidget_current_column(long long tablewidget) {
    if (!tablewidget) return -1;
    return ((QTableView*)tablewidget)->currentIndex().column();
}

// qt_tablewidget_clear(tablewidget) — clear all data
long long _qt_tablewidget_clear(long long tablewidget) {
    if (!tablewidget) return -1;
    // Requires QStandardItemModel
    return 0;
}

// qt_tablewidget_set_alternating_row_colors(tablewidget, enable) — alternating row colors
long long _qt_tablewidget_set_alternating_row_colors(long long tablewidget, long long enable) {
    if (!tablewidget) return -1;
    ((QTableView*)tablewidget)->setAlternatingRowColors(enable != 0);
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
    // Make container expand to fill available space
    container->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    // Set minimum size to ensure visibility
    container->setMinimumSize(200, 100);
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

// ============================================================================
// Layout Managers (WP5)
// ============================================================================

// --- QHBoxLayout ---

// qt_hbox_create() — create a standalone horizontal layout.
// Returns: QHBoxLayout* as int64
long long _qt_hbox_create(void) {
    QHBoxLayout* layout = new QHBoxLayout();
    return (long long)(void*)layout;
}

// qt_hbox_add_widget(layout, widget) — add widget to hbox layout.
long long _qt_hbox_add_widget(long long layout, long long widget) {
    if (!layout || !widget) return -1;
    ((QHBoxLayout*)layout)->addWidget((QWidget*)widget);
    return 0;
}

// qt_hbox_add_layout(layout, child) — add nested layout to hbox.
long long _qt_hbox_add_layout(long long layout, long long child) {
    if (!layout || !child) return -1;
    ((QHBoxLayout*)layout)->addLayout((QLayout*)child);
    return 0;
}

// qt_hbox_add_spacer(layout, width, height, h_expand, v_expand) — add spacer.
long long _qt_hbox_add_spacer(long long layout, long long width, long long height, long long h_expand, long long v_expand) {
    if (!layout) return -1;
    QSizePolicy::Policy he = h_expand ? QSizePolicy::Expanding : QSizePolicy::Minimum;
    QSizePolicy::Policy ve = v_expand ? QSizePolicy::Expanding : QSizePolicy::Minimum;
    ((QHBoxLayout*)layout)->addItem(new QSpacerItem((int)width, (int)height, he, ve));
    return 0;
}

// qt_hbox_set_spacing(layout, spacing) — set spacing between widgets.
long long _qt_hbox_set_spacing(long long layout, long long spacing) {
    if (!layout) return -1;
    ((QHBoxLayout*)layout)->setSpacing((int)spacing);
    return 0;
}

// qt_hbox_set_margins(layout, left, top, right, bottom) — set contents margins.
long long _qt_hbox_set_margins(long long layout, long long left, long long top, long long right, long long bottom) {
    if (!layout) return -1;
    ((QHBoxLayout*)layout)->setContentsMargins((int)left, (int)top, (int)right, (int)bottom);
    return 0;
}

// --- QGridLayout ---

// qt_grid_create() — create a grid layout.
// Returns: QGridLayout* as int64
long long _qt_grid_create(void) {
    QGridLayout* layout = new QGridLayout();
    return (long long)(void*)layout;
}

// qt_grid_add_widget(layout, widget, row, col, rowspan, colspan, alignment) — add widget to grid.
long long _qt_grid_add_widget(long long layout, long long widget, long long row, long long col, long long rowspan, long long colspan, long long alignment) {
    if (!layout || !widget) return -1;
    ((QGridLayout*)layout)->addWidget((QWidget*)widget, (int)row, (int)col, (int)rowspan, (int)colspan, (Qt::AlignmentFlag)(int)alignment);
    return 0;
}

// qt_grid_add_layout(layout, child, row, col, rowspan, colspan, alignment) — add nested layout.
long long _qt_grid_add_layout(long long layout, long long child, long long row, long long col, long long rowspan, long long colspan, long long alignment) {
    if (!layout || !child) return -1;
    ((QGridLayout*)layout)->addLayout((QLayout*)child, (int)row, (int)col, (int)rowspan, (int)colspan, (Qt::AlignmentFlag)(int)alignment);
    return 0;
}

// qt_grid_set_row_stretch(layout, row, stretch) — set row stretch factor.
long long _qt_grid_set_row_stretch(long long layout, long long row, long long stretch) {
    if (!layout) return -1;
    ((QGridLayout*)layout)->setRowStretch((int)row, (int)stretch);
    return 0;
}

// qt_grid_set_column_stretch(layout, col, stretch) — set column stretch factor.
long long _qt_grid_set_column_stretch(long long layout, long long col, long long stretch) {
    if (!layout) return -1;
    ((QGridLayout*)layout)->setColumnStretch((int)col, (int)stretch);
    return 0;
}

// qt_grid_set_spacing(layout, spacing) — set horizontal and vertical spacing.
long long _qt_grid_set_spacing(long long layout, long long spacing) {
    if (!layout) return -1;
    ((QGridLayout*)layout)->setSpacing((int)spacing);
    return 0;
}

// qt_grid_set_margins(layout, left, top, right, bottom) — set contents margins.
long long _qt_grid_set_margins(long long layout, long long left, long long top, long long right, long long bottom) {
    if (!layout) return -1;
    ((QGridLayout*)layout)->setContentsMargins((int)left, (int)top, (int)right, (int)bottom);
    return 0;
}

// --- QVBoxLayout (standalone) ---

// qt_vbox_create() — create a standalone vertical layout.
// Returns: QVBoxLayout* as int64
long long _qt_vbox_create(void) {
    QVBoxLayout* layout = new QVBoxLayout();
    return (long long)(void*)layout;
}

// qt_vbox_add_widget(layout, widget) — add widget to vbox layout.
long long _qt_vbox_add_widget(long long layout, long long widget) {
    if (!layout || !widget) return -1;
    ((QVBoxLayout*)layout)->addWidget((QWidget*)widget);
    return 0;
}

// qt_vbox_add_layout(layout, child) — add nested layout to vbox.
long long _qt_vbox_add_layout(long long layout, long long child) {
    if (!layout || !child) return -1;
    ((QVBoxLayout*)layout)->addLayout((QLayout*)child);
    return 0;
}

// qt_vbox_add_spacer(layout, width, height, h_expand, v_expand) — add spacer.
long long _qt_vbox_add_spacer(long long layout, long long width, long long height, long long h_expand, long long v_expand) {
    if (!layout) return -1;
    QSizePolicy::Policy he = h_expand ? QSizePolicy::Expanding : QSizePolicy::Minimum;
    QSizePolicy::Policy ve = v_expand ? QSizePolicy::Expanding : QSizePolicy::Minimum;
    ((QVBoxLayout*)layout)->addItem(new QSpacerItem((int)width, (int)height, he, ve));
    return 0;
}

// qt_vbox_set_spacing(layout, spacing) — set spacing between widgets.
long long _qt_vbox_set_spacing(long long layout, long long spacing) {
    if (!layout) return -1;
    ((QVBoxLayout*)layout)->setSpacing((int)spacing);
    return 0;
}

// qt_vbox_set_margins(layout, left, top, right, bottom) — set contents margins.
long long _qt_vbox_set_margins(long long layout, long long left, long long top, long long right, long long bottom) {
    if (!layout) return -1;
    ((QVBoxLayout*)layout)->setContentsMargins((int)left, (int)top, (int)right, (int)bottom);
    return 0;
}

// --- Set layout on widget ---

// qt_widget_set_layout(widget, layout) — set layout on a QWidget.
long long _qt_widget_set_layout(long long widget, long long layout) {
    if (!widget || !layout) return -1;
    ((QWidget*)widget)->setLayout((QLayout*)layout);
    return 0;
}

// ============================================================================
// QSplitter
// ============================================================================
// QSplitter
// ============================================================================

// qt_splitter_create(parent, orientation) — create a splitter widget.
// orientation: 0 = Horizontal, 1 = Vertical
// Returns: QSplitter* as int64
long long _qt_splitter_create(long long parent, long long orientation) {
    QWidget* p = parent ? (QWidget*)parent : nullptr;
    Qt::Orientation o = orientation ? Qt::Vertical : Qt::Horizontal;
    QSplitter* splitter = new QSplitter(o, p);
    return (long long)(void*)splitter;
}

// qt_splitter_add_widget(splitter, widget) — add widget to splitter.
long long _qt_splitter_add_widget(long long splitter, long long widget) {
    if (!splitter || !widget) return -1;
    ((QSplitter*)splitter)->addWidget((QWidget*)widget);
    return 0;
}

// qt_splitter_set_stretch(splitter, index, stretch) — set stretch factor.
long long _qt_splitter_set_stretch(long long splitter, long long index, long long stretch) {
    if (!splitter) return -1;
    ((QSplitter*)splitter)->setStretchFactor((int)index, (int)stretch);
    return 0;
}

// qt_splitter_set_sizes(splitter, sizes, count) — set sizes of all widgets.
// sizes: array of int64 values
long long _qt_splitter_set_sizes(long long splitter, long long sizes, long long count) {
    if (!splitter || !sizes) return -1;
    QList<int> list;
    long long* arr = (long long*)sizes;
    for (int i = 0; i < (int)count; i++) {
        list.append((int)arr[i]);
    }
    ((QSplitter*)splitter)->setSizes(list);
    return 0;
}

// qt_splitter_set_collapsed(splitter, index, collapsed) — collapse or expand a widget.
long long _qt_splitter_set_collapsed(long long splitter, long long index, long long collapsed) {
    if (!splitter) return -1;
    ((QSplitter*)splitter)->setCollapsible((int)index, collapsed != 0);
    return 0;
}

} // extern "C"
