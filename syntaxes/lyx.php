<?php
/**
 * GeSHi – Generic Syntax Highlighter
 * Language: Lyx (lyx)
 *
 * Installation:
 *   Datei in das GeSHi-Sprachenverzeichnis kopieren:
 *   <dokuwiki>/lib/plugins/geshi/geshi/lyx.php
 *
 *   In DokuWiki-Seiten dann:
 *   <code lyx>
 *     @dal(A) @critical @wcet(50)
 *     fn autopilot_update(): int64 { return 0; }
 *   </code>
 *
 * Keyword-Gruppen:
 *   1  Kontrollfluss        (blau)
 *   2  Deklarationen / OOP  (dunkelblau)
 *   3  Primitive Typen      (teal)
 *   4  Compiler-Builtins    (violett)
 *   5  Literale / self      (dunkelrot)
 *   6  Aerospace / Safety   (aerospace-orange, DO-178C-spezifische Keywords)
 *
 * Regexp-Gruppen:
 *   0  Safety-Annotationen   @dal @critical @wcet @stack_limit @flight_crit
 *                            @integrity @redundant                (rot/fett)
 *   1  Sonstige Annotationen @energy @big_endian @little_endian
 *                            @description @author @copyright      (violett)
 *   2  DAL-Argument          @dal(A) / @dal(B) …                 (orange, ganzer Ausdruck)
 *   3  Hex-Literale          0xFF  $FF                           (dunkelcyan)
 *   4  Binär-Literale        0b1010  %1010                       (dunkelcyan)
 *   5  Oktal-Literale        0o77  &77                            (dunkelcyan)
 *   6  Float-Literale        3.14  0.5  1000.0                   (dunkelcyan)
 *   7  Enum-Zugriff          Direction::North                    (blauviolett)
 *   8  Funktionsname         (direkt nach "fn")                  (fett blau)
 *   9  Annot.-Parameter      mode:  interval:  (in @integrity)   (mittelgrau)
 */

