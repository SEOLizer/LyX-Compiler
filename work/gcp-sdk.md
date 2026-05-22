# Fahrplan: Google Cloud Platform SDK (`std/cloud/gcp/`)

## Vision

Ein natives Lyx-SDK für die Google Cloud Platform – ohne externe Abhängigkeiten außer OpenSSL (bereits über `std/net/tls.lyu` verfügbar). Authentifizierung via Service Account JWT/OAuth 2.0, alle wichtigen GCP-Services als typsichere Lyx-API, plus eine `lyxgcloud`-CLI.

```lyx
import std/cloud/gcp/storage
import std/cloud/gcp/pubsub
import std/cloud/gcp/firestore

fn main() {
    # Credentials aus Service-Account-JSON-Datei
    let creds = GCPCredentialsFromFile("service-account.json")
    let project = "my-project-123"

    # Cloud Storage: Datei hochladen
    let gcs = GCSConnect(creds, project)
    GCSUpload(gcs, "my-bucket", "hello.txt", "Hello from Lyx!", 15)
    let data = GCSDownload(gcs, "my-bucket", "hello.txt")
    println(data.body)

    # Pub/Sub: Nachricht veröffentlichen
    let ps = PubSubConnect(creds, project)
    PubSubPublish(ps, "my-topic", "event payload", 13)

    # Firestore: Dokument schreiben und lesen
    let fs = FirestoreConnect(creds, project)
    let doc = FSDocNew()
    FSDocSetString(doc, "name", "Lyx")
    FSDocSetInt(doc, "version", 1)
    FSCreate(fs, "languages", "lyx", doc)
    let result = FSGet(fs, "languages", "lyx")
    println(FSDocGetString(result, "name"))
}
```

---

## Architektur

```
┌─────────────────────────────────────────────────────────────┐
│                     Lyx-Anwendung                           │
└────────┬──────────┬──────────┬──────────┬───────────────────┘
         │          │          │          │
    ┌────▼───┐ ┌────▼───┐ ┌───▼────┐ ┌───▼────────┐
    │  GCS   │ │Compute │ │Firest. │ │  Pub/Sub   │  ...
    │Storage │ │Engine  │ │        │ │            │
    └────┬───┘ └────┬───┘ └───┬────┘ └───┬────────┘
         └──────────┴──────────┴──────────┘
                          │
              ┌───────────▼────────────┐
              │  GCP REST/JSON Transport│
              │  (std/cloud/gcp/core)   │
              │  Bearer <access_token>  │
              └───────────┬────────────┘
                          │
              ┌───────────▼────────────┐
              │   OAuth 2.0 Token Mgr  │
              │  (WP-GCP-03/04)        │
              │  auto-refresh, cache   │
              └───────────┬────────────┘
                          │
              ┌───────────▼────────────┐
              │   JWT Builder (RS256)   │
              │  (WP-GCP-02)            │
              │  base64url + signature  │
              └───────────┬────────────┘
                          │
              ┌───────────▼────────────┐
              │  RSA-PKCS1v15 + BigNum  │
              │  (std/crypto/rsa.lyu)   │
              │  + PEM Parser           │
              └───────────┬────────────┘
                          │
              ┌───────────▼────────────┐
              │   std/net/tls.lyu       │
              │   (OpenSSL intern)      │
              └────────────────────────┘

  Credential Chain (ADC – Application Default Credentials):
  1. GOOGLE_APPLICATION_CREDENTIALS env var
  2. ~/.config/gcloud/application_default_credentials.json
  3. GCE/GKE/Cloud Run Metadata Server (169.254.169.254)
  4. gcloud auth application-default login (refresh token)
```

---

## GCP-Authentifizierung: Referenz

### Service Account JWT Flow

```
Service Account JSON Key
  ├── client_email   → JWT iss + sub
  ├── private_key    → RSA-2048 PEM → RS256-Signatur
  └── token_uri      → https://oauth2.googleapis.com/token

JWT Header:  {"alg":"RS256","typ":"JWT"}
JWT Payload: {
  "iss": "svc@project.iam.gserviceaccount.com",
  "sub": "svc@project.iam.gserviceaccount.com",
  "aud": "https://oauth2.googleapis.com/token",
  "iat": <unix_now>,
  "exp": <unix_now + 3600>,
  "scope": "https://www.googleapis.com/auth/cloud-platform"
}
JWT Signatur: RS256( base64url(header) + "." + base64url(payload) )

Token Exchange POST:
  URL:  https://oauth2.googleapis.com/token
  Body: grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer
        &assertion=<signed_jwt>
  Resp: { "access_token": "ya29...", "expires_in": 3599, "token_type": "Bearer" }
```

### OAuth 2.0 Refresh Token Flow (ADC)

```
~/.config/gcloud/application_default_credentials.json:
  { "type": "authorized_user",
    "client_id": "...",
    "client_secret": "...",
    "refresh_token": "1//..." }

POST https://oauth2.googleapis.com/token
  grant_type=refresh_token
  &client_id=...&client_secret=...&refresh_token=...
```

### GCE Metadata Server

```
GET http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token
Headers: Metadata-Flavor: Google
Response: { "access_token": "ya29...", "expires_in": 3599, "token_type": "Bearer" }
```

### RSA-PKCS1v15 Signatur (JWT RS256)

```
PEM PRIVATE KEY → DER → RSA-Schlüssel (n, e, d, p, q, dp, dq, qi)

Signatur:
  1. hash = SHA256(message)
  2. padded = PKCS1v15_pad(hash, key_size_bytes)   # 0x00 0x01 0xFF..FF 0x00 DigestInfo hash
  3. sig = BigNum_ModExp(padded, d, n)             # RSA private key operation
  4. output = BigEndian_bytes(sig, key_size_bytes)

DigestInfo für SHA-256 (DER):
  30 31 30 0d 06 09 60 86 48 01 65 03 04 02 01 05 00 04 20 <32-byte-hash>
```

---

## GCP REST API: Allgemeines Muster

```
Basis-URL:    https://<service>.googleapis.com/<version>/<resource>
Auth-Header:  Authorization: Bearer <access_token>
Content-Type: application/json
```

| Service          | Basis-URL                                           | Version |
|------------------|-----------------------------------------------------|---------|
| Cloud Storage    | https://storage.googleapis.com/storage              | v1      |
| Compute Engine   | https://compute.googleapis.com/compute              | v1      |
| Firestore        | https://firestore.googleapis.com/v1/projects/       | v1      |
| Pub/Sub          | https://pubsub.googleapis.com/v1/projects/          | v1      |
| Cloud Functions  | https://cloudfunctions.googleapis.com/v2/projects/  | v2      |
| Cloud Run        | https://run.googleapis.com/v2/projects/             | v2      |
| Cloud Logging    | https://logging.googleapis.com/v2/                  | v2      |
| Cloud Monitoring | https://monitoring.googleapis.com/v3/projects/      | v3      |
| Secret Manager   | https://secretmanager.googleapis.com/v1/projects/   | v1      |
| IAM              | https://iam.googleapis.com/v1/                      | v1      |

---

## Phasen

| Phase | WPs           | Inhalt                                  | Status |
|-------|---------------|-----------------------------------------|--------|
| 1     | GCP-01–02     | RSA/BigNum, JWT-Builder                 | ⬜     |
| 2     | GCP-03–05     | OAuth 2.0, Credential Chain, Transport  | ⬜     |
| 3     | GCP-06–07     | Cloud Storage, Compute Engine           | ⬜     |
| 4     | GCP-08–09     | Firestore, Pub/Sub                      | ⬜     |
| 5     | GCP-10–11     | Functions/Run, Logging/Monitoring       | ⬜     |
| 6     | GCP-12–13     | Secret Manager/IAM, lyxgcloud CLI       | ⬜     |
| 7     | GCP-14        | Demos & Integrationstests               | ⬜     |

---

## Work Packages

---

### WP-GCP-01 — RSA-PKCS1v15 + BigNum + PEM-Parser ⬜

**Ziel:** `std/crypto/rsa.lyu` mit BigNum-Arithmetik und RSA-PKCS1v15-Signatur. Voraussetzung für JWT RS256.

**Zu implementieren:**

