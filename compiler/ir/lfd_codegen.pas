{$mode objfpc}{$H+}
unit lfd_codegen;

interface

uses
  SysUtils, Classes;

type
  { --- Forward declarations from ast.pas --- }
  TLfdWidgetKind = (
    lfdWidgetUnknown,
    lfdWidget, lfdLabel, lfdPushButton, lfdCheckBox, lfdRadioButton,
    lfdLineEdit, lfdTextEdit, lfdGroupBox, lfdTabWidget, lfdScrollArea,
    lfdStackedWidget, lfdComboBox, lfdListWidget, lfdTreeWidget, lfdTableWidget,
    lfdProgressBar, lfdSlider, lfdSpinBox, lfdDateEdit, lfdMenuBar, lfdToolBar,
    lfdAction, lfdSeparator, lfdSpacer
  );

  TLfdLayoutKind = (
    lfdLayoutUnknown, lfdLayoutVertical, lfdLayoutHorizontal,
    lfdLayoutGrid, lfdLayoutForm
  );

  TLfdSignalKind = (
    lfdSignalUnknown, lfdSignalClicked, lfdSignalToggled, lfdSignalChanged,
    lfdSignalActivated, lfdSignalDoubleClicked, lfdSignalReturnPressed,
    lfdSignalEditingFinished
  );

  { --- AST-Knoten (vereinfacht) --- }
  TAstNode = class end;

  TLfdProperty = class
  private
    FName: string;
    FValue: string;
  public
    constructor Create(const aName, aValue: string);
    property Name: string read FName;
    property Value: string read FValue;
  end;
  TLfdPropertyList = array of TLfdProperty;

  TLfdSignal = class
  private
    FSignalKind: TLfdSignalKind;
    FHandlerName: string;
  public
    constructor Create(aSignalKind: TLfdSignalKind; const aHandlerName: string);
    property SignalKind: TLfdSignalKind read FSignalKind;
    property HandlerName: string read FHandlerName;
  end;
  TLfdSignalList = array of TLfdSignal;

  TAstLfdNodeList = array of TAstNode;

  TLfdLayout = class(TAstNode)
  private
    FLayoutKind: TLfdLayoutKind;
    FChildren: TAstLfdNodeList;
    FSpacing: Integer;
  public
    constructor Create(aLayoutKind: TLfdLayoutKind; const aChildren: TAstLfdNodeList);
    property LayoutKind: TLfdLayoutKind read FLayoutKind;
    property Children: TAstLfdNodeList read FChildren;
    property Spacing: Integer read FSpacing write FSpacing;
  end;

  TLfdWidget = class(TAstNode)
  private
    FWidgetKind: TLfdWidgetKind;
    FName: string;
    FProperties: TLfdPropertyList;
    FSignals: TLfdSignalList;
  public
    constructor Create(aWidgetKind: TLfdWidgetKind; const aName: string;
      const aProperties: TLfdPropertyList; const aSignals: TLfdSignalList);
    property WidgetKind: TLfdWidgetKind read FWidgetKind;
    property Name: string read FName;
    property Properties: TLfdPropertyList read FProperties;
    property Signals: TLfdSignalList read FSignals;
  end;

  TLfdForm = class(TAstNode)
  private
    FName: string;
    FTitle: string;
    FChildren: TAstLfdNodeList;
    FProperties: TLfdPropertyList;
  public
    constructor Create(const aName, aTitle: string;
      const aChildren: TAstLfdNodeList; const aProperties: TLfdPropertyList);
    property Name: string read FName;
    property Title: string read FTitle;
    property Children: TAstLfdNodeList read FChildren;
    property Properties: TLfdPropertyList read FProperties;
  end;

  { --- LFD Code Generator für C++/Qt --- }

  TLfdCodeGen = class
  private
    FIndent: string;
    FUseQt6: Boolean;
    
    function GetIndent: string;
    procedure IncIndent;
    procedure DecIndent;
    function WidgetKindToQtClass(wk: TLfdWidgetKind): string;
    function WidgetKindToInclude(wk: TLfdWidgetKind): string;
    function SignalKindToQtSignal(sk: TLfdSignalKind): string;
    function SignalKindToHandlerParam(sk: TLfdSignalKind): string;
    function LayoutKindToQtClass(lk: TLfdLayoutKind): string;
    function GenerateWidgetProperty(wk: TLfdWidgetKind; const PropName, PropValue, VarName: string): string;
    
  public
    constructor Create;
    destructor Destroy; override;
    function GenerateHeader(aForm: TLfdForm): string;
    function GenerateSource(aForm: TLfdForm): string;
    property UseQt6: Boolean read FUseQt6 write FUseQt6;
  end;

