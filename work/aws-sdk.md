# Lyx AWS SDK (`std/cloud/aws`) — Fahrplan

Dieses Dokument beschreibt den vollständigen Entwicklungsplan für das offizielle
AWS SDK von Lyx — analog zu boto3 (Python), `@aws-sdk` (Node.js) oder dem AWS SDK
for Go. Ziel ist ein vollständiges, rein in Lyx implementiertes SDK, das
**mehrere AWS-Services**, eine **CLI (`lyxaws`)** und die gesamte
**Credential-Infrastruktur** abdeckt.

**Konvention:** WP-AWS-NN (AWS SDK, Nummer). Status-Symbole: ✅ Erledigt,
🔄 In Arbeit, ⬜ Offen.

**Abhängigkeit:** `work/s3.md` — die dortigen WP-S3-01 (SHA-256/HMAC) und
WP-S3-02 (SigV4) werden hier als WP-AWS-03 generalisiert und sind Voraussetzung
für alle Service-Clients.

---

## Vision

```lyx
import std.cloud.aws;
import std.cloud.s3;
import std.cloud.ec2;
import std.cloud.dynamodb;
import std.cloud.lambda;
import std.io;

pub fn main(): int64 {
  // Credentials automatisch aus ~/.aws/credentials laden
  var creds: int64 := AWSCredentialsDefault();

  // S3: Datei hochladen
  var s3: int64 := S3Connect(creds, "eu-central-1");
  S3PutObject(s3, "mein-bucket", "report.txt", data, len, "text/plain");

  // EC2: Alle laufenden Instanzen auflisten
  var ec2: int64 := EC2Connect(creds, "eu-central-1");
  var instances: int64 := EC2DescribeInstances(ec2, "running");
  var i: int64 := 0;
  while (i < EC2InstanceCount(instances)) {
    PrintStr(EC2GetInstanceId(instances, i));
    PrintStr(" – ");
    PrintStr(EC2GetInstanceType(instances, i));
    PrintStr("\n");
    i := i + 1;
  }

  // DynamoDB: Item speichern
  var ddb: int64 := DDBConnect(creds, "eu-central-1");
  var item: int64 := DDBItemNew();
  DDBItemSetStr(item, "id", "user-42");
  DDBItemSetStr(item, "name", "Alice");
  DDBItemSetInt(item, "age", 30);
  DDBPutItem(ddb, "users", item);

  // Lambda: Funktion aufrufen
  var lam: int64 := LambdaConnect(creds, "eu-central-1");
  var response: pchar := LambdaInvoke(lam, "MyFunction", "{\"key\":\"value\"}");
  PrintStr(response);

  return 0;
}
```

**lyxaws CLI:**
```bash
# Credentials konfigurieren
lyxaws configure

# S3
lyxaws s3 ls
lyxaws s3 ls s3://mein-bucket/bilder/
lyxaws s3 cp report.pdf s3://mein-bucket/
lyxaws s3 cp s3://mein-bucket/report.pdf .

# EC2
lyxaws ec2 describe-instances --filter state=running
lyxaws ec2 start-instances --id i-0abc123def456

# DynamoDB
lyxaws dynamodb list-tables
lyxaws dynamodb get-item --table users --key '{"id":{"S":"user-42"}}'

# Lambda
lyxaws lambda list-functions
lyxaws lambda invoke --function MyFunction --payload '{"key":"val"}' out.json

# Logs
lyxaws logs tail /aws/lambda/MyFunction --follow
```

---

## Architektur-Überblick

```
┌──────────────────────────────────────────────────────────────────────┐
│                       lyxaws CLI                                     │
│  s3 · ec2 · iam · dynamodb · lambda · sqs · sns · logs · secrets     │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
┌──────────────────────────────▼───────────────────────────────────────┐
│                    Service-Clients (std/cloud/)                      │
│  s3.lyu · ec2.lyu · iam.lyu · dynamodb.lyu · lambda.lyu             │
│  sqs.lyu · sns.lyu · cloudwatch.lyu · secrets.lyu                   │
└──────┬───────────────┬──────────────────┬───────────────┬────────────┘
       │               │                  │               │
┌──────▼──────┐ ┌──────▼──────┐ ┌────────▼─────┐ ┌──────▼────────────┐
│ Query-Proto │ │ JSON-Proto  │ │ REST-JSON    │ │ REST-XML (S3)     │
│ (EC2, SQS,  │ │ (DynamoDB,  │ │ (Lambda,     │ │ (S3, STS-XML)     │
│  SNS, STS)  │ │  CW, Secr.) │ │  ELB, R53)   │ │                   │
└──────┬──────┘ └──────┬──────┘ └──────┬───────┘ └──────┬────────────┘
       └───────────────┴───────────────┴────────────────┘
                               │
┌──────────────────────────────▼───────────────────────────────────────┐
│                    AWS Core  (std/cloud/aws/)                        │
│  aws/core.lyu        Credential Chain, Endpoint Resolution           │
│  aws/transport.lyu   HTTPS + Retry + Error Handling                  │
│  aws/sigv4.lyu       AWS SigV4 Signing (aus WP-S3-02)                │
│  aws/xml.lyu         XML-Response-Parser                             │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
┌──────────────────────────────▼───────────────────────────────────────┐
│  std/crypto/sha256.lyu   std/net/https   std/json   std/base64       │
└──────────────────────────────────────────────────────────────────────┘
```

### AWS-API-Protokolle im Überblick

| Protokoll | Services | Transport | Body | Antwort |
|-----------|----------|-----------|------|---------|
| **Query** | EC2, SQS, SNS, AutoScaling | HTTPS POST | `x-www-form-urlencoded` | XML |
| **JSON** | DynamoDB, CloudWatch, Logs, Secrets, SSM, STS, IAM | HTTPS POST | JSON | JSON |
| **REST-JSON** | Lambda, ELB, Route53, API GW | HTTPS REST | JSON | JSON |
| **REST-XML** | S3 | HTTPS REST | XML | XML |

### Datei-Überblick

```
std/
  cloud/
    aws/
      core.lyu          ← Credential Chain, Endpoint Resolution
      transport.lyu     ← HTTPS-Transport, Retry, Error
      sigv4.lyu         ← SigV4 (generalisiert aus S3-02)
      xml.lyu           ← XML-Response-Parser
    s3.lyu              ← S3-Client (aus work/s3.md)
    ec2.lyu             ← EC2-Client
    iam.lyu             ← IAM + STS
    dynamodb.lyu        ← DynamoDB
    lambda.lyu          ← Lambda
    sqs.lyu             ← SQS
    sns.lyu             ← SNS
    cloudwatch.lyu      ← CloudWatch Metrics + Logs
    secrets.lyu         ← Secrets Manager + SSM
  crypto/
    sha256.lyu          ← SHA-256 (aus WP-S3-01)
bin/
  lyxaws.lyx            ← CLI-Einstiegspunkt
  lyxaws/
    configure.lyu       ← lyxaws configure
    cmd_s3.lyu          ← lyxaws s3 …
    cmd_ec2.lyu         ← lyxaws ec2 …
    cmd_dynamodb.lyu    ← lyxaws dynamodb …
    cmd_lambda.lyu      ← lyxaws lambda …
    cmd_logs.lyu        ← lyxaws logs …
    cmd_secrets.lyu     ← lyxaws secrets …
    output.lyu          ← JSON-/Tabellen-Ausgabe
```