BigNum (Multipräzisions-Arithmetik, intern als `u64[]`):
```lyx
# Intern: dynamisches Array von u64-Limbs (little-endian)
struct BigNum {
    limbs: ptr      # u64[]
    len:   i32      # Anzahl aktiver Limbs
    cap:   i32      # Kapazität
}

fn BigNumNew() -> BigNum
fn BigNumFree(n: BigNum)
fn BigNumFromBytes(data: ptr, size: i32) -> BigNum    # big-endian bytes
fn BigNumToBytes(n: BigNum, out: ptr, size: i32)      # big-endian, left-padded
fn BigNumCopy(n: BigNum) -> BigNum
fn BigNumCmp(a: BigNum, b: BigNum) -> i32             # -1/0/1
fn BigNumAdd(a: BigNum, b: BigNum) -> BigNum
fn BigNumSub(a: BigNum, b: BigNum) -> BigNum
fn BigNumMul(a: BigNum, b: BigNum) -> BigNum
fn BigNumDiv(a: BigNum, b: BigNum) -> BigNum
fn BigNumMod(a: BigNum, b: BigNum) -> BigNum
fn BigNumModExp(base: BigNum, exp: BigNum, mod: BigNum) -> BigNum  # Montgomery/square-and-multiply
fn BigNumShiftLeft(n: BigNum, bits: i32) -> BigNum
fn BigNumShiftRight(n: BigNum, bits: i32) -> BigNum
fn BigNumIsZero(n: BigNum) -> bool
fn BigNumBitLen(n: BigNum) -> i32
```

RSA-Schlüsselstruktur:
```lyx
struct RSAKey {
    n:    BigNum    # Modulus
    e:    BigNum    # Public Exponent (meist 65537)
    d:    BigNum    # Private Exponent
    p:    BigNum    # Primfaktor p
    q:    BigNum    # Primfaktor q
    dp:   BigNum    # d mod (p-1)
    dq:   BigNum    # d mod (q-1)
    qi:   BigNum    # q^(-1) mod p
    bits: i32       # Schlüsselgröße (2048, 4096)
}

fn RSAKeyFree(key: RSAKey)
fn RSAKeyFromDER(der: ptr, size: i32) -> RSAKey       # PKCS#8 / PKCS#1
fn RSASign(key: RSAKey, hash: ptr, hashLen: i32, sig: ptr) -> i32   # PKCS1v15
fn RSAVerify(key: RSAKey, hash: ptr, hashLen: i32, sig: ptr, sigLen: i32) -> bool
```

PEM-Parser:
```lyx
fn PEMDecode(pem: ptr, pemLen: i32, outDer: ptr, outLen: ptr) -> i32
# Unterstützt: PRIVATE KEY, RSA PRIVATE KEY, CERTIFICATE
# Findet -----BEGIN ...-----, base64-dekodiert, gibt DER zurück
```

DER-Parser für PKCS#8 / PKCS#1:
```lyx
fn DERParseRSAPrivateKey(der: ptr, size: i32) -> RSAKey
# PKCS#1: SEQUENCE { version, n, e, d, p, q, dp, dq, qi }
# PKCS#8: SEQUENCE { version, AlgorithmIdentifier, OCTET STRING { PKCS#1 } }
fn DERReadTag(der: ptr, pos: ptr) -> i32
fn DERReadLength(der: ptr, pos: ptr) -> i32
fn DERReadInteger(der: ptr, pos: ptr, outLen: ptr) -> ptr  # → BigNum-Bytes
```

PKCS1v15-Padding (für SHA-256):
```lyx
# DigestInfo-Präfix für SHA-256:
# 30 31 30 0d 06 09 60 86 48 01 65 03 04 02 01 05 00 04 20
let SHA256_DIGEST_INFO = [0x30,0x31,0x30,0x0d,0x06,0x09,0x60,0x86,
                          0x48,0x01,0x65,0x03,0x04,0x02,0x01,0x05,
                          0x00,0x04,0x20]  # 19 Bytes
fn PKCS1v15Pad(hash: ptr, hashLen: i32, out: ptr, keyBytes: i32)
# 0x00 0x01 [0xFF...] 0x00 [DigestInfo] [hash]
```

**Dateien:**
- `std/crypto/rsa.lyu` (neu) — BigNum + RSAKey + RSASign + PEM/DER-Parser
- `std/crypto/sha256.lyu` (neu, falls nicht durch WP-AWS-01 erstellt) — SHA-256

**Akzeptanzkriterien:**
- `BigNumModExp` korrekt für bekannte RSA-2048-Testvektoren
- `PEMDecode` liest typisches GCP-Service-Account-Private-Key-PEM
- `RSASign` erzeugt PKCS1v15-Signatur, die `openssl dgst -verify` akzeptiert
- Signatur-Länge = `key.bits / 8` (256 Bytes für RSA-2048)

---

### WP-GCP-02 — JWT-Builder (RS256) ⬜

**Ziel:** `std/cloud/gcp/jwt.lyu` — Baut und signiert JWTs für den GCP Service Account Flow.

**Zu implementieren:**

```lyx
struct JWT {
    header:    ptr     # base64url-kodierter Header
    payload:   ptr     # base64url-kodiertes Payload
    signature: ptr     # base64url-kodierte Signatur
    token:     ptr     # vollständiger Token: header.payload.sig
    tokenLen:  i32
}

fn JWTBuild(key: RSAKey, payload: ptr, payloadLen: i32) -> JWT
fn JWTFree(jwt: JWT)

# Interner Aufbau:
fn jwtBuildHeader() -> ptr
# → base64url({"alg":"RS256","typ":"JWT"})

fn jwtBuildPayload(
    iss: ptr, sub: ptr, aud: ptr,
    iat: i64, exp: i64,
    scope: ptr
) -> ptr
# → base64url({"iss":"...","sub":"...","aud":"...","iat":...,"exp":...,"scope":"..."})

fn jwtSign(key: RSAKey, message: ptr, messageLen: i32) -> ptr
# 1. SHA256(message) → 32-Byte-Hash
# 2. RSASign(key, hash, 32, sigBuf)
# 3. base64url(sigBuf, keyBytes)
# → base64url-kodierte Signatur

fn jwtCombine(header: ptr, payload: ptr, sig: ptr) -> ptr
# → header + "." + payload + "." + sig

# Hilfsfunktionen:
fn base64urlEncode(src: ptr, srcLen: i32, dst: ptr) -> i32
fn base64urlDecode(src: ptr, srcLen: i32, dst: ptr) -> i32
# base64url = base64 mit + → -, / → _, kein Padding (=)
```

GCP-spezifischer JWT-Builder:
```lyx
struct GCPServiceAccount {
    projectId:   ptr
    clientEmail: ptr
    privateKey:  RSAKey
    tokenUri:    ptr    # https://oauth2.googleapis.com/token
}

fn GCPServiceAccountFromJSON(json: ptr, jsonLen: i32) -> GCPServiceAccount
# Parst: project_id, client_email, private_key, token_uri

fn GCPBuildJWT(sa: GCPServiceAccount, scope: ptr, now: i64) -> JWT
# Füllt iss/sub/aud/iat/exp/scope und signiert mit RS256
```

**Dateien:**
- `std/cloud/gcp/jwt.lyu` (neu)
- `std/cloud/gcp/jwt.lyx` (Testbinär)

**Akzeptanzkriterien:**
- Erzeugtes JWT hat 3 Teile (`.`-getrennt), Header dekodiert zu `{"alg":"RS256","typ":"JWT"}`
- Payload enthält korrekte `iat`/`exp`-Timestamps (1 Stunde Differenz)
- `jwt.io`-Debugger oder `python jwt.decode()` validiert Signatur mit Public Key

---

### WP-GCP-03 — OAuth 2.0 Token-Manager ⬜

**Ziel:** `std/cloud/gcp/oauth.lyu` — Token-Austausch mit googleapis.com, automatischer Refresh, Token-Cache.

**Zu implementieren:**

