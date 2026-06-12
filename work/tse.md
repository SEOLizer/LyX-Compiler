# Architektur-Konzept: KassenSichV.TseCore

## Ziel

`KassenSichV.TseCore` ist eine herstellerunabhängige Delphi-Bibliothek, die Kassensoftware-Entwickler von der Komplexität der KassenSichV-konformen TSE-Anbindung befreit. Die Bibliothek nimmt die Rohdaten eines Bons entgegen, kapselt die gesamte Kommunikation mit der TSE (Cloud, Hardware, File-Interface) und liefert alle gesetzlich geforderten Pflichtangaben für den Belegdruck gebrauchsfertig zurück.

**Rechtliche Grundlagen:** KassenSichV, BSI TR-03153, DSFinV-K

---

## 1. Datenmodell

### TBelegDaten — Eingangsdaten eines Kassenbelegs

```delphi
type
  TBelegDaten = record
    TransId: String;               // Interne Vorgangs-ID der Kasse
    StartZeitpunkt: TDateTime;
    EndZeitpunkt: TDateTime;
    UmsatzZaehler: Currency;       // Kumulierter Umsatz (Brutto)
    KassenSeriennummer: String;    // Geräte-ID laut DSFinV-K
    ProzessTyp: String;            // z. B. "Kassenbeleg-V1"
    ProzessDaten: String;          // Strukturierter Payload (z. B. JSON nach DSFinV-K)
  end;
```

### TSignaturErgebnis — Steuerliche Pflichtangaben für den Bondruck

```delphi
type
  TSignaturErgebnis = record
    TseSeriennummer: String;       // Seriennummer der zertifizierten TSE
    SignaturZaehler: Int64;        // Fortlaufender Vorgangszähler der TSE
    StartZeitpunkt: TDateTime;     // Offizieller Startzeitpunkt laut TSE
    EndZeitpunkt: TDateTime;       // Offizieller Endzeitpunkt laut TSE
    SignaturWert: String;          // Kryptografischer Prüfwert (Base64, ECDSA/SHA-256)
    AnzahlTransaktionen: Int64;    // Gesamtzähler der TSE
    QrCodeData: String;            // Vorformatierter String für den QR-Code-Druck
    Erfolg: Boolean;
    FehlerMeldung: String;
  end;
```

---

## 2. Kern-Interface ITseProvider

Das Bibliotheks-Design folgt dem Dependency-Inversion-Prinzip: Der gesamte Kassensoftware-Code programmiert gegen `ITseProvider`. Der konkrete Anbieter (Bundesdruckerei, Fiskaly, Epson, Swissbit) wird bei der Initialisierung injiziert.

```delphi
type
  ITseProvider = interface
    ['{A3F1C2D4-8E5B-4A9F-BC01-7D3E6F2A1B94}']
    procedure Initialize(const ConfigData: String);
    function GetSeriennummer: String;
    function StartTransaction(var Beleg: TBelegDaten): String;       // Gibt TransId zurück
    function UpdateTransaction(const TransId: String;
                               const Daten: TBelegDaten): TSignaturErgebnis;
    function FinishTransaction(const TransId: String;
                               const Daten: TBelegDaten): TSignaturErgebnis;
    procedure ExportAuditData(const TargetPath: String);             // Finanzamt-Export (TAR)
    function GetStatus: String;
  end;
```

---

## 3. Hauptklasse TTseManager

Einstiegspunkt für den Entwickler. Verwaltet den Provider-Lifecycle, orchestriert den Transaktionsablauf und baut den BSI-konformen QR-Code-String zusammen.

```delphi
type
  TTseManager = class
  private
    FProvider: ITseProvider;
    function GenerateQrCodeString(const SigData: TSignaturErgebnis): String;
  public
    constructor Create(AProvider: ITseProvider);
    destructor Destroy; override;

    // Standard-Kassenvorgang (Start + Finish in einem Aufruf)
    function ProcessBeleg(var Beleg: TBelegDaten): TSignaturErgebnis;

    // Für aufgeteilte Vorgänge (z. B. Tischbewirtung, Zeiterfassung)
    function OpenBeleg(var Beleg: TBelegDaten): String;              // Gibt TransId zurück
    function UpdateBeleg(const TransId: String;
                         const Beleg: TBelegDaten): TSignaturErgebnis;
    function CloseBeleg(const TransId: String;
                        const Beleg: TBelegDaten): TSignaturErgebnis;

    procedure ExportAuditData(const TargetPath: String);
    function GetTseStatus: String;
  end;
```

