# Fahrplan: DigitalOcean SDK (`std/cloud/do/`)

## Vision

Ein natives Lyx-SDK für DigitalOcean – REST/JSON via `std/net/https`, Authentifizierung über Personal Access Token (PAT) oder OAuth2, alle wichtigen DO-Services typsicher zugänglich, plus eine `lyxdo`-CLI. DO ist deutlich einfacher als AWS/GCP: kein SigV4, kein JWT – nur `Authorization: Bearer <token>`.

```lyx
import std/cloud/do/droplets
import std/cloud/do/spaces
import std/cloud/do/dns

fn main() {
    # Token aus Umgebungsvariable DIGITALOCEAN_TOKEN
    let creds = DOCredentialsFromEnv()

    # Droplet erstellen
    let d = DropletCreate(creds, "web-01", "fra1", "s-1vcpu-1gb", "ubuntu-22-04-x64")
    DropletWait(creds, d.id, "active")
    println("Droplet IP: " + d.networks.v4[0].ipAddress)

    # Spaces: Datei hochladen (S3-kompatibel)
    let sp = SpacesConnect(creds, "fra1")
    SpacesUpload(sp, "my-bucket", "index.html", "<h1>Hello</h1>", 14)

    # DNS: A-Record auf Droplet-IP setzen
    DomainRecordCreate(creds, "example.com", "A", "web-01", d.networks.v4[0].ipAddress, 300)
}
```

---

## Architektur

```
┌─────────────────────────────────────────────────────────────┐
│                     Lyx-Anwendung                           │
└──┬──────────┬──────────┬──────────┬──────────┬─────────────┘
   │          │          │          │          │
┌──▼──┐  ┌───▼──┐  ┌────▼──┐  ┌───▼──┐  ┌────▼──────┐
│Drop-│  │Space-│  │Managed│  │  K8s │  │Networking │  ...
│lets │  │  s   │  │  DB   │  │(DOKS)│  │DNS/LB/VPC │
└──┬──┘  └───┬──┘  └────┬──┘  └───┬──┘  └────┬──────┘
   └─────────┴──────────┴──────────┴──────────┘
                         │
          ┌──────────────▼──────────────┐
          │  DO REST/JSON Transport      │
          │  (std/cloud/do/transport)    │
          │  Authorization: Bearer <PAT> │
          │  Pagination, Retry, Rate-Limit│
          └──────────────┬──────────────┘
                         │
          ┌──────────────▼──────────────┐
          │  std/net/https.lyu           │
          │  (OpenSSL TLS intern)        │
          └──────────────┬──────────────┘
                         │
          ┌──────────────▼──────────────┐
          │  std/cloud/do/credentials    │
          │  PAT | OAuth2 Token          │
          │  ~/.config/lyxdo/config.json │
          └─────────────────────────────┘

  Spaces (S3-kompatibel):
  ┌──────────────────────────────┐
  │  SpacesConn                  │
  │  Endpoint: fra1.digitalocean │
  │         spaces.com           │
  │  Auth: SigV4 (Spaces Key)    │  ← Wiederverwendung von WP-S3-01/02
  └──────────────────────────────┘
```

---

## DigitalOcean API: Referenz

### Authentifizierung

```
Personal Access Token (PAT):
  Header: Authorization: Bearer <token>
  Token-Quelle: https://cloud.digitalocean.com/account/api/tokens
  Scope: Read / Read+Write

OAuth2 (für Third-Party-Apps):
  POST https://cloud.digitalocean.com/v1/oauth/token
  grant_type=authorization_code | refresh_token
  → access_token, refresh_token, expires_in

Umgebungsvariable: DIGITALOCEAN_TOKEN
Konfig-Datei:      ~/.config/lyxdo/config.json
                   {"token": "dop_v1_...", "default_region": "fra1"}
```

### API-Konventionen

```
Basis-URL:    https://api.digitalocean.com/v2
Content-Type: application/json
Accept:       application/json

Paginierung:
  Query: ?page=1&per_page=20   (default per_page=20, max=200)
  Antwort:
  {
    "droplets": [...],
    "links": {
      "pages": {
        "next": "https://api.digitalocean.com/v2/droplets?page=2&per_page=20",
        "last": "https://api.digitalocean.com/v2/droplets?page=5&per_page=20"
      }
    },
    "meta": { "total": 94 }
  }

Rate-Limiting:
  5000 Requests/Stunde (PAT)
  Header: RateLimit-Limit, RateLimit-Remaining, RateLimit-Reset (Unix-TS)

Fehler-Format:
  { "id": "not_found", "message": "The resource you were accessing could not be found." }
  { "id": "unprocessable_entity", "message": "...", "errors": [...] }

HTTP-Status:
  200 OK, 201 Created, 204 No Content
  401 Unauthorized, 403 Forbidden, 404 Not Found
  422 Unprocessable Entity, 429 Too Many Requests
  500/503 Server Error
```

### DO Spaces (S3-kompatibel)

```
Endpoint:  https://<region>.digitaloceanspaces.com
Auth:      AWS SigV4 (Spaces Access Key + Secret Key)
           DIGITALOCEAN_SPACES_ACCESS_KEY / DIGITALOCEAN_SPACES_SECRET_KEY
Bucket-URL: https://<bucket>.<region>.digitaloceanspaces.com
CDN-URL:    https://<bucket>.<region>.cdn.digitaloceanspaces.com

API: 100% S3-kompatibel → Wiederverwendung von std/cloud/s3.lyu mit
     angepasstem Endpoint und Regions-String ("fra1" → region)
```

### Wichtige Regionen

| Slug   | Standort         |
|--------|------------------|
| fra1   | Frankfurt        |
| nyc3   | New York         |
| ams3   | Amsterdam        |
| sgp1   | Singapur         |
| lon1   | London           |
| tor1   | Toronto          |
| sfo3   | San Francisco    |
| blr1   | Bangalore        |
| syd1   | Sydney           |

---

## Phasen

| Phase | WPs         | Inhalt                                     | Status |
|-------|-------------|--------------------------------------------|--------|
| 1     | DO-01–02    | Transport + Credential Management          | ⬜     |
| 2     | DO-03–04    | Droplets, Spaces                           | ⬜     |
| 3     | DO-05–06    | Managed Databases, Kubernetes              | ⬜     |
| 4     | DO-07–08    | Networking (DNS/LB/VPC/Firewall), Volumes  | ⬜     |
| 5     | DO-09–10    | App Platform, Container Registry           | ⬜     |
| 6     | DO-11–12    | Functions, Monitoring & Alerts             | ⬜     |
| 7     | DO-13        | lyxdo CLI                                  | ⬜     |
| 8     | DO-14        | Demos & Integrationstests                  | ⬜     |

---

## Work Packages

---

### WP-DO-01 — REST/JSON Transport + Pagination + Retry ⬜

**Ziel:** `std/cloud/do/transport.lyu` — HTTP-Client für die DO-API mit Bearer-Auth, automatischer Paginierung und Exponential Backoff.

**Zu implementieren:**

```lyx
struct DOClient {
    token:      ptr
    baseURL:    ptr    # "https://api.digitalocean.com/v2"
    timeout:    i32    # ms, default: 30000
    maxRetries: i32    # default: 3
    userAgent:  ptr    # "lyxdo/1.0"
}

fn DOClientNew(token: ptr) -> DOClient
fn DOClientFree(c: DOClient)

struct DOResponse {
    statusCode:  i32
    body:        ptr
    bodyLen:     i32
    rateLimit:   i32    # RateLimit-Remaining
    rateLimitAt: i64    # RateLimit-Reset (Unix-TS)
}

fn DOResponseFree(r: DOResponse)

# HTTP-Methoden:
fn DOGet(c: DOClient, path: ptr) -> DOResponse
fn DOPost(c: DOClient, path: ptr, body: ptr, bodyLen: i32) -> DOResponse
fn DOPut(c: DOClient, path: ptr, body: ptr, bodyLen: i32) -> DOResponse
fn DOPatch(c: DOClient, path: ptr, body: ptr, bodyLen: i32) -> DOResponse
fn DODelete(c: DOClient, path: ptr) -> DOResponse

# Pagination-Iterator:
struct DOPage {
    client:   DOClient
    path:     ptr
    perPage:  i32
    page:     i32
    total:    i32
    hasNext:  bool
}

fn DOPageNew(c: DOClient, path: ptr, perPage: i32) -> DOPage
fn DOPageNext(p: DOPage) -> DOResponse   # nächste Seite
fn DOPageHasNext(p: DOPage) -> bool
fn DOPageTotal(p: DOPage) -> i32

# Alle Seiten sammeln (für kleine Ressourcenlisten):
fn DOGetAll(c: DOClient, path: ptr, resourceKey: ptr) -> ptr
# Iteriert über alle Seiten, gibt zusammengeführtes JSON-Array zurück

# Retry-Logik:
fn doShouldRetry(statusCode: i32) -> bool
# true für: 429, 500, 502, 503, 504
fn doRetryDelay(attempt: i32) -> i32
# Bei 429: bis RateLimit-Reset warten
# Bei 5xx: 100ms * 2^attempt + Jitter

# Fehler:
struct DOError {
    id:      ptr    # "not_found", "unauthorized", ...
    message: ptr
    errors:  ptr    # JSON-Array bei 422
}

fn DOParseError(body: ptr, bodyLen: i32) -> DOError
fn DOErrorFree(e: DOError)

# URL-Hilfsfunktionen:
fn doPath(parts: ptr, count: i32) -> ptr  # "/droplets/" + id + "/actions"
fn doQuery(path: ptr, key: ptr, val: ptr) -> ptr  # path + "?key=val"
fn doQueryAdd(path: ptr, key: ptr, val: ptr) -> ptr  # path + "&key=val"
```

