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

VERSION   := 1.1.10L
VERSION_DATE := 2026-08-26
DEB_NAME  := lyxc-$(VERSION).deb
PKG_DIR   := lyx-compiler
UNITS_DST := $(PKG_DIR)/usr/include/lyx/units/std
DATA_DST  := $(PKG_DIR)/usr/include/lyx/units/data
BIN_DST   := $(PKG_DIR)/usr/local/bin
SHARE_DST := $(PKG_DIR)/usr/share/lyx

UNITS_LYU := $(patsubst std/%.lyx,  $(UNITS_DST)/%.lyu, $(UNITS_SRC))
DATA_LYU  := $(patsubst data/%.lyx, $(DATA_DST)/%.lyu,  $(DATA_SRC))

.PHONY: build bootstrap singularity test test-external test-lyxos test-lyx-integration test-known-red snapshot snapshot-update clean package precompile-units install-bin install-data lic_build_flags keygen sync-units-src deb

# ── Compiler bauen ────────────────────────────────────────────────────────────

# Build-Flag-Datei schreiben (immer vor der Kompilierung)
lic_build_flags:
	@printf 'con LYXC_LICENSE_REQUIRED: int64 := %s;\n' $(LYXC_LICENSE_REQUIRED) > src/lic_build_flags.lyx

# #1170: src/crypto/lic_secret.lyx ist gitignoriert, wird zum Uebersetzen der
# Compilerquelle aber gebraucht. Ein frischer Checkout scheiterte deshalb mit
# vier sema-Fehlern ("undefined function 'lic_getMasterSecret'" und Geschwister),
# und die CI konnte ihre eigene Bootstrap-Pruefung nicht ausfuehren.
#
# Fehlt die Datei, tritt die committete Entwicklungsvorgabe an ihre Stelle. Der
# Hinweis dazu ist Absicht: der Unterschied zwischen Dev- und Release-Bau soll
# im Protokoll stehen und nicht daran haengen, ob jemand eine Datei lokal hat.
# Fehlt auch die Vorgabe, wird das gemeldet statt es den Compiler mit vier
# Folgefehlern quittieren zu lassen.
lic_secret:
	@if [ ! -f src/crypto/lic_secret.lyx ]; then \
		if [ -f src/crypto/lic_secret.dev.lyx ]; then \
			cp src/crypto/lic_secret.dev.lyx src/crypto/lic_secret.lyx; \
			echo "Hinweis: src/crypto/lic_secret.lyx fehlte — Entwicklungsvorgabe eingesetzt"; \
			echo "         (Testvektor-Werte, NICHT fuer ein Release)."; \
			echo "         Echte Werte erzeugen: python3 tools/gen_lic_secret.py"; \
		else \
			echo "FEHLER: src/crypto/lic_secret.lyx fehlt, und die Vorgabe"          >&2; \
			echo "        src/crypto/lic_secret.dev.lyx ist ebenfalls nicht da."     >&2; \
			echo "        Erzeugen mit: python3 tools/gen_lic_secret.py"             >&2; \
			exit 1; \
		fi; \
	fi

# RAM-Limit für Bootstrap-Läufe: verhindert OOM-Kill der Shell bei Endlosschleifen.
ULIMIT_VM := ulimit -v $$(( 8 * 1024 * 1024 )) &&

# Aus Seed-Binary kompilieren (erster Bootstrap-Schritt)
build: lic_build_flags lic_secret
	$(ULIMIT_VM) $(SEED) $(SRC) -o lyxc

