# KassenSichV.TseCore

Herstellerunabhängige Delphi-Bibliothek für die gesetzeskonforme TSE-Anbindung nach **KassenSichV**, **BSI TR-03153** und **DSFinV-K 2.3**.

---

## Quickstart (5 Minuten)

```delphi
uses
  KassenSichV.Types,
  KassenSichV.Manager,
  KassenSichV.Mock;

var
  Provider: TMockTseProvider;
  Manager:  TTseManager;
  Beleg:    TBelegDaten;
  Sig:      TSignaturErgebnis;
begin
  Provider := TMockTseProvider.Create;
  Provider.Initialize('{}');          // Mock braucht keine Konfiguration
  Manager := TTseManager.Create(Provider);
  try
    Beleg := Default(TBelegDaten);
    Beleg.ProzessTyp   := 'Kassenbeleg-V1';
    Beleg.ProzessDaten := 'Kaffee;2.50_0.00_0.00_0.00_0.00';

    Sig := Manager.ProcessBeleg(Beleg);

    Writeln(Sig.QrCodeData);    // V0;MOCK-TSE-...;2024-01-15T09:30:00Z;...
    Writeln(Sig.SignaturWert);  // Base64-kodierter ECDSA/SHA-256-Wert
  finally
    Manager.Free;
  end;
end;
```

**Fertig.** Für echte TSEs nur den Provider tauschen — der Rest bleibt identisch.

---

## Installation

1. Alle `.pas`-Dateien aus `KassenSichV/` zum Delphi-Suchpfad hinzufügen.
2. Keine externen Abhängigkeiten — nur Delphi-RTL (`System.*`).
3. Delphi 11 und Delphi 12 unterstützt.

---

## Provider-Übersicht

| Provider | Klasse | Einsatz |
|---|---|---|
| Mock (kein TSE) | `TMockTseProvider` | Tests, CI/CD, Bondrucktests |
| Cloud-TSE | `TRestTseProvider` | Fiskaly, Deutsche Fiskal |
| USB-TSE | `TFileTseProvider` | Swissbit, Epson |

### TMockTseProvider

```delphi
Provider := TMockTseProvider.Create;
Provider.Initialize('{}');   // keine Pflichtfelder
```

Fehlersimulation für Negativtests:
```delphi
Provider.SimulateError   := True;   // FinishTransaction wirft ETseConnectionError
Provider.SimulateTimeout := True;   // FinishTransaction wirft ETseTimeoutError
```

### TRestTseProvider (Fiskaly / Deutsche Fiskal)

```delphi
Provider := TRestTseProvider.Create;
Provider.Initialize('{'
  + '"api_url":"https://kassensichv.io/api/v1",'
  + '"api_key":"<IHR-API-KEY>",'
  + '"client_id":"<KASSEN-ID>"'
  + '}');
```

- TLS 1.2+ erzwungen
- 3 Retry-Versuche bei HTTP 503/504 mit exponentiellem Backoff (1s→2s→4s)
- `api_key` erscheint **nie** in Log-Ausgaben

### TFileTseProvider (Swissbit / Epson USB-TSE)

```delphi
Provider := TFileTseProvider.Create;
Provider.Initialize('{'
  + '"base_path":"E:\\",'
  + '"timeout_ms":5000'
  + '}');
```

- Schreibt `{TransId}_req.json` auf USB-Stick
- Pollt für `{TransId}_res.json` alle 100 ms
- Löscht beide Dateien nach Transaktion automatisch

---

## API-Referenz

### TTseManager

| Methode | Beschreibung |
|---|---|
| `ProcessBeleg(var Beleg)` | Einzel-Transaktion: Start + Finish in einem Aufruf |
| `OpenBeleg(var Beleg)` | Öffnet mehrstufige Transaktion, gibt `TransId` zurück |
| `UpdateBeleg(TransId, Beleg)` | Aktualisiert laufende Transaktion (Zwischenstand) |
| `CloseBeleg(TransId, Beleg)` | Schließt Transaktion ab, setzt `QrCodeData` |
| `ExportAuditData(TargetPath, KassenId)` | DSFinV-K-Export + `index.json` |
| `GetTseStatus` | JSON-Statusstring der angebundenen TSE |
| `GetTseSeriennummer` | Seriennummer der TSE |

### TBelegDaten

| Feld | Typ | Beschreibung |
|---|---|---|
| `TransId` | `string` | Wird von `StartTransaction` gesetzt |
| `ProzessTyp` | `string` | z.B. `'Kassenbeleg-V1'`, `'Bestellung-V1'` |
| `ProzessDaten` | `string` | Strukturierter Payload (DSFinV-K-Format) |
| `KassenSeriennummer` | `string` | Geräte-ID der Kasse |
| `UmsatzZaehler` | `Currency` | Kumulierter Bruttoumsatz (kein `Double` — Rundungsfehler!) |