```lyx
struct GCPToken {
    accessToken: ptr
    tokenLen:    i32
    expiresAt:   i64    # Unix-Timestamp (UTC)
    tokenType:   ptr    # "Bearer"
}

fn GCPTokenFree(t: GCPToken)
fn GCPTokenIsExpired(t: GCPToken) -> bool
# true wenn expiresAt - now() < 60 (60s Puffer)

# Service Account Flow:
fn GCPTokenFromServiceAccount(sa: GCPServiceAccount, scope: ptr) -> GCPToken
# 1. GCPBuildJWT(sa, scope, now)
# 2. POST https://oauth2.googleapis.com/token
#    Content-Type: application/x-www-form-urlencoded
#    Body: grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=<jwt>
# 3. Parst JSON-Antwort: access_token, expires_in

# Refresh Token Flow (ADC):
struct GCPRefreshCreds {
    clientId:     ptr
    clientSecret: ptr
    refreshToken: ptr
}

fn GCPTokenFromRefresh(creds: GCPRefreshCreds) -> GCPToken
# POST https://oauth2.googleapis.com/token
# Body: grant_type=refresh_token&client_id=...&client_secret=...&refresh_token=...

# GCE Metadata Flow:
fn GCPTokenFromMetadata() -> GCPToken
# GET http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token
# Header: Metadata-Flavor: Google
# Reiner HTTP (kein TLS), Port 80

# Token-Cache (Thread-safe via Mutex):
struct GCPTokenCache {
    token:     GCPToken
    mu:        i32       # Spinlock
    refreshFn: ptr       # Funktionszeiger → GCPToken
}

fn GCPTokenCacheNew(refreshFn: ptr) -> GCPTokenCache
fn GCPTokenCacheGet(cache: GCPTokenCache) -> ptr  # → access_token (auto-refresh)
fn GCPTokenCacheFree(cache: GCPTokenCache)
```

JSON-Antwort-Parser (minimal für Token-Antworten):
```lyx
fn parseTokenResponse(json: ptr, jsonLen: i32, token: GCPToken)
# Liest: access_token, expires_in (→ expiresAt = now + expires_in)
```

**Dateien:**
- `std/cloud/gcp/oauth.lyu` (neu)

**Akzeptanzkriterien:**
- Token-Austausch mit echtem GCP-Projekt liefert `ya29.`-Token
- `GCPTokenIsExpired` erkennt abgelaufene Tokens korrekt
- `GCPTokenCacheGet` refresht automatisch bei Ablauf (< 60s Puffer)
- Metadata-Endpunkt funktioniert auf GCE-Instanz (HTTP, kein TLS)

---

### WP-GCP-04 — Credential Chain (ADC) ⬜

**Ziel:** `std/cloud/gcp/credentials.lyu` — Application Default Credentials, kompatibel mit dem GCP-Standard.

**Zu implementieren:**

```lyx
# Credential-Typen
const GCP_CREDS_SERVICE_ACCOUNT = 1
const GCP_CREDS_REFRESH_TOKEN   = 2
const GCP_CREDS_METADATA        = 3
const GCP_CREDS_IMPERSONATED    = 4

struct GCPCredentials {
    credType:  i32
    project:   ptr
    quota:     ptr    # quota_project_id
    cache:     GCPTokenCache
}

fn GCPCredentialsFromFile(path: ptr) -> GCPCredentials
# Liest JSON-Datei, erkennt "type": "service_account" oder "authorized_user"

fn GCPCredentialsFromEnv() -> GCPCredentials
# GOOGLE_APPLICATION_CREDENTIALS → GCPCredentialsFromFile(path)

fn GCPCredentialsFromADC() -> GCPCredentials
# ~/.config/gcloud/application_default_credentials.json

fn GCPCredentialsFromMetadata() -> GCPCredentials
# GCE/GKE/Cloud Run/Cloud Functions: Metadata Server

fn GCPCredentialsDefault(scope: ptr) -> GCPCredentials
# Credential Chain (in Reihenfolge):
# 1. GOOGLE_APPLICATION_CREDENTIALS env var
# 2. ~/.config/gcloud/application_default_credentials.json
# 3. GCE Metadata Server (check via HTTP mit Timeout)
# → Fehler wenn nichts gefunden

fn GCPCredentialsFree(creds: GCPCredentials)
fn GCPGetToken(creds: GCPCredentials) -> ptr   # → access_token

# Projekt-ID-Auflösung:
fn GCPProjectFromEnv() -> ptr                  # GCLOUD_PROJECT / GOOGLE_CLOUD_PROJECT
fn GCPProjectFromMetadata() -> ptr             # Metadata Server: project/project-id
fn GCPProjectFromCreds(creds: GCPCredentials) -> ptr

# JSON-Parser für ADC-Datei:
fn parseServiceAccountJSON(json: ptr, len: i32) -> GCPServiceAccount
fn parseAuthorizedUserJSON(json: ptr, len: i32) -> GCPRefreshCreds
```

GCE-Erkennung:
```lyx
fn GCPIsRunningOnGCE() -> bool
# HTTP GET http://metadata.google.internal/ mit 1s Timeout
# Prüft: metadata-flavor: Google Header
# Gibt false zurück wenn Verbindung abgelehnt/Timeout
```

**Dateien:**
- `std/cloud/gcp/credentials.lyu` (neu)
- `std/cloud/gcp/core.lyu` (neu) — Re-exportiert credentials + oauth + jwt

**Akzeptanzkriterien:**
- `GCPCredentialsFromFile("service-account.json")` funktioniert mit echtem GCP-Key
- ADC-Datei aus `gcloud auth application-default login` wird korrekt gelesen
- Credential Chain stoppt bei erstem Treffer, gibt klare Fehlermeldung wenn leer
- `GCPIsRunningOnGCE()` gibt false außerhalb GCE, true auf GCE

---

### WP-GCP-05 — GCP REST/JSON Transport + Retry ⬜

**Ziel:** `std/cloud/gcp/transport.lyu` — HTTP-Client mit Bearer-Auth, JSON-Handling, Exponential Backoff.

**Zu implementieren:**

```lyx
struct GCPClient {
    creds:      GCPCredentials
    project:    ptr
    baseURL:    ptr
    timeout:    i32    # Millisekunden (default: 30000)
    maxRetries: i32    # default: 3
}

fn GCPClientNew(creds: GCPCredentials, project: ptr, baseURL: ptr) -> GCPClient
fn GCPClientFree(c: GCPClient)

struct GCPResponse {
    statusCode:  i32
    body:        ptr
    bodyLen:     i32
    contentType: ptr
}

fn GCPResponseFree(r: GCPResponse)

# HTTP-Methoden mit Bearer-Auth:
fn GCPGet(c: GCPClient, path: ptr) -> GCPResponse
fn GCPPost(c: GCPClient, path: ptr, body: ptr, bodyLen: i32) -> GCPResponse
fn GCPPut(c: GCPClient, path: ptr, body: ptr, bodyLen: i32) -> GCPResponse
fn GCPPatch(c: GCPClient, path: ptr, body: ptr, bodyLen: i32) -> GCPResponse
fn GCPDelete(c: GCPClient, path: ptr) -> GCPResponse

# Intern: Request-Bau
fn gcpBuildRequest(c: GCPClient, method: ptr, path: ptr, body: ptr, bodyLen: i32) -> HTTPRequest
# Setzt: Authorization: Bearer <token>
#        Content-Type: application/json
#        User-Agent: lyxgcloud/1.0
fn gcpDoRequest(c: GCPClient, req: HTTPRequest) -> GCPResponse

# Retry-Logik:
fn gcpShouldRetry(statusCode: i32) -> bool
# true für: 429, 500, 502, 503, 504
fn gcpRetryDelay(attempt: i32) -> i32
# 100ms * 2^attempt + Jitter (0..100ms)
# attempt 0→100ms, 1→200ms, 2→400ms, 3→800ms

# Fehlertypen:
const GCP_ERR_OK            = 0
const GCP_ERR_AUTH          = 401
const GCP_ERR_FORBIDDEN     = 403
const GCP_ERR_NOT_FOUND     = 404
const GCP_ERR_CONFLICT      = 409
const GCP_ERR_RATE_LIMIT    = 429
const GCP_ERR_SERVER        = 500

struct GCPError {
    code:    i32
    message: ptr
    status:  ptr    # GCP-Fehlercode z.B. "NOT_FOUND"
    details: ptr    # JSON-Array
}

fn GCPParseError(body: ptr, bodyLen: i32) -> GCPError
# Parst: {"error":{"code":404,"message":"...","status":"NOT_FOUND"}}
fn GCPErrorFree(e: GCPError)

# URL-Hilfsfunktionen:
fn gcpURLBuild(base: ptr, path: ptr, queryParams: ptr) -> ptr
fn gcpURLEncode(s: ptr, out: ptr) -> i32
fn gcpQueryParam(key: ptr, val: ptr) -> ptr   # "key=urlenc(val)"
fn gcpQueryJoin(params: ptr, count: i32) -> ptr  # "p1&p2&p3"
```

**Dateien:**
- `std/cloud/gcp/transport.lyu` (neu)

**Akzeptanzkriterien:**
- GET/POST/PUT/PATCH/DELETE mit korrektem `Authorization: Bearer`-Header
- Retry bei 429/5xx mit Exponential Backoff
- Token-Refresh bei 401 (einmalig, danach Fehler)
- `GCPParseError` extrahiert GCP-Fehlercodes korrekt