# #1726: `bootstrap` haengt von `lyxc` ab, aber es gab keine Regel dieses
# Namens — das Ziel war schlicht die gebaute Binary im Wurzelverzeichnis, und
# die ist git-ignoriert. In einem frischen Checkout oder Worktree endete
# `make bootstrap` deshalb mit "Keine Regel vorhanden, um das Ziel 'lyxc' zu
# erstellen", obwohl der Seed versioniert danebenliegt und genau dafuer da ist.
#
# Die Regel hat BEWUSST keine Voraussetzungen: so laeuft sie nur, wenn die
# Datei fehlt. Mit `lyxc: $(SEED)` wuerde make sie jedes Mal ueberschreiben,
# sobald der Seed neuer ist — also direkt nach jedem Verankern, und der
# gerade gebaute Compiler waere weg.
lyxc:
	@test -f $@ || { echo "  [kein ./lyxc — Seed $(SEED) wird uebernommen]"; cp $(SEED) $@; chmod +x $@; }

# Selbstkompilierung: lyxc kompiliert sich selbst (nimmt den Seed, wenn keins da ist)
bootstrap: lyxc lic_build_flags lic_secret
	$(ULIMIT_VM) ./lyxc $(SRC) -o lyxc.new
	mv lyxc.new lyxc

