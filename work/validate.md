# Fahrplan: Validierungs-Einheiten für Lyx (`std/validate/`)

## Namenskonvention

| Typ | Präfix | Beispiel |
|-----|--------|---------|
| Internationale Nummer | Kürzel der Norm | `ISINValidate`, `VINValidate` |
| Deutschlandspezifisch | `DE` | `DEIDCardValidate`, `DERVNRValidate` |
| Niederlandespezifisch | `NL` | `NLBSNValidate` |
| Schweizspezifisch     | `CH` | `CHAHVValidate` |
| USA-spezifisch        | `US` | `USSSNValidate`, `USCUSIPValidate` |

**Regel:** Wenn eine Nummer nur in einem Land gilt, trägt der Funktionsname den ISO-3166-1-alpha-2-Ländercode als Präfix. So erkennt ein Nutzer sofort, ob eine Funktion national gebunden ist.  
Hinweis: `GermanTaxIDValidate` in `luhn.lyx` gilt als Altbestand und wird im Zuge der DE-Phase auf `DESteuerIDValidate` migriert.

---

## Bestand (bereits implementiert)

| Unit | Funktionen (Auswahl) | Algorithmus |
|------|----------------------|-------------|
| `luhn.lyx` | `LuhnValidate`, `CreditCardValidate`, `IMEIValidate`, `GermanTaxIDValidate` | Luhn (Mod 10) |
| `iban.lyx` | `IBANValidate`, `IBANFormat`, `IBANGetCountry` | ISO 7064 Mod 97 |
| `ean.lyx`  | `EAN13Validate`, `EAN8Validate` | EAN Mod 10 (Gewichtung 1-3) |
| `isbn.lyx` | `ISBN13ValidateFull`, `ISBN10ValidateFull` | EAN-13 / Mod 11 |
| `vat.lyx`  | `VATValidate`, `VATValidateDE`, … (25 Länder) | Länderspezifisch |

---

## Phase 1 – Deutsche Identifikationsnummern

Datei: **`std/validate/de_personal.lyx`**  
Einheitenpräfix: `DEPersonal`

### 1.1 Personalausweis & Reisepass MRZ — `DEIDCardValidate`
- Maschinenlesbarer Bereich (MRZ), Zone 1 & 2
- Prüfziffernberechnung: Gewichte **7, 3, 1** zyklisch, Summe **Mod 10**
- Zeichen `<` = 0, Buchstaben A–Z = 10–35
- Funktionen:
  - `DEMRZCheckDigit(field: pchar): int64` — berechnet Prüfziffer eines MRZ-Feldes
  - `DEIDCardValidate(mrz_line1: pchar, mrz_line2: pchar): int64` — vollständige MRZ-Validierung
  - `DEPassportValidate(mrz_line1: pchar, mrz_line2: pchar, mrz_line3: pchar): int64` — 3-zeilige Variante (biometrischer Pass)
- Fehlercodes: `DE_IDCARD_OK`, `DE_IDCARD_ERR_LENGTH`, `DE_IDCARD_ERR_CHAR`, `DE_IDCARD_ERR_CHECK`

### 1.2 Steueridentifikationsnummer — `DESteuerIDValidate`
- 11 Ziffern; erste Ziffer ≠ 0, keine Ziffer darf dreimal hintereinander vorkommen
- Algorithmus: ISO 6716 (verschachteltes Mod 10 / Mod 11)
  1. Laufsumme = 10, in jeder Stelle: `product = (digit + sum) mod 10`, falls 0 → 10; `sum = (product * 2) mod 11`
  2. Prüfziffer = `(11 - sum) mod 10`
- Migration: `GermanTaxIDValidate` in `luhn.lyx` durch Alias auf `DESteuerIDValidate` ersetzen
- Funktionen:
  - `DESteuerIDValidate(id: pchar): int64`
  - `DESteuerIDCheckDigit(id: pchar): int64`
- Fehlercodes: `DE_STEUERID_OK`, `DE_STEUERID_ERR_LENGTH`, `DE_STEUERID_ERR_FIRST_DIGIT`, `DE_STEUERID_ERR_CONSECUTIVE`, `DE_STEUERID_ERR_CHECK`