**Dateien:**
- `std/cloud/do/transport.lyu` (neu)

**Akzeptanzkriterien:**
- GET /v2/account liefert Konto-Info mit korrektem Bearer-Header
- `DOGetAll` sammelt alle Droplets über mehrere Seiten (> 20)
- Rate-Limit-Handling: 429 → wartet bis Reset-Zeitstempel, retry
- Retry bei 503 mit Exponential Backoff, max 3 Versuche

---

### WP-DO-02 — Credential Management ⬜

**Ziel:** `std/cloud/do/credentials.lyu` — PAT aus Umgebung/Datei laden, OAuth2-Token-Refresh.

**Zu implementieren:**

```lyx
struct DOCredentials {
    token:         ptr
    tokenLen:      i32
    tokenType:     i32    # DO_TOKEN_PAT | DO_TOKEN_OAUTH2
    refreshToken:  ptr    # nur bei OAuth2
    expiresAt:     i64    # Unix-TS, 0 = nie (PAT)
    defaultRegion: ptr    # aus Konfig-Datei, z.B. "fra1"
    spacesKey:     ptr    # DIGITALOCEAN_SPACES_ACCESS_KEY
    spacesSecret:  ptr    # DIGITALOCEAN_SPACES_SECRET_KEY
}

const DO_TOKEN_PAT    = 1
const DO_TOKEN_OAUTH2 = 2

fn DOCredentialsFree(creds: DOCredentials)

# Laden-Funktionen:
fn DOCredentialsFromToken(token: ptr) -> DOCredentials
fn DOCredentialsFromEnv() -> DOCredentials
# DIGITALOCEAN_TOKEN → PAT
# DIGITALOCEAN_SPACES_ACCESS_KEY / _SECRET_KEY → Spaces-Credentials

fn DOCredentialsFromFile(path: ptr) -> DOCredentials
# JSON: {"token":"dop_v1_...","default_region":"fra1",
#        "spaces_access_key":"...","spaces_secret_key":"..."}

fn DOCredentialsDefault() -> DOCredentials
# Chain:
# 1. DIGITALOCEAN_TOKEN env var
# 2. ~/.config/lyxdo/config.json
# → Fehler wenn nicht gefunden

# Konfig-Datei:
fn DOConfigSave(creds: DOCredentials, path: ptr) -> i32
# Schreibt ~/.config/lyxdo/config.json
fn DOConfigLoad(path: ptr) -> DOCredentials
fn DOConfigPath() -> ptr  # → ~/.config/lyxdo/config.json

# OAuth2-Token-Refresh:
fn DOTokenRefresh(creds: DOCredentials) -> DOCredentials
# POST https://cloud.digitalocean.com/v1/oauth/token
# grant_type=refresh_token&refresh_token=...&client_id=...&client_secret=...

fn DOTokenIsExpired(creds: DOCredentials) -> bool
# true wenn expiresAt - now() < 60

# Validierung:
fn DOValidateToken(creds: DOCredentials) -> bool
# GET /v2/account → 200 = gültig, 401 = ungültig
```

**Dateien:**
- `std/cloud/do/credentials.lyu` (neu)
- `std/cloud/do/core.lyu` (neu) — Re-exportiert credentials + transport

**Akzeptanzkriterien:**
- `DOCredentialsFromEnv()` liest `DIGITALOCEAN_TOKEN`
- `DOCredentialsDefault()` findet Konfig-Datei unter `~/.config/lyxdo/config.json`
- `DOValidateToken` gibt false bei falschem Token (kein Crash)
- Konfig-Datei wird mit Modus 600 geschrieben (Token ist Geheimnis)

---

### WP-DO-03 — Droplets (VMs) ⬜

**Ziel:** `std/cloud/do/droplets.lyu` — Vollständige Droplet-Verwaltung: erstellen, auflisten, verwalten, Actions.

**Zu implementieren:**

```lyx
# Netzwerk-Info:
struct DONetwork {
    ipAddress: ptr
    netmask:   ptr
    gateway:   ptr
    netType:   ptr    # "public" | "private"
}

# Droplet-Struktur:
struct DODroplet {
    id:          i32
    name:        ptr
    status:      ptr    # "new", "active", "off", "archive"
    region:      ptr    # "fra1"
    size:        ptr    # "s-1vcpu-1gb"
    image:       ptr    # "ubuntu-22-04-x64"
    vcpus:       i32
    memory:      i32    # MB
    disk:        i32    # GB
    v4Networks:  ptr    # DONetwork[] (public + private)
    v6Networks:  ptr    # DONetwork[]
    tags:        ptr    # string[]
    created:     ptr
    features:    ptr    # ["backups","ipv6","monitoring",...]
}

fn DODropletFree(d: DODroplet)

struct DODropletCreate {
    name:     ptr
    region:   ptr     # "fra1"
    size:     ptr     # "s-1vcpu-1gb"
    image:    ptr     # "ubuntu-22-04-x64" oder numerische ID
    sshKeys:  ptr     # i32[] SSH-Key-IDs
    backups:  bool
    ipv6:     bool
    userData: ptr     # Cloud-Init-Skript
    tags:     ptr     # string[]
    vpcUUID:  ptr
}

fn DropletCreate(creds: DOCredentials, config: DODropletCreate) -> DODroplet
# POST /v2/droplets

fn DropletCreateSimple(creds: DOCredentials,
                       name: ptr, region: ptr,
                       size: ptr, image: ptr) -> DODroplet
# Kurzform ohne optionale Parameter

fn DropletDelete(creds: DOCredentials, id: i32) -> i32
fn DropletGet(creds: DOCredentials, id: i32) -> DODroplet
fn DropletList(creds: DOCredentials) -> ptr         # → DODroplet[]
fn DropletListByTag(creds: DOCredentials, tag: ptr) -> ptr

# Warten auf Status:
fn DropletWait(creds: DOCredentials, id: i32, status: ptr) -> DODroplet
# Polling GET /v2/droplets/{id} bis status erreicht, max 300s

fn DropletGetIP(creds: DOCredentials, id: i32) -> ptr
# → erste öffentliche IPv4-Adresse

# Actions (Power-Management):
const DO_ACTION_POWER_ON    = "power_on"
const DO_ACTION_POWER_OFF   = "power_off"
const DO_ACTION_REBOOT      = "reboot"
const DO_ACTION_SHUTDOWN    = "shutdown"
const DO_ACTION_RESET_PASS  = "password_reset"
const DO_ACTION_ENABLE_IPV6 = "enable_ipv6"
const DO_ACTION_SNAPSHOT    = "snapshot"
const DO_ACTION_REBUILD     = "rebuild"
const DO_ACTION_RESIZE      = "resize"
const DO_ACTION_RESTORE     = "restore"

struct DOAction {
    id:           i32
    status:       ptr    # "in-progress", "completed", "errored"
    actionType:   ptr
    startedAt:    ptr
    completedAt:  ptr
    resourceId:   i32
    resourceType: ptr
}

fn DropletAction(creds: DOCredentials, id: i32, action: ptr) -> DOAction
fn DropletActionWithParams(creds: DOCredentials, id: i32,
                           action: ptr, params: ptr) -> DOAction
fn DropletActionWait(creds: DOCredentials, dropletId: i32,
                     actionId: i32) -> DOAction
# Polling GET /v2/droplets/{id}/actions/{actionId}

fn DropletPowerOn(creds: DOCredentials, id: i32) -> DOAction
fn DropletPowerOff(creds: DOCredentials, id: i32) -> DOAction
fn DropletReboot(creds: DOCredentials, id: i32) -> DOAction
fn DropletShutdown(creds: DOCredentials, id: i32) -> DOAction
fn DropletSnapshot(creds: DOCredentials, id: i32, snapshotName: ptr) -> DOAction
fn DropletResize(creds: DOCredentials, id: i32, newSize: ptr, resizeDisk: bool) -> DOAction
fn DropletRebuild(creds: DOCredentials, id: i32, image: ptr) -> DOAction

# Tags:
fn DropletTag(creds: DOCredentials, id: i32, tag: ptr) -> i32
fn DropletUntag(creds: DOCredentials, id: i32, tag: ptr) -> i32

# Snapshots:
fn DropletSnapshotList(creds: DOCredentials, id: i32) -> ptr
fn DropletBackupList(creds: DOCredentials, id: i32) -> ptr

# SSH-Keys:
struct DOSSHKey {
    id:          i32
    name:        ptr
    fingerprint: ptr
    publicKey:   ptr
}

fn SSHKeyCreate(creds: DOCredentials, name: ptr, publicKey: ptr) -> DOSSHKey
fn SSHKeyDelete(creds: DOCredentials, id: i32) -> i32
fn SSHKeyList(creds: DOCredentials) -> ptr

# Größen und Images:
fn SizeList(creds: DOCredentials) -> ptr           # alle Droplet-Sizes
fn ImageList(creds: DOCredentials) -> ptr          # alle Images
fn ImageListDistributions(creds: DOCredentials) -> ptr
fn ImageGet(creds: DOCredentials, slug: ptr) -> ptr
```