---

## AWS-Credential-Chain — Reihenfolge

```
1. Explizit im Code (AWSCredentialsStatic)
2. Umgebungsvariablen:
     AWS_ACCESS_KEY_ID
     AWS_SECRET_ACCESS_KEY
     AWS_SESSION_TOKEN (optional, für temporäre Credentials)
     AWS_DEFAULT_REGION
3. ~/.aws/credentials  (INI-Format, [default] + benannte Profile)
4. ~/.aws/config       (Region, output, role_arn, source_profile)
5. ECS-Container-Credentials (HTTP 169.254.170.2/…)
6. EC2 Instance Metadata (HTTP 169.254.169.254/latest/meta-data/iam/security-credentials/)
```

### ~/.aws/credentials Format

```ini
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

[production]
aws_access_key_id = AKIAI44QH8DHBEXAMPLE
aws_secret_access_key = je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY
```

### ~/.aws/config Format

```ini
[default]
region = eu-central-1
output = json

[profile production]
region = us-east-1
role_arn = arn:aws:iam::123456789012:role/MyDeployRole
source_profile = default
mfa_serial = arn:aws:iam::123456789012:mfa/alice
```

---

## AWS-Protokolldetails

### Query-Protokoll (EC2, SQS, SNS)

```
POST https://ec2.eu-central-1.amazonaws.com/
Content-Type: application/x-www-form-urlencoded
[SigV4-Header]

Action=DescribeInstances&Version=2016-11-15
&Filter.1.Name=instance-state-name
&Filter.1.Value.1=running
```

XML-Antwort:
```xml
<DescribeInstancesResponse>
  <reservationSet>
    <item>
      <instancesSet><item>
        <instanceId>i-0abcdef1234567890</instanceId>
        <instanceType>t3.micro</instanceType>
        <instanceState><name>running</name></instanceState>
      </item></instancesSet>
    </item>
  </reservationSet>
</DescribeInstancesResponse>
```

### JSON-Protokoll (DynamoDB, CloudWatch, Secrets Manager)

```
POST https://dynamodb.eu-central-1.amazonaws.com/
Content-Type: application/x-amz-json-1.0
X-Amz-Target: DynamoDB_20120810.PutItem
[SigV4-Header]

{"TableName":"users","Item":{"id":{"S":"42"},"name":{"S":"Alice"}}}
```

JSON-Antwort: direkt als JSON-Object (Fehler als `{"__type":"...","message":"..."}`)

### REST-JSON-Protokoll (Lambda)

```
POST https://lambda.eu-central-1.amazonaws.com/2015-03-31/functions/MyFunc/invocations
Content-Type: application/json
[SigV4-Header]

{"key":"value"}
```

### Fehlerformat (JSON)

```json
{
  "__type": "ResourceNotFoundException",
  "message": "Table not found: nonexistent"
}
```

### Fehlerformat (XML, für EC2 / STS)

```xml
<Response>
  <Errors><Error>
    <Code>InvalidInstanceID.NotFound</Code>
    <Message>The instance ID 'i-0000' does not exist</Message>
  </Error></Errors>
  <RequestID>…</RequestID>
</Response>
```

---

## Phasen

| Phase | Inhalt | WPs |
|-------|--------|-----|
| 1 | Krypto-Fundament: SHA-256, SigV4 (aus S3-Plan) | AWS-01 |
| 2 | Core: Credentials, Transport, Retry, Endpoint | AWS-02 – AWS-04 |
| 3 | Parser: XML + JSON-Protokoll-Helpers | AWS-05 |
| 4 | Service-Clients: S3, EC2, IAM/STS | AWS-06 – AWS-08 |
| 5 | Service-Clients: DynamoDB, Lambda | AWS-09 – AWS-10 |
| 6 | Service-Clients: SQS, SNS, CloudWatch, Secrets | AWS-11 – AWS-13 |
| 7 | lyxaws CLI | AWS-14 |
| 8 | Demos & Integrationstests | AWS-15 |

---

## Work Packages

---

### WP-AWS-01: SHA-256, HMAC-SHA256 & SigV4 (generalisiert) ⬜

**Ziel:** Die Krypto- und Signing-Grundlage für das gesamte SDK schaffen.
Baut direkt auf WP-S3-01 und WP-S3-02 auf — hier werden diese Units
generalisiert, sodass sie für jeden AWS-Service (nicht nur S3) funktionieren.

**Zu implementieren:**

`std/crypto/sha256.lyu` (aus WP-S3-01, unverändert übernehmen):
- `SHA256(data, len, out[32])`
- `SHA256Hex(data, len) → pchar`
- `HMACSHA256(key, keyLen, data, dataLen, out[32])`
- `HMACSHA256Hex(key, keyLen, data, dataLen) → pchar`
- `HexEncode(data, len) → pchar`

`std/cloud/aws/sigv4.lyu` (generalisiert aus WP-S3-02):
- Neu: `AWSSignCtx`-Struct mit `service`-Feld (nicht mehr hardcoded `"s3"`)
- Neu: `sigv4SignQuery(ctx) → pchar` — für Presigned URLs (beliebiger Service)
- Neu: `sigv4AddSecurityToken(ctx, session_token)` — für temporäre Credentials (STS/IAM-Rollen)
- Alles andere aus WP-S3-02 unverändert übernehmen

**Kompatibilitäts-Test:** Alle bestehenden SigV4-Testvektoren (AWS offizielle Suite)
müssen weiter bestehen.

**Dateien:**
- `std/crypto/sha256.lyu`
- `std/cloud/aws/sigv4.lyu`

---

### WP-AWS-02: Credential Chain ⬜

**Ziel:** Alle Standard-Credential-Quellen in einer priorisierten Kette
implementieren — das SDK lädt automatisch die richtigen Zugangsdaten,
ohne dass der Nutzer etwas konfigurieren muss.

**Zu implementieren:**

- `AWSCreds`-Struct:
  ```
  AWSCreds {
    access_key=pchar; secret_key=pchar
    session_token=pchar          // null für permanente Creds, gesetzt für STS/Role
    expiration=int64             // Unix-Timestamp, 0 = kein Ablauf
    source=int64                 // CREDS_STATIC / ENV / FILE / ECS / EC2_META
    region=pchar                 // aus Konfiguration (optional)
    profile=pchar                // genutztes Profil
  }
  ```
