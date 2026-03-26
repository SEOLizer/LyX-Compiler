{$mode objfpc}{$H+}
unit lexer;

interface

uses
  SysUtils,
  diag;

type
  TTokenKind = (
    // Literale
    tkIntLit, tkFloatLit, tkStrLit, tkCharLit, tkRegexLit, tkIdent,
    // Keywords
    tkFn, tkVar, tkLet, tkCo, tkCon,
    tkIf, tkElse, tkWhile, tkReturn,
    tkTrue, tkFalse, tkNull, tkExtern, tkCase, tkSwitch, tkBreak, tkDefault, tkMatch,
    tkUnit, tkImport, tkPublic, tkAs, tkType, tkEnum, tkStruct, tkArray, tkStatic,
    tkFor, tkTo, tkDownto, tkDo, tkRepeat, tkUntil, tkPool,
    tkTry, tkCatch, tkThrow, tkFinally,
    // OOP Keywords
    tkClass, tkExtends, tkSuper, tkNew, tkDispose,
    tkInterface, tkImplements,
    // Access Control Keywords
    tkPrivate, tkProtected,
    // SIMD Keywords
    tkParallel,
    // Error Handling Keywords
    tkPanic, tkAssert,
    // Constraint Keywords
    tkWhere, tkValue,
    // Map/Set Keywords
    tkMap, tkSet, tkIn,
    // OOP Additional Keywords
    tkVirtual, tkOverride, tkAbstract, tkIs,
    // Operatoren
    tkPlus, tkMinus, tkStar, tkSlash, tkPercent,
    tkPlusPlus, tkMinusMinus,  // Inkrement/Dekrement
    tkAssign, tkSingleEq,
    tkEq, tkNeq,
    tkLt, tkLe, tkGt, tkGe,
    tkAnd, tkOr, tkNot, tkNor, tkXor,
    // Bitwise Operatoren
    tkBitAnd, tkBitOr, tkBitXor, tkBitNot,
    tkShiftLeft, tkShiftRight,
    // Trennzeichen
    tkLParen, tkRParen, tkLBrace, tkRBrace,
    tkLBracket, tkRBracket,
    tkColon, tkComma, tkSemicolon, tkEllipsis, tkDot, tkAt,
    // Null-Safety Operatoren
    tkQuestion, tkNullCoalesce, tkSafeCall,
    // Pipe-Operator
    tkPipe,
    // Fat Arrow (=>)
    tkFatArrow,
    // Sonstiges
    tkEOF, tkError
  );

  TToken = record
    Kind: TTokenKind;
    Value: string;
    Span: TSourceSpan;
  end;

  TLexer = class
  private
    FSource: string;
    FFileName: string;
    FPos: Integer;
    FLine: Integer;
    FCol: Integer;
    FDiag: TDiagnostics;
    FPeeked: Boolean;
    FPeekTok: TToken;

    function CurrentChar: Char;
    function PeekChar: Char;
    procedure Advance;
    procedure SkipWhitespace;
    procedure SkipLineComment;
    procedure SkipBlockComment;
    function IsAtEnd: Boolean;

    function MakeToken(kind: TTokenKind; const value: string;
      startLine, startCol, len: Integer): TToken;
    function ReadNumber: TToken;
    function ParseNumberWithBase(startPos: Integer): Int64;
    function IsValidDigit(c: Char; base: Integer): Boolean;
    function IsHexDigit(c: Char): Boolean;
    function DigitValue(c: Char): Integer;
    function ReadString: TToken;
    function ReadCharLit: TToken;
    function ReadRegexLit: TToken;
    function ReadIdentOrKeyword: TToken;
    function LookupKeyword(const s: string): TTokenKind;
  public
    constructor Create(const source, fileName: string; d: TDiagnostics);
    destructor Destroy; override;

    function NextToken: TToken;
    function PeekToken: TToken;
  end;

function TokenKindToStr(kind: TTokenKind): string;

implementation