---

### WP-GCP-06 — Cloud Storage (GCS) ⬜

**Ziel:** `std/cloud/gcp/storage.lyu` — Google Cloud Storage, vollständige Objekt- und Bucket-Verwaltung.

**Zu implementieren:**

```lyx
struct GCSConn {
    client:  GCPClient
    project: ptr
}

fn GCSConnect(creds: GCPCredentials, project: ptr) -> GCSConn
fn GCSDisconnect(c: GCSConn)

# Bucket-Verwaltung:
fn GCSBucketCreate(c: GCSConn, bucket: ptr, location: ptr) -> i32
# POST /b?project=... Body: {"name":"bucket","location":"EU"}
fn GCSBucketDelete(c: GCSConn, bucket: ptr) -> i32
fn GCSBucketExists(c: GCSConn, bucket: ptr) -> bool
fn GCSBucketList(c: GCSConn) -> ptr    # JSON-Array von Bucket-Namen
fn GCSBucketGetMeta(c: GCSConn, bucket: ptr) -> ptr  # JSON

# Objekt-Upload:
fn GCSUpload(c: GCSConn, bucket: ptr, object: ptr, data: ptr, dataLen: i32) -> i32
# POST /upload/storage/v1/b/{bucket}/o?uploadType=media&name={object}
# Header: Content-Type: application/octet-stream
fn GCSUploadJSON(c: GCSConn, bucket: ptr, object: ptr, json: ptr, jsonLen: i32) -> i32
# Content-Type: application/json

# Multipart-Upload (Metadaten + Daten):
fn GCSUploadMultipart(c: GCSConn, bucket: ptr, object: ptr,
                      meta: ptr, data: ptr, dataLen: i32,
                      contentType: ptr) -> i32
# uploadType=multipart, multipart/related Body

# Resumable Upload (für > 5 MB):
struct GCSResumable {
    sessionURI: ptr
    offset:     i64
    totalSize:  i64
}
fn GCSResumableStart(c: GCSConn, bucket: ptr, object: ptr, totalSize: i64, contentType: ptr) -> GCSResumable
fn GCSResumableUpload(r: GCSResumable, data: ptr, dataLen: i32, isLast: bool) -> i32
fn GCSResumableFree(r: GCSResumable)

# Objekt-Download:
fn GCSDownload(c: GCSConn, bucket: ptr, object: ptr) -> GCPResponse
# GET /storage/v1/b/{bucket}/o/{object}?alt=media
fn GCSDownloadRange(c: GCSConn, bucket: ptr, object: ptr, start: i64, end: i64) -> GCPResponse
# Header: Range: bytes=start-end

# Objekt-Verwaltung:
fn GCSDelete(c: GCSConn, bucket: ptr, object: ptr) -> i32
fn GCSExists(c: GCSConn, bucket: ptr, object: ptr) -> bool
fn GCSGetMeta(c: GCSConn, bucket: ptr, object: ptr) -> ptr     # JSON-Metadaten
fn GCSCopy(c: GCSConn, srcBucket: ptr, srcObj: ptr, dstBucket: ptr, dstObj: ptr) -> i32
fn GCSMove(c: GCSConn, srcBucket: ptr, srcObj: ptr, dstBucket: ptr, dstObj: ptr) -> i32

# Listing:
struct GCSObject {
    name:        ptr
    size:        i64
    contentType: ptr
    updated:     ptr
    etag:        ptr
}

fn GCSList(c: GCSConn, bucket: ptr, prefix: ptr, pageSize: i32) -> ptr  # → GCSObject[]
fn GCSListPage(c: GCSConn, bucket: ptr, prefix: ptr, pageToken: ptr, pageSize: i32) -> ptr

# Signed URLs (V4 Signing):
fn GCSSignedURL(c: GCSConn, bucket: ptr, object: ptr, method: ptr, expirySeconds: i32) -> ptr
# Ähnlich S3 Presigned URLs, aber mit GCP-Signatur

# ACL / IAM:
fn GCSSetPublic(c: GCSConn, bucket: ptr, object: ptr) -> i32
# Setzt allUsers: READER via IAM
fn GCSSetIAMPolicy(c: GCSConn, bucket: ptr, policy: ptr) -> i32
```

**Dateien:**
- `std/cloud/gcp/storage.lyu` (neu)

**Akzeptanzkriterien:**
- Upload/Download von Binärdaten (inkl. UTF-8 und Null-Bytes)
- Resumable Upload überträgt 100-MB-Datei in Chunks
- `GCSList` paginiert korrekt bei > 1000 Objekten
- Signed URL ist ohne Credentials 1 Stunde lang gültig

---

### WP-GCP-07 — Compute Engine (GCE) ⬜

**Ziel:** `std/cloud/gcp/compute.lyu` — VM-Instanzen erstellen, verwalten, auflisten.

**Zu implementieren:**

```lyx
struct GCEConn {
    client:  GCPClient
    project: ptr
    zone:    ptr    # default: "europe-west1-b"
}

fn GCEConnect(creds: GCPCredentials, project: ptr, zone: ptr) -> GCEConn
fn GCEDisconnect(c: GCEConn)

# VM-Instanzen:
struct GCEInstance {
    name:        ptr
    machineType: ptr    # "n1-standard-1"
    status:      ptr    # "RUNNING", "STOPPED", ...
    zone:        ptr
    internalIP:  ptr
    externalIP:  ptr
    disks:       ptr    # JSON-Array
    tags:        ptr    # JSON-Array
    created:     ptr
}

fn GCEInstanceCreate(c: GCEConn, name: ptr, machineType: ptr,
                     image: ptr, diskSizeGB: i32) -> GCEOperation
# POST /compute/v1/projects/{proj}/zones/{zone}/instances
# Body: {"name":"...","machineType":"zones/.../machineTypes/n1-standard-1",
#        "disks":[{"initializeParams":{"sourceImage":"..."}}],
#        "networkInterfaces":[{"network":"global/networks/default"}]}

fn GCEInstanceDelete(c: GCEConn, name: ptr) -> GCEOperation
fn GCEInstanceStart(c: GCEConn, name: ptr) -> GCEOperation
fn GCEInstanceStop(c: GCEConn, name: ptr) -> GCEOperation
fn GCEInstanceGet(c: GCEConn, name: ptr) -> GCEInstance
fn GCEInstanceList(c: GCEConn) -> ptr   # → GCEInstance[]
fn GCEInstanceFree(inst: GCEInstance)

# Asynchrone Operationen (LRO – Long Running Operations):
struct GCEOperation {
    name:       ptr
    status:     ptr    # "RUNNING", "DONE"
    targetLink: ptr
    error:      ptr
    progress:   i32
}

fn GCEOperationWait(c: GCEConn, op: GCEOperation) -> GCEOperation
# Polling: GET /compute/v1/projects/{proj}/zones/{zone}/operations/{op}
# bis status == "DONE", max 60s mit 2s Intervall
fn GCEOperationFree(op: GCEOperation)

# Disk-Verwaltung:
fn GCEDiskCreate(c: GCEConn, name: ptr, sizeGB: i32, diskType: ptr) -> GCEOperation
fn GCEDiskDelete(c: GCEConn, name: ptr) -> GCEOperation
fn GCEDiskList(c: GCEConn) -> ptr

# Netzwerk:
fn GCEFirewallRuleCreate(c: GCEConn, name: ptr, ports: ptr, protocol: ptr) -> GCEOperation
fn GCEFirewallRuleDelete(c: GCEConn, name: ptr) -> GCEOperation
fn GCEFirewallRuleList(c: GCEConn) -> ptr

# Maschinentypen und Regionen:
fn GCEMachineTypeList(c: GCEConn) -> ptr
fn GCERegionList(c: GCEConn) -> ptr
fn GCEZoneList(c: GCEConn) -> ptr
```

**Dateien:**
- `std/cloud/gcp/compute.lyu` (neu)

**Akzeptanzkriterien:**
- `GCEInstanceCreate` startet tatsächlich eine VM (n1-standard-1, Debian-Image)
- `GCEOperationWait` blockiert bis Operation abgeschlossen
- `GCEInstanceList` listet laufende VMs in der Zone
- Start/Stop-Zyklen ohne Datenverlust

---

### WP-GCP-08 — Firestore ⬜

**Ziel:** `std/cloud/gcp/firestore.lyu` — NoSQL-Dokument-Datenbank, vollständige CRUD + Query-API.

