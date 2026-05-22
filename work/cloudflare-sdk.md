# Fahrplan: Cloudflare SDK (`std/cloud/cf/`)

## Vision

Ein natives Lyx-SDK für Cloudflare – REST/JSON via `std/net/https`, Authentifizierung über API-Token (Bearer) oder Legacy API-Key, alle wichtigen Cloudflare-Services als typsichere Lyx-API, plus eine `lyxcf`-CLI. Cloudflare ist wie DO einfach zu authentifizieren (kein SigV4, kein JWT), bietet aber einen extrem breiten Service-Stack von DNS bis Edge-Computing.

```lyx
import std/cloud/cf/dns
import std/cloud/cf/workers
import std/cloud/cf/r2

fn main() {
    let creds = CFCredentialsFromEnv()

    # Zone für Domain finden
    let zone = ZoneGetByDomain(creds, "example.com")

    # DNS-Record setzen
    DNSRecordCreate(creds, zone.id, "A", "api", "1.2.3.4", 1, false)

    # Cache für Domain leeren
    CachePurgeAll(creds, zone.id)

    # Worker-Script deployen
    let script = fsReadFile("worker.js")
    WorkerDeploy(creds, "my-account-id", "my-worker", script.ptr, script.size)

    # R2-Objekt hochladen (S3-kompatibel)
    let r2 = R2Connect(creds, "my-account-id", "fra")
    R2Upload(r2, "my-bucket", "data.json", '{"ok":true}', 10)
}
```

---

## Architektur

```
┌──────────────────────────────────────────────────────────────┐
│                      Lyx-Anwendung                           │
└───┬──────┬──────┬──────┬──────┬──────┬──────┬───────────────┘
    │      │      │      │      │      │      │
 ┌──▼──┐ ┌─▼──┐ ┌▼────┐ ┌▼───┐ ┌▼───┐ ┌▼──┐ ┌▼──────┐
 │ DNS │ │WAF │ │Work-│ │ R2 │ │ D1 │ │KV │ │Pages /│
 │Zones│ │CDN │ │ ers │ │    │ │    │ │   │ │Tunnel │ ...
 └──┬──┘ └─┬──┘ └┬────┘ └┬───┘ └┬───┘ └┬──┘ └┬──────┘
    └───────┴─────┴───────┴──────┴──────┴─────┘
                           │
            ┌──────────────▼──────────────┐
            │  CF REST/JSON Transport      │
            │  (std/cloud/cf/transport)    │
            │  Authorization: Bearer <tok> │
            │  X-Auth-Key / X-Auth-Email   │
            │  Pagination, Retry           │
            └──────────────┬──────────────┘
                           │
            ┌──────────────▼──────────────┐
            │  std/net/https.lyu           │
            │  (OpenSSL TLS intern)        │
            └──────────────┬──────────────┘
                           │
            ┌──────────────▼──────────────┐
            │  std/cloud/cf/credentials    │
            │  API Token | API Key+Email   │
            │  ~/.config/lyxcf/config.json │
            └─────────────────────────────┘

  R2 (S3-kompatibel):
  ┌──────────────────────────────────────┐
  │  R2Conn                              │
  │  Endpoint: <account>.r2.cloudflarestorage.com │
  │  Auth: AWS SigV4 (R2 Access Key)    │  ← Wiederverwendung von WP-S3
  └──────────────────────────────────────┘

  Account-Hierarchie:
  Account ──→ Zones (Domains)
          ──→ Workers (Scripts, KV, R2, D1, Queues)
          ──→ Pages (Projekte)
          ──→ Zero Trust (Tunnels, Access)
```

---

## Cloudflare API: Referenz

### Authentifizierung

```
API-Token (empfohlen):
  Header: Authorization: Bearer <token>
  Erstellen: https://dash.cloudflare.com/profile/api-tokens
  Scopes granular: Zone:DNS:Edit, Account:Workers:Edit, etc.

API-Key + E-Mail (Legacy Global Key):
  Header: X-Auth-Key: <global-api-key>
          X-Auth-Email: <email>
  Keine Scope-Einschränkung, nicht empfohlen für Produktion

User Service Key (nur für bestimmte Endpunkte):
  Header: X-Auth-User-Service-Key: <key>

Umgebungsvariablen:
  CLOUDFLARE_API_TOKEN         → Bearer Token (bevorzugt)
  CLOUDFLARE_API_KEY           → Legacy Key
  CLOUDFLARE_EMAIL             → Legacy E-Mail
  CLOUDFLARE_ACCOUNT_ID        → Account-ID

Konfig-Datei: ~/.config/lyxcf/config.json
  { "token": "...", "account_id": "...", "default_zone": "..." }
```

### API-Konventionen

```
Basis-URL:    https://api.cloudflare.com/client/v4
Content-Type: application/json

Response-Wrapper (ALLE Antworten):
  {
    "success": true,
    "errors":   [],
    "messages": [],
    "result":   { ... } | [ ... ],
    "result_info": {
      "page": 1, "per_page": 20,
      "total_pages": 5, "count": 20, "total_count": 94
    }
  }

Fehler-Format:
  { "success": false,
    "errors": [{ "code": 7003, "message": "No route for that URI" }] }

Paginierung:
  Query: ?page=1&per_page=100   (max per_page=100 für die meisten Endpoints)
  Cursor-basiert (neuere APIs): ?cursor=<opaque-string>

Rate-Limiting:
  1200 Requests / 5 Minuten (Free-Plan)
  Header: CF-RateLimit-Limit, CF-RateLimit-Remaining, CF-RateLimit-Reset
  HTTP 429: warte bis Reset-Timestamp

HTTP-Methoden je Ressource:
  GET    → lesen / auflisten
  POST   → erstellen / Aktionen
  PUT    → ersetzen (vollständig)
  PATCH  → teilweise aktualisieren
  DELETE → löschen
```

### Wichtige IDs

```
Account-ID:  32-Hex-Zeichen  z.B. "a1b2c3d4e5f6..."
Zone-ID:     32-Hex-Zeichen  (pro Domain/Zone)
Script-Name: frei wählbar    (Workers)
Namespace-ID: UUID           (KV)
Database-ID:  UUID           (D1)
Bucket-Name: frei wählbar    (R2)
```

### R2 S3-kompatibler Endpunkt

```
Endpoint: https://<account-id>.r2.cloudflarestorage.com
Auth:     AWS SigV4 (R2-eigene Access Keys, nicht CF API Token)
          R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY
Region:   "auto" (Cloudflare wählt automatisch)
API:      100% S3-kompatibel → Wiederverwendung std/cloud/s3.lyu
```

---

## Phasen

| Phase | WPs         | Inhalt                                          | Status |
|-------|-------------|-------------------------------------------------|--------|
| 1     | CF-01–02    | Transport + Credentials, Zone-Verwaltung        | ⬜     |
| 2     | CF-03–04    | DNS, Cache / Page Rules                         | ⬜     |
| 3     | CF-05–06    | WAF + Firewall, Load Balancing                  | ⬜     |
| 4     | CF-07–08    | Workers (Scripts + Routes), Workers KV          | ⬜     |
| 5     | CF-09–10    | R2 Object Storage, D1 (Edge SQL)                | ⬜     |
| 6     | CF-11–12    | Pages, Cloudflare Tunnel                        | ⬜     |
| 7     | CF-13–14    | Analytics + Logs, Email Routing                 | ⬜     |
| 8     | CF-15        | lyxcf CLI                                       | ⬜     |
| 9     | CF-16        | Demos & Integrationstests                       | ⬜     |

---

## Work Packages

---

### WP-CF-01 — REST/JSON Transport + Credentials ⬜

**Ziel:** `std/cloud/cf/transport.lyu` + `std/cloud/cf/credentials.lyu` — HTTP-Client mit CF-spezifischem Response-Wrapper, Paginierung, Retry und Token-/Key-Auth.

**Zu implementieren:**

```lyx
# Credential-Typen:
const CF_AUTH_TOKEN   = 1    # Bearer Token (empfohlen)
const CF_AUTH_KEY     = 2    # X-Auth-Key + X-Auth-Email
const CF_AUTH_SERVICE = 3    # User Service Key

struct CFCredentials {
    authType:  i32
    token:     ptr    # Bearer Token oder Service Key
    apiKey:    ptr    # Legacy API-Key
    email:     ptr    # Legacy E-Mail
    accountId: ptr    # Standard Account-ID
    zoneId:    ptr    # Standard Zone-ID (optional)
}

fn CFCredentialsFree(c: CFCredentials)
fn CFCredentialsFromToken(token: ptr, accountId: ptr) -> CFCredentials
fn CFCredentialsFromKey(apiKey: ptr, email: ptr, accountId: ptr) -> CFCredentials
fn CFCredentialsFromEnv() -> CFCredentials
# CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID (bevorzugt)
# oder CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL
fn CFCredentialsDefault() -> CFCredentials
# 1. CLOUDFLARE_API_TOKEN env
# 2. ~/.config/lyxcf/config.json
fn CFConfigSave(c: CFCredentials, path: ptr) -> i32
fn CFConfigLoad(path: ptr) -> CFCredentials
fn CFValidateToken(c: CFCredentials) -> bool
# GET /user/tokens/verify → 200 = gültig

# Client:
struct CFClient {
    creds:      CFCredentials
    baseURL:    ptr    # "https://api.cloudflare.com/client/v4"
    timeout:    i32    # ms, default: 30000
    maxRetries: i32    # default: 3
}

fn CFClientNew(creds: CFCredentials) -> CFClient
fn CFClientFree(c: CFClient)

# CF Response-Wrapper:
struct CFResponse {
    success:    bool
    statusCode: i32
    result:     ptr    # JSON (object oder array)
    resultLen:  i32
    errors:     ptr    # JSON-Array
    messages:   ptr
    page:       i32
    perPage:    i32
    totalPages: i32
    totalCount: i32
}

fn CFResponseFree(r: CFResponse)

# HTTP-Methoden (intern wrappen HTTPSGet/HTTPSPost):
fn CFGet(c: CFClient, path: ptr) -> CFResponse
fn CFPost(c: CFClient, path: ptr, body: ptr, bodyLen: i32) -> CFResponse
fn CFPut(c: CFClient, path: ptr, body: ptr, bodyLen: i32) -> CFResponse
fn CFPatch(c: CFClient, path: ptr, body: ptr, bodyLen: i32) -> CFResponse
fn CFDelete(c: CFClient, path: ptr) -> CFResponse
fn CFPostMultipart(c: CFClient, path: ptr, parts: ptr, count: i32) -> CFResponse
# Für Worker-Script-Upload (multipart/form-data)

# Pagination:
fn CFGetAll(c: CFClient, path: ptr, perPage: i32) -> ptr
# Iteriert alle Seiten, gibt zusammengeführtes JSON-Array zurück

# Fehler:
struct CFError {
    code:    i32
    message: ptr
}

fn CFParseErrors(body: ptr, bodyLen: i32) -> ptr  # → CFError[]
fn CFErrorString(code: i32) -> ptr  # bekannte Fehlercodes

# Bekannte Fehlercodes:
# 7000: keine Route
# 7003: Zone nicht gefunden
# 9103: ungültiger Token
# 10000: Authentifizierungsfehler
# 81053: DNS-Eintrag existiert bereits
```