# Singularitätsprüfung: S3 (Seed→Quelle) == S4 (S3→Quelle)
# Hinweis: Der Seed kompiliert die große Quelle in bis zu 5 Versuchen
# (ASLR-bedingte non-deterministische Crashes bei großem Adressraum).
singularity: lic_build_flags lic_secret
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
	@bash tests/struct_ausrichtung_test.sh
	@bash tests/stdlib_umwandlung_test.sh
	@bash tests/stdlib_z3_test.sh
	@bash tests/cli_schalter_z6_test.sh
	@bash tests/cli_schalter_z13_test.sh
	@bash tests/sema_unitgrenzen_z14_test.sh
	@bash tests/oop_vererbung_test.sh
	@bash tests/bibliotheken_runde3_test.sh
	@bash tests/klassen_runde4_test.sh
	@bash tests/datetime_runde5_test.sh
	@bash tests/ffi_abi_runde6_test.sh
	@bash tests/struct_arrays_runde8_test.sh
	@bash tests/sema_runde9_test.sh
	@bash tests/klassenarray_1646_test.sh
	@bash tests/laute_abbrueche_runde10_test.sh
	@bash tests/krypto_runde11_test.sh
	@bash tests/stille_fehlfunktion_runde12_test.sh
	@bash tests/aufloesung_runde13_test.sh
	@bash tests/stdlib_runde14_test.sh
	@bash tests/vorwaerts_subnormal_runde15_test.sh
	@bash tests/stille_varianten_runde16_test.sh
	@bash tests/classname_test.sh
	@bash tests/win64_pe_test.sh
	@bash tests/doppelte_mitglieder_test.sh
	@bash tests/schluesselwoerter_test.sh
	@bash tests/struct_rueckgabe_test.sh
	@bash tests/rueckgabetyp_test.sh
	@bash tests/override_unitgrenze_test.sh
	@bash tests/sret_argumentgrenze_test.sh
	@bash tests/vmt_struct_rueckgabe_test.sh
	@bash tests/lyxos_runde_test.sh
	@bash tests/lyxos_builtin_ids_test.sh
	@bash tests/lyxos_stdlib_import_test.sh
	@bash tests/ir_importpfad_test.sh
	@bash tests/fnptr_modulvar_test.sh
	@bash tests/builtin_drift_test.sh
	@bash tests/gleitkomma_builtins_test.sh
	@bash tests/blockb_builtins_test.sh
	@bash tests/erreichbarkeit_test.sh
	@bash tests/lyxos_posix_syscalls_test.sh
	@bash tests/lyxos_nummernraum_test.sh
	@bash tests/lyxos_zeit_builtins_test.sh
	@bash tests/con_globals_test.sh
	@bash tests/lyxos_argv_test.sh
	@bash tests/lyxos_caps_geraete_test.sh
	@bash tests/ir_if_kette_test.sh
	@bash tests/iso_verzeichnisse_test.sh
	@bash tests/win64_syscalls_test.sh
	@bash tests/ir_argslots_test.sh
	@bash tests/include_pfade_test.sh
	@bash tests/weiche_schluesselwoerter_test.sh
	@bash tests/profile_schalter_test.sh
	@bash tests/doku_zusagen_test.sh
	@bash tests/capability_legacy_test.sh
	@bash tests/ci_ziele_test.sh
	@bash tests/schreibfehler_test.sh
	@bash tests/svg_ausgabe_test.sh
	@bash tests/stdlib_z20_test.sh
	@bash tests/sprache_z16_test.sh
	@bash tests/codegen_ausdruecke_test.sh
	@bash tests/stdlib_mathe_test.sh
	@bash tests/ir_builtins_test.sh
	@echo "--- riscv: Erzeugnisse ausfuehren, nicht nur uebersetzen (#1740) ---"
	@bash tests/riscv_laufzeit_test.sh
	@echo "--- Klassen auf den IR-Zielen ausfuehren (#1767) ---"
	@bash tests/oop_laufzeit_test.sh
	@echo "--- arm64: Erzeugnisse ausfuehren, nicht nur uebersetzen (#1769) ---"
	@bash tests/arm64_laufzeit_test.sh
	@echo "--- Cortex-M: Abbild starten und ueber Semihosting ausgeben (#1744) ---"
	@bash tests/arm_cm_laufzeit_test.sh
	@echo "--- xtensa: Erzeugnisse ausfuehren (#1786) ---"
	@bash tests/xtensa_laufzeit_test.sh
	@bash tests/compile_unit_codegen_test.sh
	@bash tests/skalierung_z2b_test.sh
	@bash tests/lfd_grammatik_test.sh
	@bash tests/lfd_parser_test.sh
	@bash tests/ref_parameter_test.sh
	@bash tests/log_z4_test.sh
	@bash tests/systeminfo_uuid_z7_test.sh
	@bash tests/regex_z8_test.sh
	@bash tests/rect_color_z9_test.sh
	@bash tests/https_parser_z10_test.sh
	@bash tests/flight_crit_heap_test.sh
	@bash tests/flight_crit_transitiv_test.sh
	@bash tests/f64_typspur_import_test.sh
	@bash tests/sprachluecken_z5_test.sh
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
	@bash tests/frischer_checkout_test.sh
	@bash tests/lyxc_umgebung_test.sh
	@bash tests/struct_param_ref_test.sh
	@bash tests/pruefziffern_test.sh
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
	@echo "--- @stack_limit wird nachgewiesen (12 Pruefungen) ---"
	@bash tests/stack_limit_test.sh
	@echo "OK"
	@echo "--- @wcet wird nachgewiesen (30 Pruefungen) ---"
	@bash tests/wcet_test.sh
	@echo "OK"
	@echo "--- @flight_crit schaltet die FPU-Traps frei (15 Pruefungen) ---"
	@bash tests/flight_crit_test.sh
	@echo "OK"
	@echo "--- @redundant an Globals + --verify-tmr (17 Pruefungen) ---"
	@bash tests/verify_tmr_test.sh
	@echo "OK"
	@echo "--- Typen der binaeren Operatoren + Print (28 Pruefungen) ---"
	@bash tests/binop_types_test.sh
	@echo "OK"
	@echo "--- Map<K,V> als Sprachtyp (14 Pruefungen) ---"
	@bash tests/map_type_test.sh
	@echo "OK"
	@echo "--- panic ist nicht fangbar (10 Pruefungen) ---"
	@bash tests/panic_uncatchable_test.sh
	@echo "OK"
	@echo "--- finally beim vorzeitigen Verlassen des try (12 Pruefungen) ---"
	@bash tests/finally_exit_test.sh
	@echo "OK"
	@echo "--- catch bindet den geworfenen Wert (13 Pruefungen) ---"
	@bash tests/catch_binding_test.sh
	@echo "OK"
	@echo "--- 'self'/'super' als Parametername (12 Pruefungen) ---"
	@bash tests/self_param_test.sh
	@echo "OK"
	@echo "--- Linter meldet lesbar (14 Pruefungen) ---"
	@bash tests/lint_output_test.sh
	@echo "OK"
	@echo "--- Deklarationspruefungen: return, Doppelname (17 Pruefungen) ---"
	@bash tests/decl_checks_test.sh
	@echo "OK"
	@echo "--- Typpruefung bei Zuweisung, Rueckgabe, Argumenten (21 Pruefungen) ---"
	@bash tests/type_check_test.sh
	@echo "OK"
	@echo "--- Meldung bei zyklischem Import (13 Pruefungen) ---"
	@bash tests/import_cycle_message_test.sh
	@echo "OK"
	@echo "--- Interface-Dispatch (15 Pruefungen) ---"
	@bash tests/interface_dispatch_test.sh
	@echo "OK"
	@echo "--- Zuweisung an con wird abgewiesen (16 Pruefungen) ---"
	@bash tests/con_assignment_test.sh
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
	@echo "--- Array-Felder und Laenge (11 Pruefungen) ---"
	@bash tests/array_field_len_test.sh
	@echo "OK"
	@echo "--- Einheitentypen, @if und @energy (18 Pruefungen) ---"
	@bash tests/units_atif_energy_test.sh
	@echo "OK"
	@echo "--- CLI-Pruefung, globale Startwerte, Methodenzeiger (22 Pruefungen) ---"
	@bash tests/cli_globals_methodptr_test.sh
	@echo "OK"
	@echo "--- Capability-Pfade und Typinferenz (10 Pruefungen) ---"
	@bash tests/caps_ffi_inference_test.sh
	@echo "OK"
	@echo "--- Gemischte Arithmetik, try/catch, Build-Vorgabe (12 Pruefungen) ---"
	@bash tests/mixed_arith_trycatch_test.sh
	@echo "OK"
	@echo "--- Schmale Schreibzugriffe und fn-Zeiger-Konvention (12 Pruefungen) ---"
	@bash tests/narrow_store_test.sh
	@echo "OK"
	@echo "--- Array-Deklarationen: leeres Literal, append, mehrdimensional (11 Pruefungen) ---"
	@bash tests/array_decl_test.sh
	@echo "OK"
	@echo "--- Ressourcengrenze um jeden lyxc-Aufruf (5 Pruefungen) ---"
	@bash tests/lyxc_guard_coverage_test.sh
	@echo "OK"
	@echo "--- Enum-Member, doppelte Namen, Escape-Sequenzen (12 Pruefungen) ---"
	@bash tests/enum_escape_test.sh
	@echo "OK"
	@echo "--- stdlib: string, json, pack, result, log (14 Pruefungen) ---"
	@bash tests/stdlib_bundle_test.sh
	@echo "OK"
	@echo "--- stdlib: AES gegen FIPS-197, PQC-Level, Signale, std.fs (13 Pruefungen) ---"
	@bash tests/stdlib_bundle2_test.sh
	@echo "OK"
	@echo "--- Allokator-Pool: Korrektheit und Syscall-Zahl (9 Pruefungen) ---"
	@bash tests/alloc_pool_test.sh
	@echo "OK"
	@echo "--- stdlib: base64, regex, yaml, sha256, Socket-Select (12 Pruefungen) ---"
	@bash tests/stdlib_bundle3_test.sh
	@echo "OK"
	@echo "--- std.base64 gehaertet: Puffergrenze, ungueltige Zeichen, Padding (15 Pruefungen) ---"
	@bash tests/base64_haerte_test.sh
	@echo "OK"
	@echo "--- std.ini gehaertet: Puffergrenze, Maskierung, Freigabe (12 Pruefungen) ---"
	@bash tests/ini_haerte_test.sh
	@echo "OK"
	@echo "--- std.xml/std.html: Wohlgeformtheit, Parsen, Entities, Bilanz (14 Pruefungen) ---"
	@bash tests/xml_html_test.sh
	@echo "OK"
	@echo "--- std.json gehaertet: Rundlauf, Steuerzeichen, Struktur (8 Pruefungen) ---"
	@bash tests/json_haerte_test.sh
	@echo "OK"
	@echo "--- std.datetime/std.io: Locale, Zonenversatz, FloatToStr (9 Pruefungen) ---"
	@bash tests/datetime_float_test.sh
	@echo "OK"
	@echo "--- stdlib rechnet richtig: sort, pgp, math, pack, result, argv (14 Pruefungen) ---"
	@bash tests/stdlib_rechnen_test.sh
	@echo "OK"
	@echo "--- f64-Literale: Bitmuster gegen python (5 Pruefungen) ---"
	@bash tests/f64_literal_test.sh
	@echo "OK"
	@echo "--- Programmende ruft exit_group, nicht exit (7 Pruefungen) ---"
	@bash tests/exit_group_test.sh
	@echo "OK"
	@echo "--- FFI: Gleitkomma-Argumente nach SysV in xmm (7 Pruefungen) ---"
	@bash tests/ffi_float_test.sh
	@echo "OK"
	@echo "--- Vorgabewerte importierter Funktionen (7 Pruefungen) ---"
	@bash tests/import_defaults_test.sh
	@echo "OK"
	@echo "--- Struct als Feld, Wertsemantik, Feld-Array mit Klassen (13 Pruefungen) ---"
	@bash tests/struct_inline_wert_test.sh
	@echo "OK"
	@echo "--- std.math: Festkomma-Skalierung und Raender (14 Pruefungen) ---"
	@bash tests/math_festkomma_test.sh
	@echo "OK"
	@echo "--- f64-Typspur: Vorzeichen, con, Feld-Array, kleine Literale (11 Pruefungen) ---"
	@bash tests/f64_typspur_test.sh
	@echo "OK"
	@echo "--- asm: Operandenbindung und Portbefehle (9 Pruefungen) ---"
	@bash tests/asm_operanden_test.sh
	@echo "OK"
	@echo "--- arm64: Gleitkommavergleich (FCMP-Familie, 8 Pruefungen) ---"
	@bash tests/arm64_fcmp_test.sh
	@echo "OK"
	@echo "--- Diagnose-Schalter: Relokationen, Karte, Optimierstufe (17 Pruefungen) ---"
	@bash tests/diagnose_schalter_test.sh
	@echo "OK"
	@echo "--- defer eines durchlaufenen Rahmens, Zielangabe der IR-Meldung (10 Pruefungen) ---"
	@bash tests/defer_durchlaufener_rahmen_test.sh
	@echo "OK"
	@echo "--- Enum-Werte in con und globalen Startwerten (7 Pruefungen) ---"
	@bash tests/enum_con_test.sh
	@echo "OK"
	@echo "--- Struct-Typ vor seiner Deklaration benutzt (6 Pruefungen) ---"
	@bash tests/struct_vorwaerts_test.sh
	@echo "OK"
	@echo "--- Namensaufloesung: literale IP, /etc/hosts, resolv.conf (3 Pruefungen) ---"
	@bash tests/net_resolver_test.sh
	@echo "OK"
	@echo "--- HTTP-Kopfzeilen einzeln und gezaehlt, HTTPS-Rahmen (2 Pruefungen) ---"
	@bash tests/net_http_kopf_test.sh
	@echo "OK"
	@echo "--- std.db.mysql: Prepared Statements gegen MariaDB (6 Pruefungen) ---"
	@bash tests/db_mysql_prepared_test.sh
	@echo "OK"
	@echo "--- std.db.sqlite: REAL ueber FFI in beide Richtungen (3 Pruefungen) ---"
	@bash tests/db_sqlite_real_test.sh
	@echo "OK"
	@echo "--- std.matrix: Mat3/Mat4/Vec3/Vec4 und ihre Fehlerfaelle (9 Gruppen) ---"
	@bash tests/matrix_test.sh
	@echo "OK"
	@echo "--- std.math: Sinus/Kosinus/Tangens gegen python (4 Pruefungen) ---"
	@bash tests/trig_accuracy_test.sh
	@echo "OK"
	@echo "--- std.io: Printf schreibt nicht mehr in ein String-Literal (5 Pruefungen) ---"
	@bash tests/printf_literal_test.sh
	@echo "OK"
	@echo "--- Archiv-Units: tar-prefix, iso-Verzeichnisse, rar-Uebersprungene, zip-Pfad/Zeit (14 Pruefungen) ---"
	@bash tests/archiv_units_test.sh
	@echo "OK"
	@echo "--- std.time: Kalenderrundlauf 1970-2050 (6 Pruefungen) ---"
	@bash tests/time_civil_test.sh
	@echo "OK"
	@echo "--- std.alloc: malloc_orpanic bricht ab statt zu drehen (7 Pruefungen) ---"
	@bash tests/alloc_orpanic_test.sh
	@echo "OK"
	@echo "--- Import-Namensraum: import X as m, m.Fn() bindet richtig (9 Pruefungen) ---"
	@bash tests/import_namensraum_test.sh
	@echo "OK"
	@echo "--- Builtin-Auswahl: Cast und Argumentzahl (7 Pruefungen) ---"
	@bash tests/builtin_dispatch_test.sh
	@echo "OK"
	@echo "--- Klassen-Lebenszyklus: dispose, new, override (11 Pruefungen) ---"
	@bash tests/class_lifecycle_test.sh
	@echo "OK"
	@echo "--- ebnf.md gegen den Compiler gemessen (12 Pruefungen) ---"
	@bash tests/ebnf_claims_test.sh
	@echo "OK"
	@echo "--- globale Aggregate: Arrays und Structs auf Modulebene (10 Pruefungen) ---"
	@bash tests/global_aggregate_test.sh
	@echo "OK"
	@echo "--- mehrdimensionale Arrays [N][M]T (8 Pruefungen) ---"
	@bash tests/multidim_array_test.sh
	@echo "OK"
	@echo "--- new T[n] mit Laufzeitlaenge (11 Pruefungen) ---"
	@bash tests/dynamic_array_new_test.sh
	@echo "OK"
	@echo "--- Ausnahmeweg: finally reicht weiter, defer laeuft, throw bricht ab (13 Pruefungen) ---"
	@bash tests/exception_unwind_test.sh
	@echo "OK"
	@echo "--- Frontend: Lambda/fn-Typ, Tupel-Muster, benannte Argumente, Pipe (25 Pruefungen) ---"
	@bash tests/frontend_calls_patterns_test.sh
	@echo "OK"
	@echo "--- FFI/Capabilities: link-Pflicht, @cap wirkt, Grant-Modell unbewertet (16 Pruefungen) ---"
	@bash tests/ffi_link_caps_test.sh
	@echo "OK"
	@echo "--- sema-Pruefungen ueber Unit-Grenzen, Methoden, Aliase, Attribute (21 Pruefungen) ---"
	@bash tests/sema_checks_test.sh
	@echo "OK"
	@echo "--- Wert statt Adresse: Feldzugriff, Verkettung, Array-Parameter, FloatToStr (19 Pruefungen) ---"
	@bash tests/value_vs_address_test.sh
	@echo "OK"
	@echo "--- Paketbaum deckt sich mit std/ und uebersetzt (3 Pruefungen) ---"
	@bash tests/packaged_units_sync_test.sh
	@echo "OK"
	@echo "--- Grammatik-Hinweise: Generics, match-Auffangfall, StrNew, free, Closure (11 Pruefungen) ---"
	@bash tests/grammar_hints_test.sh
	@echo "OK"
	@echo "--- Handbuchseite: uebersetzt, deckt --help, mandb indiziert sie (14 Pruefungen) ---"
	@bash tests/manpage_test.sh
	@echo "OK"
	@echo "--- CLI sagt die Wahrheit: stdlib-Pfad, wirksame Schalter, RISC-V (19 Pruefungen) ---"
	@bash tests/cli_truth_test.sh
	@echo "OK"
	@echo "--- Capability-Tor: signal-Pfad, FFI-Schluessel, Groessenparameter, fcntl, TLS (19 Pruefungen) ---"
	@bash tests/capabilities_ffi_test.sh
	@echo "OK"
	@echo "--- Codegen-Werte: uint64-Division, con-Vorwaertsreferenz, Einheitentypen (15 Pruefungen) ---"
	@bash tests/codegen_werte_test.sh
	@echo "OK"
	@echo "--- Backend-Opcodes und VerifyIntegrity: kein stiller Default mehr (18 Pruefungen) ---"
	@bash tests/backend_opcodes_test.sh
	@echo "OK"
	@echo "--- f64-Typspur: globale, Array-Elemente, Felder, Casts (13 Pruefungen) ---"
	@bash tests/f64_typspur_test.sh
	@echo "OK"
	@echo "--- StringBuilder waechst, r-Literal, Methodenrueckgabe (11 Pruefungen) ---"
	@bash tests/stringbuilder_rawstring_test.sh
	@echo "OK"
	@echo "--- Map mit Zeichenketten-Schluesseln: Inhalt statt Adresse (12 Pruefungen) ---"
	@bash tests/map_string_keys_test.sh
	@echo "OK"
	@echo "--- POSIX-Schicht: pthread, fork/exec/wait/kill, Pdf/Svg (14 Pruefungen) ---"
	@bash tests/posix_layer_test.sh
	@echo "OK"
	@echo "--- Zusicherungen in den IR-Backends: Division prueft wieder (13 Pruefungen) ---"
	@bash tests/assert_opcodes_test.sh
	@echo "OK"
	@echo "--- freistehendes Kernel-Ziel: kein Syscall, RDI bleibt unberuehrt (22 Pruefungen) ---"
	@bash tests/kernel_target_test.sh
	@echo "OK"
	@echo "--- jede Unit der Standardbibliothek ist importierbar (dauert einige Minuten) ---"
	@bash tests/std_import_test.sh
	@echo "OK"
	@echo "--- TextMate-Grammatik: Schluesselwoerter und Typen vollstaendig ---"
	@bash tests/syntax/test_grammar.sh
	@echo "OK"
	@echo "--- Generics: Typparameter (15 Pruefungen) ---"
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

	@echo "--- Mathematik-Units: Fuzz gegen Python-Referenzen (7 Einheiten) ---"
	@bash tests/lyx_units_fuzz_test.sh
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

# Fertiges .deb mit Version und Architektur im Namen. Das Skript füllt den
# Paketbaum (std, data, KassenSichV), räumt verwaiste Dateien weg, stempelt
# DEBIAN/control und prüft anschließend, was tatsächlich im Paket liegt.
# `package` (darunter) baut ohne diese Prüfungen und ohne Architektur im Namen.
deb: precompile-units install-data
	@bash tools/make_deb.sh $(DEB_ARCH)

package: sync-units-src precompile-units install-bin install-data
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

# Mitgelieferte Datendateien in den Paketbaum. Derzeit nur share/pci.ids
# (PCI-ID-Datenbank, von std/hardware/pci_ids.lyx zur Laufzeit gelesen).
# Sie wird bewusst NICHT zu einer Lyx-Datenunit uebersetzt: eine generierte
# Unit dieser Groesse bringt lyxc zum Absturz.
install-data:
	@echo "Installiere share/ -> $(SHARE_DST)/"
	@mkdir -p $(SHARE_DST)
	cp share/pci.ids $(SHARE_DST)/pci.ids
	cp share/pci.ids.LICENSE $(SHARE_DST)/pci.ids.LICENSE

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