implementation

constructor TLfdProperty.Create(const aName, aValue: string);
begin inherited Create; FName := aName; FValue := aValue; end;
constructor TLfdSignal.Create(aSignalKind: TLfdSignalKind; const aHandlerName: string);
begin inherited Create; FSignalKind := aSignalKind; FHandlerName := aHandlerName; end;
constructor TLfdLayout.Create(aLayoutKind: TLfdLayoutKind; const aChildren: TAstLfdNodeList);
begin inherited Create; FLayoutKind := aLayoutKind; FChildren := aChildren; FSpacing := -1; end;
constructor TLfdWidget.Create(aWidgetKind: TLfdWidgetKind; const aName: string;
  const aProperties: TLfdPropertyList; const aSignals: TLfdSignalList);
begin inherited Create; FWidgetKind := aWidgetKind; FName := aName; FProperties := aProperties; FSignals := aSignals; end;
constructor TLfdForm.Create(const aName, aTitle: string;
  const aChildren: TAstLfdNodeList; const aProperties: TLfdPropertyList);
begin inherited Create; FName := aName; FTitle := aTitle; FChildren := aChildren; FProperties := aProperties; end;

constructor TLfdCodeGen.Create;
begin inherited Create; FIndent := '    '; FUseQt6 := False; end;
destructor TLfdCodeGen.Destroy; begin inherited Destroy; end;
function TLfdCodeGen.GetIndent: string; begin Result := FIndent; end;
procedure TLfdCodeGen.IncIndent; begin FIndent := FIndent + '    '; end;
procedure TLfdCodeGen.DecIndent; begin if Length(FIndent) > 4 then SetLength(FIndent, Length(FIndent) - 4); end;

function TLfdCodeGen.WidgetKindToQtClass(wk: TLfdWidgetKind): string;
begin
  case wk of
    lfdWidget: Result := 'QWidget';
    lfdLabel: Result := 'QLabel';
    lfdPushButton: Result := 'QPushButton';
    lfdCheckBox: Result := 'QCheckBox';
    lfdRadioButton: Result := 'QRadioButton';
    lfdLineEdit: Result := 'QLineEdit';
    lfdTextEdit: Result := 'QTextEdit';
    lfdGroupBox: Result := 'QGroupBox';
    lfdTabWidget: Result := 'QTabWidget';
    lfdScrollArea: Result := 'QScrollArea';
    lfdStackedWidget: Result := 'QStackedWidget';
    lfdComboBox: Result := 'QComboBox';
    lfdListWidget: Result := 'QListWidget';
    lfdTreeWidget: Result := 'QTreeWidget';
    lfdTableWidget: Result := 'QTableWidget';
    lfdProgressBar: Result := 'QProgressBar';
    lfdSlider: Result := 'QSlider';
    lfdSpinBox: Result := 'QSpinBox';
    lfdDateEdit: Result := 'QDateEdit';
    else Result := 'QWidget';
  end;
end;