**Zu implementieren:**

Firestore-Werttypen (spezifisch für Firestore-REST-API):
```lyx
# Firestore verwendet ein typisiertes Wert-Format:
# {"stringValue": "hello"}
# {"integerValue": "42"}       ← string in JSON!
# {"doubleValue": 3.14}
# {"booleanValue": true}
# {"nullValue": null}
# {"timestampValue": "2024-01-01T00:00:00Z"}
# {"bytesValue": "<base64>"}
# {"referenceValue": "projects/.../documents/..."}
# {"geoPointValue": {"latitude": 48.8, "longitude": 2.3}}
# {"arrayValue": {"values": [...]}}
# {"mapValue": {"fields": {"key": <Value>}}}

struct FSDoc {
    fields:  ptr    # JSON-Objekt mit Firestore-typisierten Feldern
    name:    ptr    # vollständiger Ressourcenname
    created: ptr
    updated: ptr
}

fn FSDocNew() -> FSDoc
fn FSDocFree(doc: FSDoc)
fn FSDocSetString(doc: FSDoc, key: ptr, val: ptr)
fn FSDocSetInt(doc: FSDoc, key: ptr, val: i64)
fn FSDocSetFloat(doc: FSDoc, key: ptr, val: f64)
fn FSDocSetBool(doc: FSDoc, key: ptr, val: bool)
fn FSDocSetNull(doc: FSDoc, key: ptr)
fn FSDocSetArray(doc: FSDoc, key: ptr, arr: ptr, count: i32)
fn FSDocSetMap(doc: FSDoc, key: ptr, subDoc: FSDoc)

fn FSDocGetString(doc: FSDoc, key: ptr) -> ptr
fn FSDocGetInt(doc: FSDoc, key: ptr) -> i64
fn FSDocGetFloat(doc: FSDoc, key: ptr) -> f64
fn FSDocGetBool(doc: FSDoc, key: ptr) -> bool
fn FSDocHasField(doc: FSDoc, key: ptr) -> bool
fn FSDocFieldCount(doc: FSDoc) -> i32
```

Firestore-Operationen:
```lyx
struct FirestoreConn {
    client:   GCPClient
    project:  ptr
    database: ptr    # "(default)"
}

fn FirestoreConnect(creds: GCPCredentials, project: ptr) -> FirestoreConn
fn FirestoreDisconnect(c: FirestoreConn)

# CRUD:
fn FSCreate(c: FirestoreConn, collection: ptr, docId: ptr, doc: FSDoc) -> i32
# PUT /v1/projects/{proj}/databases/(default)/documents/{collection}/{docId}
fn FSGet(c: FirestoreConn, collection: ptr, docId: ptr) -> FSDoc
# GET /v1/projects/{proj}/databases/(default)/documents/{collection}/{docId}
fn FSUpdate(c: FirestoreConn, collection: ptr, docId: ptr, doc: FSDoc) -> i32
# PATCH ... (field mask update)
fn FSDelete(c: FirestoreConn, collection: ptr, docId: ptr) -> i32
# DELETE ...
fn FSExists(c: FirestoreConn, collection: ptr, docId: ptr) -> bool

# Upsert (create or update):
fn FSSet(c: FirestoreConn, collection: ptr, docId: ptr, doc: FSDoc) -> i32
# Überschreibt Dokument vollständig

# Abfragen:
struct FSQuery {
    collection: ptr
    filters:    ptr    # JSON-Array von Filterobjekten
    orderBy:    ptr    # JSON-Array
    limit:      i32
    offset:     i32
    startAfter: ptr    # Cursor
}

fn FSQueryNew(collection: ptr) -> FSQuery
fn FSQueryWhere(q: FSQuery, field: ptr, op: ptr, value: ptr) -> FSQuery
# op: "EQUAL", "LESS_THAN", "GREATER_THAN", "ARRAY_CONTAINS", "IN"
fn FSQueryOrderBy(q: FSQuery, field: ptr, dir: ptr) -> FSQuery
# dir: "ASCENDING", "DESCENDING"
fn FSQueryLimit(q: FSQuery, n: i32) -> FSQuery
fn FSQueryOffset(q: FSQuery, n: i32) -> FSQuery
fn FSQueryRun(c: FirestoreConn, q: FSQuery) -> ptr  # → FSDoc[]

# Collection-Listing:
fn FSList(c: FirestoreConn, collection: ptr, pageSize: i32) -> ptr
fn FSListPage(c: FirestoreConn, collection: ptr, pageToken: ptr, pageSize: i32) -> ptr

# Transaktionen:
struct FSTx {
    txId:   ptr
    client: FirestoreConn
}

fn FSBegin(c: FirestoreConn) -> FSTx
fn FSTxGet(tx: FSTx, collection: ptr, docId: ptr) -> FSDoc
fn FSTxCreate(tx: FSTx, collection: ptr, docId: ptr, doc: FSDoc)
fn FSTxUpdate(tx: FSTx, collection: ptr, docId: ptr, doc: FSDoc)
fn FSTxDelete(tx: FSTx, collection: ptr, docId: ptr)
fn FSCommit(tx: FSTx) -> i32
fn FSRollback(tx: FSTx) -> i32

# Dokument-Konverter:
fn FSDocToJSON(doc: FSDoc) -> ptr      # Firestore-Format → Plain JSON
fn FSDocFromJSON(json: ptr) -> FSDoc  # Plain JSON → Firestore-Format
```

**Dateien:**
- `std/cloud/gcp/firestore.lyu` (neu)

**Akzeptanzkriterien:**
- CRUD-Zyklus: Erstellen → Lesen → Aktualisieren → Löschen
- Query mit Where-Filter und OrderBy liefert korrekte Ergebnisse
- Transaktion: entweder alle Ops committed oder keiner
- `FSDocToJSON` erzeugt lesbares JSON (ohne Firestore-Typ-Wrapper)

---

### WP-GCP-09 — Pub/Sub ⬜

**Ziel:** `std/cloud/gcp/pubsub.lyu` — Google Cloud Pub/Sub, Publisher und Subscriber.

**Zu implementieren:**

```lyx
struct PubSubConn {
    client:  GCPClient
    project: ptr
}

fn PubSubConnect(creds: GCPCredentials, project: ptr) -> PubSubConn
fn PubSubDisconnect(c: PubSubConn)

# Topics:
fn PubSubTopicCreate(c: PubSubConn, topic: ptr) -> i32
# PUT /v1/projects/{proj}/topics/{topic}
fn PubSubTopicDelete(c: PubSubConn, topic: ptr) -> i32
fn PubSubTopicExists(c: PubSubConn, topic: ptr) -> bool
fn PubSubTopicList(c: PubSubConn) -> ptr   # → Topic-Namen[]

# Subscriptions:
fn PubSubSubscriptionCreate(c: PubSubConn, sub: ptr, topic: ptr, ackDeadline: i32) -> i32
# PUT /v1/projects/{proj}/subscriptions/{sub}
# Body: {"topic": "projects/{proj}/topics/{topic}", "ackDeadlineSeconds": 30}
fn PubSubSubscriptionDelete(c: PubSubConn, sub: ptr) -> i32
fn PubSubSubscriptionList(c: PubSubConn) -> ptr

# Publishing:
struct PubSubMessage {
    data:       ptr     # base64-kodierte Nutzlast
    dataLen:    i32
    attributes: ptr     # JSON-Objekt {"key":"val",...}
    messageId:  ptr     # Server-zugewiesene ID
}

fn PubSubPublish(c: PubSubConn, topic: ptr, data: ptr, dataLen: i32) -> ptr
# POST /v1/projects/{proj}/topics/{topic}:publish
# Body: {"messages":[{"data":"<base64(data)>"}]}
# → message IDs[]

fn PubSubPublishBatch(c: PubSubConn, topic: ptr, msgs: ptr, count: i32) -> ptr
# Mehrere Nachrichten in einem Request

fn PubSubPublishWithAttrs(c: PubSubConn, topic: ptr,
                          data: ptr, dataLen: i32,
                          attrs: ptr) -> ptr

# Pull-Subscriber:
struct PubSubPulledMessage {
    ackId:   ptr
    message: PubSubMessage
}

fn PubSubPull(c: PubSubConn, sub: ptr, maxMessages: i32) -> ptr  # → PubSubPulledMessage[]
# POST /v1/projects/{proj}/subscriptions/{sub}:pull
# Body: {"maxMessages": N}

fn PubSubAck(c: PubSubConn, sub: ptr, ackIds: ptr, count: i32) -> i32
# POST /v1/.../subscriptions/{sub}:acknowledge
# Body: {"ackIds": ["..."]}

fn PubSubNack(c: PubSubConn, sub: ptr, ackIds: ptr, count: i32) -> i32
# POST .../modifyAckDeadline mit ackDeadlineSeconds=0

# Synchroner Consumer (Pull-Loop):
fn PubSubConsume(c: PubSubConn, sub: ptr, maxMessages: i32,
                 handler: ptr) -> i32
# Ruft handler(msg: PubSubPulledMessage) für jede Nachricht auf
# handler gibt 0 (ack) oder 1 (nack) zurück
# Läuft bis handler -1 zurückgibt

# Dead Letter Topics:
fn PubSubSetDeadLetter(c: PubSubConn, sub: ptr, deadLetterTopic: ptr, maxAttempts: i32) -> i32

# Message-Hilfsfunktionen:
fn PubSubMsgData(msg: PubSubPulledMessage) -> ptr      # base64-dekodiert
fn PubSubMsgDataLen(msg: PubSubPulledMessage) -> i32
fn PubSubMsgAttr(msg: PubSubPulledMessage, key: ptr) -> ptr
fn PubSubMsgFree(msg: PubSubPulledMessage)
```

