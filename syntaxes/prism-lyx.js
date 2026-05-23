/**
 * Prism.js – Sprachdefinition für Lyx
 *
 * Lyx ist eine kompilierte Systemsprache (Linux x86_64 ELF64) mit
 * Aerospace/DO-178C-Sicherheitsannotationen.
 *
 * Installation (codeprism-Plugin):
 *   Datei kopieren nach:
 *   /var/www/doc/lib/plugins/codeprism/prism/components/prism-lyx.js
 *
 *   Danach DokuWiki-Cache leeren:  Admin → Cache löschen
 *
 * Verwendung in DokuWiki-Seiten:
 *   <code lyx>
 *     @dal(A) @critical @wcet(50)
 *     fn autopilot_update(dt: f64): int64 { return 0; }
 *   </code>
 *
 * Token-Klassen → Prism-Alias:
 *   Safety-Annotationen        → important   (rot/fett)
 *   Informative Annotationen   → regex        (violett)
 *   Kontrollfluss-Keywords     → keyword      (blau)
 *   Deklarationen              → keyword      (blau)
 *   Primitive Typen            → class-name   (teal)
 *   Compiler-Builtins          → builtin      (violett)
 *   true/false/null/self       → boolean      (dunkelrot)
 *   Aerospace Safety-Werte     → important    (rot/fett)
 *   Zahlen                     → number       (cyan)
 *   Strings                    → string       (rot)
 *   Kommentare                 → comment      (grau/kursiv)
 */
