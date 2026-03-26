{$mode objfpc}{$H+}
unit parser;

interface

uses
  SysUtils, Classes,
  diag, lexer, ast, backend_types, c_header_parser;

type
  TParser = class
  private
    FLexer: TLexer;
    FDiag: TDiagnostics;
    FCurTok: TToken;
    FHasCur: Boolean;
    FLastParamListVarArgs: Boolean;
    FCurrentTypeParams: TStringArray; // type params of current generic function

    procedure Advance; // setzt FCurTok
    function Check(kind: TTokenKind): Boolean;
    function Accept(kind: TTokenKind): Boolean;
    procedure Expect(kind: TTokenKind);

    function ParseVisibility: TVisibility;

    // Parsing-Methoden
    function ParseTopDecl: TAstNode;
    function ParseFuncDecl(isPub: Boolean): TAstFuncDecl;
    function ParseConDecl(isPub: Boolean): TAstConDecl;
    function ParseEnumDecl(isPub: Boolean): TAstEnumDecl;
    function ParseTypeDecl(isPub: Boolean): TAstNode;
    function ParseGlobalVarDecl(isPub: Boolean): TAstVarDecl;
    function ParseUnitDecl: TAstUnitDecl;
    function ParseImportDecl: TAstImportDecl;

    function ParseBlock: TAstBlock;
    function ParseStmt: TAstStmt;
    function ParseVarLetCoDecl: TAstVarDecl;
    function ParseForStmt: TAstFor;
    function ParseRepeatUntilStmt: TAstRepeatUntil;
    function ParseTryStmt: TAstTry;
    function ParseAssignStmtOrExprStmt: TAstStmt;

    // Expressions (Präzedenz): Pipe -> NullCoalesce -> Or -> And
    //   -> BitOr -> BitXor -> BitAnd -> Cmp -> Shift -> Add -> Mul -> Unary -> Primary -> Postfix
    function ParseExpr: TAstExpr;
    function ParsePipeExpr: TAstExpr;
    function ParseNullCoalesceExpr: TAstExpr;
    function ParseOrExpr: TAstExpr;
    function ParseAndExpr: TAstExpr;
    function ParseBitOrExpr: TAstExpr;
    function ParseBitXorExpr: TAstExpr;
    function ParseBitAndExpr: TAstExpr;
    function ParseCmpExpr: TAstExpr;
    function ParseShiftExpr: TAstExpr;
    function ParseAddExpr: TAstExpr;
    function ParseMulExpr: TAstExpr;
    function ParseUnaryExpr: TAstExpr;
    function ParsePrimary: TAstExpr;
    function ParseCallOrIdent: TAstExpr;
    function ParsePostfix(base: TAstExpr): TAstExpr;


    function ParseTypeEx(out arrayLen: Integer; out typeName: string): TAurumType;
    function ParseTypeExFull(out arrayLen: Integer; out typeName: string; out isNullable: Boolean): TAurumType;
    function ParseType: TAurumType;
    function ParseParamList: TAstParamList;
    function ParseEnergyAttr: TEnergyLevel; // Energy-Aware-Compiling Attribut parsen
  public
    constructor Create(lexer: TLexer; diag: TDiagnostics);
    destructor Destroy; override;

    function ParseProgram: TAstProgram;
  end;

implementation

{ Helpers }

procedure TParser.Advance;
begin
  FCurTok := FLexer.NextToken;
  FHasCur := True;
end;

function TParser.Check(kind: TTokenKind): Boolean;
begin
  // Ensure token is present (constructor preloads)
  Result := FCurTok.Kind = kind;
end;

function TParser.Accept(kind: TTokenKind): Boolean;
begin
  if FCurTok.Kind = kind then
  begin
    Advance;
    Exit(True);
  end;
  Result := False;
end;

procedure TParser.Expect(kind: TTokenKind);
begin
  if not Accept(kind) then
  begin
    FDiag.Error(Format('expected token %s but got %s', [TokenKindToStr(kind), TokenKindToStr(FCurTok.Kind)]), FCurTok.Span);
    // try to continue: advance once
    Advance;
  end;
end;

function TParser.ParseVisibility: TVisibility;
begin
  Result := visPublic; // default
  if Accept(tkPrivate) then
    Result := visPrivate
  else if Accept(tkProtected) then
    Result := visProtected
  else if Accept(tkPublic) then
    Result := visPublic;
end;

{ Parsing }

constructor TParser.Create(lexer: TLexer; diag: TDiagnostics);
begin
  inherited Create;
  FLexer := lexer;
  FDiag := diag;
  FHasCur := True;
  Advance; // load first token
end;

destructor TParser.Destroy;
begin
  inherited Destroy;
end;

function TParser.ParseProgram: TAstProgram;
var
  decls: TAstNodeList;
  d: TAstNode;
  // importC local vars
  cHeaderFile: string;
  cLinkName: string;
  cParser: TCHeaderParser;
  cResult: TCHeaderParseResult;
  cFn: TCFunctionDecl;
  cFuncDecl: TAstFuncDecl;
  cParams: TAstParamList;
  cRetType: TAurumType;
  cLyxType: string;
  pi: Integer;
begin
  decls := nil;
  // optional unit declaration
  if Check(tkUnit) then
  begin
    d := ParseUnitDecl;
    if d <> nil then
    begin
      SetLength(decls, Length(decls) + 1);
      decls[High(decls)] := d;
    end;
  end;

  // Impliziter Import von std.system (Auto-Injection)
  d := TAstImportDecl.Create('std.system', '', nil, MakeSpan(1,1,0,''));
  SetLength(decls, Length(decls) + 1);
  decls[High(decls)] := d;

  // import declarations
  while Check(tkImport) do
  begin
    d := ParseImportDecl;
    if d <> nil then
    begin
      SetLength(decls, Length(decls) + 1);
      decls[High(decls)] := d;
    end;
  end;
  // top-level declarations
  while True do
  begin
    if Check(tkEOF) then Break;

    // importC "header.h" link "libname"; — C FFI header import
    if Check(tkIdent) and (FCurTok.Value = 'importC') then
    begin
      Advance;
      cHeaderFile := '';
      cLinkName := '';
      if Check(tkStrLit) then begin cHeaderFile := FCurTok.Value; Advance; end
      else FDiag.Error('expected header path string after importC', FCurTok.Span);
      if Check(tkIdent) and (FCurTok.Value = 'link') then
      begin
        Advance;
        if Check(tkStrLit) then begin cLinkName := FCurTok.Value; Advance; end
        else FDiag.Error('expected library name after link', FCurTok.Span);
      end;
      if Check(tkSemicolon) then Advance;

      if cHeaderFile <> '' then
      begin
        cParser := TCHeaderParser.Create;
        try
          if FileExists(cHeaderFile) then
            cResult := cParser.ParseFile(cHeaderFile)
          else
          begin
            // Try system include paths
            if FileExists('/usr/include/' + cHeaderFile) then
              cResult := cParser.ParseFile('/usr/include/' + cHeaderFile)
            else if FileExists('/usr/local/include/' + cHeaderFile) then
              cResult := cParser.ParseFile('/usr/local/include/' + cHeaderFile)
            else
            begin
              FDiag.Error('importC: header not found: ' + cHeaderFile, FCurTok.Span);
              cResult.Functions := nil;
              cResult.OpaqueTypes := TStringList.Create;
            end;
          end;

          for cFn in cResult.Functions do
          begin
            if cFn.IsStatic then Continue; // skip static inline
            // Build param list
            SetLength(cParams, Length(cFn.Params));
            for pi := 0 to High(cFn.Params) do
            begin
              cLyxType := MapCTypeToLyx(cFn.Params[pi].CType);
              cParams[pi].Name := cFn.Params[pi].Name;
              if cParams[pi].Name = '' then
                cParams[pi].Name := 'p' + IntToStr(pi);
              cParams[pi].ParamType := StrToAurumType(cLyxType);
              cParams[pi].TypeName := cLyxType;
            end;
            // Map return type
            cLyxType := MapCTypeToLyx(cFn.ReturnType);
            cRetType := StrToAurumType(cLyxType);
            // Create extern fn declaration
            cFuncDecl := TAstFuncDecl.Create(cFn.Name, cParams, cRetType,
              nil, FCurTok.Span, False);
            cFuncDecl.IsExtern := True;
            cFuncDecl.IsVarArgs := cFn.IsVariadic;
            cFuncDecl.LibraryName := cLinkName;
            SetLength(decls, Length(decls) + 1);
            decls[High(decls)] := cFuncDecl;
          end;
          cResult.OpaqueTypes.Free;
        finally
          cParser.Free;
        end;
      end;
      Continue;
    end;

    d := ParseTopDecl;
    if d <> nil then
    begin
      SetLength(decls, Length(decls) + 1);
      decls[High(decls)] := d;
    end
    else
      // Skip token to avoid infinite loop
      Advance;
  end;
  Result := TAstProgram.Create(decls, MakeSpan(1,1,0,''));
end;

function TParser.ParseTopDecl: TAstNode;
var
  isExtern: Boolean;
  name: string;
  params: TAstParamList;
  retType: TAurumType;
  linkName: string;
