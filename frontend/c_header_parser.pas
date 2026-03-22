{$mode objfpc}{$H+}
unit c_header_parser;

{
  Minimal C header parser for Lyx C FFI.

  Parses a subset of C99 headers to extract:
  - Function prototypes
  - typedef struct X X; (opaque type aliases)
  - #define numeric constants

  Does NOT follow #include directives.
  Preprocessor conditionals are handled by tracking depth only (no evaluation).
}

interface

uses
  SysUtils, Classes;

type
  TCHeaderParam = record
    Name: string;     // parameter name (may be empty for unnamed params)
    CType: string;    // raw C type string (e.g. "const char *")
  end;
  TCHeaderParamArray = array of TCHeaderParam;

  TCFunctionDecl = record
    Name: string;
    ReturnType: string;    // raw C return type
    Params: TCHeaderParamArray;
    IsVariadic: Boolean;
    IsStatic: Boolean;     // static inline functions — skip
  end;
  TCFunctionDeclArray = array of TCFunctionDecl;

  TCDefine = record
    Name: string;
    Value: Int64;
    IsNumeric: Boolean;
  end;
  TCDefineArray = array of TCDefine;

  TCHeaderParseResult = record
    Functions: TCFunctionDeclArray;
    Defines: TCDefineArray;
    OpaqueTypes: TStringList;  // names of typedef'd opaque structs
  end;

  TCHeaderParser = class
  private
    FText: string;
    FPos: Integer;
    FLen: Integer;
    FErrors: TStringList;

    function Peek: Char;
    function PeekAt(offset: Integer): Char;
    procedure Advance;
    function AtEnd: Boolean;

    procedure SkipWhitespace;
    procedure SkipLineComment;
    procedure SkipBlockComment;
    procedure SkipWhitespaceAndComments;
    procedure SkipPreprocessorLine;
    function  ReadIdent: string;

    // Parse a full type+declarator combo like "const char *name" or "int (*)(void)"
    // Returns the base type and sets outName to the identifier found (if any)
    function ParseTypeAndName(out outName: string): string;
    function ParseParamList(out isVariadic: Boolean): TCHeaderParamArray;

    // Skip balanced {...}
    procedure SkipBraces;
    // Skip balanced (...)
    procedure SkipParens;

    // Attempt to parse a top-level declaration starting at current position.
    // Returns true if something was consumed, false if we should skip forward.
    function ParseDecl(var res: TCHeaderParseResult): Boolean;

  public
    constructor Create;
    destructor Destroy; override;

    function ParseFile(const filename: string): TCHeaderParseResult;
    function ParseString(const src: string): TCHeaderParseResult;

    property Errors: TStringList read FErrors;
  end;

// Map a raw C type string to a Lyx type name
function MapCTypeToLyx(const cType: string): string;

implementation

{ ── helpers ──────────────────────────────────────────────────────────────── }

function IsAlpha(c: Char): Boolean; inline;
begin
  Result := (c in ['a'..'z', 'A'..'Z', '_']);
end;

function IsAlNum(c: Char): Boolean; inline;
begin
  Result := (c in ['a'..'z', 'A'..'Z', '0'..'9', '_']);
end;

function IsDigit(c: Char): Boolean; inline;
begin
  Result := (c in ['0'..'9']);
end;

function Trim(const s: string): string;
var
  i, j: Integer;