**Dateien:**
- `std/cloud/gcp/pubsub.lyu` (neu)

**Akzeptanzkriterien:**
- Publish + Pull-Consumer verarbeitet 1000 Nachrichten ohne Verlust
- Batch-Publish sendet bis zu 1000 Nachrichten in einem Request (GCP-Limit)
- ACK nach Verarbeitung, NACK bei Handler-Fehler
- `PubSubConsume`-Loop endet sauber bei Handler-Return -1

---

### WP-GCP-10 — Cloud Functions & Cloud Run ⬜

**Ziel:** `std/cloud/gcp/functions.lyu` — Deployment und Invoke von Cloud Functions (v2) und Cloud Run.

**Zu implementieren:**

```lyx
# Cloud Functions v2:
struct GCFConn {
    client:  GCPClient
    project: ptr
    region:  ptr    # "europe-west1"
}

struct GCFFunction {
    name:       ptr
    state:      ptr    # "ACTIVE", "DEPLOYING", "FAILED"
    url:        ptr    # HTTPS-Trigger-URL
    runtime:    ptr    # "nodejs20", "python312", "go122"
    entryPoint: ptr
    memory:     i32    # MB
    timeout:    i32    # Sekunden
    updated:    ptr
}

fn GCFConnect(creds: GCPCredentials, project: ptr, region: ptr) -> GCFConn
fn GCFDisconnect(c: GCFConn)

fn GCFFunctionList(c: GCFConn) -> ptr       # → GCFFunction[]
fn GCFFunctionGet(c: GCFConn, name: ptr) -> GCFFunction
fn GCFFunctionDelete(c: GCFConn, name: ptr) -> GCFOperation
fn GCFFunctionExists(c: GCFConn, name: ptr) -> bool

# Aufrufen einer Funktion:
fn GCFInvoke(c: GCFConn, name: ptr, data: ptr, dataLen: i32) -> GCPResponse
# POST zur Function-URL mit Bearer-Auth
# Header: Content-Type: application/json

fn GCFInvokeRaw(c: GCFConn, url: ptr, data: ptr, dataLen: i32) -> GCPResponse
# Direkt an beliebige Cloud-Run/Function-URL

# GCF Operations (LRO):
struct GCFOperation {
    name:   ptr
    done:   bool
    error:  ptr
}

fn GCFOperationWait(c: GCFConn, op: GCFOperation) -> GCFOperation

# Cloud Run:
struct GCRConn {
    client:  GCPClient
    project: ptr
    region:  ptr
}

struct GCRService {
    name:    ptr
    url:     ptr    # öffentliche HTTPS-URL
    image:   ptr    # Container-Image
    status:  ptr    # "ACTIVE", "FAILED"
    traffic: i32    # % Traffic auf diese Revision
}

fn GCRConnect(creds: GCPCredentials, project: ptr, region: ptr) -> GCRConn
fn GCRServiceList(c: GCRConn) -> ptr
fn GCRServiceGet(c: GCRConn, name: ptr) -> GCRService
fn GCRServiceDelete(c: GCRConn, name: ptr) -> i32

# Cloud Run aufrufen:
fn GCRInvoke(c: GCRConn, name: ptr, path: ptr,
             data: ptr, dataLen: i32) -> GCPResponse
fn GCRInvokeGet(c: GCRConn, name: ptr, path: ptr) -> GCPResponse
```

**Dateien:**
- `std/cloud/gcp/functions.lyu` (neu)

**Akzeptanzkriterien:**
- `GCFInvoke` ruft HTTPS-Trigger-Funktion auf und gibt Response zurück
- `GCRInvoke` sendet authentifizierten Request an Cloud Run Service
- `GCFFunctionList` zeigt Status aller Functions in der Region
- LRO-Wait bei Deploy max 120s

---

### WP-GCP-11 — Cloud Logging & Cloud Monitoring ⬜

**Ziel:** `std/cloud/gcp/logging.lyu` + `std/cloud/gcp/monitoring.lyu` — Observability für GCP-Anwendungen.

**Zu implementieren:**

Cloud Logging:
```lyx
# Severity-Level:
const GCL_DEFAULT   = 0
const GCL_DEBUG     = 100
const GCL_INFO      = 200
const GCL_NOTICE    = 300
const GCL_WARNING   = 400
const GCL_ERROR     = 500
const GCL_CRITICAL  = 600
const GCL_ALERT     = 700
const GCL_EMERGENCY = 800

struct GCLConn {
    client:    GCPClient
    project:   ptr
    logName:   ptr    # "projects/{proj}/logs/{log-id}"
    resource:  ptr    # monitored resource JSON
}

fn GCLConnect(creds: GCPCredentials, project: ptr, logId: ptr) -> GCLConn
fn GCLDisconnect(c: GCLConn)

fn GCLWrite(c: GCLConn, severity: i32, message: ptr) -> i32
# POST /v2/entries:write
# Body: {"logName":"...","resource":{"type":"global"},
#        "entries":[{"textPayload":"...","severity":"INFO","timestamp":"..."}]}

fn GCLWriteJSON(c: GCLConn, severity: i32, jsonPayload: ptr) -> i32
# Strukturiertes Logging (jsonPayload statt textPayload)

fn GCLFlush(c: GCLConn) -> i32
# Schreibt gepufferte Einträge (Batch-Modus)

# Log-Abfragen:
fn GCLFilter(c: GCLConn, filter: ptr, pageSize: i32) -> ptr
# POST /v2/entries:list
# filter: Cloud Logging-Filter-Syntax z.B. 'severity>=ERROR'
# → Array von Log-Einträgen als JSON

# Convenience-Logger (Wrapper mit Buffering):
struct GCLLogger {
    conn:    GCLConn
    buf:     ptr
    bufLen:  i32
    maxBuf:  i32    # Default: 100 Einträge
}

fn GCLLoggerNew(conn: GCLConn, bufSize: i32) -> GCLLogger
fn GCLLoggerDebug(l: GCLLogger, msg: ptr)
fn GCLLoggerInfo(l: GCLLogger, msg: ptr)
fn GCLLoggerWarning(l: GCLLogger, msg: ptr)
fn GCLLoggerError(l: GCLLogger, msg: ptr)
fn GCLLoggerFlush(l: GCLLogger) -> i32
fn GCLLoggerFree(l: GCLLogger)
```

Cloud Monitoring (Custom Metrics):
```lyx
struct GCMConn {
    client:  GCPClient
    project: ptr
}

fn GCMConnect(creds: GCPCredentials, project: ptr) -> GCMConn
fn GCMDisconnect(c: GCMConn)

# Custom Metric Descriptor:
fn GCMCreateMetric(c: GCMConn, metricType: ptr,
                   displayName: ptr, unit: ptr, kind: ptr) -> i32
# POST /v3/projects/{proj}/metricDescriptors
# kind: "GAUGE", "CUMULATIVE", "DELTA"
# metricType: "custom.googleapis.com/my_metric"

# Messwerte schreiben:
struct GCMPoint {
    metricType: ptr
    value:      f64
    timestamp:  i64    # Unix-Nanosekunden
    labels:     ptr    # JSON-Objekt {"key":"val"}
}

fn GCMWrite(c: GCMConn, points: ptr, count: i32) -> i32
# POST /v3/projects/{proj}/timeSeries
# Batch bis 200 Punkte

fn GCMWriteGauge(c: GCMConn, metricType: ptr, value: f64) -> i32
fn GCMWriteCounter(c: GCMConn, metricType: ptr, delta: f64) -> i32

# Messwerte lesen:
fn GCMQuery(c: GCMConn, metricType: ptr,
            startTime: i64, endTime: i64) -> ptr   # JSON-Array
```