- Quell-Konstanten: `CREDS_STATIC`, `CREDS_ENV`, `CREDS_FILE`, `CREDS_ECS`, `CREDS_EC2_META`
- `AWSCredentialsStatic(access_key, secret_key) → int64`
  — explizite Credentials (höchste Priorität)
- `AWSCredentialsStaticWithToken(access_key, secret_key, session_token) → int64`
  — für STS/AssumeRole-Credentials
- `AWSCredentialsFromEnv() → int64`
  — liest `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
  — via sys_getenv (oder Lesen aus `/proc/self/environ`)
- `AWSCredentialsFromFile(path, profile) → int64`
  — parst `~/.aws/credentials` (INI-Format)
  — `profile = 0` → `"default"`
- `AWSConfigFromFile(path, profile) → int64`
  — parst `~/.aws/config` für Region, role_arn, source_profile
- `AWSCredentialsFromEC2Meta() → int64`
  — HTTP GET `http://169.254.169.254/latest/meta-data/iam/security-credentials/`
  → Rollenname → JSON mit temporären Credentials
- `AWSCredentialsDefault() → int64`
  — Credential-Chain: Static → Env → File → EC2-Meta
  — gibt erste gefundene zurück; 0 wenn keine
- `AWSCredentialsProfile(profile) → int64`
  — lädt benanntes Profil aus `~/.aws/credentials`
- `AWSCredentialsFree(creds) → void`
- `AWSCredentialsIsExpired(creds) → bool`
- `AWSCredentialsRefresh(creds) → bool`
  — aktualisiert abgelaufene temporäre Credentials (EC2-Meta / ECS)

**INI-Parser** (intern, für credentials + config):
- `iniGetValue(content, section, key) → pchar`
  — minimal: liest `[section]\nkey=value`
- Kommentare (`#`, `;`) und Leerzeilen ignorieren
- Werte können Leerzeichen enthalten (kein Quoting nötig)

**Dateien:**
- `std/cloud/aws/core.lyu` (Abschnitt: Credentials)

**Akzeptanzkriterien:**
- `AWSCredentialsFromEnv` liest korrekte Werte wenn Variablen gesetzt
- `AWSCredentialsFromFile` parst `[default]` + benanntes Profil korrekt
- `AWSCredentialsDefault` gibt ENV-Credentials zurück wenn gesetzt (Priorität)
- `AWSCredentialsDefault` fällt auf Datei zurück wenn keine ENV-Vars
- `AWSCredentialsIsExpired` gibt true wenn expiration < aktuelle Zeit

---

### WP-AWS-03: Core HTTP-Transport & Retry ⬜

**Ziel:** Einen robusten, wiederverwendbaren HTTP/HTTPS-Transport für alle
AWS-Services implementieren — mit automatischen Wiederholungen, Timeouts und
einheitlicher Fehlerbehandlung.

**Zu implementieren:**

- `AWSRequest`-Struct:
  ```
  AWSRequest {
    method=pchar; url=pchar; host=pchar; path=pchar; query=pchar
    headers=int64; header_count=int64; header_alloc=int64
    body=int64; body_len=int64
    creds=int64               // AWSCreds*
    service=pchar; region=pchar
    sign=bool                 // SigV4 automatisch hinzufügen?
  }
  ```
- `AWSResponse`-Struct:
  ```
  AWSResponse {
    status_code=int64
    headers=int64; header_count=int64
    body=int64; body_len=int64
    request_id=pchar          // x-amzn-requestid oder x-amz-request-id
    is_error=bool
    error_code=pchar          // z. B. "ResourceNotFoundException"
    error_message=pchar
  }
  ```
- `awsSend(req) → int64` — sendet Request mit SigV4 + TLS; gibt AWSResponse zurück
- `awsSendWithRetry(req, max_retries) → int64`
  — **Exponential Backoff** bei Retry-fähigen Fehlern:
  - Retry bei: 429 Too Many Requests, 500, 502, 503, 504
  - Warte-Zeiten: 100ms → 200ms → 400ms → 800ms … (Jitter: ±20%)
  - Kein Retry bei: 400, 401, 403, 404, 409 (Client-Fehler)
- `awsAddHeader(req, name, value) → void`
- `awsSetBody(req, data, len) → void`
- `awsResponseFree(resp) → void`
- `awsResponseGetHeader(resp, name) → pchar` — case-insensitiv
- Fehler-Parsing:
  - `awsParseJsonError(body) → void` — füllt `error_code` + `error_message` aus JSON
  - `awsParseXmlError(body) → void` — füllt aus XML `<Error><Code>…</Code></Error>`

**Timeout-Konfiguration:**
```
AWS_SDK_CONNECT_TIMEOUT_MS  = 5000   (Verbindungsaufbau)
AWS_SDK_REQUEST_TIMEOUT_MS  = 30000  (Gesamter Request)
```

**Dateien:**
- `std/cloud/aws/transport.lyu`

**Akzeptanzkriterien:**
- `awsSend` für bekannten AWS-Endpoint liefert valide Antwort
- `awsSendWithRetry` wiederholt bei HTTP 429 maximal `max_retries`-Mal
- Retry-Delay zwischen zwei Versuchen ≥ 100ms (via sleep-Syscall)
- `awsParseJsonError` extrahiert Fehlercode aus DynamoDB-Fehlerantwort korrekt
- `awsParseXmlError` extrahiert Code aus EC2-Fehlerantwort korrekt

---

### WP-AWS-04: Regionale Endpoint-Auflösung ⬜

**Ziel:** Für jeden AWS-Service und jede Region den korrekten HTTPS-Endpunkt
berechnen — inklusive globaler Services, Dual-Stack und LocalStack-Support.

**Zu implementieren:**

- `awsEndpoint(service, region) → pchar`
  — Standard-Template: `<service>.<region>.amazonaws.com`
  — Ausnahmen:
    ```
    s3           → <bucket>.s3.<region>.amazonaws.com  (virtual-hosted)
    iam          → iam.amazonaws.com                   (global)
    sts          → sts.amazonaws.com  ODER  sts.<region>.amazonaws.com
    route53      → route53.amazonaws.com               (global)
    cloudfront   → cloudfront.amazonaws.com            (global)
    ```
- `awsEndpointS3(bucket, region, path_style) → pchar` — S3-Spezialfall
- `awsEndpointCustom(service, region, custom_endpoint) → pchar`
  — für LocalStack: `http://localhost:4566`
  — für MinIO (S3-kompatibel): `http://localhost:9000`
- `AWSServiceConfig`-Struct (pro Service-Client):
  ```
  AWSServiceConfig {
    region=pchar; endpoint=pchar   // custom endpoint (0 = auto)
    use_dual_stack=bool            // IPv4+IPv6: <service>.dualstack.<region>…
    use_fips=bool                  // FIPS-Endpoints für Gov-Cloud
    max_retries=int64              // default: 3
    timeout_ms=int64               // default: 30000
  }
  ```