### 1.3 Rentenversicherungsnummer — `DERVNRValidate`
- Format: `YYMMDDABBBBBBBP` (12 Zeichen: 2 Bereichsnummer + 6 Geburtsdatum + 1 Initial + 3 Seriennummer + 1 Geschlecht + 1 Prüfziffer)
- Serienprüfverfahren (Mod 10, ähnlich Luhn): Buchstabe (Position 9) wird durch Ordinalwert (A=01 … Z=26) ersetzt → 13-stellige reine Zahlenkette
- Feste Gewichte: `2 1 2 1 2 1 2 1 2 1 2 1`; Ziffernprodukte > 9 werden quergesummt
- Summe Mod 10 = Prüfziffer
- Funktionen:
  - `DERVNRValidate(rvnr: pchar): int64`
  - `DERVNRCheckDigit(rvnr: pchar): int64`
  - `DERVNRGetBirthdate(rvnr: pchar, out_buf: pchar): int64`
- Fehlercodes: `DE_RVNR_OK`, `DE_RVNR_ERR_LENGTH`, `DE_RVNR_ERR_FORMAT`, `DE_RVNR_ERR_CHECK`

### 1.4 Krankenkassen-Versichertennummer (eGK) — `DEGKVValidate`
- 10 Zeichen: 1 Buchstabe + 9 Ziffern; Buchstabe an Position 1 wird in zweistellige Zahl umgewandelt (A=01 … Z=26) → 11-stellige Zahlenkette
- Gewichtung **2 1 2 1 2 1 2 1 2 1 2** (Luhn-ähnlich), Quersum­me bei Produkt > 9
- Letzte Stelle = Prüfziffer aus `Summe Mod 10`
- Funktionen:
  - `DEGKVValidate(nr: pchar): int64`
  - `DEGKVCheckDigit(nr: pchar): int64`
- Fehlercodes: `DE_GKV_OK`, `DE_GKV_ERR_LENGTH`, `DE_GKV_ERR_FIRST_CHAR`, `DE_GKV_ERR_CHECK`

---

## Phase 2 – Deutsche Fach- & Sachnummern

Datei: **`std/validate/de_numbers.lyx`**  
Einheitenpräfix: `DENum`

### 2.1 Pharmazentralnummer — `DEPZNValidate`
- 8 Ziffern (inkl. Prüfziffer); ältere Nummern 7-stellig mit führender 0 auffüllen
- Gewichte: **2 3 4 5 6 7** für Stellen 1–6; Summe Mod 11
- Rest 11 → ungültig; Rest 10 → Prüfziffer = 0 (Ausnahme)
- Funktionen:
  - `DEPZNValidate(pzn: pchar): int64`
  - `DEPZNCheckDigit(pzn: pchar): int64`
  - `DEPZNNormalize(pzn: pchar, out_buf: pchar): int64` — führende Null ergänzen
- Fehlercodes: `DE_PZN_OK`, `DE_PZN_ERR_LENGTH`, `DE_PZN_ERR_CHAR`, `DE_PZN_ERR_CHECK`

### 2.2 Wertpapierkennnummer — `DEWKNValidate`
- 6 alphanumerische Zeichen (A–Z, 0–9); Buchstaben: A=10 … Z=35
- Gewichte abwechselnd **2 1 2 1 2 1**; Ziffernprodukte > 9 werden quergesummt
- Prüfziffer: `(10 - (Summe Mod 10)) Mod 10`
- Funktionen:
  - `DEWKNValidate(wkn: pchar): int64`
  - `DEWKNCheckDigit(wkn: pchar): int64`
- Fehlercodes: `DE_WKN_OK`, `DE_WKN_ERR_LENGTH`, `DE_WKN_ERR_CHAR`, `DE_WKN_ERR_CHECK`

### 2.3 GND-Nummer (Gemeinsame Normdatei) — `DEGNDValidate`
- Format: bis zu 9 Ziffern + optionales `X` als Prüfziffer
- Modulo-11-Verfahren: Gewichte **9 8 7 6 5 4 3 2 1**; Rest 10 → Prüfzeichen `X`, Rest 11 → 0
- Wichtig für Bibliotheks- und Linkdatensysteme (Wikipedia, Universitäten)
- Funktionen:
  - `DEGNDValidate(gnd: pchar): int64`
  - `DEGNDCheckDigit(gnd: pchar): int64` — gibt ASCII-Zeichen zurück (`'0'`–`'9'` oder `'X'`)
- Fehlercodes: `DE_GND_OK`, `DE_GND_ERR_LENGTH`, `DE_GND_ERR_CHAR`, `DE_GND_ERR_CHECK`