**Dateien:**
- `std/cloud/do/droplets.lyu` (neu)

**Akzeptanzkriterien:**
- `DropletCreate` + `DropletWait` → Droplet im Status "active"
- `DropletGetIP` gibt korrekte öffentliche IPv4 zurück
- `DropletSnapshot` + `DropletActionWait` → Snapshot im Account sichtbar
- `DropletList` paginiert korrekt bei > 20 Droplets

---

### WP-DO-04 — Spaces (S3-kompatibeler Objektspeicher) ⬜

**Ziel:** `std/cloud/do/spaces.lyu` — DigitalOcean Spaces auf Basis von `std/cloud/s3.lyu`, angepasster Endpoint.

**Zu implementieren:**

DO Spaces ist 100% S3-API-kompatibel. Der Transport-Layer wird direkt von `std/cloud/s3.lyu` übernommen (WP-S3), nur Endpoint und Credential-Quelle werden angepasst.

```lyx
struct SpacesConn {
    s3:     S3Conn    # intern: std/cloud/s3.lyu S3Conn
    region: ptr       # "fra1", "nyc3", ...
    bucket: ptr       # aktueller Default-Bucket
}

fn SpacesConnect(creds: DOCredentials, region: ptr) -> SpacesConn
# Baut S3Conn mit:
#   endpoint = region + ".digitaloceanspaces.com"
#   accessKey = creds.spacesKey
#   secretKey = creds.spacesSecret
#   region    = region (Spaces akzeptiert beliebigen Region-String)

fn SpacesDisconnect(c: SpacesConn)

# Bucket-Verwaltung:
fn SpacesBucketCreate(c: SpacesConn, bucket: ptr, acl: ptr) -> i32
# acl: "private" | "public-read"
fn SpacesBucketDelete(c: SpacesConn, bucket: ptr) -> i32
fn SpacesBucketList(c: SpacesConn) -> ptr           # → Bucket-Namen[]
fn SpacesBucketExists(c: SpacesConn, bucket: ptr) -> bool

# Objekte:
fn SpacesUpload(c: SpacesConn, bucket: ptr, key: ptr,
                data: ptr, dataLen: i32) -> i32
fn SpacesUploadPublic(c: SpacesConn, bucket: ptr, key: ptr,
                      data: ptr, dataLen: i32) -> i32
# Setzt ACL: public-read → öffentlich abrufbar
fn SpacesDownload(c: SpacesConn, bucket: ptr, key: ptr) -> DOResponse
fn SpacesDelete(c: SpacesConn, bucket: ptr, key: ptr) -> i32
fn SpacesExists(c: SpacesConn, bucket: ptr, key: ptr) -> bool
fn SpacesList(c: SpacesConn, bucket: ptr, prefix: ptr) -> ptr
fn SpacesGetMeta(c: SpacesConn, bucket: ptr, key: ptr) -> ptr
fn SpacesCopy(c: SpacesConn,
              srcBucket: ptr, srcKey: ptr,
              dstBucket: ptr, dstKey: ptr) -> i32

# CDN-URL:
fn SpacesCDNURL(region: ptr, bucket: ptr, key: ptr) -> ptr
# → "https://<bucket>.<region>.cdn.digitaloceanspaces.com/<key>"
fn SpacesPublicURL(region: ptr, bucket: ptr, key: ptr) -> ptr
# → "https://<bucket>.<region>.digitaloceanspaces.com/<key>"

# Presigned URLs (Wiederverwendung von S3-SigV4):
fn SpacesPresignedURL(c: SpacesConn, bucket: ptr, key: ptr,
                      method: ptr, expirySeconds: i32) -> ptr

# CDN-Endpunkte über DO API verwalten (REST, nicht S3):
fn SpacesCDNCreate(creds: DOCredentials, origin: ptr, ttl: i32) -> ptr
# POST /v2/cdn/endpoints
# origin = "<bucket>.<region>.digitaloceanspaces.com"
fn SpacesCDNList(creds: DOCredentials) -> ptr
fn SpacesCDNDelete(creds: DOCredentials, cdnId: ptr) -> i32
fn SpacesCDNFlush(creds: DOCredentials, cdnId: ptr, files: ptr, count: i32) -> i32
# POST /v2/cdn/endpoints/{id}/cache
```

**Dateien:**
- `std/cloud/do/spaces.lyu` (neu)
- Erfordert: `std/cloud/s3.lyu` (WP-S3-01 bis WP-S3-04)

**Akzeptanzkriterien:**
- `SpacesUpload` + `SpacesDownload` Round-Trip mit Binärdaten
- `SpacesUploadPublic` → Datei über CDN-URL abrufbar
- `SpacesPresignedURL` erzeugt gültige URL (1 Stunde)
- `SpacesCDNFlush` invalidiert Cache für bestimmte Pfade

---

### WP-DO-05 — Managed Databases ⬜

**Ziel:** `std/cloud/do/databases.lyu` — Verwaltung von DO Managed Databases (PostgreSQL, MySQL, Redis, MongoDB, Kafka, OpenSearch).

**Zu implementieren:**

```lyx
# Datenbank-Engines:
const DO_DB_POSTGRES   = "pg"
const DO_DB_MYSQL      = "mysql"
const DO_DB_REDIS      = "redis"
const DO_DB_MONGODB    = "mongodb"
const DO_DB_KAFKA      = "kafka"
const DO_DB_OPENSEARCH = "opensearch"

struct DODatabase {
    id:          ptr    # UUID
    name:        ptr
    engine:      ptr    # "pg", "mysql", ...
    version:     ptr    # "15", "8.0", ...
    status:      ptr    # "creating", "online", "migrating"
    region:      ptr
    size:        ptr    # "db-s-1vcpu-1gb"
    numNodes:    i32
    host:        ptr    # primärer Host
    port:        i32
    dbUser:      ptr    # Default-User
    dbPassword:  ptr    # Default-Passwort
    dbName:      ptr    # Default-Datenbank
    sslCert:     ptr    # CA-Zertifikat (PEM)
    created:     ptr
    maintenanceWindow: ptr
}

fn DODatabaseFree(db: DODatabase)

# Cluster-Verwaltung:
fn DatabaseCreate(creds: DOCredentials,
                  name: ptr, engine: ptr, version: ptr,
                  region: ptr, size: ptr, numNodes: i32) -> DODatabase
# POST /v2/databases

fn DatabaseDelete(creds: DOCredentials, id: ptr) -> i32
fn DatabaseGet(creds: DOCredentials, id: ptr) -> DODatabase
fn DatabaseList(creds: DOCredentials) -> ptr    # → DODatabase[]
fn DatabaseWait(creds: DOCredentials, id: ptr) -> DODatabase
# Polling bis status == "online", max 600s

fn DatabaseResize(creds: DOCredentials, id: ptr,
                  size: ptr, numNodes: i32) -> i32
fn DatabaseMigrate(creds: DOCredentials, id: ptr, region: ptr) -> i32

# Connection Details:
struct DODBConnection {
    uri:       ptr    # "postgresql://user:pass@host:port/db?sslmode=require"
    database:  ptr
    host:      ptr
    port:      i32
    user:      ptr
    password:  ptr
    sslMode:   ptr    # "require"
}

fn DatabaseGetConnection(creds: DOCredentials, id: ptr) -> DODBConnection
fn DatabaseGetConnectionPool(creds: DOCredentials, id: ptr, poolName: ptr) -> DODBConnection
fn DODBConnectionFree(c: DODBConnection)

# User-Verwaltung:
struct DODBUser {
    name:     ptr
    role:     ptr    # "primary", "normal"
    password: ptr
}

fn DatabaseUserCreate(creds: DOCredentials, id: ptr, username: ptr) -> DODBUser
fn DatabaseUserDelete(creds: DOCredentials, id: ptr, username: ptr) -> i32
fn DatabaseUserList(creds: DOCredentials, id: ptr) -> ptr
fn DatabaseUserResetPassword(creds: DOCredentials, id: ptr, username: ptr) -> DODBUser

# Datenbank-Verwaltung (innerhalb Cluster):
fn DatabaseDBCreate(creds: DOCredentials, id: ptr, dbName: ptr) -> i32
fn DatabaseDBDelete(creds: DOCredentials, id: ptr, dbName: ptr) -> i32
fn DatabaseDBList(creds: DOCredentials, id: ptr) -> ptr   # → Namen[]

# Connection Pools (PostgreSQL):
struct DODBPool {
    name:     ptr
    mode:     ptr    # "session", "transaction", "statement"
    size:     i32
    db:       ptr
    user:     ptr
    host:     ptr
    port:     i32
    password: ptr
    uri:      ptr
}

fn DatabasePoolCreate(creds: DOCredentials, id: ptr,
                      name: ptr, mode: ptr, size: i32,
                      db: ptr, user: ptr) -> DODBPool
fn DatabasePoolDelete(creds: DOCredentials, id: ptr, name: ptr) -> i32
fn DatabasePoolList(creds: DOCredentials, id: ptr) -> ptr

# Firewall-Regeln:
fn DatabaseFirewallAdd(creds: DOCredentials, id: ptr,
                       ruleType: ptr, value: ptr) -> i32
# ruleType: "ip_addr", "droplet", "tag", "k8s", "app"
fn DatabaseFirewallList(creds: DOCredentials, id: ptr) -> ptr
fn DatabaseFirewallSet(creds: DOCredentials, id: ptr, rules: ptr, count: i32) -> i32

# Backups:
fn DatabaseBackupList(creds: DOCredentials, id: ptr) -> ptr
fn DatabaseRestore(creds: DOCredentials, name: ptr,
                   engine: ptr, backupCreatedAt: ptr) -> DODatabase

# Read-Only Replicas:
fn DatabaseReplicaCreate(creds: DOCredentials, id: ptr,
                         name: ptr, size: ptr, region: ptr) -> DODatabase
fn DatabaseReplicaList(creds: DOCredentials, id: ptr) -> ptr
fn DatabaseReplicaDelete(creds: DOCredentials, id: ptr, replicaName: ptr) -> i32
fn DatabaseReplicaPromote(creds: DOCredentials, id: ptr, replicaName: ptr) -> i32
```