### Implementierungslogik ProcessBeleg

```delphi
function TTseManager.ProcessBeleg(var Beleg: TBelegDaten): TSignaturErgebnis;
begin
  // 1. Transaktion bei der TSE öffnen → TSE vergibt internen Zähler
  Beleg.TransId := FProvider.StartTransaction(Beleg);

  // 2. Transaktion abschließen → TSE signiert und liefert Pflichtdaten
  Result := FProvider.FinishTransaction(Beleg.TransId, Beleg);

  // 3. QR-Code-String nach BSI TR-03153 zusammensetzen
  if Result.Erfolg then
    Result.QrCodeData := GenerateQrCodeString(Result);
end;

function TTseManager.GenerateQrCodeString(const SigData: TSignaturErgebnis): String;
begin
  // Formatierung nach BSI TR-03153 Anhang A
  Result := Format(
    'V0;%s;%s;%s;%s;%d;%s',
    [
      SigData.TseSeriennummer,
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', SigData.StartZeitpunkt),
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', SigData.EndZeitpunkt),
      IntToStr(SigData.SignaturZaehler),
      SigData.AnzahlTransaktionen,
      SigData.SignaturWert
    ]
  );
end;
```

---

## 4. Workflow-Visualisierung

```
Kassensoftware (Client)
        │
        │  ProcessBeleg(TBelegDaten)
        ▼
  ┌─────────────┐
  │ TTseManager │
  │             │  StartTransaction()
  │             │─────────────────────► ITseProvider
  │             │                             │
  │             │                    (Hardware-TSE / Cloud / File)
  │             │                             │
  │             │  FinishTransaction()        │ Signiert mit ECDSA-Schlüssel
  │             │◄────────────────────────────┘
  │             │
  │  GenerateQrCodeString()   (intern)
  │             │
  └─────────────┘
        │
        │  TSignaturErgebnis
        ▼
Kassensoftware druckt Bon mit:
  • TSE-Seriennummer
  • Signaturzähler
  • Start/Endzeitpunkt
  • Signaturwert
  • QR-Code
```

---

## 5. Vorteile

| Vorteil | Erläuterung |
|---|---|
| **Kapselung** | Entwickler muss keine ECDSA-, SHA-256- oder herstellerspezifische SDK-Kenntnisse haben |
| **Austauschbarkeit** | Wechsel von USB-TSE auf Cloud-TSE: nur Provider tauschen, Kassencode bleibt gleich |
| **DSFinV-K Ready** | Datenstrukturen so ausgelegt, dass der Finanzamt-Export direkt unterstützt wird |
| **Testbarkeit** | MockProvider ermöglicht vollständige Bondrucktests ohne physische TSE |
| **Zukunftssicher** | Neue TSE-Anbieter erfordern nur eine neue ITseProvider-Implementierung |

---

## Arbeitspakete

---

### WP-TSE-01 — Datenmodell & Typdefinitionen

**Info:**
Definiert alle zentralen Record-Typen und Enumerationen der Bibliothek in einer eigenen Unit `KassenSichV.Types`. Dies ist die Basis für alle weiteren WPs.

**Grund:**
Alle anderen Units (Manager, Provider, Tests) müssen auf dieselben Typen referenzieren. Eine saubere Trennung verhindert Zirkelbezüge und erlaubt es, die Typen ohne Abhängigkeit zu importieren.

**Hinweise:**
- `TBelegDaten` und `TSignaturErgebnis` als `record` (Value-Semantik), nicht als Klassen
- `ProzessTyp` als String belassen (keine Enum), da die BSI-Spezifikation neue Werte ohne Code-Änderung erlauben soll
- `UmsatzZaehler` als `Currency` (4 Dezimalstellen, BCD-intern) — kein `Double` wegen Rundungsfehlern
- `SignaturWert` ist immer Base64-kodiert (nach TR-03153)
- Alle Zeitfelder als `TDateTime` (UTC-basiert intern, Ausgabe lokalisiert)
- Unit enthält **keine Logik**, nur Typen und Konstanten