- `AWSServiceConfigDefault(region) → int64`
- `AWSServiceConfigLocalStack() → int64`
  — preset: endpoint=`http://localhost:4566`
- China-Regionen: `cn-north-1`, `cn-northwest-1` → `.amazonaws.com.cn`-Suffix
- GovCloud: `us-gov-west-1`, `us-gov-east-1` → normale Templates

**Dateien:**
- `std/cloud/aws/core.lyu` (Abschnitt: Endpoint Resolution)

**Akzeptanzkriterien:**
- `awsEndpoint("lambda", "eu-central-1")` == `"lambda.eu-central-1.amazonaws.com"`
- `awsEndpoint("iam", "us-east-1")` == `"iam.amazonaws.com"` (global)
- `awsEndpoint("s3", "cn-north-1")` endet mit `.amazonaws.com.cn`
- `AWSServiceConfigLocalStack` setzt Endpoint auf `http://localhost:4566`

---

### WP-AWS-05: Response-Parser (XML + JSON-Protokoll-Helpers) ⬜

**Ziel:** Wiederverwendbare Parser-Utilities für alle vier AWS-Protokollvarianten.

**XML-Parser** (`std/cloud/aws/xml.lyu`, erweitert aus S3-05):

S3 braucht einen einfachen XML-Extraktor. Für EC2 und STS sind die Strukturen
tiefer verschachtelt — hier wird der Parser robuster gemacht:

- `xmlFind(xml, tag) → pchar` — erster Wert von `<tag>…</tag>` (beliebige Tiefe)
- `xmlFindAll(xml, tag, outCount) → pchar*` — alle Vorkommen
- `xmlFindIn(xml, outer, inner) → pchar` — `<outer>…<inner>…</inner>…</outer>`
- `xmlAttr(tag_str, attr) → pchar` — Attribut aus `<tag attr="val">`
- `xmlNextSibling(xml, off, tag) → pchar` — iteriert gleichnamige Geschwister
- `xmlFreeResults(results, count) → void`

**Query-Protokoll-Helpers** (für EC2, SQS, SNS):
- `awsQueryBuild(action, version, params, count) → pchar`
  — baut `Action=X&Version=Y&Param=Z`-String (URL-enkodiert)
- `awsQueryAdd(buf, key, value) → void`
- `awsQueryAddIndexed(buf, prefix, idx, key, value) → void`
  — für `Filter.1.Name=…`-Muster

**JSON-Protokoll-Helpers** (für DynamoDB, CloudWatch, Secrets):
- `awsJsonRequest(conn, target, body_json) → AWSResponse*`
  — POST mit `X-Amz-Target: <target>` + `Content-Type: application/x-amz-json-1.0`
- `awsJsonRequest11(conn, target, body_json) → AWSResponse*`
  — wie oben, aber `application/x-amz-json-1.1` (für neuere Services)

**REST-JSON-Helpers** (für Lambda, ELB):
- `awsRestJsonRequest(conn, method, path, query, body_json) → AWSResponse*`

**Paginierungs-Helper:**
- `awsPaginationToken(response_json) → pchar`
  — extrahiert `NextToken` / `NextMarker` / `NextContinuationToken` / `Marker`
  aus JSON oder XML (je nach Service unterschiedliche Namen)
- `awsHasMorePages(response) → bool`

**Dateien:**
- `std/cloud/aws/xml.lyu`
- `std/cloud/aws/transport.lyu` (Protokoll-Helpers)

**Akzeptanzkriterien:**
- `xmlFind` findet Wert auch in 5 Ebenen tief verschachteltem XML
- `xmlFindAll` liefert alle `<instanceId>`-Einträge in einer EC2-Antwort
- `awsQueryBuild("DescribeInstances", "2016-11-15", params, n)` erzeugt korrekten Form-Body
- `awsJsonRequest` setzt alle Pflicht-Header korrekt (X-Amz-Target, Content-Type)

---

### WP-AWS-06: S3-Client ⬜

**Ziel:** Den vollständigen S3-Client aus `work/s3.md` in das SDK integrieren
und die API auf `AWSCreds` umstellen.

**Änderungen gegenüber `work/s3.md`:**
- `S3Connect(creds, region) → int64` statt `S3Connect(region, access_key, secret_key)`
- `S3ConnectConfig(creds, config) → int64` für volle Konfiguration
- `sigv4`-Layer nutzt jetzt `std/cloud/aws/sigv4.lyu` (generalisiert)
- `S3PutObjectStream(conn, bucket, key, fd, content_type) → bool`
  — liest aus Datei-Deskriptor statt In-Memory-Buffer (für Streaming)
- Session-Token-Unterstützung: `X-Amz-Security-Token`-Header wenn `creds.session_token != 0`

**Alle WPs aus `work/s3.md`** (S3-03 bis S3-10) werden übernommen;
lediglich die Connect-API ändert sich.

**Dateien:**
- `std/cloud/s3.lyu`

**Akzeptanzkriterien:**
- `S3Connect(AWSCredentialsDefault(), "eu-central-1")` nutzt automatisch
  geladene Credentials
- Session-Token wird korrekt als Header gesetzt
- Alle S3-Akzeptanzkriterien aus `work/s3.md` bestehen weiter

---

### WP-AWS-07: EC2-Client ⬜

**Ziel:** Die wichtigsten EC2-Operationen über das Query-Protokoll implementieren:
Instanzen beschreiben, starten, stoppen, erstellen und terminieren.

**Zu implementieren:**

- `EC2Connect(creds, region) → int64` — gibt EC2Client-Ptr zurück
- `EC2ConnectConfig(creds, config) → int64`
- `EC2Close(conn) → void`

**Instanz-Operationen:**
- `EC2DescribeInstances(conn, state_filter) → int64`
  — `Action=DescribeInstances&Filter.1.Name=instance-state-name&Filter.1.Value.1=<filter>`
  → gibt EC2InstanceList zurück
- `EC2DescribeInstanceById(conn, instance_id) → int64` — ein spezifisches Instance
- `EC2StartInstances(conn, instance_ids, count) → bool`
- `EC2StopInstances(conn, instance_ids, count) → bool`
- `EC2RebootInstances(conn, instance_ids, count) → bool`
- `EC2TerminateInstances(conn, instance_ids, count) → bool`
- `EC2RunInstances(conn, ami_id, instance_type, count, key_name, sg_id) → int64`
  — startet neue Instanz(en); gibt EC2InstanceList zurück

**AMI & Images:**
- `EC2DescribeImages(conn, owner, name_filter) → int64` — gibt EC2ImageList zurück

**Netzwerk:**
- `EC2DescribeVpcs(conn) → int64`
- `EC2DescribeSubnets(conn, vpc_id) → int64`
- `EC2DescribeSecurityGroups(conn, vpc_id) → int64`