function TokenKindToStr(kind: TTokenKind): string;
begin
  case kind of
    tkIntLit:    Result := 'IntLit';
    tkFloatLit:  Result := 'FloatLit';
    tkStrLit:    Result := 'StrLit';
    tkCharLit:   Result := 'CharLit';
    tkRegexLit:  Result := 'RegexLit';
    tkIdent:     Result := 'Ident';
    tkFn:        Result := 'fn';
    tkVar:       Result := 'var';
    tkLet:       Result := 'let';
    tkCo:        Result := 'co';
    tkCon:       Result := 'con';
    tkIf:        Result := 'if';
    tkElse:      Result := 'else';
    tkWhile:     Result := 'while';
    tkReturn:    Result := 'return';
    tkTrue:      Result := 'true';
    tkFalse:     Result := 'false';
    tkNull:      Result := 'null';
    tkExtern:    Result := 'extern';
    tkCase:      Result := 'case';
    tkSwitch:    Result := 'switch';
    tkBreak:     Result := 'break';
    tkDefault:   Result := 'default';
    tkMatch:     Result := 'match';
    tkUnit:      Result := 'unit';
    tkImport:    Result := 'import';
    tkPublic:    Result := 'public';
    tkAs:        Result := 'as';
    tkType:      Result := 'type';
    tkEnum:      Result := 'enum';
    tkStruct:    Result := 'struct';
    tkArray:     Result := 'array';
    tkStatic:    Result := 'static';
    tkFor:       Result := 'for';
    tkTo:        Result := 'to';
    tkDownto:    Result := 'downto';
    tkDo:        Result := 'do';
    tkRepeat:     Result := 'repeat';
    tkUntil:      Result := 'until';
    tkPool:       Result := 'pool';
    tkTry:        Result := 'try';
    tkCatch:      Result := 'catch';
    tkThrow:      Result := 'throw';
    tkFinally:    Result := 'finally';
    tkClass:      Result := 'class';
    tkExtends:    Result := 'extends';
    tkSuper:      Result := 'super';
    tkNew:        Result := 'new';
    tkDispose:    Result := 'dispose';
    tkInterface:  Result := 'interface';
    tkImplements: Result := 'implements';
    tkPrivate:    Result := 'private';
    tkProtected:  Result := 'protected';
    tkPanic:      Result := 'panic';
    tkAssert:     Result := 'assert';
    tkWhere:      Result := 'where';
    tkValue:      Result := 'value';
    tkMap:        Result := 'Map';
    tkSet:        Result := 'Set';
    tkIn:         Result := 'in';
    tkVirtual:    Result := 'virtual';
    tkOverride:   Result := 'override';
    tkAbstract:   Result := 'abstract';
    tkPlus:       Result := '+';
    tkMinus:      Result := '-';
    tkPlusPlus:   Result := '++';
    tkMinusMinus: Result := '--';
    tkStar:       Result := '*';
    tkSlash:     Result := '/';
    tkPercent:   Result := '%';
    tkAssign:    Result := ':=';
    tkSingleEq:  Result := '=';
    tkEq:        Result := '==';
    tkNeq:       Result := '!=';
    tkLt:        Result := '<';
    tkLe:        Result := '<=';
    tkGt:        Result := '>';
    tkGe:        Result := '>=';
    tkAnd:       Result := '&&';
    tkOr:        Result := '||';
    tkNot:       Result := '!';
    tkNor:       Result := '~|';
    tkXor:       Result := '^';
    tkLParen:    Result := '(';
    tkRParen:    Result := ')';
    tkLBrace:    Result := '{';
    tkRBrace:    Result := '}';
    tkLBracket:  Result := '[';
    tkRBracket:  Result := ']';
    tkColon:     Result := ':';
    tkComma:     Result := ',';
    tkSemicolon: Result := ';';
    tkEllipsis:  Result := '...';
    tkDot:       Result := '.';
    tkAt:        Result := '@';
    tkQuestion:  Result := '?';
    tkNullCoalesce: Result := '??';
    tkSafeCall:  Result := '?.';
    tkBitAnd:    Result := '&';
    tkBitOr:     Result := '|';
    tkBitXor:    Result := '^';
    tkBitNot:    Result := '~';
    tkShiftLeft: Result := '<<';
    tkShiftRight:Result := '>>';
    tkPipe:      Result := '|>';
    tkFatArrow:  Result := '=>';
    tkEOF:       Result := 'EOF';
    tkError:     Result := 'ERROR';
  end;
end;

{ TLexer }

constructor TLexer.Create(const source, fileName: string; d: TDiagnostics);
begin
  inherited Create;
  FSource := source;
  FFileName := fileName;
  FPos := 1;
  FLine := 1;
  FCol := 1;
  FDiag := d;
  FPeeked := False;