### 2.4 Zählpunktbezeichnung (Strom/Gas) — `DEMeterIDValidate`
- 33-stellige ID (z. B. `DE00012345678900000000000000000001`)
- Aufbau: 2 Ländercode + 10 Netzbetreiberkennung + 20 Zählpunktkennung + 1 Prüfziffer
- Prüfziffer: Mod-10-Verfahren über den numerischen Teil (Buchstaben über Ordinalwert eingerechnet)
- Funktionen:
  - `DEMeterIDValidate(id: pchar): int64`
  - `DEMeterIDGetOperator(id: pchar, out_buf: pchar): int64`
- Fehlercodes: `DE_METERID_OK`, `DE_METERID_ERR_LENGTH`, `DE_METERID_ERR_COUNTRY`, `DE_METERID_ERR_CHECK`

---

## Phase 3 – Internationale Wertpapiere & Finanz

Datei: **`std/validate/isin.lyx`**  
Einheitenpräfix: `ISIN`

### 3.1 ISIN — `ISINValidate`
- 12 Zeichen: 2 Ländercode (ISO 3166-1) + 9 alphanumerische Zeichen + 1 Prüfziffer
- Buchstaben A–Z → zweistellige Zahlen (A=10 … Z=35) → reine Ziffernkette
- Auf diese Kette wird der **Luhn-Algorithmus** angewendet
- Funktionen:
  - `ISINValidate(isin: pchar): int64`
  - `ISINCheckDigit(isin: pchar): int64`
  - `ISINGetCountry(isin: pchar, out_buf: pchar): int64`
  - `ISINNormalize(isin: pchar, out_buf: pchar): int64` — Leerzeichen entfernen, Großschreibung
- Fehlercodes: `ISIN_OK`, `ISIN_ERR_LENGTH`, `ISIN_ERR_COUNTRY`, `ISIN_ERR_CHAR`, `ISIN_ERR_CHECK`

Datei: **`std/validate/lei.lyx`**  
Einheitenpräfix: `LEI`

### 3.2 LEI (Legal Entity Identifier) — `LEIValidate`
- 20 Zeichen: 4 LOU-Präfix + 14 alphanumerische Entitätskennung + 2 Prüfziffern
- Verfahren identisch mit IBAN: ISO 7064 **Mod 97** (Prüfziffern an Ende → Anfang rotieren, Buchstaben A=10 … Z=35, `Restvalue Mod 97 == 1`)
- Funktionen:
  - `LEIValidate(lei: pchar): int64`
  - `LEIGetLOU(lei: pchar, out_buf: pchar): int64`
- Fehlercodes: `LEI_OK`, `LEI_ERR_LENGTH`, `LEI_ERR_CHAR`, `LEI_ERR_CHECK`

Datei: **`std/validate/bic.lyx`**  
Einheitenpräfix: `BIC`

### 3.3 BIC/SWIFT-Code — `BICValidate`
- Keine mathematische Prüfziffer; rein strukturelle Validierung:
  - 4 Zeichen Bankcode (A–Z)
  - 2 Zeichen Ländercode ISO 3166-1 alpha-2
  - 2 Zeichen Ortscode (A–Z, 0–9; zweiter Zeichen nicht `O`)
  - 3 optionale Zeichen Filialcode (A–Z, 0–9; `XXX` = Zentrale)
- Gesamtlänge: 8 oder 11 Zeichen
- Funktionen:
  - `BICValidate(bic: pchar): int64`
  - `BICNormalize(bic: pchar, out_buf: pchar): int64` — Großschreibung, Leerzeichen entfernen
  - `BICGetBankCode(bic: pchar, out_buf: pchar): int64`
  - `BICGetCountry(bic: pchar, out_buf: pchar): int64`
  - `BICIsHeadOffice(bic: pchar): int64`
- Fehlercodes: `BIC_OK`, `BIC_ERR_LENGTH`, `BIC_ERR_BANKCODE`, `BIC_ERR_COUNTRY`, `BIC_ERR_LOCATION`

Datei: **`std/validate/us_cusip.lyx`** *(US-spezifisch)*  
Einheitenpräfix: `USCUSIP`