function TLfdCodeGen.WidgetKindToInclude(wk: TLfdWidgetKind): string;
begin
  case wk of
    lfdWidget: Result := '#include <QWidget>';
    lfdLabel: Result := '#include <QLabel>';
    lfdPushButton: Result := '#include <QPushButton>';
    lfdCheckBox: Result := '#include <QCheckBox>';
    lfdRadioButton: Result := '#include <QRadioButton>';
    lfdLineEdit: Result := '#include <QLineEdit>';
    lfdTextEdit: Result := '#include <QTextEdit>';
    lfdGroupBox: Result := '#include <QGroupBox>';
    lfdTabWidget: Result := '#include <QTabWidget>';
    lfdScrollArea: Result := '#include <QScrollArea>';
    lfdStackedWidget: Result := '#include <QStackedWidget>';
    lfdComboBox: Result := '#include <QComboBox>';
    lfdListWidget: Result := '#include <QListWidget>';
    lfdTreeWidget: Result := '#include <QTreeWidget>';
    lfdTableWidget: Result := '#include <QTableWidget>';
    lfdProgressBar: Result := '#include <QProgressBar>';
    lfdSlider: Result := '#include <QSlider>';
    lfdSpinBox: Result := '#include <QSpinBox>';
    lfdDateEdit: Result := '#include <QDateEdit>';
    else Result := '#include <QWidget>';
  end;
end;

function TLfdCodeGen.SignalKindToQtSignal(sk: TLfdSignalKind): string;
begin
  case sk of
    lfdSignalClicked: Result := 'clicked';
    lfdSignalToggled: Result := 'toggled';
    lfdSignalChanged: Result := 'changed';
    lfdSignalActivated: Result := 'activated';
    lfdSignalDoubleClicked: Result := 'doubleClicked';
    lfdSignalReturnPressed: Result := 'returnPressed';
    lfdSignalEditingFinished: Result := 'editingFinished';
    else Result := 'clicked';
  end;
end;

function TLfdCodeGen.SignalKindToHandlerParam(sk: TLfdSignalKind): string;
begin
  case sk of
    lfdSignalToggled: Result := 'bool';
    lfdSignalChanged: Result := 'const QString&';
    lfdSignalActivated: Result := 'int';
    else Result := '';
  end;
end;

function TLfdCodeGen.LayoutKindToQtClass(lk: TLfdLayoutKind): string;
begin
  case lk of
    lfdLayoutVertical: Result := 'QVBoxLayout';
    lfdLayoutHorizontal: Result := 'QHBoxLayout';
    lfdLayoutGrid: Result := 'QGridLayout';
    lfdLayoutForm: Result := 'QFormLayout';
    else Result := 'QVBoxLayout';
  end;
end;

function TLfdCodeGen.GenerateWidgetProperty(wk: TLfdWidgetKind; const PropName, PropValue, VarName: string): string;
begin
  Result := '';
  if PropName = 'Text' then
  begin
    if wk in [lfdLabel, lfdPushButton, lfdCheckBox, lfdRadioButton] then
      Result := Format('    %s->setText("%s");', [VarName, PropValue]);
  end
  else if PropName = 'Placeholder' then
  begin
    if wk = lfdLineEdit then
      Result := Format('    %s->setPlaceholderText("%s");', [VarName, PropValue]);
  end
  else if PropName = 'Enabled' then
    Result := Format('    %s->setEnabled(%s);', [VarName, PropValue])
  else if PropName = 'Visible' then
    Result := Format('    %s->setVisible(%s);', [VarName, PropValue])
  else if PropName = 'Checked' then
  begin
    if wk in [lfdCheckBox, lfdRadioButton] then
      Result := Format('    %s->setChecked(%s);', [VarName, PropValue]);
  end
  else if PropName = 'Title' then
  begin
    if wk = lfdGroupBox then
      Result := Format('    %s->setTitle("%s");', [VarName, PropValue]);
  end
  else if PropName = 'ObjectName' then
    Result := Format('    %s->setObjectName("%s");', [VarName, PropValue])
  else if PropName = 'Style' then
    Result := Format('    %s->setStyleSheet("%s");', [VarName, PropValue])
  else if PropName = 'Minimum' then
  begin
    if wk in [lfdSlider, lfdSpinBox, lfdProgressBar] then
      Result := Format('    %s->setMinimum(%s);', [VarName, PropValue]);
  end
  else if PropName = 'Maximum' then
  begin
    if wk in [lfdSlider, lfdSpinBox, lfdProgressBar] then
      Result := Format('    %s->setMaximum(%s);', [VarName, PropValue]);
  end
  else if PropName = 'Value' then
  begin
    if wk in [lfdSlider, lfdSpinBox] then
      Result := Format('    %s->setValue(%s);', [VarName, PropValue]);
  end;