**Dateien:**
- `std/cloud/cf/transport.lyu` (neu)
- `std/cloud/cf/credentials.lyu` (neu)
- `std/cloud/cf/core.lyu` (neu) — Re-Export

**Akzeptanzkriterien:**
- `CFValidateToken` → true bei gültigem Token, false bei 401
- `CFGetAll` sammelt alle DNS-Records einer Zone über mehrere Seiten
- 429-Handling: wartet bis `CF-RateLimit-Reset`-Timestamp, dann Retry
- `success: false`-Antworten werden als Fehler zurückgegeben (kein Crash)

---

### WP-CF-02 — Zones (Domain-Verwaltung) ⬜

**Ziel:** `std/cloud/cf/zones.lyu` — Zones (Domains) anlegen, konfigurieren, Einstellungen verwalten.

**Zu implementieren:**

```lyx
struct CFZone {
    id:            ptr
    name:          ptr    # "example.com"
    status:        ptr    # "active", "pending", "initializing", "moved", "deleted"
    paused:        bool
    type:          ptr    # "full", "partial", "secondary"
    plan:          ptr    # "free", "pro", "business", "enterprise"
    nameServers:   ptr    # string[] — CF-Nameserver
    originalNS:    ptr    # string[] — originale Nameserver
    activatedOn:   ptr
    created:       ptr
    accountId:     ptr
    accountName:   ptr
    developmentMode: i32  # 0 = off, Sekunden bis Ende
}

fn CFZoneFree(z: CFZone)

# Zone-Verwaltung:
fn ZoneCreate(c: CFClient, domain: ptr, accountId: ptr, zoneType: ptr) -> CFZone
# POST /zones  Body: {"name":"example.com","account":{"id":"..."},"jump_start":true}
fn ZoneDelete(c: CFClient, zoneId: ptr) -> i32
fn ZoneGet(c: CFClient, zoneId: ptr) -> CFZone
fn ZoneGetByDomain(c: CFClient, domain: ptr) -> CFZone
# GET /zones?name=example.com  → erster Treffer
fn ZoneList(c: CFClient) -> ptr    # → CFZone[]
fn ZoneListAccount(c: CFClient, accountId: ptr) -> ptr

# Zone aktivieren/pausieren:
fn ZonePause(c: CFClient, zoneId: ptr) -> i32
fn ZoneUnpause(c: CFClient, zoneId: ptr) -> i32
fn ZonePurgeCache(c: CFClient, zoneId: ptr) -> i32   # alias, siehe WP-CF-04

# Zone-Einstellungen (GET + PATCH /zones/{id}/settings/{name}):
struct CFSetting {
    id:         ptr    # Einstellungsname
    value:      ptr    # JSON-Wert
    modifiable: bool
    modified:   ptr
}

fn ZoneSettingGet(c: CFClient, zoneId: ptr, setting: ptr) -> CFSetting
fn ZoneSettingSet(c: CFClient, zoneId: ptr, setting: ptr, value: ptr) -> i32

# Häufige Einstellungen:
fn ZoneSetSSL(c: CFClient, zoneId: ptr, mode: ptr) -> i32
# mode: "off","flexible","full","strict"
fn ZoneSetHTTPS(c: CFClient, zoneId: ptr, enabled: bool) -> i32
# always_use_https: on/off
fn ZoneSetMinTLS(c: CFClient, zoneId: ptr, version: ptr) -> i32
# "1.0","1.1","1.2","1.3"
fn ZoneSetCacheTTL(c: CFClient, zoneId: ptr, ttl: i32) -> i32
fn ZoneSetBrotli(c: CFClient, zoneId: ptr, enabled: bool) -> i32
fn ZoneSetHTTP2(c: CFClient, zoneId: ptr, enabled: bool) -> i32
fn ZoneSetHTTP3(c: CFClient, zoneId: ptr, enabled: bool) -> i32
fn ZoneSetEarlyHints(c: CFClient, zoneId: ptr, enabled: bool) -> i32
fn ZoneSetDevelopmentMode(c: CFClient, zoneId: ptr, enabled: bool) -> i32
fn ZoneSettingsGetAll(c: CFClient, zoneId: ptr) -> ptr   # → CFSetting[]
fn ZoneSettingsSetBulk(c: CFClient, zoneId: ptr, settings: ptr, count: i32) -> i32
# PATCH /zones/{id}/settings  Body: {"items":[{"id":"ssl","value":"strict"},...]}'

# Nameserver-Info:
fn ZoneActivationCheck(c: CFClient, zoneId: ptr) -> i32
# PUT /zones/{id}/activation_check → prüft NS-Delegation
```

**Dateien:**
- `std/cloud/cf/zones.lyu` (neu)

**Akzeptanzkriterien:**
- `ZoneGetByDomain("example.com")` gibt korrekte Zone-ID zurück
- `ZoneSetSSL` → Einstellung in Dashboard sichtbar
- `ZoneSettingGet("ssl")` gibt aktuellen SSL-Modus zurück
- `ZoneList` paginiert korrekt bei > 100 Zones

---

### WP-CF-03 — DNS Records ⬜

**Ziel:** `std/cloud/cf/dns.lyu` — Vollständige DNS-Record-Verwaltung.

**Zu implementieren:**

```lyx
struct CFDNSRecord {
    id:         ptr
    zoneId:     ptr
    zoneName:   ptr
    type:       ptr    # "A","AAAA","CNAME","MX","TXT","NS","SRV","CAA","PTR"
                       # "CERT","DNSKEY","DS","NAPTR","SMIMEA","SSHFP","TLSA","URI"
    name:       ptr    # "www.example.com" (vollqualifiziert)
    content:    ptr    # IP, Hostname, TXT-Inhalt
    ttl:        i32    # 1 = auto (CF-Proxy: immer auto)
    proxied:    bool   # true = Cloudflare-Proxy aktiv (orange Wolke)
    proxiable:  bool
    priority:   i32    # MX/SRV/URI
    locked:     bool
    created:    ptr
    modified:   ptr
    # SRV-spezifisch (in "data"-Objekt):
    srvService:  ptr   # "_http"
    srvProto:    ptr   # "_tcp"
    srvWeight:   i32
    srvPort:     i32
    srvTarget:   ptr
}

fn CFDNSRecordFree(r: CFDNSRecord)

# CRUD:
fn DNSRecordCreate(c: CFClient, zoneId: ptr,
                   recType: ptr, name: ptr, content: ptr,
                   ttl: i32, proxied: bool) -> CFDNSRecord
# POST /zones/{zoneId}/dns_records

fn DNSRecordUpdate(c: CFClient, zoneId: ptr, recordId: ptr,
                   content: ptr, ttl: i32, proxied: bool) -> CFDNSRecord
# PUT /zones/{zoneId}/dns_records/{recordId}

fn DNSRecordPatch(c: CFClient, zoneId: ptr, recordId: ptr,
                  content: ptr) -> CFDNSRecord
# PATCH — nur content ändern

fn DNSRecordDelete(c: CFClient, zoneId: ptr, recordId: ptr) -> i32
fn DNSRecordGet(c: CFClient, zoneId: ptr, recordId: ptr) -> CFDNSRecord

# Listen + Suchen:
fn DNSRecordList(c: CFClient, zoneId: ptr) -> ptr
fn DNSRecordListByType(c: CFClient, zoneId: ptr, recType: ptr) -> ptr
fn DNSRecordListByName(c: CFClient, zoneId: ptr, name: ptr) -> ptr
# GET /zones/{zoneId}/dns_records?name=www.example.com&type=A

fn DNSRecordFind(c: CFClient, zoneId: ptr,
                 recType: ptr, name: ptr) -> CFDNSRecord
# Sucht erstes passendes Record (oder nil)

# Upsert-Hilfsfunktion:
fn DNSRecordUpsert(c: CFClient, zoneId: ptr,
                   recType: ptr, name: ptr, content: ptr,
                   ttl: i32, proxied: bool) -> CFDNSRecord
# Existiert → Update, sonst → Create

# Bulk-Operationen:
fn DNSRecordDeleteByName(c: CFClient, zoneId: ptr, name: ptr) -> i32
# Löscht ALLE Records mit diesem Namen (alle Typen)
fn DNSRecordDeleteByType(c: CFClient, zoneId: ptr,
                          recType: ptr, name: ptr) -> i32

# Spezialisierte Ersteller:
fn DNSRecordCreateA(c: CFClient, zoneId: ptr,
                    name: ptr, ip: ptr, proxied: bool) -> CFDNSRecord
fn DNSRecordCreateAAAA(c: CFClient, zoneId: ptr,
                        name: ptr, ipv6: ptr, proxied: bool) -> CFDNSRecord
fn DNSRecordCreateCNAME(c: CFClient, zoneId: ptr,
                         name: ptr, target: ptr, proxied: bool) -> CFDNSRecord
fn DNSRecordCreateMX(c: CFClient, zoneId: ptr,
                      name: ptr, mailServer: ptr, priority: i32) -> CFDNSRecord
fn DNSRecordCreateTXT(c: CFClient, zoneId: ptr,
                       name: ptr, content: ptr) -> CFDNSRecord
fn DNSRecordCreateSRV(c: CFClient, zoneId: ptr,
                       service: ptr, proto: ptr, name: ptr,
                       priority: i32, weight: i32, port: i32,
                       target: ptr) -> CFDNSRecord
fn DNSRecordCreateCAA(c: CFClient, zoneId: ptr,
                       name: ptr, flags: i32, tag: ptr, value: ptr) -> CFDNSRecord

# Import / Export:
fn DNSZoneExport(c: CFClient, zoneId: ptr) -> ptr    # → BIND-Zone-File (text/dns)
fn DNSZoneImport(c: CFClient, zoneId: ptr, bindZoneFile: ptr, fileLen: i32) -> ptr
# POST /zones/{zoneId}/dns_records/import  (multipart)
# → { "recs_added": 42, "total_records_parsed": 45 }
```

**Dateien:**
- `std/cloud/cf/dns.lyu` (neu)

**Akzeptanzkriterien:**
- `DNSRecordCreateA("@", "1.2.3.4", true)` → Record in CF-Dashboard sichtbar
- `DNSRecordUpsert` erzeugt beim ersten Call, updated beim zweiten
- `DNSZoneExport` gibt valides BIND-Format zurück
- `DNSZoneImport` importiert exportierten BIND-File ohne Fehler

---

### WP-CF-04 — Cache & Page Rules ⬜

**Ziel:** `std/cloud/cf/cache.lyu` — Cache-Purging, Cache-Regeln, Page Rules, Transform Rules.

**Zu implementieren:**