### 3.4 CUSIP — `USCUSIPValidate`
- 9 alphanumerische Zeichen (CUSIP Services); 8 Nutzdaten + 1 Prüfziffer
- Buchstaben A–Z → 10–35; `*`=36, `@`=37, `#`=38; Ziffern 0–9
- Gewichte abwechselnd **1 2 1 2 1 2 1 2**; Ziffernprodukte > 9 werden quergesummt
- Prüfziffer: `(10 - (Summe Mod 10)) Mod 10`
- Funktionen:
  - `USCUSIPValidate(cusip: pchar): int64`
  - `USCUSIPCheckDigit(cusip: pchar): int64`
- Fehlercodes: `US_CUSIP_OK`, `US_CUSIP_ERR_LENGTH`, `US_CUSIP_ERR_CHAR`, `US_CUSIP_ERR_CHECK`

---

## Phase 4 – Fahrzeuge & Transport

Datei: **`std/validate/vin.lyx`**

### 4.1 FIN/VIN (Fahrzeugidentifikationsnummer) — `VINValidate`
- 17 Zeichen (Buchstaben I, O, Q verboten)
- Position 9 = Prüfziffer (US-Markt & globale Hersteller)
- Transliteration: A=1, B=2, … H=8, J=1, K=2, … (herstellerspezifische Tabelle nach FMVSS 565)
- Gewichte für Positionen 1–17: `8 7 6 5 4 3 2 10 0 9 8 7 6 5 4 3 2`
- Prüfziffer: `Summe Mod 11`; Rest 10 = `'X'`
- Funktionen:
  - `VINValidate(vin: pchar): int64`
  - `VINCheckDigit(vin: pchar): int64`
  - `VINGetModelYear(vin: pchar): int64`
  - `VINGetManufacturer(vin: pchar, out_buf: pchar): int64`
- Fehlercodes: `VIN_OK`, `VIN_ERR_LENGTH`, `VIN_ERR_FORBIDDEN_CHAR`, `VIN_ERR_CHECK`

Datei: **`std/validate/iso6346.lyx`**

### 4.2 Container-Nummer (ISO 6346) — `ContainerValidate`
- 11 Zeichen: 3 Buchstaben Eigentümercode + 1 Buchstabe Gerätekategorie + 6 Ziffern Seriennummer + 1 Prüfziffer
- Buchstaben: A=10, B=12, … (11 und Vielfache von 11 werden übersprungen!)
- Gewichte: `2^0 2^1 2^2 … 2^9` (Zweierpotenzen für Positionen 1–10)
- Prüfziffer: `Summe Mod 11`; Rest 10 → Prüfziffer = 0 (Ausnahme per ISO)
- Funktionen:
  - `ContainerValidate(id: pchar): int64`
  - `ContainerCheckDigit(id: pchar): int64`
  - `ContainerGetOwner(id: pchar, out_buf: pchar): int64`
  - `ContainerGetSerial(id: pchar, out_buf: pchar): int64`
- Fehlercodes: `CONTAINER_OK`, `CONTAINER_ERR_LENGTH`, `CONTAINER_ERR_CATEGORY`, `CONTAINER_ERR_CHAR`, `CONTAINER_ERR_CHECK`

Datei: **`std/validate/uic.lyx`**

### 4.3 UIC-Fahrzeugnummer (Eisenbahn) — `UICVehicleValidate`
- 12 Ziffern für Reisezugwagen & Triebfahrzeuge in Europa
- Luhn-Algorithmus (Gewichtung **2 1 2 1 2 1 2 1 2 1 2**), Quersum­me bei Produkt > 9
- Letzte Stelle = Prüfziffer `(10 - (Summe Mod 10)) Mod 10`
- Funktionen:
  - `UICVehicleValidate(nr: pchar): int64`
  - `UICVehicleCheckDigit(nr: pchar): int64`
  - `UICVehicleGetCountry(nr: pchar): int64` — ISO-Ländercode aus Ziffern 1–2
- Fehlercodes: `UIC_OK`, `UIC_ERR_LENGTH`, `UIC_ERR_CHAR`, `UIC_ERR_CHECK`

Datei: **`std/validate/iata.lyx`**

### 4.4 IATA-Ticketnummer & Air Waybill — `IATATicketValidate`
- Ticketnummer: 3 Airline-Code + 10 Ziffern (letzte = Prüfziffer); Prüfziffer = `Zahl Mod 7`
- Air Waybill: 3 Airline-Code + 8 Ziffern; Prüfziffer = `Zahl[1..7] Mod 7`
- Algorithmus: Die Ziffernkette (ohne Prüfstelle) als ganze Zahl interpretiert, dann `Mod 7`
- Funktionen:
  - `IATATicketValidate(ticket: pchar): int64`
  - `IATAAWBValidate(awb: pchar): int64`
  - `IATACheckDigit(number_str: pchar): int64`
