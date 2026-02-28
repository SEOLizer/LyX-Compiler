{$mode objfpc}{$H+}
unit parser;

interface

uses
  SysUtils, Classes,
  diag, lexer, ast;

type
  TParser = class
  private
    FLexer: TLexer;
    FDiag: TDiagnostics;
    FCurTok: TToken;
    FHasCur: Boolean;
    FLastParamListVarArgs: Boolean;

    procedure Advance; // setzt FCurTok
    function Check(kind: TTokenKind): Boolean;
    function Accept(kind: TTokenKind): Boolean;
    procedure Expect(kind: TTokenKind);

    function ParseVisibility: TVisibility;

    // Parsing-Methoden
    function ParseTopDecl: TAstNode;
    function ParseFuncDecl(isPub: Boolean): TAstFuncDecl;
    function ParseConDecl(isPub: Boolean): TAstConDecl;
    function ParseTypeDecl(isPub: Boolean): TAstNode;
    function ParseGlobalVarDecl(isPub: Boolean): TAstVarDecl;
    function ParseUnitDecl: TAstUnitDecl;
    function ParseImportDecl: TAstImportDecl;

    function ParseBlock: TAstBlock;
    function ParseStmt: TAstStmt;
    function ParseVarLetCoDecl: TAstVarDecl;
    function ParseForStmt: TAstFor;
    function ParseRepeatUntilStmt: TAstRepeatUntil;
    function ParseAssignStmtOrExprStmt: TAstStmt;

    // Expressions (Präzedenz): Pipe -> NullCoalesce -> Or -> And -> Cmp -> Add -> Mul -> Unary -> Primary -> Postfix
    function ParseExpr: TAstExpr;
    function ParsePipeExpr: TAstExpr;
    function ParseNullCoalesceExpr: TAstExpr;
    function ParseOrExpr: TAstExpr;
    function ParseAndExpr: TAstExpr;
    function ParseCmpExpr: TAstExpr;
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
  else if Accept(tkPub) then
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
begin
  isExtern := False;
  if Check(tkPub) then
  begin
    Advance; // consume 'pub'
    if Check(tkFn) then
      Exit(ParseFuncDecl(True))
    else if Check(tkCon) then
      Exit(ParseConDecl(True))
    else if Check(tkType) then
      Exit(ParseTypeDecl(True))
    else if Check(tkVar) or Check(tkLet) then
      Exit(ParseGlobalVarDecl(True))
    else
    begin
      FDiag.Error('expected fn, con, type, var or let after pub', FCurTok.Span);
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
      Expect(tkSemicolon);
      Result := TAstFuncDecl.Create(name, params, retType, nil, FCurTok.Span, False);
      // mark extern and varargs if parser recorded them
      TAstFuncDecl(Result).IsExtern := True;
      TAstFuncDecl(Result).IsVarArgs := FLastParamListVarArgs;
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
  if Check(tkCon) then
    Exit(ParseConDecl(False));
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
begin
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
  Result := TAstConDecl.Create(name, declType, initExpr, FCurTok.Span);
end;

function TParser.ParseTypeDecl(isPub: Boolean): TAstNode;
var
  name: string;
  declType: TAurumType;
  fields: TStructFieldList;
  methods: TMethodList;
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
  // '=' (single equals for type declarations)
  if Check(tkSingleEq) then
    Advance
  else
  begin
    FDiag.Error('expected ''='' in type declaration', FCurTok.Span);
  end;

  // class [extends BaseClass] { ... }
  if Check(tkClass) then
  begin
    Advance; // class
    baseClassName := '';
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
    end;
    Expect(tkLBrace);
    fields := nil;
    methods := nil;
    while not Check(tkRBrace) and not Check(tkEOF) do
    begin
      // parse optional visibility modifier
      curVisibility := ParseVisibility;
      if Check(tkFn) or Check(tkStatic) or Check(tkVirtual) then
      begin
        // parse method declaration
        isStatic := Accept(tkStatic);
        isVirtual := Accept(tkVirtual);
        // After static/virtual, we expect fn
        if not Check(tkFn) then
        begin
          FDiag.Error('expected ''fn'' keyword', FCurTok.Span);
        end;
        Expect(tkFn);
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
        mBody := ParseBlock;
        m := TAstFuncDecl.Create(mName, mParams, mRetType, mBody, FCurTok.Span, False);
        m.ReturnTypeName := mRetTypeName;
        m.IsStatic := isStatic;
        m.Visibility := curVisibility;
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
    Exit;
  end
  // struct { ... }  or simple type
  else if Check(tkStruct) then
  begin
    // parse inline struct definition
    Advance; // struct
    Expect(tkLBrace);
    fields := nil;
    methods := nil;
    while not Check(tkRBrace) and not Check(tkEOF) do
    begin
      // parse optional visibility modifier
      curVisibility := ParseVisibility;
      if Check(tkFn) or Check(tkStatic) then
      begin
        // parse method declaration
        // check for static modifier
        isStatic := Accept(tkStatic);
        Expect(tkFn);
        // parse method name, params, return type, body inline (similar to ParseFuncDecl but without the 'fn' expect)
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
        if not Check(tkRParen) then
          mParams := ParseParamList
        else
          mParams := nil;
        Expect(tkRParen);
        // optional return type
        mRetTypeName := '';
        if Accept(tkColon) then
          mRetType := ParseTypeEx(dummy, mRetTypeName)
        else
          mRetType := atVoid;
        mBody := ParseBlock;
        m := TAstFuncDecl.Create(mName, mParams, mRetType, mBody, FCurTok.Span, False);
        m.ReturnTypeName := mRetTypeName;
        m.IsStatic := isStatic;
        m.IsVirtual := isVirtual;
        m.Visibility := curVisibility;
        SetLength(methods, Length(methods) + 1);
        methods[High(methods)] := m;
      end
      else
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
        FDiag.Error('unexpected token in struct body', FCurTok.Span);
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
    Expect(tkSemicolon);
    Result := TAstTypeDecl.Create(name, declType, isPub, FCurTok.Span);
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
begin
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

  Expect(tkAssign);
  initExpr := ParseExpr;
  Expect(tkSemicolon);

  Result := TAstVarDecl.Create(storage, name, declType, declTypeName, arrayLen, initExpr, isNullable, initExpr.Span);
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
    Advance;
  end
  else
  begin
    name := '<anon>'; 
    FDiag.Error('expected identifier in global declaration', FCurTok.Span);
  end;

  Expect(tkColon);
  declType := ParseTypeExFull(arrayLen, declTypeName, isNullable);

  Expect(tkAssign);
  initExpr := ParseExpr;
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
  Result := ParseCmpExpr;
  while Accept(tkAnd) do
  begin
    rhs := ParseCmpExpr;
    Result := TAstBinOp.Create(tkAnd, Result, rhs, Result.Span);
  end;
