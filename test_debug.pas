program test_debug;

uses
  SysUtils, bytes, backend_types, energy_model,
  diag, lexer, parser, ast, sema, unit_manager,
  ir, lower_ast_to_ir, ir_inlining,
  x86_64_emit;

var
  src: TStringList;
  d: TDiagnostics;
  lx: TLexer;
  p: TParser;
  prog: TAstProgram;
  s: TSema;
  um: TUnitManager;
  module: TIRModule;
  lower: TIRLowering;
  inliner: TIRInlining;
  emit: TX86_64Emitter;
  codeBuf, dataBuf: TByteBuffer;
  i: Integer;
begin
  src := TStringList.Create;
  src.LoadFromFile('test_dynlink.lyx');
  
  d := TDiagnostics.Create;
  lx := TLexer.Create(src.Text, d);
  p := TParser.Create(lx, d);
  prog := p.ParseProgram;
  
  um := TUnitManager.Create;
  s := TSema.Create(prog, um, d);
  s.Analyze;
  
  module := TIRModule.Create;
  lower := TIRLowering.Create(module, d);
  lower.Lower(prog);
  
  inliner := TIRInlining.Create(module);
  inliner.Optimize;
  
  emit := TX86_64Emitter.Create(d);
  emit.SetEnergyLevel(eelMedium);
  emit.EmitFromIR(module);
  
  codeBuf := emit.GetCodeBuffer;
  dataBuf := emit.GetDataBuffer;
  
  WriteLn('Code size: ', codeBuf.Size);
  WriteLn('Data size: ', dataBuf.Size);
  
  WriteLn('Label positions:');
  for i := 0 to High(emit.FLabelPositions) do
    WriteLn('  ', emit.FLabelPositions[i].Name, ' at ', emit.FLabelPositions[i].Pos);
  
  WriteLn('Jump patches:');
  for i := 0 to High(emit.FJumpPatches) do
    WriteLn('  ', emit.FJumpPatches[i].LabelName, ' at ', emit.FJumpPatches[i].Pos);
  
  WriteLn('External symbols:');
  for i := 0 to High(emit.FExternalSymbols) do
    WriteLn('  ', emit.FExternalSymbols[i].Name, ' from ', emit.FExternalSymbols[i].LibraryName);
  
  emit.Free;
  module.Free;
  lower.Free;
  inliner.Free;
  prog.Free;
  p.Free;
  lx.Free;
  d.Free;
  src.Free;
end.