**Dateien:**
- `std/cloud/gcp/logging.lyu` (neu)
- `std/cloud/gcp/monitoring.lyu` (neu)

**Akzeptanzkriterien:**
- `GCLWrite` + `GCLFlush` erscheinen im Cloud Logging-Console
- Strukturiertes JSON-Logging mit korrekter Severity
- `GCMWriteGauge` schreibt Custom Metric, sichtbar im Metrics Explorer
- Logger-Buffer sammelt 100 Einträge, flush schreibt alle in einem Request

---

### WP-GCP-12 — Secret Manager & IAM ⬜

**Ziel:** `std/cloud/gcp/secrets.lyu` + `std/cloud/gcp/iam.lyu` — Secrets-Verwaltung und IAM-Operationen.

**Zu implementieren:**

Secret Manager:
```lyx
struct GCSMConn {
    client:  GCPClient
    project: ptr
}

fn GCSMConnect(creds: GCPCredentials, project: ptr) -> GCSMConn
fn GCSMDisconnect(c: GCSMConn)

# Secret-Verwaltung:
fn GCSMCreate(c: GCSMConn, name: ptr) -> i32
# POST /v1/projects/{proj}/secrets
# Body: {"replication":{"automatic":{}}}

fn GCSMAddVersion(c: GCSMConn, name: ptr, data: ptr, dataLen: i32) -> ptr
# POST /v1/projects/{proj}/secrets/{name}:addSecretVersion
# Body: {"payload":{"data":"<base64(data)>"}}
# → Version-Name: "projects/.../versions/1"

fn GCSMAccess(c: GCSMConn, name: ptr, version: ptr) -> ptr
# GET /v1/projects/{proj}/secrets/{name}/versions/{version}:access
# version: "latest" oder "1", "2", ...
# → base64-dekodierter Secret-Wert

fn GCSMDelete(c: GCSMConn, name: ptr) -> i32
fn GCSMDisable(c: GCSMConn, name: ptr, version: ptr) -> i32
fn GCSMList(c: GCSMConn) -> ptr    # → Secret-Namen[]
fn GCSMVersionList(c: GCSMConn, name: ptr) -> ptr   # → Version-Infos[]

# Kurzform (häufig verwendet):
fn GCSMGet(c: GCSMConn, name: ptr) -> ptr
# Alias für GCSMAccess(c, name, "latest")
fn GCSMSet(c: GCSMConn, name: ptr, data: ptr, dataLen: i32) -> i32
# Create (if not exists) + AddVersion
```

IAM:
```lyx
struct GCIAMConn {
    client:  GCPClient
    project: ptr
}

fn GCIAMConnect(creds: GCPCredentials, project: ptr) -> GCIAMConn
fn GCIAMDisconnect(c: GCIAMConn)

# Service Accounts:
struct GCIAMServiceAccount {
    name:        ptr    # "projects/{proj}/serviceAccounts/{email}"
    email:       ptr
    displayName: ptr
    disabled:    bool
}

fn GCIAMServiceAccountCreate(c: GCIAMConn, accountId: ptr, displayName: ptr) -> GCIAMServiceAccount
fn GCIAMServiceAccountDelete(c: GCIAMConn, email: ptr) -> i32
fn GCIAMServiceAccountList(c: GCIAMConn) -> ptr
fn GCIAMServiceAccountGet(c: GCIAMConn, email: ptr) -> GCIAMServiceAccount

# Keys:
fn GCIAMKeyCreate(c: GCIAMConn, saEmail: ptr) -> ptr  # → JSON-Key-Datei
fn GCIAMKeyDelete(c: GCIAMConn, saEmail: ptr, keyId: ptr) -> i32
fn GCIAMKeyList(c: GCIAMConn, saEmail: ptr) -> ptr

# IAM Policy (Ressource-Level):
fn GCIAMGetPolicy(c: GCIAMConn, resource: ptr) -> ptr  # → Policy JSON
fn GCIAMSetPolicy(c: GCIAMConn, resource: ptr, policy: ptr) -> i32
fn GCIAMAddBinding(c: GCIAMConn, resource: ptr, role: ptr, member: ptr) -> i32
# member: "user:...", "serviceAccount:...", "group:...", "allUsers"
fn GCIAMRemoveBinding(c: GCIAMConn, resource: ptr, role: ptr, member: ptr) -> i32
fn GCIAMTestPermissions(c: GCIAMConn, resource: ptr, perms: ptr, count: i32) -> ptr
# → Array der erlaubten Berechtigungen

# Rollen:
fn GCIAMRoleList(c: GCIAMConn) -> ptr       # Alle Rollen
fn GCIAMRoleGet(c: GCIAMConn, role: ptr) -> ptr  # Rolle-Details
```

**Dateien:**
- `std/cloud/gcp/secrets.lyu` (neu)
- `std/cloud/gcp/iam.lyu` (neu)

**Akzeptanzkriterien:**
- `GCSMSet` + `GCSMGet` speichert und lädt Secret korrekt
- Secrets enthalten keine Trailing-Whitespace nach base64-Dekodierung
- `GCIAMServiceAccountCreate` erstellt SA mit minimalen Rechten
- `GCIAMTestPermissions` gibt nur tatsächlich gewährte Berechtigungen zurück

---

### WP-GCP-13 — `lyxgcloud` CLI ⬜

**Ziel:** `bin/lyxgcloud` — Kommandozeilen-Tool analog zu `gcloud`, nutzt das Lyx GCP SDK.

**Zu implementieren:**

```
lyxgcloud <command> [subcommand] [flags]

Globale Flags:
  --project      GCP-Projekt-ID
  --credentials  Pfad zur Service-Account-JSON
  --format       Ausgabeformat: json|text|table (default: text)
  --quiet        Nur Fehler ausgeben

Befehle:

  config
    set project <project-id>     → ~/.config/lyxgcloud/config.json
    set credentials <path>
    list                         → zeigt aktuelle Konfiguration
    get-token                    → gibt access_token aus

  storage (gs://)
    ls [gs://bucket[/prefix]]    → Buckets oder Objekte auflisten
    cp <src> gs://bucket/dst     → lokale Datei hochladen
    cp gs://bucket/src <dst>     → herunterladen
    mv gs://src gs://dst         → verschieben (copy + delete)
    rm gs://bucket/object        → löschen
    cat gs://bucket/object       → Inhalt auf stdout
    mb gs://bucket               → Bucket erstellen (make bucket)
    rb gs://bucket               → Bucket löschen (remove bucket)
    stat gs://bucket/object      → Metadaten anzeigen
    signurl gs://bucket/obj 1h   → Signed URL erzeugen

  compute
    instances list               → alle VMs der Zone
    instances describe <name>    → VM-Details
    instances start <name>
    instances stop <name>
    instances delete <name>
    disks list
    firewall-rules list

  firestore
    get <collection> <doc-id>    → Dokument ausgeben
    set <collection> <doc-id> '{"key":"val"}'
    delete <collection> <doc-id>
    list <collection>            → Dokumente auflisten
    query <collection> --where 'field=value'

  pubsub
    topics list
    topics create <topic>
    topics delete <topic>
    topics publish <topic> <message>
    subscriptions list
    subscriptions create <sub> --topic <topic>
    subscriptions delete <sub>
    subscriptions pull <sub> [--max-messages 10]
    subscriptions ack <sub> <ack-id>

  functions
    list                         → alle Cloud Functions
    describe <name>              → Details
    call <name> --data '{"key":"val"}'
    delete <name>

  run
    services list
    services describe <name>
    services invoke <name> [--path /api] [--data '...']

  logging
    read [--filter '...'] [--limit 100]
    write <log-id> <message> [--severity INFO]
    tail [--filter '...']        → Streaming (Poll alle 5s)

  secrets
    list
    create <name>
    get <name> [--version latest]
    set <name> <value>           → neue Version
    delete <name>
    versions list <name>

  iam
    service-accounts list
    service-accounts create <id> [--display-name '...']
    service-accounts delete <email>
    service-accounts keys create <email>
    service-accounts keys list <email>
```