**Dateien:**
- `std/cloud/do/databases.lyu` (neu)

**Akzeptanzkriterien:**
- `DatabaseCreate` + `DatabaseWait` → PostgreSQL-Cluster im Status "online"
- `DatabaseGetConnection` liefert gültige URI mit SSL-Parametern
- `DatabaseUserCreate` → neuer User kann sich verbinden (via `std/db/postgres.lyu`)
- `DatabasePoolCreate` erstellt PgBouncer-Pool (Mode: transaction)

---

### WP-DO-06 — Kubernetes (DOKS) ⬜

**Ziel:** `std/cloud/do/kubernetes.lyu` — DigitalOcean Kubernetes Service: Cluster erstellen, verwalten, kubeconfig laden.

**Zu implementieren:**

```lyx
struct DOK8sCluster {
    id:          ptr    # UUID
    name:        ptr
    region:      ptr
    version:     ptr    # "1.29.1-do.0"
    status:      ptr    # "provisioning", "running", "degraded", "error", "deleted"
    endpoint:    ptr    # HTTPS API-Endpunkt
    nodePools:   ptr    # DOK8sNodePool[]
    ipv4:        ptr    # öffentliche IP des Load Balancers
    clusterSubnet: ptr
    serviceSubnet: ptr
    created:     ptr
    autoUpgrade: bool
    surgeUpgrade: bool
}

struct DOK8sNodePool {
    id:        ptr
    name:      ptr
    size:      ptr    # "s-2vcpu-4gb"
    count:     i32
    autoScale: bool
    minNodes:  i32
    maxNodes:  i32
    tags:      ptr
    nodes:     ptr    # DOK8sNode[]
}

struct DOK8sNode {
    id:      ptr
    name:    ptr
    status:  ptr    # "provisioning", "running", "draining", "deleting"
    dropletId: ptr
    created: ptr
}

fn DOK8sClusterFree(c: DOK8sCluster)

# Cluster-Verwaltung:
fn K8sClusterCreate(creds: DOCredentials,
                    name: ptr, region: ptr, version: ptr,
                    nodeSize: ptr, nodeCount: i32) -> DOK8sCluster
# POST /v2/kubernetes/clusters

fn K8sClusterDelete(creds: DOCredentials, id: ptr) -> i32
fn K8sClusterGet(creds: DOCredentials, id: ptr) -> DOK8sCluster
fn K8sClusterList(creds: DOCredentials) -> ptr
fn K8sClusterWait(creds: DOCredentials, id: ptr) -> DOK8sCluster
# Polling bis status == "running", max 600s

fn K8sClusterUpgrade(creds: DOCredentials, id: ptr, version: ptr) -> i32
fn K8sClusterVersionsAvailable(creds: DOCredentials, id: ptr) -> ptr

# kubeconfig:
fn K8sKubeconfig(creds: DOCredentials, id: ptr) -> ptr
# GET /v2/kubernetes/clusters/{id}/kubeconfig
# → YAML (kubeconfig-Datei-Inhalt)
fn K8sKubeconfigSave(creds: DOCredentials, id: ptr, path: ptr) -> i32
# Schreibt nach path (default: ~/.kube/config)

# Node Pools:
fn K8sNodePoolCreate(creds: DOCredentials, clusterId: ptr,
                     name: ptr, size: ptr, count: i32) -> DOK8sNodePool
fn K8sNodePoolUpdate(creds: DOCredentials, clusterId: ptr, poolId: ptr,
                     count: i32, autoScale: bool, min: i32, max: i32) -> DOK8sNodePool
fn K8sNodePoolDelete(creds: DOCredentials, clusterId: ptr, poolId: ptr) -> i32
fn K8sNodePoolList(creds: DOCredentials, clusterId: ptr) -> ptr

# Node-Operationen:
fn K8sNodeRecycle(creds: DOCredentials, clusterId: ptr,
                  poolId: ptr, nodeId: ptr) -> i32
fn K8sNodeDelete(creds: DOCredentials, clusterId: ptr,
                 poolId: ptr, nodeId: ptr) -> i32

# Verfügbare Versionen und Größen:
fn K8sVersionList(creds: DOCredentials) -> ptr
fn K8sNodeSizeList(creds: DOCredentials) -> ptr
fn K8sRegionList(creds: DOCredentials) -> ptr
```

**Dateien:**
- `std/cloud/do/kubernetes.lyu` (neu)

**Akzeptanzkriterien:**
- `K8sClusterCreate` + `K8sClusterWait` → Cluster im Status "running"
- `K8sKubeconfigSave` schreibt gültige kubeconfig (testbar mit `kubectl --kubeconfig`)
- `K8sNodePoolCreate` fügt Worker-Nodes hinzu, sichtbar in Cluster
- kubeconfig enthält korrektes CA-Zertifikat und Bearer-Token

---

### WP-DO-07 — Networking (DNS, Load Balancer, VPC, Firewall, Floating IPs) ⬜

**Ziel:** `std/cloud/do/networking.lyu` — Vollständige Netzwerk-Verwaltung für DO-Infrastruktur.

**Zu implementieren:**

DNS:
```lyx
struct DODomain {
    name:     ptr
    ttl:      i32
    zoneFile: ptr
}

struct DODNSRecord {
    id:       i32
    type:     ptr    # "A","AAAA","CNAME","MX","TXT","NS","SRV","CAA"
    name:     ptr    # "@", "www", "mail"
    data:     ptr    # IP, Ziel-Host, TXT-Inhalt
    priority: i32    # MX/SRV
    port:     i32    # SRV
    ttl:      i32
    weight:   i32    # SRV
    flags:    i32    # CAA
    tag:      ptr    # CAA
}

fn DomainCreate(creds: DOCredentials, name: ptr, ipAddress: ptr) -> DODomain
fn DomainDelete(creds: DOCredentials, name: ptr) -> i32
fn DomainGet(creds: DOCredentials, name: ptr) -> DODomain
fn DomainList(creds: DOCredentials) -> ptr

fn DomainRecordCreate(creds: DOCredentials, domain: ptr,
                      recType: ptr, name: ptr,
                      data: ptr, ttl: i32) -> DODNSRecord
fn DomainRecordUpdate(creds: DOCredentials, domain: ptr,
                      id: i32, data: ptr, ttl: i32) -> DODNSRecord
fn DomainRecordDelete(creds: DOCredentials, domain: ptr, id: i32) -> i32
fn DomainRecordList(creds: DOCredentials, domain: ptr) -> ptr
fn DomainRecordGet(creds: DOCredentials, domain: ptr, id: i32) -> DODNSRecord
```