begin
  i := 1;
  j := Length(s);
  while (i <= j) and (s[i] in [' ', #9, #10, #13]) do Inc(i);
  while (j >= i) and (s[j] in [' ', #9, #10, #13]) do Dec(j);
  Result := Copy(s, i, j - i + 1);
end;

{ ── TCHeaderParser ────────────────────────────────────────────────────────── }

constructor TCHeaderParser.Create;
begin
  inherited Create;
  FErrors := TStringList.Create;
end;

destructor TCHeaderParser.Destroy;
begin
  FErrors.Free;
  inherited Destroy;
end;

function TCHeaderParser.Peek: Char;
begin
  if FPos <= FLen then
    Result := FText[FPos]
  else
    Result := #0;
end;

function TCHeaderParser.PeekAt(offset: Integer): Char;
begin
  if (FPos + offset) <= FLen then
    Result := FText[FPos + offset]
  else
    Result := #0;
end;

procedure TCHeaderParser.Advance;
begin
  if FPos <= FLen then Inc(FPos);
end;

function TCHeaderParser.AtEnd: Boolean;
begin
  Result := FPos > FLen;
end;

procedure TCHeaderParser.SkipWhitespace;
begin
  while (not AtEnd) and (Peek in [' ', #9, #10, #13]) do
    Advance;
end;

procedure TCHeaderParser.SkipLineComment;
begin
  // consume until end of line
  while (not AtEnd) and (Peek <> #10) do Advance;
end;

procedure TCHeaderParser.SkipBlockComment;
begin
  // skip past */
  Advance; Advance; // skip /*
  while not AtEnd do
  begin
    if (Peek = '*') and (PeekAt(1) = '/') then
    begin
      Advance; Advance;
      Exit;
    end;
    Advance;
  end;
end;

procedure TCHeaderParser.SkipPreprocessorLine;
begin
  // Skip the rest of the line, handling line continuations with backslash
  while not AtEnd do
  begin
    if Peek = '\' then
    begin
      Advance;
      if Peek = #10 then Advance  // line continuation
      else if Peek = #13 then begin Advance; if Peek = #10 then Advance; end;
    end
    else if Peek = #10 then
    begin
      Advance; Exit;
    end
    else if Peek = #13 then
    begin
      Advance; if Peek = #10 then Advance; Exit;
    end
    else
      Advance;
  end;
end;

function TCHeaderParser.ReadIdent: string;
var
  start: Integer;
begin
  start := FPos;
  while (not AtEnd) and IsAlNum(Peek) do Advance;
  Result := Copy(FText, start, FPos - start);
end;

procedure TCHeaderParser.SkipBraces;
var
  depth: Integer;
begin
  depth := 0;
  while not AtEnd do
  begin
    if Peek = '{' then Inc(depth)
    else if Peek = '}' then
    begin
      Dec(depth);
      if depth = 0 then begin Advance; Exit; end;
    end;
    Advance;
  end;
end;

procedure TCHeaderParser.SkipParens;
var
  depth: Integer;
begin
  depth := 0;
  while not AtEnd do
  begin
    if Peek = '(' then Inc(depth)
    else if Peek = ')' then
    begin
      Dec(depth);
      if depth = 0 then begin Advance; Exit; end;
    end;
    Advance;
  end;
end;

procedure TCHeaderParser.SkipWhitespaceAndComments;
begin
  while not AtEnd do
  begin
    if Peek in [' ', #9, #10, #13] then
      SkipWhitespace
    else if (Peek = '/') and (PeekAt(1) = '/') then
      SkipLineComment
    else if (Peek = '/') and (PeekAt(1) = '*') then
      SkipBlockComment
    else
      Break;
  end;
end;

{ Read a C type+name combination.
  Handles: const, volatile, unsigned, signed, struct, pointer stars, arrays.
  Returns the type string; sets outName to the declared identifier (if any). }
function TCHeaderParser.ParseTypeAndName(out outName: string): string;
var
  typeParts: TStringList;
  tok: string;
  starCount: Integer;
  i: Integer;
  s: string;
begin
  outName := '';
  typeParts := TStringList.Create;
  try
    // Collect type keywords and identifier tokens until we hit , ) ; { =
    while not AtEnd do
    begin
      SkipWhitespaceAndComments;
      if AtEnd then Break;

      // Pointer stars
      if Peek = '*' then
      begin
        Advance;
        typeParts.Add('*');
        Continue;
      end;

      // Function pointer: int (*funcname)(params) - treat as void*
      if Peek = '(' then
      begin
        // Could be (*)(...) function pointer - just treat as void*
        SkipParens;
        SkipWhitespaceAndComments;
        if Peek = '(' then SkipParens; // skip parameter list too
        outName := '';
        typeParts.Clear;
        typeParts.Add('void*');
        Break;
      end;

      // Array brackets — treat as pointer
      if Peek = '[' then
      begin
        while not AtEnd and (Peek <> ']') do Advance;
        if not AtEnd then Advance; // skip ]
        typeParts.Add('*');
        Continue;
      end;

      // Stop tokens
      if Peek in [',', ')', ';', '{', '='] then Break;

      // Identifier
      if IsAlpha(Peek) then
      begin
        tok := ReadIdent;
        // Skip qualifiers that don't affect the type
        if (tok = 'const') or (tok = 'volatile') or (tok = 'restrict') or
           (tok = '__restrict') or (tok = '__const') or (tok = 'register') or
           (tok = 'extern') or (tok = 'inline') or (tok = '__inline') or
           (tok = '__inline__') or (tok = '__attribute__') then
        begin
          // Skip __attribute__((..))
          if tok = '__attribute__' then
          begin
            SkipWhitespaceAndComments;
            if Peek = '(' then SkipParens;
            SkipWhitespaceAndComments;
            if Peek = '(' then SkipParens;
          end;
          Continue;
        end;
        // Type-only keywords: struct/union/enum — skip the tag name
        if (tok = 'struct') or (tok = 'union') or (tok = 'enum') then
        begin
          typeParts.Add(tok);
          SkipWhitespaceAndComments;
          if IsAlpha(Peek) then
          begin
            typeParts.Add(ReadIdent);
          end;
          Continue;
        end;
        // Type keywords
        if (tok = 'void') or (tok = 'int') or (tok = 'char') or
           (tok = 'short') or (tok = 'long') or (tok = 'float') or
           (tok = 'double') or (tok = 'unsigned') or (tok = 'signed') or
           (tok = 'bool') or (tok = '_Bool') or (tok = 'size_t') or
           (tok = 'ssize_t') or (tok = 'ptrdiff_t') or (tok = 'intptr_t') or
           (tok = 'uintptr_t') or
           // stdint.h types
           (tok = 'int8_t') or (tok = 'int16_t') or (tok = 'int32_t') or
           (tok = 'int64_t') or (tok = 'uint8_t') or (tok = 'uint16_t') or
           (tok = 'uint32_t') or (tok = 'uint64_t') or
           (tok = 'int_least8_t') or (tok = 'int_least16_t') or
           (tok = 'int_least32_t') or (tok = 'int_least64_t') or
           (tok = 'uint_least8_t') or (tok = 'uint_least16_t') or
           (tok = 'uint_least32_t') or (tok = 'uint_least64_t') then
        begin
          typeParts.Add(tok);
          Continue;
        end;
        // Otherwise: could be a typedef'd type name or the parameter name
        // Heuristic: if next non-whitespace is , ) ; or * we check context
        // If typeParts is empty so far, this is probably the type
        // If typeParts is non-empty, this is probably the name
        SkipWhitespaceAndComments;
        if typeParts.Count = 0 then
          typeParts.Add(tok)  // first thing: it's the type
        else if (Peek in [',', ')', ';', '[', '(']) or AtEnd then
        begin
          outName := tok;      // followed by param list or terminator — it's the name
          Break;               // stop parsing — don't let '(' handler clear it
        end
        else
          typeParts.Add(tok);  // another type token (e.g. "unsigned long")
        Continue;
      end;
      Break;
    end;

    // Build type string from parts
    s := '';
    starCount := 0;
    for i := 0 to typeParts.Count - 1 do
    begin
      if typeParts[i] = '*' then
        Inc(starCount)
      else
      begin
        if s <> '' then s := s + ' ';
        s := s + typeParts[i];
      end;
    end;
    if starCount > 0 then
      s := s + StringOfChar('*', starCount);
    Result := Trim(s);
  finally
    typeParts.Free;
  end;
end;

function TCHeaderParser.ParseParamList(out isVariadic: Boolean): TCHeaderParamArray;
var
  params: TCHeaderParamArray;
  paramCount: Integer;
  paramName: string;
  paramType: string;
begin
  isVariadic := False;
  paramCount := 0;
  SetLength(params, 0);

  // skip '('
  if Peek = '(' then Advance else Exit(nil);

  SkipWhitespaceAndComments;

  // empty param list or void
  if Peek = ')' then begin Advance; Exit(nil); end;

  while not AtEnd do
  begin
    SkipWhitespaceAndComments;
    if Peek = ')' then begin Advance; Break; end;

    // Variadic
    if (Peek = '.') and (PeekAt(1) = '.') and (PeekAt(2) = '.') then
    begin
      isVariadic := True;
      Advance; Advance; Advance;
      SkipWhitespaceAndComments;
      if Peek = ')' then Advance;
      Break;
    end;

    // Parse "type name"
    paramName := '';
    paramType := ParseTypeAndName(paramName);

    // Skip void-only param list: void
    if (paramType = 'void') and (paramName = '') then
    begin
      SkipWhitespaceAndComments;
      if Peek = ')' then begin Advance; Break; end;
      Continue;
    end;

    if paramType <> '' then
    begin
      Inc(paramCount);
      SetLength(params, paramCount);
      params[paramCount - 1].CType := paramType;
      params[paramCount - 1].Name  := paramName;
    end;

    SkipWhitespaceAndComments;
    if Peek = ',' then begin Advance; Continue; end;
    if Peek = ')' then begin Advance; Break; end;
    Break; // unexpected
  end;

  Result := params;
end;

function TCHeaderParser.ParseDecl(var res: TCHeaderParseResult): Boolean;
var
  tok: string;
  savedPos: Integer;
  fnDecl: TCFunctionDecl;
  paramName: string;
  retType: string;
  fnName: string;
  isVariadic: Boolean;
  defName: string;
  defVal: Int64;
  numStr: string;
  isNeg: Boolean;
  alreadyExists: Boolean;
  di: Integer;
begin
  Result := False;
  SkipWhitespaceAndComments;
  if AtEnd then Exit;

  // Preprocessor directive
  if Peek = '#' then
  begin
    Advance;
    SkipWhitespace; // only spaces, not newlines
    while (not AtEnd) and (Peek in [' ', #9]) do Advance;
    tok := ReadIdent;
    if tok = 'define' then
    begin
      // Try to parse: #define NAME number
      while (not AtEnd) and (Peek in [' ', #9]) do Advance;
      defName := ReadIdent;
      while (not AtEnd) and (Peek in [' ', #9]) do Advance;
      if not AtEnd and (Peek = '(') then
      begin
        // Function-like macro — skip
        SkipPreprocessorLine;
      end
      else
      begin
        // Simple constant
        isNeg := False;
        if Peek = '-' then begin isNeg := True; Advance; end;
        if Peek = '(' then begin Advance; if isNeg then isNeg := True; end;
        numStr := '';
        if IsDigit(Peek) or (Peek = '0') then
        begin
          while not AtEnd and (Peek in ['0'..'9', 'x', 'X', 'a'..'f', 'A'..'F', 'u', 'U', 'l', 'L']) do
          begin
            numStr := numStr + Peek;
            Advance;
          end;
        end;
        SkipPreprocessorLine;
        if numStr <> '' then
        begin
          try
            if (Length(numStr) > 2) and (numStr[1] = '0') and
               (numStr[2] in ['x', 'X']) then
              defVal := StrToInt('$' + Copy(numStr, 3, MaxInt))
            else
            begin
              // Strip suffixes
              while (Length(numStr) > 0) and (numStr[Length(numStr)] in ['u', 'U', 'l', 'L']) do
                Delete(numStr, Length(numStr), 1);
              defVal := StrToInt64(numStr);
            end;
            if isNeg then defVal := -defVal;
            SetLength(res.Defines, Length(res.Defines) + 1);
            res.Defines[High(res.Defines)].Name := defName;
            res.Defines[High(res.Defines)].Value := defVal;
            res.Defines[High(res.Defines)].IsNumeric := True;
          except
            // not a simple integer, skip
          end;
        end;
      end;
    end
    else
      SkipPreprocessorLine;
    Result := True;
    Exit;
  end;

  // Skip 'extern "C"' block start
  if (Peek = 'e') then
  begin
    savedPos := FPos;
    tok := ReadIdent;
    if tok = 'extern' then
    begin
      SkipWhitespaceAndComments;
      if Peek = '"' then
      begin
        // extern "C" — skip the string, then handle { or single decl
        Advance; // "
        while not AtEnd and (Peek <> '"') do Advance;
        if not AtEnd then Advance; // closing "
        SkipWhitespaceAndComments;
        if Peek = '{' then
        begin
          Advance; // consume { — we'll keep parsing inside
          Result := True;
          Exit;
        end;
        // else: fall through to parse the single declaration
        Result := True;
        Exit;
      end;
      // else: 'extern' before a declaration — treat as qualifier, keep parsing
      FPos := savedPos;
    end
    else
      FPos := savedPos;
  end;

  // Skip closing brace (from extern "C" { ... })
  if Peek = '}' then
  begin
    Advance;
    SkipWhitespaceAndComments;
    if Peek = ';' then Advance; // extern "C" { } ;
    Result := True;
    Exit;
  end;

  // typedef struct X X; — register as opaque type
  if Peek = 't' then
  begin
    savedPos := FPos;
    tok := ReadIdent;
    if tok = 'typedef' then
    begin
      SkipWhitespaceAndComments;
      tok := ReadIdent;
      if (tok = 'struct') or (tok = 'union') or (tok = 'enum') then
      begin
        SkipWhitespaceAndComments;
        // Might be: typedef struct X { ... } X; or typedef struct X X;
        if IsAlpha(Peek) then
        begin
          tok := ReadIdent; // struct tag name
          SkipWhitespaceAndComments;
          if Peek = '{' then
          begin
            SkipBraces;
            SkipWhitespaceAndComments;
          end;
          if IsAlpha(Peek) then
          begin
            defName := ReadIdent; // alias name
            SkipWhitespaceAndComments;
            if Peek = ';' then
            begin
              Advance;
              if res.OpaqueTypes.IndexOf(defName) < 0 then
                res.OpaqueTypes.Add(defName);
            end;
          end
          else if Peek = ';' then
            Advance;
        end
        else if Peek = '{' then
        begin
          SkipBraces;
          SkipWhitespaceAndComments;
          if IsAlpha(Peek) then
          begin
            defName := ReadIdent;
            SkipWhitespaceAndComments;
            if res.OpaqueTypes.IndexOf(defName) < 0 then
              res.OpaqueTypes.Add(defName);
          end;
          if Peek = ';' then Advance;
        end;
      end
      else
      begin
        // typedef <type> <name>; — skip for now
        while not AtEnd and (Peek <> ';') do Advance;
        if not AtEnd then Advance;
      end;
      Result := True;
      Exit;
    end
    else
      FPos := savedPos;
  end;

  // struct / union / enum definition at top level — skip
  if Peek in ['s', 'u', 'e'] then
  begin
    savedPos := FPos;
    tok := ReadIdent;
    if (tok = 'struct') or (tok = 'union') or (tok = 'enum') then
    begin
      SkipWhitespaceAndComments;
      if IsAlpha(Peek) then ReadIdent; // tag
      SkipWhitespaceAndComments;
      if Peek = '{' then
      begin
        SkipBraces;
        SkipWhitespaceAndComments;
        while not AtEnd and (Peek <> ';') do Advance;
        if not AtEnd then Advance;
        Result := True;
        Exit;
      end;
      FPos := savedPos;
    end
    else
      FPos := savedPos;
  end;

  // Try to parse a function declaration:
  // rettype [*] funcname ( params ) ;
  // or rettype [*] funcname ( params ) { ... }  — skip body
  savedPos := FPos;
  paramName := '';
  retType := ParseTypeAndName(paramName);

  if retType = '' then
  begin
    // couldn't parse anything sensible — skip one char
    Advance;
    Result := True;
    Exit;
  end;

  SkipWhitespaceAndComments;

  // After the type, we expect either an identifier (function name) or '('
  fnName := '';
  if paramName <> '' then
    fnName := paramName  // ParseTypeAndName found a name
  else if IsAlpha(Peek) then
  begin
    fnName := ReadIdent;
    SkipWhitespaceAndComments;
  end;

  if fnName = '' then
  begin
    // No function name found — skip to semicolon
    while not AtEnd and (Peek <> ';') and (Peek <> '{') do Advance;
    if not AtEnd then
    begin
      if Peek = '{' then SkipBraces else Advance;
    end;
    Result := True;
    Exit;
  end;

  // Expect '(' for function params
  if Peek <> '(' then
  begin
    // Not a function — variable or other declaration, skip to ;
    while not AtEnd and (Peek <> ';') do Advance;
    if not AtEnd then Advance;
    Result := True;
    Exit;
  end;

  // Parse parameter list
  isVariadic := False;
  fnDecl.Params := ParseParamList(isVariadic);
  fnDecl.Name := fnName;
  fnDecl.ReturnType := retType;
  fnDecl.IsVariadic := isVariadic;
  fnDecl.IsStatic := False;

  SkipWhitespaceAndComments;

  // Skip GCC qualifiers/attributes between param list and ; or {
  // e.g. __THROW, __attribute_pure__, __nonnull((1)), __attribute__((nothrow))
  while not AtEnd and (Peek <> ';') and (Peek <> '{') do
  begin
    if (Peek = '_') or (FText[FPos] in ['a'..'z', 'A'..'Z']) then
    begin
      tok := ReadIdent;
      // If it's __attribute__ it may be followed by ((...))
      SkipWhitespaceAndComments;
      if Peek = '(' then SkipParens;
      SkipWhitespaceAndComments;
      if Peek = '(' then SkipParens;
      SkipWhitespaceAndComments;
    end
    else
      Break; // unexpected non-ident, non-paren — stop and let outer check handle it
  end;

  if Peek = ';' then
  begin
    Advance; // consume ;
    // Valid function declaration — add if it has a real name and return type
    // Skip duplicates (GCC headers often have const/non-const overload pairs)
    if (fnDecl.Name <> '') and (fnDecl.ReturnType <> '') then
    begin
      alreadyExists := False;
      for di := 0 to High(res.Functions) do
        if res.Functions[di].Name = fnDecl.Name then begin alreadyExists := True; Break; end;
      if not alreadyExists then
      begin
        SetLength(res.Functions, Length(res.Functions) + 1);
        res.Functions[High(res.Functions)] := fnDecl;
      end;
    end;
  end
  else if Peek = '{' then
  begin
    SkipBraces; // inline/static function definition — skip body
    // Optionally collect static inline functions too? For now skip.
    fnDecl.IsStatic := True;
  end
  else
  begin
    // unexpected — skip to ;
    while not AtEnd and (Peek <> ';') do Advance;
    if not AtEnd then Advance;
  end;

  Result := True;
end;

function TCHeaderParser.ParseString(const src: string): TCHeaderParseResult;
var
  safety: Integer;
begin
  FText := src;
  FPos := 1;
  FLen := Length(src);
  FErrors.Clear;
  Result.Functions := nil;
  Result.Defines := nil;
  Result.OpaqueTypes := TStringList.Create;
  Result.OpaqueTypes.Sorted := False;
  Result.OpaqueTypes.Duplicates := dupIgnore;

  safety := 0;
  while not AtEnd do
  begin
    Inc(safety);
    if safety > 1000000 then Break; // infinite loop guard
    if not ParseDecl(Result) then
      Advance; // skip unrecognized char
  end;
end;

function TCHeaderParser.ParseFile(const filename: string): TCHeaderParseResult;
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.LoadFromFile(filename);
    Result := ParseString(sl.Text);
  finally
    sl.Free;
  end;
end;

{ ── Type Mapping ──────────────────────────────────────────────────────────── }

function MapCTypeToLyx(const cType: string): string;
var
  t: string;
  isPtr: Boolean;
begin
  t := Trim(cType);
  isPtr := False;

  // Pointer: any type ending with * is a pchar (raw C pointer)
  if (Length(t) > 0) and (t[Length(t)] = '*') then
  begin
    // Check for function pointer (already mapped to void*)
    Result := 'pchar';
    Exit;
  end;

  // Normalize: remove duplicate spaces
  while Pos('  ', t) > 0 do
    t := StringReplace(t, '  ', ' ', [rfReplaceAll]);

  // Exact type mappings
  if (t = 'void')                                          then Result := 'void'
  else if (t = 'int') or (t = 'signed int') or
          (t = 'signed') or (t = 'int32_t') or
          (t = 'int_least32_t')                           then Result := 'int32'
  else if (t = 'unsigned int') or (t = 'unsigned') or
          (t = 'uint32_t') or (t = 'uint_least32_t')     then Result := 'uint32'
  else if (t = 'long long') or (t = 'signed long long') or
          (t = 'long long int') or (t = 'int64_t') or
          (t = 'int_least64_t')                           then Result := 'int64'
  else if (t = 'unsigned long long') or
          (t = 'unsigned long long int') or
          (t = 'uint64_t') or (t = 'uint_least64_t')     then Result := 'uint64'
  else if (t = 'long') or (t = 'long int') or
          (t = 'signed long')                             then Result := 'int64'  // 64-bit on Linux/macOS
  else if (t = 'unsigned long') or
          (t = 'unsigned long int')                       then Result := 'uint64'
  else if (t = 'short') or (t = 'short int') or
          (t = 'signed short') or (t = 'int16_t') or
          (t = 'int_least16_t')                           then Result := 'int16'
  else if (t = 'unsigned short') or
          (t = 'unsigned short int') or
          (t = 'uint16_t') or (t = 'uint_least16_t')     then Result := 'uint16'
  else if (t = 'char') or (t = 'signed char') or
          (t = 'int8_t') or (t = 'int_least8_t')         then Result := 'int8'
  else if (t = 'unsigned char') or (t = 'uint8_t') or
          (t = 'uint_least8_t')                           then Result := 'uint8'
  else if (t = 'float')                                   then Result := 'f32'
  else if (t = 'double') or (t = 'long double')          then Result := 'f64'
  else if (t = 'bool') or (t = '_Bool')                  then Result := 'bool'
  else if (t = 'size_t') or (t = 'uintptr_t')           then Result := 'usize'
  else if (t = 'ssize_t') or (t = 'ptrdiff_t') or
          (t = 'intptr_t')                                then Result := 'isize'
  else
    // Unknown / struct / opaque type — treat as opaque pointer
    Result := 'pchar';
end;

end.
