FPC      = fpc
FPCFLAGS = -Mobjfpc -Sh -FUlib/ -Fuutil/ -Fufrontend/ -Fuir/ -Fubackend/ -Fubackend/x86_64/ -Fubackend/elf/ -Fubackend/pe/ -Fubackend/arm64/ -Fubackend/macho/ -Fubackend/xtensa/ -Fubackend/esp32/ -Fubackend/macosx64/ -Fubackend/win_arm64/

# Release-Flags
RELEASE_FLAGS = -O2
# Debug-Flags (Range/Overflow/Stack-Checks, Heaptrace)
DEBUG_FLAGS   = -g -gl -Ci -Cr -Co -gh

# Test roots (relative to repo root, one level up)
TESTS_REGRESSION   = ../tests/regression
TESTS_FEATURES     = ../tests/feature_checks

# Alle Test-Units (nur existierende .pas Dateien)
# Ausgeschlossene Tests: test_printf und test_std_examples (Import-Konflikte durch Funktionsüberladung)
TEST_SOURCES = $(filter-out ../tests/test_printf.pas ../tests/test_std_examples.pas,$(wildcard ../tests/test_*.pas))
TESTS        = $(TEST_SOURCES:.pas=)

.PHONY: build debug test clean e2e

build:
	@mkdir -p lib
	$(FPC) $(FPCFLAGS) $(RELEASE_FLAGS) lyxc.lpr -o../lyxc

debug:
	@mkdir -p lib
	$(FPC) $(FPCFLAGS) $(DEBUG_FLAGS) lyxc.lpr -o../lyxc_debug

test: $(TESTS)
	@echo "=== Alle Tests ==="
	@fail=0; \
	for t in $(TESTS); do \
		echo "--- $$t ---"; \
		./$$t --all --format=plain || fail=1; \
	done; \
	if [ $$fail -eq 1 ]; then echo "FEHLER: Einige Tests fehlgeschlagen"; exit 1; fi; \
	echo "=== Alle Tests bestanden ==="

.PHONY: syntax-test
syntax-test:
	@echo "=== Syntax Grammar Tests ==="
	@../tests/aurumc/test_grammar.sh

# End-to-end smoke tests (uses ../lyxc binary built by 'build')
e2e: build
	@echo "=== E2E: hello ==="
	@../lyxc ../examples/hello.lyx -o /tmp/lyx_hello || exit 1
	@/tmp/lyx_hello || exit 1
	@echo "=== E2E: print_int ==="
	@../lyxc $(TESTS_REGRESSION)/printf/print_int.lyx -o /tmp/lyx_print_int || exit 1
	@/tmp/lyx_print_int || exit 1
	@echo "=== E2E: crt ANSI demo ==="
	@../lyxc $(TESTS_REGRESSION)/crt/test_crt_ansi.lyx -o /tmp/lyx_test_crt_ansi || exit 1
	@/tmp/lyx_test_crt_ansi || exit 1
	@echo "=== E2E: println/printf demo ==="
	@../lyxc $(TESTS_REGRESSION)/printf/test_println.lyx -o /tmp/lyx_test_println || exit 1
	@/tmp/lyx_test_println || exit 1
	@echo "=== E2E: generics ==="
	@../lyxc $(TESTS_FEATURES)/generics/test_generics.lyx -o /tmp/lyx_test_generics || exit 1
	@/tmp/lyx_test_generics || exit 1
	@echo "=== E2E: pattern matching ==="
	@../lyxc $(TESTS_FEATURES)/pattern_matching/test_pattern_matching.lyx -o /tmp/lyx_test_pm || exit 1
	@/tmp/lyx_test_pm || exit 1
	@echo "=== E2E passed ==="

clean:
	rm -f ../lyxc ../lyxc_debug
	rm -f lib/*.ppu lib/*.o
	rm -f *.ppu *.o