**Datentypen:**
- `EC2Instance`-Struct:
  ```
  EC2Instance {
    instance_id=pchar; instance_type=pchar
    state=pchar; public_ip=pchar; private_ip=pchar
    ami_id=pchar; key_name=pchar
    launch_time=pchar; availability_zone=pchar
    vpc_id=pchar; subnet_id=pchar
    tags=int64; tag_count=int64     // Array EC2Tag*
  }
  ```
- `EC2InstanceList`-Struct + Accessoren (`EC2InstanceCount`, `EC2GetInstance`, `EC2InstanceListFree`)
- `EC2Tag`-Struct: `{ key=pchar; value=pchar }`
- `EC2GetTag(instance, key) → pchar`

**Dateien:**
- `std/cloud/ec2.lyu`

**Akzeptanzkriterien:**
- `EC2DescribeInstances(conn, "running")` liefert alle laufenden Instanzen
- `EC2StopInstances` → `EC2DescribeInstanceById` → state `"stopping"` oder `"stopped"`
- `EC2DescribeInstances(conn, "")` ohne Filter = alle Instanzen
- `EC2GetTag(instance, "Name")` gibt den Namen-Tag zurück

---

### WP-AWS-08: IAM + STS-Client ⬜

**Ziel:** Identity-Operationen (Benutzer, Rollen, Keys) und Security Token
Service für temporäre Credentials implementieren.

**STS (Security Token Service):**
- `STSGetCallerIdentity(creds) → int64` — gibt STSIdentity zurück
  (Account-ID, UserId, ARN) — nützlich zum Verifizieren von Credentials
- `STSAssumeRole(creds, role_arn, session_name, duration_sec) → int64`
  — gibt neue `AWSCreds*` zurück (temporäre Credentials, inkl. session_token)
- `STSAssumeRoleWithMFA(creds, role_arn, session_name, serial, token_code) → int64`
- `STSGetSessionToken(creds, duration_sec) → int64` — für MFA-geschützte Calls
- `STSIdentity`-Struct: `{ account=pchar; user_id=pchar; arn=pchar }`

**IAM-Benutzer:**
- `IAMListUsers(creds) → int64` — gibt IAMUserList zurück
- `IAMCreateUser(creds, username) → bool`
- `IAMDeleteUser(creds, username) → bool`
- `IAMGetUser(creds, username) → int64` — IAMUser-Ptr

**IAM-Access-Keys:**
- `IAMCreateAccessKey(creds, username) → int64` — IAMAccessKey-Ptr
- `IAMDeleteAccessKey(creds, username, key_id) → bool`
- `IAMListAccessKeys(creds, username) → int64`
- `IAMAccessKey`-Struct: `{ access_key_id=pchar; secret_key=pchar; status=pchar; created=pchar }`

**IAM-Rollen:**
- `IAMListRoles(creds, path_prefix) → int64`
- `IAMCreateRole(creds, name, assume_role_policy_json) → bool`
- `IAMAttachRolePolicy(creds, role_name, policy_arn) → bool`
- `IAMGetRole(creds, name) → int64`

**IAM-Policies:**
- `IAMListAttachedRolePolicies(creds, role_name) → int64`
- `IAMListAttachedUserPolicies(creds, username) → int64`
- `IAMAttachUserPolicy(creds, username, policy_arn) → bool`

**Dateien:**
- `std/cloud/iam.lyu`

**Akzeptanzkriterien:**
- `STSGetCallerIdentity` gibt korrektes Account + ARN zurück
- `STSAssumeRole` liefert temporäre Credentials mit `session_token != 0`
- Temporäre Credentials funktionieren für nachfolgende S3/EC2-Aufrufe
- `IAMCreateAccessKey` + `IAMDeleteAccessKey` ohne Fehler

---

### WP-AWS-09: DynamoDB-Client ⬜

**Ziel:** Vollständige DynamoDB-CRUD-Operationen über das JSON-Protokoll.

**DynamoDB-Datenmodell in Lyx:**

DynamoDB speichert Items als Attribute-Maps mit Typ-Annotierungen:
```json
{"id":{"S":"42"}, "name":{"S":"Alice"}, "age":{"N":"30"}, "active":{"BOOL":true}}
```

- `DDBItem`-Struct (per `mmap`):
  ```
  DDBItem { attrs=int64; attr_count=int64; attr_alloc=int64 }
  ```
- `DDBItemNew() → int64`
- `DDBItemSetStr(item, key, value) → void` — Typ `S`
- `DDBItemSetNum(item, key, value_str) → void` — Typ `N` (Zahl als String)
- `DDBItemSetInt(item, key, value) → void` — Typ `N`, int64 → Dezimalstring
- `DDBItemSetFloat(item, key, value) → void` — Typ `N`, f64 → String
- `DDBItemSetBool(item, key, value) → void` — Typ `BOOL`
- `DDBItemSetNull(item, key) → void` — Typ `NULL`
- `DDBItemSetBlob(item, key, data, len) → void` — Typ `B` (base64-kodiert)
- `DDBItemGetStr(item, key) → pchar`
- `DDBItemGetInt(item, key) → int64`
- `DDBItemGetFloat(item, key) → f64`
- `DDBItemGetBool(item, key) → bool`
- `DDBItemIsNull(item, key) → bool`
- `DDBItemFree(item) → void`
- `DDBItemSerialize(item) → pchar` — gibt JSON-Attribut-Map zurück
- `DDBItemDeserialize(json) → int64` — parst JSON-Attribut-Map → DDBItem

**Table-Operationen:**
- `DDBConnect(creds, region) → int64`
- `DDBListTables(conn) → pchar*` — gibt Array von Tabellennamen zurück
- `DDBCreateTable(conn, name, pk_name, pk_type, sk_name, sk_type, billing) → bool`
- `DDBDeleteTable(conn, name) → bool`
- `DDBDescribeTable(conn, name) → pchar` — raw JSON
- `DDBTableExists(conn, name) → bool`

**Item-Operationen:**
- `DDBPutItem(conn, table, item) → bool`
- `DDBGetItem(conn, table, key_item) → int64` — gibt DDBItem zurück (oder 0)
- `DDBDeleteItem(conn, table, key_item) → bool`
- `DDBUpdateItem(conn, table, key_item, update_expr, expr_values) → bool`
  — Expression: `"SET #name = :name"` mit `ExpressionAttributeValues`

**Query & Scan:**
- `DDBQuery(conn, table, key_cond, filter, limit) → int64` — gibt DDBResultSet zurück
- `DDBScan(conn, table, filter, limit) → int64`
- `DDBResultSet`-Struct + Accessoren: `DDBResultCount`, `DDBResultGetItem`, `DDBResultFree`
- `DDBResultHasMore(result) → bool` — LastEvaluatedKey vorhanden?
- `DDBResultLastKey(result) → int64` — DDBItem (ExclusiveStartKey für nächste Seite)

**Dateien:**
- `std/cloud/dynamodb.lyu`