Cache Purging:
```lyx
fn CachePurgeAll(c: CFClient, zoneId: ptr) -> i32
# POST /zones/{zoneId}/purge_cache  Body: {"purge_everything":true}

fn CachePurgeFiles(c: CFClient, zoneId: ptr, urls: ptr, count: i32) -> i32
# POST /zones/{zoneId}/purge_cache  Body: {"files":["https://...",...]}
# max. 30 URLs pro Request

fn CachePurgeTags(c: CFClient, zoneId: ptr, tags: ptr, count: i32) -> i32
# Body: {"tags":["tag1","tag2"]}  (Business/Enterprise)

fn CachePurgePrefixes(c: CFClient, zoneId: ptr, prefixes: ptr, count: i32) -> i32
# Body: {"prefixes":["example.com/static/"]}  (Enterprise)

fn CachePurgeHosts(c: CFClient, zoneId: ptr, hosts: ptr, count: i32) -> i32
# Body: {"hosts":["www.example.com"]}  (Enterprise)
```

Cache Rules (neue API, ersetzt Page Rules):
```lyx
struct CFCacheRule {
    id:          ptr
    description: ptr
    expression:  ptr    # Firewall-Rule-Ausdruck: (http.host eq "example.com")
    action:      ptr    # "set_cache_settings", "bypass_cache", "serve_stale"
    enabled:     bool
    # Cache-Einstellungen (bei set_cache_settings):
    browserTTL:  i32    # Sekunden, 0 = Respect Origin
    edgeTTL:     i32
    cacheKey:    ptr    # JSON: custom cache key config
    serveStale:  i32    # Sekunden bei Fehler
}

fn CacheRuleCreate(c: CFClient, zoneId: ptr, rule: CFCacheRule) -> CFCacheRule
fn CacheRuleUpdate(c: CFClient, zoneId: ptr, ruleId: ptr, rule: CFCacheRule) -> CFCacheRule
fn CacheRuleDelete(c: CFClient, zoneId: ptr, ruleId: ptr) -> i32
fn CacheRuleList(c: CFClient, zoneId: ptr) -> ptr
```

Page Rules (Legacy, aber weit verbreitet):
```lyx
# Aktionen als JSON-kompatible Structs:
const CF_PR_ALWAYS_HTTPS          = "always_use_https"
const CF_PR_BROWSER_CACHE_TTL     = "browser_cache_ttl"
const CF_PR_CACHE_LEVEL           = "cache_level"
const CF_PR_DISABLE_SECURITY      = "disable_security"
const CF_PR_EDGE_CACHE_TTL        = "edge_cache_ttl"
const CF_PR_FORWARDING_URL        = "forwarding_url"
const CF_PR_MINIFY                = "minify"
const CF_PR_ROCKET_LOADER         = "rocket_loader"
const CF_PR_SECURITY_LEVEL        = "security_level"
const CF_PR_SSL                   = "ssl"

struct CFPageRule {
    id:       ptr
    targets:  ptr    # [{"target":"url","constraint":{"operator":"matches","value":"*"}}]
    actions:  ptr    # [{"id":"always_use_https"},{"id":"cache_level","value":"aggressive"}]
    priority: i32
    status:   ptr    # "active", "disabled"
    created:  ptr
    modified: ptr
}

fn PageRuleCreate(c: CFClient, zoneId: ptr,
                  urlPattern: ptr, actions: ptr, actionsLen: i32,
                  priority: i32) -> CFPageRule
fn PageRuleUpdate(c: CFClient, zoneId: ptr, ruleId: ptr,
                  urlPattern: ptr, actions: ptr, actionsLen: i32) -> CFPageRule
fn PageRuleDelete(c: CFClient, zoneId: ptr, ruleId: ptr) -> i32
fn PageRuleList(c: CFClient, zoneId: ptr) -> ptr

# Hilfsfunktionen (häufige Patterns):
fn PageRuleRedirect(c: CFClient, zoneId: ptr,
                    fromPattern: ptr, toURL: ptr,
                    statusCode: i32) -> CFPageRule
# Erstellt Forwarding Rule: 301/302-Redirect
fn PageRuleForceHTTPS(c: CFClient, zoneId: ptr, pattern: ptr) -> CFPageRule
# always_use_https für Pattern
fn PageRuleCacheEverything(c: CFClient, zoneId: ptr, pattern: ptr, ttl: i32) -> CFPageRule
```

Transform Rules:
```lyx
# URL-Rewrite Rules:
struct CFTransformRule {
    id:          ptr
    description: ptr
    expression:  ptr    # Wirefilter-Ausdruck
    action:      ptr    # "rewrite"
    enabled:     bool
    pathValue:   ptr    # Neuer Pfad (statisch oder Expression)
    queryValue:  ptr    # Neue Query (statisch oder Expression)
}

fn TransformRuleCreate(c: CFClient, zoneId: ptr,
                        description: ptr, expression: ptr,
                        newPath: ptr) -> CFTransformRule
fn TransformRuleDelete(c: CFClient, zoneId: ptr, ruleId: ptr) -> i32
fn TransformRuleList(c: CFClient, zoneId: ptr) -> ptr

# Header-Modify Rules:
fn HeaderRuleCreate(c: CFClient, zoneId: ptr,
                    description: ptr, expression: ptr,
                    reqHeaders: ptr, respHeaders: ptr) -> ptr
fn HeaderRuleList(c: CFClient, zoneId: ptr) -> ptr
```

**Dateien:**
- `std/cloud/cf/cache.lyu` (neu)

**Akzeptanzkriterien:**
- `CachePurgeAll` → CF-Dashboard zeigt "Cache wurde geleert"
- `CachePurgeFiles` mit max. 30 URLs in einem Request
- `PageRuleRedirect` erstellt funktionierenden 301-Redirect
- `CacheRuleCreate` mit TTL-Einstellung sichtbar im Ruleset

---

### WP-CF-05 — WAF, Firewall-Regeln & Rate-Limiting ⬜

**Ziel:** `std/cloud/cf/waf.lyu` — IP-Regeln, Custom Rules, Rate Limiting, Bot Management, Security Settings.

**Zu implementieren:**

Firewall Rules (Custom Rules, neue API):
```lyx
# Wirefilter-Ausdrücke:
# (ip.src eq 1.2.3.4)
# (ip.src.country in {"DE" "AT" "CH"})
# (http.request.uri.path contains "/admin")
# (cf.threat_score gt 14)
# (http.user_agent contains "curl")

struct CFFirewallRule {
    id:          ptr
    description: ptr
    expression:  ptr    # Wirefilter-Ausdruck
    action:      ptr    # "block","challenge","js_challenge","managed_challenge",
                        # "allow","log","bypass","skip"
    enabled:     bool
    priority:    i32
    paused:      bool
    products:    ptr    # string[] bei "bypass": ["waf","rateLimit",...]
}

fn FirewallRuleCreate(c: CFClient, zoneId: ptr, rule: CFFirewallRule) -> CFFirewallRule
fn FirewallRuleUpdate(c: CFClient, zoneId: ptr, ruleId: ptr, rule: CFFirewallRule) -> CFFirewallRule
fn FirewallRuleDelete(c: CFClient, zoneId: ptr, ruleId: ptr) -> i32
fn FirewallRuleList(c: CFClient, zoneId: ptr) -> ptr
fn FirewallRuleEnable(c: CFClient, zoneId: ptr, ruleId: ptr) -> i32
fn FirewallRuleDisable(c: CFClient, zoneId: ptr, ruleId: ptr) -> i32

# Schnell-Erstellung:
fn FirewallBlockIP(c: CFClient, zoneId: ptr, ip: ptr, note: ptr) -> CFFirewallRule
fn FirewallBlockCountry(c: CFClient, zoneId: ptr,
                         countryCodes: ptr, count: i32, note: ptr) -> CFFirewallRule
fn FirewallAllowIP(c: CFClient, zoneId: ptr, ip: ptr, note: ptr) -> CFFirewallRule
fn FirewallChallengePath(c: CFClient, zoneId: ptr,
                          pathPrefix: ptr, note: ptr) -> CFFirewallRule
```

IP Access Rules (Account-Level oder Zone-Level):
```lyx
const CF_IP_RULE_WHITELIST = "whitelist"
const CF_IP_RULE_BLOCK     = "block"
const CF_IP_RULE_CHALLENGE = "challenge"
const CF_IP_RULE_JS_CHALLENGE = "js_challenge"

struct CFIPAccessRule {
    id:         ptr
    mode:       ptr
    notes:      ptr
    configuration: struct {
        target: ptr    # "ip","ip_range","country","asn"
        value:  ptr    # IP, CIDR, ISO-Code, AS-Nummer
    }
    scope:      ptr    # "zone" oder "account"
    created:    ptr
    modified:   ptr
}

fn IPRuleCreate(c: CFClient, zoneId: ptr,
                mode: ptr, target: ptr, value: ptr, notes: ptr) -> CFIPAccessRule
fn IPRuleCreateAccount(c: CFClient,
                        mode: ptr, target: ptr, value: ptr, notes: ptr) -> CFIPAccessRule
fn IPRuleDelete(c: CFClient, zoneId: ptr, ruleId: ptr) -> i32
fn IPRuleList(c: CFClient, zoneId: ptr) -> ptr
fn IPRuleListAccount(c: CFClient) -> ptr
```

Rate Limiting:
```lyx
struct CFRateLimit {
    id:          ptr
    description: ptr
    match:       struct {
        request: struct {
            urlPattern: ptr    # "example.com/api/*"
            methods:    ptr    # string[] ["GET","POST"]
            schemes:    ptr    # string[] ["HTTP","HTTPS"]
        }
        response: struct {
            statuses:     ptr    # i32[] [200,201]
            originTraffic: bool
        }
    }
    threshold:   i32    # Requests pro Periode
    period:      i32    # Sekunden
    action:      struct {
        mode:    ptr    # "simulate","ban","challenge","js_challenge"
        timeout: i32    # Bann-Dauer Sekunden
        response: ptr   # Custom Response (optional)
    }
    enabled:     bool
}

fn RateLimitCreate(c: CFClient, zoneId: ptr,
                   urlPattern: ptr, threshold: i32,
                   period: i32, action: ptr, timeout: i32) -> CFRateLimit
fn RateLimitDelete(c: CFClient, zoneId: ptr, ruleId: ptr) -> i32
fn RateLimitList(c: CFClient, zoneId: ptr) -> ptr
```

WAF Managed Rules:
```lyx
fn WAFPackageList(c: CFClient, zoneId: ptr) -> ptr
fn WAFPackageGet(c: CFClient, zoneId: ptr, packageId: ptr) -> ptr
fn WAFRuleGroupList(c: CFClient, zoneId: ptr, packageId: ptr) -> ptr
fn WAFRuleGroupEnable(c: CFClient, zoneId: ptr, packageId: ptr, groupId: ptr) -> i32
fn WAFRuleGroupDisable(c: CFClient, zoneId: ptr, packageId: ptr, groupId: ptr) -> i32

# Security Level:
fn ZoneSetSecurityLevel(c: CFClient, zoneId: ptr, level: ptr) -> i32
# level: "off","essentially_off","low","medium","high","under_attack"
fn ZoneSetBotFightMode(c: CFClient, zoneId: ptr, enabled: bool) -> i32
fn ZoneSetHotlinkProtection(c: CFClient, zoneId: ptr, enabled: bool) -> i32
fn ZoneSetEmailObfuscation(c: CFClient, zoneId: ptr, enabled: bool) -> i32
```