### TSignaturErgebnis

| Feld | Typ | Beschreibung |
|---|---|---|
| `TseSeriennummer` | `string` | Seriennummer der zertifizierten TSE |
| `SignaturZaehler` | `Int64` | Fortlaufender TSE-Vorgangszähler |
| `SignaturWert` | `string` | ECDSA/SHA-256, Base64-kodiert |
| `AnzahlTransaktionen` | `Int64` | Gesamtzähler der TSE |
| `QrCodeData` | `string` | Vorformatierter QR-Code-String (BSI TR-03153 Anhang A) |
| `StartZeitpunkt` | `TDateTime` | Offizieller Startzeitpunkt laut TSE |
| `EndZeitpunkt` | `TDateTime` | Offizieller Endzeitpunkt laut TSE |
| `Erfolg` | `Boolean` | `False` → `FehlerMeldung` auswerten |

### QR-Code-Format (BSI TR-03153 Anhang A)

```
V0;{TSE-Seriennummer};{StartUTC};{EndUTC};{Zähler};{AnzahlTransaktionen};{SignaturWert}
```

Beispiel:
```
V0;MOCK-TSE-0000000000000001;2024-01-15T09:30:00Z;2024-01-15T09:30:01Z;1;1;abc123...
```

---

## Exception-Hierarchie

```
ETseException                    (Basis, ErrorCode + ProviderInfo)
├── ETseConnectionError          (503 — Netzwerk/USB-Verbindungsfehler)
├── ETseTimeoutError             (408 — Zeitüberschreitung)
├── ETseSignatureError           (500 — ECDSA-Signierfehler)
├── ETseConfigurationError       (400 — fehlende/ungültige Konfiguration)
├── ETseTransactionError         (409 — offene/doppelte Transaktion)
└── ETseExportError              (403 — Exportpfad nicht schreibbar)
```

Alle Exceptions aus Provider-Implementierungen werden in diese Hierarchie gewrapped — kein `EInOutError` oder `EHTTPException` dringt nach außen.

---

## FAQ

**Q: Muss ich für Tests eine echte TSE haben?**
A: Nein. `TMockTseProvider` erfüllt das vollständige `ITseProvider`-Interface, benötigt keine Hardware und erzeugt deterministische Testsignaturen (SHA-256 des TransId+Zeitstempels als Base64).

**Q: Offene Transaktion — was tun?**
A: Eine offene TSE-Transaktion (d.h. `StartTransaction` ohne `FinishTransaction`) ist ein Compliance-Problem. Der Manager wirft bei `FinishTransaction`-Fehlern immer eine `ETseTransactionError`. Die Kassensoftware muss diese Exception fangen und den Vorgang manuell abschließen oder stornieren.

**Q: Wie wechsle ich von Mock auf Fiskaly?**
A: Nur den Provider tauschen — der Manager-Code und alle Datenstrukturen bleiben identisch:
```delphi
// Alt:
Provider := TMockTseProvider.Create;
// Neu:
Provider := TRestTseProvider.Create;
Provider.Initialize('{"api_url":"...","api_key":"...","client_id":"..."}');
```

**Q: Warum `Currency` statt `Double` für `UmsatzZaehler`?**
A: `Double` hat IEEE-754-Rundungsfehler. Bei Geldbeträgen (z.B. 0.1 + 0.2 ≠ 0.3 in `Double`) sind BCD-basierte `Currency`-Werte gesetzlich korrekt und entsprechen DSFinV-K-Anforderungen.

**Q: Wie aktiviere ich das Logging?**
```delphi
Provider.OnLogMessage := procedure(const AMsg: string)
begin
  MyLogger.Log(AMsg);  // beliebiger Log-Callback
end;
```
`api_key` und Credentials werden im Log **niemals** im Klartext ausgegeben.

---

## Rechtliche Grundlagen

- **KassenSichV** (Kassensicherungsverordnung) — Pflicht zur unveränderlichen TSE-Anbindung seit 01.01.2020
- **BSI TR-03153** — Technische Richtlinie des BSI, definiert TSE-Schnittstelle und QR-Code-Format
- **DSFinV-K 2.3** — Digitale Schnittstelle der Finanzverwaltung für Kassensysteme

> **Haftungshinweis:** Diese Bibliothek ist eine technische Hilfsmittel-Implementierung. Die Kassenbetreiber sind für die gesetzeskonforme Integration und den Betrieb der TSE verantwortlich. Bei Unklarheiten zur rechtlichen Einordnung ist steuerlicher und rechtlicher Rat einzuholen.