begin
  isExtern := False;
  if Check(tkPublic) then
  begin
    Advance; // consume 'public'
    if Check(tkFn) then
      Exit(ParseFuncDecl(True))
    else if Check(tkCon) then
      Exit(ParseConDecl(True))
    else if Check(tkType) then
      Exit(ParseTypeDecl(True))
    else if Check(tkEnum) then
      Exit(ParseEnumDecl(True))
    else if Check(tkVar) or Check(tkLet) then
      Exit(ParseGlobalVarDecl(True))
    else
    begin
      FDiag.Error('expected fn, con, type, enum, var or let after pub', FCurTok.Span);
      Exit(nil);
    end;
  end;
  // support 'extern fn ... ;' top-level declarations
  if Check(tkExtern) then
  begin
    isExtern := True;
    Advance;
  end;
  if isExtern then
  begin
    if Check(tkFn) then
    begin
      // parse function signature without body
      Expect(tkFn);
      // reuse ParseFuncDecl for name/params/retType parsing by peeking and backtracking is complex
      // Instead, parse inline here
      if Check(tkIdent) then
      begin
        name := FCurTok.Value; Advance;
      end
      else
      begin
        name := '<anon>'; FDiag.Error('expected function name', FCurTok.Span);
      end;
      Expect(tkLParen);
      if not Check(tkRParen) then
        params := ParseParamList
      else
        params := nil;
      Expect(tkRParen);
      if Accept(tkColon) then
        retType := ParseType
      else
        retType := atVoid;
      // Optional: link "libname" annotation
      linkName := '';
      if Check(tkIdent) and (FCurTok.Value = 'link') then
      begin
        Advance;
        if Check(tkStrLit) then
        begin
          linkName := FCurTok.Value;
          Advance;
        end
        else
          FDiag.Error('expected library name string after link', FCurTok.Span);
      end;
      Expect(tkSemicolon);
      Result := TAstFuncDecl.Create(name, params, retType, nil, FCurTok.Span, False);
      // mark extern and varargs if parser recorded them
      TAstFuncDecl(Result).IsExtern := True;
      TAstFuncDecl(Result).IsVarArgs := FLastParamListVarArgs;
      TAstFuncDecl(Result).LibraryName := linkName;
      Exit(Result);
    end
    else
    begin
      FDiag.Error('expected fn after extern', FCurTok.Span);
      Exit(nil);
    end;
  end;
  if Check(tkFn) then
    Exit(ParseFuncDecl(False));
  // @energy(level) Attribut vor Funktion
  if Check(tkAt) then
  begin
    // Peek next token to see if it's @energy followed by fn
    // For now, just try parsing as function (ParseFuncDecl handles @energy)
    Exit(ParseFuncDecl(False));
  end;
  if Check(tkCon) then
    Exit(ParseConDecl(False));
  if Check(tkEnum) then
    Exit(ParseEnumDecl(False));
  if Check(tkType) then
    Exit(ParseTypeDecl(False));
  // Global variables: var/let at top-level
  if Check(tkVar) or Check(tkLet) then
    Exit(ParseGlobalVarDecl(False));
  // unexpected top-level
  FDiag.Error('unexpected top-level declaration', FCurTok.Span);
  Result := nil;
end;

function TParser.ParseFuncDecl(isPub: Boolean): TAstFuncDecl;
var
  name: string;
  params: TAstParamList;
  retType: TAurumType;
  retTypeName: string;
  body: TAstBlock;
  arrLen: Integer;
  energyLevel: TEnergyLevel;
  savedTypeParams: TStringArray;
  typeParams: TStringArray;
begin
  // @energy(level) Attribut parsen, falls vorhanden
  energyLevel := ParseEnergyAttr;

  // fn
  Expect(tkFn);
  if Check(tkIdent) then
  begin
    name := FCurTok.Value;
    Advance;
  end
  else
  begin
    name := '<anon>';
    FDiag.Error('expected function name', FCurTok.Span);
  end;

  // Optional generic type params: fn name[T] or fn name[T, U]
  savedTypeParams := FCurrentTypeParams;
  SetLength(typeParams, 0);
  if Check(tkLBracket) then
  begin
    Advance; // consume '['
    if Check(tkIdent) then
    begin
      repeat
        SetLength(typeParams, Length(typeParams) + 1);
        typeParams[High(typeParams)] := FCurTok.Value;
        Advance;
      until not Accept(tkComma);
    end;
    Expect(tkRBracket);
    FCurrentTypeParams := typeParams;
  end
  else
    SetLength(FCurrentTypeParams, 0);

  // (
  Expect(tkLParen);
  if not Check(tkRParen) then
    params := ParseParamList
  else
    params := nil;
  Expect(tkRParen);

  // optional : RetType
  retTypeName := '';
  if Accept(tkColon) then
  begin
    retType := ParseTypeEx(arrLen, retTypeName);
  end
  else
    retType := atVoid; // default

  body := ParseBlock;
  Result := TAstFuncDecl.Create(name, params, retType, body, FCurTok.Span, isPub);
  Result.ReturnTypeName := retTypeName;
  Result.EnergyLevel := energyLevel;
  Result.TypeParams := typeParams;
  // Restore type params context after parsing the function
  FCurrentTypeParams := savedTypeParams;
end;

function TParser.ParseConDecl(isPub: Boolean): TAstConDecl;
var
  name: string;
  declType: TAurumType;
  initExpr: TAstExpr;
begin
  Expect(tkCon);
  if Check(tkIdent) then
  begin
    name := FCurTok.Value;
    Advance;
  end
  else
  begin
    name := '<anon>';
    FDiag.Error('expected constant name', FCurTok.Span);
  end;
  Expect(tkColon);
  declType := ParseType;
  Expect(tkAssign); // ':='
  initExpr := ParseExpr; // ConstExpr restriction checked in sema
  Expect(tkSemicolon);
  Result := TAstConDecl.Create(name, declType, initExpr, FCurTok.Span, isPub, skCo);
end;

function TParser.ParseEnumDecl(isPub: Boolean): TAstEnumDecl;
// Syntax:
//   [pub] enum Name {
//     VALUE1;           // auto-value: 0, 1, 2, ...
//     VALUE2 := expr;   // explicit value
//   };
var
  ename:    string;
  values:   TEnumValueList;
  valName:  string;
  nextVal:  Int64;
  initExpr: TAstExpr;
  span:     TSourceSpan;
begin
  span := FCurTok.Span;
  Expect(tkEnum);
  if Check(tkIdent) then
  begin
    ename := FCurTok.Value;
    Advance;
  end
  else
  begin
    ename := '<anon>';
    FDiag.Error('expected enum name', FCurTok.Span);
  end;
  Expect(tkLBrace);
  SetLength(values, 0);
  nextVal := 0;
  while not Check(tkRBrace) and not Check(tkEOF) do
  begin
    if not Check(tkIdent) then
    begin
      FDiag.Error('expected enum value name', FCurTok.Span);
      Break;
    end;
    valName := FCurTok.Value;
    Advance;
    if Accept(tkAssign) then
    begin
      initExpr := ParseExpr;
      if initExpr is TAstIntLit then
      begin
        nextVal := TAstIntLit(initExpr).Value;
        initExpr.Free;
      end
      else
      begin
        FDiag.Error('enum value must be an integer literal', initExpr.Span);
        initExpr.Free;
      end;
    end;
    SetLength(values, Length(values) + 1);
    values[High(values)].Name  := valName;
    values[High(values)].Value := nextVal;
    Inc(nextVal);
    Expect(tkSemicolon);
  end;
  Expect(tkRBrace);
  Expect(tkSemicolon);
  Result := TAstEnumDecl.Create(ename, values, isPub, span);
end;

function TParser.ParseTypeDecl(isPub: Boolean): TAstNode;
var
  name: string;
  declType: TAurumType;
  fields: TStructFieldList;
  methods: TMethodList;
  fld: TStructField;
  m: TAstFuncDecl;
  fldTypeName: string;
  mName: string;
  mParams: TAstParamList;
  mRetType: TAurumType;
  mRetTypeName: string;
  mBody: TAstBlock;
  dummy: Integer;
  isStatic: Boolean;
  isVirtual: Boolean;
  isOverride: Boolean;
  isAbstract: Boolean;
  baseClassName: string;
  implInterfaces: TStringArray;
  curVisibility: TVisibility;
  constraintExpr: TAstExpr;
