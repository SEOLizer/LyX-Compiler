# Root Makefile — Lyx Bootstrap Compiler
#
# Der Lyx-Compiler ist vollständig selbstkompilierend (100% self-hosted).
# Quelle:  src/lyxc.lyx
# Seed:    src/lyxc_bootstrap  (singularitätsverifiziertes Binary)
#
# Der Seed muss neu verankert werden, sobald sich die AUSGABE des Codegens
# ändert — nicht erst beim Versionsbump. `make singularity` ist der Detektor:
# S3 (Seed → Quelle) und S4 (S3 → Quelle) laufen dann auseinander, weil S3 die
# Bytes des alten Codegens trägt. Der Seed war bis 1.0.12A auf 1.0.7B stehen
# geblieben und belegte damit nichts mehr (#1167). Verankern heißt: den
# Fixpunkt (gen2 == gen3 == gen4) nach src/lyxc_bootstrap kopieren, dann
# `make singularity` — sie muss SINGULAR melden.

SEED := src/lyxc_bootstrap
SRC  := src/lyxc.lyx

# WP-LIC-12: 0 = Lizenzprüfung aus (Dev-Default), 1 = Lizenzprüfung an (Release)
LYXC_LICENSE_REQUIRED ?= 0

UNITS_SRC := $(shell find std  -name "*.lyx" | sort)
DATA_SRC  := $(shell find data -name "*.lyx" | sort)

VERSION   := 1.0.14B
VERSION_DATE := 2026-08-09
DEB_NAME  := lyxc-$(VERSION).deb
PKG_DIR   := lyx-compiler
UNITS_DST := $(PKG_DIR)/usr/include/lyx/units/std
DATA_DST  := $(PKG_DIR)/usr/include/lyx/units/data
BIN_DST   := $(PKG_DIR)/usr/local/bin

UNITS_LYU := $(patsubst std/%.lyx,  $(UNITS_DST)/%.lyu, $(UNITS_SRC))
DATA_LYU  := $(patsubst data/%.lyx, $(DATA_DST)/%.lyu,  $(DATA_SRC))

