# Root Makefile — Lyx Bootstrap Compiler
#
# Der Lyx-Compiler ist vollständig selbstkompilierend (100% self-hosted).
# Quelle:  src/lyxc.lyx
# Seed:    src/lyxc_bootstrap  (singularitätsverifiziertes Binary)

SEED := src/lyxc_bootstrap
SRC  := src/lyxc.lyx

# WP-LIC-12: 0 = Lizenzprüfung aus (Dev-Default), 1 = Lizenzprüfung an (Release)
LYXC_LICENSE_REQUIRED ?= 0

UNITS_SRC := $(shell find std  -name "*.lyx" | sort)
DATA_SRC  := $(shell find data -name "*.lyx" | sort)

VERSION   := 0.9.4A
DEB_NAME  := lyxc-$(VERSION).deb
PKG_DIR   := lyx-compiler
UNITS_DST := $(PKG_DIR)/usr/include/lyx/units/std
DATA_DST  := $(PKG_DIR)/usr/include/lyx/units/data
BIN_DST   := $(PKG_DIR)/usr/local/bin

UNITS_LYU := $(patsubst std/%.lyx,  $(UNITS_DST)/%.lyu, $(UNITS_SRC))
DATA_LYU  := $(patsubst data/%.lyx, $(DATA_DST)/%.lyu,  $(DATA_SRC))

.PHONY: build bootstrap singularity test snapshot snapshot-update clean package precompile-units install-bin lic_build_flags keygen

# ── Compiler bauen ────────────────────────────────────────────────────────────

# Build-Flag-Datei schreiben (immer vor der Kompilierung)
lic_build_flags:
	@printf 'con LYXC_LICENSE_REQUIRED: int64 := %s;\n' $(LYXC_LICENSE_REQUIRED) > src/lic_build_flags.lyx

# RAM-Limit für Bootstrap-Läufe: verhindert OOM-Kill der Shell bei Endlosschleifen.
ULIMIT_VM := ulimit -v $$(( 8 * 1024 * 1024 )) &&

# Aus Seed-Binary kompilieren (erster Bootstrap-Schritt)
build: lic_build_flags
	$(ULIMIT_VM) $(SEED) $(SRC) -o lyxc

# Selbstkompilierung: lyxc kompiliert sich selbst (erfordert vorhandenes lyxc)
bootstrap: lyxc lic_build_flags
	$(ULIMIT_VM) ./lyxc $(SRC) -o lyxc.new
	mv lyxc.new lyxc

# Singularitätsprüfung: S3 (Seed→Quelle) == S4 (S3→Quelle)
# Hinweis: Der Seed kompiliert die große Quelle in bis zu 5 Versuchen
# (ASLR-bedingte non-deterministische Crashes bei großem Adressraum).
singularity: lic_build_flags
	@echo "=== Singularitätsprüfung ==="
	@for i in 1 2 3 4 5; do \
		$(ULIMIT_VM) $(SEED) $(SRC) -o /tmp/lyxc_s3 2>/dev/null && break; \
		echo "  [S3-Versuch $$i fehlgeschlagen, retry...]"; \
	done; test -f /tmp/lyxc_s3
	@for i in 1 2 3 4 5; do \
		$(ULIMIT_VM) /tmp/lyxc_s3 $(SRC) -o /tmp/lyxc_s4 2>/dev/null && break; \
		echo "  [S4-Versuch $$i fehlgeschlagen, retry...]"; \
	done; test -f /tmp/lyxc_s4
	@sha256sum /tmp/lyxc_s3 /tmp/lyxc_s4
	@diff /tmp/lyxc_s3 /tmp/lyxc_s4 \
		&& echo "SINGULAR: S3 == S4" \
		|| (echo "NICHT SINGULAR: S3 != S4" && exit 1)
	@rm -f /tmp/lyxc_s3 /tmp/lyxc_s4

# ── Tests ─────────────────────────────────────────────────────────────────────

test: lyxc
	@echo "=== Integrationstest ==="
	./lyxc examples/basics/hello.lyx -o /tmp/lyxc_hello_test
	@/tmp/lyxc_hello_test
	@rm -f /tmp/lyxc_hello_test
	@echo "OK"

snapshot: lyxc
	@bash tests/run_snapshot_tests.sh

snapshot-update: lyxc
	@bash tests/run_snapshot_tests.sh --update

# ── Paketierung ───────────────────────────────────────────────────────────────

package: precompile-units install-bin
	dpkg-deb --build $(PKG_DIR) $(DEB_NAME)
	@echo ""
	@echo "Paket fertig: $(DEB_NAME)"

precompile-units: lyxc
	@echo "Pass 1: Kompiliere Units..."
	@$(MAKE) --no-print-directory -k $(UNITS_LYU) $(DATA_LYU) 2>/dev/null; true
	@echo "Pass 2: Kompiliere abhängige Units..."
	$(MAKE) --no-print-directory $(UNITS_LYU) $(DATA_LYU)
	@echo "$(words $(UNITS_LYU) $(DATA_LYU)) Units vorkompiliert."

install-bin: lyxc
	@echo "Installiere lyxc -> $(BIN_DST)/"
	cp lyxc $(BIN_DST)/lyxc
	chmod 755 $(BIN_DST)/lyxc

$(UNITS_DST)/%.lyu: std/%.lyx lyxc
	@mkdir -p $(dir $@)
	@echo "  precompile $<"
	./lyxc --compile-unit $< -o $@

$(DATA_DST)/%.lyu: data/%.lyx lyxc
	@mkdir -p $(dir $@)
	@echo "  precompile $<"
	./lyxc --compile-unit $< -o $@

# ── Keygen (nicht für Endkunden — nur intern verwenden) ──────────────────────

# Baut lyxc-keygen mit dem Seed-Binary (kein lyxc nötig).
# NICHT ins Paket aufnehmen — nur lokal für die Schlüssel-Ausstellung nutzen.
keygen:
	$(ULIMIT_VM) $(SEED) src/lyxc_keygen.lyx -I src -o lyxc-keygen

# ── Aufräumen ─────────────────────────────────────────────────────────────────

clean:
	rm -f lyxc lyxc.new lyxc-keygen