begin
  Expect(tkType);
  if Check(tkIdent) then
  begin
    name := FCurTok.Value;
    Advance;
  end
  else
  begin
    name := '<anon>';
    FDiag.Error('expected type name', FCurTok.Span);
  end;
  // '=' or ':=' (both are valid for type declarations)
  if Check(tkSingleEq) or Check(tkAssign) then
    Advance
  else
  begin
    FDiag.Error('expected ''='' in type declaration', FCurTok.Span);
  end;

  // Interface IName { ... }
  if Check(tkInterface) then
  begin
    Advance; // interface
    // Parse interface method signatures (no body)
    methods := nil;
    while not Check(tkRBrace) and not Check(tkEOF) do
    begin
      // Method signature: fn name(params): retType;
      if Check(tkFn) then
      begin
        Advance; // fn
        if Check(tkIdent) then
        begin
          mName := FCurTok.Value;
          Advance;
        end
        else
        begin
          mName := '<anon>';
          FDiag.Error('expected method name', FCurTok.Span);
        end;
        Expect(tkLParen);
        mParams := nil;
        if not Check(tkRParen) then
          mParams := ParseParamList
        else
          mParams := nil;
        Expect(tkRParen);
        mRetTypeName := '';
        mRetType := atVoid;
        if Accept(tkColon) then
          mRetType := ParseTypeEx(dummy, mRetTypeName);
        // Interface methods have no body - they end with ;
        Expect(tkSemicolon);
        m := TAstFuncDecl.Create(mName, mParams, mRetType, nil, FCurTok.Span, False);
        m.ReturnTypeName := mRetTypeName;
        SetLength(methods, Length(methods) + 1);
        methods[High(methods)] := m;
      end
      else
      begin
        FDiag.Error('expected method signature in interface', FCurTok.Span);
        Advance;
      end;
    end;
    Expect(tkRBrace);
    Expect(tkSemicolon);
    Result := TAstInterfaceDecl.Create(name, methods, isPub, FCurTok.Span);
    Exit;
  end
  // class [extends BaseClass] [implements IName] { ... }
  else if Check(tkClass) then
  begin
    // class [extends BaseClass] [implements IName] { ... }
    Advance; // class
    baseClassName := '';
    SetLength(implInterfaces, 0);
    // Check for extends
    if Check(tkExtends) then
    begin
      Advance; // extends
      if Check(tkIdent) then
      begin
        baseClassName := FCurTok.Value;
        Advance;
      end
      else
        FDiag.Error('expected base class name after ''extends''', FCurTok.Span);
    end
    else
    begin
      // No explicit inheritance: automatically inherit from TObject
      baseClassName := 'TObject';
    end;
    // Check for implements
    if Check(tkImplements) then
    begin
      Advance; // implements
      // Parse interface names
      while Check(tkIdent) do
      begin
        SetLength(implInterfaces, Length(implInterfaces) + 1);
        implInterfaces[High(implInterfaces)] := FCurTok.Value;
        Advance;
        if Check(tkComma) then
          Advance  // consume comma
        else
          Break;
      end;
    end;
    // Now expect class body
    Expect(tkLBrace);
    fields := nil;
    methods := nil;
    while not Check(tkRBrace) and not Check(tkEOF) do
    begin
      // parse optional visibility modifier
      curVisibility := ParseVisibility;
      if Check(tkFn) or Check(tkStatic) or Check(tkVirtual) or Check(tkOverride) or Check(tkAbstract) then
      begin
        // parse method declaration
        // Modifier order: [static] [virtual|override|abstract] fn name(...)
        isStatic := Accept(tkStatic);
        isVirtual := Accept(tkVirtual);
        isOverride := Accept(tkOverride);
        isAbstract := Accept(tkAbstract);
        // abstract implies virtual
        if isAbstract then
          isVirtual := True;
        // After modifiers, we expect fn
        if not Check(tkFn) then
        begin
          FDiag.Error('expected ''fn'' keyword after modifiers', FCurTok.Span);
        end;
        Expect(tkFn);
        // Method name can be: identifier, 'new' (constructor), or 'dispose' (destructor)
        if Check(tkIdent) or Check(tkNew) or Check(tkDispose) then
        begin
          mName := FCurTok.Value;
          Advance;
        end
        else
        begin
          mName := '<anon>';
          FDiag.Error('expected method name', FCurTok.Span);
        end;
        Expect(tkLParen);
        if not Check(tkRParen) then
          mParams := ParseParamList
        else
          mParams := nil;
        Expect(tkRParen);
        mRetTypeName := '';
        if Accept(tkColon) then
          mRetType := ParseTypeEx(dummy, mRetTypeName)
        else
          mRetType := atVoid;
        // Abstract methods have no body - they end with ;
        if isAbstract then
        begin
          if not Check(tkSemicolon) then
            FDiag.Error('abstract method must not have a body', FCurTok.Span)
          else
            Advance;
          mBody := nil;
        end
        else
          mBody := ParseBlock;
        m := TAstFuncDecl.Create(mName, mParams, mRetType, mBody, FCurTok.Span, False);
        m.ReturnTypeName := mRetTypeName;
        m.IsStatic := isStatic;
        m.IsVirtual := isVirtual;
        m.IsOverride := isOverride;
        m.IsAbstract := isAbstract;
        m.Visibility := curVisibility;
        // Constructor/Destructor detection
        if (mName = 'new') or (mName = 'Create') then
          m.IsConstructor := True
        else if (mName = 'dispose') or (mName = 'Destroy') then
          m.IsDestructor := True;
        SetLength(methods, Length(methods) + 1);
        methods[High(methods)] := m;
      end
      else if Check(tkIdent) then
      begin
        // field: name : Type ;
        fld.Name := FCurTok.Value; Advance;
        Expect(tkColon);
        fld.FieldType := ParseTypeEx(fld.ArrayLen, fldTypeName);
        fld.FieldTypeName := fldTypeName;
        fld.Visibility := curVisibility;
        Expect(tkSemicolon);
        SetLength(fields, Length(fields) + 1);
        fields[High(fields)] := fld;
      end
      else
      begin
        FDiag.Error('unexpected token in class body', FCurTok.Span);
        Advance;
      end;
    end;
    Expect(tkRBrace);
    Expect(tkSemicolon);
    Result := TAstClassDecl.Create(name, baseClassName, fields, methods, isPub, FCurTok.Span);
    // Set implemented interfaces
    TAstClassDecl(Result).ImplementedInterfaces := implInterfaces;
    Exit;
  end
  // struct { ... }
  else if Check(tkStruct) then
  begin
    Advance; // struct
    Expect(tkLBrace);
    fields := nil;
    methods := nil;
    while not Check(tkRBrace) and not Check(tkEOF) do
    begin
      // Allow visibility modifiers (pub, private, protected) in structs
      curVisibility := ParseVisibility;
      if Check(tkIdent) then
      begin
        fld.Name := FCurTok.Value; Advance;
        Expect(tkColon);
        fld.FieldType := ParseTypeEx(fld.ArrayLen, fldTypeName);
        fld.FieldTypeName := fldTypeName;
        fld.Visibility := curVisibility;
        Expect(tkSemicolon);
        SetLength(fields, Length(fields) + 1);
        fields[High(fields)] := fld;
      end
      else
      begin
        FDiag.Error('expected field name in struct', FCurTok.Span);
        Advance;
      end;
    end;
    Expect(tkRBrace);
    Expect(tkSemicolon);
    Result := TAstStructDecl.Create(name, fields, methods, isPub, FCurTok.Span);
    Exit;
  end
  else
  begin
    declType := ParseType;
    // Parse optional where clause
    constraintExpr := nil;
    if Accept(tkWhere) then
    begin
      Expect(tkLBrace);
      constraintExpr := ParseExpr; // ConstExpr restriction checked in sema
      Expect(tkRBrace);
    end;
    Expect(tkSemicolon);
    Result := TAstTypeDecl.Create(name, declType, isPub, constraintExpr, FCurTok.Span);
  end;
end;

function TParser.ParseUnitDecl: TAstUnitDecl;
var
  path: string;
begin
  Expect(tkUnit);
  if Check(tkIdent) then
  begin
    path := FCurTok.Value;
    Advance;
    while Accept(tkDot) do
    begin
      if Check(tkIdent) then
      begin
        path := path + '.' + FCurTok.Value;
        Advance;
      end
      else
        FDiag.Error('expected identifier after dot in unit path', FCurTok.Span);
    end;
  end
  else
  begin
    path := '<anon>';
    FDiag.Error('expected unit name', FCurTok.Span);
  end;
  Expect(tkSemicolon);
  Result := TAstUnitDecl.Create(path, FCurTok.Span);
end;

function TParser.ParseImportDecl: TAstImportDecl;
var
  path, alias: string;
  items: TAstImportItemList;
  item: TAstImportItem;
begin
  Expect(tkImport);
  items := nil;
  alias := '';
  if Check(tkIdent) then
  begin
    path := FCurTok.Value;
    Advance;
    while Accept(tkDot) do
    begin
      if Check(tkIdent) then
      begin
        path := path + '.' + FCurTok.Value;
        Advance;
      end
      else
        FDiag.Error('expected identifier after dot in import path', FCurTok.Span);
    end;
  end
  else
  begin
    path := '<anon>';
    FDiag.Error('expected module path in import', FCurTok.Span);
  end;
  // optional 'as Alias'
  if Accept(tkAs) then
  begin
    if Check(tkIdent) then
    begin
      alias := FCurTok.Value;
      Advance;
    end
    else
      FDiag.Error('expected alias after as', FCurTok.Span);
  end;
  // optional selective import { item, item }
  if Accept(tkLBrace) then
  begin
    while not Check(tkRBrace) and not Check(tkEOF) do
    begin
      item.Alias := '';
      if Check(tkIdent) then
      begin
        item.Name := FCurTok.Value;
        Advance;
      end
      else
      begin
        item.Name := '<anon>';
        FDiag.Error('expected identifier in import list', FCurTok.Span);
      end;
      if Accept(tkAs) then
      begin
        if Check(tkIdent) then
        begin
          item.Alias := FCurTok.Value;
          Advance;
        end
        else
          FDiag.Error('expected alias after as', FCurTok.Span);
      end;
      SetLength(items, Length(items) + 1);
      items[High(items)] := item;
      if not Accept(tkComma) then Break;
    end;
    Expect(tkRBrace);
  end;
  Expect(tkSemicolon);
  Result := TAstImportDecl.Create(path, alias, items, FCurTok.Span);
end;

function TParser.ParseBlock: TAstBlock;
var
  stmts: TAstStmtList;
  s: TAstStmt;
begin
  Expect(tkLBrace);
  stmts := nil;
  while not Check(tkRBrace) and not Check(tkEOF) do
  begin
    s := ParseStmt;
    if s <> nil then
    begin
      SetLength(stmts, Length(stmts) + 1);
      stmts[High(stmts)] := s;
    end
    else
      Advance;
  end;
  Expect(tkRBrace);
  Result := TAstBlock.Create(stmts, FCurTok.Span);
end;

function TParser.ParseStmt: TAstStmt;
var
  cond: TAstExpr;
  thenStmt: TAstStmt;
  elseStmt: TAstStmt;
  bodyStmt: TAstStmt;
  vExpr: TAstExpr;
  cases: TAstCaseList;
  defaultBody: TAstStmt;
  caseObj: TAstCase;
  valExpr: TAstExpr;
  i: Integer;