- Fehlercodes: `IATA_OK`, `IATA_ERR_LENGTH`, `IATA_ERR_CHAR`, `IATA_ERR_CHECK`

Datei: **`std/validate/mmsi.lyx`**

### 4.5 MMSI (Seefunk) — `MMSIValidate`
- 9 Ziffern; keine klassische Endprüfziffer
- Strukturelle Validierung anhand Länderpräfix-Tabellen (ITU-Tabelle):
  - Maritime MID (Maritime Identification Digits): Ziffern 1–3
  - Gruppenrufe: Präfix `0`; Seerettung: `970`; Küstenfunkstellen: `00MIDRRRR`
- Funktionen:
  - `MMSIValidate(mmsi: pchar): int64`
  - `MMSIGetCountry(mmsi: pchar, out_buf: pchar): int64`
  - `MMSIGetType(mmsi: pchar): int64` — Schiff / Küstenfunkstelle / Gruppenruf / SAR
- Fehlercodes: `MMSI_OK`, `MMSI_ERR_LENGTH`, `MMSI_ERR_CHAR`, `MMSI_ERR_INVALID_MID`

---

## Phase 5 – Wissenschaft & Publikationen

Datei: **`std/validate/issn.lyx`**

### 5.1 ISSN — `ISSNValidate`
- 8 Ziffern (inkl. Prüfziffer, kann `X` sein)
- Gewichte **8 7 6 5 4 3 2**; Summe Mod 11 = 0 (sonst ungültig)
- Rest 10 → Prüfziffer `X`
- Funktionen:
  - `ISSNValidate(issn: pchar): int64`
  - `ISSNCheckDigit(issn: pchar): int64`
  - `ISSNNormalize(issn: pchar, out_buf: pchar): int64` — Bindestriche normieren
- Fehlercodes: `ISSN_OK`, `ISSN_ERR_LENGTH`, `ISSN_ERR_CHAR`, `ISSN_ERR_CHECK`

Datei: **`std/validate/ismn.lyx`**

### 5.2 ISMN (Musiknoten) — `ISMNValidate`
- 13 Zeichen: Präfix `979-0` + 7 alphanumerische Zeichen + 1 Prüfziffer
- Identisches Verfahren wie EAN-13: Gewichtung **1 3 1 3 1 3 … 1**, Summe Mod 10
- Prüfziffer: `(10 - (Summe Mod 10)) Mod 10`
- Funktionen:
  - `ISMNValidate(ismn: pchar): int64`
  - `ISMNCheckDigit(ismn: pchar): int64`
  - `ISMNNormalize(ismn: pchar, out_buf: pchar): int64`
- Fehlercodes: `ISMN_OK`, `ISMN_ERR_LENGTH`, `ISMN_ERR_PREFIX`, `ISMN_ERR_CHECK`

Datei: **`std/validate/isrc.lyx`**

### 5.3 ISRC (Musikaufnahmen) — `ISRCValidate`
- Format: `CC-XXX-YY-NNNNN` (12 Zeichen ohne Bindestriche)
  - `CC`: ISO-3166-1-alpha-2-Ländercode (Großbuchstaben)
  - `XXX`: 3-stelliger alphanumerischer Registrantencode
  - `YY`: 2-stelliges Jahr (00–99)
  - `NNNNN`: 5-stellige Seriennummer
- Keine mathematische Prüfziffer; Validierung: Zeichenklassen + Ländercode-Tabelle
- Funktionen:
  - `ISRCValidate(isrc: pchar): int64`
  - `ISRCNormalize(isrc: pchar, out_buf: pchar): int64` — Bindestriche normieren
  - `ISRCGetCountry(isrc: pchar, out_buf: pchar): int64`
  - `ISRCGetYear(isrc: pchar): int64`
- Fehlercodes: `ISRC_OK`, `ISRC_ERR_LENGTH`, `ISRC_ERR_COUNTRY`, `ISRC_ERR_CHAR`

Datei: **`std/validate/orcid.lyx`**