Load Balancer:
```lyx
struct DOLoadBalancer {
    id:        ptr
    name:      ptr
    ip:        ptr
    status:    ptr    # "new", "active", "errored"
    region:    ptr
    algorithm: ptr    # "round_robin", "least_connections"
    dropletIds: ptr   # i32[]
    tag:       ptr
}

struct DOForwardingRule {
    entryProtocol:  ptr    # "http","https","tcp","udp"
    entryPort:      i32
    targetProtocol: ptr
    targetPort:     i32
    certificateId:  ptr    # für HTTPS
    tlsPassthrough: bool
}

struct DOHealthCheck {
    protocol:         ptr    # "http","https","tcp"
    port:             i32
    path:             ptr    # "/health"
    checkIntervalSec: i32
    responseTimeout:  i32
    unhealthyThreshold: i32
    healthyThreshold:   i32
}

fn LBCreate(creds: DOCredentials,
            name: ptr, region: ptr,
            rules: ptr, rulesCount: i32,
            dropletIds: ptr, dropletCount: i32) -> DOLoadBalancer
fn LBDelete(creds: DOCredentials, id: ptr) -> i32
fn LBGet(creds: DOCredentials, id: ptr) -> DOLoadBalancer
fn LBList(creds: DOCredentials) -> ptr
fn LBAddDroplets(creds: DOCredentials, id: ptr, dropletIds: ptr, count: i32) -> i32
fn LBRemoveDroplets(creds: DOCredentials, id: ptr, dropletIds: ptr, count: i32) -> i32
fn LBSetHealthCheck(creds: DOCredentials, id: ptr, hc: DOHealthCheck) -> i32
```

Floating IPs:
```lyx
struct DOFloatingIP {
    ip:       ptr
    region:   ptr
    dropletId: i32   # 0 = nicht zugewiesen
}

fn FloatingIPCreate(creds: DOCredentials, region: ptr) -> DOFloatingIP
fn FloatingIPDelete(creds: DOCredentials, ip: ptr) -> i32
fn FloatingIPAssign(creds: DOCredentials, ip: ptr, dropletId: i32) -> DOAction
fn FloatingIPUnassign(creds: DOCredentials, ip: ptr) -> DOAction
fn FloatingIPList(creds: DOCredentials) -> ptr
```

VPC:
```lyx
struct DOVPC {
    id:          ptr
    name:        ptr
    region:      ptr
    ipRange:     ptr    # "10.10.10.0/24"
    isDefault:   bool
    created:     ptr
}

fn VPCCreate(creds: DOCredentials, name: ptr, region: ptr, ipRange: ptr) -> DOVPC
fn VPCDelete(creds: DOCredentials, id: ptr) -> i32
fn VPCGet(creds: DOCredentials, id: ptr) -> DOVPC
fn VPCList(creds: DOCredentials) -> ptr
fn VPCMemberList(creds: DOCredentials, id: ptr) -> ptr  # Droplets, DBs, K8s, LBs
```

Firewall:
```lyx
struct DOFirewallRule {
    protocol:  ptr    # "tcp","udp","icmp"
    ports:     ptr    # "80", "8000-9000", "0"=all
    sources:   ptr    # JSON: addresses[], droplet_ids[], tags[], load_balancer_uids[]
    destinations: ptr
}

struct DOFirewall {
    id:          ptr
    name:        ptr
    status:      ptr    # "waiting", "succeeded", "failed"
    inboundRules:  ptr  # DOFirewallRule[]
    outboundRules: ptr
    dropletIds:    ptr
    tags:          ptr
}

fn FirewallCreate(creds: DOCredentials, name: ptr,
                  inbound: ptr, inCount: i32,
                  outbound: ptr, outCount: i32) -> DOFirewall
fn FirewallDelete(creds: DOCredentials, id: ptr) -> i32
fn FirewallGet(creds: DOCredentials, id: ptr) -> DOFirewall
fn FirewallList(creds: DOCredentials) -> ptr
fn FirewallAddDroplets(creds: DOCredentials, id: ptr, dropletIds: ptr, count: i32) -> i32
fn FirewallRemoveDroplets(creds: DOCredentials, id: ptr, dropletIds: ptr, count: i32) -> i32
fn FirewallAddRules(creds: DOCredentials, id: ptr, rules: ptr, isInbound: bool) -> i32
fn FirewallRemoveRules(creds: DOCredentials, id: ptr, rules: ptr, isInbound: bool) -> i32
```

**Dateien:**
- `std/cloud/do/networking.lyu` (neu)

**Akzeptanzkriterien:**
- `DomainRecordCreate` → A-Record in DO-DNS sichtbar
- `LBCreate` + Droplets → HTTP-Traffic wird verteilt
- `FloatingIPAssign` → IP zeigt auf Droplet, Ping möglich
- `FirewallCreate` mit Port-80-Regel blockiert anderen Traffic

---

### WP-DO-08 — Block Storage (Volumes) & Snapshots ⬜

**Ziel:** `std/cloud/do/volumes.lyu` — Persistente Block-Storage-Volumes und Snapshot-Verwaltung.

**Zu implementieren:**

```lyx
struct DOVolume {
    id:          ptr
    name:        ptr
    region:      ptr
    sizeGB:      i32
    status:      ptr    # "creating", "available", "attached", "deleting"
    dropletIds:  ptr    # i32[] (meist max. 1)
    filesystemType: ptr  # "ext4", "xfs"
    filesystemLabel: ptr
    created:     ptr
}

fn DOVolumeFree(v: DOVolume)

# Volume-Verwaltung:
fn VolumeCreate(creds: DOCredentials,
                name: ptr, region: ptr,
                sizeGB: i32, filesystemType: ptr) -> DOVolume
# POST /v2/volumes

fn VolumeDelete(creds: DOCredentials, id: ptr) -> i32
fn VolumeGet(creds: DOCredentials, id: ptr) -> DOVolume
fn VolumeList(creds: DOCredentials) -> ptr
fn VolumeResize(creds: DOCredentials, id: ptr, newSizeGB: i32) -> DOAction

# Attachment:
fn VolumeAttach(creds: DOCredentials, id: ptr, dropletId: i32) -> DOAction
fn VolumeDetach(creds: DOCredentials, id: ptr, dropletId: i32) -> DOAction
fn VolumeWaitDetached(creds: DOCredentials, id: ptr) -> DOVolume
fn VolumeWaitAttached(creds: DOCredentials, id: ptr) -> DOVolume

# Snapshots von Volumes:
fn VolumeSnapshotCreate(creds: DOCredentials, id: ptr, name: ptr) -> ptr
fn VolumeSnapshotList(creds: DOCredentials, id: ptr) -> ptr

# Alle Snapshots (Droplets + Volumes):
struct DOSnapshot {
    id:           ptr
    name:         ptr
    createdAt:    ptr
    regions:      ptr    # string[]
    resourceId:   ptr
    resourceType: ptr    # "droplet", "volume"
    minDiskSize:  i32
    sizeGB:       f64
}

fn SnapshotList(creds: DOCredentials) -> ptr
fn SnapshotListDroplets(creds: DOCredentials) -> ptr
fn SnapshotListVolumes(creds: DOCredentials) -> ptr
fn SnapshotGet(creds: DOCredentials, id: ptr) -> DOSnapshot
fn SnapshotDelete(creds: DOCredentials, id: ptr) -> i32
fn SnapshotTransfer(creds: DOCredentials, id: ptr, region: ptr) -> DOAction
```

**Dateien:**
- `std/cloud/do/volumes.lyu` (neu)

**Akzeptanzkriterien:**
- `VolumeCreate` + `VolumeAttach` + `VolumeWaitAttached` → Volume auf Droplet gemountet
- `VolumeResize` vergrößert Volume ohne Datenverlust
- `VolumeSnapshotCreate` → Snapshot in Account sichtbar
- `SnapshotDelete` entfernt alten Snapshot

---

### WP-DO-09 — App Platform ⬜

**Ziel:** `std/cloud/do/apps.lyu` — DigitalOcean App Platform: Apps deployen, verwalten, Logs abrufen.

**Zu implementieren:**