begin
  if Check(tkVar) or Check(tkLet) or Check(tkCo) then
    Exit(ParseVarLetCoDecl);

  // Nested function declaration
  if Check(tkFn) then
    Exit(TAstFuncStmt.Create(ParseFuncDecl(False)));

  if Check(tkIf) then
  begin
    // if (Expr) Stmt [else Stmt]
    Advance; // if
    Expect(tkLParen);
    cond := ParseExpr;
    Expect(tkRParen);
    thenStmt := Self.ParseStmt;
    elseStmt := nil;
    if Accept(tkElse) then
      elseStmt := Self.ParseStmt;
    Exit(TAstIf.Create(cond, thenStmt, elseStmt, cond.Span));
  end;

  if Check(tkWhile) then
  begin
    Advance;
    Expect(tkLParen);
    cond := ParseExpr;
    Expect(tkRParen);
    bodyStmt := Self.ParseStmt;
    Exit(TAstWhile.Create(cond, bodyStmt, cond.Span));
  end;

  // pool { ... } - Memory Pool Block
  if Check(tkPool) then
  begin
    Advance; // pool
    Expect(tkLBrace);
    bodyStmt := ParseBlock;
    Exit(TAstPoolStmt.Create(bodyStmt, FCurTok.Span));
  end;

  // switch (expr) { case CONST: stmt ... default: stmt }
  if Check(tkSwitch) then
  begin
    Advance; // switch
    Expect(tkLParen);
    cond := ParseExpr;
    Expect(tkRParen);
    Expect(tkLBrace);
    // collect cases
    SetLength(cases, 0);
    defaultBody := nil;
    while not Check(tkRBrace) and not Check(tkEOF) do
    begin
      if Accept(tkCase) then
      begin
        // parse single const expr
        valExpr := ParseExpr;
        Expect(tkColon);
        // case body: allow either a block or a single statement
        if Check(tkLBrace) then
          bodyStmt := ParseBlock
        else
          bodyStmt := ParseStmt;
        caseObj := TAstCase.Create(valExpr, bodyStmt);
        SetLength(cases, Length(cases) + 1);
        cases[High(cases)] := caseObj;
        Continue;
      end
      else if Accept(tkDefault) then
      begin
        Expect(tkColon);
        // default body must be a block
        defaultBody := ParseBlock;
        Continue;
      end

      else
      begin
        // unexpected token inside switch
        FDiag.Error('unexpected token in switch', FCurTok.Span);
        Advance;
      end;
    end;
    Expect(tkRBrace);
    Exit(TAstSwitch.Create(cond, cases, defaultBody, cond.Span));
  end;

  if Check(tkFor) then
    Exit(ParseForStmt);

  if Check(tkRepeat) then
    Exit(ParseRepeatUntilStmt);

  if Check(tkReturn) then
  begin
    Advance;
    if Check(tkSemicolon) then
    begin
      Advance;
      Exit(TAstReturn.Create(nil, FCurTok.Span));
    end
    else
    begin
      vExpr := ParseExpr;
      if vExpr = nil then
        vExpr := TAstIntLit.Create(0, FCurTok.Span);
      Expect(tkSemicolon);
      Exit(TAstReturn.Create(vExpr, vExpr.Span));
    end;
  end;

  // break; - exit loop early
  if Check(tkBreak) then
  begin
    Advance;
    Expect(tkSemicolon);
    Exit(TAstBreak.Create(FCurTok.Span));
  end;

  // dispose expr; - free heap-allocated class instance
  if Check(tkDispose) then
  begin
    Advance; // consume 'dispose'
    vExpr := ParseExpr;
    Expect(tkSemicolon);
    Exit(TAstDispose.Create(vExpr, FCurTok.Span));
  end;

  // assert(cond, msg); - runtime assertion
  if Check(tkAssert) then
  begin
    Advance; // consume 'assert'
    Expect(tkLParen);
    cond := ParseExpr;
    Expect(tkComma);
    valExpr := ParseExpr; // reuse valExpr for message
    Expect(tkRParen);
    Expect(tkSemicolon);
    Exit(TAstAssert.Create(cond, valExpr, FCurTok.Span));
  end;

  // try { body } catch (e: int64) { handler }
  if Check(tkTry) then
    Exit(ParseTryStmt);

  // throw expr;
  if Check(tkThrow) then
  begin
    Advance; // consume 'throw'
    vExpr := ParseExpr;
    Expect(tkSemicolon);
    Exit(TAstThrow.Create(vExpr, vExpr.Span));
  end;

  if Check(tkLBrace) then
    Exit(ParseBlock);

  // Assignment or expression statement
  Exit(ParseAssignStmtOrExprStmt);
end;

function TParser.ParseVarLetCoDecl: TAstVarDecl;
var
  storage: TStorageKlass;
  name: string;
  declType: TAurumType;
  declTypeName: string;
  initExpr: TAstExpr;
  arrayLen: Integer;
  isNullable: Boolean;
  span: TSourceSpan;
begin
  span := FCurTok.Span;
  if Accept(tkVar) then storage := skVar
  else if Accept(tkLet) then storage := skLet
  else if Accept(tkCo) then storage := skCo
  else storage := skVar; // unreachable

  if Check(tkIdent) then
  begin
    name := FCurTok.Value; Advance;
  end
  else
  begin
    name := '<anon>'; FDiag.Error('expected identifier in declaration', FCurTok.Span);
  end;

  Expect(tkColon);
  declType := ParseTypeExFull(arrayLen, declTypeName, isNullable);

  // Optional initializer for const
  if Accept(tkAssign) then
    initExpr := ParseExpr
  else
    initExpr := nil;
  Expect(tkSemicolon);

  if Assigned(initExpr) then
    Result := TAstVarDecl.Create(storage, name, declType, declTypeName, arrayLen, initExpr, isNullable, initExpr.Span)
  else
    Result := TAstVarDecl.Create(storage, name, declType, declTypeName, arrayLen, initExpr, isNullable, span);
end;

function TParser.ParseGlobalVarDecl(isPub: Boolean): TAstVarDecl;
var
  storage: TStorageKlass;
  name: string;
  declType: TAurumType;
  declTypeName: string;
  initExpr: TAstExpr;
  arrayLen: Integer;
  isNullable: Boolean;
  span: TSourceSpan;