Konfigurationsdatei (`~/.config/lyxgcloud/config.json`):
```json
{
  "project": "my-project-123",
  "credentials": "/home/user/.gcp/service-account.json",
  "region": "europe-west1",
  "zone": "europe-west1-b",
  "format": "text"
}
```

**Dateien:**
- `bin/lyxgcloud.lyu` (neu) — Haupt-CLI-Dispatcher
- `bin/lyxgcloud_storage.lyu` (neu)
- `bin/lyxgcloud_compute.lyu` (neu)
- `bin/lyxgcloud_firestore.lyu` (neu)
- `bin/lyxgcloud_pubsub.lyu` (neu)
- `bin/lyxgcloud_functions.lyu` (neu)
- `bin/lyxgcloud_logging.lyu` (neu)
- `bin/lyxgcloud_secrets.lyu` (neu)
- `bin/lyxgcloud_iam.lyu` (neu)
- `bin/lyxgcloud.lyx` (Binär)

**Akzeptanzkriterien:**
- `lyxgcloud storage ls gs://` listet Buckets des konfigurierten Projekts
- `lyxgcloud storage cp local.txt gs://bucket/remote.txt` lädt Datei hoch
- `lyxgcloud secrets get my-secret` gibt Klartext aus
- `lyxgcloud config set project xyz` persistiert in `~/.config/lyxgcloud/config.json`
- `--format json` gibt maschinenlesbare JSON-Ausgabe für alle Befehle

---

### WP-GCP-14 — Demos & Integrationstests ⬜

**Ziel:** End-to-End-Beispielprogramme und vollständige Integrationstests.

**Zu implementieren:**

Demo 1 — GCS File-Sync:
```lyx
import std/cloud/gcp/storage

fn main() {
    let creds = GCPCredentialsDefault("https://www.googleapis.com/auth/cloud-platform")
    let gcs = GCSConnect(creds, "my-project")

    # Alle lokalen Dateien eines Verzeichnisses hochladen
    let files = fsReadDir("./data/")
    for f in files {
        let data = fsReadFile(f.path)
        GCSUpload(gcs, "backup-bucket", f.name, data.ptr, data.size)
        println("Uploaded: " + f.name)
    }

    # Bucket-Inventar ausgeben
    let objects = GCSList(gcs, "backup-bucket", "", 1000)
    for obj in objects {
        println(obj.name + "\t" + obj.size)
    }
}
```

Demo 2 — Firestore Event Store:
```lyx
import std/cloud/gcp/firestore
import std/cloud/gcp/pubsub

fn main() {
    let creds = GCPCredentialsFromFile("service-account.json")
    let fs = FirestoreConnect(creds, "my-project")
    let ps = PubSubConnect(creds, "my-project")

    # Events aus Pub/Sub konsumieren und in Firestore speichern
    PubSubConsume(ps, "events-sub", 10, fn(msg: PubSubPulledMessage) -> i32 {
        let data = PubSubMsgData(msg)
        let eventId = PubSubMsgAttr(msg, "event_id")

        let doc = FSDocNew()
        FSDocSetString(doc, "payload", data)
        FSDocSetString(doc, "source", "pubsub")
        FSDocSetInt(doc, "processed_at", unixNow())
        FSCreate(fs, "events", eventId, doc)

        return 0  # ACK
    })
}
```

Demo 3 — Secret-gesteuerter DB-Connect:
```lyx
import std/cloud/gcp/secrets
import std/db/postgres

fn main() {
    let creds = GCPCredentialsFromEnv()
    let sm = GCSMConnect(creds, "my-project")

    # Credentials aus Secret Manager laden
    let dbUrl = GCSMGet(sm, "prod-db-url")
    let dbPass = GCSMGet(sm, "prod-db-password")

    let pg = PGConnect("db.internal", 5432, "app", dbPass, "production")
    let result = PGQuery(pg, "SELECT count(*) FROM users")
    println("User count: " + PGGetValue(result, 0, 0))
}
```

Demo 4 — GCE-VM-Deployment:
```lyx
import std/cloud/gcp/compute
import std/cloud/gcp/logging

fn main() {
    let creds = GCPCredentialsFromFile("service-account.json")
    let gce = GCEConnect(creds, "my-project", "europe-west1-b")
    let log = GCLConnect(creds, "my-project", "deployments")

    let op = GCEInstanceCreate(gce, "worker-01", "n1-standard-2",
                               "debian-cloud/global/images/family/debian-12", 20)
    GCLWrite(log, GCL_INFO, "Creating VM worker-01...")

    let done = GCEOperationWait(gce, op)
    if done.error != null {
        GCLWrite(log, GCL_ERROR, "VM creation failed: " + done.error)
    } else {
        let inst = GCEInstanceGet(gce, "worker-01")
        GCLWrite(log, GCL_INFO, "VM ready at: " + inst.externalIP)
    }
}
```

Demo 5 — Cloud Function aufrufen:
```lyx
import std/cloud/gcp/functions
import std/json

fn main() {
    let creds = GCPCredentialsDefault("https://www.googleapis.com/auth/cloud-platform")
    let gcf = GCFConnect(creds, "my-project", "europe-west1")

    let payload = '{"action":"process","items":42}'
    let resp = GCFInvoke(gcf, "data-processor", payload, len(payload))

    if resp.statusCode == 200 {
        println("Result: " + resp.body)
    } else {
        println("Error " + resp.statusCode + ": " + resp.body)
    }
}
```

Integrationstests:
```lyx
fn testGCSRoundtrip(creds: GCPCredentials, bucket: ptr) -> bool
fn testFirestoreCRUD(creds: GCPCredentials, project: ptr) -> bool
fn testPubSubPublishConsume(creds: GCPCredentials, project: ptr) -> bool
fn testSecretManagerGetSet(creds: GCPCredentials, project: ptr) -> bool
fn testCredentialChain() -> bool
fn testJWTBuildAndVerify() -> bool
fn testRSASignVerify() -> bool
```

**Dateien:**
- `demo_gcp.lyu` (neu) — kombiniertes Demo
- `demo_gcp.lyx` (Binär)
- `tests/gcp_integration.lyu` (neu)

**Akzeptanzkriterien:**
- Alle 5 Demos laufen ohne Fehler mit echten GCP-Credentials
- Integrationstests grün gegen ein GCP-Testprojekt
- `testCredentialChain()` erkennt korrekt die ADC-Quelle
- `testRSASignVerify()` validiert gegen `openssl`-Referenzsignatur
- Gesamte SDK-Initialisierung (Credentials → Token) < 2 Sekunden

---

## Empfohlene Implementierungsreihenfolge

```
Woche 1-2:  WP-GCP-01  → RSA + BigNum (komplexeste Komponente, isoliert testbar)
Woche 2:    WP-GCP-02  → JWT Builder (hängt von RSA ab)
Woche 3:    WP-GCP-03  → OAuth 2.0 Token Manager
Woche 3:    WP-GCP-04  → Credential Chain (hängt von 03 ab)
Woche 4:    WP-GCP-05  → GCP Transport Layer (Basis für alle Services)
Woche 4-5:  WP-GCP-06  → Cloud Storage (wichtigster Service)
Woche 5:    WP-GCP-07  → Compute Engine
Woche 5-6:  WP-GCP-08  → Firestore
Woche 6:    WP-GCP-09  → Pub/Sub
Woche 7:    WP-GCP-10  → Cloud Functions + Cloud Run
Woche 7:    WP-GCP-11  → Logging + Monitoring
Woche 8:    WP-GCP-12  → Secret Manager + IAM
Woche 8-9:  WP-GCP-13  → lyxgcloud CLI
Woche 9:    WP-GCP-14  → Demos + Integrationstests
```

## Kritischer Pfad

```
WP-GCP-01 (RSA/BigNum)
    └→ WP-GCP-02 (JWT)
           └→ WP-GCP-03 (OAuth Token)
                  └→ WP-GCP-04 (Credential Chain)
                         └→ WP-GCP-05 (Transport)
                                └→ WP-GCP-06..12 (Services) ─→ WP-GCP-13 (CLI)
                                                                      └→ WP-GCP-14 (Tests)
```

**Hinweis:** WP-GCP-01 (RSA + BigNum) ist die technisch schwierigste Komponente.
`BigNumModExp` benötigt korrekte Montgomery-Multiplikation oder Barret-Reduktion
für akzeptable Performance bei RSA-2048. Alternativ kann OpenSSL's `EVP_DigestSign`
via `extern fn` genutzt werden, falls BigNum zu aufwändig ist — dies spart 2 Wochen.