### 5.4 ORCID iD — `ORCIDValidate`
- 16 Ziffern in Format `XXXX-XXXX-XXXX-XXXC` (letzte Stelle kann `X` sein)
- Algorithmus: ISO/IEC 7064 **MOD 11-2**
  - Laufsumme beginnt mit 0; je Ziffer: `total = (total + digit) * 2`; am Ende: `(12 - (total Mod 11)) Mod 11`
  - Rest 10 → Prüfzeichen `X`
- Funktionen:
  - `ORCIDValidate(orcid: pchar): int64`
  - `ORCIDCheckDigit(orcid: pchar): int64`
  - `ORCIDNormalize(orcid: pchar, out_buf: pchar): int64` — Bindestriche normieren
- Fehlercodes: `ORCID_OK`, `ORCID_ERR_LENGTH`, `ORCID_ERR_CHAR`, `ORCID_ERR_CHECK`

Datei: **`std/validate/cas.lyx`**

### 5.5 CAS-Nummer — `CASValidate`
- Format: `NNNNNN-NN-N` (7-10 Stellen + 2 Stellen + 1 Prüfziffer)
- Algorithmus: Alle Ziffern (ohne Prüfziffer, ohne Bindestriche) **von hinten nach vorne** mit 1, 2, 3, … multiplizieren; `Summe Mod 10` = Prüfziffer
- Funktionen:
  - `CASValidate(cas: pchar): int64`
  - `CASCheckDigit(cas: pchar): int64`
  - `CASNormalize(cas: pchar, out_buf: pchar): int64`
- Fehlercodes: `CAS_OK`, `CAS_ERR_FORMAT`, `CAS_ERR_CHAR`, `CAS_ERR_CHECK`

---

## Phase 6 – Andere Länderspezifische Nummern

Datei: **`std/validate/nl_bsn.lyx`** *(Niederlande)*

### 6.1 BSN (Burgerservicenummer) — `NLBSNValidate`
- 9 Ziffern
- **9-Proef** (Neun-Test): Abwandlung Mod 11
  - Gewichte: **9 8 7 6 5 4 3 2 −1** (letzte Stelle negativ!)
  - Summe muss durch 11 teilbar sein (`Summe Mod 11 == 0`)
- Funktionen:
  - `NLBSNValidate(bsn: pchar): int64`
  - `NLBSNCheckSum(bsn: pchar): int64`
- Fehlercodes: `NL_BSN_OK`, `NL_BSN_ERR_LENGTH`, `NL_BSN_ERR_CHAR`, `NL_BSN_ERR_CHECK`

Datei: **`std/validate/ch_ahv.lyx`** *(Schweiz)*

### 6.2 AHV-Nummer — `CHAHVValidate`
- 13 Ziffern: Präfix `756` (ISO-Ländercode Schweiz) + 9 Ziffern + 1 Prüfziffer
- EAN-Profil: Gewichtung **1 3 1 3 1 3 1 3 1 3 1 3**; Summe Mod 10
- Prüfziffer: `(10 - (Summe Mod 10)) Mod 10`
- Funktionen:
  - `CHAHVValidate(ahv: pchar): int64`
  - `CHAHVCheckDigit(ahv: pchar): int64`
  - `CHAHVNormalize(ahv: pchar, out_buf: pchar): int64` — Punkte normieren
- Fehlercodes: `CH_AHV_OK`, `CH_AHV_ERR_LENGTH`, `CH_AHV_ERR_PREFIX`, `CH_AHV_ERR_CHECK`

Datei: **`std/validate/us_ssn.lyx`** *(USA)*

### 6.3 SSN (Social Security Number) — `USSSNValidate`
- 9 Ziffern in Format `AAA-BB-CCCC`
- Keine Prüfziffer (historisch); Validierung über Blockrestriktionen:
  - Area Number (AAA): 001–899, nicht 666
  - Group Number (BB): 01–99
  - Serial Number (CCCC): 0001–9999
  - Sperrliste bekannter ungültiger Muster (z. B. `123-45-6789`, `219-09-9999`)
- Funktionen:
  - `USSSNValidate(ssn: pchar): int64`
  - `USSSNNormalize(ssn: pchar, out_buf: pchar): int64`
  - `USSSNGetArea(ssn: pchar): int64`
- Fehlercodes: `US_SSN_OK`, `US_SSN_ERR_LENGTH`, `US_SSN_ERR_CHAR`, `US_SSN_ERR_AREA`, `US_SSN_ERR_GROUP`, `US_SSN_ERR_SERIAL`, `US_SSN_ERR_KNOWN_INVALID`