Prism.languages.lyx = {

    /* ------------------------------------------------------------------ */
    /* Kommentare                                                           */
    /* ------------------------------------------------------------------ */
    'comment': [
        { pattern: /\/\*[\s\S]*?\*\//, greedy: true },
        { pattern: /\/\/.*/, greedy: true }
    ],

    /* ------------------------------------------------------------------ */
    /* Strings  "..."  mit Escape-Sequenzen                                */
    /* ------------------------------------------------------------------ */
    'string': {
        pattern: /"(?:\\[\s\S]|[^"\\])*"/,
        greedy: true,
        inside: {
            'escape': /\\[nrt\\"0]/
        }
    },

    /* ------------------------------------------------------------------ */
    /* Safety-Annotationen  (DO-178C / Aerospace)                          */
    /* ------------------------------------------------------------------ */

    /* @dal(A)  @dal(B)  @dal(C)  @dal(D)  – mit DAL-Level-Argument       */
    'dal-expr': {
        pattern: /@dal\s*\(\s*[ABCD]\s*\)/,
        alias: 'important'
    },

    /* Bare Safety-Annotationen ohne Argument-Parsing                      */
    'safety-annotation': {
        pattern: /@(?:dal|critical|wcet|stack_limit|integrity|redundant|flight_crit)\b/,
        alias: 'important'
    },

    /* Informative / Metadaten-Annotationen                                */
    'meta-annotation': {
        pattern: /@(?:energy|big_endian|little_endian|description|author|copyright)\b/,
        alias: 'regex'
    },

    /* ------------------------------------------------------------------ */
    /* Zahlenliterale                                                       */
    /* ------------------------------------------------------------------ */
    'number': [
        { pattern: /\b0[xX][0-9a-fA-F][0-9a-fA-F_]*\b/ },   /* 0xFF   */
        { pattern: /\$[0-9a-fA-F][0-9a-fA-F_]*\b/       },   /* $FF    */
        { pattern: /\b0[bB][01][01_]*\b/                 },   /* 0b1010 */
        { pattern: /%[01][01_]*\b/                        },   /* %1010  */
        { pattern: /\b0[oO][0-7][0-7_]*\b/               },   /* 0o77   */
        { pattern: /&[0-7][0-7_]*\b/                      },   /* &77    */
        { pattern: /\b\d+\.\d+\b/                         },   /* 3.14   */
        { pattern: /\b\d+\b/                              }
    ],

    /* ------------------------------------------------------------------ */
    /* Funktionsname direkt hinter dem "fn"-Keyword                        */
    /* ------------------------------------------------------------------ */
    'function-def': {
        pattern: /(\bfn\s+)[A-Za-z_]\w*/,
        lookbehind: true,
        alias: 'function'
    },

    /* ------------------------------------------------------------------ */
    /* Enum- / Namespace-Zugriff   Direction::North                        */
    /* ------------------------------------------------------------------ */
    'namespace-access': {
        pattern: /\b[A-Za-z_]\w*::[A-Za-z_]\w*/,
        alias: 'class-name'
    },

    /* ------------------------------------------------------------------ */
    /* Aerospace Safety-Werte  (Argumente von @integrity(mode: ...))       */
    /* ------------------------------------------------------------------ */
    'safety-value': {
        pattern: /\b(?:software_lockstep|scrubbed|hardware_ecc)\b/,
        alias: 'important'
    },

    /* ------------------------------------------------------------------ */
    /* Annotations-Parameter   mode:   interval:                           */
    /* ------------------------------------------------------------------ */
    'annotation-param': {
        pattern: /\b(?:mode|interval)(?=\s*:)/,
        alias: 'attr-name'
    },

    /* ------------------------------------------------------------------ */
    /* Kontrollfluss-Keywords                                               */
    /* ------------------------------------------------------------------ */
    'keyword': /\b(?:if|else|while|for|do|repeat|switch|case|match|default|break|continue|return|try|catch|throw|limit)\b/,

    /* ------------------------------------------------------------------ */
    /* Deklarations-Keywords  (OOP, Module, Typen, Speicher)               */
    /* ------------------------------------------------------------------ */
    'declaration': {
        pattern: /\b(?:fn|var|let|co|con|const|pub|extern|static|private|protected|unit|import|type|struct|flat|packed|class|extends|abstract|virtual|override|enum|dim|utype|new|dispose|as|in|link|range|wraps|where|value|at)\b/,
        alias: 'keyword'
    },

    /* ------------------------------------------------------------------ */
    /* Primitive und Container-Typen                                        */
    /* ------------------------------------------------------------------ */
    'class-name': /\b(?:int8|int16|int32|int64|uint8|uint16|uint32|uint64|int|isize|usize|f32|f64|bool|void|pchar|string|array|Map|Set|Array|parallel)\b/,

    /* ------------------------------------------------------------------ */
    /* Compiler-Builtins                                                    */
    /* ------------------------------------------------------------------ */
    'builtin': {
        pattern: /\b(?:PrintStr|PrintInt|PrintFloat|exit|panic|assert|check|Random|RandomSeed|StrNew|StrFree|StrLen|StrCharAt|StrSetChar|StrAppend|StrAppendStr|StrConcat|StrCopy|StrSub|StrFindChar|StrStartsWith|StrEndsWith|StrEquals|IntToStr|StrFromInt|int_to_str|FileGetSize|HashNew|HashSet|HashGet|HashHas|push|pop|free|len|GetArgC|GetArgV|ArgvGet|sqrt|abs|VerifyIntegrity|peek8|peek16|peek32|peek64|peekf64|poke8|poke16|poke32|poke64|pokef64|mmap|munmap|open|read|write|close)\b/,
        alias: 'builtin'
    },

    /* ------------------------------------------------------------------ */
    /* Literalwerte und Selbstreferenzen                                   */
    /* ------------------------------------------------------------------ */
    'boolean': /\b(?:true|false|null|self|Self|super)\b/,

    /* ------------------------------------------------------------------ */
    /* Operatoren  (mehrzeichige zuerst)                                   */
    /* ------------------------------------------------------------------ */
    'operator': /:=|==|!=|<=|>=|&&|\|\||\|>|=>|\?\?|\?\.|\.\.\.|\.\.?|<<|>>|\|~|\+\+|--|[-+*\/%<>!&|^~?=]/,

    /* ------------------------------------------------------------------ */
    /* Interpunktion                                                        */
    /* ------------------------------------------------------------------ */
    'punctuation': /[{}[\]();,.:@]/
};