**Akzeptanzkriterien:**
- `DDBPutItem` + `DDBGetItem` → Roundtrip für alle Attributtypen (S, N, BOOL, NULL)
- `DDBDeleteItem` + `DDBGetItem` → 0 zurück
- `DDBQuery` mit PK-Filter → korrekte Ergebnismenge
- `DDBScan` ohne Filter → alle Items der Tabelle

---

### WP-AWS-10: Lambda-Client ⬜

**Ziel:** Lambda-Funktionen aufrufen, verwalten und Code deployen.

**Zu implementieren:**

- `LambdaConnect(creds, region) → int64`
- `LambdaInvoke(conn, function_name, payload_json) → pchar`
  — POST `.../functions/<name>/invocations`; gibt Response-JSON zurück
- `LambdaInvokeAsync(conn, function_name, payload_json) → bool`
  — `X-Amz-Invocation-Type: Event` (fire-and-forget)
- `LambdaInvokeResult`-Struct:
  ```
  LambdaInvokeResult {
    status_code=int64; payload=pchar
    function_error=pchar    // aus x-amz-function-error Header
    log_result=pchar        // base64-dekodiertes Tail-Log (wenn LogType=Tail)
  }
  ```
- `LambdaInvokeDetailed(conn, function_name, payload_json, log_tail) → int64`
- `LambdaListFunctions(conn) → int64` — gibt LambdaFunctionList zurück
- `LambdaGetFunction(conn, name) → int64`
- `LambdaCreateFunction(conn, name, runtime, role_arn, handler, zip_data, zip_len) → bool`
- `LambdaUpdateFunctionCode(conn, name, zip_data, zip_len) → bool`
- `LambdaUpdateFunctionCodeFromS3(conn, name, s3_bucket, s3_key) → bool`
- `LambdaDeleteFunction(conn, name) → bool`
- `LambdaAddPermission(conn, name, statement_id, action, principal) → bool`
- `LambdaGetFunctionArn(conn, name) → pchar`
- `LambdaFunction`-Struct:
  ```
  LambdaFunction {
    name=pchar; arn=pchar; runtime=pchar
    handler=pchar; role=pchar; description=pchar
    timeout_sec=int64; memory_mb=int64
    last_modified=pchar; code_size=int64
  }
  ```

**Dateien:**
- `std/cloud/lambda.lyu`

**Akzeptanzkriterien:**
- `LambdaInvoke` für Echo-Funktion: Response = Payload
- `LambdaListFunctions` gibt alle Funktionen zurück
- `LambdaCreateFunction` + `LambdaInvoke` + `LambdaDeleteFunction` ohne Fehler

---

### WP-AWS-11: SQS + SNS-Client ⬜

**Ziel:** Message-Queue- und Publish/Subscribe-Operationen für asynchrone
Anwendungsarchitekturen.

**SQS (Simple Queue Service) — Query-Protokoll:**
- `SQSConnect(creds, region) → int64`
- `SQSCreateQueue(conn, name) → pchar` — gibt Queue-URL zurück
- `SQSGetQueueUrl(conn, name) → pchar`
- `SQSDeleteQueue(conn, url) → bool`
- `SQSListQueues(conn, prefix) → pchar*`
- `SQSSendMessage(conn, url, body) → pchar` — gibt MessageId zurück
- `SQSSendMessageDelayed(conn, url, body, delay_sec) → pchar`
- `SQSReceiveMessage(conn, url, max_count, wait_sec) → int64` — gibt SQSMessageList zurück
- `SQSDeleteMessage(conn, url, receipt_handle) → bool`
- `SQSChangeVisibility(conn, url, receipt_handle, timeout_sec) → bool`
- `SQSGetAttributes(conn, url) → pchar` — raw JSON mit Queue-Attributen
- `SQSMessage`-Struct: `{ message_id=pchar; receipt_handle=pchar; body=pchar; attributes=pchar }`

**SNS (Simple Notification Service) — Query-Protokoll:**
- `SNSConnect(creds, region) → int64`
- `SNSCreateTopic(conn, name) → pchar` — gibt Topic-ARN zurück
- `SNSDeleteTopic(conn, arn) → bool`
- `SNSListTopics(conn) → pchar*`
- `SNSPublish(conn, topic_arn, message, subject) → pchar` — gibt MessageId zurück
- `SNSPublishToPhone(conn, phone, message) → pchar` — SMS-Versand
- `SNSSubscribe(conn, topic_arn, protocol, endpoint) → pchar` — gibt Subscription-ARN
- `SNSUnsubscribe(conn, subscription_arn) → bool`
- `SNSListSubscriptions(conn, topic_arn) → int64`

**Dateien:**
- `std/cloud/sqs.lyu`
- `std/cloud/sns.lyu`

**Akzeptanzkriterien:**
- `SQSCreateQueue` + `SQSSendMessage` + `SQSReceiveMessage` → Nachricht korrekt empfangen
- `SQSDeleteMessage` verhindert erneutes Empfangen
- `SNSCreateTopic` + `SNSPublish` ohne Fehler
- SQS-FIFO-Queue: `SQSCreateQueue("test.fifo")` → korrekte URL

---

### WP-AWS-12: CloudWatch (Metrics + Logs) ⬜

**Ziel:** Monitoring-Metriken schreiben und Logs lesen — die Grundlage für
Observability aller Lyx-Anwendungen auf AWS.

**CloudWatch Metrics — JSON-Protokoll:**
- `CWConnect(creds, region) → int64`
- `CWPutMetric(conn, namespace, name, value, unit, dimensions) → bool`
  — `X-Amz-Target: GraniteServiceVersion20100801.PutMetricData`
- `CWPutMetrics(conn, namespace, metrics_json) → bool` — Batch-Version
- `CWGetMetricStats(conn, namespace, name, start, end, period, stat) → int64`
  — gibt CWDatapoints zurück
- `CWPutAlarm(conn, name, namespace, metric, threshold, comparison, periods, sns_arn) → bool`
- Einheiten-Konstanten: `CW_UNIT_COUNT`, `CW_UNIT_SECONDS`, `CW_UNIT_BYTES`,
  `CW_UNIT_PERCENT`, `CW_UNIT_NONE`, …

**CloudWatch Logs — JSON-Protokoll:**
- `CWLogsConnect(creds, region) → int64`
- `CWLogsCreateGroup(conn, group_name) → bool`
- `CWLogsCreateStream(conn, group_name, stream_name) → bool`
- `CWLogsPutEvents(conn, group_name, stream_name, events, count) → bool`
  — sendet Batch von Log-Einträgen (max. 1 MB / max. 10.000 Events)
- `CWLogsGetEvents(conn, group_name, stream_name, start, end, limit) → int64`
- `CWLogsFilterEvents(conn, group_name, pattern, start, end, limit) → int64`
  — CloudWatch Logs Insights Lite (Filter Pattern)
- `CWLogsTailStream(conn, group_name, stream_name, callback, ctx) → void`
  — pollt kontinuierlich (nextForwardToken) und ruft callback für neue Events