**Dateien:**
- `std/cloud/cf/waf.lyu` (neu)

**Akzeptanzkriterien:**
- `FirewallBlockIP("1.2.3.4")` → HTTP 403 bei Zugriff von dieser IP
- `RateLimitCreate` → API-Endpunkt nach N Requests geblockt
- `IPRuleCreate` account-weit → gilt für alle Zones
- `ZoneSetSecurityLevel("under_attack")` schützt bei DDoS

---

### WP-CF-06 — Load Balancing ⬜

**Ziel:** `std/cloud/cf/lb.lyu` — Load Balancer, Origin Pools, Health Checks.

**Zu implementieren:**

```lyx
# Health Check:
struct CFHealthCheck {
    id:              ptr
    name:            ptr
    type:            ptr    # "http","https","tcp"
    address:         ptr    # URL oder IP
    port:            i32
    path:            ptr    # "/health"
    interval:        i32    # Sekunden zwischen Checks
    timeout:         i32
    retries:         i32
    expectedCodes:   ptr    # "2xx","200","200-299"
    expectedBody:    ptr    # optionale Zeichenkette im Response
    method:          ptr    # "GET","HEAD"
    followRedirects: bool
    allowInsecure:   bool
    created:         ptr
}

fn HealthCheckCreate(c: CFClient, accountId: ptr, hc: CFHealthCheck) -> CFHealthCheck
fn HealthCheckDelete(c: CFClient, accountId: ptr, id: ptr) -> i32
fn HealthCheckList(c: CFClient, accountId: ptr) -> ptr

# Origin Pool:
struct CFOrigin {
    name:    ptr
    address: ptr    # IP oder Hostname
    enabled: bool
    weight:  f64    # 0.0–1.0
    header:  ptr    # optionaler Host-Header
}

struct CFPool {
    id:              ptr
    name:            ptr
    description:     ptr
    enabled:         bool
    origins:         ptr    # CFOrigin[]
    minimumOrigins:  i32
    monitor:         ptr    # Health-Check-ID
    notificationEmail: ptr
    latitude:        f64
    longitude:       f64
    loadShedding:    ptr
}

fn PoolCreate(c: CFClient, accountId: ptr, pool: CFPool) -> CFPool
fn PoolUpdate(c: CFClient, accountId: ptr, poolId: ptr, pool: CFPool) -> CFPool
fn PoolDelete(c: CFClient, accountId: ptr, poolId: ptr) -> i32
fn PoolGet(c: CFClient, accountId: ptr, poolId: ptr) -> CFPool
fn PoolList(c: CFClient, accountId: ptr) -> ptr
fn PoolHealthGet(c: CFClient, accountId: ptr, poolId: ptr) -> ptr
# → {"healthy":true,"origins":[{"healthy":true,"address":"1.2.3.4"}]}

# Load Balancer:
struct CFLoadBalancer {
    id:              ptr
    name:            ptr    # "lb.example.com" (DNS-Name)
    defaultPools:    ptr    # Pool-IDs in Reihenfolge (Fallback)
    fallbackPool:    ptr    # letzter Fallback
    steering:        ptr    # "off","geo","random","dynamic_latency","proximity"
    sessionAffinity: ptr    # "none","cookie","ip_cookie"
    ttl:             i32    # DNS-TTL (0 = auto)
    proxied:         bool
    enabled:         bool
    regionPools:     ptr    # JSON: {"WNAM":["pool-id-1"],"EEU":["pool-id-2"]}
    countryPools:    ptr    # JSON: {"DE":["pool-id"],...}
    rules:           ptr    # LB-Rules (Overrides)
}

fn LBCreate(c: CFClient, zoneId: ptr, lb: CFLoadBalancer) -> CFLoadBalancer
fn LBUpdate(c: CFClient, zoneId: ptr, lbId: ptr, lb: CFLoadBalancer) -> CFLoadBalancer
fn LBDelete(c: CFClient, zoneId: ptr, lbId: ptr) -> i32
fn LBGet(c: CFClient, zoneId: ptr, lbId: ptr) -> CFLoadBalancer
fn LBList(c: CFClient, zoneId: ptr) -> ptr
fn LBHealthGet(c: CFClient, zoneId: ptr, lbId: ptr) -> ptr
```

**Dateien:**
- `std/cloud/cf/lb.lyu` (neu)

**Akzeptanzkriterien:**
- `HealthCheckCreate` + `PoolCreate` → Pool-Status "healthy" bei lebendem Origin
- `LBCreate` → DNS-Name löst auf Load Balancer auf
- Geo-Steering: DE-Traffic → EU-Pool, US-Traffic → NA-Pool
- Pool unhealthy → Traffic automatisch auf Fallback-Pool

---

### WP-CF-07 — Workers (Edge Computing) ⬜

**Ziel:** `std/cloud/cf/workers.lyu` — Cloudflare Workers deployen, Routes konfigurieren, Bindings verwalten.

**Zu implementieren:**

```lyx
struct CFWorkerScript {
    name:        ptr
    etag:        ptr
    size:        i32
    modified:    ptr
    usage:       struct {
        requests: i64
        errors:   i64
        subrequests: i64
        wallTime: f64   # ms gesamt
    }
}

# Script-Verwaltung:
fn WorkerDeploy(c: CFClient, accountId: ptr,
                scriptName: ptr, script: ptr, scriptLen: i32) -> i32
# PUT /accounts/{id}/workers/scripts/{name}
# Content-Type: application/javascript
# Body: JS-Script direkt

fn WorkerDeployModule(c: CFClient, accountId: ptr,
                       scriptName: ptr,
                       moduleScript: ptr, scriptLen: i32,
                       metadata: ptr) -> i32
# multipart/form-data: metadata JSON + script
# Für ES-Module (export default { fetch(req) {} })

fn WorkerDeployWithBindings(c: CFClient, accountId: ptr,
                              scriptName: ptr,
                              script: ptr, scriptLen: i32,
                              bindings: ptr, bindingsLen: i32) -> i32
# metadata.bindings: KV, R2, D1, secrets, etc.

fn WorkerDelete(c: CFClient, accountId: ptr, scriptName: ptr) -> i32
fn WorkerGet(c: CFClient, accountId: ptr, scriptName: ptr) -> CFWorkerScript
fn WorkerList(c: CFClient, accountId: ptr) -> ptr
fn WorkerDownload(c: CFClient, accountId: ptr, scriptName: ptr) -> ptr  # → JS-Code

# Routes (Zone-Level: welche URLs lösen Worker aus):
struct CFWorkerRoute {
    id:      ptr
    pattern: ptr    # "example.com/api/*"
    script:  ptr    # Script-Name (null = deaktiviert)
}

fn WorkerRouteCreate(c: CFClient, zoneId: ptr,
                      pattern: ptr, scriptName: ptr) -> CFWorkerRoute
fn WorkerRouteUpdate(c: CFClient, zoneId: ptr, routeId: ptr,
                      pattern: ptr, scriptName: ptr) -> CFWorkerRoute
fn WorkerRouteDelete(c: CFClient, zoneId: ptr, routeId: ptr) -> i32
fn WorkerRouteList(c: CFClient, zoneId: ptr) -> ptr

# Subdomain (workers.dev):
fn WorkerSubdomainGet(c: CFClient, accountId: ptr) -> ptr
# GET /accounts/{id}/workers/subdomain → "<subdomain>.workers.dev"
fn WorkerSubdomainCreate(c: CFClient, accountId: ptr, subdomain: ptr) -> i32
fn WorkerEnableSubdomain(c: CFClient, accountId: ptr, scriptName: ptr) -> i32
fn WorkerDisableSubdomain(c: CFClient, accountId: ptr, scriptName: ptr) -> i32
# → <scriptName>.<subdomain>.workers.dev

# Secrets (Umgebungsvariablen, verschlüsselt):
fn WorkerSecretSet(c: CFClient, accountId: ptr,
                    scriptName: ptr, key: ptr, value: ptr) -> i32
# PUT /accounts/{id}/workers/scripts/{name}/secrets
fn WorkerSecretDelete(c: CFClient, accountId: ptr, scriptName: ptr, key: ptr) -> i32
fn WorkerSecretList(c: CFClient, accountId: ptr, scriptName: ptr) -> ptr

# Cron Triggers:
fn WorkerCronCreate(c: CFClient, accountId: ptr,
                     scriptName: ptr, cronExpr: ptr) -> i32
# PUT /accounts/{id}/workers/scripts/{name}/schedules
fn WorkerCronList(c: CFClient, accountId: ptr, scriptName: ptr) -> ptr
fn WorkerCronDelete(c: CFClient, accountId: ptr, scriptName: ptr, cronExpr: ptr) -> i32

# Logs (Tail Worker, via SSE):
fn WorkerTailStart(c: CFClient, accountId: ptr, scriptName: ptr) -> ptr
# POST /accounts/{id}/workers/scripts/{name}/tails → tail-ID
fn WorkerTailDelete(c: CFClient, accountId: ptr,
                     scriptName: ptr, tailId: ptr) -> i32

# Wasm-Modul hochladen:
fn WorkerDeployWasm(c: CFClient, accountId: ptr,
                     scriptName: ptr,
                     jsScript: ptr, jsLen: i32,
                     wasmModule: ptr, wasmLen: i32) -> i32
# multipart: main.js + worker.wasm
```

**Dateien:**
- `std/cloud/cf/workers.lyu` (neu)

**Akzeptanzkriterien:**
- `WorkerDeploy` → Script unter `<name>.<subdomain>.workers.dev` erreichbar
- `WorkerRouteCreate("example.com/api/*", "my-worker")` → Route aktiv
- `WorkerSecretSet("DB_URL", "postgres://...")` → in Script als `env.DB_URL`
- `WorkerCronCreate("0 * * * *")` → stündliche Ausführung

---

### WP-CF-08 — Workers KV ⬜

**Ziel:** `std/cloud/cf/kv.lyu` — Workers KV Namespaces und Key-Value-Operationen.

**Zu implementieren:**