---

## Phase 7 – Sonstige internationale Normen

Datei: **`std/validate/ewc.lyx`**

### 7.1 EWC/AVV-Abfallschlüssel — `EWCValidate`
- 6-stelliger Code im Format `XX XX XX` (Kapitel-Unterkapitel-Eintrag)
- Validierung strukturell gegen den offiziellen Europäischen Abfallkatalog (2000/532/EG)
- Sternchen `*` am Ende kennzeichnet gefährlichen Abfall
- Funktionen:
  - `EWCValidate(code: pchar): int64`
  - `EWCIsHazardous(code: pchar): int64`
  - `EWCNormalize(code: pchar, out_buf: pchar): int64`
- Fehlercodes: `EWC_OK`, `EWC_ERR_FORMAT`, `EWC_ERR_UNKNOWN_CODE`

---

## Gemeinsame Hilfsfunktionen (intern, pro Unit)

Jede Unit implementiert lokal (nicht exportiert):

| Funktion | Zweck |
|----------|-------|
| `XxxStrLen(s)` | Länge ohne stdlib-Abhängigkeit |
| `XxxIsDigit(c)` | Zeichenklasse Ziffer |
| `XxxIsAlpha(c)` | Zeichenklasse Buchstabe |
| `XxxIsAlphaNum(c)` | Zeichenklasse alphanumerisch |
| `XxxToUpper(c)` | Normierung auf Großbuchstaben |
| `XxxDigitToInt(c)` | `'0'`–`'9'` → 0–9 |
| `XxxNormalize(s, out)` | Leerzeichen/Bindestriche entfernen, Groß­schreibung |

---

## Implementierungsreihenfolge (Empfehlung)

| Prio | Unit | Begründung |
|------|------|-----------|
| 1 | `de_personal.lyx` (§ 1.1–1.4) | Hohe praktische Relevanz im DACH-Raum |
| 2 | `de_numbers.lyx` (§ 2.1 PZN) | PZN in jedem DE-Apothekenprojekt benötigt |
| 3 | `isin.lyx` | Finanzanwendungen, nutzt vorhandenen Luhn |
| 4 | `vin.lyx` | Automotive, weit verbreitet |
| 5 | `issn.lyx` | Kurze Implementierung, hoher Nutzen |
| 6 | `orcid.lyx` | ISO 7064 MOD 11-2 Referenzimplementierung |
| 7 | `lei.lyx` | Nutzt vorhandenen IBAN Mod-97-Code |
| 8 | `bic.lyx` | Rein strukturell, schnell implementiert |
| 9 | `iso6346.lyx` | Logistik/Shipping |
| 10 | `nl_bsn.lyx`, `ch_ahv.lyx`, `us_ssn.lyx` | DACH + US Länderpakete |
| 11 | `cas.lyx`, `ismn.lyx`, `isrc.lyx` | Wissenschaft & Medien |
| 12 | `uic.lyx`, `iata.lyx`, `mmsi.lyx` | Transport-Spezialdomänen |
| 13 | `de_numbers.lyx` (§ 2.2–2.4) | WKN/GND/Zähler |
| 14 | `us_cusip.lyx` | US-Finanzmarkt |
| 15 | `ewc.lyx` | Abfallwirtschaft (Katalog-Daten nötig) |

---

## Algorithmus-Übersicht

| Algorithmus | Einheiten | Schutzgrad |
|-------------|-----------|------------|
| Luhn Mod 10 | Kreditkarten, IMEI, ISIN, UIC, GKV, RVNR | Gut |
| Mod 10 gewichtet (7-3-1) | MRZ (Personalausweis/Pass) | Gut |
| Mod 10 (EAN-Profil 1-3) | EAN, ISMN, CH-AHV | Gut |
| Mod 11 | ISBN-10, ISSN, PZN, GND, VIN | Sehr gut |
| Mod 11 verschachtelt | DE-Steuer-ID | Sehr gut |
| 9-Proef (Mod 11 mit −1) | NL-BSN | Sehr gut |
| Mod 11 ISO/IEC 7064 | ORCID | Sehr gut |
| Mod 97 ISO/IEC 7064 | IBAN, LEI | Exzellent |
| Zweierpotenzen Mod 11 | ISO 6346 Container | Sehr gut |
| Mod 7 | IATA | Einfach |
| Strukturell | BIC, ISRC, MMSI, SSN, EWC | Formatprüfung |