end;

function TLfdCodeGen.GenerateHeader(aForm: TLfdForm): string;
var
  i, j: Integer;
  UniqueKinds: array of TLfdWidgetKind;
  HasUnique: Boolean;
  wk: TLfdWidgetKind;
  Widget: TLfdWidget;
begin
  Result := '';
  Result := Result + '#ifndef UI_' + UpperCase(aForm.Name) + '_H' + LineEnding;
  Result := Result + '#define UI_' + UpperCase(aForm.Name) + '_H' + LineEnding;
  Result := Result + LineEnding;
  if FUseQt6 then
    Result := Result + '#include <QtGlobal>' + LineEnding;
  Result := Result + LineEnding;
  
  SetLength(UniqueKinds, 0);
  for i := 0 to High(aForm.Children) do
  begin
    if aForm.Children[i] is TLfdWidget then
    begin
      Widget := TLfdWidget(aForm.Children[i]);
      wk := Widget.WidgetKind;
      HasUnique := False;
      for j := 0 to High(UniqueKinds) do
        if UniqueKinds[j] = wk then
        begin
          HasUnique := True;
          Break;
        end;
      if not HasUnique then
      begin
        SetLength(UniqueKinds, Length(UniqueKinds) + 1);
        UniqueKinds[High(UniqueKinds)] := wk;
      end;
    end;
  end;
  
  Result := Result + '#include <QWidget>' + LineEnding;
  Result := Result + '#include <QLayout>' + LineEnding;
  for i := 0 to High(UniqueKinds) do
    Result := Result + WidgetKindToInclude(UniqueKinds[i]) + LineEnding;
  Result := Result + LineEnding;
  
  Result := Result + 'class ' + aForm.Name + ' : public QWidget' + LineEnding;
  Result := Result + '{' + LineEnding;
  Result := Result + '    Q_OBJECT' + LineEnding;
  Result := Result + LineEnding;
  Result := Result + 'public:' + LineEnding;
  Result := Result + '    ' + aForm.Name + '(QWidget* parent = nullptr);' + LineEnding;
  Result := Result + '    ~' + aForm.Name + '();' + LineEnding;
  Result := Result + LineEnding;
  Result := Result + 'private:' + LineEnding;
  
  for i := 0 to High(aForm.Children) do
  begin
    if aForm.Children[i] is TLfdWidget then
    begin
      Widget := TLfdWidget(aForm.Children[i]);
      Result := Result + '    ' + WidgetKindToQtClass(Widget.WidgetKind) + '* ' + Widget.Name + ';' + LineEnding;
    end;
  end;
  Result := Result + LineEnding;
  Result := Result + 'private slots:' + LineEnding;
  
  for i := 0 to High(aForm.Children) do
  begin
    if aForm.Children[i] is TLfdWidget then
    begin
      Widget := TLfdWidget(aForm.Children[i]);
      for j := 0 to High(Widget.Signals) do
      begin
        Result := Result + '    void ' + Widget.Signals[j].HandlerName + '(';
        Result := Result + SignalKindToHandlerParam(Widget.Signals[j].SignalKind) + ');' + LineEnding;
      end;
    end;
  end;
  
  Result := Result + '};' + LineEnding;
  Result := Result + LineEnding;
  Result := Result + '#endif // UI_' + UpperCase(aForm.Name) + '_H' + LineEnding;
end;

function TLfdCodeGen.GenerateSource(aForm: TLfdForm): string;
var
  i, j, k, FirstLayoutIdx: Integer;
  Widget: TLfdWidget;
  Layout: TLfdLayout;
  PropCode: string;