**Abnahmekriterien:**
- [ ] Unit `KassenSichV.Types` kompiliert ohne Warnings
- [ ] `TBelegDaten` enthält alle Felder laut DSFinV-K-Anforderungsliste
- [ ] `TSignaturErgebnis` enthält alle 7 Pflichtfelder für den Bondruck
- [ ] Beide Records sind vollständig mit XML-Doc-Kommentaren dokumentiert
- [ ] Unit hat keine Abhängigkeiten außer `System.*`

---

### WP-TSE-02 — ITseProvider Interface & Basisklassen

**Info:**
Definiert das Interface `ITseProvider` und eine abstrakte Basisklasse `TTseProviderBase`, die Boilerplate (Logging, Fehlerbehandlung) kapselt, sodass konkrete Provider-Implementierungen schlank bleiben.

**Grund:**
Das Interface ist der Vertrag zwischen Bibliothek und TSE-Anbietern. Ohne eine stabile Interface-Definition können WP-03 (Manager) und WP-05 (Mock) nicht parallel entwickelt werden.

**Hinweise:**
- GUID des Interfaces einmalig generieren und festschreiben (nie ändern — Delphi-Binärkompatibilität)
- `TTseProviderBase` erbt von `TInterfacedObject`, implementiert `ITseProvider` als `abstract`
- Basisklasse übernimmt: Exception-to-FehlerMeldung-Mapping, optionales Event-Log-Callback (`OnLogMessage: TProc<String>`)
- `Initialize` erhält JSON-String als `ConfigData` — die Basis-Klasse parst keinen JSON, gibt ihn 1:1 weiter
- `GetStatus` soll einen strukturierten JSON-String zurückgeben (TSE-Version, Verbindungsstatus, Füllstand)

**Abnahmekriterien:**
- [ ] Interface `ITseProvider` mit allen 6 Methoden definiert und kompilierbar
- [ ] `TTseProviderBase` implementiert Logging-Callback und Exception-Wrapping
- [ ] Alle Methoden der Basisklasse sind `abstract` (kein toter Code)
- [ ] GUID ist eingetragen und eindeutig
- [ ] Unit-Tests belegen, dass eine leere Subklasse kompiliert und instanziierbar ist

---

### WP-TSE-03 — TTseManager Kernlogik

**Info:**
Implementiert `TTseManager` mit `ProcessBeleg` (Einzel-Transaktion), `OpenBeleg`/`UpdateBeleg`/`CloseBeleg` (mehrstufige Transaktion) und der QR-Code-Generierung nach BSI TR-03153.

**Grund:**
Dies ist der primäre Einstiegspunkt für Kassensoftware-Entwickler. Alle anderen WPs stützen sich auf diesen Manager oder setzen ihn voraus.

**Hinweise:**
- `ProcessBeleg` darf `StartTransaction` und `FinishTransaction` nicht mischen — immer beides aufrufen (TSE-Protokoll schreibt offene Transaktion vor)
- Bei Fehler in `FinishTransaction`: Exception werfen, **nicht** ein leeres Result liefern — offene TSE-Transaktionen sind ein Compliance-Problem
- QR-Code-Format: `V0;{SerNr};{StartISO};{EndISO};{Zähler};{AnzTrans};{SigBase64}` — exakt nach TR-03153 Anhang A, keine optionalen Felder weglassen
- `TDateTime` für QR-Code immer als UTC ausgeben: `FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', TTimeZone.Local.ToUniversalTime(dt))`
- Manager ist **nicht** thread-safe — dokumentieren, dass pro Kasse eine Instanz zu verwenden ist

**Abnahmekriterien:**
- [ ] `ProcessBeleg` ruft `StartTransaction` und `FinishTransaction` in genau dieser Reihenfolge auf
- [ ] QR-Code-String entspricht TR-03153 Anhang A (Referenz-Vektor aus BSI-Dokument bestanden)
- [ ] Bei Provider-Exception in FinishTransaction wirft Manager eine `ETseTransactionError` weiter
- [ ] `OpenBeleg`/`CloseBeleg` erzeugen valide `TSignaturErgebnis` mit befülltem `QrCodeData`
- [ ] Unit-Tests mit MockProvider (WP-05) decken alle 3 öffentlichen Workflows ab