```lyx
struct CFKVNamespace {
    id:    ptr
    title: ptr
}

# Namespace-Verwaltung:
fn KVNamespaceCreate(c: CFClient, accountId: ptr, title: ptr) -> CFKVNamespace
# POST /accounts/{id}/storage/kv/namespaces
fn KVNamespaceDelete(c: CFClient, accountId: ptr, nsId: ptr) -> i32
fn KVNamespaceRename(c: CFClient, accountId: ptr, nsId: ptr, newTitle: ptr) -> i32
fn KVNamespaceList(c: CFClient, accountId: ptr) -> ptr

# Key-Value-Operationen:
fn KVGet(c: CFClient, accountId: ptr, nsId: ptr, key: ptr) -> ptr
# GET /accounts/{id}/storage/kv/namespaces/{nsId}/values/{key}
# → Wert als Bytes (kein JSON-Wrapper)

fn KVGetWithMeta(c: CFClient, accountId: ptr, nsId: ptr, key: ptr) -> ptr
# GET ...?cacheTtl=60  + X-CF-KV-Metadata Header

fn KVPut(c: CFClient, accountId: ptr, nsId: ptr,
          key: ptr, value: ptr, valueLen: i32) -> i32
# PUT .../values/{key}  Body: Wert direkt (kein JSON)
fn KVPutWithTTL(c: CFClient, accountId: ptr, nsId: ptr,
                 key: ptr, value: ptr, valueLen: i32,
                 expirationTTL: i32) -> i32
# Query: ?expiration_ttl=3600
fn KVPutWithExpiry(c: CFClient, accountId: ptr, nsId: ptr,
                    key: ptr, value: ptr, valueLen: i32,
                    expirationUnix: i64) -> i32
# Query: ?expiration=<unix-ts>
fn KVPutWithMeta(c: CFClient, accountId: ptr, nsId: ptr,
                  key: ptr, value: ptr, valueLen: i32,
                  metaJSON: ptr) -> i32
# multipart: value + metadata

fn KVDelete(c: CFClient, accountId: ptr, nsId: ptr, key: ptr) -> i32
fn KVExists(c: CFClient, accountId: ptr, nsId: ptr, key: ptr) -> bool

# Listen:
struct CFKVKey {
    name:       ptr
    expiration: i64    # 0 = kein Ablauf
    metadata:   ptr    # JSON
}

fn KVList(c: CFClient, accountId: ptr, nsId: ptr,
           prefix: ptr, limit: i32) -> ptr    # → CFKVKey[]
fn KVListAll(c: CFClient, accountId: ptr, nsId: ptr, prefix: ptr) -> ptr
# Iteriert Cursor-basierte Paginierung

# Bulk-Operationen:
struct CFKVBulkEntry {
    key:            ptr
    value:          ptr
    valueLen:       i32
    expirationTTL:  i32
    metadata:       ptr
    base64:         bool
}

fn KVPutBulk(c: CFClient, accountId: ptr, nsId: ptr,
              entries: ptr, count: i32) -> i32
# PUT .../bulk  Body: JSON-Array (max 10.000 Keys)
fn KVDeleteBulk(c: CFClient, accountId: ptr, nsId: ptr,
                 keys: ptr, count: i32) -> i32
# DELETE .../bulk  Body: JSON-Array von Keys (max 10.000)
```

**Dateien:**
- `std/cloud/cf/kv.lyu` (neu)

**Akzeptanzkriterien:**
- `KVPut` + `KVGet` Round-Trip mit Binärdaten
- `KVPutWithTTL(3600)` → Key nach 1 Stunde nicht mehr abrufbar
- `KVPutBulk` schreibt 1000 Keys in einem Request
- `KVListAll` paginiert vollständig bei > 1000 Keys

---

### WP-CF-09 — R2 Object Storage ⬜

**Ziel:** `std/cloud/cf/r2.lyu` — Cloudflare R2, S3-kompatibel, auf Basis von `std/cloud/s3.lyu`.

**Zu implementieren:**

```lyx
struct R2Conn {
    s3:        S3Conn    # intern: std/cloud/s3.lyu S3Conn
    accountId: ptr
}

fn R2Connect(creds: CFCredentials, accountId: ptr) -> R2Conn
# Baut S3Conn mit:
#   endpoint  = accountId + ".r2.cloudflarestorage.com"
#   accessKey = R2_ACCESS_KEY_ID   (eigene Keys, nicht CF-API-Token)
#   secretKey = R2_SECRET_ACCESS_KEY
#   region    = "auto"
fn R2Disconnect(c: R2Conn)

# Bucket-Verwaltung (via CF API, nicht S3):
fn R2BucketCreate(c: CFCredentials, accountId: ptr, bucket: ptr, location: ptr) -> i32
# POST /accounts/{id}/r2/buckets  Body: {"name":"bucket","locationHint":"WEUR"}
fn R2BucketDelete(c: CFCredentials, accountId: ptr, bucket: ptr) -> i32
fn R2BucketList(c: CFCredentials, accountId: ptr) -> ptr    # → Bucket-Namen[]
fn R2BucketExists(c: CFCredentials, accountId: ptr, bucket: ptr) -> bool

# Objekte (via S3-API):
fn R2Upload(c: R2Conn, bucket: ptr, key: ptr, data: ptr, dataLen: i32) -> i32
fn R2Download(c: R2Conn, bucket: ptr, key: ptr) -> DOResponse
fn R2Delete(c: R2Conn, bucket: ptr, key: ptr) -> i32
fn R2Exists(c: R2Conn, bucket: ptr, key: ptr) -> bool
fn R2List(c: R2Conn, bucket: ptr, prefix: ptr) -> ptr
fn R2GetMeta(c: R2Conn, bucket: ptr, key: ptr) -> ptr
fn R2Copy(c: R2Conn, srcBucket: ptr, srcKey: ptr, dstBucket: ptr, dstKey: ptr) -> i32

# Multipart (für > 100 MB):
fn R2MultipartStart(c: R2Conn, bucket: ptr, key: ptr) -> ptr    # → Upload-ID
fn R2MultipartUpload(c: R2Conn, bucket: ptr, key: ptr,
                      uploadId: ptr, partNum: i32,
                      data: ptr, dataLen: i32) -> ptr   # → ETag
fn R2MultipartComplete(c: R2Conn, bucket: ptr, key: ptr,
                        uploadId: ptr, parts: ptr, count: i32) -> i32
fn R2MultipartAbort(c: R2Conn, bucket: ptr, key: ptr, uploadId: ptr) -> i32

# Presigned URLs (Wiederverwendung S3-SigV4):
fn R2PresignedURL(c: R2Conn, bucket: ptr, key: ptr,
                   method: ptr, expirySeconds: i32) -> ptr

# Public Access (via Custom Domain oder r2.dev):
fn R2BucketEnablePublic(c: CFCredentials, accountId: ptr, bucket: ptr) -> i32
# PUT /accounts/{id}/r2/buckets/{bucket}/domains/managed
fn R2PublicURL(accountId: ptr, bucket: ptr, key: ptr) -> ptr
# → "https://pub-<hash>.r2.dev/<key>"

# Custom Domain für R2:
fn R2CustomDomainAdd(c: CFCredentials, accountId: ptr,
                      bucket: ptr, domain: ptr, zoneId: ptr) -> i32
fn R2CustomDomainList(c: CFCredentials, accountId: ptr, bucket: ptr) -> ptr
fn R2CustomDomainRemove(c: CFCredentials, accountId: ptr,
                         bucket: ptr, domain: ptr) -> i32

# R2 Access Keys verwalten (via CF API):
fn R2AccessKeyCreate(c: CFCredentials, accountId: ptr,
                      name: ptr, permissions: ptr) -> ptr
# → {"accessKeyId":"...","secretAccessKey":"..."}
fn R2AccessKeyList(c: CFCredentials, accountId: ptr) -> ptr
fn R2AccessKeyDelete(c: CFCredentials, accountId: ptr, keyId: ptr) -> i32
```

**Dateien:**
- `std/cloud/cf/r2.lyu` (neu)
- Erfordert: `std/cloud/s3.lyu` (WP-S3-01 bis WP-S3-04)

**Akzeptanzkriterien:**
- `R2Upload` + `R2Download` Round-Trip mit Binärdaten
- `R2PublicURL` → Objekt öffentlich abrufbar nach `R2BucketEnablePublic`
- Multipart-Upload überträgt 500-MB-Datei ohne Fehler
- R2 Custom Domain: Objekte via eigener Domain erreichbar

---

### WP-CF-10 — D1 (Edge SQL Database) ⬜

**Ziel:** `std/cloud/cf/d1.lyu` — Cloudflare D1 SQLite-Datenbank via REST API.

**Zu implementieren:**

```lyx
struct CFD1Database {
    uuid:          ptr
    name:          ptr
    version:       ptr    # SQLite-Version
    numTables:     i32
    fileSizeMB:    f64
    created:       ptr
}

# Datenbank-Verwaltung:
fn D1Create(c: CFClient, accountId: ptr, name: ptr) -> CFD1Database
# POST /accounts/{id}/d1/database  Body: {"name":"my-db"}
fn D1Delete(c: CFClient, accountId: ptr, dbId: ptr) -> i32
fn D1Get(c: CFClient, accountId: ptr, dbId: ptr) -> CFD1Database
fn D1GetByName(c: CFClient, accountId: ptr, name: ptr) -> CFD1Database
fn D1List(c: CFClient, accountId: ptr) -> ptr

# SQL-Abfragen:
struct D1Result {
    success:     bool
    results:     ptr    # JSON-Array von Zeilen-Objekten [{"col":"val",...},...]
    meta:        struct {
        duration:    f64    # ms
        lastRowId:   i64
        rowsAffected: i32
        changedDB:   bool
        sizeAfter:   i64
    }
}

fn D1Query(c: CFClient, accountId: ptr, dbId: ptr,
            sql: ptr, params: ptr, paramCount: i32) -> D1Result
# POST /accounts/{id}/d1/database/{dbId}/query
# Body: {"sql":"SELECT * FROM t WHERE id = ?","params":[42]}
fn D1QueryFree(r: D1Result)

fn D1Exec(c: CFClient, accountId: ptr, dbId: ptr, sql: ptr) -> D1Result
# POST .../query ohne params (für DDL: CREATE TABLE, etc.)

fn D1ExecScript(c: CFClient, accountId: ptr, dbId: ptr,
                 sqlScript: ptr) -> ptr
# POST .../export  (mehrere SQL-Statements hintereinander)
# Gibt Array von D1Result zurück

# Ergebnis-Accessoren:
fn D1ResultRowCount(r: D1Result) -> i32
fn D1ResultGetString(r: D1Result, row: i32, col: ptr) -> ptr
fn D1ResultGetInt(r: D1Result, row: i32, col: ptr) -> i64
fn D1ResultGetFloat(r: D1Result, row: i32, col: ptr) -> f64
fn D1ResultGetBool(r: D1Result, row: i32, col: ptr) -> bool
fn D1ResultIsNull(r: D1Result, row: i32, col: ptr) -> bool
fn D1ResultColumns(r: D1Result) -> ptr    # → Spaltennamen-Array

# Batch (mehrere Statements in einer Transaktion):
struct D1Statement {
    sql:    ptr
    params: ptr    # JSON-Array
    count:  i32
}

fn D1Batch(c: CFClient, accountId: ptr, dbId: ptr,
            stmts: ptr, stmtCount: i32) -> ptr    # → D1Result[]
# POST /accounts/{id}/d1/database/{dbId}/query
# Body: [{"sql":"...","params":[]},{"sql":"...","params":[]}]
# Atomare Ausführung: alle oder keine

# Schema-Info:
fn D1Tables(c: CFClient, accountId: ptr, dbId: ptr) -> ptr
# D1Query("SELECT name FROM sqlite_master WHERE type='table'")
fn D1Schema(c: CFClient, accountId: ptr, dbId: ptr, tableName: ptr) -> ptr
# D1Query("SELECT sql FROM sqlite_master WHERE name=?", [tableName])

# Export / Import:
fn D1Export(c: CFClient, accountId: ptr, dbId: ptr) -> ptr
# GET /accounts/{id}/d1/database/{dbId}/export → SQL-Dump
fn D1Import(c: CFClient, accountId: ptr, dbId: ptr,
             sqlDump: ptr, dumpLen: i32) -> i32
```

