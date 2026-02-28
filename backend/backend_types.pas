{$mode objfpc}{$H+}
unit backend_types;

interface

uses
  bytes;

type
  IObjectWriter = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}']
    function WriteObjectFile(const AFileName: string; ACodeBuffer: TByteBuffer; ADataBuffer: TByteBuffer): Boolean;
  end;

  TExternalSymbol = record
    Name: string;
    LibraryName: string;
  end;
  
  TExternalSymbolArray = array of TExternalSymbol;
  
  TPLTGOTPatch = record
    Pos: Integer;        // Position in code where GOT offset needs patching (for PLTn jmp [rip+disp32])
    SymbolName: string;  // Symbol name for GOT lookup
    SymbolIndex: Integer; // Index in external symbols array
    // PLT0 patching info (same for all external symbols)
    PLT0PushPos: Integer;   // Position of rel32 in PLT0 pushq GOT+8 instruction
    PLT0JmpPos: Integer;    // Position of rel32 in PLT0 jmpq GOT+16 instruction
    PLT0VA: UInt64;        // Virtual address where PLT0 starts (filled by writer)
    GotVA: UInt64;          // Virtual address of GOT (filled by writer)
  end;
  
  TPLTGOTPatchArray = array of TPLTGOTPatch;

implementation

end.