---

### WP-TSE-04 — DSFinV-K Datenexport

**Info:**
Implementiert `ExportAuditData` — generiert die für Finanzamtprüfungen vorgeschriebene TAR-Datei mit Kassendaten im DSFinV-K-Format aus dem TSE-internen Audit-Log.

**Grund:**
Die KassenSichV verpflichtet Betreiber, auf Anfrage eine exportierte Datendatei vorzulegen. Ohne diesen Export ist die Bibliothek nicht vollständig compliant. Finanzamt-Prüfsoftware (z. B. IDEA) erwartet das genaue DSFinV-K-Schema.

**Hinweise:**
- `ExportAuditData(TargetPath)` delegiert zunächst an `FProvider.ExportAuditData` — der Provider erzeugt die Roh-TAR der TSE
- Zusätzlich schreibt der Manager eine `index.json` mit Metadaten (Kassennummer, Exportzeitpunkt, TSE-Seriennummer) in denselben Ordner
- TAR-Datei darf nicht entpackt/verändert werden — Integrität ist durch TSE-interne Signatur gesichert
- Exportpfad muss schreibbar sein, sonst `EDirectoryWriteError`
- DSFinV-K-Version: 2.3 (aktuell, Stand BSI-Veröffentlichung 2024)

**Abnahmekriterien:**
- [ ] `ExportAuditData` erzeugt eine `.tar`-Datei im angegebenen Verzeichnis
- [ ] `index.json` enthält `tse_serial`, `kasse_id`, `export_timestamp` (ISO 8601)
- [ ] Bei nicht schreibbarem Pfad: sprechende Exception, kein stiller Fehlschlag
- [ ] Exportierte Datei besteht Validierung mit dem DSFinV-K-Prüftool (Referenzimplementierung BMF)

---

### WP-TSE-05 — MockTseProvider (Test-Doppelgänger)

**Info:**
Implementiert `TMockTseProvider`, der `ITseProvider` vollständig erfüllt, aber keine echte TSE benötigt. Erzeugt deterministische Testsignaturen und ist konfigurierbar für Fehlersimulation.

**Grund:**
Ohne einen Mock können weder Unit-Tests noch Bondrucktests ohne physische TSE-Hardware durchgeführt werden. Kontinuierliche Integration (CI) wäre sonst nicht möglich.

**Hinweise:**
- Signaturwert: SHA-256 über `TransId + Zeitstempel` als Base64 — deterministisch, aber nicht kryptografisch sicher (nur für Tests)
- Zähler: einfacher Integer, startet bei 1, wird bei jedem `FinishTransaction` inkrementiert
- `SimulateError: Boolean` — wenn `True`, wirft `FinishTransaction` eine `ETseConnectionError`
- `LastBeleg: TBelegDaten` und `LastSignatur: TSignaturErgebnis` als öffentliche Felder für Assertion in Tests
- `ExportAuditData` schreibt eine leere `mock_audit.tar` (Datei muss existieren, Inhalt egal)

**Abnahmekriterien:**
- [ ] `TMockTseProvider` implementiert alle 6 Interface-Methoden ohne externe Abhängigkeiten
- [ ] `SignaturZaehler` ist je Instanz monoton steigend
- [ ] `SimulateError = True` → `FinishTransaction` wirft Exception, kein Result
- [ ] `LastSignatur.QrCodeData` ist nach `ProcessBeleg` befüllt (via Manager-Test)
- [ ] Bibliothek kompiliert und alle WP-03-Tests laufen grün ohne TSE-Hardware

---

### WP-TSE-06 — RestTseProvider (Cloud-TSE-Anbindung)

**Info:**
Implementiert `TRestTseProvider` für Cloud-TSE-Anbieter (z. B. Fiskaly, Deutsche Fiskal). Kommuniziert über HTTPS/REST und kapselt Authentifizierung, Retry-Logik und Deserialisierung.

**Grund:**
Cloud-TSEs sind in Deutschland weit verbreitet (geringere Hardwarekosten, zentrale Verwaltung). Ein produktionsreifer REST-Provider ist für den realen Einsatz der Bibliothek unabdingbar.