**Dateien:**
- `std/cloud/cf/d1.lyu` (neu)

**Akzeptanzkriterien:**
- `D1Create` + `D1Exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")` erfolgreich
- `D1Query("INSERT INTO t VALUES (?,?)", [1,"hello"])` → `rowsAffected == 1`
- `D1Query("SELECT * FROM t WHERE id=?", [1])` → Zeile mit `name = "hello"`
- `D1Batch` mit 100 INSERTs: entweder alle oder keiner committed

---

### WP-CF-11 — Pages ⬜

**Ziel:** `std/cloud/cf/pages.lyu` — Cloudflare Pages: Projekte verwalten, Deployments auslösen, Domains konfigurieren.

**Zu implementieren:**

```lyx
struct CFPagesProject {
    id:            ptr
    name:          ptr
    subdomain:     ptr    # "<name>.pages.dev"
    domains:       ptr    # string[] — Custom Domains
    source:        ptr    # Git-Quelle (GitHub/GitLab)
    buildConfig:   struct {
        buildCommand:     ptr    # "npm run build"
        destinationDir:   ptr    # "dist"
        rootDir:          ptr    # ""
        webAnalyticsTag:  ptr
    }
    deploymentConfigs: ptr    # JSON: preview + production Einstellungen
    latestDeployment:  ptr    # CFPagesDeployment
    created:       ptr
    updated:       ptr
}

struct CFPagesDeployment {
    id:          ptr
    projectName: ptr
    environment: ptr    # "production", "preview"
    url:         ptr    # https://<hash>.<name>.pages.dev
    aliases:     ptr    # string[] — Alias-URLs
    stages:      ptr    # Deployment-Phasen [{"name":"build","status":"success"},...]
    buildConfig: ptr
    deploymentTrigger: struct {
        type:     ptr    # "ad_hoc", "github"
        metadata: ptr
    }
    shortId:     ptr    # Kurze Deploy-ID
    created:     ptr
    modified:    ptr
}

# Projekt-Verwaltung:
fn PagesProjectCreate(c: CFClient, accountId: ptr,
                       name: ptr, buildCmd: ptr, outputDir: ptr) -> CFPagesProject
# POST /accounts/{id}/pages/projects
fn PagesProjectDelete(c: CFClient, accountId: ptr, projectName: ptr) -> i32
fn PagesProjectGet(c: CFClient, accountId: ptr, projectName: ptr) -> CFPagesProject
fn PagesProjectList(c: CFClient, accountId: ptr) -> ptr
fn PagesProjectUpdate(c: CFClient, accountId: ptr, projectName: ptr,
                       buildCmd: ptr, outputDir: ptr) -> CFPagesProject

# Direktes Deployment (ohne Git, via File-Upload):
fn PagesDeploy(c: CFClient, accountId: ptr, projectName: ptr,
               branch: ptr, files: ptr, fileCount: i32) -> CFPagesDeployment
# POST /accounts/{id}/pages/projects/{name}/deployments
# multipart/form-data: manifest JSON + alle Dateien

fn PagesDeployDir(c: CFClient, accountId: ptr, projectName: ptr,
                   branch: ptr, dirPath: ptr) -> CFPagesDeployment
# Liest Verzeichnis, baut multipart, deployed

# Deployment-Verwaltung:
fn PagesDeploymentGet(c: CFClient, accountId: ptr,
                       projectName: ptr, deployId: ptr) -> CFPagesDeployment
fn PagesDeploymentList(c: CFClient, accountId: ptr, projectName: ptr) -> ptr
fn PagesDeploymentRetry(c: CFClient, accountId: ptr,
                         projectName: ptr, deployId: ptr) -> CFPagesDeployment
fn PagesDeploymentRollback(c: CFClient, accountId: ptr,
                            projectName: ptr, deployId: ptr) -> CFPagesDeployment
fn PagesDeploymentDelete(c: CFClient, accountId: ptr,
                          projectName: ptr, deployId: ptr) -> i32
fn PagesDeploymentLogs(c: CFClient, accountId: ptr,
                        projectName: ptr, deployId: ptr) -> ptr

# Custom Domains:
fn PagesDomainAdd(c: CFClient, accountId: ptr,
                   projectName: ptr, domain: ptr) -> i32
fn PagesDomainDelete(c: CFClient, accountId: ptr,
                      projectName: ptr, domain: ptr) -> i32
fn PagesDomainList(c: CFClient, accountId: ptr, projectName: ptr) -> ptr

# Umgebungsvariablen:
fn PagesEnvSet(c: CFClient, accountId: ptr, projectName: ptr,
                env: ptr, key: ptr, value: ptr, isSecret: bool) -> i32
# env: "production" | "preview"
fn PagesEnvDelete(c: CFClient, accountId: ptr, projectName: ptr,
                   env: ptr, key: ptr) -> i32
fn PagesEnvList(c: CFClient, accountId: ptr, projectName: ptr, env: ptr) -> ptr
```

**Dateien:**
- `std/cloud/cf/pages.lyu` (neu)

**Akzeptanzkriterien:**
- `PagesDeployDir("dist/")` deployt lokales Build-Verzeichnis
- Deployment-URL unter `<name>.pages.dev` erreichbar nach Deploy
- `PagesDomainAdd("www.example.com")` → Custom Domain aktiv
- `PagesEnvSet("production","API_URL","https://api.example.com",false)` gespeichert

---

### WP-CF-12 — Cloudflare Tunnel (Zero Trust) ⬜

**Ziel:** `std/cloud/cf/tunnel.lyu` — Cloudflare Tunnel erstellen, konfigurieren, Tokens für cloudflared erzeugen.

**Zu implementieren:**

```lyx
struct CFTunnel {
    id:            ptr    # UUID
    name:          ptr
    status:        ptr    # "healthy", "degraded", "down", "inactive"
    credentialsFile: ptr  # JSON-Credentials für cloudflared
    token:         ptr    # Base64-Token für cloudflared
    connections:   ptr    # aktive Verbindungen
    created:       ptr
    deletedAt:     ptr
}

struct CFTunnelConfig {
    tunnelId:  ptr
    version:   i32
    config:    struct {
        ingress: ptr    # Ingress-Regeln[]
    }
}

struct CFIngressRule {
    hostname: ptr    # "app.example.com" (leer = catch-all)
    service:  ptr    # "http://localhost:8080" oder "https://..."
    path:     ptr    # optionaler Pfad-Prefix
    originRequest: ptr  # JSON: SSL, connectTimeout, etc.
}

# Tunnel-Verwaltung:
fn TunnelCreate(c: CFClient, accountId: ptr, name: ptr) -> CFTunnel
# POST /accounts/{id}/cfd_tunnel  Body: {"name":"my-tunnel","tunnel_secret":"<32-byte-hex>"}
fn TunnelDelete(c: CFClient, accountId: ptr, tunnelId: ptr) -> i32
fn TunnelGet(c: CFClient, accountId: ptr, tunnelId: ptr) -> CFTunnel
fn TunnelGetByName(c: CFClient, accountId: ptr, name: ptr) -> CFTunnel
fn TunnelList(c: CFClient, accountId: ptr) -> ptr
fn TunnelCleanup(c: CFClient, accountId: ptr, tunnelId: ptr) -> i32
# DELETE /connections → trennt alle aktiven Verbindungen

# Token für cloudflared:
fn TunnelToken(c: CFClient, accountId: ptr, tunnelId: ptr) -> ptr
# GET /accounts/{id}/cfd_tunnel/{tunnelId}/token
# → Base64-Token, direkt verwendbar als cloudflared --token <token>
fn TunnelTokenSave(c: CFClient, accountId: ptr, tunnelId: ptr, path: ptr) -> i32
# Schreibt Token-Datei für cloudflared

# Ingress-Konfiguration:
fn TunnelConfigGet(c: CFClient, accountId: ptr, tunnelId: ptr) -> CFTunnelConfig
fn TunnelConfigSet(c: CFClient, accountId: ptr, tunnelId: ptr,
                    rules: ptr, ruleCount: i32) -> i32
# PUT /accounts/{id}/cfd_tunnel/{tunnelId}/configurations
# Body: {"config":{"ingress":[{"hostname":"app.example.com","service":"http://localhost:3000"},
#                              {"service":"http_status:404"}]}}

fn TunnelIngressAdd(c: CFClient, accountId: ptr, tunnelId: ptr,
                     hostname: ptr, service: ptr) -> i32
fn TunnelIngressList(c: CFClient, accountId: ptr, tunnelId: ptr) -> ptr

# DNS-Route (CNAME → Tunnel):
fn TunnelDNSRoute(c: CFClient, zoneId: ptr,
                   hostname: ptr, tunnelId: ptr) -> i32
# Erstellt CNAME-Record: hostname → <tunnelId>.cfargotunnel.com
# (Wiederverwendung DNS-API aus WP-CF-03)
fn TunnelDNSUnroute(c: CFClient, zoneId: ptr, hostname: ptr) -> i32

# Verbindungen:
fn TunnelConnectionList(c: CFClient, accountId: ptr, tunnelId: ptr) -> ptr
# → aktive cloudflared-Verbindungen mit connectorId, originIP, etc.

# Virtual Networks (für Split-Tunneling):
fn TunnelVNetCreate(c: CFClient, accountId: ptr, name: ptr, isDefault: bool) -> ptr
fn TunnelVNetList(c: CFClient, accountId: ptr) -> ptr
fn TunnelRouteCreate(c: CFClient, accountId: ptr,
                      network: ptr, tunnelId: ptr, vnetId: ptr) -> ptr
# IP-Route: z.B. "10.0.0.0/8" → Tunnel
fn TunnelRouteList(c: CFClient, accountId: ptr) -> ptr
```

**Dateien:**
- `std/cloud/cf/tunnel.lyu` (neu)

**Akzeptanzkriterien:**
- `TunnelCreate` + `TunnelToken` → `cloudflared tunnel --token <token> run` startet
- `TunnelIngressAdd("app.example.com","http://localhost:3000")` → Route konfiguriert
- `TunnelDNSRoute` erstellt korrekten CNAME-Record in DNS
- `TunnelConnectionList` zeigt aktive cloudflared-Instanzen

---

### WP-CF-13 — Analytics & Logs ⬜

**Ziel:** `std/cloud/cf/analytics.lyu` — Zone-Analytics, GraphQL-Analytics API, Logpush.

**Zu implementieren:**

