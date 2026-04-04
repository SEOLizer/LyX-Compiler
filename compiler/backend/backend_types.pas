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

  { --- Safety Pragma Types (DO-178C, aerospace-todo P1 #6) --- }
  { DAL (Design Assurance Level): dalNone = not set, dalD..dalA = DO-178C level }
  TDALLevel = (dalNone, dalD, dalC, dalB, dalA);

  { --- Integrity Management Types (aerospace-todo P0 #43) --- }
  { Integrity mode for @integrity(mode: ...) — imNone = not set }
  TIntegrityMode = (imNone, imSoftwareLockstep, imScrubbed, imHardwareEcc);

  { --- Endianness Types (aerospace-todo P2 #52) --- }
  { Struct endianness annotation: enNative = not set (uses target arch endianness) }
  TEndianType = (enNative, enBigEndian, enLittleEndian);

  { Integrity attribute attached to unit or function declarations }
  TIntegrityAttr = record
    Mode:     TIntegrityMode; // @integrity(mode: software_lockstep|scrubbed|hardware_ecc)
    Interval: Int64;          // @integrity(interval: N) — check interval in ms (0 = not set)
  end;

  { Aggregated safety pragmas attached to a function declaration }
  TSafetyPragmas = record
    DALLevel:        TDALLevel;     // @dal(A|B|C|D)  — DO-178C assurance level
    IsCritical:      Boolean;       // @critical       — safety-critical function
    WCETBudget:      Int64;         // @wcet(N)        — WCET budget in microseconds (0 = not set)
    StackLimit:      Int64;         // @stack_limit(N) — max stack usage in bytes     (0 = not set)
    Integrity:       TIntegrityAttr; // @integrity(mode:..., interval:N) — integrity protection
    FPDeterministic: Boolean;       // @flight_crit    — strict FP determinism (aerospace-todo P2 #58)
  end;

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