.PHONY: build bootstrap singularity test test-external test-lyxos test-lyx-integration test-known-red snapshot snapshot-update clean package precompile-units install-bin lic_build_flags keygen sync-units-src

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
	@echo "--- LX-25: Block Header ---"
	./lyxc tests/lx25_block_header_test.lyx -o /tmp/lyxc_lx25_test
	@/tmp/lyxc_lx25_test
	@rm -f /tmp/lyxc_lx25_test
	@echo "--- LX-26: Genesis Serializer ---"
	./lyxc tests/lx26_genesis_test.lyx -o /tmp/lyxc_lx26_test
	@/tmp/lyxc_lx26_test
	@rm -f /tmp/lyxc_lx26_test
	@echo "--- LX-27: TLV-Framework ---"
	./lyxc tests/lx27_tlv_test.lyx -o /tmp/lyxc_lx27_test
	@/tmp/lyxc_lx27_test
	@rm -f /tmp/lyxc_lx27_test
	@echo "--- LX-28: Section Block Emitter ---"
	./lyxc tests/lx28_sections_test.lyx -o /tmp/lyxc_lx28_test
	@/tmp/lyxc_lx28_test
	@rm -f /tmp/lyxc_lx28_test
	@echo "--- LX-29: Supply Chain Security ---"
	./lyxc tests/lx29_security_test.lyx -o /tmp/lyxc_lx29_test
	@/tmp/lyxc_lx29_test
	@rm -f /tmp/lyxc_lx29_test
	@echo "--- LX-30: LBF-Nativ Backend ---"
	./lyxc tests/lx30_lbf_backend_test.lyx -o /tmp/lyxc_lx30_test
	@/tmp/lyxc_lx30_test
	@rm -f /tmp/lyxc_lx30_test
	@echo "--- LX-31: lbf_loader ---"
	./lyxc tests/lx31_lbf_loader_test.lyx -o /tmp/lyxc_lx31_test
	@/tmp/lyxc_lx31_test
	@rm -f /tmp/lyxc_lx31_test
	./lyxc tests/lx32_lbf_import_test.lyx -o /tmp/lyxc_lx32_test
	@/tmp/lyxc_lx32_test
	@rm -f /tmp/lyxc_lx32_test
	./lyxc tests/lx33_dep_resolver_test.lyx -o /tmp/lyxc_lx33_test
	@/tmp/lyxc_lx33_test
	@rm -f /tmp/lyxc_lx33_test
	./lyxc tests/lx35_lbf_dump_test.lyx -o /tmp/lyxc_lx35_test
	@/tmp/lyxc_lx35_test
	@rm -f /tmp/lyxc_lx35_test
	@echo "--- LBF nativer Loader/Runtime (End-to-End) ---"
	./lyxc tests/lbf_run_test.lyx -o /tmp/lyxc_lbfrun_test
	@/tmp/lyxc_lbfrun_test
	@rm -f /tmp/lyxc_lbfrun_test
	@echo "--- LX-30: nativer lyxos-LYX!-Emit ---"
	@bash tests/lbf_native_emit_test.sh
	@echo "OK"
	@echo "--- LYXOS-WP-1: Arithmetik/Vergleiche (6 tests) ---"
	@bash tests/lyxos_wp1_arith_test.sh
	@echo "OK"
	@echo "--- LYXOS-WP-2: Control-Flow nativ ausgeführt (6 tests) ---"
	@bash tests/lyxos_wp2_controlflow_test.sh
	@echo "OK"
	@echo "--- LYXOS-WP-3: Globals nativ ausgeführt (5 tests) ---"
	@bash tests/lyxos_wp3_globals_test.sh
	@echo "OK"
	@echo "--- LYXOS-WP-4: Fields/Index Emission (4 tests) ---"
	@bash tests/lyxos_wp4_fields_test.sh
	@echo "OK"
	@echo "--- LYXOS-WP-5: Multi-Section-Metadaten (5 tests) ---"
	@bash tests/lyxos_wp5_sections_test.sh
	@echo "OK"
	@echo "--- LYXOS pchar-Variable an PrintStr (4 tests) ---"
	@bash tests/lyxos_pchar_var_test.sh
	@echo "OK"
	@echo "--- LYXOS user-Funktions-Calls (8 tests) ---"
	@bash tests/lyxos_call_args_test.sh
	@echo "OK"
	@echo "--- LYXOS Memory-Intrinsics peek/poke/StrCharAt (10 tests) ---"
	@bash tests/lyxos_builtin_intrinsics_test.sh
	@echo "OK"
	@echo "--- LYXOS strength-reduction *2^k / div2^k (20 tests) ---"
	@bash tests/lyxos_strength_reduction_test.sh
	@echo "OK"
	@echo "--- Statischer Methodenaufruf TypeName.Method() (7 tests) ---"
	@bash tests/static_method_call_test.sh
	@echo "OK"
	@echo "--- sys_open/sys_lseek Datei-Roundtrip (6 Prüfungen) ---"
	./lyxc --std-path=. tests/sys_file_syscalls_test.lyx -o /tmp/lyxc_sf_test
	@/tmp/lyxc_sf_test > /dev/null
	@rm -f /tmp/lyxc_sf_test
	@echo "OK"
	@echo "--- Select/Poll I/O-Multiplexing (3 Prüfungen) ---"
	./lyxc --std-path=. tests/select_poll_test.lyx -o /tmp/lyxc_sp_test
	@/tmp/lyxc_sp_test > /dev/null
	@rm -f /tmp/lyxc_sp_test
	@echo "OK"
	@echo "--- _indirect_call_N Argumentlage (5 Prüfungen) ---"
	./lyxc --std-path=. tests/indirect_call_test.lyx -o /tmp/lyxc_ic_test
	@/tmp/lyxc_ic_test > /dev/null
	@rm -f /tmp/lyxc_ic_test
	@echo "OK"
	@echo "--- Keine Phantom-Builtins in sema (10 tests) ---"
	@bash tests/no_phantom_builtins_test.sh
	@echo "OK"
	@echo "--- Import auf fehlendes Modul (6 tests) ---"
	@bash tests/dangling_import_test.sh
	@echo "OK"
	@echo "--- Mehrdeutige Symbole aus zwei Units (4 Prüfungen) ---"
	@bash tests/ambiguous_symbol_test.sh
	@echo "OK"
	@echo "--- Printf im x86-Codegen (15 Prüfungen) ---"
	@bash tests/printf_x86_test.sh
	@echo "OK"
	@echo "--- uintN als Schreibweise von uN (6 Prüfungen) ---"
	@bash tests/uint_alias_test.sh
	@echo "OK"
	@echo "--- zstd: melden statt raten (3 Prüfungen) ---"
	@bash tests/zstd_fail_closed_test.sh
	@bash tests/zstd_compress_test.sh
	@bash tests/gzip_test.sh
	@bash tests/deflate_single_source_test.sh
	@bash tests/brotli_compress_test.sh
	@bash tests/brotli_decode_test.sh
	@bash tests/match_guard_test.sh
	@bash tests/range_type_test.sh
	@bash tests/storage_class_test.sh
	@bash tests/struct_layout_test.sh
	@bash tests/type_inference_test.sh
	@bash tests/struct_method_test.sh
	@bash tests/named_args_test.sh
	@bash tests/tuple_test.sh
	@bash tests/default_param_test.sh
	@bash tests/static_member_test.sh
	@bash tests/oop_super_abstract_test.sh
	@bash tests/nullable_test.sh
	@bash tests/is_type_test.sh
	@bash tests/range_runtime_test.sh
	@bash tests/attribute_test.sh
	@bash tests/while_limit_test.sh
	@bash tests/grammar_gaps_test.sh
	@echo "OK"
	@echo "--- Verschachtelte Funktionen (8 Prüfungen) ---"
	./lyxc --std-path=std tests/nested_fn_test.lyx -o /tmp/lyxc_nfn_test
	@/tmp/lyxc_nfn_test > /dev/null
	@rm -f /tmp/lyxc_nfn_test
	@echo "OK"
	@echo "--- Verschachtelte Funktionen: Capture-Grenze (7 tests) ---"
	@bash tests/nested_fn_capture_test.sh
	@echo "OK"
	@echo "--- Methodenaufruf auf Aufruf-Ergebnis (13 Prüfungen) ---"
	./lyxc --std-path=std tests/method_result_dispatch_test.lyx -o /tmp/lyxc_mrd_test
	@/tmp/lyxc_mrd_test > /dev/null
	@rm -f /tmp/lyxc_mrd_test
	@echo "OK"
	@echo "--- Verschachtelte Aufrufe mit Stack-Argumenten (11 Prüfungen) ---"
	./lyxc --std-path=std tests/nested_call_stackargs_test.lyx -o /tmp/lyxc_ncs_test
	@/tmp/lyxc_ncs_test > /dev/null
	@rm -f /tmp/lyxc_ncs_test
	@echo "OK"
	@echo "--- Statischer Methodenaufruf: Codegen/Argumentlage (10 Prüfungen) ---"
	./lyxc --std-path=std tests/static_method_codegen_test.lyx -o /tmp/lyxc_smc_test
	@/tmp/lyxc_smc_test > /dev/null
	@rm -f /tmp/lyxc_smc_test
	@echo "OK"
	@echo "--- std.process gegen echte Prozesse (8 Prüfungen) ---"
	./lyxc --std-path=std tests/process_unit_test.lyx -o /tmp/lyxc_process_test
	@/tmp/lyxc_process_test > /dev/null
	@rm -f /tmp/lyxc_process_test
	@echo "OK"
	@echo "--- FFI-Trust-Grenze von --compile-unit (5 tests) ---"
	@bash tests/ffi_unit_trust_test.sh
	@echo "OK"
	@echo "--- GLX-/EGL-Wrapper (4 tests) ---"
	@bash tests/glx_egl_wrappers_test.sh
	@echo "OK"
	@echo "--- unbekannte Feldnamen (4 tests) ---"
	@bash tests/unknown_field_test.sh
	@echo "OK"
	@echo "--- AST-Sentinel fuer Knotenindex -1 (3 tests) ---"
	@bash tests/node_sentinel_test.sh
	@echo "OK"
	@echo "--- Atomics und Mutex (11 tests) ---"
	@bash tests/atomics_test.sh
	@echo "OK"
	@echo "--- free-Arity: free(ptr, size) ueberall ---"
	@bash tests/free_arity_test.sh
	@echo "OK"
	@echo "--- Builtins, die Unit-Namen verdecken ---"
	@bash tests/builtin_shadow_test.sh
	@echo "OK"
	@echo "--- Testabdeckung: jede Datei einem Ziel zugeordnet ---"
	@bash tests/test_coverage_test.sh
	@echo "OK"
	@echo "--- ebnf.md Keyword-Liste gegen den Compiler ---"
	@bash tests/ebnf_keywords_test.sh
	@echo "OK"
	@echo "--- Viertes Syscall-Argument liegt in r10 (5 Pruefungen) ---"
	@bash tests/syscall_r10_test.sh
	@echo "OK"
	@echo "--- seccomp-Filter deckt die emittierten Syscalls (12 Pruefungen) ---"
	@bash tests/seccomp_filter_test.sh
	@echo "OK"
	@echo "--- Explizite Enum-Werte (16 Pruefungen) ---"
	@bash tests/enum_explicit_value_test.sh
	@echo "OK"
	@echo "--- x in a..b und for i in a..b (18 Pruefungen) ---"
	@bash tests/in_range_test.sh
	@echo "OK"
	@echo "--- NaN-Vergleiche folgen IEEE 754 (#1128) ---"
	@bash tests/nan_compare_test.sh
	@echo "OK"
	@echo "--- uint64-Vergleiche laufen unsigniert (#1126) ---"
	@bash tests/unsigned_compare_test.sh
	@echo "OK"
	@echo "--- f32 liefert den Wert statt des Bitmusters (#1127) ---"
	@bash tests/f32_value_test.sh
	@echo "OK"
	@echo "--- Rechtsshift auf int64 zieht das Vorzeichen nach (17 Pruefungen) ---"
	@bash tests/shift_right_signed_test.sh
	@echo "OK"
	@echo "--- @bounds_check(true) wirkt (12 Pruefungen) ---"
	@bash tests/bounds_check_directive_test.sh
	@echo "OK"
	@echo "--- Struct-Elemente in Tupeln (16 Pruefungen) ---"
	@bash tests/tuple_struct_elem_test.sh
	@echo "OK"
	@echo "--- Tupel-Rueckgabe aus Methoden (14 Pruefungen) ---"
	@bash tests/method_tuple_return_test.sh
	@echo "OK"
	@echo "--- Geerbte nicht-virtuelle Methode aufrufbar (14 Pruefungen) ---"
	@bash tests/inherited_method_call_test.sh
	@echo "OK"
	@echo "--- defer auf throw- und switch-break-Ausgang (16 Pruefungen) ---"
	@bash tests/defer_exit_paths_test.sh
	@echo "OK"
	@echo "--- Dynamisches Array ohne Initialisierung (12 Pruefungen) ---"
	@bash tests/dyn_array_decl_test.sh
	@echo "OK"
	@echo "--- Array als Funktionsparameter (12 Pruefungen) ---"
	@bash tests/array_param_test.sh
	@echo "OK"
	@echo "--- Bereichsmuster in match (12 Pruefungen) ---"
	@bash tests/match_range_test.sh
	@echo "OK"
	@echo "--- Einheitentypen: Faktor, Dimension, range/wraps (18 Pruefungen) ---"
	@bash tests/utype_test.sh
	@echo "OK"
	@echo "--- Arrays mit Struct-/Klassen-Elementtyp (12 Pruefungen) ---"
	@bash tests/struct_array_test.sh
	@echo "OK"
	@echo "--- Capability-Argumente: Namen geprueft, Wirkung gemeldet (14 Pruefungen) ---"
	@bash tests/capability_args_test.sh
	@echo "OK"
	@echo "--- Versionsangaben stimmen ueberein ---"
	@bash tests/version_consistency_test.sh
	@echo "OK"
	@echo "--- Schmale Ganzzahltypen kuerzen beim Speichern (20 Pruefungen) ---"
	@bash tests/int_width_test.sh
	@echo "OK"
	@echo "--- Ganzzahlbreiten Ende-zu-Ende ---"
	@bash tests/e2e/test_int_widths.sh
	@echo "OK"
	@echo "--- Array-Bereichspruefung (12 Pruefungen) ---"
	@bash tests/bounds_check_test.sh
	@echo "OK"
	@echo "--- TextMate-Grammatik: Schluesselwoerter und Typen vollstaendig ---"
	@bash tests/syntax/test_grammar.sh
	@echo "OK"
	@echo "--- Generics: Typparameter (8 Pruefungen) ---"
	@bash tests/generics_typeparam_test.sh
	@echo "OK"
	@echo "--- Aufruf ueber indizierten Ausdruck wird abgewiesen (6 Pruefungen) ---"
	@bash tests/indexed_call_reject_test.sh
	@echo "OK"
	@echo "--- Inline-Array als Struct-Feld (6 Pruefungen) ---"
	@bash tests/inline_array_field_test.sh
	@echo "OK"
	@echo "--- zstd: Decoder ueber einen Groessenbereich (#1027) ---"
	@bash tests/zstd_measure.sh
	@echo "OK"
	@echo "--- macOS-Backend: BSD-Socket-Syscallnummern (12 Pruefungen) ---"
	@bash tests/macos_socket_syscalls_test.sh
	@echo "OK"
	@echo "--- Print/PrintLn mit Aufruf-Ergebnis (6 Pruefungen) ---"
	@bash tests/print_call_result_test.sh
	@echo "OK"
	@echo "--- Print/PrintLn geben f64 aus (7 Pruefungen) ---"
	@bash tests/print_f64_test.sh
	@echo "OK"
	@echo "--- pub wird beim Import ausgewertet (6 Pruefungen) ---"
	@bash tests/pub_visibility_test.sh
	@echo "OK"
	@echo "--- Builtin-IDs eindeutig vergeben (2 tests) ---"
	@bash tests/builtin_id_test.sh
	@echo "OK"
	@echo "--- Kurzschluss von && und || (10 tests) ---"
	@bash tests/shortcircuit_test.sh
	@echo "OK"
	@echo "--- match: Mustervergleich (15 tests) ---"
	@bash tests/match_patterns_test.sh
	@echo "OK"
	@echo "--- defer an der Blockgrenze (11 tests) ---"
	@bash tests/defer_block_test.sh
	@echo "OK"
	@echo "--- Kernsprache (.lyx-Suite) ---"
	@bash tests/run_lyx_suite.sh tests/suite-core.txt "Kernsprache"
	@echo "OK"
	@echo "--- Funktions- und Methodenzeiger (8 Suiten) ---"
	@bash tests/arity_check_test.sh
	@bash tests/asm_block_test.sh
	@bash tests/elf_reloc_test.sh
	@bash tests/fnptr_field_test.sh
	@bash tests/inline_fnptr_test.sh
	@bash tests/local_fnptr_test.sh
	@bash tests/method_ptr_test.sh
	@bash tests/method_ptr_xmod_test.sh
	@echo "OK"
	@echo "--- Geometrie-/Result-Units (Struct-Literal-Umbau, 31 Prüfungen) ---"
	./lyxc --std-path=std tests/geom_units_test.lyx -o /tmp/lyxc_geom_test
	@/tmp/lyxc_geom_test > /dev/null
	@rm -f /tmp/lyxc_geom_test
	@echo "OK"
	@echo "--- LYXOS @capabilities → CAPS-TLV-Mapping (6 tests) ---"
	@bash tests/lyxos_caps_tlv_test.sh
	@echo "--- LYXOS importierte-Klassen-Methoden-Dispatch (1 test) ---"
	@bash tests/lyxos_imported_class_dispatch_test.sh
	@echo "OK"
	@echo "OK"
	@echo "--- LX-36: Lifecycle Descriptor ---"
	./lyxc tests/lx36_lifecycle_test.lyx -o /tmp/lyxc_lx36_test
	@/tmp/lyxc_lx36_test
	@rm -f /tmp/lyxc_lx36_test

	@echo "--- net_frame: kernel-safe frame units (45 tests) ---"
	./lyxc tests/net_frame_test.lyx -o /tmp/lyxc_net_frame_test
	@/tmp/lyxc_net_frame_test
	@rm -f /tmp/lyxc_net_frame_test

	@echo "--- sec_wp26: alloc()/calloc() Integer-Overflow + Zero-Alloc (18 tests) ---"
	./lyxc tests/sec_wp26_alloc_test.lyx -o /tmp/lyxc_sec_wp26_test
	@/tmp/lyxc_sec_wp26_test
	@rm -f /tmp/lyxc_sec_wp26_test
	@echo "OK"

	@echo "--- sec_wp27: read()-Fehlerbehandlung OOB (7 tests) ---"
	@bash tests/sec_wp27_read_test.sh
	@echo "OK"

	@echo "--- sec_ffi: FFI-Sandbox Fail-Closed (4 tests) ---"
	@bash tests/sec_ffi_failclosed_test.sh
	@echo "OK"

	@echo "--- sec_dns: DNS rdata OOB-Härtung (5 tests) ---"
	@bash tests/sec_dns_oob_test.sh
	@echo "OK"

	@echo "--- sec_tls: TLS Hostname-Verifikation (5 tests) ---"
	@bash tests/sec_tls_hostname_test.sh
	@echo "OK"

	@echo "--- sec_stdpath: --std-path off-by-one (2 tests) ---"
	@bash tests/sec_stdpath_test.sh
	@echo "OK"

	@echo "--- sec_wp28: kernel-mode-guard allowlist (20 tests) ---"
	@bash tests/sec_wp28_kernel_guard_test.sh
	@echo "OK"

	@echo "--- sec_wp29: Ed25519-Lizenzverifikation (20 tests) ---"
	./lyxc tests/sec_wp29_ed25519_test.lyx -o /tmp/lyxc_sec_wp29_test
	@/tmp/lyxc_sec_wp29_test
	@rm -f /tmp/lyxc_sec_wp29_test
	@echo "OK"

	@echo "--- sec_wp30: HTTP Custom-Header CRLF-Injection (20 tests) ---"
	./lyxc tests/sec_wp30_crlf_test.lyx -o /tmp/lyxc_sec_wp30_test
	@/tmp/lyxc_sec_wp30_test
	@rm -f /tmp/lyxc_sec_wp30_test
	@echo "OK"

	@echo "--- sec_wp31: Dateigrößen-Limit FileReadAll (20 tests) ---"
	@bash tests/sec_wp31_filesize_test.sh
	@echo "OK"

	@echo "--- sec_wp32: TOCTOU ms_appendMetaSafe (20 tests) ---"
	@bash tests/sec_wp32_toctou_test.sh
	@echo "OK"

	@echo "--- sec_wp33: String-Library Bounds-Hardening (20 tests) ---"
	@bash tests/sec_wp33_string_bounds_test.sh
	@echo "OK"

	@echo "--- sec_wp34: Codegen-Buffer-Größenlimit (20 tests) ---"
	@bash tests/sec_wp34_codegen_buffer_test.sh
	@echo "OK"

	@echo "--- sec_wp35: LYU-Parser symCount-Limit (20 tests) ---"
	@bash tests/sec_wp35_lyu_symcount_test.sh
	@echo "OK"

	@echo "--- sec_wp36: SecureZero Compiler-Barriere (20 tests) ---"
	@bash tests/sec_wp36_securezero_test.sh
	@echo "OK"

	@echo "--- sec_wp37: RandInt64 Fehlerbehandlung (20 tests) ---"
	@bash tests/sec_wp37_randint64_test.sh
	@echo "OK"