- `CWLogEvent`-Struct: `{ timestamp=int64; message=pchar }`

**Dateien:**
- `std/cloud/cloudwatch.lyu`

**Akzeptanzkriterien:**
- `CWPutMetric` → Metrik in CloudWatch Console sichtbar
- `CWLogsPutEvents` → Events im CloudWatch Log Stream sichtbar
- `CWLogsGetEvents` liefert genau die gepushten Events zurück
- `CWPutAlarm` erzeugt Alarm ohne Fehler

---

### WP-AWS-13: Secrets Manager & SSM Parameter Store ⬜

**Ziel:** Sichere Speicherung und Abruf von Credentials, API-Keys und
Konfigurationswerten — die Grundlage dafür, dass Lyx-Programme **niemals
Passwörter im Code haben**.

**Secrets Manager — JSON-Protokoll:**
- `SecretsConnect(creds, region) → int64`
- `SecretsGetValue(conn, secret_id) → pchar` — gibt Secret-String zurück
- `SecretsGetValueJSON(conn, secret_id, key) → pchar`
  — parst `{"username":"…","password":"…"}` und gibt Wert für `key` zurück
- `SecretsCreateSecret(conn, name, value) → pchar` — gibt ARN zurück
- `SecretsUpdateValue(conn, secret_id, new_value) → bool`
- `SecretsDeleteSecret(conn, secret_id, force) → bool`
- `SecretsListSecrets(conn) → pchar*`
- `SecretsRotateSecret(conn, secret_id, lambda_arn) → bool`

**SSM Parameter Store — JSON-Protokoll:**
- `SSMConnect(creds, region) → int64`
- `SSMGetParameter(conn, name, with_decryption) → pchar` — gibt Wert zurück
- `SSMGetParametersByPath(conn, path, recursive) → int64` — gibt Param-Liste zurück
- `SSMPutParameter(conn, name, value, param_type, overwrite) → bool`
  — `param_type`: `"String"` / `"SecureString"` / `"StringList"`
- `SSMDeleteParameter(conn, name) → bool`
- Typ-Konstanten: `SSM_TYPE_STRING`, `SSM_TYPE_SECURE`, `SSM_TYPE_LIST`
- `SSMParameter`-Struct: `{ name=pchar; value=pchar; type=pchar; version=int64 }`

**Pattern: Kein Passwort im Code:**
```lyx
// Schlechtes Beispiel:
var conn: int64 := MySQLConnect("host", 3306, "user", "HARDCODED_PASSWORD", "db");

// Gutes Beispiel mit Secrets Manager:
var pw: pchar := SecretsGetValue(secrets_conn, "prod/mysql/password");
var conn: int64 := MySQLConnect("host", 3306, "user", pw, "db");
```

**Dateien:**
- `std/cloud/secrets.lyu`

**Akzeptanzkriterien:**
- `SecretsCreateSecret` + `SecretsGetValue` → Roundtrip korrekt
- `SecretsGetValueJSON(conn, "db/mysql", "password")` extrahiert Schlüssel korrekt
- `SSMPutParameter` + `SSMGetParameter(with_decryption=true)` → Roundtrip
- `SSMGetParametersByPath("/app/prod/", true)` liefert alle verschachtelten Params

---

### WP-AWS-14: lyxaws CLI ⬜

**Ziel:** Eine vollständige Kommandozeilen-Oberfläche, die das AWS SDK für
Terminal-Nutzung und Skripte zugänglich macht — analog zur offiziellen AWS CLI.

**Zu implementieren:**

**Argument-Parser** (`lyxaws/args.lyu`):
- Subcommand-Dispatching: `lyxaws <service> <command> [--flag value]`
- Globale Flags: `--region`, `--profile`, `--output` (json/table/text), `--endpoint-url`
- `--query` für JMESPath-ähnliche Ausgabefilterung (Basis-Subset)

**`lyxaws configure`:**
- Interaktive Eingabe: Access Key ID, Secret Key, Default Region, Output Format
- Schreibt in `~/.aws/credentials` + `~/.aws/config`
- `lyxaws configure list` — aktuelle Konfiguration anzeigen
- `lyxaws configure get aws_access_key_id` — einzelnen Wert ausgeben

**`lyxaws s3`** (`lyxaws/cmd_s3.lyu`):
```
lyxaws s3 ls                              Liste aller Buckets
lyxaws s3 ls s3://bucket/prefix/          Objekte auflisten
lyxaws s3 cp local.txt s3://bucket/key    Upload
lyxaws s3 cp s3://bucket/key local.txt    Download
lyxaws s3 rm s3://bucket/key              Löschen
lyxaws s3 mv s3://bucket/src s3://b/dst   Umbenennen (Copy + Delete)
lyxaws s3 mb s3://bucket                  Bucket erstellen
lyxaws s3 rb s3://bucket                  Bucket löschen
lyxaws s3 presign s3://bucket/key --expires-in 3600
```

**`lyxaws ec2`** (`lyxaws/cmd_ec2.lyu`):
```
lyxaws ec2 describe-instances [--filter state=running]
lyxaws ec2 start-instances --instance-ids i-0abc,i-0def
lyxaws ec2 stop-instances  --instance-ids i-0abc
lyxaws ec2 describe-images --owner amazon --name "amzn2-ami-*"
```

**`lyxaws iam`** (`lyxaws/cmd_iam.lyu`):
```
lyxaws iam list-users
lyxaws iam create-user --name alice
lyxaws iam create-access-key --user alice
lyxaws iam get-caller-identity
lyxaws iam assume-role --arn arn:aws:iam::…:role/MyRole --session test
```

**`lyxaws dynamodb`** (`lyxaws/cmd_dynamodb.lyu`):
```
lyxaws dynamodb list-tables
lyxaws dynamodb describe-table --table users
lyxaws dynamodb get-item --table users --key '{"id":{"S":"42"}}'
lyxaws dynamodb put-item --table users --item '{"id":{"S":"99"},"name":{"S":"Bob"}}'
lyxaws dynamodb scan --table users
```

**`lyxaws lambda`** (`lyxaws/cmd_lambda.lyu`):
```
lyxaws lambda list-functions
lyxaws lambda invoke --function MyFunc --payload '{"x":1}' output.json
lyxaws lambda update-function-code --function MyFunc --zip-file function.zip
```

**`lyxaws logs`** (`lyxaws/cmd_logs.lyu`):
```
lyxaws logs describe-log-groups
lyxaws logs get-log-events --group /aws/lambda/MyFunc --stream latest
lyxaws logs tail /aws/lambda/MyFunc [--follow]   ← pollt kontinuierlich
lyxaws logs filter --group /aws/lambda/MyFunc --pattern "ERROR"
```

**`lyxaws secrets`** (`lyxaws/cmd_secrets.lyu`):
```
lyxaws secrets list-secrets
lyxaws secrets get-secret-value --secret prod/mysql/password
lyxaws secrets create-secret --name prod/api-key --value "s3cret"
```