end;

destructor TLexer.Destroy;
begin
  inherited Destroy;
end;

function TLexer.CurrentChar: Char;
begin
  if FPos <= Length(FSource) then
    Result := FSource[FPos]
  else
    Result := #0;
end;

function TLexer.PeekChar: Char;
begin
  if FPos + 1 <= Length(FSource) then
    Result := FSource[FPos + 1]
  else
    Result := #0;
end;

procedure TLexer.Advance;
begin
  if FPos <= Length(FSource) then
  begin
    if FSource[FPos] = #10 then
    begin
      Inc(FLine);
      FCol := 1;
    end
    else
      Inc(FCol);
    Inc(FPos);
  end;
end;

function TLexer.IsAtEnd: Boolean;
begin
  Result := FPos > Length(FSource);
end;

procedure TLexer.SkipWhitespace;
begin
  while (not IsAtEnd) and (CurrentChar in [' ', #9, #13, #10]) do
    Advance;
end;

procedure TLexer.SkipLineComment;
begin
  // Wir stehen auf dem ersten '/'
  Advance; // zweites '/'
  Advance;
  while (not IsAtEnd) and (CurrentChar <> #10) do
    Advance;
end;

procedure TLexer.SkipBlockComment;
var
  startLine, startCol: Integer;
begin
  startLine := FLine;
  startCol := FCol;
  Advance; // '*'
  Advance;
  while not IsAtEnd do
  begin
    if (CurrentChar = '*') and (PeekChar = '/') then
    begin
      Advance; // '*'
      Advance; // '/'
      Exit;
    end;
    Advance;
  end;
  FDiag.Error('unterminated block comment',
    MakeSpan(startLine, startCol, 2, FFileName));
end;

function TLexer.MakeToken(kind: TTokenKind; const value: string;
  startLine, startCol, len: Integer): TToken;
begin
  Result.Kind := kind;
  Result.Value := value;
  Result.Span := MakeSpan(startLine, startCol, len, FFileName);
end;

{ Helper function to check if character is a valid digit for given base }
function TLexer.IsValidDigit(c: Char; base: Integer): Boolean;
begin
  case base of
    2:   Result := (c in ['0', '1']);
    8:   Result := (c in ['0'..'7']);
    10:  Result := (c in ['0'..'9']);
    16:  Result := (c in ['0'..'9', 'a'..'f', 'A'..'F']);
  else
    Result := False;
  end;
end;

{ Check if character is a hex digit (0-9, a-f, A-F) }
function TLexer.IsHexDigit(c: Char): Boolean;
begin
  Result := c in ['0'..'9', 'a'..'f', 'A'..'F'];
end;

{ Helper function to convert digit character to integer value }
function TLexer.DigitValue(c: Char): Integer;
begin
  case c of
    '0'..'9': Result := Ord(c) - Ord('0');
    'a'..'f': Result := Ord(c) - Ord('a') + 10;
    'A'..'F': Result := Ord(c) - Ord('A') + 10;
  else
    Result := 0;
  end;
end;

{ Parse number with support for different bases }
function TLexer.ParseNumberWithBase(startPos: Integer): Int64;
var
  base: Integer;
  digit: Integer;
  c: Char;
  hasDigits: Boolean;
begin
  Result := 0;
  hasDigits := False;
  base := 10; // default
  
  // Check for prefix
  if not IsAtEnd and (CurrentChar = '0') and (FPos + 1 <= Length(FSource)) then
  begin
    case FSource[FPos + 1] of
      'x', 'X': begin base := 16; Advance; Advance; end;
      'b', 'B': begin base := 2; Advance; Advance; end;
      'o', 'O': begin base := 8; Advance; Advance; end;
    end;
  end
  else if not IsAtEnd and (CurrentChar = '$') then
  begin
    base := 16;
    Advance;
  end
  else if not IsAtEnd and (CurrentChar = '%') then
  begin
    base := 2;
    Advance;
  end
  else if not IsAtEnd and (CurrentChar = '&') then
  begin
    base := 8;
    Advance;
  end;
  
  // Parse digits
  while not IsAtEnd do
  begin
    c := CurrentChar;
    
    // Skip underscores (digit separators)
    if c = '_' then
    begin
      Advance;
      Continue;
    end;
    
    // Check if valid digit for current base
    if not IsValidDigit(c, base) then
      Break;
    
    digit := DigitValue(c);
    Result := Result * base + digit;
    hasDigits := True;
    Advance;
  end;
  
  // Error if no valid digits found
  if not hasDigits then
  begin
    FDiag.Error('invalid number literal for base ' + IntToStr(base), MakeSpan(FLine, FCol, 1, FFileName));
    Result := 0;
  end;
end;

function TLexer.ReadNumber: TToken;
var
  startPos, startCol: Integer;
  s: string;
  isFloat: Boolean;
  currentLen: Integer;
  numValue: Int64;
begin
  startPos := FPos;
  startCol := FCol;
  isFloat := False;

  // Check for hex/binary/octal prefix first
  if (not IsAtEnd) and (CurrentChar = '0') and (FPos + 1 <= Length(FSource)) then
  begin
    case FSource[FPos + 1] of
      'x', 'X', 'b', 'B', 'o', 'O':
      begin
        // Parse number with base
        numValue := ParseNumberWithBase(startPos);
        s := IntToStr(numValue); // Store as decimal string internally
        currentLen := FPos - startPos;
        Exit(MakeToken(tkIntLit, s, FLine, startCol, currentLen));
      end;
    end;
  end
  // Check for $ (hex) or % (binary) or & (octal)
  else if (not IsAtEnd) and (CurrentChar in ['$', '%', '&']) then
  begin
    numValue := ParseNumberWithBase(startPos);
    s := IntToStr(numValue);
    currentLen := FPos - startPos;
    Exit(MakeToken(tkIntLit, s, FLine, startCol, currentLen));
  end;

  // Default: decimal number
  while (not IsAtEnd) and (CurrentChar in ['0'..'9', '_']) do
  begin
    // Skip underscores but don't advance past them
    if CurrentChar = '_' then
    begin
      Advance;
      if IsAtEnd then Break;
      Continue;
    end;
    Advance;
  end;

  // Check for decimal point for Float-Literale
  if (not IsAtEnd) and (CurrentChar = '.') then
  begin
    // Check if after the dot there's a digit, otherwise it's a Dot-Token
    if (FPos + 1 <= Length(FSource)) and (FSource[FPos + 1] in ['0'..'9']) then
    begin
      isFloat := True;
      Advance; // skip dot
      while (not IsAtEnd) and (CurrentChar in ['0'..'9', '_']) do
      begin
        if CurrentChar = '_' then
        begin
          Advance;
          if IsAtEnd then Break;
          Continue;
        end;
        Advance;
      end;
    end;
  end;

  currentLen := FPos - startPos;
  s := Copy(FSource, startPos, currentLen);

  // Remove underscores from number string (both integer and float)
  s := StringReplace(s, '_', '', [rfReplaceAll]);

  if isFloat then
    Result := MakeToken(tkFloatLit, s, FLine, startCol, currentLen)
  else
    Result := MakeToken(tkIntLit, s, FLine, startCol, currentLen);
end;

function TLexer.ReadString: TToken;
var
  startLine, startCol: Integer;
  s: string;
  c: Char;
  hexStr: string;
  hexVal: Integer;
begin
  startLine := FLine;
  startCol := FCol;
  Advance; // öffnendes "
  s := '';
  while (not IsAtEnd) and (CurrentChar <> '"') do
  begin
    if CurrentChar = #10 then
    begin
      FDiag.Error('unterminated string literal',
        MakeSpan(startLine, startCol, 1, FFileName));
      Result := MakeToken(tkError, '', startLine, startCol, 1);
      Exit;
    end;
    if CurrentChar = '\' then
    begin
      Advance;
      if IsAtEnd then
      begin
        FDiag.Error('unexpected end of file in string escape',
          MakeSpan(FLine, FCol, 1, FFileName));
        Result := MakeToken(tkError, '', startLine, startCol, 1);
        Exit;
      end;
      c := CurrentChar;
      case c of
        'n':  begin s := s + #10; Advance; end;
        'r':  begin s := s + #13; Advance; end;
        't':  begin s := s + #9; Advance; end;
        '\':  begin s := s + '\'; Advance; end;
        '"':  begin s := s + '"'; Advance; end;
        '0':  begin s := s + #0; Advance; end;
        'e':  begin s := s + #27; Advance; end;  // ESC character
        'a':  begin s := s + #7; Advance; end;   // Bell
        'b':  begin s := s + #8; Advance; end;   // Backspace
        'f':  begin s := s + #12; Advance; end;  // Form feed
        'v':  begin s := s + #11; Advance; end;  // Vertical tab
        'x':  begin
                // Hex escape: \xNN
                Advance;
                if IsAtEnd or (not IsHexDigit(CurrentChar)) then
                begin
                  FDiag.Error('invalid hex escape sequence',
                    MakeSpan(FLine, FCol - 2, 2, FFileName));
                end
                else
                begin
                  hexStr := '';
                  // Read up to 2 hex digits
                  if IsHexDigit(CurrentChar) then
                  begin
                    hexStr := hexStr + CurrentChar;
                    Advance;
                  end;
                  if (not IsAtEnd) and IsHexDigit(CurrentChar) then
                  begin
                    hexStr := hexStr + CurrentChar;
                    Advance;
                  end;
                  hexVal := StrToInt('$' + hexStr);
                  s := s + Chr(hexVal);
                end;
              end;
      else
        FDiag.Error('unknown escape sequence: \' + c,
          MakeSpan(FLine, FCol - 1, 2, FFileName));
        Advance;
      end;
    end
    else
    begin
      s := s + CurrentChar;
      Advance;
    end;
  end;
  if IsAtEnd then
  begin
    FDiag.Error('unterminated string literal',
      MakeSpan(startLine, startCol, 1, FFileName));
    Result := MakeToken(tkError, '', startLine, startCol, 1);
    Exit;
  end;
  Advance; // schließendes "
  Result := MakeToken(tkStrLit, s, startLine, startCol,
    FCol - startCol);
end;

function TLexer.ReadCharLit: TToken;
var
  startLine, startCol: Integer;
  ch: string;
  c: Char;
begin
  startLine := FLine;
  startCol := FCol;
  Advance; // öffnendes '
  ch := '';
  if IsAtEnd then
  begin
    FDiag.Error('unterminated char literal',
      MakeSpan(startLine, startCol, 1, FFileName));
    Result := MakeToken(tkError, '', startLine, startCol, 1);
    Exit;
  end;
  if CurrentChar = '\' then
  begin
    Advance;
    if IsAtEnd then
    begin
      FDiag.Error('unterminated char literal escape',
        MakeSpan(startLine, startCol, 1, FFileName));
      Result := MakeToken(tkError, '', startLine, startCol, 1);
      Exit;
    end;
    c := CurrentChar;
    case c of
      'n':  ch := #10;
      'r':  ch := #13;
      't':  ch := #9;
      '\':  ch := '\';
      '''': ch := '''';
      '0':  ch := #0;
    else
      FDiag.Error('unknown escape in char literal: \' + c,
        MakeSpan(FLine, FCol - 1, 2, FFileName));
      ch := c;
    end;
    Advance;
  end
  else
  begin
    ch := CurrentChar;
    Advance;
  end;
  if IsAtEnd or (CurrentChar <> '''') then
  begin
    FDiag.Error('unterminated char literal, expected closing quote',
      MakeSpan(startLine, startCol, 1, FFileName));
    Result := MakeToken(tkError, ch, startLine, startCol, 1);
    Exit;
  end;
  Advance; // schließendes '
  Result := MakeToken(tkCharLit, ch, startLine, startCol,
    FCol - startCol);
end;

function TLexer.ReadRegexLit: TToken;
{ Regex-Literal: r"..." }
var
  startLine, startCol: Integer;
  s: string;
begin
  startLine := FLine;
  startCol := FCol;
  Advance; // 'r'
  Advance; // öffnendes "
  s := '';
  while (not IsAtEnd) and (CurrentChar <> '"') do
  begin
    if CurrentChar = #10 then
    begin
      FDiag.Error('unterminated regex literal',
        MakeSpan(startLine, startCol, 1, FFileName));
      Result := MakeToken(tkError, '', startLine, startCol, 1);
      Exit;
    end;
    // Support basic escape sequences in regex
    if CurrentChar = '\' then
    begin
      Advance;
      if IsAtEnd then
      begin
        FDiag.Error('unexpected end of file in regex escape',
          MakeSpan(FLine, FCol, 1, FFileName));
        Result := MakeToken(tkError, '', startLine, startCol, 1);
        Exit;
      end;
      // Pass through escape sequences - regex engine handles them
      s := s + '\';
      s := s + CurrentChar;
      Advance;
      Continue;
    end;
    s := s + CurrentChar;
    Advance;
  end;
  if IsAtEnd then
  begin
    FDiag.Error('unterminated regex literal',
      MakeSpan(startLine, startCol, 1, FFileName));
    Result := MakeToken(tkError, '', startLine, startCol, 1);
    Exit;
  end;
  Advance; // schließendes "
  Result := MakeToken(tkRegexLit, s, startLine, startCol,
    FCol - startCol);
end;

function TLexer.LookupKeyword(const s: string): TTokenKind;
begin
  case s of
    'fn':      Result := tkFn;
    'var':     Result := tkVar;
    'let':     Result := tkLet;
    'co':      Result := tkCo;
    'con':     Result := tkCon;
    'if':      Result := tkIf;
    'else':    Result := tkElse;
    'while':   Result := tkWhile;
    'return':  Result := tkReturn;
    'true':    Result := tkTrue;
    'false':   Result := tkFalse;
    'null':    Result := tkNull;
    'extern':  Result := tkExtern;
    'case':    Result := tkCase;
    'switch':  Result := tkSwitch;
    'break':   Result := tkBreak;
    'default': Result := tkDefault;
    'match':   Result := tkMatch;
    'unit':    Result := tkUnit;
    'import':  Result := tkImport;
    'public':  Result := tkPublic;
    'pub':     Result := tkPublic;
    'as':      Result := tkAs;
    'type':    Result := tkType;
    'enum':    Result := tkEnum;
    'struct':  Result := tkStruct;
    'array':   Result := tkArray;
    'static':  Result := tkStatic;
    'for':     Result := tkFor;
    'to':      Result := tkTo;
    'downto':  Result := tkDownto;
    'do':      Result := tkDo;
    'repeat':     Result := tkRepeat;
    'until':      Result := tkUntil;
    'pool':       Result := tkPool;
    'try':        Result := tkTry;
    'catch':      Result := tkCatch;
    'throw':      Result := tkThrow;
    'finally':    Result := tkFinally;
    // OOP Keywords
    'class':      Result := tkClass;
    'extends':    Result := tkExtends;
    'super':      Result := tkSuper;
    'new':        Result := tkNew;
    'dispose':    Result := tkDispose;
    'interface':   Result := tkInterface;
    'implements':  Result := tkImplements;
    // Access Control Keywords
    'private':    Result := tkPrivate;
    'protected':  Result := tkProtected;
    // SIMD Keywords
    'parallel':   Result := tkParallel;
    // Error Handling Keywords
    'panic':      Result := tkPanic;
    'assert':     Result := tkAssert;
    // Constraint Keywords
    'where':      Result := tkWhere;
    'value':      Result := tkValue;
    // Map/Set Keywords
    'Map':        Result := tkMap;
    'Set':        Result := tkSet;
    'in':         Result := tkIn;
    // OOP Additional Keywords
    'virtual':    Result := tkVirtual;
    'override':   Result := tkOverride;
    'abstract':   Result := tkAbstract;
    'is':         Result := tkIs;
  else
    Result := tkIdent;
  end;
end;

function TLexer.ReadIdentOrKeyword: TToken;
var
  startPos, startCol: Integer;
  s: string;
  kind: TTokenKind;
begin
  startPos := FPos;
  startCol := FCol;
  while (not IsAtEnd) and
    (CurrentChar in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
    Advance;
  s := Copy(FSource, startPos, FPos - startPos);
  kind := LookupKeyword(s);
  Result := MakeToken(kind, s, FLine, startCol, Length(s));
end;

function TLexer.NextToken: TToken;
var
  startLine, startCol: Integer;
  c: Char;
begin
  if FPeeked then
  begin
    FPeeked := False;
    Result := FPeekTok;
    Exit;
  end;

  // Whitespace und Kommentare überspringen
  while True do
  begin
    SkipWhitespace;
    if IsAtEnd then
    begin
      Result := MakeToken(tkEOF, '', FLine, FCol, 0);
      Exit;
    end;
    // Kommentare
    if (CurrentChar = '/') and (PeekChar = '/') then
    begin
      SkipLineComment;
      Continue;
    end;
    if (CurrentChar = '/') and (PeekChar = '*') then
    begin
      SkipBlockComment;
      Continue;
    end;
    Break;
  end;

  startLine := FLine;
  startCol := FCol;
  c := CurrentChar;

  // Zahlen (decimal, hex, binary, octal)
  if c in ['0'..'9'] then
  begin
    Result := ReadNumber;
    Exit;
  end;
  
  if c = '$' then // Hex-Literal ($FF)
  begin
    Result := ReadNumber;
    Exit;
  end;

  if c = '%' then // Binary-Literal (%1010) oder Modulo Operator
  begin
    if (not IsAtEnd) and (FPos + 1 <= Length(FSource)) and (FSource[FPos + 1] in ['0', '1']) then
    begin
      // % gefolgt von Binärziffer - parse als Binärzahl
      Result := ReadNumber;
      Exit;
    end;
    // Ansonsten, wenn nicht gefolgt von Binärziffer, dann ist es der Modulo Operator
  end;

  if c = '&' then // Octal-Literal (&77) oder Bitwise AND Operator
  begin
    if (not IsAtEnd) and (FPos + 1 <= Length(FSource)) and (FSource[FPos + 1] in ['0'..'7']) then
    begin
      // & gefolgt von Oktalziffer - parse als Oktalzahl
      Result := ReadNumber;
      Exit;
    end;
    // Ansonsten, wenn nicht gefolgt von Oktalziffer, dann ist es der Bitwise AND Operator
  end;

  // Strings
  if c = '"' then
  begin
    Result := ReadString;
    Exit;
  end;

  // Char literals
  if c = '''' then
  begin
    Result := ReadCharLit;
    Exit;
  end;

  // Regex literals: r"..."
  if (c = 'r') and (PeekChar = '"') then
  begin
    Result := ReadRegexLit;
    Exit;
  end;

  // Identifier / Keywords
  if c in ['A'..'Z', 'a'..'z', '_'] then
  begin
    Result := ReadIdentOrKeyword;
    Exit;
  end;

  // Operatoren und Trennzeichen
  case c of
    '+': begin
      Advance;
      if (not IsAtEnd) and (CurrentChar = '+') then
      begin
        Advance;
        Result := MakeToken(tkPlusPlus, '++', startLine, startCol, 2);
      end
      else
        Result := MakeToken(tkPlus, '+', startLine, startCol, 1);
    end;
    '-': begin
      Advance;
      if (not IsAtEnd) and (CurrentChar = '-') then
      begin
        Advance;
        Result := MakeToken(tkMinusMinus, '--', startLine, startCol, 2);
      end
      else
        Result := MakeToken(tkMinus, '-', startLine, startCol, 1);
    end;
    '*': begin Advance; Result := MakeToken(tkStar, '*', startLine, startCol, 1); end;
    '%': begin Advance; Result := MakeToken(tkPercent, '%', startLine, startCol, 1); end;
    '(': begin Advance; Result := MakeToken(tkLParen, '(', startLine, startCol, 1); end;
    ')': begin Advance; Result := MakeToken(tkRParen, ')', startLine, startCol, 1); end;
    '{': begin Advance; Result := MakeToken(tkLBrace, '{', startLine, startCol, 1); end;
    '}': begin Advance; Result := MakeToken(tkRBrace, '}', startLine, startCol, 1); end;
    ',': begin Advance; Result := MakeToken(tkComma, ',', startLine, startCol, 1); end;
    ';': begin Advance; Result := MakeToken(tkSemicolon, ';', startLine, startCol, 1); end;
    '.': begin
      // handle '...' ellipsis
      if (FPos + 2 <= Length(FSource)) and (FSource[FPos + 1] = '.') and (FSource[FPos + 2] = '.') then
      begin
        // consume three dots
        Advance; Advance; Advance;
        Result := MakeToken(tkEllipsis, '...', startLine, startCol, 3);
      end
      else
      begin
        Advance; Result := MakeToken(tkDot, '.', startLine, startCol, 1);
      end;
    end;
    '@': begin Advance; Result := MakeToken(tkAt, '@', startLine, startCol, 1); end;
    '?': begin
      Advance;
      if (not IsAtEnd) and (CurrentChar = '?') then
      begin
        Advance;
        Result := MakeToken(tkNullCoalesce, '??', startLine, startCol, 2);
      end
      else if (not IsAtEnd) and (CurrentChar = '.') then
      begin
        Advance;
        Result := MakeToken(tkSafeCall, '?.', startLine, startCol, 2);
      end
      else
        Result := MakeToken(tkQuestion, '?', startLine, startCol, 1);
    end;
    '!': begin
      Advance;
      if (not IsAtEnd) and (CurrentChar = '=') then
      begin
        Advance;
        Result := MakeToken(tkNeq, '!=', startLine, startCol, 2);
      end
      else
        Result := MakeToken(tkNot, '!', startLine, startCol, 1);
    end;
    '[': begin Advance; Result := MakeToken(tkLBracket, '[', startLine, startCol, 1); end;
    ']': begin Advance; Result := MakeToken(tkRBracket, ']', startLine, startCol, 1); end;

    '/': begin
      Advance;
      Result := MakeToken(tkSlash, '/', startLine, startCol, 1);
    end;

    ':': begin
      Advance;
      if (not IsAtEnd) and (CurrentChar = '=') then
      begin
        Advance;
        Result := MakeToken(tkAssign, ':=', startLine, startCol, 2);
      end
      else
        Result := MakeToken(tkColon, ':', startLine, startCol, 1);
    end;

    '=': begin
      Advance;
      if (not IsAtEnd) and (CurrentChar = '=') then
      begin
        Advance;
        Result := MakeToken(tkEq, '==', startLine, startCol, 2);
      end
      else if (not IsAtEnd) and (CurrentChar = '>') then
      begin
        Advance;
        Result := MakeToken(tkFatArrow, '=>', startLine, startCol, 2);
      end
      else
        Result := MakeToken(tkSingleEq, '=', startLine, startCol, 1);
    end;

    '<': begin
      Advance;
      if (not IsAtEnd) and (CurrentChar = '<') then
      begin
        // Shift Left
        Advance;
        Result := MakeToken(tkShiftLeft, '<<', startLine, startCol, 2);
      end
      else if (not IsAtEnd) and (CurrentChar = '=') then
      begin
        Advance;
        Result := MakeToken(tkLe, '<=', startLine, startCol, 2);
      end
      else
        Result := MakeToken(tkLt, '<', startLine, startCol, 1);
    end;

    '>': begin
      Advance;
      if (not IsAtEnd) and (CurrentChar = '>') then
      begin
        // Shift Right
        Advance;
        Result := MakeToken(tkShiftRight, '>>', startLine, startCol, 2);
      end
      else if (not IsAtEnd) and (CurrentChar = '=') then
      begin
        Advance;
        Result := MakeToken(tkGe, '>=', startLine, startCol, 2);
      end
      else
        Result := MakeToken(tkGt, '>', startLine, startCol, 1);
    end;

    '&': begin
      Advance;
      if (not IsAtEnd) and (CurrentChar = '&') then
      begin
        Advance;
        Result := MakeToken(tkAnd, '&&', startLine, startCol, 2);
      end
      else
      begin
        // Bitwise AND
        Result := MakeToken(tkBitAnd, '&', startLine, startCol, 1);
      end;
    end;

    '^': begin
      // Bitwise XOR
      Advance;
      Result := MakeToken(tkBitXor, '^', startLine, startCol, 1);
    end;

    '~': begin
      // Bitwise NOT
      Advance;
      Result := MakeToken(tkBitNot, '~', startLine, startCol, 1);
    end;

    '|': begin
      Advance;
      if (not IsAtEnd) and (CurrentChar = '|') then
      begin
        Advance;
        Result := MakeToken(tkOr, '||', startLine, startCol, 2);
      end
      else if (not IsAtEnd) and (CurrentChar = '~') then
      begin
        Advance;
        Result := MakeToken(tkNor, '|~', startLine, startCol, 2);
      end
      else if (not IsAtEnd) and (CurrentChar = '>') then
      begin
        Advance;
        Result := MakeToken(tkPipe, '|>', startLine, startCol, 2);
      end
      else
      begin
        // Bitwise OR
        Result := MakeToken(tkBitOr, '|', startLine, startCol, 1);
      end;
    end;

  else
    Advance;
    FDiag.Error('unexpected character: ' + c,
      MakeSpan(startLine, startCol, 1, FFileName));
    Result := MakeToken(tkError, c, startLine, startCol, 1);
  end;
end;

function TLexer.PeekToken: TToken;
begin
  if not FPeeked then
  begin
    FPeekTok := NextToken;
    FPeeked := True;
  end;
  Result := FPeekTok;
end;

end.