```lyx
# Basis-Analyse (REST, kein GraphQL):
struct CFAnalyticsDashboard {
    requests: struct {
        all:       i64
        cached:    i64
        uncached:  i64
        ssl:       i64
    }
    bandwidth: struct {
        all:     i64    # Bytes
        cached:  i64
        uncached: i64
    }
    threats:  i64
    pageviews: i64
    uniques:   i64
}

struct CFAnalyticsTimeseries {
    since:  ptr
    until:  ptr
    totals: CFAnalyticsDashboard
    timeseries: ptr    # Array von Perioden mit je einem CFAnalyticsDashboard
}

fn AnalyticsDashboard(c: CFClient, zoneId: ptr,
                       since: i64, until: i64) -> CFAnalyticsDashboard
# GET /zones/{zoneId}/analytics/dashboard?since=-1440&until=0
fn AnalyticsTimeseries(c: CFClient, zoneId: ptr,
                        since: i64, until: i64) -> CFAnalyticsTimeseries

# GraphQL Analytics API (für detailliertere Abfragen):
fn AnalyticsGraphQL(c: CFClient, query: ptr, variables: ptr) -> ptr
# POST https://api.cloudflare.com/client/v4/graphql
# Body: {"query":"...","variables":{...}}
# → rohe JSON-Antwort

# Hilfsabfragen via GraphQL:
fn AnalyticsTop10IPs(c: CFClient, zoneId: ptr, hours: i32) -> ptr
# → [{ip, requests, threats}]
fn AnalyticsTop10URLs(c: CFClient, zoneId: ptr, hours: i32) -> ptr
fn AnalyticsFirewallEvents(c: CFClient, zoneId: ptr, hours: i32) -> ptr
fn AnalyticsWorkerInvocations(c: CFClient, accountId: ptr, scriptName: ptr, hours: i32) -> ptr

# Web Analytics (RUM - Real User Monitoring):
fn WebAnalyticsSiteCreate(c: CFClient, accountId: ptr, host: ptr) -> ptr
# POST /accounts/{id}/web3/hostnames → Analytics-Site-Tag
fn WebAnalyticsSiteList(c: CFClient, accountId: ptr) -> ptr

# Logpush (für Log-Streaming an S3, R2, Datadog, etc.):
struct CFLogpushJob {
    id:                 i32
    name:               ptr
    enabled:            bool
    dataset:            ptr    # "http_requests","firewall_events","dns_logs"
    destinationConf:    ptr    # "s3://bucket/path?region=eu-west-1&..."
                               # "r2://bucket/path?account-id=..."
                               # "https://endpoint" (Datadog/Splunk/etc.)
    logpullOptions:     ptr    # Felder-Filter
    lastComplete:       ptr
    lastError:          ptr
    errorMessage:       ptr
}

fn LogpushJobCreate(c: CFClient, zoneId: ptr,
                     name: ptr, dataset: ptr,
                     destination: ptr, fields: ptr) -> CFLogpushJob
fn LogpushJobUpdate(c: CFClient, zoneId: ptr, jobId: i32,
                     enabled: bool, destination: ptr) -> CFLogpushJob
fn LogpushJobDelete(c: CFClient, zoneId: ptr, jobId: i32) -> i32
fn LogpushJobList(c: CFClient, zoneId: ptr) -> ptr
fn LogpushJobCheck(c: CFClient, zoneId: ptr,
                    destination: ptr) -> i32
# POST .../validate/destination → prüft Schreibzugriff

# Verfügbare Datasets:
# "http_requests" — HTTP-Traffic-Logs
# "firewall_events" — WAF/Firewall-Events
# "nel_reports" — Network Error Logging
# "spectrum_events" — Spectrum/TCP-Proxy
# "dns_logs" — DNS-Abfragen (Enterprise)
# "audit_logs" — Account-Aktivitäten
```

**Dateien:**
- `std/cloud/cf/analytics.lyu` (neu)

**Akzeptanzkriterien:**
- `AnalyticsDashboard` gibt reale Request-/Bandwidth-Zahlen zurück
- `AnalyticsGraphQL` führt Custom-Query aus
- `LogpushJobCreate` mit R2-Destination → Logs erscheinen in R2-Bucket
- `LogpushJobCheck` schlägt bei ungültigem Bucket-Pfad fehl

---

### WP-CF-14 — Email Routing ⬜

**Ziel:** `std/cloud/cf/email.lyu` — Cloudflare Email Routing: Weiterleitungsregeln, Catch-All, Custom Addresses.

**Zu implementieren:**

```lyx
# Email Routing Settings:
fn EmailRoutingGet(c: CFClient, zoneId: ptr) -> ptr
# GET /zones/{zoneId}/email/routing  → enabled, name, tag, created
fn EmailRoutingEnable(c: CFClient, zoneId: ptr) -> i32
fn EmailRoutingDisable(c: CFClient, zoneId: ptr) -> i32

# DNS-Records für Email Routing:
fn EmailRoutingDNSGet(c: CFClient, zoneId: ptr) -> ptr
# GET /zones/{zoneId}/email/routing/dns
# → Array der benötigten MX/TXT-Records (zum Vergleich mit IST-Zustand)
fn EmailRoutingDNSVerify(c: CFClient, zoneId: ptr) -> bool
# Prüft ob alle DNS-Records korrekt gesetzt sind

# Routing Rules:
struct CFEmailRule {
    id:       ptr
    name:     ptr
    enabled:  bool
    priority: i32
    matchers: ptr   # [{"type":"literal","field":"to","value":"info@example.com"}]
                    # field: "to","from","subject"
                    # type: "literal","all"
    actions:  ptr   # [{"type":"forward","value":["user@gmail.com"]}]
                    # type: "forward","worker","drop"
}

fn EmailRuleCreate(c: CFClient, zoneId: ptr,
                    name: ptr, fromAddr: ptr,
                    toAddr: ptr) -> CFEmailRule
# Kurzform: Weiterleitung von fromAddr → toAddr

fn EmailRuleCreateWorker(c: CFClient, zoneId: ptr,
                          name: ptr, matchAddr: ptr,
                          workerName: ptr) -> CFEmailRule
# Leitet an Worker weiter (für E-Mail-Processing)

fn EmailRuleDelete(c: CFClient, zoneId: ptr, ruleId: ptr) -> i32
fn EmailRuleList(c: CFClient, zoneId: ptr) -> ptr
fn EmailRuleUpdate(c: CFClient, zoneId: ptr, ruleId: ptr,
                    rule: CFEmailRule) -> CFEmailRule

# Catch-All:
fn EmailCatchAllGet(c: CFClient, zoneId: ptr) -> CFEmailRule
fn EmailCatchAllSet(c: CFClient, zoneId: ptr,
                     action: ptr, destination: ptr) -> i32
# action: "forward","worker","drop"

# Destination Addresses (Verifizierung):
fn EmailDestinationCreate(c: CFClient, accountId: ptr, email: ptr) -> ptr
# POST /accounts/{id}/email/routing/addresses → sendet Verifizierungs-E-Mail
fn EmailDestinationDelete(c: CFClient, accountId: ptr, destId: ptr) -> i32
fn EmailDestinationList(c: CFClient, accountId: ptr) -> ptr
# → [{email, verified, created}]
```

**Dateien:**
- `std/cloud/cf/email.lyu` (neu)

**Akzeptanzkriterien:**
- `EmailRoutingEnable` + `EmailRuleCreate` → E-Mail wird weitergeleitet
- `EmailRoutingDNSVerify` gibt true wenn MX/TXT-Records korrekt
- Catch-All mit Drop-Action → unbekannte Adressen werden verworfen
- `EmailRuleCreateWorker` → Worker empfängt E-Mail-Events

---

### WP-CF-15 — `lyxcf` CLI ⬜

**Ziel:** `bin/lyxcf` — Kommandozeilen-Tool analog zu `wrangler`/`flarectl`, nutzt das Lyx CF SDK.

**Zu implementieren:**

```
lyxcf <command> [subcommand] [flags]

Globale Flags:
  --token       API-Token (überschreibt CLOUDFLARE_API_TOKEN)
  --account     Account-ID
  --zone        Zone-ID oder Domain-Name (wird automatisch aufgelöst)
  --config      Konfig-Datei (default: ~/.config/lyxcf/config.json)
  --format      Ausgabeformat: json|text|table (default: text)

Befehle:

  auth
    login                        → Token interaktiv eingeben + speichern
    check                        → Token validieren
    token                        → aktuellen Token ausgeben

  zone
    list
    get <domain>
    create <domain>
    delete <domain>
    pause <domain>
    unpause <domain>
    purge <domain> [--all] [--url https://example.com/style.css]
    settings get <domain> <setting>
    settings set <domain> <setting> <value>
    settings list <domain>
    activate-check <domain>

  dns
    list [--type A] [--name www]
    create --type A --name www --content 1.2.3.4 [--proxied] [--ttl 300]
    update <record-id> --content 5.6.7.8
    delete <record-id>
    upsert --type A --name api --content 1.2.3.4
    export                       → BIND-Zonefile auf stdout
    import <zone-file>

  cache
    purge --all
    purge --files https://example.com/img/logo.png
    purge --tags tag1,tag2

  firewall
    rules list
    rules create --expression "(ip.src eq 1.2.3.4)" --action block
    rules delete <id>
    ip-rules list [--type block]
    ip-rules block <ip|cidr|country|asn> [--note "bot"]
    ip-rules allow <value>
    ip-rules delete <id>
    ratelimit list
    ratelimit create --url "*/api/*" --threshold 100 --period 60 --action ban

  lb
    list
    create --name lb.example.com --pools <pool-id>
    delete <id>
    pools list
    pools create --name prod --origins "1.2.3.4:80,5.6.7.8:80"
    pools delete <id>
    healthchecks list
    healthchecks create --name check --url https://example.com/health

  workers
    list
    deploy <script.js> --name my-worker
    delete <name>
    routes list
    routes create --pattern "example.com/api/*" --script my-worker
    routes delete <id>
    kv list
    kv create-ns <title>
    kv get <ns-id> <key>
    kv put <ns-id> <key> <value> [--ttl 3600]
    kv delete <ns-id> <key>
    secret set <script> <key>    → Wert interaktiv eingeben
    secret delete <script> <key>
    secret list <script>
    cron list <script>
    cron create <script> --cron "0 * * * *"

  r2
    buckets list
    buckets create <bucket> [--location WEUR]
    buckets delete <bucket>
    objects list <bucket> [--prefix path/]
    objects put <bucket>/<key> <local-file>
    objects get <bucket>/<key> [--output <file>]
    objects delete <bucket>/<key>
    presign <bucket>/<key> [--ttl 3600]
    access-keys list
    access-keys create --name <name>
    access-keys delete <id>

  d1
    list
    create <name>
    delete <id>
    execute <db-name|id> --command "SELECT 1"
    execute <db-name|id> --file schema.sql
    export <db-name|id> [--output dump.sql]
    import <db-name|id> --file dump.sql
    info <db-name|id>            → Größe, Tabellen

  pages
    list
    create --name my-site [--build-cmd "npm run build"] [--output dist]
    delete <name>
    deploy <name> <dir>          → deployt lokales Verzeichnis
    deployments list <name>
    deployments rollback <name> <deploy-id>
    domains list <name>
    domains add <name> <domain>
    env set <name> --env production <KEY=VALUE>
    env list <name>

  tunnel
    list
    create <name>
    delete <id>
    token <id>                   → Token für cloudflared ausgeben
    info <id>                    → Ingress-Config + Verbindungen
    route add <id> <hostname> <service>
    route list <id>
    dns-route <id> <hostname>    → CNAME-Record erstellen

  analytics
    dashboard --zone <domain> [--since -1440]
    top-ips --zone <domain>
    top-urls --zone <domain>
    firewall-events --zone <domain>

  email
    status <domain>
    enable <domain>
    rules list <domain>
    rules create <domain> --from info@example.com --to user@gmail.com
    rules delete <domain> <id>
    catch-all set <domain> --action forward --dest user@gmail.com
    destinations list
```

