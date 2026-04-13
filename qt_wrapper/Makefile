CXX      ?= g++
CXXFLAGS := -std=c++17 -fPIC -O2 -Wall \
            $(shell pkg-config --cflags Qt5Widgets Qt5Core Qt5Gui)
LDFLAGS  := -shared \
            $(shell pkg-config --libs Qt5Widgets Qt5Core Qt5Gui)

TARGET   := libqtlyx.so
SRC      := qt_wrapper.cpp

.PHONY: all install clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS)
	@echo "Built $(TARGET)"

install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/lib/
	ldconfig
	@echo "Installed $(TARGET) → /usr/local/lib/"

clean:
	rm -f $(TARGET)
