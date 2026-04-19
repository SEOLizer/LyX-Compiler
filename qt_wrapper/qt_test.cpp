// qt_test.cpp - Minimal C++ test to verify Qt works
#include <QApplication>
#include <QMainWindow>
#include <QLabel>
#include <QVBoxLayout>
#include <QWidget>

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);
    
    QMainWindow win;
    win.setWindowTitle("C++ Test");
    win.resize(400, 400);
    
    QWidget container;
    QVBoxLayout* layout = new QVBoxLayout(&container);
    layout->setContentsMargins(10,10,10,10);
    layout->setSpacing(5);
    
    QLabel* label = new QLabel("C++ LABEL TEST");
    QLabel* label2 = new QLabel("Button would go here");
    QLabel* label3 = new QLabel("More widgets...");
    
    layout->addWidget(label);
    layout->addWidget(label2);
    layout->addWidget(label3);
    layout->addStretch();
    
    container.setLayout(layout);
    container.setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    win.setCentralWidget(&container);
    
    win.show();
    
    return app.exec();
}