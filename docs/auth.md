# Auth — Apple Business API OAuth (client-assertion)

*Verified 2026-07-04 against Apple's OAuth documentation, Apple Support, and live testing. Confidence per item.*

## Base URLs
| Platform | API host + prefix | OAuth `scope` |
|---|---|---|
| Apple **Business** (us) | `https://api-business.apple.com/v1/` | `business.api` |
| Apple **School** | `https://api-school.apple.com/v1/` | `school.api` |

Same OAuth mechanics; only host + scope differ. **ABM-only surfaces:** Configurations, Blueprints, Users,
UserGroups, Apps, Packages, AuditEvents, mdmDevices. Device/MDM resources (`orgDevices`, `mdmServers`,
`orgDeviceActivities`) exist on both.

## Token flow (OAuth2 client_credentials + JWT bearer)
Token endpoint is a **different host** (`account.apple.com`) than the API.
```
POST https://account.apple.com/auth/oauth2/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
client_id=BUSINESSAPI.<uuid>
client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
client_assertion=<ES256-signed JWT>
scope=business.api
```
- Response: `{ "access_token","token_type":"Bearer","expires_in":3600 }`. **Bearer TTL 60 min** (read `expires_in`, don't hard-code). Refresh when <5 min remain and re-mint on any `401`.
- `/oauth2/token` and `/oauth2/v2/token` both resolve; POST the token request to `/token`.
- `client_id` in the form body is redundant with the JWT, but include it — the token endpoint expects it.

## JWT client assertion
**Header:** `{ "alg":"ES256", "typ":"JWT" }` — ES256 = ECDSA **P-256** + SHA-256. **OMIT `kid`.**
> ✅ **Verified live 2026-07-04:** including **any** `kid` (Key ID, account name, or Client ID) → `400 invalid_client`; **omitting `kid` → success**. Apple resolves the key by `client_id` + signature against the registered public key, so **no Key ID is needed** — this corrects a common assumption. Client ID + private key alone authenticate.

**Claims (all six):**
| Claim | Value |
|---|---|
| `sub` | Client ID (`BUSINESSAPI.<uuid>`) |
| `iss` | Client ID — **same as `sub`** (Apple's doc mislabels it `team_id`; do not invent a team id) |
| `aud` | `https://account.apple.com/auth/oauth2/v2/token` — **must be the `/v2/token` form** |
| `iat` | now (UNIX UTC seconds) |
| `exp` | **strictly `< iat + 180 days`** — use e.g. `iat + 179d` to stay inside the exclusive bound. Long-lived + reusable across many token calls (mint once, cache). |
| `jti` | fresh UUID per assertion |

## Console setup
**Settings > API** → `https://business.apple.com/main/preferences/integrations/apis`. Needs **Organization
Administrator**. Up to 50 API accounts. On create you get **Client ID** + **Key ID** (both re-copyable) and
**Generate & Download** the private key.

## Gotchas
- **A — key is download-once.** Client ID / Key ID stay retrievable; the private key is **not** re-downloadable. Lost key ⇒ roll a new Key ID.
- **B — key format.** ES256 signing uses an **unencrypted EC P-256** key. Apple's download is SEC1 (`BEGIN EC PRIVATE KEY`); `abctl` reads SEC1 **and** PKCS#8 (`BEGIN PRIVATE KEY`) directly (`x509.ParseECPrivateKey` / `x509.ParsePKCS8PrivateKey`), and scans **all** PEM blocks — so a two-block file with a leading `BEGIN EC PARAMETERS` block (how OpenSSL, and some ABM downloads, emit EC keys) also works as-is. So **no conversion is needed**. Only an **encrypted** key must be converted first: `openssl pkcs8 -topk8 -nocrypt -in <key> -out key_pkcs8.pem`.
- **C — "Device API Manager" migrated role.** Orgs migrated from ABM/Essentials keep a device-only API role. It gets **`403` on `/v1/blueprints` and `/v1/configurations`** until **View/Manage Blueprints** + **Create/edit/delete device configurations** are explicitly granted and the key regenerated. *(Watch for this on first write attempt — medium confidence it's unchecked by default.)*

