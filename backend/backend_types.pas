{$mode objfpc}{$H+}
unit backend_types;

interface

uses
  bytes;

type
  { --- Target OS --- }
  TTargetOS = (atLinux, atmacOS, atWindows);

  { --- Energy-Aware Enums --- }
  TEnergyLevel = (eelNone, eelMinimal, eelLow, eelMedium, eelHigh, eelExtreme);
  TCPUFamily = (cfUnknown, cfX86_64, cfARM64, cfARMCortexM, cfARMCortexA);

  { --- Object Writer Interface --- }
  IObjectWriter = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}']
    function WriteObjectFile(const AFileName: string; ACodeBuffer: TByteBuffer; ADataBuffer: TByteBuffer): Boolean;
  end;

  { --- Dynamic Linking Types --- }
  TExternalSymbol = record Name, LibraryName: string; end;
  TExternalSymbolArray = array of TExternalSymbol;

  TPLTGOTPatch = record
    Pos, SymbolIndex, PLT0PushPos, PLT0JmpPos: Integer;
    SymbolName: string;
    PLT0VA, GotVA: UInt64;
  end;
  TPLTGOTPatchArray = array of TPLTGOTPatch;

implementation

end.