begin
  span := FCurTok.Span;
  
  if Accept(tkVar) then 
    storage := skVar
  else if Accept(tkLet) then 
    storage := skLet
  else 
  begin
    FDiag.Error('expected var or let', FCurTok.Span);
    Exit(nil);
  end;

  if Check(tkIdent) then
  begin
    name := FCurTok.Value;
    // Warnung: Klassenname sollte mit 'T' beginnen
    if (Length(name) > 0) and (name[1] <> 'T') then
      FDiag.Report(dkWarning, 'Class name ''' + name + ''' should start with ''T'' (naming convention)', FCurTok.Span);
    Advance;
  end
  else
  begin
    name := '<anon>'; 
    FDiag.Error('expected identifier in global declaration', FCurTok.Span);
  end;

  Expect(tkColon);
  declType := ParseTypeExFull(arrayLen, declTypeName, isNullable);

  // Optional initializer: var x: int64 := value or just var x: int64
  if Accept(tkAssign) then
    initExpr := ParseExpr
  else
    initExpr := nil;
  Expect(tkSemicolon);

  Result := TAstVarDecl.Create(storage, name, declType, declTypeName, arrayLen, initExpr, isNullable, span);
  Result.SetGlobal(True, isPub);
end;

function TParser.ParseForStmt: TAstFor;
var
  varName: string;
  startExpr, endExpr: TAstExpr;
  isDownto: Boolean;
  bodyStmt: TAstStmt;
  span: TSourceSpan;
begin
  span := FCurTok.Span;
  Expect(tkFor);
  if Check(tkIdent) then
  begin
    varName := FCurTok.Value;
    Advance;
  end
  else
  begin
    varName := '<anon>';
    FDiag.Error('expected loop variable name', FCurTok.Span);
  end;
  Expect(tkAssign);
  startExpr := ParseExpr;
  isDownto := False;
  if Accept(tkDownto) then
    isDownto := True
  else
    Expect(tkTo);
  endExpr := ParseExpr;
  Expect(tkDo);
  bodyStmt := Self.ParseStmt;
  Result := TAstFor.Create(varName, startExpr, endExpr, isDownto, bodyStmt, span);
end;

function TParser.ParseRepeatUntilStmt: TAstRepeatUntil;
var
  bodyBlock: TAstBlock;
  cond: TAstExpr;
  span: TSourceSpan;
begin
  span := FCurTok.Span;
  Expect(tkRepeat);
  bodyBlock := ParseBlock;
  Expect(tkUntil);
  cond := ParseExpr;
  Expect(tkSemicolon);
  Result := TAstRepeatUntil.Create(bodyBlock, cond, span);
end;

function TParser.ParseTryStmt: TAstTry;
// try { body } catch (varName: int64) { handler }
var
  tryBody:    TAstStmt;
  catchVar:   string;
  catchBody:  TAstStmt;
  span:       TSourceSpan;
  dummyLen:   Integer;
  dummyName:  string;
  dummyNull:  Boolean;
begin
  span := FCurTok.Span;
  Expect(tkTry);
  tryBody := ParseBlock;
  Expect(tkCatch);
  Expect(tkLParen);
  // catch variable name
  if Check(tkIdent) then
  begin
    catchVar := FCurTok.Value;
    Advance;
  end
  else
  begin
    catchVar := '_e';
    FDiag.Error('expected identifier in catch clause', FCurTok.Span);
  end;
  // type annotation (: int64) — consume but ignore
  if Accept(tkColon) then
    ParseTypeExFull(dummyLen, dummyName, dummyNull);
  Expect(tkRParen);
  catchBody := ParseBlock;
  Result := TAstTry.Create(tryBody, catchVar, catchBody, span);
end;

function TParser.ParseAssignStmtOrExprStmt: TAstStmt;
var
  expr: TAstExpr;
  name: string;
  valExpr: TAstExpr;
  fa: TAstFieldAccess;
  objExpr: TAstExpr;
  fieldName: string;
  incExpr: TAstBinOp;
begin
  expr := ParseExpr;
  // Assignment pattern: ident := expr ;
  // (for now, only simple ident assignment; field/index LValues parsed but not assignable yet)
  if (expr is TAstIdent) and Check(tkAssign) then
  begin
    name := TAstIdent(expr).Name;
    Advance; // consume ':='
    valExpr := ParseExpr;
    Expect(tkSemicolon);
    // free ident node
    expr.Free;
    Exit(TAstAssign.Create(name, valExpr, valExpr.Span));
  end
  else if (expr is TAstIdent) and Check(tkPlusPlus) then
  begin
    // Increment: ident++ -> ident := ident + 1
    name := TAstIdent(expr).Name;
    Advance; // consume '++'
    Expect(tkSemicolon);
    expr.Free;
    // Build: name := name + 1
    incExpr := TAstBinOp.Create(tkPlus, TAstIdent.Create(name, expr.Span), TAstIntLit.Create(1, expr.Span), expr.Span);
    Exit(TAstAssign.Create(name, incExpr, expr.Span));
  end
  else if (expr is TAstIdent) and Check(tkMinusMinus) then
  begin
    // Decrement: ident-- -> ident := ident - 1
    name := TAstIdent(expr).Name;
    Advance; // consume '--'
    Expect(tkSemicolon);
    expr.Free;
    // Build: name := name - 1
    incExpr := TAstBinOp.Create(tkMinus, TAstIdent.Create(name, expr.Span), TAstIntLit.Create(1, expr.Span), expr.Span);
    Exit(TAstAssign.Create(name, incExpr, expr.Span));
  end
  else if (expr is TAstFieldAccess) and Check(tkAssign) then
  begin
    // Field assignment: obj.field := value
    Advance; // consume ':='
    valExpr := ParseExpr;
    Expect(tkSemicolon);
    // create field-assign node using the existing field-access AST as target
    fa := TAstFieldAccess(expr);
    Exit(TAstFieldAssign.Create(fa, valExpr, valExpr.Span));
  end
  else if (expr is TAstFieldAccess) and Check(tkPlusPlus) then
  begin
    // Field increment: obj.field++ -> obj.field := obj.field + 1
    Advance; // consume '++'
    Expect(tkSemicolon);
    fa := TAstFieldAccess(expr);
    incExpr := TAstBinOp.Create(tkPlus, TAstFieldAccess.Create(fa.Obj, fa.Field, fa.Span), TAstIntLit.Create(1, fa.Span), fa.Span);
    Exit(TAstFieldAssign.Create(fa, incExpr, fa.Span));
  end
  else if (expr is TAstFieldAccess) and Check(tkMinusMinus) then
  begin
    // Field decrement: obj.field-- -> obj.field := obj.field - 1
    Advance; // consume '--'
    Expect(tkSemicolon);
    fa := TAstFieldAccess(expr);
    incExpr := TAstBinOp.Create(tkMinus, TAstFieldAccess.Create(fa.Obj, fa.Field, fa.Span), TAstIntLit.Create(1, fa.Span), fa.Span);
    Exit(TAstFieldAssign.Create(fa, incExpr, fa.Span));
  end
  else if (expr is TAstIndexAccess) and Check(tkAssign) then
  begin
    // Index assignment: arr[idx] := value
    Advance; // consume ':='
    valExpr := ParseExpr;
    Expect(tkSemicolon);
    // create index-assign node using the existing index-access AST as target
    Exit(TAstIndexAssign.Create(TAstIndexAccess(expr), valExpr, valExpr.Span));
  end
  else if (expr is TAstIndexAccess) and Check(tkPlusPlus) then
  begin
    // Index increment: arr[idx]++ -> arr[idx] := arr[idx] + 1
    Advance; // consume '++'
    Expect(tkSemicolon);
    // Build NEW arr[idx] := arr[idx] + 1
    // Don't free old expression, use it one
    incExpr := TAstBinOp.Create(tkPlus, TAstIndexAccess.Create(TAstIndexAccess(expr).Obj, TAstIndexAccess(expr).Index, expr.Span), TAstIntLit.Create(1, expr.Span), expr.Span);
    Exit(TAstIndexAssign.Create(TAstIndexAccess(expr), incExpr, expr.Span));
  end
  else if (expr is TAstIndexAccess) and Check(tkMinusMinus) then
  begin
    // Index decrement: arr[idx]-- -> arr[idx] := arr[idx] - 1
    Advance; // consume '--'
    Expect(tkSemicolon);
    // Build new arr[idx] := arr[idx] - 1
    // Don't free old expression, use the one
    incExpr := TAstBinOp.Create(tkMinus, TAstIndexAccess.Create(TAstIndexAccess(expr).Obj, TAstIndexAccess(expr).Index, expr.Span), TAstIntLit.Create(1, expr.Span), expr.Span);
    Exit(TAstIndexAssign.Create(TAstIndexAccess(expr), incExpr, expr.Span));
  end
  else
  begin
    Expect(tkSemicolon);
    Exit(TAstExprStmt.Create(expr, expr.Span));
  end;
  end;

{ Expressions }

function TParser.ParseExpr: TAstExpr;
begin
  Result := ParsePipeExpr;
end;

function TParser.ParsePipeExpr: TAstExpr;
var
  funcName: string;
  args, newArgs: TAstExprList;
  i: Integer;
  span: TSourceSpan;
begin
  Result := ParseNullCoalesceExpr;
  while Accept(tkPipe) do
  begin
    span := FCurTok.Span;
    // Nach |> muss ein Ident oder ein Call kommen
    if Check(tkIdent) then
    begin
      funcName := FCurTok.Value;
      Advance;
      
      // Prüfen ob es ein Call ist (mit Klammern)
      if Accept(tkLParen) then
      begin
        // Parse Argumente
        args := nil;
        if not Check(tkRParen) then
        begin
          while True do
          begin
            SetLength(args, Length(args) + 1);
            args[High(args)] := ParseExpr;
            if Accept(tkComma) then Continue;
            Break;
          end;
        end;
        Expect(tkRParen);
        
        // Desugar: expr |> func(a, b) -> func(expr, a, b)
        SetLength(newArgs, Length(args) + 1);
        newArgs[0] := Result;  // Pipe-Ergebnis als erstes Argument
        for i := 0 to High(args) do
          newArgs[i + 1] := args[i];
        
        Result := TAstCall.Create(funcName, newArgs, span);
      end
      else
      begin
        // Desugar: expr |> func -> func(expr)
        SetLength(newArgs, 1);
        newArgs[0] := Result;
        Result := TAstCall.Create(funcName, newArgs, span);
      end;
    end
    else
    begin
      FDiag.Error('expected function name after |>', span);
      Exit;
    end;
  end;
end;

function TParser.ParseNullCoalesceExpr: TAstExpr;
var
  rhs: TAstExpr;
begin
  Result := ParseOrExpr;
  while Accept(tkNullCoalesce) do
  begin
    rhs := ParseOrExpr;
    Result := TAstBinOp.Create(tkNullCoalesce, Result, rhs, Result.Span);
  end;
end;

function TParser.ParseOrExpr: TAstExpr;
var
  rhs: TAstExpr;
begin
  Result := ParseAndExpr;
  while Accept(tkOr) do
  begin
    rhs := ParseAndExpr;
    Result := TAstBinOp.Create(tkOr, Result, rhs, Result.Span);
  end;
end;

function TParser.ParseAndExpr: TAstExpr;
var
  rhs: TAstExpr;
begin
  Result := ParseBitOrExpr;
  while Accept(tkAnd) do
  begin
    rhs := ParseBitOrExpr;
    Result := TAstBinOp.Create(tkAnd, Result, rhs, Result.Span);
  end;
end;

function TParser.ParseBitOrExpr: TAstExpr;
var
  rhs: TAstExpr;
begin
  Result := ParseBitXorExpr;
  while Accept(tkBitOr) do
  begin
    rhs := ParseBitXorExpr;
    Result := TAstBinOp.Create(tkBitOr, Result, rhs, Result.Span);
  end;
end;

function TParser.ParseBitXorExpr: TAstExpr;
var
  rhs: TAstExpr;
begin
  Result := ParseBitAndExpr;
  while Accept(tkBitXor) do
  begin
    rhs := ParseBitAndExpr;
    Result := TAstBinOp.Create(tkBitXor, Result, rhs, Result.Span);
  end;
end;

function TParser.ParseBitAndExpr: TAstExpr;
var
  rhs: TAstExpr;
begin
  Result := ParseCmpExpr;
  while Accept(tkBitAnd) do
  begin
    rhs := ParseCmpExpr;
    Result := TAstBinOp.Create(tkBitAnd, Result, rhs, Result.Span);
  end;
end;

function TParser.ParseCmpExpr: TAstExpr;
var
  op: TTokenKind;
  rhs: TAstExpr;
  targetClassName: string;
begin
  Result := ParseShiftExpr;
  
  if Result = nil then Exit(nil);

  // "is" Operator für Laufzeit-Typprüfung
  if Check(tkIs) then
  begin
    Advance; // consume 'is'
    if not (FCurTok.Kind = tkIdent) then
    begin
      FDiag.Error('erwartete Klassenname nach is', FCurTok.Span);
      Exit(nil);
    end;
    targetClassName := FCurTok.Value;
    Advance; // consume class name
    Result := TAstIsExpr.Create(Result, targetClassName, Result.Span);
  end
  // "in" Operator für Map/Set Containment-Check
  else if Check(tkIn) then
  begin
    Advance;
    rhs := ParseShiftExpr;
    Result := TAstInExpr.Create(Result, rhs, Result.Span);
  end
  else if Check(tkEq) or Check(tkNeq) or Check(tkLt) or Check(tkLe) or Check(tkGt) or Check(tkGe) then
  begin
    op := FCurTok.Kind; Advance;
    rhs := ParseShiftExpr;
    Result := TAstBinOp.Create(op, Result, rhs, Result.Span);
  end;
end;

function TParser.ParseShiftExpr: TAstExpr;
var
  op: TTokenKind;
  rhs: TAstExpr;
begin
  Result := ParseAddExpr;
  while Check(tkShiftLeft) or Check(tkShiftRight) do
  begin
    op := FCurTok.Kind; Advance;
    rhs := ParseAddExpr;
    Result := TAstBinOp.Create(op, Result, rhs, Result.Span);
  end;
end;

function TParser.ParseAddExpr: TAstExpr;
var
  op: TTokenKind;
  rhs: TAstExpr;
begin
  Result := ParseMulExpr;
  if Result = nil then Exit(nil);
  while Check(tkPlus) or Check(tkMinus) do
  begin
    op := FCurTok.Kind; Advance;
    rhs := ParseMulExpr;
    if rhs = nil then Exit(nil);
    Result := TAstBinOp.Create(op, Result, rhs, Result.Span);
  end;
end;

function TParser.ParseMulExpr: TAstExpr;
var
  op: TTokenKind;
  rhs: TAstExpr;
begin
  Result := ParseUnaryExpr;
  if Result = nil then Exit(nil);
  while Check(tkStar) or Check(tkSlash) or Check(tkPercent) do
  begin
    op := FCurTok.Kind; Advance;
    rhs := ParseUnaryExpr;
    if rhs = nil then Exit(nil);
    Result := TAstBinOp.Create(op, Result, rhs, Result.Span);
  end;
end;

function TParser.ParseUnaryExpr: TAstExpr;
var
  ops: array of TTokenKind;
  op: TTokenKind;
  i: Integer;
  value: Int64;
  boolVal: Boolean;
  span: TSourceSpan;
begin
    // Collect consecutive prefix unary operators (e.g. - - ! ! ~ ~)
  while Check(tkMinus) or Check(tkNot) or Check(tkMinusMinus) or Check(tkBitNot) do
  begin
    if Check(tkMinusMinus) then
    begin
      // Treat -- as two consecutive unary minus operators
      SetLength(ops, Length(ops) + 2);
      ops[High(ops) - 1] := tkMinus;
      ops[High(ops)] := tkMinus;
    end
    else
    begin
      SetLength(ops, Length(ops) + 1);
      ops[High(ops)] := FCurTok.Kind;
    end;
    Advance;
  end;

  // Parse the primary expression (operand)
  Result := ParsePrimary;
  if Result = nil then Exit(nil);

  // Apply collected unary operators from right to left
  for i := High(ops) downto 0 do
  begin
    op := ops[i];
    if op = tkMinus then
    begin
      if Result is TAstIntLit then
      begin
        value := -TAstIntLit(Result).Value;
        span := Result.Span;
        Result.Free;
        Result := TAstIntLit.Create(value, span);
      end
      else
      begin
        Result := TAstUnaryOp.Create(tkMinus, Result, Result.Span);
      end;
    end
    else if op = tkNot then
    begin
      if Result is TAstBoolLit then
      begin
        boolVal := not TAstBoolLit(Result).Value;
        span := Result.Span;
        Result.Free;
        Result := TAstBoolLit.Create(boolVal, span);
      end
      else
      begin
        Result := TAstUnaryOp.Create(tkNot, Result, Result.Span);
      end;
    end
    else if op = tkBitNot then
    begin
      Result := TAstUnaryOp.Create(tkBitNot, Result, Result.Span);
    end;
  end;
end;

function TParser.ParsePrimary: TAstExpr;
var
  v: Int64;
  span: TSourceSpan;
  s: string;
  name: string;
  mName: string;
  b: Boolean;
  e: TAstExpr;
  a: TAstExpr;
  dummy: TAstIntLit;
  items: TAstExprList;
  args: TAstExprList;
  firstExpr: TAstExpr;
  mapEntries: TMapEntryList;
begin
  if Check(tkIntLit) then
  begin
    v := StrToInt64Def(FCurTok.Value, 0);
    span := FCurTok.Span;
    Advance;
    Exit(ParsePostfix(TAstIntLit.Create(v, span)));
  end;

  if Check(tkFloatLit) then
  begin
    span := FCurTok.Span;
    // Parse als Double
    s := FCurTok.Value;
    Advance;
    Exit(ParsePostfix(TAstFloatLit.Create(StrToFloat(s), span)));
  end;

  if Check(tkStrLit) then
  begin
    s := FCurTok.Value;
    span := FCurTok.Span;
    Advance;
    Exit(ParsePostfix(TAstStrLit.Create(s, span)));
  end;

  if Check(tkCharLit) then
  begin
    span := FCurTok.Span;
    if Length(FCurTok.Value) > 0 then
      Result := TAstCharLit.Create(FCurTok.Value[1], span)
    else
      Result := TAstCharLit.Create(#0, span);
    Advance;
    Exit(ParsePostfix(Result));
  end;

  if Check(tkRegexLit) then
  begin
    span := FCurTok.Span;
    Result := TAstRegexLit.Create(FCurTok.Value, span);
    Advance;
    Exit(ParsePostfix(Result));
  end;

  if Check(tkTrue) or Check(tkFalse) then
  begin
    b := Check(tkTrue);
    span := FCurTok.Span;
    Advance;
    Exit(ParsePostfix(TAstBoolLit.Create(b, span)));
  end;

  // null literal for nullable pointers
  if Check(tkNull) then
  begin
    span := FCurTok.Span;
    Advance;
    Exit(ParsePostfix(TAstIntLit.Create(0, span))); // null as integer 0 (pointer representation)
  end;

  if Check(tkIdent) then
    Exit(ParseCallOrIdent);

  // new ClassName() - heap allocation for classes
  if Check(tkNew) then
  begin
    Advance; // consume 'new'
    if not Check(tkIdent) then
    begin
      FDiag.Error('expected class name after ''new''', FCurTok.Span);
      Exit(TAstIntLit.Create(0, FCurTok.Span)); // dummy
    end;
    span := FCurTok.Span;
    name := FCurTok.Value;
    Advance;
    // new ClassName() or new ClassName(args)
    if Accept(tkLParen) then
    begin
      args := nil;
      if not Check(tkRParen) then
      begin
        SetLength(args, 1);
        args[0] := ParseExpr;
        while Accept(tkComma) do
        begin
          SetLength(args, Length(args) + 1);
          args[High(args)] := ParseExpr;
        end;
      end;
      Expect(tkRParen);
      if Length(args) > 0 then
        Exit(ParsePostfix(TAstNewExpr.CreateWithArgs(name, args, span)))
      else
        Exit(ParsePostfix(TAstNewExpr.Create(name, span)));
    end
    else
      Exit(ParsePostfix(TAstNewExpr.Create(name, span)));
  end;

  // super.method() - call to base class method
  if Check(tkSuper) then
  begin
    Advance; // consume 'super'
    Expect(tkDot);
    if not Check(tkIdent) then
    begin
      FDiag.Error('expected method name after ''super.''''', FCurTok.Span);
      Exit(TAstIntLit.Create(0, FCurTok.Span)); // dummy
    end;
    mName := FCurTok.Value;
    span := FCurTok.Span;
    Advance;
    Expect(tkLParen);
    args := nil;
    if not Check(tkRParen) then
    begin
      SetLength(args, 1);
      args[0] := ParseExpr;
      while Accept(tkComma) do
      begin
        SetLength(args, Length(args) + 1);
        args[High(args)] := ParseExpr;
      end;
    end;
    Expect(tkRParen);
    Exit(ParsePostfix(TAstSuperCall.Create(mName, args, span)));
  end;

  // panic(message) - abort with error message
  if Check(tkPanic) then
  begin
    span := FCurTok.Span;
    Advance; // consume 'panic'
    Expect(tkLParen);
    e := ParseExpr;
    Expect(tkRParen);
    Exit(ParsePostfix(TAstPanicExpr.Create(e, span)));
  end;

  if Accept(tkLBracket) then
  begin
    // array literal: [expr, expr, ...]
    items := nil;
    if not Check(tkRBracket) then
    begin
      while True do
      begin
        a := ParseExpr;
        SetLength(items, Length(items) + 1);
        items[High(items)] := a;
        if Accept(tkComma) then Continue;
        Break;
      end;
    end;
    Expect(tkRBracket);
    Exit(ParsePostfix(TAstArrayLit.Create(items, FCurTok.Span)));
  end;

  // Map/Set Literal: {key: value, ...} oder {value, value, ...}
  if Accept(tkLBrace) then
  begin
    span := FCurTok.Span;
    // Leeres Map/Set: {}
    if Accept(tkRBrace) then
      Exit(ParsePostfix(TAstMapLit.Create(nil, span)));
    
    // Erstes Element parsen um Map vs Set zu unterscheiden
    firstExpr := ParseExpr;
    
    if Accept(tkColon) then
    begin
      // Es ist ein Map-Literal: {key: value, ...}
      SetLength(mapEntries, 1);
      mapEntries[0].Key := firstExpr;
      mapEntries[0].Value := ParseExpr;
      
      while Accept(tkComma) do
      begin
        if Check(tkRBrace) then Break; // trailing comma erlaubt
        SetLength(mapEntries, Length(mapEntries) + 1);
        mapEntries[High(mapEntries)].Key := ParseExpr;
        Expect(tkColon);
        mapEntries[High(mapEntries)].Value := ParseExpr;
      end;
      Expect(tkRBrace);
      Exit(ParsePostfix(TAstMapLit.Create(mapEntries, span)));
    end
    else
    begin
      // Es ist ein Set-Literal: {value, value, ...}
      SetLength(items, 1);
      items[0] := firstExpr;
      
      while Accept(tkComma) do
      begin
        if Check(tkRBrace) then Break; // trailing comma erlaubt
        SetLength(items, Length(items) + 1);
        items[High(items)] := ParseExpr;
      end;
      Expect(tkRBrace);
      Exit(ParsePostfix(TAstSetLit.Create(items, span)));
    end;
  end;

  if Accept(tkLParen) then
  begin
    e := ParseExpr;
    Expect(tkRParen);
    Exit(ParsePostfix(e));
  end;

  // unexpected primary
  FDiag.Error('unexpected token in expression: ' + TokenKindToStr(FCurTok.Kind), FCurTok.Span);
  // create dummy literal
  dummy := TAstIntLit.Create(0, FCurTok.Span);
  Advance;
  Result := dummy;
end;

function TParser.ParseCallOrIdent: TAstExpr;
var
  name: string;
  namespace: string;
  args: TAstExprList;
  span: TSourceSpan;
  a: TAstExpr;
  fields: TStructFieldInitList;
  fld: TStructFieldInit;
  fldName: string;
  savedName: string;
  savedSpan: TSourceSpan;
  nsCandidate: string;
  nsSpan: TSourceSpan;
  widthVal, decimalsVal: Integer;
  typeArgs: array of TAurumType;
  dummyLen: Integer;
  dummyName: string;
  dummyNull: Boolean;
  ta: TAurumType;
  callExpr: TAstCall;
  peeked: TToken;
  i: Integer;
begin
  name := FCurTok.Value;
  span := FCurTok.Span;
  Advance; // consume ident
  
  // Check for namespace qualifier: Ident.Ident( or Ident.Ident{
  // Only treat as namespace if followed by call or struct literal,
  // otherwise it is a field access (handled by ParsePostfix).
  namespace := '';
  if Check(tkDot) and (FLexer.PeekToken.Kind = tkIdent) then
  begin
    // Save state so we can backtrack if this is not a namespace call
    savedName := name;
    savedSpan := span;
    Advance; // consume dot
    nsCandidate := FCurTok.Value;  // second ident (potential function name)
    nsSpan := FCurTok.Span;
    Advance; // consume the second ident
    
    // Check for Pascal-style constructor: ClassName.Create or ClassName.Create() = new ClassName()
    // Note: Create without parentheses is also valid
    if (nsCandidate = 'Create') and not Check(tkLBrace) then
    begin
      // Pascal-style constructor: ClassName.Create = new ClassName()
      // Check if there are arguments
      args := nil;
      if Accept(tkLParen) then
      begin
        // With arguments: ClassName.Create(arg1, arg2, ...)
        if not Check(tkRParen) then
        begin
          SetLength(args, 1);
          args[0] := ParseExpr;
          while Accept(tkComma) do
          begin
            SetLength(args, Length(args) + 1);
            args[High(args)] := ParseExpr;
          end;
        end;
        Expect(tkRParen);
      end;
      // Create as new expression
      if Length(args) > 0 then
        Result := ParsePostfix(TAstNewExpr.CreateWithArgs(savedName, args, savedSpan))
      else
        Result := ParsePostfix(TAstNewExpr.Create(savedName, savedSpan));
      Exit;
    end
    else if Check(tkLParen) or Check(tkLBrace) then
    begin
      // Confirmed: namespace-qualified call or struct literal
      namespace := savedName;
      name := nsCandidate;
      span := nsSpan;
    end
    else
    begin
      // Not a namespace call → treat as field access: ident.field
      // Build TAstIdent for the first name, then wrap in TAstFieldAccess
      Result := ParsePostfix(TAstFieldAccess.Create(
        TAstIdent.Create(savedName, savedSpan), nsCandidate, savedSpan));
      Exit;
    end;
  end;

  // Parse optional generic type args: name[int64] or name[T] before (
  // Heuristic: only treat [X] as type args if X is a known type name or current type param
  typeArgs := nil;
  if Check(tkLBracket) then
  begin
    peeked := FLexer.PeekToken;
    // Only parse as type args if the content looks like a type (identifier = potential type name)
    if peeked.Kind = tkIdent then
    begin
      Advance; // consume '['
      repeat
        dummyLen := 0; dummyName := ''; dummyNull := False;
        ta := ParseTypeExFull(dummyLen, dummyName, dummyNull);
        SetLength(typeArgs, Length(typeArgs) + 1);
        typeArgs[High(typeArgs)] := ta;
      until not Accept(tkComma);
      Expect(tkRBracket);
    end;
  end;

  if Accept(tkLParen) then
  begin
    args := nil;
    if not Check(tkRParen) then
    begin
      // ArgList
      while True do
      begin
        a := ParseExpr;
        // Check for Pascal format specifier: expr:width:decimals
        if Check(tkColon) then
        begin
          Advance; // consume ':'
          if Check(tkIntLit) then
          begin
            widthVal := StrToIntDef(FCurTok.Value, 0);
            Advance; // consume width
            if Check(tkColon) then
            begin
              Advance; // consume ':'
              if Check(tkIntLit) then
              begin
                decimalsVal := StrToIntDef(FCurTok.Value, 0);
                Advance; // consume decimals
                a := TAstFormatExpr.Create(a, widthVal, decimalsVal, a.Span);
              end
              else
                FDiag.Error('expected integer for decimal places in format specifier', FCurTok.Span);
            end
            else
              FDiag.Error('expected '':'' after width in format specifier', FCurTok.Span);
          end
          else
            FDiag.Error('expected integer for width in format specifier', FCurTok.Span);
        end;
        SetLength(args, Length(args) + 1);
        args[High(args)] := a;
        if Accept(tkComma) then Continue;
        Break;
      end;
    end;
    Expect(tkRParen);
    callExpr := TAstCall.Create(name, args, span);
    if namespace <> '' then
      callExpr.Namespace := namespace;
    // Attach generic type args if parsed
    if Length(typeArgs) > 0 then
      callExpr.TypeArgs := typeArgs;
    Result := ParsePostfix(callExpr);
  end
  else if Accept(tkLBrace) then
  begin
    // Struct literal: TypeName { field: value, ... }
    // Note: for struct literals, namespace is not supported yet
    fields := nil;
    if not Check(tkRBrace) then
    begin
      while True do
      begin
        // Parse field initializer: name: expr
        if Check(tkIdent) then
        begin
          fldName := FCurTok.Value;
          Advance;
        end
        else
        begin
          fldName := '<anon>';
          FDiag.Error('expected field name in struct literal', FCurTok.Span);
        end;
        Expect(tkColon);
        fld.Name := fldName;
        fld.Value := ParseExpr;
        SetLength(fields, Length(fields) + 1);
        fields[High(fields)] := fld;
        if Accept(tkComma) then Continue;
        Break;
      end;
    end;
    Expect(tkRBrace);
    Result := ParsePostfix(TAstStructLit.Create(name, fields, span));
  end
  else
    Result := ParsePostfix(TAstIdent.Create(name, span));
end;

function TParser.ParsePostfix(base: TAstExpr): TAstExpr;
var
  fieldName: string;
  indexExpr: TAstExpr;
  args: TAstExprList;
  a: TAstExpr;
  args2: TAstExprList;
  ii: Integer;
  s: string;
begin
  Result := base;
  while True do
  begin
    if Accept(tkDot) then
    begin
      if Check(tkIdent) then
      begin
        fieldName := FCurTok.Value;
        Advance;
        // Method call syntax: .Ident ( args )
        if Accept(tkLParen) then
        begin
          // parse args
          args := nil;
          if not Check(tkRParen) then
          begin
            while True do
            begin
              a := ParseExpr;
              SetLength(args, Length(args) + 1);
              args[High(args)] := a;
              if Accept(tkComma) then Continue;
              Break;
            end;
          end;
          Expect(tkRParen);
          // method call -> desugar to call with implicit receiver as first arg
          // name format: _METHOD_<methodname>
          SetLength(args2, Length(args) + 1);
          args2[0] := Result; // receiver as first arg
          for ii := 0 to High(args) do
            args2[ii+1] := args[ii];
          Result := TAstCall.Create('_METHOD_' + fieldName, args2, Result.Span);
        end
        else
          Result := TAstFieldAccess.Create(Result, fieldName, Result.Span);
      end
      else
      begin
        FDiag.Error('expected field name after .', FCurTok.Span);
        Exit;
      end;
    end
    else if Accept(tkLBracket) then
    begin
      indexExpr := ParseExpr;
      Expect(tkRBracket);
      Result := TAstIndexAccess.Create(Result, indexExpr, Result.Span);
    end
    else if Accept(tkAs) then
    begin
      // Type cast: expr as Type
      if Check(tkIdent) then
      begin
        // Parse type name
        s := FCurTok.Value;
        Advance;
        Result := TAstCast.Create(Result, atUnresolved, Result.Span);
        TAstCast(Result).CastTypeName := s;
      end
      else
      begin
        FDiag.Error('expected type name after as', FCurTok.Span);
      end;
    end
    else
      Break;
  end;
end;

function TParser.ParseTypeEx(out arrayLen: Integer; out typeName: string): TAurumType;
var 
  isNullable: Boolean;
begin
  Result := ParseTypeExFull(arrayLen, typeName, isNullable);
end;

function TParser.ParseTypeExFull(out arrayLen: Integer; out typeName: string; out isNullable: Boolean): TAurumType;
var
  s: string;
  baseType: TAurumType;
  parsedLen: Integer;
  innerTypeName: string;
  innerNullable: Boolean;
  innerArrayLen: Integer;
  innerType, keyType, valueType, elementType, paramType, returnType: TAurumType;
  paramTypes: array of TAurumType;
begin
  arrayLen := 0;
  typeName := '';
  isNullable := False;

  // Check for array type syntax: Type[N] or []Type or Array<T> or Map<K,V> or Set<T>
  // Also check for function pointer type: fn(params) -> returnType
  // First parse the base type
  if Check(tkIdent) or Check(tkArray) or Check(tkParallel) or Check(tkMap) or Check(tkSet) or Check(tkFn) then
  begin
    // Handle function pointer type: fn(params) -> returnType
    if Check(tkFn) then
    begin
      Advance; // consume 'fn'
      Expect(tkLParen);
      
      // Parse parameter types
      paramTypes := nil;
      if not Check(tkRParen) then
      begin
        repeat
          paramType := ParseType;
          SetLength(paramTypes, Length(paramTypes) + 1);
          paramTypes[High(paramTypes)] := paramType;
        until not Accept(tkComma);
      end;
      Expect(tkRParen);
      
      // Parse return type
      Expect(tkMinus);
      Expect(tkGt);
      returnType := ParseType;
      
      // Create function pointer type AST node
      Result := atFnPtr;
      // Note: We store the signature info in a global or pass it through
      // For now, we'll handle this in sema phase
      Exit;
    end;
    
    // Handle 'parallel Array<T>' first
    if Check(tkParallel) then
    begin
      Advance; // consume 'parallel'
      Expect(tkArray);
      // Now we have 'parallel Array' - check for generic syntax Array<T>
      if Accept(tkLt) then
      begin
        // Generic array: parallel Array<T>
        innerType := ParseType; // Recursively parse inner type
        if innerType = atUnresolved then
        begin
          FDiag.Error('expected element type in Array<T>', FCurTok.Span);
          Result := atVoid;
        end;
        Expect(tkGt);
        // Mark as parallel array
        arrayLen := -2;
        Result := atDynArray;
        Exit;
      end
      else
      begin
        // Just 'parallel' without generic - treat as unresolved type
        typeName := 'parallel';
        Result := atUnresolved;
        Exit;
      end;
    end;

    // Handle Map<K,V> generic syntax
    if Accept(tkMap) then
    begin
      Expect(tkLt);
      // Parse Key Type
      keyType := ParseType;
      if keyType = atUnresolved then
      begin
        FDiag.Error('expected key type in Map<K,V>', FCurTok.Span);
        Result := atVoid;
        Exit;
      end;
      Expect(tkComma);
      // Parse Value Type
      valueType := ParseType;
      if valueType = atUnresolved then
      begin
        FDiag.Error('expected value type in Map<K,V>', FCurTok.Span);
        Result := atVoid;
        Exit;
      end;
      Expect(tkGt);
      Result := atMap;
      Exit;
    end;

    // Handle Set<T> generic syntax
    if Accept(tkSet) then
    begin
      Expect(tkLt);
      // Parse Element Type
      elementType := ParseType;
      if elementType = atUnresolved then
      begin
        FDiag.Error('expected element type in Set<T>', FCurTok.Span);
        Result := atVoid;
        Exit;
      end;
      Expect(tkGt);
      Result := atSet;
      Exit;
    end;

    // Handle 'Array<T>' generic syntax
    if Accept(tkArray) then
    begin
      // Check for generic syntax: Array<T>
      if Accept(tkLt) then
      begin
        // Generic array: Array<T>
        innerType := ParseType; // Recursively parse inner type
        if innerType = atUnresolved then
        begin
          FDiag.Error('expected element type in Array<T>', FCurTok.Span);
          Result := atVoid;
          Exit;
        end;
        Expect(tkGt);
        // Mark as generic array (-3 indicates generic array)
        arrayLen := -3;
        Result := atDynArray;
        Exit;
      end;

      // Check if 'array' is followed by [N] for static array BEFORE treating as dynamic
      // This handles: array[4]int64
      if Check(tkLBracket) then
      begin
        // Static array: array[N]ElementType
        // Don't advance yet - the code below will handle the bracket
        s := 'array';
        Result := atArray;  // Mark as static array type
      end
      else
      begin
        // Old syntax: 'array' keyword for dynamic array (without [N])
        s := 'array';
        arrayLen := -1;
        Result := atDynArray;
      end
    end
    else
    begin
      // Regular identifier type (int64, bool, struct name, etc.)
      s := FCurTok.Value;
      Advance;
      
      // Handle qualified type names (e.g., types.NativeSocket, std.net.IPAddr)
      while Check(tkDot) do
      begin
        Advance; // consume dot
        if Check(tkIdent) then
        begin
          s := s + '.' + FCurTok.Value;
          Advance;
        end
        else
        begin
          FDiag.Error('expected identifier after dot in type name', FCurTok.Span);
          Break;
        end;
      end;
      
      Result := StrToAurumType(s);
      if Result = atUnresolved then
        typeName := s;
    end;

    // Check for array suffix: type[N] or type[]
    if Accept(tkLBracket) then
    begin
      // Array type: type[N] or type[]
      if Check(tkIntLit) then
      begin
        parsedLen := StrToIntDef(FCurTok.Value, 0);
        Advance;
        Expect(tkRBracket);
        arrayLen := parsedLen;
        // If base type was 'array', parse element type after [N]
        // e.g., array[4]int64 means static array of 4 int64 elements
        if (s = 'array') and Check(tkIdent) then
        begin
          // Parse element type
          innerTypeName := FCurTok.Value;
          Advance;
          innerType := StrToAurumType(innerTypeName);
          if innerType = atUnresolved then
          begin
            // Keep as typeName for struct types
            typeName := innerTypeName;
          end
          else
          begin
            Result := atArray;  // This is a static array
          end;
        end;
      end
      else if Accept(tkRBracket) then
      begin
        // Dynamic array: type[]
        arrayLen := -1;
      end
      else
      begin
        FDiag.Error('expected integer literal or ] in array type', FCurTok.Span);
        if Check(tkRBracket) then Advance;
      end;
    end;
  end
  else if Accept(tkLBracket) then
  begin
    // Array type: [N] Type (alternative syntax)
    parsedLen := 0;
    if Check(tkIntLit) then
    begin
      parsedLen := StrToIntDef(FCurTok.Value, 0);
      Advance;
      Expect(tkRBracket);
    end
    else if Accept(tkRBracket) then
    begin
      // Dynamic array: [] Type
      parsedLen := -1;
    end
    else
    begin
      FDiag.Error('expected integer literal or ] in array type', FCurTok.Span);
      if Check(tkRBracket) then Advance;
    end;
    
    // Recursively parse the base type of the array
    baseType := ParseTypeExFull(innerArrayLen, innerTypeName, innerNullable);
    arrayLen := parsedLen;
    typeName := innerTypeName;
    isNullable := innerNullable;
    Result := baseType;
  end
  else
  begin
    FDiag.Error('expected type name', FCurTok.Span);
    Result := atUnresolved;
  end;

  // optional nullable suffix: ?
  if Accept(tkQuestion) then
    isNullable := True;

  // Convert to nullable type if needed
  if isNullable and (Result = atPChar) then
    Result := atPCharNullable;
end;

function TParser.ParseType: TAurumType;
var dummy: Integer; dummyName: string;
begin
  Result := ParseTypeEx(dummy, dummyName);
end;

function TParser.ParseParamList: TAstParamList;
var
  params: TAstParamList;
  name: string;
  typ: TAurumType;
  typName: string;
  p: TAstParam;
  arrLen: Integer;
begin
  params := nil;
  FLastParamListVarArgs := False;
  while not Check(tkRParen) and not Check(tkEOF) do
  begin
    if Check(tkEllipsis) then
    begin
      // varargs marker
      Accept(tkEllipsis);
      FLastParamListVarArgs := True;
      Break;
    end;
    if Check(tkIdent) then
    begin
      name := FCurTok.Value; Advance;
    end
    else
    begin
      name := '<anon>'; FDiag.Error('expected parameter name', FCurTok.Span);
    end;
    Expect(tkColon);
    typ := ParseTypeEx(arrLen, typName);
    if arrLen <> 0 then
      FDiag.Error('array parameter types not yet supported', FCurTok.Span);
    p.Name := name; p.ParamType := typ; p.TypeName := typName; p.Span := FCurTok.Span;
    SetLength(params, Length(params) + 1);
    params[High(params)] := p;
    if Accept(tkComma) then Continue else Break;
  end;
  Result := params;
end;

{ Parst @energy(level) Attribut, falls vorhanden }
function TParser.ParseEnergyAttr: TEnergyLevel;
var
  level: Integer;
begin
  Result := eelNone; // Standard: verwende globales Level
  if not Check(tkAt) then
    Exit;
  
  // @energy
  Advance;
  if not Check(tkIdent) or (FCurTok.Value <> 'energy') then
  begin
    FDiag.Error('expected @energy attribute', FCurTok.Span);
    Exit;
  end;
  Advance;
  
  // (level)
  Expect(tkLParen);
  if Check(tkIntLit) then
  begin
    try
      level := StrToInt(FCurTok.Value);
      if (level < 1) or (level > 5) then
      begin
        FDiag.Error('energy level must be between 1 and 5', FCurTok.Span);
        level := 3;
      end;
      Result := TEnergyLevel(level);
    except
      FDiag.Error('invalid energy level', FCurTok.Span);
      Result := eelMedium;
    end;
    Advance;
  end
  else
  begin
    FDiag.Error('expected energy level (1-5)', FCurTok.Span);
  end;
  Expect(tkRParen);
end;

end.
