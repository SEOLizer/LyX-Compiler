# Root Makefile — delegates to compiler/Makefile
# Build output: ./lyxc (at repo root)

.PHONY: build debug test clean e2e package precompile-units install-bin

# ── Compiler ──────────────────────────────────────────────────────────────────

build:
	$(MAKE) -C compiler build

debug:
	$(MAKE) -C compiler debug

test:
	$(MAKE) -C compiler test

e2e:
	$(MAKE) -C compiler e2e

clean:
	$(MAKE) -C compiler clean

# ── Packaging ─────────────────────────────────────────────────────────────────

VERSION   := 0.8.3-aerospace
DEB_NAME  := lyxc-$(VERSION).deb
PKG_DIR   := lyx-compiler
UNITS_DST := $(PKG_DIR)/usr/include/lyx/units/std
BIN_DST   := $(PKG_DIR)/usr/local/bin

STD_LYXFILES  := $(shell find std  -name "*.lyx" | sort)
DATA_LYXFILES := $(shell find data -name "*.lyx" | sort)

STD_LYUFILES  := $(patsubst std/%.lyx,  $(UNITS_DST)/%.lyu, $(STD_LYXFILES))
DATA_LYUFILES := $(patsubst data/%.lyx, $(UNITS_DST)/%.lyu, $(DATA_LYXFILES))

package: precompile-units install-bin
	dpkg-deb --build $(PKG_DIR) $(DEB_NAME)
	@echo ""
	@echo "Paket fertig: $(DEB_NAME)"

precompile-units: $(STD_LYUFILES) $(DATA_LYUFILES)
	@echo "$(words $(STD_LYUFILES) $(DATA_LYUFILES)) Units vorkompiliert."

install-bin:
	@echo "Installiere lyxc -> $(BIN_DST)/ ..."
	cp lyxc $(BIN_DST)/lyxc
	chmod 755 $(BIN_DST)/lyxc

$(UNITS_DST)/%.lyu: std/%.lyx
	@mkdir -p $(dir $@)
	@echo "  precompile $<"
	./lyxc --compile-unit $< -o $@

$(UNITS_DST)/%.lyu: data/%.lyx
	@mkdir -p $(dir $@)
	@echo "  precompile $<"
	./lyxc --compile-unit $< -o $@