```lyx
struct DOApp {
    id:          ptr
    spec:        ptr    # JSON App-Spec
    defaultIngress: ptr  # https://<slug>.ondigitalocean.app
    liveURL:     ptr
    status:      ptr    # "pending", "deploying", "running", "error"
    region:      ptr
    created:     ptr
    updated:     ptr
}

struct DODeployment {
    id:          ptr
    appId:       ptr
    phase:       ptr    # "building", "deploying", "active", "error"
    progress:    ptr    # JSON: steps
    created:     ptr
    updated:     ptr
}

# App-Verwaltung:
fn AppCreate(creds: DOCredentials, spec: ptr, specLen: i32) -> DOApp
# POST /v2/apps  Body: {"spec": {...}}
fn AppDelete(creds: DOCredentials, id: ptr) -> i32
fn AppGet(creds: DOCredentials, id: ptr) -> DOApp
fn AppList(creds: DOCredentials) -> ptr
fn AppUpdate(creds: DOCredentials, id: ptr, spec: ptr, specLen: i32) -> DOApp

# App-Spec-Builder (JSON-Hilfsfunktionen):
fn AppSpecNew(name: ptr, region: ptr) -> ptr
fn AppSpecAddService(spec: ptr, name: ptr, image: ptr, port: i32, instanceSize: ptr) -> ptr
fn AppSpecAddStaticSite(spec: ptr, name: ptr, repoURL: ptr, branch: ptr, buildCmd: ptr) -> ptr
fn AppSpecAddJob(spec: ptr, name: ptr, image: ptr, runCmd: ptr) -> ptr
fn AppSpecAddEnvVar(spec: ptr, componentName: ptr, key: ptr, val: ptr, scope: ptr) -> ptr
# scope: "RUN_TIME", "BUILD_TIME", "RUN_AND_BUILD_TIME"

# Deployments:
fn AppDeploy(creds: DOCredentials, appId: ptr, forceRebuild: bool) -> DODeployment
fn AppDeploymentGet(creds: DOCredentials, appId: ptr, deployId: ptr) -> DODeployment
fn AppDeploymentList(creds: DOCredentials, appId: ptr) -> ptr
fn AppDeploymentWait(creds: DOCredentials, appId: ptr, deployId: ptr) -> DODeployment
# Polling bis phase == "active" oder "error", max 600s

fn AppDeploymentCancel(creds: DOCredentials, appId: ptr, deployId: ptr) -> DODeployment

# Logs:
fn AppLogs(creds: DOCredentials, appId: ptr,
           component: ptr, logType: ptr) -> ptr
# GET /v2/apps/{id}/logs?component_name=...&type=BUILD|DEPLOY|RUN
# → Log-URL (live streaming via SSE) + historische Logs

fn AppLogsTail(creds: DOCredentials, appId: ptr,
               component: ptr, lines: i32) -> ptr
# Polling der letzten N Zeilen

# Instanzen & Tier:
fn AppInstanceSizeList(creds: DOCredentials) -> ptr
fn AppRegionList(creds: DOCredentials) -> ptr
```

**Dateien:**
- `std/cloud/do/apps.lyu` (neu)

**Akzeptanzkriterien:**
- `AppCreate` + `AppDeploymentWait` → App im Status "active", URL erreichbar
- `AppLogs` gibt Build- und Runtime-Logs zurück
- `AppSpecBuilder` erzeugt validen JSON-Spec für einfachen Web-Service
- `AppUpdate` triggert neues Deployment

---

### WP-DO-10 — Container Registry ⬜

**Ziel:** `std/cloud/do/registry.lyu` — DigitalOcean Container Registry: Images verwalten, Credentials für Kubernetes erzeugen.

**Zu implementieren:**

```lyx
struct DORegistry {
    name:          ptr    # Registry-Name (global eindeutig)
    endpoint:      ptr    # "registry.digitalocean.com/<name>"
    storageUsageGB: f64
    subscriptionTier: ptr  # "starter", "basic", "professional"
    created:       ptr
}

struct DORepository {
    registryName: ptr
    name:         ptr
    tagCount:     i32
    manifestCount: i32
    latestTag:    ptr
}

struct DOTag {
    registryName: ptr
    repository:   ptr
    tag:          ptr
    manifestDigest: ptr
    compressedSizeMB: f64
    sizeBytes:    i64
    updatedAt:    ptr
}

# Registry-Verwaltung:
fn RegistryCreate(creds: DOCredentials, name: ptr, tier: ptr) -> DORegistry
fn RegistryDelete(creds: DOCredentials) -> i32
fn RegistryGet(creds: DOCredentials) -> DORegistry

# Docker-Login-Credentials:
fn RegistryDockerCredentials(creds: DOCredentials, readWrite: bool) -> ptr
# GET /v2/registry/docker-credentials?read_write=true
# → Docker config.json-Inhalt (für docker login)
fn RegistryDockerCredentialsSave(creds: DOCredentials, path: ptr) -> i32
# Schreibt nach ~/.docker/config.json

# K8s-Integration:
fn RegistryK8sSecret(creds: DOCredentials) -> ptr
# GET /v2/registry/docker-credentials?kubernetes_format=true
# → Kubernetes Secret YAML für imagePullSecrets

# Repositories und Tags:
fn RegistryRepositoryList(creds: DOCredentials) -> ptr
fn RegistryTagList(creds: DOCredentials, repo: ptr) -> ptr
fn RegistryTagDelete(creds: DOCredentials, repo: ptr, tag: ptr) -> i32
fn RegistryTagDeleteBatch(creds: DOCredentials, repo: ptr,
                          manifests: ptr, count: i32) -> i32

# Garbage Collection:
fn RegistryGCRun(creds: DOCredentials) -> ptr
# POST /v2/registry/garbage-collection
fn RegistryGCGet(creds: DOCredentials, gcUUID: ptr) -> ptr
fn RegistryGCList(creds: DOCredentials) -> ptr

# Endpoint:
fn RegistryEndpoint(creds: DOCredentials) -> ptr
# → "registry.digitalocean.com/<name>"
```

**Dateien:**
- `std/cloud/do/registry.lyu` (neu)

**Akzeptanzkriterien:**
- `RegistryDockerCredentialsSave` → `docker pull registry.digitalocean.com/<name>/image:tag` funktioniert
- `RegistryTagList` listet alle verfügbaren Tags eines Repositories
- `RegistryK8sSecret` erzeugt valides Kubernetes-Secret-YAML
- `RegistryGCRun` löst Garbage Collection aus

---

### WP-DO-11 — Functions (Serverless) ⬜

**Ziel:** `std/cloud/do/functions.lyu` — DigitalOcean Functions (basiert auf Apache OpenWhisk): Namespaces, Packages, Functions verwalten und aufrufen.

**Zu implementieren:**

```lyx
struct DOFNamespace {
    uuid:     ptr
    label:    ptr
    region:   ptr
    apiHost:  ptr    # "https://faas-fra1-xxxx.doserverless.co"
    created:  ptr
}

struct DOFFunction {
    namespaceName: ptr
    packageName:   ptr
    name:          ptr
    runtime:       ptr    # "nodejs:18", "python:3.11", "go:1.21", "php:8.2"
    url:           ptr    # HTTP-Trigger-URL
    limits: struct {
        timeout: i32   # ms
        memory:  i32   # MB
        logs:    i32   # MB
    }
}

# Namespace-Verwaltung:
fn FNamespaceCreate(creds: DOCredentials, label: ptr, region: ptr) -> DOFNamespace
fn FNamespaceDelete(creds: DOCredentials, uuid: ptr) -> i32
fn FNamespaceGet(creds: DOCredentials, uuid: ptr) -> DOFNamespace
fn FNamespaceList(creds: DOCredentials) -> ptr

# Functions aufrufen (HTTP-Trigger):
fn FInvoke(creds: DOCredentials, nsUUID: ptr,
           packageName: ptr, fnName: ptr,
           body: ptr, bodyLen: i32) -> DOResponse
# POST <apiHost>/api/v1/web/<ns-uuid>/default/<pkg>/<fn>
# Header: Authorization: Basic base64(auth-key)

fn FInvokeAsync(creds: DOCredentials, nsUUID: ptr,
                packageName: ptr, fnName: ptr,
                body: ptr, bodyLen: i32) -> ptr  # → Activation ID

fn FInvokeRaw(url: ptr, apiKey: ptr,
              body: ptr, bodyLen: i32) -> DOResponse
# Direkt an HTTP-Trigger-URL

# Activation-Logs:
fn FActivationGet(creds: DOCredentials, nsUUID: ptr, activationId: ptr) -> ptr
fn FActivationList(creds: DOCredentials, nsUUID: ptr, limit: i32) -> ptr
fn FActivationLogs(creds: DOCredentials, nsUUID: ptr, activationId: ptr) -> ptr
```

**Dateien:**
- `std/cloud/do/functions.lyu` (neu)

**Akzeptanzkriterien:**
- `FInvoke` ruft HTTP-Trigger auf und gibt Response zurück
- `FActivationLogs` gibt stdout/stderr der Funktion zurück
- Namespace-Erstellung in korrekter Region
- Fehler bei ungültigem API-Key klar kommuniziert (401)

---

### WP-DO-12 — Monitoring & Alerts ⬜

**Ziel:** `std/cloud/do/monitoring.lyu` — Droplet-Metriken abrufen, Alert-Policies verwalten.

**Zu implementieren:**