**Hinweise:**
- `ConfigData` (JSON) muss `api_url`, `api_key`, `client_id` enthalten — bei fehlendem Feld: `EConfigurationError` mit Feldname
- HTTP-Client: Delphi `THTTPClient` (System.Net.HttpClient) — keine externen HTTP-Libs
- Timeout: 5 Sekunden connect, 10 Sekunden read (TSE-Antwort kann langsam sein)
- Retry: max. 3 Versuche bei HTTP 503/504, exponentielles Backoff (1s, 2s, 4s)
- TLS: mindestens TLS 1.2 erzwingen (`THTTPClient.SecureProtocols`)
- Antwort-Parsing: JSON nach `TSignaturErgebnis` mappen — Feldnamen nach Fiskaly-API-Spec (konfigurierbar via Mapping-JSON)
- Credentials **niemals** loggen (api_key maskieren: `***`)

**Abnahmekriterien:**
- [ ] `Initialize` mit fehlendem `api_key` wirft `EConfigurationError` mit Meldung "api_key fehlt"
- [ ] Erfolgreicher `FinishTransaction`-Call gegen Fiskaly-Sandbox liefert valides `TSignaturErgebnis`
- [ ] HTTP 503 löst 3 Retry-Versuche aus (messbar via Mock-HTTP-Server)
- [ ] `api_key` erscheint nicht im Log-Callback
- [ ] TLS < 1.2 wird abgelehnt (Integrationstest mit Testserver)

---

### WP-TSE-07 — FileTseProvider (Offline-/Hardware-Interface)

**Info:**
Implementiert `TFileTseProvider` für Hardware-TSEs, die über ein lokales Datei-Interface kommunizieren (z. B. Swissbit-USB-Stick, Epson-TSE). Schreibt Request-Dateien in ein Verzeichnis, liest Response-Dateien.

**Grund:**
Viele stationäre Kassen nutzen USB-TSEs mit proprietärem File-Interface. Ein File-Provider deckt diesen Anwendungsfall ohne Vendor-SDK-Abhängigkeit ab.

**Hinweise:**
- `ConfigData` (JSON): `base_path` (Verzeichnis des TSE-Mounts), `timeout_ms` (default 5000)
- Request-Format: JSON-Datei `{TransId}_req.json` im `base_path`
- Response-Format: TSE schreibt `{TransId}_res.json` — Provider pollt bis Timeout
- Poll-Intervall: 100 ms (kein Busy-Wait, `Sleep(100)` im Loop)
- Nach erfolgreichem Read: beide Dateien löschen (keine Rückstände)
- Timeout: `ETseTimeoutError` mit `TransId` im Message-Text

**Abnahmekriterien:**
- [ ] Request-Datei wird korrekt als JSON im `base_path` erzeugt
- [ ] Response-Datei wird korrekt gelesen und in `TSignaturErgebnis` gemappt
- [ ] Timeout nach `timeout_ms` wirft `ETseTimeoutError`
- [ ] Beide Dateien werden nach erfolgreicher Transaktion gelöscht
- [ ] Test mit simuliertem TSE-Response-Writer (separates CLI-Tool) läuft durch

---

### WP-TSE-08 — Fehlerbehandlung & Exception-Hierarchie

**Info:**
Definiert eine vollständige, strukturierte Exception-Hierarchie für die Bibliothek und stellt sicher, dass alle Provider und der Manager ausschließlich diese Typen verwenden.

**Grund:**
Kassensoftware-Entwickler müssen TSE-Fehler von allgemeinen Delphi-Exceptions unterscheiden können. Eine flache `Exception`-Hierarchie macht differenzierte Fehlerbehandlung unmöglich.

**Hinweise:**
- Basis: `ETseException = class(Exception)` mit Feldern `ErrorCode: Integer` und `ProviderInfo: String`
- Unterklassen: `ETseConnectionError`, `ETseTimeoutError`, `ETseSignatureError`, `ETseConfigurationError`, `ETseTransactionError`
- Alle internen Exceptions aus Provider-Implementierungen müssen in die Hierarchie gewrapped werden (kein `raise Exception.Create`)
- `ErrorCode` orientiert sich an IETF-HTTP-Codes wo sinnvoll (408=Timeout, 503=Verbindungsfehler, 400=Konfiguration)
- Exception-Messages sind auf Deutsch (Anwendungssprache ist DE)