**Ausgabe-Formatter** (`lyxaws/output.lyu`):
- `--output json` → Rohdaten als JSON (Standard)
- `--output table` → ASCII-Tabelle (wie AWS CLI)
- `--output text` → Tab-getrennte Werte

**Dateien:**
- `bin/lyxaws.lyx`
- `bin/lyxaws/*.lyu`

**Akzeptanzkriterien:**
- `lyxaws configure` schreibt korrekte INI-Dateien
- `lyxaws s3 ls` gibt alle Buckets aus
- `lyxaws s3 cp file.txt s3://bucket/` → Datei in S3, Return-Code 0
- `lyxaws ec2 describe-instances --output table` gibt formatierte Tabelle aus
- `lyxaws iam get-caller-identity` gibt Account + ARN aus
- `lyxaws lambda invoke --function Echo --payload '{"msg":"hallo"}' out.json`
  → `out.json` enthält Antwort
- `lyxaws logs tail /aws/lambda/MyFunc` gibt letzte 10 Log-Events aus

---

### WP-AWS-15: Demos & Integrationstests ⬜

**Demo 1 — Credential-Chain** (`demo_aws_creds.lyx`):
```lyx
// Alle Quellen testen: Static, Env, File, EC2-Meta
// STSGetCallerIdentity mit jeder Quelle
// Profile aus ~/.aws/credentials auflisten
```

**Demo 2 — S3 + Lambda Pipeline** (`demo_aws_pipeline.lyx`):
```lyx
// S3: Datei hochladen
// Lambda: Funktion aufrufen, die S3-Datei verarbeitet
// S3: Ergebnis-Datei herunterladen + ausgeben
```

**Demo 3 — DynamoDB Session-Store** (`demo_aws_ddb_session.lyx`):
```lyx
// Tabelle "sessions" anlegen (PK: session_id)
// 100 Sessions einfügen (DDBPutItem)
// Session via DDBGetItem lesen
// Abgelaufene Sessions via DDBScan + DDBDeleteItem aufräumen
```

**Demo 4 — SQS Worker** (`demo_aws_sqs_worker.lyx`):
```lyx
// Producer: 10 Nachrichten in Queue senden
// Consumer: Empfangen, verarbeiten, löschen (in Schleife)
// Visibility-Timeout demonstrieren
```

**Demo 5 — CloudWatch Monitoring** (`demo_aws_monitoring.lyx`):
```lyx
// Custom Metrik "AppRequests" mit Count pushen
// Log-Gruppe erstellen + Events pushen
// Alarm konfigurieren (AppRequests > 100)
```

**Demo 6 — Secrets im echten Einsatz** (`demo_aws_secrets.lyx`):
```lyx
// Datenbankpasswort in Secrets Manager speichern
// MySQL-Verbindung nur mit geladenen Secrets aufbauen
// Kein Passwort im Quellcode
```

**Demo 7 — lyxaws End-to-End** (`demo_aws_cli.sh`):
```bash
lyxaws configure
lyxaws s3 mb s3://test-bucket
lyxaws s3 cp README.md s3://test-bucket/
lyxaws s3 ls s3://test-bucket/
lyxaws ec2 describe-instances --output table
lyxaws s3 rb s3://test-bucket
```

---

## Abhängigkeiten

| Abhängigkeit | Quelle | Notiz |
|-------------|--------|-------|
| `std/crypto/sha256` | Lyx stdlib (neu, WP-AWS-01) | Basis für SigV4 |
| `std/cloud/aws/sigv4` | Lyx stdlib (WP-AWS-01) | Geteilt von allen Services |
| `std/cloud/aws/transport` | Lyx stdlib (WP-AWS-03) | Geteilt von allen Services |
| `std/net/https` | Lyx stdlib | TLSInit, TLSConnect, TLSWrite, TLSRead |
| `std/json` | Lyx stdlib | JSON-Protokoll + DynamoDB |
| `std/base64` | Lyx stdlib | SigV4, DynamoDB Blob |
| `std/io` | Lyx stdlib | Datei-I/O, sys_getenv |
| AWS-Account | extern | IAM-Benutzer mit entsprechenden Policies |

---

## Empfohlene Implementierungsreihenfolge

```
1. WP-AWS-01  (SHA-256 + SigV4)          ← Alles hängt davon ab
2. WP-AWS-02  (Credential Chain)         ← Alles hängt davon ab
3. WP-AWS-03  (Transport + Retry)        ← Alles hängt davon ab
4. WP-AWS-04  (Endpoint Resolution)      ← Alles hängt davon ab
5. WP-AWS-05  (XML + Protokoll-Helpers)  ← EC2 + STS hängen davon ab
6. WP-AWS-08  (IAM + STS)               ← AssumeRole für andere Services
7. WP-AWS-06  (S3)                       ← Größter Einzelclient, gut getestet
8. WP-AWS-09  (DynamoDB)                 ← JSON-Protokoll-Showcase
9. WP-AWS-07  (EC2)                      ← Query-Protokoll-Showcase
10. WP-AWS-10 (Lambda)                   ← REST-JSON-Showcase
11. WP-AWS-11 (SQS + SNS)               ← Messaging-Layer
12. WP-AWS-12 (CloudWatch)              ← Observability
13. WP-AWS-13 (Secrets Manager + SSM)   ← Security-Layer
14. WP-AWS-14 (lyxaws CLI)              ← Baut auf allem auf
15. WP-AWS-15 (Demos)                   ← End-to-End-Tests
```

---

## Offene Fragen

- **LocalStack:** Alle Services können gegen `http://localhost:4566` getestet
  werden (kostenloses AWS-Emulator-Tool). `AWSServiceConfigLocalStack()` +
  `AWS_ENDPOINT_URL=http://localhost:4566` als Umgebungsvariable sinnvoll?
- **Paginierung automatisch:** boto3 hat `get_paginator()` — soll `lyxaws` 
  automatisch alle Seiten zusammenführen (z. B. `ec2 describe-instances` immer
  vollständig) oder explizites `--page-token` anbieten?
- **Output-Format `--output table`:** Benötigt Spaltenbreiten-Berechnung — ist
  eine einfache Tab-getrennte Ausgabe (`--output text`) als erster Schritt
  ausreichend?
- **Weitere Services:** Welche Services nach dem MVP?
  - **RDS:** Datenbankinstanzen starten/stoppen (API-Calls, keine SQL-Verbindung)
  - **ECS/EKS:** Container-Orchestrierung
  - **CloudFormation:** Stack-Deployment
  - **Bedrock:** Claude/LLM-API-Calls (naheliegend für Lyx!)
  - **Cognito:** User-Pool-Management
- **AWS Bedrock als Priorität?** Da Lyx bereits ML-Fähigkeiten hat (`std/ml`),
  wäre ein `std/cloud/bedrock`-Client (Claude, Titan, Llama) ein naheliegender
  nächster Schritt nach dem SDK-Core.