begin
  Result := '';
  Result := Result + '#include "' + aForm.Name + '.h"' + LineEnding;
  Result := Result + LineEnding;
  Result := Result + '#include <QApplication>' + LineEnding;
  Result := Result + LineEnding;
  
  Result := Result + aForm.Name + '::' + aForm.Name + '(QWidget* parent)' + LineEnding;
  Result := Result + '    : QWidget(parent)' + LineEnding;
  Result := Result + '{' + LineEnding;
  
  if aForm.Title <> '' then
    Result := Result + '    setWindowTitle("' + aForm.Title + '");' + LineEnding;
  Result := Result + LineEnding;
  
  for i := 0 to High(aForm.Children) do
  begin
    if aForm.Children[i] is TLfdWidget then
    begin
      Widget := TLfdWidget(aForm.Children[i]);
      Result := Result + '    ' + Widget.Name + ' = new ' + WidgetKindToQtClass(Widget.WidgetKind) + '(this);' + LineEnding;
      for j := 0 to High(Widget.Properties) do
      begin
        PropCode := GenerateWidgetProperty(Widget.WidgetKind, Widget.Properties[j].Name, Widget.Properties[j].Value, Widget.Name);
        if PropCode <> '' then
          Result := Result + PropCode + LineEnding;
      end;
      Result := Result + '    ' + Widget.Name + '->setObjectName("' + Widget.Name + '");' + LineEnding;
    end;
  end;
  Result := Result + LineEnding;
  
  FirstLayoutIdx := -1;
  for i := 0 to High(aForm.Children) do
  begin
    if aForm.Children[i] is TLfdLayout then
    begin
      if FirstLayoutIdx = -1 then FirstLayoutIdx := i;
      Layout := TLfdLayout(aForm.Children[i]);
      Result := Result + '    auto* layout_' + IntToStr(i) + ' = new ' + LayoutKindToQtClass(Layout.LayoutKind) + '(this);' + LineEnding;
      if Layout.Spacing >= 0 then
        Result := Result + '    layout_' + IntToStr(i) + '->setSpacing(' + IntToStr(Layout.Spacing) + ');' + LineEnding;
      for j := 0 to High(Layout.Children) do
      begin
        if Layout.Children[j] is TLfdWidget then
        begin
          Result := Result + '    layout_' + IntToStr(i) + '->addWidget(' + TLfdWidget(Layout.Children[j]).Name + ');' + LineEnding;
        end
        else if Layout.Children[j] is TLfdLayout then
        begin
          for k := 0 to High(aForm.Children) do
            if aForm.Children[k] = Layout.Children[j] then
            begin
              Result := Result + '    layout_' + IntToStr(i) + '->addLayout(layout_' + IntToStr(k) + ');' + LineEnding;
              Break;
            end;
        end;
      end;
    end;
  end;
  
  if FirstLayoutIdx >= 0 then
    Result := Result + '    setLayout(layout_' + IntToStr(FirstLayoutIdx) + ');' + LineEnding;
  Result := Result + LineEnding;
  
  Result := Result + '    // Signal-Slot connections' + LineEnding;
  for i := 0 to High(aForm.Children) do
  begin
    if aForm.Children[i] is TLfdWidget then
    begin
      Widget := TLfdWidget(aForm.Children[i]);
      for j := 0 to High(Widget.Signals) do
      begin
        Result := Result + '    connect(' + Widget.Name + ', &' + WidgetKindToQtClass(Widget.WidgetKind) + '::' + 
                  SignalKindToQtSignal(Widget.Signals[j].SignalKind) + ',' + LineEnding;
        Result := Result + '            this, &' + aForm.Name + '::' + Widget.Signals[j].HandlerName + ');' + LineEnding;
      end;
    end;
  end;
  
  Result := Result + '}' + LineEnding;
  Result := Result + LineEnding;
  Result := Result + aForm.Name + '::~' + aForm.Name + '()' + LineEnding;
  Result := Result + '{' + LineEnding;
  Result := Result + '}' + LineEnding;
end;

end.