**Abnahmekriterien:**
- [ ] Alle 5 Exception-Typen existieren und erben korrekt von `ETseException`
- [ ] Kein `raise Exception.Create` oder `raise EInOutError` außerhalb von Tests
- [ ] MockProvider kann alle Exception-Typen via Konfiguration auslösen (für Test-Coverage)
- [ ] Exception-Hierarchie ist in `KassenSichV.Exceptions` Unit dokumentiert

---

### WP-TSE-09 — Integrationstests & Referenz-Testvektoren

**Info:**
Erstellt eine umfassende DUnit-Testsuite, die alle WPs abdeckt, und validiert die QR-Code-Ausgabe gegen die offiziellen BSI TR-03153-Testvektoren.

**Grund:**
Compliance-Bibliotheken haben null Toleranz für falsche Ausgaben. Ein Fehler im QR-Code-Format oder Signaturzähler ist eine Ordnungswidrigkeit für den Kassenbetreiber. Testvektoren aus BSI-Dokumenten sind die einzige belastbare Quelle.

**Hinweise:**
- BSI TR-03153, Anhang A: enthält mindestens 3 Referenz-Testvektoren (Input → erwarteter QR-String) — diese 1:1 als DUnit-Tests abbilden
- MockProvider-basierte Tests für Manager-Logik (WP-05)
- Integrationstests gegen Fiskaly-Sandbox (WP-06) nur in separater Test-Suite, die nicht im Standard-Build läuft (benötigt API-Credentials)
- Testabdeckung: Ziel ≥ 90 % Zeilencoverage auf `KassenSichV.Manager` und `KassenSichV.Types`
- Testprojekt ist eigenständige `.dpr`-Datei, keine Abhängigkeit auf Kassensoftware

**Abnahmekriterien:**
- [ ] Alle 3 BSI-Referenz-Testvektoren bestehen (QR-Code exakt korrekt)
- [ ] Alle Mock-basierten Manager-Tests laufen ohne echte TSE durch
- [ ] Fehlerszenarien (Timeout, Verbindungsfehler, Konfigurationsfehler) sind als Negativtests abgedeckt
- [ ] CI-Build führt Standard-Testsuite aus und bricht bei Fehler ab

---

### WP-TSE-10 — Beispielanwendung & Developer-Dokumentation

**Info:**
Erstellt eine minimale Delphi-Konsolenanwendung, die den vollständigen ProcessBeleg-Workflow mit dem MockProvider demonstriert, sowie eine `README.md` mit Quickstart und API-Referenz.

**Grund:**
Ohne ein lauffähiges Beispiel ist die Einstiegshürde für neue Entwickler zu hoch. Die Beispielapp dient gleichzeitig als manueller Smoke-Test und als Copy-Paste-Vorlage.

**Hinweise:**
- Beispielapp nutzt ausschließlich `KassenSichV.*`-Units und `TMockTseProvider` — keine externen Abhängigkeiten
- Ausgabe auf Konsole: alle Felder von `TSignaturErgebnis`, QR-Code als ASCII-Darstellung (optional: über Drittbibliothek)
- `README.md`: Installation, 10-Zeilen-Quickstart, Interface-Übersicht, FAQ zu häufigen Fehlerbildern
- Inline-XML-Dokumentation in allen `public` Klassen und Methoden (Delphi Help Insight kompatibel)
- Beispielapp kompiliert mit Delphi 12 und Delphi 11 (keine v12-only Features)

**Abnahmekriterien:**
- [ ] Beispielapp kompiliert und läuft ohne Konfiguration (MockProvider ist Default)
- [ ] Ausgabe zeigt validen QR-Code-String (passt zum TR-03153-Format)
- [ ] `README.md` enthält Quickstart, der in unter 5 Minuten zu einem laufenden Beispiel führt
- [ ] Alle `public` Methoden haben XML-Doc-Kommentare
- [ ] Kompilierbar mit Delphi 11 und Delphi 12 (getestet)
