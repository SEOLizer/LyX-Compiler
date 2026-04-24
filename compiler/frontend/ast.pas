{$mode objfpc}{$H+}
unit ast;

interface

uses
  SysUtils, Classes,
  diag, lexer, backend_types;

type
  { --- Aurum-Typsystem --- }

  TAurumType = (
    atUnresolved,
    // signed integer widths
    atInt8, atInt16, atInt32, atInt64,
    // unsigned integer widths
    atUInt8, atUInt16, atUInt32, atUInt64,
    // platform-size integers
    atISize, atUSize,
    // floating-point
    atF32, atF64,
    // char
    atChar,
    atBool,
    atVoid,
    atPChar,
    atPCharNullable,  // nullable pointer type (Option Type)
    atDynArray,       // dynamic array (fat-pointer)
    atArray,          // static array type
    atMap,            // hash map type
    atSet,            // hash set type
    atParallelArray,  // SIMD parallel array
    atRingBuffer,     // lock-free ring buffer (aerospace-todo P2 #56)
    atFnPtr,          // function pointer type
    atTuple           // multi-return tuple: (T1, T2, ...)
  );

  { --- Speicherklassen --- }

  TStorageKlass = (skVar, skLet, skCo, skCon);

  { --- SIMD Element-Typen --- }

  TSIMDKind = (simdI8, simdI16, simdI32, simdI64, simdF32, simdF64);

  { --- Sichtbarkeit für Klassen-Member (Access Control) --- }

  TVisibility = (visPrivate, visProtected, visPublic);

  { --- LFD Widget-Typen (Qt-Widgets) --- }

  TLfdWidgetKind = (
    lfdWidgetUnknown,
    // Basis-Widgets
    lfdWidget,        // generisches QWidget
    lfdLabel,        // QLabel
    lfdPushButton,   // QPushButton
    lfdCheckBox,     // QCheckBox
    lfdRadioButton,  // QRadioButton
    lfdLineEdit,     // QLineEdit (Input)
    lfdTextEdit,     // QTextEdit / QPlainTextEdit
    // Container-Widgets
    lfdGroupBox,     // QGroupBox
    lfdTabWidget,    // QTabWidget
    lfdScrollArea,   // QScrollArea
    lfdStackedWidget, // QStackedWidget
    // Auswahl-Widgets
    lfdComboBox,     // QComboBox
    lfdListWidget,   // QListWidget
    lfdTreeWidget,   // QTreeWidget
    lfdTableWidget,  // QTableWidget
    // Fortschritt/Datum
    lfdProgressBar,  // QProgressBar
    lfdSlider,       // QSlider
    lfdSpinBox,      // QSpinBox
    lfdDateEdit,     // QDateEdit / QTimeEdit
    // Spezial
    lfdMenuBar,      // QMenuBar
    lfdToolBar,      // QToolBar
    lfdAction,       // QAction
    lfdSeparator,    // Separator/ Trennlinie
    lfdSpacer        // QSpacerItem (in Layouts)
  );

  { --- LFD Layout-Typen --- }

  TLfdLayoutKind = (
    lfdLayoutUnknown,
    lfdLayoutVertical,   // QVBoxLayout
    lfdLayoutHorizontal,  // QHBoxLayout
    lfdLayoutGrid,        // QGridLayout
    lfdLayoutForm         // QFormLayout
  );

  { --- LFD Signal-Typen --- }

  TLfdSignalKind = (
    lfdSignalUnknown,
    lfdSignalClicked,       // OnClick
    lfdSignalToggled,       // OnToggle (CheckBox)
    lfdSignalChanged,       // OnChange (Text/Value)
    lfdSignalActivated,     // OnSelect (ComboBox)
    lfdSignalDoubleClicked, // OnDblClick
    lfdSignalReturnPressed, // OnReturn (LineEdit)
    lfdSignalEditingFinished // OnEditingFinished
  );

  { --- Knotenarten (für schnellen Typcheck ohne 'is') --- }

   TNodeKind = (
      // Ausdrücke
      nkIntLit, nkFloatLit, nkStrLit, nkBoolLit, nkCharLit, nkRegexLit, nkIdent,
      nkConstrainedTypeDecl,
     nkBinOp, nkUnaryOp, nkCall, nkArrayLit, nkStructLit, nkTupleLit,
     nkFieldAccess, nkIndexAccess, nkCast,
     nkNewExpr, nkSuperCall, nkPanic,  // OOP expressions + panic
     nkMapLit, nkSetLit, nkInExpr,     // Map/Set expressions
     nkInspect,                         // In-Situ Data Visualizer
     // Statements
     nkVarDecl, nkAssign, nkFieldAssign, nkIndexAssign,
     nkIf, nkWhile, nkFor, nkRepeatUntil, nkPool,
     nkReturn, nkBreak, nkContinue, nkSwitch,
      nkBlock, nkExprStmt, nkDispose, nkAssert, nkCheck,  // OOP statement + assert (check is expression)
     nkTry, nkThrow,                             // Exception handling
     nkTupleVarDecl,                             // var a, b := tupleExpr
     // Top-Level
     nkFuncDecl, nkConDecl, nkTypeDecl, nkStructDecl, nkEnumDecl, nkClassDecl, nkInterfaceDecl,
     nkUnitDecl, nkImportDecl,
     nkProgram,
     // Bitwise AST nodes
     nkBitAnd, nkBitOr, nkBitXor, nkBitNot,
     nkShiftLeft, nkShiftRight,
     // SIMD/ParallelArray AST nodes
     nkSIMDNew, nkSIMDBinOp, nkSIMDUnaryOp, nkSIMDIndexAccess,
      nkIsExpr, // 'is' operator (type check)
      nkFormatExpr, // Pascal format specifier: expr:width:decimals

      // LFD (LyX Form Description) AST nodes
      nkLfdForm,         // Form MyForm "Title" { ... }
      nkLfdWidget,       // Button btnOk { ... }
      nkLfdLayout,       // Layout Vertical { ... }
      nkLfdProperty,     // Text: "value"
      nkLfdSignal        // OnClick: "handler()"
   );

  { --- Vorwärtsdeklarationen --- }

  TAstNode = class;
  TAstExpr = class;
  TAstStmt = class;
  TAstStructDecl = class;
  TAstClassDecl = class;
  TAstInterfaceDecl = class;
  TAstFuncDecl = class;
  
  { --- Knotenlisten --- }

  TAstNodeList = array of TAstNode;
  TAstExprList = array of TAstExpr;
  TAstStmtList = array of TAstStmt;
  TIntArray = array of Integer;
  TStringArray = array of string;

  { Map-Entry: key: value Paar }
  TMapEntry = record
    Key: TAstExpr;
    Value: TAstExpr;
  end;
  TMapEntryList = array of TMapEntry;

  { Captured Variable: Referenzierte Variable aus dem äußeren Scope }
  TCapturedVar = record
    Name: string;
    VarType: TAurumType;
    OuterSlot: Integer;
    InnerSlot: Integer;
  end;
  TAstCapturedVarList = array of TCapturedVar;

  { --- Basisklasse --- }

  TAstNode = class
  private
    FKind: TNodeKind;
    FSpan: TSourceSpan;
    // Provenance Tracking (WP-F): unique ID for this AST node
    FID: Integer;
  public
    constructor Create(aKind: TNodeKind; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Kind: TNodeKind read FKind;
    property Span: TSourceSpan read FSpan write FSpan;
    property ID: Integer read FID write FID;
  end;

  // ================================================================
  // Ausdrücke
  // ================================================================

  TAstExpr = class(TAstNode)
  private
    FResolvedType: TAurumType;
  public
    constructor Create(aKind: TNodeKind; aSpan: TSourceSpan);
    property ResolvedType: TAurumType read FResolvedType write FResolvedType;
  end;

  { Ganzzahl-Literal: 42 }
  TAstIntLit = class(TAstExpr)
  private
    FValue: Int64;
  public
    constructor Create(aValue: Int64; aSpan: TSourceSpan);
    property Value: Int64 read FValue;
  end;

  { String-Literal: "hello\n" }
  TAstStrLit = class(TAstExpr)
  private
    FValue: string;
  public
    constructor Create(const aValue: string; aSpan: TSourceSpan);
    property Value: string read FValue;
  end;

  { Bool-Literal: true / false }
  TAstBoolLit = class(TAstExpr)
  private
    FValue: Boolean;
  public
    constructor Create(aValue: Boolean; aSpan: TSourceSpan);
    property Value: Boolean read FValue;
  end;

  { Float-Literal: 3.14, 2.0 }
  TAstFloatLit = class(TAstExpr)
  private
    FValue: Double;
  public
    constructor Create(aValue: Double; aSpan: TSourceSpan);
    property Value: Double read FValue;
  end;

  { Identifier-Referenz: x, counter }
  TAstIdent = class(TAstExpr)
  private
    FName: string;
  public
    constructor Create(const aName: string; aSpan: TSourceSpan);
    property Name: string read FName;
  end;

  { Binärer Operator: a + b, x == y }
  TAstBinOp = class(TAstExpr)
  private
    FOp: TTokenKind;
    FLeft: TAstExpr;
    FRight: TAstExpr;
  public
    constructor Create(aOp: TTokenKind; aLeft, aRight: TAstExpr;
      aSpan: TSourceSpan);
    destructor Destroy; override;
    property Op: TTokenKind read FOp;
    property Left: TAstExpr read FLeft;
    property Right: TAstExpr read FRight;
  end;

  { Unärer Operator: -x, !flag }
  TAstUnaryOp = class(TAstExpr)
  private
    FOp: TTokenKind;
    FOperand: TAstExpr;
  public
    constructor Create(aOp: TTokenKind; aOperand: TAstExpr;
      aSpan: TSourceSpan);
    destructor Destroy; override;
    property Op: TTokenKind read FOp;
    property Operand: TAstExpr read FOperand;
  end;

  { Funktionsaufruf: print_str("hi"), foo(1, 2), IO.print_str("hi") }
  TAstCall = class(TAstExpr)
  private
    FName: string;
    FArgs: TAstExprList;
    FNamespace: string;  // z.B. "IO" für "IO.PrintStr"
    FIsIndirectCall: Boolean;  // true wenn dies ein Funktionszeiger-Aufruf ist
    FIsPatternBinding: Boolean;  // true if this is a pattern like Ok(v) in match
  public
    constructor Create(const aName: string; const aArgs: TAstExprList;
      aSpan: TSourceSpan);
    destructor Destroy; override;
    procedure SetName(const aName: string);
    procedure SetArgs(const aArgs: TAstExprList);
    procedure ReplaceArgs(const aArgs: TAstExprList); // replaces without freeing old args
    property Name: string read FName;
    property Args: TAstExprList read FArgs;
    property Namespace: string read FNamespace write FNamespace;  // z.B. "IO" für "IO.PrintStr"
    property IsIndirectCall: Boolean read FIsIndirectCall write FIsIndirectCall;
    property IsPatternBinding: Boolean read FIsPatternBinding write FIsPatternBinding;
  public
    // Generic type arguments for monomorphization, e.g., [atInt64] for max[int64](...)
    TypeArgs: array of TAurumType;
  end;

  { Array-Literal: [expr, expr, ...] }
  TAstArrayLit = class(TAstExpr)
  private
    FItems: TAstExprList;
    FElemType: TAurumType;  // inferred element type
  public
    constructor Create(const aItems: TAstExprList; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Items: TAstExprList read FItems;
    property ElemType: TAurumType read FElemType write FElemType;
  end;

  { Map-Literal: {key: value, key: value, ...} }
  TAstMapLit = class(TAstExpr)
  private
    FEntries: TMapEntryList;
    FKeyType: TAurumType;
    FValueType: TAurumType;
  public
    constructor Create(const aEntries: TMapEntryList; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Entries: TMapEntryList read FEntries;
    property KeyType: TAurumType read FKeyType write FKeyType;
    property ValueType: TAurumType read FValueType write FValueType;
  end;

  { Set-Literal: {value, value, ...} }
  TAstSetLit = class(TAstExpr)
  private
    FItems: TAstExprList;
    FElemType: TAurumType;
  public
    constructor Create(const aItems: TAstExprList; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Items: TAstExprList read FItems;
    property ElemType: TAurumType read FElemType write FElemType;
  end;

  { In-Expression: key in map/set }
  TAstInExpr = class(TAstExpr)
  private
    FKey: TAstExpr;
    FContainer: TAstExpr;
  public
    constructor Create(aKey, aContainer: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Key: TAstExpr read FKey;
    property Container: TAstExpr read FContainer;
  end;

  { Is-Operator: expr is ClassName }
  TAstIsExpr = class(TAstExpr)
  private
    FExpr: TAstExpr;
    FClassName: string;
  public
    constructor Create(aExpr: TAstExpr; const aClassName: string; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Expr: TAstExpr read FExpr;
    property ClassName: string read FClassName;
  end;

  { Format-Ausdruck: expr:width:decimals (Pascal-Formatierung für f32/f64) }
  TAstFormatExpr = class(TAstExpr)
  private
    FExpr: TAstExpr;
    FWidth: Integer;
    FDecimals: Integer;
  public
    constructor Create(aExpr: TAstExpr; aWidth, aDecimals: Integer; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Expr: TAstExpr read FExpr;
    property Width: Integer read FWidth;
    property Decimals: Integer read FDecimals;
  end;

  { SIMD New Expression: parallel Array<T>(size) }
  TAstSIMDNew = class(TAstExpr)
  private
    FSize: TAstExpr;
    FElementType: TAurumType;
    FSIMDKind: TSIMDKind;
  public
    constructor Create(aSize: TAstExpr; aElemType: TAurumType; aKind: TSIMDKind; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Size: TAstExpr read FSize;
    property ElementType: TAurumType read FElementType;
    property SIMDKind: TSIMDKind read FSIMDKind;
  end;

  { SIMD Binary Operation: vec1 + vec2 }
  TAstSIMDBinOp = class(TAstExpr)
  private
    FOp: TTokenKind;
    FLeft: TAstExpr;
    FRight: TAstExpr;
    FSIMDKind: TSIMDKind;
  public
    constructor Create(aOp: TTokenKind; aLeft, aRight: TAstExpr; aKind: TSIMDKind; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Op: TTokenKind read FOp;
    property Left: TAstExpr read FLeft;
    property Right: TAstExpr read FRight;
    property SIMDKind: TSIMDKind read FSIMDKind;
  end;

  { SIMD Unary Operation: -vec }
  TAstSIMDUnaryOp = class(TAstExpr)
  private
    FOp: TTokenKind;
    FOperand: TAstExpr;
    FSIMDKind: TSIMDKind;
  public
    constructor Create(aOp: TTokenKind; aOperand: TAstExpr; aKind: TSIMDKind; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Op: TTokenKind read FOp;
    property Operand: TAstExpr read FOperand;
    property SIMDKind: TSIMDKind read FSIMDKind;
  end;

  { SIMD Index Access: vec[i] }
  TAstSIMDIndexAccess = class(TAstExpr)
  private
    FObj: TAstExpr;
    FIndex: TAstExpr;
  public
    constructor Create(aObj, aIndex: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Obj: TAstExpr read FObj;
    property Index: TAstExpr read FIndex;
  end;

  { Char-Literal: 'A' }
  TAstCharLit = class(TAstExpr)
  private
    FValue: Char;
  public
    constructor Create(aValue: Char; aSpan: TSourceSpan);
    property Value: Char read FValue;
  end;

  { Regex-Literal: r"pattern" }
  TAstRegexLit = class(TAstExpr)
  private
    FPattern: string;
    FCompiled: string;
    FCompiledLen: Integer;
    FCaptureSlots: Integer;
    FHasCompiled: Boolean;
  public
    constructor Create(const aPattern: string; aSpan: TSourceSpan);
    procedure SetCompiled(const data: string; capSlots: Integer);
    property Pattern: string read FPattern;
    property CompiledProgram: string read FCompiled;
    property CompiledLen: Integer read FCompiledLen;
    property CaptureSlots: Integer read FCaptureSlots;
    property HasCompiled: Boolean read FHasCompiled;
  end;

  { Feldzugriff: expr.field }
  TAstFieldAccess = class(TAstExpr)
  private
    FObj: TAstExpr;
    FField: string;
    FFieldOffset: Integer; // -1 if unknown
    FOwnerName: string; // owner struct name if known
    FFieldType: TAurumType; // resolved field type
  public
    constructor Create(aObj: TAstExpr; const aField: string; aSpan: TSourceSpan);
    destructor Destroy; override;
    procedure SetFieldOffset(aOffset: Integer);
    procedure SetOwnerName(const aName: string);
    procedure SetFieldType(aType: TAurumType);
    function DetachObj: TAstExpr; // transfer ownership of the Obj out of this node
    property Obj: TAstExpr read FObj;
    property Field: string read FField;
    property FieldOffset: Integer read FFieldOffset;
    property OwnerName: string read FOwnerName;
    property FieldType: TAurumType read FFieldType write FFieldType;
  end;


  { Indexzugriff: expr[index] }
  TAstIndexAccess = class(TAstExpr)
  private
    FObj: TAstExpr;
    FIndex: TAstExpr;
  public
    constructor Create(aObj: TAstExpr; aIndex: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Obj: TAstExpr read FObj;
    property Index: TAstExpr read FIndex;
  end;

  { Type Cast: expr as Type }
  TAstCast = class(TAstExpr)
  private
    FExpr: TAstExpr;
    FCastType: TAurumType;
    FCastTypeName: string;  // Type name for resolution in sema
    FIsFunctionToPointer: Boolean;  // True if casting function to pointer (returns address)
  public
    constructor Create(aExpr: TAstExpr; aCastType: TAurumType; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Expr: TAstExpr read FExpr;
    property CastType: TAurumType read FCastType write FCastType;
    property CastTypeName: string read FCastTypeName write FCastTypeName;
    property IsFunctionToPointer: Boolean read FIsFunctionToPointer write FIsFunctionToPointer;
  end;

  { Function Pointer Type: fn(param1, param2) -> returnType }
  TAstFnPtrType = class(TAstExpr)
  private
    FParamTypes: array of TAurumType;
    FReturnType: TAurumType;
    FSignatureString: string;  // Cached signature for comparison
    function GetParamCount: Integer;
    function GetParamType(idx: Integer): TAurumType;
  public
    constructor Create(const aParamTypes: array of TAurumType; aReturnType: TAurumType; aSpan: TSourceSpan);
    destructor Destroy; override;
    property ParamCount: Integer read GetParamCount;
    property ParamTypes[idx: Integer]: TAurumType read GetParamType;
    property ReturnType: TAurumType read FReturnType write FReturnType;
    property SignatureString: string read FSignatureString;
  end;

  { Struct-Literal Feld-Initialisierer: name: expr }
  TStructFieldInit = record
    Name: string;
    Value: TAstExpr;
  end;
  TStructFieldInitList = array of TStructFieldInit;

  { Struct-Literal: TypeName { field1: val1, field2: val2 } }
  TAstStructLit = class(TAstExpr)
  private
    FTypeName: string;
    FFields: TStructFieldInitList;
    FStructDecl: TAstStructDecl; // set by sema, nil initially
  public
    constructor Create(const aTypeName: string; const aFields: TStructFieldInitList; aSpan: TSourceSpan);
    destructor Destroy; override;
    procedure SetStructDecl(aDecl: TAstStructDecl);
    property TypeName: string read FTypeName;
    property Fields: TStructFieldInitList read FFields;
    property StructDecl: TAstStructDecl read FStructDecl;
  end;

  // ================================================================
  // Statements
  // ================================================================

  TAstStmt = class(TAstNode)
  public
    constructor Create(aKind: TNodeKind; aSpan: TSourceSpan);
  end;

  { Nested function wrapper: fn innerName() { ... } inside a function body }
  TAstFuncStmt = class(TAstStmt)
  public
    FuncDecl: TAstFuncDecl;
    constructor Create(aFuncDecl: TAstFuncDecl);
  end;

  { Variable/Let/Co-Deklaration: var x: int64 := 42; }
  TAstVarDecl = class(TAstStmt)
  private
    FStorage: TStorageKlass;
    FName: string;
    FDeclType: TAurumType; // element type for arrays (primitive) or atUnresolved for named types
    FDeclTypeName: string; // if named type (struct), store the name here
    FArrayLen: Integer;    // 0 = not array, >0 = static length, -1 = dynamic array ([]) 
    FInitExpr: TAstExpr;
    FIsNullable: Boolean;  // true if type ends with ? (null-safety)
    FIsGlobal: Boolean;    // true if declared at top-level
    FIsPublic: Boolean;    // true if declared with 'pub'
    FIsRedundant: Boolean; // true if @redundant annotated (aerospace-todo P2 #51)
  public
    constructor Create(aStorage: TStorageKlass; const aName: string;
      aDeclType: TAurumType; const aDeclTypeName: string; aArrayLen: Integer; 
      aInitExpr: TAstExpr; aIsNullable: Boolean; aSpan: TSourceSpan);
    destructor Destroy; override;
    procedure SetGlobal(aIsGlobal, aIsPublic: Boolean);
    property Storage: TStorageKlass read FStorage;
    property Name: string read FName;
    property DeclType: TAurumType read FDeclType;
    property DeclTypeName: string read FDeclTypeName;
    property ArrayLen: Integer read FArrayLen;
    property InitExpr: TAstExpr read FInitExpr;
    property IsNullable: Boolean read FIsNullable;
    property IsGlobal: Boolean read FIsGlobal;
    property IsPublic: Boolean read FIsPublic;
    property IsRedundant: Boolean read FIsRedundant write FIsRedundant; // aerospace-todo P2 #51
  end;

  { Zuweisung: x := expr; }
  TAstAssign = class(TAstStmt)
  private
    FName: string;
    FValue: TAstExpr;
  public
    constructor Create(const aName: string; aValue: TAstExpr;
      aSpan: TSourceSpan);
    destructor Destroy; override;
    property Name: string read FName;
    property Value: TAstExpr read FValue;
  end;

  { Feld-Zuweisung: obj.field := value }
  TAstFieldAssign = class(TAstStmt)
  private
    FTarget: TAstFieldAccess; // the LHS field-access node
    FValue: TAstExpr;
  public
    constructor Create(aTarget: TAstFieldAccess; aValue: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Target: TAstFieldAccess read FTarget;
    property Value: TAstExpr read FValue;
  end;

  { Index-Zuweisung: arr[idx] := value }
  TAstIndexAssign = class(TAstStmt)
  private
    FTarget: TAstIndexAccess; // the LHS index-access node
    FValue: TAstExpr;
  public
    constructor Create(aTarget: TAstIndexAccess; aValue: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Target: TAstIndexAccess read FTarget;
    property Value: TAstExpr read FValue;
  end;

  { If-Statement: if (cond) thenStmt [else elseStmt] }
  TAstIf = class(TAstStmt)
  private
    FCond: TAstExpr;
    FThenBranch: TAstStmt;
    FElseBranch: TAstStmt; // kann nil sein
  public
    constructor Create(aCond: TAstExpr; aThen: TAstStmt;
      aElse: TAstStmt; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Cond: TAstExpr read FCond;
    property ThenBranch: TAstStmt read FThenBranch;
    property ElseBranch: TAstStmt read FElseBranch;
  end;

  { Break-Statement: break; }
  TAstBreak = class(TAstStmt)
  public
    constructor Create(aSpan: TSourceSpan);
  end;

  TAstContinue = class(TAstStmt)
  public
    constructor Create(aSpan: TSourceSpan);
  end;

  { Switch-Statement: switch (expr) { case val: stmt ... default: stmt }
    Cases are modelled as array of (ValueExpr, BodyStmt) }
  TAstCase = class
  public
    Value: TAstExpr;
    ExtraValues: array of TAstExpr;  // additional OR pattern values (for case 1|2|3)
    Body: TAstStmt;
    // Pattern bindings for struct patterns like Ok(v) or Err(e)
    Bindings: array of string;      // names of bound variables
    BindingExprs: array of TAstExpr; // expressions for bindings (e.g., Ok(v) -> result.value)
    constructor Create(aValue: TAstExpr; aBody: TAstStmt);
    destructor Destroy; override;
    procedure AddBinding(const name: string; expr: TAstExpr);
  end;
  TAstCaseList = array of TAstCase;

  TAstSwitch = class(TAstStmt)
  private
    FExpr: TAstExpr;
    FCases: TAstCaseList;
    FDefault: TAstStmt;
  public
    constructor Create(aExpr: TAstExpr; const aCases: TAstCaseList; aDefault: TAstStmt; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Expr: TAstExpr read FExpr;
    property Cases: TAstCaseList read FCases;
    property Default: TAstStmt read FDefault;
  end;

  { While-Statement: while (cond) [limit(n)] body }
  TAstWhile = class(TAstStmt)
  private
    FCond: TAstExpr;
    FBody: TAstStmt;
    FLimit: TAstExpr;  // Optional: Maximum iteration count for bounded while
  public
    constructor Create(aCond: TAstExpr; aBody: TAstStmt;
      aSpan: TSourceSpan);
    constructor CreateBounded(aCond: TAstExpr; aLimit: TAstExpr; aBody: TAstStmt;
      aSpan: TSourceSpan);
    destructor Destroy; override;
    function HasLimit: Boolean;
    property Cond: TAstExpr read FCond;
    property Body: TAstStmt read FBody;
    property Limit: TAstExpr read FLimit write FLimit;
    property IsBounded: Boolean read HasLimit;
  end;

  { For-Statement: for i := start to/downto end do stmt }
  TAstFor = class(TAstStmt)
  private
    FVarName: string;
    FStartExpr: TAstExpr;
    FEndExpr: TAstExpr;
    FIsDownto: Boolean;
    FBody: TAstStmt;
  public
    constructor Create(const aVarName: string; aStart, aEnd: TAstExpr;
      aDownto: Boolean; aBody: TAstStmt; aSpan: TSourceSpan);
    destructor Destroy; override;
    property VarName: string read FVarName;
    property StartExpr: TAstExpr read FStartExpr;
    property EndExpr: TAstExpr read FEndExpr;
    property IsDownto: Boolean read FIsDownto;
    property Body: TAstStmt read FBody;
  end;

  { Repeat-Until: repeat { body } until (cond); }
  TAstRepeatUntil = class(TAstStmt)
  private
    FBody: TAstStmt;
    FCond: TAstExpr;
  public
    constructor Create(aBody: TAstStmt; aCond: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Body: TAstStmt read FBody;
    property Cond: TAstExpr read FCond;
  end;

  { Return-Statement: return [expr]; }
  TAstReturn = class(TAstStmt)
  private
    FValue: TAstExpr; // kann nil sein (void-Funktionen)
  public
    constructor Create(aValue: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Value: TAstExpr read FValue;
  end;

  { Try-Statement: try { body } catch (e: int64) { handler } }
  TAstTry = class(TAstStmt)
  private
    FTryBody:    TAstStmt;
    FCatchVar:   string;    // name of the catch variable
    FCatchBody:  TAstStmt;
  public
    constructor Create(aTryBody: TAstStmt; const aCatchVar: string;
      aCatchBody: TAstStmt; aSpan: TSourceSpan);
    destructor Destroy; override;
    property TryBody:   TAstStmt read FTryBody;
    property CatchVar:  string   read FCatchVar;
    property CatchBody: TAstStmt read FCatchBody;
  end;

  { Throw-Statement: throw expr; }
  TAstThrow = class(TAstStmt)
  private
    FValue: TAstExpr;
  public
    constructor Create(aValue: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Value: TAstExpr read FValue;
  end;

  { Tuple literal: (expr1, expr2) — multi-return value }
  TAstTupleLit = class(TAstExpr)
  private
    FElems: TAstExprList;
  public
    constructor Create(const aElems: TAstExprList; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Elems: TAstExprList read FElems;
  end;

  { Tuple var decl: var name1, name2 := expr — destructuring multi-return }
  TAstTupleVarDecl = class(TAstStmt)
  private
    FNames:    TStringArray;
    FInitExpr: TAstExpr;
  public
    constructor Create(const aNames: TStringArray; aInit: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Names:    TStringArray read FNames;
    property InitExpr: TAstExpr    read FInitExpr;
  end;

  // Block: { stmt1; stmt2; ... }
  TAstBlock = class(TAstStmt)
  private
    FStmts: TAstStmtList;
  public
    constructor Create(const aStmts: TAstStmtList; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Stmts: TAstStmtList read FStmts;
  end;

  // Pool-Block: pool { ... } - Memory Pool für schnelle Allokation
  TAstPoolStmt = class(TAstStmt)
  private
    FBody: TAstStmt;
  public
    constructor Create(aBody: TAstStmt; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Body: TAstStmt read FBody;
  end;

  { Expression-Statement: expr; }
  TAstExprStmt = class(TAstStmt)
  private
    FExpr: TAstExpr;
  public
    constructor Create(aExpr: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Expr: TAstExpr read FExpr;
  end;

  // ================================================================
  // Top-Level Deklarationen
  // ================================================================

  { Funktionsparameter }
  TAstParam = record
    Name: string;
    ParamType: TAurumType;
    TypeName: string;  // for named types (structs)
    Span: TSourceSpan;
  end;
  TAstParamList = array of TAstParam;

  // Funktionsdeklaration: [pub] fn name(params): retType { body }
  TAstFuncDecl = class(TAstNode)
  private
    FName: string;
    FParams: TAstParamList;
    FReturnType: TAurumType;
    FReturnTypeName: string; // for named return types like Self or struct names
    FBody: TAstBlock;
    FIsPublic: Boolean;
    FIsExtern: Boolean;
    FIsVarArgs: Boolean;
    FIsStatic: Boolean; // true for static methods (no self parameter)
    FVisibility: TVisibility; // for class members (default: visPublic)
    FEnergyLevel: TEnergyLevel; // Energy-Aware-Compiling level (0 = use global)
    FSafetyPragmas: TSafetyPragmas; // Safety pragmas: @dal, @critical, @wcet, @stack_limit
    FLibraryName: string; // for external functions - library name to link against
    // VMT fields
    FIsVirtual: Boolean;
    FIsOverride: Boolean;
    FIsAbstract: Boolean;
    FVirtualTableIndex: Integer;
    // Constructor/Destructor
    FIsConstructor: Boolean;
    FIsDestructor: Boolean;
    // Closure / Nested function fields
    FCapturedVars: TAstCapturedVarList;
    FParentFuncName: string; // name of enclosing function (if nested)
    FNeedsStaticLink: Boolean; // true if this function captures variables
  public
    constructor Create(const aName: string; const aParams: TAstParamList;
      aReturnType: TAurumType; aBody: TAstBlock; aSpan: TSourceSpan; aIsPublic: Boolean = False);
    destructor Destroy; override;
    property Name: string read FName;
    property Params: TAstParamList read FParams;
    property ReturnType: TAurumType read FReturnType write FReturnType;
    property ReturnTypeName: string read FReturnTypeName write FReturnTypeName;
    property Body: TAstBlock read FBody write FBody;
    property IsPublic: Boolean read FIsPublic;
    property IsExtern: Boolean read FIsExtern write FIsExtern;
    property IsVarArgs: Boolean read FIsVarArgs write FIsVarArgs;
    property IsStatic: Boolean read FIsStatic write FIsStatic;
    property Visibility: TVisibility read FVisibility write FVisibility;
    property EnergyLevel: TEnergyLevel read FEnergyLevel write FEnergyLevel;
    property SafetyPragmas: TSafetyPragmas read FSafetyPragmas write FSafetyPragmas;
    property LibraryName: string read FLibraryName write FLibraryName;
    // VMT properties
    property IsVirtual: Boolean read FIsVirtual write FIsVirtual;
    property IsOverride: Boolean read FIsOverride write FIsOverride;
    property IsAbstract: Boolean read FIsAbstract write FIsAbstract;
    property VirtualTableIndex: Integer read FVirtualTableIndex write FVirtualTableIndex;
    // Constructor/Destructor
    property IsConstructor: Boolean read FIsConstructor write FIsConstructor;
    property IsDestructor: Boolean read FIsDestructor write FIsDestructor;
    // Closure properties
    property CapturedVars: TAstCapturedVarList read FCapturedVars;
    property ParentFuncName: string read FParentFuncName write FParentFuncName;
    property NeedsStaticLink: Boolean read FNeedsStaticLink write FNeedsStaticLink;
    procedure AddCapturedVar(const aName: string; aType: TAurumType; aOuterSlot: Integer);
    function HasCapturedVar(const aName: string): Boolean;
  public
    // Tuple return element types (populated when ReturnType = atTuple)
    TupleReturnTypes: array of TAurumType;
    // Generic type parameters, e.g., ['T'] for fn max[T](...)
    TypeParams: TStringArray;
  end;

  { Con-Deklaration (Top-Level): con NAME: type := constExpr; }
  TAstConDecl = class(TAstNode)
  private
    FName: string;
    FDeclType: TAurumType;
    FInitExpr: TAstExpr;
    FIsPublic: Boolean;
    FStorage: TStorageKlass;  // skCo oder skCon
  public
    constructor Create(const aName: string; aDeclType: TAurumType;
      aInitExpr: TAstExpr; aSpan: TSourceSpan; aIsPublic: Boolean = False; aStorage: TStorageKlass = skCo);
    destructor Destroy; override;
    property Name: string read FName;
    property DeclType: TAurumType read FDeclType;
    property InitExpr: TAstExpr read FInitExpr;
    property IsPublic: Boolean read FIsPublic;
    property Storage: TStorageKlass read FStorage;
  end;

  { Enum-Deklaration: enum Name { VALUE1; VALUE2 := 5; ... }; }
  TEnumValue = record
    Name:  string;
    Value: Int64;
  end;
  TEnumValueList = array of TEnumValue;

  TAstEnumDecl = class(TAstNode)
  private
    FName:     string;
    FValues:   TEnumValueList;
    FIsPublic: Boolean;
  public
    constructor Create(const aName: string; const aValues: TEnumValueList;
      aPublic: Boolean; aSpan: TSourceSpan);
    property Name:     string         read FName;
    property Values:   TEnumValueList read FValues;
    property IsPublic: Boolean        read FIsPublic;
  end;

  { Type-Deklaration (Top-Level): type Name = Type; oder type Name = int64 range Min..Max; }
  TAstTypeDecl = class(TAstNode)
  private
    FName: string;
    FDeclType: TAurumType;
    FTypeName: string;   // for named base types (e.g. structs used as alias base)
    FIsPublic: Boolean;
    FConstraint: TAstExpr; // Bedingung für typsichere Typen (z.B. value >= 0 && value <= 100)
    // Range-Typ-Felder (aerospace-todo P1 #7)
    FHasRange: Boolean;  // true wenn range-Annotation vorhanden
    FRangeMin: Int64;    // untere Schranke (inklusiv)
    FRangeMax: Int64;    // obere Schranke (inklusiv)
  public
    constructor Create(const aName: string; aDeclType: TAurumType;
      aPublic: Boolean; aConstraint: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Name: string read FName;
    property DeclType: TAurumType read FDeclType;
    property TypeName: string read FTypeName write FTypeName;
    property IsPublic: Boolean read FIsPublic;
    property Constraint: TAstExpr read FConstraint;
    // Range type
    property HasRange: Boolean read FHasRange write FHasRange;
    property RangeMin: Int64 read FRangeMin write FRangeMin;
    property RangeMax: Int64 read FRangeMax write FRangeMax;
  end;

  { Struct/Type-Deklaration mit Feldern und Methoden }
  TStructField = record
    Name: string;
    FieldType: TAurumType;
    FieldTypeName: string; // if named type
    ArrayLen: Integer; // 0 = scalar, >0 static, -1 dynamic
    Visibility: TVisibility; // for class fields (default: visPublic)
    BitOffset: Integer;  // -1 = auto (normal), >=0 = explicit bit position (aerospace-todo P2 #50)
    // parameterized-type metadata (atDynArray/atArray/atSet: ElemType; atMap: KeyType+ValType)
    ElemType:     TAurumType; // element type for []T, [N]T, Set<T>
    ElemTypeName: string;     // named element type (struct/class)
    KeyType:      TAurumType; // key type for Map<K,V>
    KeyTypeName:  string;     // named key type
    ValType:      TAurumType; // value type for Map<K,V>
    ValTypeName:  string;     // named value type
  end;
  TStructFieldList = array of TStructField;
  TMethodList = array of TAstFuncDecl;

  TAstStructDecl = class(TAstNode)
  private
    FName: string;
    FFields: TStructFieldList;
    FMethods: TMethodList; // reuse TAstFuncDecl for method declarations
    FIsPublic: Boolean;
    FEndian: TEndianType; // endianness annotation (aerospace-todo P2 #52)
    FIsFlat: Boolean;     // flat struct: no pointer fields allowed (aerospace-todo P2 #57)
    FIsPacked: Boolean;   // @packed struct: no padding, bit-level field mapping (aerospace-todo P2 #50)
    // layout info (bytes)
    FFieldOffsets: array of Integer; // offset per field
    FSize: Integer; // total size in bytes
    FAlign: Integer; // alignment in bytes
  public
    constructor Create(const aName: string; const aFields: TStructFieldList;
      const aMethods: TMethodList; aPublic: Boolean; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Name: string read FName;
    property Fields: TStructFieldList read FFields;
    property Methods: TMethodList read FMethods;
    property IsPublic: Boolean read FIsPublic;
    property Endian: TEndianType read FEndian write FEndian; // aerospace-todo P2 #52
    property IsFlat: Boolean read FIsFlat write FIsFlat;     // aerospace-todo P2 #57
    property IsPacked: Boolean read FIsPacked write FIsPacked; // aerospace-todo P2 #50
    property FieldOffsets: TIntArray read FFieldOffsets write FFieldOffsets;
    property Size: Integer read FSize write FSize;
    property Align: Integer read FAlign;
    procedure SetLayout(aSize, aAlign: Integer);
  end;

  { Interface-Deklaration }
  TAstInterfaceDecl = class(TAstNode)
  private
    FName: string;
    FMethods: TMethodList;  // nur Methodensignaturen (keine bodies)
    FIsPublic: Boolean;
    FMethodOffsets: array of Integer;  // für IMT (Interface Method Table)
  public
    constructor Create(const aName: string; const aMethods: TMethodList;
      aPublic: Boolean; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Name: string read FName;
    property Methods: TMethodList read FMethods;
    property IsPublic: Boolean read FIsPublic;
    property MethodOffsets: TIntArray read FMethodOffsets;
  end;

  { Class-Deklaration mit Vererbung }
  TAstClassDecl = class(TAstNode)
  private
    FName: string;
    FBaseClassName: string; // nil/empty if no base class
    FParentVMTLabel: string; // Label for parent VMT (for RTTI)
    FFields: TStructFieldList;
    FMethods: TMethodList;
    // VMT fields
    FVirtualMethods: TMethodList;  // Nur virtuelle Methoden
    FVMTName: string;               // "_vmt_ClassName"
    FClassNameLabel: string;        // Label for class name string in .rodata
    FIsPublic: Boolean;
    FIsAbstract: Boolean;
    // Interface fields
    FImplementedInterfaces: TStringArray;  // Liste der Interface-Namen
    FIMTName: string;  // "_imt_ClassName" Interface Method Table
    // layout info (computed by sema)
    FFieldOffsets: array of Integer;
    FSize: Integer;  // total size including base class fields
    FAlign: Integer;
    FBaseSize: Integer; // size of base class fields
  public
    constructor Create(const aName, aBaseClass: string;
      const aFields: TStructFieldList; const aMethods: TMethodList;
      aPublic: Boolean; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Name: string read FName;
    property BaseClassName: string read FBaseClassName;
    property ParentVMTLabel: string read FParentVMTLabel write FParentVMTLabel;
    property Fields: TStructFieldList read FFields;
    property Methods: TMethodList read FMethods;
    // VMT properties
    property VirtualMethods: TMethodList read FVirtualMethods write FVirtualMethods;
    property VMTName: string read FVMTName write FVMTName;
    property ClassNameLabel: string read FClassNameLabel write FClassNameLabel;
    property IsPublic: Boolean read FIsPublic;
    property IsAbstract: Boolean read FIsAbstract write FIsAbstract;
    // Interface properties
    property ImplementedInterfaces: TStringArray read FImplementedInterfaces write FImplementedInterfaces;
    property IMTName: string read FIMTName;
    property FieldOffsets: TIntArray read FFieldOffsets write FFieldOffsets;
    property Size: Integer read FSize write FSize;
    property Align: Integer read FAlign;
    property BaseSize: Integer read FBaseSize;
    procedure SetLayout(aSize, aAlign, aBaseSize: Integer);
    procedure SetBaseClassName(const aBaseClass: string);
    procedure AddVirtualMethod(method: TAstFuncDecl);
    procedure AddImplementedInterface(const ifaceName: string);
  end;

  { new Ausdruck: new ClassName() oder new ClassName(args) }
  TAstNewExpr = class(TAstExpr)
  private
    FClassName: string;
    FArgs: TAstExprList;
    FConstructorName: string;  // 'new' or 'Create'
  public
    constructor Create(const aClassName: string; aSpan: TSourceSpan);
    constructor CreateWithArgs(const aClassName: string; const aArgs: array of TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property ClassName: string read FClassName;
    property Args: TAstExprList read FArgs;
    property ConstructorName: string read FConstructorName write FConstructorName;
  end;

  { dispose Statement: dispose expr; }
  TAstDispose = class(TAstStmt)
  private
    FExpr: TAstExpr;
  public
    constructor Create(aExpr: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Expr: TAstExpr read FExpr;
  end;

  { assert Statement: assert(condition, message); }
  TAstAssert = class(TAstStmt)
  private
    FCondition: TAstExpr;
    FMessage: TAstExpr;
  public
    constructor Create(aCondition, aMessage: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Condition: TAstExpr read FCondition;
    property Message: TAstExpr read FMessage;
  end;

  { super.method() Aufruf }
  TAstSuperCall = class(TAstExpr)
  private
    FMethodName: string;
    FArgs: TAstExprList;
  public
    constructor Create(const aMethodName: string; const aArgs: TAstExprList; aSpan: TSourceSpan);
    destructor Destroy; override;
    property MethodName: string read FMethodName;
    property Args: TAstExprList read FArgs;
  end;

  { panic(message) - bricht Programm mit Fehlermeldung ab }
  TAstPanicExpr = class(TAstExpr)
  private
    FMessage: TAstExpr;
  public
    constructor Create(aMessage: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Message: TAstExpr read FMessage;
  end;

  { check(condition) - runtime-only assertion, panics if false without message }
  TAstCheckExpr = class(TAstExpr)
  private
    FCondition: TAstExpr;
  public
    constructor Create(aCondition: TAstExpr; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Condition: TAstExpr read FCondition;
  end;

  { Inspect(expr) - In-Situ Data Visualizer für Debugging }
  { Gibt zur Laufzeit eine formatierte Darstellung des Werts aus }
  TInspectFormat = (
    ifAuto,       // automatisch basierend auf Typ
    ifTable,      // Tabelle für Maps/Structs
    ifTree,       // Baumstruktur für verschachtelte Daten
    ifHex,        // Hexadezimal für Integers
    ifBinary      // Binär für Integers
  );

  TAstInspect = class(TAstExpr)
  private
    FExpr: TAstExpr;
    FVarName: string;        // Name der Variable (für Anzeige)
    FFormat: TInspectFormat; // Ausgabeformat
    FInspectedType: TAurumType; // Typ des inspizierten Ausdrucks (von Sema gesetzt)
    FStructName: string;     // Struct/Class Name wenn relevant
    FFieldNames: TStringArray; // Feldnamen für Structs (von Sema gefüllt)
    FFieldOffsets: TIntArray;  // Feldoffsets für Structs
    FFieldTypes: array of TAurumType; // Feldtypen für Structs
  public
    constructor Create(aExpr: TAstExpr; const aVarName: string; 
      aFormat: TInspectFormat; aSpan: TSourceSpan);
    destructor Destroy; override;
    procedure SetTypeInfo(aType: TAurumType; const aStructName: string);
    procedure SetStructFields(const aNames: TStringArray; 
      const aOffsets: TIntArray; const aTypes: array of TAurumType);
    property Expr: TAstExpr read FExpr;
    property VarName: string read FVarName;
    property Format: TInspectFormat read FFormat;
    property InspectedType: TAurumType read FInspectedType;
    property StructName: string read FStructName;
    property FieldNames: TStringArray read FFieldNames;
    property FieldOffsets: TIntArray read FFieldOffsets;
  end;

  { Unit-Deklaration: unit path.to.name; }
  TAstUnitDecl = class(TAstNode)
  private
    FUnitPath: string;
    FIntegrityAttr: TIntegrityAttr; // @integrity(mode:..., interval:N) before unit decl
  public
    constructor Create(const aPath: string; aSpan: TSourceSpan);
    property UnitPath: string read FUnitPath;
    property IntegrityAttr: TIntegrityAttr read FIntegrityAttr write FIntegrityAttr;
  end;

  { Import-Item }
  TAstImportItem = record
    Name: string;
    Alias: string; // leer wenn kein 'as'
  end;
  TAstImportItemList = array of TAstImportItem;

  { Import-Deklaration: import path [as alias] [{ items }]; }
  TAstImportDecl = class(TAstNode)
  private
    FUnitPath: string;
    FAlias: string;
    FItems: TAstImportItemList;
  public
    constructor Create(const aPath, aAlias: string;
      const aItems: TAstImportItemList; aSpan: TSourceSpan);
    property UnitPath: string read FUnitPath;
    property Alias: string read FAlias;
    property Items: TAstImportItemList read FItems;
  end;

  { Programm (Wurzelknoten): Liste von Top-Level Deklarationen }
  TAstProgram = class(TAstNode)
  private
    FDecls: TAstNodeList;
  public
    constructor Create(const aDecls: TAstNodeList; aSpan: TSourceSpan);
    destructor Destroy; override;
    property Decls: TAstNodeList read FDecls;
  end;

  // ================================================================
  // LFD (LyX Form Description) AST Nodes
  // ================================================================

  { LFD Property: name: value oder name: "value" }
  TLfdProperty = class(TAstNode)
  private
    FName: string;
    FValue: string;
  public
    constructor Create(const aName, aValue: string; aSpan: TSourceSpan);
    property Name: string read FName;
    property Value: string read FValue;
  end;
  TLfdPropertyList = array of TLfdProperty;

  { LFD Signal: OnClick: "handler()" }
  TLfdSignal = class(TAstNode)
  private
    FSignalKind: TLfdSignalKind;
    FHandlerName: string;
  public
    constructor Create(aSignalKind: TLfdSignalKind; const aHandlerName: string; aSpan: TSourceSpan);
    property SignalKind: TLfdSignalKind read FSignalKind;
    property HandlerName: string read FHandlerName;
  end;
  TLfdSignalList = array of TLfdSignal;

  { LFD Widget-Liste (Knoten in einem Layout oder Form) }
  TAstLfdNodeList = array of TAstNode;

  { LFD Layout: Layout Vertical { ... } oder Layout Horizontal { ... } }
  TLfdLayout = class(TAstNode)
  private
    FLayoutKind: TLfdLayoutKind;
    FChildren: TAstLfdNodeList;
    FSpacing: Integer;       // -1 = default
    FMarginTop: Integer;
    FMarginBottom: Integer;
    FMarginLeft: Integer;
    FMarginRight: Integer;
  public
    constructor Create(aLayoutKind: TLfdLayoutKind; const aChildren: TAstLfdNodeList; aSpan: TSourceSpan);
    destructor Destroy; override;
    property LayoutKind: TLfdLayoutKind read FLayoutKind;
    property Children: TAstLfdNodeList read FChildren;
    property Spacing: Integer read FSpacing write FSpacing;
    property MarginTop: Integer read FMarginTop write FMarginTop;
    property MarginBottom: Integer read FMarginBottom write FMarginBottom;
    property MarginLeft: Integer read FMarginLeft write FMarginLeft;
    property MarginRight: Integer read FMarginRight write FMarginRight;
  end;

  { LFD Widget: Button btnOk { Text: "OK" OnClick: "handleOk()" } }
  TLfdWidget = class(TAstNode)
  private
    FWidgetKind: TLfdWidgetKind;
    FName: string;
    FProperties: TLfdPropertyList;
    FSignals: TLfdSignalList;
    FChildren: TAstLfdNodeList;  // Für Container-Widgets (GroupBox, TabWidget, etc.)
  public
    constructor Create(aWidgetKind: TLfdWidgetKind; const aName: string;
      const aProperties: TLfdPropertyList; const aSignals: TLfdSignalList;
      const aChildren: TAstLfdNodeList; aSpan: TSourceSpan);
    destructor Destroy; override;
    property WidgetKind: TLfdWidgetKind read FWidgetKind;
    property Name: string read FName;
    property Properties: TLfdPropertyList read FProperties;
    property Signals: TLfdSignalList read FSignals;
    property Children: TAstLfdNodeList read FChildren;
    function GetProperty(const aName: string): string;
    function GetSignal(aSignalKind: TLfdSignalKind): string;
  end;

  { LFD Form: Form MainWindow "Title" { ... } }
  TLfdForm = class(TAstNode)
  private
    FName: string;
    FTitle: string;
    FChildren: TAstLfdNodeList;  // Widgets und Layouts auf oberster Ebene
    FProperties: TLfdPropertyList;
  public
    constructor Create(const aName, aTitle: string;
      const aChildren: TAstLfdNodeList; const aProperties: TLfdPropertyList;
      aSpan: TSourceSpan);
    destructor Destroy; override;
    property Name: string read FName;
    property Title: string read FTitle;
    property Children: TAstLfdNodeList read FChildren;
    property Properties: TLfdPropertyList read FProperties;
    function GetProperty(const aName: string): string;
  end;

{ --- Hilfsfunktionen für Nullable-Typen --- }

function IsNullableType(t: TAurumType): Boolean;
function IsPointerType(t: TAurumType): Boolean;
function BaseTypeOf(t: TAurumType): TAurumType;
function NullableVersion(t: TAurumType): TAurumType;
function NonNullableVersion(t: TAurumType): TAurumType;

{ --- Hilfsfunktionen --- }

function AurumTypeToStr(t: TAurumType): string;
function StrToAurumType(const s: string): TAurumType;
function StorageKlassToStr(sk: TStorageKlass): string;
function NodeKindToStr(nk: TNodeKind): string;

implementation

{ ================================================================ }
{ LFD (LyX Form Description) Implementation }
{ ================================================================ }

constructor TLfdProperty.Create(const aName, aValue: string; aSpan: TSourceSpan);
begin
  inherited Create(nkLfdProperty, aSpan);
  FName := aName;
  FValue := aValue;
end;

constructor TLfdSignal.Create(aSignalKind: TLfdSignalKind; const aHandlerName: string; aSpan: TSourceSpan);
begin
  inherited Create(nkLfdSignal, aSpan);
  FSignalKind := aSignalKind;
  FHandlerName := aHandlerName;
end;

constructor TLfdLayout.Create(aLayoutKind: TLfdLayoutKind; const aChildren: TAstLfdNodeList; aSpan: TSourceSpan);
begin
  inherited Create(nkLfdLayout, aSpan);
  FLayoutKind := aLayoutKind;
  FChildren := aChildren;
  FSpacing := -1;
  FMarginTop := -1;
  FMarginBottom := -1;
  FMarginLeft := -1;
  FMarginRight := -1;
end;

destructor TLfdLayout.Destroy;
var i: Integer;
begin
  for i := 0 to High(FChildren) do
    FChildren[i].Free;
  inherited Destroy;
end;

constructor TLfdWidget.Create(aWidgetKind: TLfdWidgetKind; const aName: string;
  const aProperties: TLfdPropertyList; const aSignals: TLfdSignalList;
  const aChildren: TAstLfdNodeList; aSpan: TSourceSpan);
begin
  inherited Create(nkLfdWidget, aSpan);
  FWidgetKind := aWidgetKind;
  FName := aName;
  FProperties := aProperties;
  FSignals := aSignals;
  FChildren := aChildren;
end;

destructor TLfdWidget.Destroy;
var i: Integer;
begin
  for i := 0 to High(FProperties) do
    FProperties[i].Free;
  for i := 0 to High(FSignals) do
    FSignals[i].Free;
  for i := 0 to High(FChildren) do
    FChildren[i].Free;
  inherited Destroy;
end;

function TLfdWidget.GetProperty(const aName: string): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to High(FProperties) do
    if FProperties[i].Name = aName then
    begin
      Result := FProperties[i].Value;
      Exit;
    end;
end;

function TLfdWidget.GetSignal(aSignalKind: TLfdSignalKind): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to High(FSignals) do
    if FSignals[i].SignalKind = aSignalKind then
    begin
      Result := FSignals[i].HandlerName;
      Exit;
    end;
end;

constructor TLfdForm.Create(const aName, aTitle: string;
  const aChildren: TAstLfdNodeList; const aProperties: TLfdPropertyList;
  aSpan: TSourceSpan);
begin
  inherited Create(nkLfdForm, aSpan);
  FName := aName;
  FTitle := aTitle;
  FChildren := aChildren;
  FProperties := aProperties;
end;

destructor TLfdForm.Destroy;
var i: Integer;
begin
  for i := 0 to High(FChildren) do
    FChildren[i].Free;
  for i := 0 to High(FProperties) do
    FProperties[i].Free;
  inherited Destroy;
end;

function TLfdForm.GetProperty(const aName: string): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to High(FProperties) do
    if FProperties[i].Name = aName then
    begin
      Result := FProperties[i].Value;
      Exit;
    end;
end;

{ --- Hilfsfunktionen für Nullable-Typen --- }

function IsNullableType(t: TAurumType): Boolean;
begin
  Result := t = atPCharNullable;
end;

// IsPointerType: returns true if t is any pointer type (aerospace-todo P2 #57)
function IsPointerType(t: TAurumType): Boolean;
begin
  Result := t in [atPChar, atPCharNullable, atFnPtr];
end;

function BaseTypeOf(t: TAurumType): TAurumType;
begin
  if t = atPCharNullable then
    Result := atPChar
  else
    Result := t;
end;

function NullableVersion(t: TAurumType): TAurumType;
begin
  if t = atPChar then
    Result := atPCharNullable
  else
    Result := t;
end;

function NonNullableVersion(t: TAurumType): TAurumType;
begin
  if t = atPCharNullable then
    Result := atPChar
  else
    Result := t;
end;

{ --- Hilfsfunktionen --- }

function AurumTypeToStr(t: TAurumType): string;
begin
  case t of
    atUnresolved: Result := '<unresolved>';
    atInt8:       Result := 'int8';
    atInt16:      Result := 'int16';
    atInt32:      Result := 'int32';
    atInt64:      Result := 'int64';
    atUInt8:      Result := 'uint8';
    atUInt16:     Result := 'uint16';
    atUInt32:     Result := 'uint32';
    atUInt64:     Result := 'uint64';
    atISize:      Result := 'isize';
    atUSize:      Result := 'usize';
    atF32:        Result := 'f32';
    atF64:        Result := 'f64';
    atChar:       Result := 'char';
    atBool:       Result := 'bool';
    atVoid:       Result := 'void';
    atPChar:      Result := 'pchar';
    atPCharNullable: Result := 'pchar?';
    atDynArray:    Result := 'array';
    atArray:       Result := 'static_array';
    atMap:         Result := 'Map';
    atSet:         Result := 'Set';
    atRingBuffer:  Result := 'RingBuffer'; // aerospace-todo P2 #56
    atFnPtr:       Result := 'fn';  // Treat as int64 internally for now
    atTuple:       Result := 'tuple';
  else
    Result := '<unknown>';
  end;
end;

function StrToAurumType(const s: string): TAurumType;
begin
  case s of
    'int8':   Result := atInt8;
    'int16':  Result := atInt16;
    'int32':  Result := atInt32;
    'int64':  Result := atInt64;
    'int':    Result := atInt64; // alias
    'uint8':  Result := atUInt8;
    'uint16': Result := atUInt16;
    'uint32': Result := atUInt32;
    'uint64': Result := atUInt64;
    'isize':  Result := atISize;
    'usize':  Result := atUSize;
    'f32':    Result := atF32;
    'f64':    Result := atF64;
    'char':   Result := atChar;
    'bool':   Result := atBool;
    'void':   Result := atVoid;
    'pchar':  Result := atPChar;
    'pchar?': Result := atPCharNullable;
    'string': Result := atPChar; // map string to pchar for now
    'array':  Result := atDynArray;
    'Map':    Result := atMap;
    'Set':    Result := atSet;
    'RingBuffer': Result := atRingBuffer; // aerospace-todo P2 #56
  else
    Result := atUnresolved;
  end;
end;

function StorageKlassToStr(sk: TStorageKlass): string;
begin
  case sk of
    skVar: Result := 'var';
    skLet: Result := 'let';
    skCo:  Result := 'co';
    skCon: Result := 'con';
  end;
end;

function NodeKindToStr(nk: TNodeKind): string;
begin
  case nk of
    nkIntLit:      Result := 'IntLit';
    nkFloatLit:    Result := 'FloatLit';
    nkStrLit:      Result := 'StrLit';
    nkBoolLit:     Result := 'BoolLit';
    nkCharLit:     Result := 'CharLit';
    nkRegexLit:    Result := 'RegexLit';
    nkIdent:       Result := 'Ident';
    nkBinOp:       Result := 'BinOp';
    nkUnaryOp:     Result := 'UnaryOp';
    nkCall:        Result := 'Call';
    nkArrayLit:    Result := 'ArrayLit';
    nkStructLit:   Result := 'StructLit';
    nkFieldAccess: Result := 'FieldAccess';
    nkIndexAccess: Result := 'IndexAccess';
    nkCast:       Result := 'Cast';
    nkNewExpr:     Result := 'NewExpr';
    nkSuperCall:   Result := 'SuperCall';
    nkVarDecl:     Result := 'VarDecl';
    nkAssign:      Result := 'Assign';
    nkFieldAssign: Result := 'FieldAssign';
    nkIndexAssign: Result := 'IndexAssign';
    nkIf:          Result := 'If';
    nkWhile:       Result := 'While';
    nkFor:         Result := 'For';
    nkRepeatUntil: Result := 'RepeatUntil';
    nkPool:        Result := 'Pool';
    nkReturn:      Result := 'Return';
    nkBreak:       Result := 'Break';
    nkContinue:    Result := 'Continue';
    nkSwitch:      Result := 'Switch';
    nkBlock:       Result := 'Block';
    nkExprStmt:    Result := 'ExprStmt';
    nkDispose:     Result := 'Dispose';
    nkFuncDecl:    Result := 'FuncDecl';
    nkConDecl:     Result := 'ConDecl';
    nkTypeDecl:    Result := 'TypeDecl';
    nkConstrainedTypeDecl: Result := 'ConstrainedTypeDecl';
    nkStructDecl:  Result := 'StructDecl';
    nkClassDecl:   Result := 'ClassDecl';
    nkInterfaceDecl: Result := 'InterfaceDecl';
    nkUnitDecl:     Result := 'UnitDecl';
    nkImportDecl:  Result := 'ImportDecl';
    nkProgram:     Result := 'Program';
    nkInspect:     Result := 'Inspect';
  else
    Result := '<unknown>';
  end;
end;

// ================================================================

// Provenance Tracking (WP-F): global AST ID counter
var
  GAstIDCounter: Integer = 0;

function GetNextAstID: Integer;
begin
  Result := GAstIDCounter;
  Inc(GAstIDCounter);
end;

// ================================================================

// TAstNode
// ================================================================

constructor TAstNode.Create(aKind: TNodeKind; aSpan: TSourceSpan);
begin
  inherited Create;
  FKind := aKind;
  FSpan := aSpan;
  // Provenance Tracking (WP-F): assign unique AST ID
  FID := GetNextAstID;
end;

destructor TAstNode.Destroy;
begin
  inherited Destroy;
end;

// ================================================================
// TAstExpr
// ================================================================

constructor TAstExpr.Create(aKind: TNodeKind; aSpan: TSourceSpan);
begin
  inherited Create(aKind, aSpan);
  FResolvedType := atUnresolved;
end;

// ================================================================
// TAstIntLit
// ================================================================

constructor TAstIntLit.Create(aValue: Int64; aSpan: TSourceSpan);
begin
  inherited Create(nkIntLit, aSpan);
  FValue := aValue;
  FResolvedType := atInt64;
end;

// ================================================================
// TAstStrLit
// ================================================================

constructor TAstStrLit.Create(const aValue: string; aSpan: TSourceSpan);
begin
  inherited Create(nkStrLit, aSpan);
  FValue := aValue;
  FResolvedType := atPChar;
end;

// ================================================================
// TAstBoolLit
// ================================================================

constructor TAstBoolLit.Create(aValue: Boolean; aSpan: TSourceSpan);
begin
  inherited Create(nkBoolLit, aSpan);
  FValue := aValue;
  FResolvedType := atBool;
end;

// ================================================================
// TAstFloatLit
// ================================================================

constructor TAstFloatLit.Create(aValue: Double; aSpan: TSourceSpan);
begin
  inherited Create(nkFloatLit, aSpan);
  FValue := aValue;
  FResolvedType := atF64;
end;

// ================================================================
// TAstIdent
// ================================================================

constructor TAstIdent.Create(const aName: string; aSpan: TSourceSpan);
begin
  inherited Create(nkIdent, aSpan);
  FName := aName;
end;

// ================================================================
// TAstFormatExpr
// ================================================================

constructor TAstFormatExpr.Create(aExpr: TAstExpr; aWidth, aDecimals: Integer; aSpan: TSourceSpan);
begin
  inherited Create(nkFormatExpr, aSpan);
  FExpr := aExpr;
  FWidth := aWidth;
  FDecimals := aDecimals;
end;

destructor TAstFormatExpr.Destroy;
begin
  FExpr.Free;
  inherited Destroy;
end;

// ================================================================
// TAstBinOp
// ================================================================

constructor TAstBinOp.Create(aOp: TTokenKind; aLeft, aRight: TAstExpr;
  aSpan: TSourceSpan);
begin
  inherited Create(nkBinOp, aSpan);
  FOp := aOp;
  FLeft := aLeft;
  FRight := aRight;
end;

destructor TAstBinOp.Destroy;
begin
  FLeft.Free;
  FRight.Free;
  inherited Destroy;
end;

// ================================================================
// TAstUnaryOp
// ================================================================

constructor TAstUnaryOp.Create(aOp: TTokenKind; aOperand: TAstExpr;
  aSpan: TSourceSpan);
begin
  inherited Create(nkUnaryOp, aSpan);
  FOp := aOp;
  FOperand := aOperand;
end;

destructor TAstUnaryOp.Destroy;
begin
  FOperand.Free;
  inherited Destroy;
end;

// ================================================================
// TAstCall
// ================================================================

constructor TAstCall.Create(const aName: string; const aArgs: TAstExprList; aSpan: TSourceSpan);
begin
  inherited Create(nkCall, aSpan);
  FName := aName;
  FArgs := aArgs;
  FIsPatternBinding := False;
end;

procedure TAstCall.SetName(const aName: string);
begin
  FName := aName;
end;

procedure TAstCall.SetArgs(const aArgs: TAstExprList);
var i: Integer;
begin
  // free previous args
  for i := 0 to High(FArgs) do
    FArgs[i].Free;
  FArgs := aArgs;
end;

procedure TAstCall.ReplaceArgs(const aArgs: TAstExprList);
begin
  // Replace args without freeing old ones (caller is responsible)
  FArgs := aArgs;
end;

destructor TAstCall.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FArgs) do
    FArgs[i].Free;
  FArgs := nil;
  inherited Destroy;
end;


  constructor TAstArrayLit.Create(const aItems: TAstExprList; aSpan: TSourceSpan);
begin
  inherited Create(nkArrayLit, aSpan);
  FItems := aItems;
  FElemType := atUnresolved;  // Will be set during semantic analysis
end;

destructor TAstArrayLit.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    FItems[i].Free;
  FItems := nil;
  inherited Destroy;
end;

// ================================================================
// TAstMapLit
// ================================================================

constructor TAstMapLit.Create(const aEntries: TMapEntryList; aSpan: TSourceSpan);
begin
  inherited Create(nkMapLit, aSpan);
  FEntries := aEntries;
  FKeyType := atUnresolved;
  FValueType := atUnresolved;
end;

destructor TAstMapLit.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FEntries) do
  begin
    FEntries[i].Key.Free;
    FEntries[i].Value.Free;
  end;
  FEntries := nil;
  inherited Destroy;
end;

// ================================================================
// TAstSetLit
// ================================================================

constructor TAstSetLit.Create(const aItems: TAstExprList; aSpan: TSourceSpan);
begin
  inherited Create(nkSetLit, aSpan);
  FItems := aItems;
  FElemType := atUnresolved;
end;

destructor TAstSetLit.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    FItems[i].Free;
  FItems := nil;
  inherited Destroy;
end;

// ================================================================
// TAstInExpr
// ================================================================

constructor TAstInExpr.Create(aKey, aContainer: TAstExpr; aSpan: TSourceSpan);
begin
  inherited Create(nkInExpr, aSpan);
  FKey := aKey;
  FContainer := aContainer;
end;

destructor TAstInExpr.Destroy;
begin
  FKey.Free;
  FContainer.Free;
  inherited Destroy;
end;

// ================================================================
// TAstIsExpr
// ================================================================

constructor TAstIsExpr.Create(aExpr: TAstExpr; const aClassName: string; aSpan: TSourceSpan);
begin
  inherited Create(nkIsExpr, aSpan);
  FExpr := aExpr;
  FClassName := aClassName;
end;

destructor TAstIsExpr.Destroy;
begin
  FExpr.Free;
  inherited Destroy;
end;

// ================================================================
// TAstSIMDNew
// ================================================================

constructor TAstSIMDNew.Create(aSize: TAstExpr; aElemType: TAurumType; aKind: TSIMDKind; aSpan: TSourceSpan);
begin
  inherited Create(nkSIMDNew, aSpan);
  FSize := aSize;
  FElementType := aElemType;
  FSIMDKind := aKind;
end;

destructor TAstSIMDNew.Destroy;
begin
  FSize.Free;
  inherited Destroy;
end;

// ================================================================
// TAstSIMDBinOp
// ================================================================

constructor TAstSIMDBinOp.Create(aOp: TTokenKind; aLeft, aRight: TAstExpr; aKind: TSIMDKind; aSpan: TSourceSpan);
begin
  inherited Create(nkSIMDBinOp, aSpan);
  FOp := aOp;
  FLeft := aLeft;
  FRight := aRight;
  FSIMDKind := aKind;
end;

destructor TAstSIMDBinOp.Destroy;
begin
  FLeft.Free;
  FRight.Free;
  inherited Destroy;
end;

// ================================================================
// TAstSIMDUnaryOp
// ================================================================

constructor TAstSIMDUnaryOp.Create(aOp: TTokenKind; aOperand: TAstExpr; aKind: TSIMDKind; aSpan: TSourceSpan);
begin
  inherited Create(nkSIMDUnaryOp, aSpan);
  FOp := aOp;
  FOperand := aOperand;
  FSIMDKind := aKind;
end;

destructor TAstSIMDUnaryOp.Destroy;
begin
  FOperand.Free;
  inherited Destroy;
end;

// ================================================================
// TAstSIMDIndexAccess
// ================================================================

constructor TAstSIMDIndexAccess.Create(aObj, aIndex: TAstExpr; aSpan: TSourceSpan);
begin
  inherited Create(nkSIMDIndexAccess, aSpan);
  FObj := aObj;
  FIndex := aIndex;
end;

destructor TAstSIMDIndexAccess.Destroy;
begin
  FObj.Free;
  FIndex.Free;
  inherited Destroy;
end;

// ================================================================
// TAstStmt
// ================================================================

constructor TAstStmt.Create(aKind: TNodeKind; aSpan: TSourceSpan);
begin
  inherited Create(aKind, aSpan);
end;

constructor TAstFuncStmt.Create(aFuncDecl: TAstFuncDecl);
begin
  inherited Create(nkFuncDecl, aFuncDecl.Span);
  FuncDecl := aFuncDecl;
end;

// ================================================================
// TAstVarDecl
// ================================================================

constructor TAstVarDecl.Create(aStorage: TStorageKlass;
  const aName: string; aDeclType: TAurumType; const aDeclTypeName: string; aArrayLen: Integer; 
  aInitExpr: TAstExpr; aIsNullable: Boolean; aSpan: TSourceSpan);
begin
  inherited Create(nkVarDecl, aSpan);
  FStorage := aStorage;
  FName := aName;
  FDeclType := aDeclType;
  FDeclTypeName := aDeclTypeName;
  FArrayLen := aArrayLen;
  FInitExpr := aInitExpr;
  FIsNullable := aIsNullable;
  FIsGlobal := False;
  FIsPublic := False;
end;

procedure TAstVarDecl.SetGlobal(aIsGlobal, aIsPublic: Boolean);
begin
  FIsGlobal := aIsGlobal;
  FIsPublic := aIsPublic;
end;

destructor TAstVarDecl.Destroy;
begin
  FInitExpr.Free;
  inherited Destroy;
end;


// ================================================================
// TAstAssign
// ================================================================

constructor TAstAssign.Create(const aName: string; aValue: TAstExpr;
  aSpan: TSourceSpan);
begin
  inherited Create(nkAssign, aSpan);
  FName := aName;
  FValue := aValue;
end;

destructor TAstAssign.Destroy;
begin
  FValue.Free;
  inherited Destroy;
end;

// ================================================================
// TAstIf
// ================================================================

constructor TAstIf.Create(aCond: TAstExpr; aThen: TAstStmt;
  aElse: TAstStmt; aSpan: TSourceSpan);
begin
  inherited Create(nkIf, aSpan);
  FCond := aCond;
  FThenBranch := aThen;
  FElseBranch := aElse;
end;

destructor TAstIf.Destroy;
begin
  FCond.Free;
  FThenBranch.Free;
  FElseBranch.Free; // nil.Free ist sicher in FPC
  inherited Destroy;
end;

{ TAstBreak }
constructor TAstBreak.Create(aSpan: TSourceSpan);
begin
  inherited Create(nkBreak, aSpan);
end;

{ TAstContinue }
constructor TAstContinue.Create(aSpan: TSourceSpan);
begin
  inherited Create(nkContinue, aSpan);
end;

{ TAstSwitch }
constructor TAstSwitch.Create(aExpr: TAstExpr; const aCases: TAstCaseList; aDefault: TAstStmt; aSpan: TSourceSpan);
begin
  inherited Create(nkSwitch, aSpan);
  FExpr := aExpr;
  FCases := aCases;
  FDefault := aDefault;
end;

destructor TAstSwitch.Destroy;
var i: Integer;
begin
  FExpr.Free;
  for i := 0 to High(FCases) do
  begin
    FCases[i].Free;
  end;
  SetLength(FCases, 0);
  FDefault.Free;
  inherited Destroy;
end;

{ TAstCase }
constructor TAstCase.Create(aValue: TAstExpr; aBody: TAstStmt);
begin
  inherited Create;
  Value := aValue;
  Body := aBody;
  SetLength(Bindings, 0);
  SetLength(BindingExprs, 0);
end;

destructor TAstCase.Destroy;
var i: Integer;
begin
  Value.Free;
  for i := 0 to High(ExtraValues) do
    ExtraValues[i].Free;
  SetLength(ExtraValues, 0);
  for i := 0 to High(BindingExprs) do
    BindingExprs[i].Free;
  SetLength(BindingExprs, 0);
  Body.Free;
  inherited Destroy;
end;

{ Add pattern binding to case }
procedure TAstCase.AddBinding(const name: string; expr: TAstExpr);
begin
  SetLength(Bindings, Length(Bindings) + 1);
  SetLength(BindingExprs, Length(BindingExprs) + 1);
  Bindings[High(Bindings)] := name;
  BindingExprs[High(BindingExprs)] := expr;
end;

// ================================================================
// TAstWhile
// ================================================================

constructor TAstWhile.Create(aCond: TAstExpr; aBody: TAstStmt;
  aSpan: TSourceSpan);
begin
  inherited Create(nkWhile, aSpan);
  FCond := aCond;
  FBody := aBody;
  FLimit := nil;  // No limit by default
end;

constructor TAstWhile.CreateBounded(aCond: TAstExpr; aLimit: TAstExpr; aBody: TAstStmt;
  aSpan: TSourceSpan);
begin
  inherited Create(nkWhile, aSpan);
  FCond := aCond;
  FLimit := aLimit;
  FBody := aBody;
end;

destructor TAstWhile.Destroy;
begin
  FCond.Free;
  FBody.Free;
  FLimit.Free;
  inherited Destroy;
end;

function TAstWhile.HasLimit: Boolean;
begin
  Result := (FLimit <> nil);
end;

// ================================================================
// TAstReturn
// ================================================================

constructor TAstReturn.Create(aValue: TAstExpr; aSpan: TSourceSpan);
begin
  inherited Create(nkReturn, aSpan);
  FValue := aValue;
end;

destructor TAstReturn.Destroy;
begin
  FValue.Free;
  inherited Destroy;
end;

// ================================================================
// TAstBlock
// ================================================================

constructor TAstBlock.Create(const aStmts: TAstStmtList;
  aSpan: TSourceSpan);
begin
  inherited Create(nkBlock, aSpan);
  FStmts := aStmts;
end;

destructor TAstBlock.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FStmts) do
    FStmts[i].Free;
  FStmts := nil;
  inherited Destroy;
end;

// ================================================================
// TAstPoolStmt
// ================================================================

constructor TAstPoolStmt.Create(aBody: TAstStmt; aSpan: TSourceSpan);
begin
  inherited Create(nkPool, aSpan);
  FBody := aBody;
end;

destructor TAstPoolStmt.Destroy;
begin
  FBody.Free;
  inherited Destroy;
end;

// ================================================================
// TAstExprStmt
// ================================================================

constructor TAstExprStmt.Create(aExpr: TAstExpr; aSpan: TSourceSpan);
begin
  inherited Create(nkExprStmt, aSpan);
  FExpr := aExpr;
end;

destructor TAstExprStmt.Destroy;
begin
  FExpr.Free;
  inherited Destroy;
end;

// ================================================================
// TAstCharLit
// ================================================================

constructor TAstCharLit.Create(aValue: Char; aSpan: TSourceSpan);
begin
  inherited Create(nkCharLit, aSpan);
  FValue := aValue;
  FResolvedType := atChar;
end;

// ================================================================
// TAstRegexLit
// ================================================================

constructor TAstRegexLit.Create(const aPattern: string; aSpan: TSourceSpan);
begin
  inherited Create(nkRegexLit, aSpan);
  FPattern := aPattern;
  FCompiled := '';
  FCompiledLen := 0;
  FCaptureSlots := 0;
  FHasCompiled := False;
  // Regex type - will be resolved in sema
end;

procedure TAstRegexLit.SetCompiled(const data: string; capSlots: Integer);
begin
  FCompiled := data;
  FCompiledLen := Length(data);
  FCaptureSlots := capSlots;
  FHasCompiled := True;
end;

// ================================================================
// TAstFieldAccess
// ================================================================

constructor TAstFieldAccess.Create(aObj: TAstExpr; const aField: string;
  aSpan: TSourceSpan);
begin
  inherited Create(nkFieldAccess, aSpan);
  FObj := aObj;
  FField := aField;
  FFieldOffset := -1;
  FOwnerName := '';
end;

procedure TAstFieldAccess.SetFieldOffset(aOffset: Integer);
begin
  FFieldOffset := aOffset;
end;

procedure TAstFieldAccess.SetOwnerName(const aName: string);
begin
  FOwnerName := aName;
end;

procedure TAstFieldAccess.SetFieldType(aType: TAurumType);
begin
  FFieldType := aType;
end;

function TAstFieldAccess.DetachObj: TAstExpr;
begin
  Result := FObj;
  FObj := nil;
end;

destructor TAstFieldAccess.Destroy;
begin
  if Assigned(FObj) then FObj.Free;
  inherited Destroy;
end;

// ================================================================
// TAstIndexAccess
// ================================================================

constructor TAstIndexAccess.Create(aObj: TAstExpr; aIndex: TAstExpr;
  aSpan: TSourceSpan);
begin
  inherited Create(nkIndexAccess, aSpan);
  FObj := aObj;
  FIndex := aIndex;
end;

destructor TAstIndexAccess.Destroy;
begin
  FObj.Free;
  FIndex.Free;
  inherited Destroy;
end;

// ================================================================
// TAstCast
// ================================================================

constructor TAstCast.Create(aExpr: TAstExpr; aCastType: TAurumType; aSpan: TSourceSpan);
begin
  inherited Create(nkCast, aSpan);
  FExpr := aExpr;
  FCastType := aCastType;
  FResolvedType := aCastType;
end;

destructor TAstCast.Destroy;
begin
  FExpr.Free;
  inherited Destroy;
end;

// ================================================================
// TAstFnPtrType
// ================================================================
constructor TAstFnPtrType.Create(const aParamTypes: array of TAurumType; aReturnType: TAurumType; aSpan: TSourceSpan);
var
  i: Integer;
begin
  inherited Create(nkIdent, aSpan);  // Use nkIdent as base kind
  SetLength(FParamTypes, Length(aParamTypes));
  for i := 0 to High(aParamTypes) do
    FParamTypes[i] := aParamTypes[i];
  FReturnType := aReturnType;
  FResolvedType := atFnPtr;
  
  // Build signature string for comparison
  FSignatureString := 'fn(';
  for i := 0 to High(FParamTypes) do
  begin
    if i > 0 then FSignatureString := FSignatureString + ',';
    FSignatureString := FSignatureString + AurumTypeToStr(FParamTypes[i]);
  end;
  FSignatureString := FSignatureString + ')->' + AurumTypeToStr(FReturnType);
end;

destructor TAstFnPtrType.Destroy;
begin
  SetLength(FParamTypes, 0);
  inherited Destroy;
end;

function TAstFnPtrType.GetParamCount: Integer;
begin
  Result := Length(FParamTypes);
end;

function TAstFnPtrType.GetParamType(idx: Integer): TAurumType;
begin
  if (idx >= 0) and (idx < Length(FParamTypes)) then
    Result := FParamTypes[idx]
  else
    Result := atUnresolved;
end;

// ================================================================
// TAstStructLit
// ================================================================

constructor TAstStructLit.Create(const aTypeName: string; const aFields: TStructFieldInitList; aSpan: TSourceSpan);
begin
  inherited Create(nkStructLit, aSpan);
  FTypeName := aTypeName;
  FFields := aFields;
  FStructDecl := nil;
end;

destructor TAstStructLit.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FFields) do
    if Assigned(FFields[i].Value) then
      FFields[i].Value.Free;
  FFields := nil;
  // FStructDecl is not owned by us
  inherited Destroy;
end;

procedure TAstStructLit.SetStructDecl(aDecl: TAstStructDecl);
begin
  FStructDecl := aDecl;
end;

// ================================================================
// TAstFor
// ================================================================

constructor TAstFor.Create(const aVarName: string; aStart, aEnd: TAstExpr;
  aDownto: Boolean; aBody: TAstStmt; aSpan: TSourceSpan);
begin
  inherited Create(nkFor, aSpan);
  FVarName := aVarName;
  FStartExpr := aStart;
  FEndExpr := aEnd;
  FIsDownto := aDownto;
  FBody := aBody;
end;

destructor TAstFor.Destroy;
begin
  FStartExpr.Free;
  FEndExpr.Free;
  FBody.Free;
  inherited Destroy;
end;

// ================================================================
// TAstRepeatUntil
// ================================================================

constructor TAstRepeatUntil.Create(aBody: TAstStmt; aCond: TAstExpr;
  aSpan: TSourceSpan);
begin
  inherited Create(nkRepeatUntil, aSpan);
  FBody := aBody;
  FCond := aCond;
end;

destructor TAstRepeatUntil.Destroy;
begin
  FBody.Free;
  FCond.Free;
  inherited Destroy;
end;

// ================================================================
// TAstTypeDecl
// ================================================================

constructor TAstTypeDecl.Create(const aName: string; aDeclType: TAurumType;
  aPublic: Boolean; aConstraint: TAstExpr; aSpan: TSourceSpan);
begin
  inherited Create(nkTypeDecl, aSpan);
  FName := aName;
  FDeclType := aDeclType;
  FTypeName := '';
  FIsPublic := aPublic;
  FConstraint := aConstraint;
  FHasRange := False;
  FRangeMin := 0;
  FRangeMax := 0;
  if Assigned(aConstraint) then FKind := nkConstrainedTypeDecl; // If constraint is present, set node kind to nkConstrainedTypeDecl
end;

destructor TAstTypeDecl.Destroy;
begin
  if Assigned(FConstraint) then FConstraint.Free;
  inherited Destroy;
end;

constructor TAstStructDecl.Create(const aName: string; const aFields: TStructFieldList;
  const aMethods: TMethodList; aPublic: Boolean; aSpan: TSourceSpan);
var i: Integer;
begin
  inherited Create(nkStructDecl, aSpan);
  FName := aName;
  FFields := aFields;
  SetLength(FMethods, Length(aMethods));
  for i := 0 to High(aMethods) do
    FMethods[i] := aMethods[i];
  FIsPublic := aPublic;
  // default layout unknown
  FSize := 0;
  FAlign := 0;
  SetLength(FFieldOffsets, Length(FFields));
  for i := 0 to High(FFieldOffsets) do
    FFieldOffsets[i] := -1;
end;


destructor TAstStructDecl.Destroy;
var i: Integer;
begin
  for i := 0 to High(FMethods) do
    if Assigned(FMethods[i]) then
      FMethods[i].Free;
  FMethods := nil;
  SetLength(FFields, 0);
  SetLength(FFieldOffsets, 0);
  inherited Destroy;
end;

procedure TAstStructDecl.SetLayout(aSize, aAlign: Integer);
begin
  FSize := aSize;
  FAlign := aAlign;
end;

{ TAstInterfaceDecl }

constructor TAstInterfaceDecl.Create(const aName: string; const aMethods: TMethodList;
  aPublic: Boolean; aSpan: TSourceSpan);
var i: Integer;
begin
  inherited Create(nkInterfaceDecl, aSpan);
  FName := aName;
  SetLength(FMethods, Length(aMethods));
  for i := 0 to High(aMethods) do
    FMethods[i] := aMethods[i];
  FIsPublic := aPublic;
  SetLength(FMethodOffsets, Length(FMethods));
  for i := 0 to High(FMethodOffsets) do
    FMethodOffsets[i] := -1;
end;

destructor TAstInterfaceDecl.Destroy;
begin
  FMethods := nil;
  inherited Destroy;
end;

{ TAstClassDecl }

constructor TAstClassDecl.Create(const aName, aBaseClass: string;
  const aFields: TStructFieldList; const aMethods: TMethodList;
  aPublic: Boolean; aSpan: TSourceSpan);
var i: Integer;
begin
  inherited Create(nkClassDecl, aSpan);
  FName := aName;
  FBaseClassName := aBaseClass;
  FFields := aFields;
  SetLength(FMethods, Length(aMethods));
  for i := 0 to High(aMethods) do
    FMethods[i] := aMethods[i];
  // VMT fields initialization
  SetLength(FVirtualMethods, 0);
  FVMTName := '_vmt_' + aName;
  FIMTName := '_imt_' + aName;
  FIsPublic := aPublic;
  FIsAbstract := False;
  FSize := 0;
  FAlign := 0;
  FBaseSize := 0;
  SetLength(FFieldOffsets, Length(FFields));
  for i := 0 to High(FFieldOffsets) do
    FFieldOffsets[i] := -1;
  SetLength(FImplementedInterfaces, 0);
end;

destructor TAstClassDecl.Destroy;
var i: Integer;
begin
  for i := 0 to High(FMethods) do
    if Assigned(FMethods[i]) then
      FMethods[i].Free;
  FMethods := nil;
  SetLength(FFields, 0);
  SetLength(FFieldOffsets, 0);
  inherited Destroy;
end;

procedure TAstClassDecl.SetLayout(aSize, aAlign, aBaseSize: Integer);
begin
  FSize := aSize;
  FAlign := aAlign;
  FBaseSize := aBaseSize;
end;

procedure TAstClassDecl.SetBaseClassName(const aBaseClass: string);
begin
  FBaseClassName := aBaseClass;
end;

procedure TAstClassDecl.AddVirtualMethod(method: TAstFuncDecl);
begin
  SetLength(FVirtualMethods, Length(FVirtualMethods) + 1);
  FVirtualMethods[High(FVirtualMethods)] := method;
end;

procedure TAstClassDecl.AddImplementedInterface(const ifaceName: string);
begin
  SetLength(FImplementedInterfaces, Length(FImplementedInterfaces) + 1);
  FImplementedInterfaces[High(FImplementedInterfaces)] := ifaceName;
end;

{ TAstNewExpr }

constructor TAstNewExpr.Create(const aClassName: string; aSpan: TSourceSpan);
begin
  inherited Create(nkNewExpr, aSpan);
  FClassName := aClassName;
  SetLength(FArgs, 0);
  FConstructorName := 'new';  // default
end;

constructor TAstNewExpr.CreateWithArgs(const aClassName: string; const aArgs: array of TAstExpr; aSpan: TSourceSpan);
var
  i: Integer;
begin
  inherited Create(nkNewExpr, aSpan);
  FClassName := aClassName;
  SetLength(FArgs, Length(aArgs));
  for i := 0 to High(aArgs) do
    FArgs[i] := aArgs[i];
  FConstructorName := 'new';  // default
end;

destructor TAstNewExpr.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FArgs) do
    if Assigned(FArgs[i]) then FArgs[i].Free;
  SetLength(FArgs, 0);
  inherited Destroy;
end;



{ TAstDispose }

constructor TAstDispose.Create(aExpr: TAstExpr; aSpan: TSourceSpan);
begin
  inherited Create(nkDispose, aSpan);
  FExpr := aExpr;
end;

destructor TAstDispose.Destroy;
begin
  if Assigned(FExpr) then FExpr.Free;
  inherited Destroy;
end;

{ TAstAssert }

constructor TAstAssert.Create(aCondition, aMessage: TAstExpr; aSpan: TSourceSpan);
begin
  inherited Create(nkAssert, aSpan);
  FCondition := aCondition;
  FMessage := aMessage;
end;

destructor TAstAssert.Destroy;
begin
  if Assigned(FCondition) then FCondition.Free;
  if Assigned(FMessage) then FMessage.Free;
  inherited Destroy;
end;

{ TAstSuperCall }

constructor TAstSuperCall.Create(const aMethodName: string; const aArgs: TAstExprList; aSpan: TSourceSpan);
var i: Integer;
begin
  inherited Create(nkSuperCall, aSpan);
  FMethodName := aMethodName;
  SetLength(FArgs, Length(aArgs));
  for i := 0 to High(aArgs) do
    FArgs[i] := aArgs[i];
end;

destructor TAstSuperCall.Destroy;
var i: Integer;
begin
  for i := 0 to High(FArgs) do
    if Assigned(FArgs[i]) then FArgs[i].Free;
  FArgs := nil;
  inherited Destroy;
end;

{ TAstPanicExpr }

constructor TAstPanicExpr.Create(aMessage: TAstExpr; aSpan: TSourceSpan);
begin
  inherited Create(nkPanic, aSpan);
  FMessage := aMessage;
end;

destructor TAstPanicExpr.Destroy;
begin
  if Assigned(FMessage) then FMessage.Free;
  inherited Destroy;
end;

{ TAstCheckExpr }

constructor TAstCheckExpr.Create(aCondition: TAstExpr; aSpan: TSourceSpan);
begin
  inherited Create(nkCheck, aSpan);
  FCondition := aCondition;
end;

destructor TAstCheckExpr.Destroy;
begin
  if Assigned(FCondition) then FCondition.Free;
  inherited Destroy;
end;

constructor TAstFieldAssign.Create(aTarget: TAstFieldAccess; aValue: TAstExpr; aSpan: TSourceSpan);
begin
  inherited Create(nkFieldAssign, aSpan);
  FTarget := aTarget;
  FValue := aValue;
end;


destructor TAstFieldAssign.Destroy;
begin
  if Assigned(FTarget) then FTarget.Free;
  if Assigned(FValue) then FValue.Free;
  inherited Destroy;
end;

// ================================================================
// TAstIndexAssign
// ================================================================

constructor TAstIndexAssign.Create(aTarget: TAstIndexAccess; aValue: TAstExpr; aSpan: TSourceSpan);
begin
  inherited Create(nkIndexAssign, aSpan);
  FTarget := aTarget;
  FValue := aValue;
end;

destructor TAstIndexAssign.Destroy;
begin
  if Assigned(FTarget) then FTarget.Free;
  if Assigned(FValue) then FValue.Free;
  inherited Destroy;
end;

// ================================================================
// TAstUnitDecl
// ================================================================

constructor TAstUnitDecl.Create(const aPath: string; aSpan: TSourceSpan);
begin
  inherited Create(nkUnitDecl, aSpan);
  FUnitPath := aPath;
  FIntegrityAttr.Mode     := imNone;
  FIntegrityAttr.Interval := 0;
end;

// ================================================================
// TAstImportDecl
// ================================================================

constructor TAstImportDecl.Create(const aPath, aAlias: string;
  const aItems: TAstImportItemList; aSpan: TSourceSpan);
begin
  inherited Create(nkImportDecl, aSpan);
  FUnitPath := aPath;
  FAlias := aAlias;
  FItems := aItems;
end;

// ================================================================
// TAstFuncDecl
// ================================================================

constructor TAstFuncDecl.Create(const aName: string;
  const aParams: TAstParamList; aReturnType: TAurumType;
  aBody: TAstBlock; aSpan: TSourceSpan; aIsPublic: Boolean = False);
begin
  inherited Create(nkFuncDecl, aSpan);
  FName := aName;
  FParams := aParams;
  FReturnType := aReturnType;
  FReturnTypeName := '';
  FBody := aBody;
  FIsPublic := aIsPublic;
  FIsStatic := False;
  FVisibility := visPublic; // default: public
  FEnergyLevel := eelNone; // eelNone = use global level from --target-energy
  FSafetyPragmas.DALLevel   := dalNone;
  FSafetyPragmas.IsCritical := False;
  FSafetyPragmas.WCETBudget := 0;
  FSafetyPragmas.StackLimit := 0;
  FSafetyPragmas.FPDeterministic := False;  // FIX: initialize to avoid uninitialized garbage
  // VMT fields initialization
  FIsVirtual := False;
  FIsOverride := False;
  FVirtualTableIndex := -1;
  // Constructor/Destructor
  FIsConstructor := False;
  FIsDestructor := False;
  // Closure fields
  FParentFuncName := '';
  FNeedsStaticLink := False;
  SetLength(FCapturedVars, 0);
end;

destructor TAstFuncDecl.Destroy;
begin
  FBody.Free;
  FParams := nil;
  FCapturedVars := nil;
  inherited Destroy;
end;

procedure TAstFuncDecl.AddCapturedVar(const aName: string; aType: TAurumType; aOuterSlot: Integer);
var
  idx: Integer;
begin
  // Check if already captured
  if HasCapturedVar(aName) then Exit;
  idx := Length(FCapturedVars);
  SetLength(FCapturedVars, idx + 1);
  FCapturedVars[idx].Name := aName;
  FCapturedVars[idx].VarType := aType;
  FCapturedVars[idx].OuterSlot := aOuterSlot;
  FCapturedVars[idx].InnerSlot := -1; // assigned during lowering
  FNeedsStaticLink := True;
end;

function TAstFuncDecl.HasCapturedVar(const aName: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FCapturedVars) do
    if FCapturedVars[i].Name = aName then
      Exit(True);
  Result := False;
end;

// ================================================================
// TAstConDecl
// ================================================================

constructor TAstConDecl.Create(const aName: string;
  aDeclType: TAurumType; aInitExpr: TAstExpr; aSpan: TSourceSpan; aIsPublic: Boolean = False; aStorage: TStorageKlass = skCo);
begin
  inherited Create(nkConDecl, aSpan);
  FName := aName;
  FDeclType := aDeclType;
  FInitExpr := aInitExpr;
  FIsPublic := aIsPublic;
  FStorage := aStorage;
end;

destructor TAstConDecl.Destroy;
begin
  FInitExpr.Free;
  inherited Destroy;
end;

// ================================================================
// TAstEnumDecl
// ================================================================

constructor TAstEnumDecl.Create(const aName: string; const aValues: TEnumValueList;
  aPublic: Boolean; aSpan: TSourceSpan);
begin
  inherited Create(nkEnumDecl, aSpan);
  FName     := aName;
  FValues   := aValues;
  FIsPublic := aPublic;
end;

// ================================================================
// TAstTry
// ================================================================

constructor TAstTry.Create(aTryBody: TAstStmt; const aCatchVar: string;
  aCatchBody: TAstStmt; aSpan: TSourceSpan);
begin
  inherited Create(nkTry, aSpan);
  FTryBody   := aTryBody;
  FCatchVar  := aCatchVar;
  FCatchBody := aCatchBody;
end;

destructor TAstTry.Destroy;
begin
  FTryBody.Free;
  FCatchBody.Free;
  inherited Destroy;
end;

// ================================================================
// TAstThrow
// ================================================================

constructor TAstThrow.Create(aValue: TAstExpr; aSpan: TSourceSpan);
begin
  inherited Create(nkThrow, aSpan);
  FValue := aValue;
end;

destructor TAstThrow.Destroy;
begin
  FValue.Free;
  inherited Destroy;
end;

// ================================================================
// TAstTupleLit
// ================================================================

constructor TAstTupleLit.Create(const aElems: TAstExprList; aSpan: TSourceSpan);
begin
  inherited Create(nkTupleLit, aSpan);
  FElems := aElems;
end;

destructor TAstTupleLit.Destroy;
var i: Integer;
begin
  for i := 0 to High(FElems) do FElems[i].Free;
  inherited Destroy;
end;

// ================================================================
// TAstTupleVarDecl
// ================================================================

constructor TAstTupleVarDecl.Create(const aNames: TStringArray; aInit: TAstExpr; aSpan: TSourceSpan);
begin
  inherited Create(nkTupleVarDecl, aSpan);
  FNames    := aNames;
  FInitExpr := aInit;
end;

destructor TAstTupleVarDecl.Destroy;
begin
  FInitExpr.Free;
  inherited Destroy;
end;

// ================================================================
// TAstProgram
// ================================================================

constructor TAstProgram.Create(const aDecls: TAstNodeList;
  aSpan: TSourceSpan);
begin
  inherited Create(nkProgram, aSpan);
  FDecls := aDecls;
end;

destructor TAstProgram.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FDecls) do
    FDecls[i].Free;
  FDecls := nil;
  inherited Destroy;
end;

// ================================================================
// TAstInspect - In-Situ Data Visualizer
// ================================================================

constructor TAstInspect.Create(aExpr: TAstExpr; const aVarName: string;
  aFormat: TInspectFormat; aSpan: TSourceSpan);
begin
  inherited Create(nkInspect, aSpan);
  FExpr := aExpr;
  FVarName := aVarName;
  FFormat := aFormat;
  FInspectedType := atUnresolved;
  FStructName := '';
  FFieldNames := nil;
  FFieldOffsets := nil;
  FFieldTypes := nil;
end;

destructor TAstInspect.Destroy;
begin
  if Assigned(FExpr) then FExpr.Free;
  FFieldNames := nil;
  FFieldOffsets := nil;
  FFieldTypes := nil;
  inherited Destroy;
end;

procedure TAstInspect.SetTypeInfo(aType: TAurumType; const aStructName: string);
begin
  FInspectedType := aType;
  FStructName := aStructName;
  FResolvedType := atVoid; // Inspect returns void
end;

procedure TAstInspect.SetStructFields(const aNames: TStringArray;
  const aOffsets: TIntArray; const aTypes: array of TAurumType);
var
  i: Integer;
begin
  FFieldNames := aNames;
  FFieldOffsets := aOffsets;
  SetLength(FFieldTypes, Length(aTypes));
  for i := 0 to High(aTypes) do
    FFieldTypes[i] := aTypes[i];
end;

end.