**Dateien:**
- `bin/lyxcf.lyu` (neu) — CLI-Dispatcher
- `bin/lyxcf_zone.lyu` (neu)
- `bin/lyxcf_dns.lyu` (neu)
- `bin/lyxcf_workers.lyu` (neu)
- `bin/lyxcf_r2.lyu` (neu)
- `bin/lyxcf_d1.lyu` (neu)
- `bin/lyxcf_pages.lyu` (neu)
- `bin/lyxcf_tunnel.lyu` (neu)
- `bin/lyxcf_analytics.lyu` (neu)
- `bin/lyxcf.lyx` (Binär)

**Akzeptanzkriterien:**
- `lyxcf auth check` gibt Account-E-Mail und Token-Gültigkeitsstatus aus
- `lyxcf dns list --zone example.com` gibt formatierte Tabelle aller Records
- `lyxcf r2 objects put my-bucket/key.txt local.txt` lädt Datei hoch
- `lyxcf d1 execute my-db --command "SELECT COUNT(*) FROM users"` gibt Ergebnis aus
- `lyxcf tunnel token <id>` gibt Token für `cloudflared` direkt auf stdout

---

### WP-CF-16 — Demos & Integrationstests ⬜

**Ziel:** End-to-End-Beispielprogramme und vollständige Integrationstests.

**Zu implementieren:**

Demo 1 — DNS-Verwaltung für Multi-Umgebung:
```lyx
import std/cloud/cf/dns
import std/cloud/cf/zones

fn main() {
    let creds = CFCredentialsFromEnv()
    let zone = ZoneGetByDomain(creds, "example.com")

    # Produktions-IP setzen
    DNSRecordUpsert(creds, zone.id, "A", "@",   "1.2.3.4",  1, true)
    DNSRecordUpsert(creds, zone.id, "A", "www", "1.2.3.4",  1, true)
    DNSRecordUpsert(creds, zone.id, "A", "api", "5.6.7.8",  1, false)

    # MX für E-Mail
    DNSRecordCreate(creds, zone.id, "MX", "@", "mail.example.com", 300, false)

    # SPF + DKIM + DMARC
    DNSRecordCreate(creds, zone.id, "TXT", "@",
                    "v=spf1 include:_spf.google.com ~all", 300, false)

    # Cache leeren
    CachePurgeAll(creds, zone.id)
    println("DNS konfiguriert, Cache geleert.")
}
```

Demo 2 — Worker + KV + R2 Edge-App:
```lyx
import std/cloud/cf/workers
import std/cloud/cf/kv
import std/cloud/cf/r2

fn main() {
    let creds = CFCredentialsFromEnv()
    let accountId = "a1b2c3d4..."

    # KV-Namespace erstellen
    let ns = KVNamespaceCreate(creds, accountId, "app-cache")
    KVPut(creds, accountId, ns.id, "config", '{"maxItems":100}', 17)

    # R2-Bucket erstellen und Datei hochladen
    let r2 = R2Connect(creds, accountId)
    R2BucketCreate(creds, accountId, "app-assets", "WEUR")
    R2Upload(r2, "app-assets", "index.html",
             "<html><body>Hello from Lyx!</body></html>", 38)

    # Worker deployen mit KV + R2 Binding
    let script = '
      export default {
        async fetch(req, env) {
          const config = await env.CACHE.get("config");
          return new Response("Config: " + config);
        }
      }
    '
    let bindings = '[{"type":"kv_namespace","name":"CACHE","namespace_id":"' + ns.id + '"}]'
    WorkerDeployWithBindings(creds, accountId, "edge-app",
                              script, strLen(script),
                              bindings, strLen(bindings))

    # Route konfigurieren
    let zone = ZoneGetByDomain(creds, "example.com")
    WorkerRouteCreate(creds, zone.id, "example.com/app/*", "edge-app")
    println("Worker + KV + R2 deployed.")
}
```

Demo 3 — D1 Edge-Datenbank:
```lyx
import std/cloud/cf/d1

fn main() {
    let creds = CFCredentialsFromEnv()
    let accountId = "a1b2c3d4..."

    let db = D1Create(creds, accountId, "app-db")
    D1Exec(creds, accountId, db.uuid,
           "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")

    let batch = [
        D1Statement{"INSERT INTO users VALUES (?,?,?)", ["1","Alice","alice@example.com"], 3},
        D1Statement{"INSERT INTO users VALUES (?,?,?)", ["2","Bob","bob@example.com"], 3}
    ]
    D1Batch(creds, accountId, db.uuid, batch, 2)

    let result = D1Query(creds, accountId, db.uuid,
                          "SELECT * FROM users WHERE id = ?", ["1"], 1)
    println("User: " + D1ResultGetString(result, 0, "name"))
}
```

Demo 4 — Cloudflare Tunnel + DNS:
```lyx
import std/cloud/cf/tunnel
import std/cloud/cf/dns

fn main() {
    let creds = CFCredentialsFromEnv()
    let accountId = "a1b2c3d4..."
    let zone = ZoneGetByDomain(creds, "example.com")

    # Tunnel erstellen
    let t = TunnelCreate(creds, accountId, "home-server")
    TunnelIngressAdd(creds, accountId, t.id, "home.example.com", "http://localhost:8080")
    TunnelIngressAdd(creds, accountId, t.id, "nas.example.com", "http://192.168.1.50:5000")

    # DNS-Records für Tunnel
    TunnelDNSRoute(creds, zone.id, "home.example.com", t.id)
    TunnelDNSRoute(creds, zone.id, "nas.example.com", t.id)

    # Token ausgeben
    let token = TunnelToken(creds, accountId, t.id)
    println("Starte cloudflared mit:")
    println("  cloudflared tunnel --token " + token + " run")
}
```

Demo 5 — WAF + Rate Limiting + Analytics:
```lyx
import std/cloud/cf/waf
import std/cloud/cf/analytics

fn main() {
    let creds = CFCredentialsFromEnv()
    let zone = ZoneGetByDomain(creds, "example.com")

    # Länder blocken
    let blockedCountries = ["CN","RU","KP"]
    FirewallBlockCountry(creds, zone.id, blockedCountries, 3, "Geo-Block")

    # API-Endpunkt rate-limiting
    RateLimitCreate(creds, zone.id, "*/api/*",
                    100, 60, "ban", 3600)

    # Security Level auf "high"
    ZoneSetSecurityLevel(creds, zone.id, "high")

    # Analytics ausgeben
    let stats = AnalyticsDashboard(creds, zone.id, -1440, 0)
    println("Requests letzte 24h: " + stats.requests.all)
    println("Threats blocked:     " + stats.threats)
    println("Bandwidth:           " + stats.bandwidth.all + " Bytes")
}
```

Integrationstests:
```lyx
fn testDNSCRUD(creds: CFCredentials, zoneId: ptr) -> bool
fn testCachePurge(creds: CFCredentials, zoneId: ptr) -> bool
fn testKVRoundtrip(creds: CFCredentials, accountId: ptr) -> bool
fn testR2RoundTrip(creds: CFCredentials, accountId: ptr) -> bool
fn testD1CRUD(creds: CFCredentials, accountId: ptr) -> bool
fn testFirewallRuleCreateDelete(creds: CFCredentials, zoneId: ptr) -> bool
fn testWorkerDeploy(creds: CFCredentials, accountId: ptr) -> bool
fn testCredentialChain() -> bool
fn testPaginationDNSList(creds: CFCredentials, zoneId: ptr) -> bool
fn testRateLimitHandling(creds: CFCredentials) -> bool
```

**Dateien:**
- `demo_cf.lyu` (neu)
- `demo_cf.lyx` (Binär)
- `tests/cf_integration.lyu` (neu)

**Akzeptanzkriterien:**
- Alle 5 Demos laufen ohne Fehler mit echtem CF-Token
- Integrationstests grün gegen Test-Zone + Test-Account
- Cleanup nach Tests (keine verwaisten DNS-Records, Worker, KV-Namespaces)
- `testRateLimitHandling` übersteht bewussten Burst (429 → Retry → Erfolg)

---

## Empfohlene Implementierungsreihenfolge

```
Woche 1:    WP-CF-01          → Transport + Credentials (Fundament)
Woche 1:    WP-CF-02          → Zones
Woche 1-2:  WP-CF-03          → DNS (meistgenutzter Service)
Woche 2:    WP-CF-04          → Cache + Page Rules
Woche 2:    WP-CF-05          → WAF + Firewall
Woche 2-3:  WP-CF-06          → Load Balancing
Woche 3:    WP-CF-07          → Workers
Woche 3:    WP-CF-08          → Workers KV
Woche 3-4:  WP-CF-09          → R2 (erfordert std/cloud/s3.lyu)
Woche 4:    WP-CF-10          → D1
Woche 4:    WP-CF-11          → Pages
Woche 4-5:  WP-CF-12          → Tunnel
Woche 5:    WP-CF-13          → Analytics + Logs
Woche 5:    WP-CF-14          → Email Routing
Woche 5-6:  WP-CF-15          → lyxcf CLI
Woche 6:    WP-CF-16          → Demos + Tests
```

## Vergleich mit anderen Cloud-SDKs

| Aspekt              | Cloudflare            | DigitalOcean          | AWS                    | GCP                     |
|---------------------|-----------------------|-----------------------|------------------------|-------------------------|
| Auth                | Bearer Token (einfach)| Bearer Token (einfach)| SigV4 (komplex)        | JWT/OAuth2 (komplex)    |
| DNS                 | Kernprodukt (API v4)  | Domains API           | Route 53               | Cloud DNS               |
| Edge Computing      | Workers (V8 isolates) | Functions (OpenWhisk) | Lambda@Edge            | Cloud Functions          |
| Objekt-Storage      | R2 (S3-kompatibel)    | Spaces (S3-kompatibel)| S3                     | GCS                     |
| Edge SQL            | D1 (SQLite)           | –                     | Aurora Serverless      | –                       |
| KV Store            | Workers KV            | –                     | DynamoDB               | Firestore               |
| CDN / Proxy         | Kernprodukt           | Spaces CDN            | CloudFront             | Cloud CDN               |
| WAF                 | Integriert            | Cloud Firewalls        | WAF                    | Cloud Armor             |
| Tunnel              | Cloudflare Tunnel     | –                     | AWS VPN                | Cloud VPN               |
| API-Komplexität     | ★★★☆☆ (mittel)       | ★★☆☆☆ (minimal)      | ★★★★★ (sehr komplex)   | ★★★★☆ (komplex)        |
| Crypto-Voraussetzung| keine                 | keine                 | SHA-256 + HMAC         | RSA + SHA-256 + JWT     |
| Implementierungszeit| ~6 Wochen             | ~7 Wochen             | ~12 Wochen             | ~9 Wochen               |