```lyx
# Metriken-Abfrage:
const DO_METRIC_CPU          = "v1/insights/droplet/cpu"
const DO_METRIC_MEMORY       = "v1/insights/droplet/memory_utilization_percent"
const DO_METRIC_DISK_READ    = "v1/insights/droplet/disk_read"
const DO_METRIC_DISK_WRITE   = "v1/insights/droplet/disk_write"
const DO_METRIC_NET_IN       = "v1/insights/droplet/public_outbound_bandwidth"
const DO_METRIC_NET_OUT      = "v1/insights/droplet/public_inbound_bandwidth"
const DO_METRIC_LOAD_1       = "v1/insights/droplet/load_1"
const DO_METRIC_LOAD_5       = "v1/insights/droplet/load_5"
const DO_METRIC_LOAD_15      = "v1/insights/droplet/load_15"
const DO_METRIC_FS_SIZE      = "v1/insights/droplet/filesystem_size"
const DO_METRIC_FS_USED      = "v1/insights/droplet/filesystem_utilization_percent"

struct DOMetricResult {
    status: ptr    # "success"
    data:   struct {
        resultType: ptr    # "matrix"
        result: ptr        # Prometheus-Format: [{metric:{},values:[[ts,val],...]}]
    }
}

fn MetricQuery(creds: DOCredentials,
               metricType: ptr,
               hostId: ptr,
               start: i64, end: i64,    # Unix-TS
               step: i32) -> DOMetricResult
# GET /v2/monitoring/metrics/<type>
# ?host_id=<droplet-id>&start=<ts>&end=<ts>&step=60s

fn MetricQueryFree(r: DOMetricResult)

# Alert-Policies:
const DO_ALERT_CPU      = "v1/insights/droplet/cpu"
const DO_ALERT_MEM      = "v1/insights/droplet/memory_utilization_percent"
const DO_ALERT_DISK     = "v1/insights/droplet/disk_utilization_percent"
const DO_ALERT_NET_IN   = "v1/insights/droplet/public_inbound_bandwidth"
const DO_ALERT_NET_OUT  = "v1/insights/droplet/public_outbound_bandwidth"
const DO_ALERT_LOAD_1   = "v1/insights/droplet/load_1"
const DO_ALERT_LOAD_5   = "v1/insights/droplet/load_5"

struct DOAlertPolicy {
    uuid:        ptr
    type:        ptr    # Metrik-Typ
    description: ptr
    compare:     ptr    # "GreaterThan" | "LessThan"
    value:       f64    # Schwellenwert
    window:      ptr    # "5m", "10m", "30m", "1h"
    entities:    ptr    # Droplet-IDs[] oder Tags[]
    tags:        ptr
    alerts:      struct {
        slack:  ptr    # Slack-Webhook-URL
        email:  ptr    # E-Mail-Adressen[]
    }
    enabled:     bool
}

fn AlertCreate(creds: DOCredentials,
               metricType: ptr, description: ptr,
               compare: ptr, value: f64, window: ptr,
               dropletIds: ptr, count: i32,
               emailTo: ptr, slackURL: ptr) -> DOAlertPolicy
fn AlertDelete(creds: DOCredentials, uuid: ptr) -> i32
fn AlertGet(creds: DOCredentials, uuid: ptr) -> DOAlertPolicy
fn AlertList(creds: DOCredentials) -> ptr
fn AlertUpdate(creds: DOCredentials, uuid: ptr, policy: DOAlertPolicy) -> DOAlertPolicy
fn AlertEnable(creds: DOCredentials, uuid: ptr) -> i32
fn AlertDisable(creds: DOCredentials, uuid: ptr) -> i32

# Uptime-Checks:
struct DOUptimeCheck {
    id:       ptr
    name:     ptr
    type:     ptr    # "https", "http", "ping"
    target:   ptr    # URL oder IP
    regions:  ptr    # string[] Prüfort
    enabled:  bool
}

fn UptimeCreate(creds: DOCredentials, name: ptr, checkType: ptr,
                target: ptr) -> DOUptimeCheck
fn UptimeDelete(creds: DOCredentials, id: ptr) -> i32
fn UptimeList(creds: DOCredentials) -> ptr
fn UptimeStateGet(creds: DOCredentials, id: ptr) -> ptr  # aktueller Status
```

**Dateien:**
- `std/cloud/do/monitoring.lyu` (neu)

**Akzeptanzkriterien:**
- `MetricQuery` liefert CPU-Verlauf eines Droplets der letzten Stunde
- `AlertCreate` → Alert erscheint in DO-Console
- Alert feuert bei CPU > 90% (testbar mit `stress --cpu 4`)
- `UptimeCreate` überwacht HTTPS-Endpunkt

---

### WP-DO-13 — `lyxdo` CLI ⬜

**Ziel:** `bin/lyxdo` — Kommandozeilen-Tool analog zu `doctl`, nutzt das Lyx DO SDK.

**Zu implementieren:**

```
lyxdo <command> [subcommand] [flags]

Globale Flags:
  --token       API-Token (überschreibt DIGITALOCEAN_TOKEN)
  --config      Konfig-Datei (default: ~/.config/lyxdo/config.json)
  --format      Ausgabeformat: json|text|table (default: text)
  --region      Standard-Region (default: fra1)
  --no-header   Tabellenüberschriften unterdrücken

Befehle:

  auth
    init                         → Token interaktiv eingeben + speichern
    list                         → zeigt gespeicherte Contexts
    switch <context>
    token                        → gibt aktuellen Token aus (für Skripte)

  account
    get                          → Konto-Info
    ratelimit                    → verbleibende API-Requests

  compute droplet
    list [--tag <tag>]
    get <id>
    create --name <n> --region <r> --size <s> --image <i> [--ssh-keys <id1,id2>]
    delete <id> [--force]
    start <id>
    stop <id>
    reboot <id>
    snapshot <id> --snapshot-name <n>
    resize <id> --size <s> [--resize-disk]
    ip <id>                      → nur IP ausgeben

  compute ssh-key
    list
    create --name <n> --public-key-file <path>
    delete <id>

  compute image
    list [--type distribution]

  compute size
    list

  spaces
    ls [<bucket>[/<prefix>]]     → Buckets oder Objekte
    cp <src> spaces://<b>/<key>  → hochladen
    cp spaces://<b>/<key> <dst>  → herunterladen
    rm spaces://<bucket>/<key>
    mb <bucket> [--acl public]   → Bucket erstellen
    rb <bucket>                  → Bucket löschen
    url <bucket>/<key>           → CDN-URL ausgeben
    presign <bucket>/<key> [--ttl 3600]

  database
    list
    get <id>
    create --name <n> --engine <e> --version <v> --region <r> --size <s>
    delete <id>
    connection <id>              → URI ausgeben
    user list <id>
    user create <id> <username>
    db list <id>
    pool list <id>
    pool create <id> --name <n> --mode transaction --size 10 --db <db> --user <u>
    firewall <id> add --type ip_addr --value 1.2.3.4
    replica list <id>
    replica create <id> --name <n> --region <r>

  kubernetes cluster
    list
    get <id>
    create --name <n> --region <r> --version <v> --node-size <s> --node-count <n>
    delete <id>
    kubeconfig save <id> [--output ~/.kube/config]
    versions                     → verfügbare K8s-Versionen

  kubernetes node-pool
    list <cluster-id>
    create <cluster-id> --name <n> --size <s> --count <n>
    update <cluster-id> <pool-id> --count <n>
    delete <cluster-id> <pool-id>

  networking domain
    list
    create <domain> --ip <ip>
    delete <domain>
    records list <domain>
    records create <domain> --type A --name www --data 1.2.3.4 --ttl 300
    records delete <domain> <record-id>

  networking load-balancer
    list
    get <id>
    create --name <n> --region <r> --droplet-ids <id1,id2>
    delete <id>
    add-droplets <id> --droplet-ids <id1,id2>

  networking floating-ip
    list
    create --region <r>
    assign <ip> --droplet-id <id>
    unassign <ip>
    delete <ip>

  networking vpc
    list
    create --name <n> --region <r> --ip-range 10.10.10.0/24
    delete <id>

  networking firewall
    list
    get <id>
    create --name <n>
    add-rules <id> --inbound-rule "protocol:tcp,ports:80,sources:0.0.0.0/0"
    add-droplets <id> --droplet-ids <id1,id2>

  volume
    list
    get <id>
    create --name <n> --region <r> --size 10
    delete <id>
    attach <id> --droplet-id <did>
    detach <id>
    snapshot <id> --snapshot-name <n>

  apps
    list
    get <id>
    create --spec spec.json
    delete <id>
    update <id> --spec spec.json
    deploy <id> [--force-rebuild]
    logs <id> [--component <n>] [--type RUN]
    deployments list <id>

  registry
    get
    docker-credentials [--read-write] [--save]
    repository list
    tag list <repo>
    tag delete <repo> <tag>
    garbage-collection run

  functions namespace
    list
    create --label <l> --region <r>
    delete <uuid>

  functions invoke <ns-uuid> <package>/<function> [--param '{"key":"val"}']

  monitoring
    metrics get <droplet-id> --metric cpu [--start -1h] [--end now]
    alert list
    alert create --type cpu --compare GreaterThan --value 80 --window 5m
                 --droplet-ids <id> --emails user@example.com
    alert delete <uuid>
    uptime list
    uptime create --name <n> --type https --target https://example.com

  secrets                        (Secret-Store via Managed Redis als Workaround)
    # Hinweis: DO hat keinen nativen Secret Manager.
    # Empfehlung: Vault, Infisical, oder Parameter in App-Env-Vars
```