end;

function TParser.ParseCmpExpr: TAstExpr;
var
  op: TTokenKind;
  rhs: TAstExpr;
begin
  Result := ParseAddExpr;
  if Check(tkEq) or Check(tkNeq) or Check(tkLt) or Check(tkLe) or Check(tkGt) or Check(tkGe) then
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
  // Collect consecutive prefix unary operators (e.g. - - ! !)
  while Check(tkMinus) or Check(tkNot) or Check(tkMinusMinus) do
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
begin
  if Check(tkIntLit) then
  begin
    v := StrToInt64Def(FCurTok.Value, 0);
    span := FCurTok.Span;
    Advance;
    Exit(TAstIntLit.Create(v, span));
  end;

  if Check(tkFloatLit) then
  begin
    span := FCurTok.Span;
    // Parse als Double
    s := FCurTok.Value;
    Advance;
    Exit(TAstFloatLit.Create(StrToFloat(s), span));
  end;

  if Check(tkStrLit) then
  begin
    s := FCurTok.Value;
    span := FCurTok.Span;
    Advance;
    Exit(TAstStrLit.Create(s, span));
  end;

  if Check(tkCharLit) then
  begin
    span := FCurTok.Span;
    if Length(FCurTok.Value) > 0 then
      Result := TAstCharLit.Create(FCurTok.Value[1], span)
    else
      Result := TAstCharLit.Create(#0, span);
    Advance;
    Exit;
  end;

  if Check(tkRegexLit) then
  begin
    span := FCurTok.Span;
    Result := TAstRegexLit.Create(FCurTok.Value, span);
    Advance;
    Exit;
  end;

  if Check(tkTrue) or Check(tkFalse) then
  begin
    b := Check(tkTrue);
    span := FCurTok.Span;
    Advance;
    Exit(TAstBoolLit.Create(b, span));
  end;

  // null literal for nullable pointers
  if Check(tkNull) then
  begin
    span := FCurTok.Span;
    Advance;
    Exit(TAstIntLit.Create(0, span)); // null as integer 0 (pointer representation)
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
        Exit(TAstNewExpr.CreateWithArgs(name, args, span))
      else
        Exit(TAstNewExpr.Create(name, span));
    end
    else
      Exit(TAstNewExpr.Create(name, span));
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
    Exit(TAstSuperCall.Create(mName, args, span));
  end;

  // panic(message) - abort with error message
  if Check(tkPanic) then
  begin
    span := FCurTok.Span;
    Advance; // consume 'panic'
    Expect(tkLParen);
    e := ParseExpr;
    Expect(tkRParen);
    Exit(TAstPanicExpr.Create(e, span));
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
    Exit(TAstArrayLit.Create(items, FCurTok.Span));
  end;

  if Accept(tkLParen) then
  begin
    e := ParseExpr;
    Expect(tkRParen);
    Exit(e);
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
    if Check(tkLParen) or Check(tkLBrace) then
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
  
  if Accept(tkLParen) then
  begin
    args := nil;
    if not Check(tkRParen) then
    begin
      // ArgList
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
    Result := ParsePostfix(TAstCall.Create(name, args, span));
    // Set namespace if present
    if namespace <> '' then
      TAstCall(Result).Namespace := namespace;
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
begin
  arrayLen := 0;
  typeName := '';
  isNullable := False;

  // Check for array type syntax: Type[N] or []Type
  // First parse the base type
  if Check(tkIdent) or Check(tkArray) then
  begin
    if Accept(tkArray) then
    begin
      // 'array' keyword: dynamic array
      s := 'array';
      arrayLen := -1; // Dynamic array by default for 'array' keyword
      Result := atDynArray; // Return atDynArray for dynamic array type
    end
    else
    begin
      s := FCurTok.Value;
      Advance;
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
    p.Name := name; p.ParamType := typ; p.Span := FCurTok.Span;
    SetLength(params, Length(params) + 1);
    params[High(params)] := p;
    if Accept(tkComma) then Continue else Break;
  end;
  Result := params;
end;

end.