$language_data = array(
    'LANG_NAME'      => 'Lyx',
    'COMMENT_SINGLE' => array(1 => '//'),
    'COMMENT_MULTI'  => array('/*' => '*/'),
    'COMMENT_REGEXP' => array(),

    // Strings: doppelte Anführungszeichen, Backslash-Escapes
    'QUOTEMARKS'    => array('"'),
    'ESCAPE_CHAR'   => '\\',
    'ESCAPE_REGEXP' => array(
        1 => "/\\\\(n|r|t|\\\\|\\\"|0)/",
    ),

    // =========================================================================
    // KEYWORDS
    // =========================================================================
    'KEYWORDS' => array(

        // -----------------------------------------------------------------
        // Gruppe 1 — Kontrollfluss
        // -----------------------------------------------------------------
        1 => array(
            'if', 'else',
            'while', 'for', 'do', 'repeat',
            'switch', 'case', 'match', 'default',
            'break', 'continue', 'return',
            'try', 'catch', 'throw',
            // Aerospace: bounded while  → while (…) limit(N) { }
            'limit',
        ),

        // -----------------------------------------------------------------
        // Gruppe 2 — Deklarationen, Strukturelemente, OOP
        // -----------------------------------------------------------------
        2 => array(
            'fn', 'var', 'let', 'co', 'con', 'const',
            'pub', 'extern', 'static', 'private', 'protected',
            'unit', 'import',
            'type', 'struct', 'flat', 'packed',
            'class', 'extends', 'abstract', 'virtual', 'override',
            'enum', 'dim', 'utype',
            'new', 'dispose',
            'as', 'in', 'link',
            // Aerospace: Range-Typen und Unit-Typen
            'range', 'wraps',
            // Type-Constraints
            'where', 'value',
            // Packed-Struct Bit-Position:  field: bool at(64);
            'at',
        ),

        // -----------------------------------------------------------------
        // Gruppe 3 — Primitive und Container-Typen
        // -----------------------------------------------------------------
        3 => array(
            'int8', 'int16', 'int32', 'int64',
            'uint8', 'uint16', 'uint32', 'uint64',
            'int', 'isize', 'usize',
            'f32', 'f64',
            'bool', 'void', 'pchar',
            'string', 'array', 'Map', 'Set', 'Array', 'parallel',
        ),

        // -----------------------------------------------------------------
        // Gruppe 4 — Compiler-Builtins
        // -----------------------------------------------------------------
        4 => array(
            // Ausgabe
            'PrintStr', 'PrintInt', 'PrintFloat',
            // Prozess
            'exit', 'panic', 'assert', 'check',
            // Zufall
            'Random', 'RandomSeed',
            // String-Builtins
            'StrNew', 'StrFree', 'StrLen', 'StrCharAt', 'StrSetChar',
            'StrAppend', 'StrAppendStr', 'StrConcat', 'StrCopy', 'StrSub',
            'StrFindChar', 'StrStartsWith', 'StrEndsWith', 'StrEquals',
            'IntToStr', 'StrFromInt', 'int_to_str', 'FileGetSize',
            // HashMap-Builtins
            'HashNew', 'HashSet', 'HashGet', 'HashHas',
            // Array-Builtins
            'push', 'pop', 'free', 'len',
            // Kommandozeile
            'GetArgC', 'GetArgV', 'ArgvGet',
            // Mathematik
            'sqrt', 'abs',
            // Aerospace: TMR-Integritätsprüfung
            'VerifyIntegrity',
            // Speicher (peek/poke, Low-Level-Zugriff)
            'peek8', 'peek16', 'peek32', 'peek64', 'peekf64',
            'poke8', 'poke16', 'poke32', 'poke64', 'pokef64',
            // Speicherverwaltung
            'mmap', 'munmap',
            // Datei-Syscalls
            'open', 'read', 'write', 'close',
        ),

        // -----------------------------------------------------------------
        // Gruppe 5 — Literalwerte und spezielle Bezeichner
        // -----------------------------------------------------------------
        5 => array(
            'true', 'false', 'null',
            'self', 'Self', 'super',
        ),

        // -----------------------------------------------------------------
        // Gruppe 6 — Aerospace / DO-178C Safety-Schlüsselwörter
        //
        // Sind als Bezeichner in bestimmten Annotation-Kontexten gültig,
        // werden aber hier global hervorgehoben, da sie ausschließlich im
        // Rahmen von @integrity(...) auftreten und dort hochrelevant sind.
        // -----------------------------------------------------------------
        6 => array(
            // @integrity(mode: ...) Werte
            'software_lockstep',
            'scrubbed',
            'hardware_ecc',
            // Innerhalb von @integrity(mode: ..., interval: ...)
            // und @dal(...) kommen "mode" und "interval" als benannte
            // Parameter vor – sie sind als Schlüsselwörter zu kurz,
            // werden stattdessen per Regexp (Gruppe 9) erfasst.
        ),
    ),

    // =========================================================================
    // REGULÄRE AUSDRÜCKE
    // =========================================================================
    'REGEXPS' => array(

        // -----------------------------------------------------------------
        // Regexp 0 — Safety-kritische Annotationen  (rot/fett)
        //
        //   DO-178C Compliance:  @dal   @critical   @wcet   @stack_limit
        //   Laufzeit-Redundanz:  @integrity   @redundant
        //   FP-Deterministik:    @flight_crit
        //
        //   Diese Annotationen kennzeichnen sicherheitskritische Code-
        //   Stellen und werden bewusst in einer auffälligen Signalfarbe
        //   (Warnorange) dargestellt.
        // -----------------------------------------------------------------
        0 => array(
            'PATTERN'   => '/@(?:dal|critical|wcet|stack_limit|integrity|redundant|flight_crit)\b/',
            'MODIFIERS' => '',
            'STYLER'    => 'color: #cc4400; font-weight: bold;',
            'AFTER'     => '',
            'BEFORE'    => '',
        ),

        // -----------------------------------------------------------------
        // Regexp 1 — Sonstige / informative Annotationen  (violett)
        //
        //   Energie-Optimierung:  @energy
        //   Endianness:           @big_endian  @little_endian
        //   Metadaten:            @description  @author  @copyright
        // -----------------------------------------------------------------
        1 => array(
            'PATTERN'   => '/@(?:energy|big_endian|little_endian|description|author|copyright)\b/',
            'MODIFIERS' => '',
            'STYLER'    => 'color: #8833aa;',
            'AFTER'     => '',
            'BEFORE'    => '',
        ),

        // -----------------------------------------------------------------
        // Regexp 2 — @dal mit DAL-Level-Argument: @dal(A)  @dal(B) …
        //
        //   Der gesamte Ausdruck wird als zusammengehöriges Token
        //   hervorgehoben.  DAL A ist das höchste Sicherheitslevel
        //   (DO-178C), DAL D das niedrigste.
        // -----------------------------------------------------------------
        2 => array(
            'PATTERN'   => '/@dal\s*\(\s*[ABCD]\s*\)/',
            'MODIFIERS' => '',
            'STYLER'    => 'color: #cc4400; font-weight: bold; text-decoration: underline;',
            'AFTER'     => '',
            'BEFORE'    => '',
        ),

        // -----------------------------------------------------------------
        // Regexp 3 — Hex-Literale  0xFF  $FF
        // -----------------------------------------------------------------
        3 => array(
            'PATTERN'   => '/\b(?:0[xX][0-9a-fA-F][0-9a-fA-F_]*)|\$[0-9a-fA-F][0-9a-fA-F_]*/',
            'MODIFIERS' => '',
            'STYLER'    => 'color: #007090;',
            'AFTER'     => '',
            'BEFORE'    => '',
        ),

        // -----------------------------------------------------------------
        // Regexp 4 — Binär-Literale  0b1010  %1010
        // -----------------------------------------------------------------
        4 => array(
            'PATTERN'   => '/\b0[bB][01][01_]*|%[01][01_]*/',
            'MODIFIERS' => '',
            'STYLER'    => 'color: #007090;',
            'AFTER'     => '',
            'BEFORE'    => '',
        ),

        // -----------------------------------------------------------------
        // Regexp 5 — Oktal-Literale  0o77  &77
        // -----------------------------------------------------------------
        5 => array(
            'PATTERN'   => '/\b0[oO][0-7][0-7_]*|&[0-7][0-7_]*/',
            'MODIFIERS' => '',
            'STYLER'    => 'color: #007090;',
            'AFTER'     => '',
            'BEFORE'    => '',
        ),

        // -----------------------------------------------------------------
        // Regexp 6 — Float-Literale  3.14  1000.0  0.277778
        // -----------------------------------------------------------------
        6 => array(
            'PATTERN'   => '/\b[0-9]+\.[0-9]+\b/',
            'MODIFIERS' => '',
            'STYLER'    => 'color: #007090;',
            'AFTER'     => '',
            'BEFORE'    => '',
        ),

        // -----------------------------------------------------------------
        // Regexp 7 — Enum-/Namespace-Zugriff  Direction::North
        // -----------------------------------------------------------------
        7 => array(
            'PATTERN'   => '/\b[A-Za-z_][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*/',
            'MODIFIERS' => '',
            'STYLER'    => 'color: #4040a0;',
            'AFTER'     => '',
            'BEFORE'    => '',
        ),

        // -----------------------------------------------------------------
        // Regexp 8 — Funktionsname (direkt hinter dem "fn"-Keyword)
        // -----------------------------------------------------------------
        8 => array(
            'PATTERN'   => '/(?<=\bfn\s{1,16})[A-Za-z_][A-Za-z0-9_]*/',
            'MODIFIERS' => '',
            'STYLER'    => 'color: #0055aa; font-weight: bold;',
            'AFTER'     => '',
            'BEFORE'    => '',
        ),

        // -----------------------------------------------------------------
        // Regexp 9 — Annotations-Parameter  mode:  interval:
        //
        //   Erscheinen innerhalb von @integrity(...) und heben die
        //   benannten Parameter von den Werten ab.
        //   Nur diese beiden Namen werden erfasst, um False-Positives
        //   (z.B. Struct-Felder namens "mode") zu minimieren.
        // -----------------------------------------------------------------
        9 => array(
            'PATTERN'   => '/\b(?:mode|interval)(?=\s*:)/',
            'MODIFIERS' => '',
            'STYLER'    => 'color: #666600; font-style: italic;',
            'AFTER'     => '',
            'BEFORE'    => '',
        ),
    ),

    // =========================================================================
    // SYMBOLE / OPERATOREN
    // =========================================================================
    'SYMBOLS' => array(
        // Zusammengesetzte Operatoren (zuerst, damit GeSHi sie bevorzugt)
        ':=', '==', '!=', '<=', '>=',
        '&&', '||',
        '|>', '=>', '??', '?.', '..', '...', '::',
        '<<', '>>', '|~',
        '++', '--',
        // Einfache Operatoren
        '+', '-', '*', '/', '%',
        '<', '>', '!', '&', '|', '^', '~',
        // Interpunktion
        '(', ')', '{', '}', '[', ']',
        ':', ',', ';', '.', '@', '?',
    ),

    // =========================================================================
    // CASE SENSITIVITY
    // =========================================================================
    'CASE_SENSITIVE' => array(
        GESHI_COMMENTS => false,
        1 => true,   // Kontrollfluss
        2 => true,   // Deklarationen
        3 => true,   // Typen
        4 => true,   // Builtins
        5 => true,   // Literale / self
        6 => true,   // Aerospace Safety-Wörter
    ),

    // =========================================================================
    // STYLES
    // =========================================================================
    'STYLES' => array(
        'KEYWORDS' => array(
            1 => 'color: #0000cc; font-weight: bold;',
                 // Kontrollfluss         → blau
            2 => 'color: #000099; font-weight: bold;',
                 // Deklarationen         → dunkelblau
            3 => 'color: #006666; font-weight: bold;',
                 // Typen                 → teal
            4 => 'color: #6644cc; font-weight: bold;',
                 // Builtins              → violett
            5 => 'color: #880000; font-weight: bold;',
                 // true/false/null/self  → dunkelrot
            6 => 'color: #884400; font-weight: bold; background-color: #fff8f0;',
                 // Aerospace Safety      → warnorange, leicht hinterlegter Hintergrund
                 //   software_lockstep / scrubbed / hardware_ecc
        ),
        'COMMENTS' => array(
            1       => 'color: #888888; font-style: italic;',
            'MULTI' => 'color: #888888; font-style: italic;',
        ),
        'ESCAPE_CHAR' => array(
            0 => 'color: #cc4400; font-weight: bold;',
            1 => 'color: #cc4400; font-weight: bold;',
        ),
        'BRACKETS' => array(
            0 => 'color: #444444;',
        ),
        'STRINGS' => array(
            0 => 'color: #bb0000;',
        ),
        'NUMBERS' => array(
            0 => 'color: #007090;',
        ),
        'METHODS' => array(
            0 => 'color: #004488;',
        ),
        'SYMBOLS' => array(
            0 => 'color: #555555;',
        ),
        'REGEXPS' => array(
            0 => 'color: #cc4400; font-weight: bold;',
                 // Safety-Annotationen   → Warnorange
            1 => 'color: #8833aa;',
                 // Sonstige Annotationen → violett
            2 => 'color: #cc4400; font-weight: bold; text-decoration: underline;',
                 // @dal(A/B/C/D)         → unterstrichen orange
            3 => 'color: #007090;',
                 // Hex
            4 => 'color: #007090;',
                 // Binär
            5 => 'color: #007090;',
                 // Oktal
            6 => 'color: #007090;',
                 // Float
            7 => 'color: #4040a0;',
                 // Enum::Member
            8 => 'color: #0055aa; font-weight: bold;',
                 // fn Name
            9 => 'color: #666600; font-style: italic;',
                 // mode:  interval:
        ),
        'SCRIPT' => array(),
    ),

    // =========================================================================
    // WEITERE EINSTELLUNGEN
    // =========================================================================
    'URLS' => array(
        1 => '', 2 => '', 3 => '', 4 => '', 5 => '', 6 => '',
    ),

    'OOLANG'              => false,
    'OBJECT_SPLITTERS'    => array(),
    'STRICT_MODE_APPLIES' => GESHI_NEVER,
    'SCRIPT_DELIMITERS'   => array(),
    'HIGHLIGHT_STRICT_BLOCK' => array(),
    'TAB_WIDTH'           => 4,

    'PARSER_CONTROL' => array(
        'KEYWORDS' => array(
            'DISALLOWED_BEFORE' => '(?<![A-Za-z0-9_])',
            'DISALLOWED_AFTER'  => '(?![A-Za-z0-9_])',
        ),
    ),
);
