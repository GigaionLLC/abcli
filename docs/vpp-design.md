# VPP / Apps & Books — design + verified API reference

`abctl` speaks two Apple services. The **Apple Business API** (`api-business.apple.com/v1`,
ES256 client-assertion) drives built-in-MDM Configurations + Blueprints. **Apps & Books
license management** — how many app/book licenses the org owns, and who they're assigned to
— lives in a *separate* service with a *different* credential: the **App and Book
Management API** (`vpp.itunes.apple.com/mdm/v2`), authenticated with a **content token
(sToken)** downloaded from Apple Business Manager → **Apps and Books → download content
token**. This document is the verified API reference + the plan to add it to abctl (and,
on top of that, abgui).

> **AI-authored** under Gigaion, LLC's direction, like the rest of this repo. The v2 API
> facts below are transcribed from Apple's current developer documentation (DocC), verified
> 2026-07. Live end-to-end verification against a real content token is **pending a token**
> (Gigaion has no VPP-licensed content to test against yet); until then the client is
> verified against the *documented* request/response shapes via `httptest`, and a live
> integration test self-skips without a token.

## 1. Auth + discovery

- **Credential:** the base64 **sToken** (a.k.a. content token / location token) from ABM.
  It is sensitive (grants license assignment) and is **never committed** — abctl reads it
  from `$AB_VPP_TOKEN` (the token string), `$AB_VPP_TOKEN_FILE` (a path), or `--vpp-token`.
- **Header:** every request sends `Authorization: Bearer <sToken>`. A malformed header
  returns Apple error `9722`; a missing/expired token returns **HTTP 401**.
- **Base:** `https://vpp.itunes.apple.com/mdm/v2` (overridable via `$AB_VPP_BASE` for tests).
- **Discovery:** `GET /service/config` returns a `urls` map of every endpoint plus a
  `limits` object. abctl uses it as the token validator; the fixed v2 paths below equal the
  discovered URLs (same base), so abctl builds paths directly and keeps discovery for
  validation.

The **legacy** API (`POST /mdm/getVPP…Srv` with `sToken` in the JSON body) is explicitly in
maintenance mode; abctl uses **v2 only**.

## 2. Verified v2 endpoints

| Purpose | Method + path | Notes |
|---|---|---|
| **Service config** | `GET /service/config` | `urls{…}`, `limits{maxAssets:25, maxUsers:100, maxClientUserIds:1000, maxSerialNumbers:1000, …}`, `notificationTypes[]`, `errorCodes[]`. Read-only; validates the token. |
| **Get assets** | `GET /assets` | The org's owned apps/books + license counts. |
| **Get assignments** | `GET /assignments` | Which asset is assigned to which device/user. |
| **Get users** | `GET /users` | Registered Managed Apple ID VPP users. |
| Associate / disassociate | `POST /assets/associate` · `/assets/disassociate` | **Writes** (assign/unassign licenses). Out of scope for the read-only v1 (see §5). |
| Revoke · users create/update/retire · client config · status | `…/assets/revoke`, `/users/*`, `/client/config`, `/status` | Later. |

### `GET /assets` (the hero)

Query params (all optional): `pageIndex` (int32), `productType` (`App`|`Book`),
`pricingParam` (`STDQ`|`PLUS`), `revocable` (bool), `deviceAssignable` (bool), `adamId`,
`unlimited`, `min/maxAvailableCount`, `min/maxAssignedCount`.

Response (`200`; `400`/`401`/`500` are `ErrorResponse`):

```json
{ "assets": [ {
    "adamId": "408709785", "productType": "App", "pricingParam": "STDQ",
    "availableCount": 10000, "assignedCount": 5000, "retiredCount": 0, "totalCount": 15000,
    "deviceAssignable": true, "revocable": true, "supportedPlatforms": ["iOS"] } ],
  "currentPageIndex": 0, "size": 5, "totalPages": 1,
  "tokenExpirationDate": "2030-11-08T22:33:22+0000", "uId": "…", "versionId": "…" }
```

- `adamId` is the App Store product id (string). Human names aren't in this response —
  they come from the content-metadata lookup (later; the Business API's `/v1/apps` carries
  names). abctl shows the adamId + counts; abgui can cross-reference names later.
- **Pagination:** loop `pageIndex` 0..`totalPages-1`, accumulating `assets`.
- **Counts** are the answer to "how many licenses do we own / have free": `totalCount =
  availableCount + assignedCount + retiredCount`.

`GET /assignments` and `GET /users` follow the same v2 shape (Bearer, `pageIndex`,
`currentPageIndex`/`totalPages` paging). Assignment ≈ `{adamId, pricingParam, serialNumber?,
clientUserId?}`; user ≈ `{clientUserId, email?, status, …}`. These two are modeled from the
docs and will be field-checked against a live token when one is available.

## 3. abctl surface (read-only v1)

A new `internal/vpp` client (standalone — different host + auth from `internal/ab`) and a
`vpp` command group. All read-only, all honoring the global `-o table|json|yaml`:

| Command | Endpoint | Shows |
|---|---|---|
| `abctl vpp config` | `GET /service/config` | token OK? org/location, limits — the VPP "whoami". |
| `abctl vpp assets [--type App\|Book] [--pricing STDQ\|PLUS] [--adam-id N]` | `GET /assets` | apps/books + license counts (auto-paginated) |
| `abctl vpp assignments [--adam-id N] [--serial S] [--user U]` | `GET /assignments` | asset → device/user |
| `abctl vpp users` | `GET /users` | registered VPP users |

Token resolution: `--vpp-token` › `$AB_VPP_TOKEN` › `$AB_VPP_TOKEN_FILE`. Base override:
`$AB_VPP_BASE`. `vpp config` is the connection test (like `auth whoami` for the Business
API). Capability token `vpp-json` is added to `version --json` so a GUI can gate on it.

## 4. abgui (on top of abctl — same as every other screen)

abgui shells out to `abctl vpp … -o json` and renders — no new API code in Swift. A new
**Read-only** sidebar group section or entries: **Apps & Books (VPP)** → assets table
(adamId, type, pricing, available/assigned/total, device-assignable), **VPP Assignments**,
**VPP Users**, plus a VPP connection indicator (from `vpp config`). All read-only, badged
like the other read-only screens. The content token is configured out-of-band (env/flag);
abgui never handles the token bytes.

## 5. Writes (later)

`associate`/`disassociate` assign/unassign licenses (batch: ≤25 assets × ≤1000 serials or
client-user-ids per call; async — returns an event id, poll `/status`). These are genuine
tenant mutations that consume/reassign licenses, so they land **after** read-only browse is
solid and only behind abctl's standard `--yes`/confirm gating (and abgui's own confirm) —
mirroring how config/blueprint writes were staged.