test-lyxos: lyxc
	@echo "=== LyxOS Integrations-Kompilierungstest ==="
	@for f in \
		tests/lyxos/lx00_lbf_magic.lyx \
		tests/lyxos/lx03_entry.lyx \
		tests/lyxos/lx04_io.lyx \
		tests/lyxos/lx05_alloc.lyx \
		tests/lyxos/lx06_fs.lyx \
		tests/lyxos/lx08_net.lyx \
		tests/lyxos/lx09_spawn.lyx \
		tests/lyxos/lx10_mutex.lyx \
		tests/lyxos/lx11_timer.lyx \
		tests/lyxos/lx12_pledge.lyx \
		tests/lyxos/lx13_parallel.lyx \
		tests/lyxos/lx14_ai_infer.lyx \
		tests/lyxos/lx21_two_ret.lyx \
		tests/lyxos/lx25_block_header.lyx \
		tests/lyxos/lx26_genesis.lyx \
		tests/lyxos/lx27_tlv.lyx \
		tests/lyxos/lx28_sections.lyx; do \
		printf "  %-40s" "$$f"; \
		./lyxc $$f --target=lyxos --emit=lbf -o /tmp/lyxos_test.lbf \
			&& echo "OK" \
			|| (echo "FAIL" && exit 1); \
	done
	@rm -f /tmp/lyxos_test.lbf
	@echo "=== Alle LyxOS-Tests kompiliert ==="