**Dateien:**
- `bin/lyxdo.lyu` (neu) — CLI-Dispatcher
- `bin/lyxdo_compute.lyu` (neu)
- `bin/lyxdo_spaces.lyu` (neu)
- `bin/lyxdo_database.lyu` (neu)
- `bin/lyxdo_kubernetes.lyu` (neu)
- `bin/lyxdo_networking.lyu` (neu)
- `bin/lyxdo_apps.lyu` (neu)
- `bin/lyxdo_monitoring.lyu` (neu)
- `bin/lyxdo.lyx` (Binär)

**Akzeptanzkriterien:**
- `lyxdo auth init` speichert Token korrekt in `~/.config/lyxdo/config.json`
- `lyxdo compute droplet list --format table` gibt formatierte Tabelle aus
- `lyxdo spaces cp local.txt spaces://bucket/key` lädt Datei hoch
- `lyxdo --format json compute droplet list` gibt maschinenlesbares JSON
- `lyxdo database connection <id>` gibt URI direkt auf stdout (für Shell-Scripting)

---

### WP-DO-14 — Demos & Integrationstests ⬜

**Ziel:** End-to-End-Beispielprogramme und vollständige Integrationstests.

**Zu implementieren:**

Demo 1 — Einfacher Webserver-Deploy:
```lyx
import std/cloud/do/droplets
import std/cloud/do/networking

fn main() {
    let creds = DOCredentialsFromEnv()

    # SSH-Key aus Datei importieren
    let pubKey = fsReadFile("~/.ssh/id_rsa.pub")
    let key = SSHKeyCreate(creds, "lyx-key", pubKey.ptr)

    # Droplet mit Cloud-Init erstellen
    let userData = "#!/bin/bash\napt-get install -y nginx\nsystemctl start nginx"
    let cfg = DODropletCreate{
        name:     "web-01",
        region:   "fra1",
        size:     "s-1vcpu-1gb",
        image:    "ubuntu-22-04-x64",
        sshKeys:  [key.id],
        userData: userData,
        tags:     ["web", "lyx-demo"]
    }
    let d = DropletCreate(creds, cfg)
    DropletWait(creds, d.id, "active")

    let ip = DropletGetIP(creds, d.id)
    println("Droplet läuft: " + ip)

    # Floating IP zuweisen
    let fip = FloatingIPCreate(creds, "fra1")
    FloatingIPAssign(creds, fip.ip, d.id)
    println("Floating IP: " + fip.ip)

    # DNS-Record erstellen
    DomainRecordCreate(creds, "example.com", "A", "web", fip.ip, 300)
    println("DNS: web.example.com → " + fip.ip)
}
```

Demo 2 — Managed Database + Spaces Backup:
```lyx
import std/cloud/do/databases
import std/cloud/do/spaces
import std/db/postgres

fn main() {
    let creds = DOCredentialsFromEnv()

    # Managed PostgreSQL erstellen
    let db = DatabaseCreate(creds, "prod-pg", DO_DB_POSTGRES, "15",
                             "fra1", "db-s-1vcpu-1gb", 1)
    db = DatabaseWait(creds, db.id)

    let conn = DatabaseGetConnection(creds, db.id)
    println("DB-URI: " + conn.uri)

    # Via std/db/postgres verbinden
    let pg = PGConnectURI(conn.uri)
    PGExec(pg, "CREATE TABLE events (id SERIAL PRIMARY KEY, data TEXT)")
    PGExec(pg, "INSERT INTO events (data) VALUES ('hello from lyx')")

    # Backup in Spaces:
    let sp = SpacesConnect(creds, "fra1")
    SpacesUpload(sp, "backups", "dump.sql", "-- backup\n", 10)
    println("Backup gespeichert: " + SpacesPublicURL("fra1", "backups", "dump.sql"))
}
```

Demo 3 — Kubernetes-Cluster + Registry:
```lyx
import std/cloud/do/kubernetes
import std/cloud/do/registry

fn main() {
    let creds = DOCredentialsFromEnv()

    # Registry erstellen
    let reg = RegistryCreate(creds, "meine-registry", "basic")
    RegistryDockerCredentialsSave(creds, "~/.docker/config.json")

    # K8s-Cluster erstellen
    let cluster = K8sClusterCreate(creds, "prod-cluster", "fra1",
                                    "1.29.1-do.0", "s-2vcpu-4gb", 3)
    cluster = K8sClusterWait(creds, cluster.id)
    K8sKubeconfigSave(creds, cluster.id, "~/.kube/config")

    println("Cluster endpoint: " + cluster.endpoint)
    println("Registry: " + RegistryEndpoint(creds))
}
```

Demo 4 — App Platform Deploy:
```lyx
import std/cloud/do/apps

fn main() {
    let creds = DOCredentialsFromEnv()

    let spec = AppSpecNew("meine-app", "fra1")
    spec = AppSpecAddService(spec, "web", "nginx:latest", 80, "basic-xxs")
    spec = AppSpecAddEnvVar(spec, "web", "ENV", "production", "RUN_TIME")

    let app = AppCreate(creds, spec, strLen(spec))
    let deploy = AppDeploy(creds, app.id, false)
    deploy = AppDeploymentWait(creds, app.id, deploy.id)

    println("App live: " + app.liveURL)
    println("Status: " + deploy.phase)
}
```

Demo 5 — Monitoring + Alert:
```lyx
import std/cloud/do/monitoring
import std/cloud/do/droplets

fn main() {
    let creds = DOCredentialsFromEnv()
    let droplets = DropletList(creds)
    let d = droplets[0]

    # CPU-Verlauf der letzten Stunde
    let now = unixNow()
    let metrics = MetricQuery(creds, DO_METRIC_CPU,
                               intToStr(d.id), now - 3600, now, 60)
    println("CPU-Datenpunkte: " + metrics.data.result[0].values.len)

    # Alert bei CPU > 80%
    let alert = AlertCreate(creds,
        DO_ALERT_CPU, "Hohe CPU-Last",
        "GreaterThan", 80.0, "5m",
        [d.id], 1,
        "admin@example.com", "")
    println("Alert erstellt: " + alert.uuid)
}
```

Integrationstests:
```lyx
fn testDropletLifecycle(creds: DOCredentials) -> bool
fn testSpacesRoundtrip(creds: DOCredentials, region: ptr) -> bool
fn testDatabaseCreateDelete(creds: DOCredentials) -> bool
fn testDNSRecordCRUD(creds: DOCredentials, domain: ptr) -> bool
fn testFloatingIPAssign(creds: DOCredentials) -> bool
fn testCredentialChain() -> bool
fn testPaginationDropletList(creds: DOCredentials) -> bool
fn testRateLimitHandling(creds: DOCredentials) -> bool
```

**Dateien:**
- `demo_do.lyu` (neu)
- `demo_do.lyx` (Binär)
- `tests/do_integration.lyu` (neu)

**Akzeptanzkriterien:**
- Alle 5 Demos laufen ohne Fehler mit echtem DO-Token
- Integrationstests grün (kein hart-kodierter State)
- Cleanup nach Tests: alle erstellten Ressourcen werden gelöscht
- `testRateLimitHandling` übersteht bewussten Burst ohne Fehler

---

## Empfohlene Implementierungsreihenfolge

```
Woche 1:    WP-DO-01 + DO-02  → Transport + Credentials (Fundament)
Woche 1-2:  WP-DO-03          → Droplets (Kernprodukt)
Woche 2:    WP-DO-04          → Spaces (erfordert std/cloud/s3.lyu)
Woche 2-3:  WP-DO-07          → Networking (häufig benötigt)
Woche 3:    WP-DO-08          → Volumes
Woche 3-4:  WP-DO-05          → Managed Databases
Woche 4:    WP-DO-06          → Kubernetes
Woche 4-5:  WP-DO-09          → App Platform
Woche 5:    WP-DO-10          → Container Registry
Woche 5:    WP-DO-11          → Functions
Woche 5-6:  WP-DO-12          → Monitoring
Woche 6-7:  WP-DO-13          → lyxdo CLI
Woche 7:    WP-DO-14          → Demos + Tests
```

## Vergleich mit AWS/GCP

| Aspekt              | DigitalOcean          | AWS                    | GCP                     |
|---------------------|-----------------------|------------------------|-------------------------|
| Auth                | Bearer PAT (einfach)  | SigV4 (komplex)        | JWT/OAuth2 (komplex)    |
| Objekt-Storage      | Spaces (S3-kompatibel)| S3                     | GCS                     |
| VMs                 | Droplets              | EC2                    | Compute Engine          |
| Managed DB          | Managed Databases     | RDS                    | Cloud SQL               |
| K8s                 | DOKS                  | EKS                    | GKE                     |
| Serverless          | Functions             | Lambda                 | Cloud Functions         |
| DNS                 | Domains API           | Route 53               | Cloud DNS               |
| API-Komplexität     | ★★☆☆☆ (minimal)      | ★★★★★ (sehr komplex)   | ★★★★☆ (komplex)        |
| Crypto-Voraussetzung| keine                 | SHA-256 + HMAC         | RSA + SHA-256 + JWT     |
| Implementierungszeit| ~7 Wochen             | ~12 Wochen             | ~9 Wochen               |