snapshot: lyxc
	@bash tests/run_snapshot_tests.sh

snapshot-update: lyxc
	@bash tests/run_snapshot_tests.sh --update

# ── Paketierung ───────────────────────────────────────────────────────────────

package: sync-units-src precompile-units install-bin
	dpkg-deb --build $(PKG_DIR) $(DEB_NAME)
	@echo ""
	@echo "Paket fertig: $(DEB_NAME)"

# Gepackte .lyx-Quelltexte aus der kanonischen Source synchronisieren.
# Der Import-Resolver (sema.lyx) bevorzugt .lyx vor .lyu — die gepackten
# .lyx sind also funktional autoritativ und MÜSSEN der Source entsprechen,
# sonst kompiliert ein installiertes lyxc gegen veraltete stdlib.
sync-units-src:
	@echo "Synchronisiere std/ + data/ .lyx → Paketbaum..."
	@for f in $(UNITS_SRC); do \
		dst=$(UNITS_DST)/$${f#std/}; \
		mkdir -p $$(dirname $$dst); \
		cp $$f $$dst; \
	done
	@for f in $(DATA_SRC); do \
		dst=$(DATA_DST)/$${f#data/}; \
		mkdir -p $$(dirname $$dst); \
		cp $$f $$dst; \
	done
	@echo "$(words $(UNITS_SRC) $(DATA_SRC)) .lyx-Quelltexte synchronisiert."

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

# Alle uebersetzbaren .lyx-Tests ausserhalb von `make test` (Inventur zu #1004).
# Dauert rund fuenf Minuten und ist deshalb nicht Teil von `make test`.
.PHONY: test-lyx
# Externe Tests: uebersetzen ohne Zugangsdaten pruefen (#1004).
# Ausgefuehrt werden sie nicht — sie brauchen AWS, Cloudflare, Postgres o.ae.
test-external: lyxc
	@echo "=== Externe Tests: Uebersetzbarkeit ==="
	@bash tests/run_external_compile.sh

test-lyx: lyxc
	@bash tests/run_lyx_suite.sh tests/suite-full.txt "Vollsuite"

# Die 268 .lyx-Dateien unter tests/lyx/** mit ihren .expected-Dateien. Der
# Runner dafuer lag seit jeher im Repo, hing aber an keinem Ziel — bemerkt
# wurde das erst, als die Abdeckungspruefung rekursiv suchte (#1112). Bekannt
# rote Eintraege stehen in tests/known-red.txt (#1153); nicht Teil von
# `make test`, weil ein Teil davon Soundkarte oder MySQL braucht.
.PHONY: test-lyx-integration
test-lyx-integration: lyxc
	@bash tests/run_lyx_tests.sh

# Die .sh-Eintraege aus tests/known-red.txt. Sie laufen, ihr Fehlschlag ist
# erwartet und bricht nichts ab — aber wenn einer wieder gruen wird, wird
# DIESES Ziel rot, damit der Eintrag verschwindet statt zu veralten.
.PHONY: test-known-red
test-known-red: lyxc
	@fail=0; n=0; \
	while read -r line; do \
	  line="$${line%%\#*}"; line="$$(printf '%s' "$$line" | sed -e 's/[[:space:]]*$$//' -e 's/[[:space:]]*!flaky$$//')"; \
	  case "$$line" in ''|*.lyx) continue ;; esac; \
	  n=$$((n+1)); \
	  if bash "$$line" >/dev/null 2>&1; then \
	    echo "WIEDER GRUEN $$line — Eintrag aus tests/known-red.txt streichen"; \
	    fail=$$((fail+1)); \
	  else \
	    echo "bekannt rot   $$line"; \
	  fi; \
	done < tests/known-red.txt; \
	echo "known-red (.sh): $$n geprueft, $$fail unerwartet gruen"; \
	test $$fail -eq 0

# LyxOS-Tests aus tests/ (nicht tests/lyxos/ -- dafuer gibt es `test-lyxos`).
# Nur uebersetzen, der erzeugte Code laeuft nicht auf dem Buildhost.
.PHONY: test-lyxos-units
test-lyxos-units: lyxc
	@fail=0; n=0; \
	while read -r t; do \
	  case "$$t" in ''|\#*) continue ;; esac; \
	  n=$$((n+1)); \
	  if ! ./lyxc --std-path=. --target=lyxos tests/$$t.lyx -o /tmp/lyxos_$$t >/dev/null 2>&1; then \
	    echo "FAIL $$t"; fail=$$((fail+1)); \
	  fi; \
	done < tests/suite-lyxos.txt; \
	echo "LyxOS-Suite: $$((n-fail))/$$n uebersetzen"; \
	test $$fail -eq 0
