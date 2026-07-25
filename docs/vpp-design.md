# VPP / Apps & Books — design + verified API reference

> **⚠️ EXTERNAL-MDM API — NOT A PRODUCT FEATURE.** Apple Business can provide an organizational-unit
> content token, but Apple documents that token as the connection to an **external device-management
> service**. Apple warns that an external service must release the primary organization's token before
> built-in management owns that pool, or license inventory and app assignments can become inconsistent.
> Apple does permit an isolated external lane through an additional OU, transferred unassigned licenses, and
> that OU's token; this is technically supported coexistence but remains outside `abctl`'s product boundary.
> The implementation is therefore **disabled by default**: `abctl vpp` is
> hidden and errors unless the existing developer-only `ABCTL_ENABLE_VPP=1` escape hatch is set,
> and abgui has no VPP screen or enable toggle. Do not offer that escape hatch as an end-user GUI
> setting. The implementation is retained as quarantined reference code, not as roadmap scope.
> **For built-in MDM, manage Apps & Books via blueprints** — see [design-abctl.md](design-abctl.md)
> and `abctl get blueprint <id>` (apps + `appLicenseDeficient`) / `abctl attach app … --blueprint …`.
> **A VPP association allocates a license; it does not install the app.** An external MDM must subsequently
> send an `AppManaged` declaration or `InstallApplication` command. The end-to-end decision handoff is
> [app-provisioning-research.md](app-provisioning-research.md).
> Source: [Apple's content-token guidance](https://support.apple.com/guide/business/manage-content-tokens-axme0f8659ec/web).

`abctl` speaks two Apple services. The **Apple Business API** (`api-business.apple.com/v1`,
ES256 client-assertion) drives built-in-MDM Configurations + Blueprints. **Apps & Books
license management** — how many app/book licenses the org owns, and who they're assigned to
— lives in a *separate* service with a *different* credential: the **App and Book
Management API** (`vpp.itunes.apple.com/mdm/v2`), authenticated with a **content token
(sToken)** downloaded from Apple Business Manager → **Apps and Books → download content
token**. This document preserves the verified API reference and explains why it is outside the
Apple-Business-built-in-MDM product boundary.

> **AI-authored** under Gigaion, LLC's direction, like the rest of this repo. The v2 API
> facts below are transcribed from Apple's current developer documentation (DocC).
>
> **Live-verified (2026-07) against the real API** with a Gigaion, LLC content token: the auth
> form is confirmed — the **outer base64 sToken** (the `.vpptoken` file's contents,
> verbatim) as `Authorization: Bearer …` is what the server accepts (the *inner* decoded
> `token` field is rejected as `9622`). `GET /service/config` succeeds, and the client
> correctly surfaces Apple's error envelope. The token on hand is **revoked** (`9625 "The
> server has revoked the sToken."` — downloading a newer content token in ABM revokes older
> ones), so **listing actual inventory awaits a fresh, non-revoked content token**. Client
> logic is otherwise verified against the documented shapes via `httptest` + a
> self-skipping live integration test.

## 1. Auth + discovery

- **Credential:** the base64 **sToken** (a.k.a. content token / location token) from ABM.
  It is sensitive (grants license assignment) and is **never committed** — abctl reads it
  from `$AB_VPP_TOKEN` (the token string), `$AB_VPP_TOKEN_FILE` (a path), or `--vpp-token`.
- **Header:** every request sends `Authorization: Bearer <sToken>`. A malformed header
  returns Apple error `9722`; a missing/expired token returns **HTTP 401**.
- **Base:** `https://vpp.itunes.apple.com/mdm/v2` (overridable via `$AB_VPP_BASE` for tests).
- **Discovery:** `GET /service/config` returns a `urls` map of every endpoint plus a
  `limits` object. The fixed v2 paths below equal the discovered URLs (same base), so abctl builds paths
  directly and keeps discovery for limits/metadata. This endpoint is lenient and can respond for a revoked
  token; `abctl vpp config` probes `/assets` before declaring the token valid for data.

The **legacy** API (`POST /mdm/getVPP…Srv` with `sToken` in the JSON body) is explicitly in
maintenance mode; abctl uses **v2 only**.

## 2. Verified v2 endpoints

| Purpose | Method + path | Notes |
|---|---|---|
| **Service config** | `GET /service/config` | `urls{…}`, dynamic `limits{…}`, `notificationTypes[]`, `errorCodes[]`. Discovery only; probe `/assets` to validate data access. |
| **Get assets** | `GET /assets` | The org's owned apps/books + license counts. |
| **Get assignments** | `GET /assignments` | Which asset is assigned to which device/user. |
| **Get users** | `GET /users` | Registered Apps & Books distribution users (`clientUserId` namespace). |
| Associate / disassociate | `POST /assets/associate` · `/assets/disassociate` | Hidden/gated writes are built; live verification awaits a safe token/pool. |
| Status | `GET /status?eventId=…` | Hidden read is built for async associate/disassociate polling. |
| Revoke · users create/update/retire · client config | `…/assets/revoke`, `/users/*`, `/client/config` | Not implemented. |

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

## 3. Quarantined abctl read surface

`internal/vpp` is standalone — a different host and credential from `internal/ab` — with a hidden `vpp`
command group. Its reads honor the global `-o table|json|yaml`; section 6 records the hidden gated writes.

| Command | Endpoint | Shows |
|---|---|---|
| `abctl vpp config` | `GET /service/config` | token OK? org/location, limits — the VPP "whoami". |
| `abctl vpp assets [--type App\|Book] [--pricing STDQ\|PLUS] [--adam-id N]` | `GET /assets` | apps/books + license counts (auto-paginated) |
| `abctl vpp assignments [--adam-id N] [--serial S] [--user U]` | `GET /assignments` | asset → device/user |
| `abctl vpp users` | `GET /users` | registered VPP users |

Token resolution: `--vpp-token` › `$AB_VPP_TOKEN` › `$AB_VPP_TOKEN_FILE`. Base override:
`$AB_VPP_BASE`. `vpp config` fetches service metadata and probes `/assets` as the connection test (like
`auth whoami` for the Business API). No `vpp-json` capability is advertised in `version --json` while the path is
quarantined, so no GUI should gate a screen on one.

## 4. Identity, installation, and token ownership

- Device association uses a literal `serialNumber`. VPP does not provide device inventory; obtain serials
  from the MDM/CMDB or resolve Apple organization inventory separately.
- User association uses an MDM-selected `clientUserId`. It is not an Apple Business `/v1/users` resource ID,
  Managed Apple Account, or necessarily an email address. User creation/invitation is a separate VPP flow.
- Association consumes/allocates a license only. Installation requires an external MDM's declarative
  [`AppManaged`](https://developer.apple.com/documentation/devicemanagement/appmanaged) configuration or
  [`InstallApplication`](https://developer.apple.com/documentation/devicemanagement/install-application-command)
  command and its enrollment/APNs/status infrastructure.
- Exactly one client should own a token/location pool. If an existing MDM owns it, use that MDM's supported
  API instead of racing it with `abctl`.
- Primary-pool built-in/external sharing is unsafe. Apple's supported external coexistence lane is an additional
  OU, transferred **unassigned** licenses, and that OU's content token. Do not assume this secondary pool feeds
  built-in Blueprint installation.
- Tokens expire after one year and can be invalidated by password changes or replacement downloads. Treat the
  complete outer Base64 `.vpptoken` contents as a secret and plan renewal.
- Batch examples are not constants: fetch `/service/config` and honor its current limits.

See [Apple's user model](https://developer.apple.com/documentation/devicemanagement/managing-users),
[organizational-unit guidance](https://support.apple.com/guide/business/configure-organizational-units-axmfdbe2cb0d/web),
and [content-token guidance](https://support.apple.com/guide/business/manage-content-tokens-axme0f8659ec/web).

## 5. abgui decision

Do not add a VPP screen, connection indicator, token field, feature flag, or “advanced” toggle. Even a
read-only inventory request makes `abgui` look like an external MDM integration and encourages operators to
attach the primary organization's content token contrary to the built-in-management workflow. The useful
built-in experience is the Apple Business API app catalog, Blueprint app membership, and
`appLicenseDeficient` state already exposed through `abctl`/`abgui`.

## 6. Writes — built (gated), live-test pending a token

`associate`/`disassociate` assign/unassign licenses via `POST /assets/associate` ·
`/assets/disassociate` with the symmetric `ManageAssetsRequest` body
`{assets:[{adamId,pricingParam}], clientUserIds:[], serialNumbers:[]}` → async
`EventResponse{eventId,…}`. Apple's current service-config examples report ≤25 assets and ≤1000 serials or
client-user-ids per call, but callers must use the live dynamic limits. Poll completion with
`GET /status?eventId=`.

Shipped in abctl (read + write, all httptest-verified):

| Command | Endpoint | Notes |
|---|---|---|
| `abctl vpp associate   --adam-id N [--pricing STDQ] --serial S… --user U… [--yes]` | `POST /assets/associate` | gated write; async → eventId |
| `abctl vpp disassociate --adam-id N … [--yes]` | `POST /assets/disassociate` | gated write; async → eventId |
| `abctl vpp status <eventId>` | `GET /status?eventId=` | poll; raw map (shape field-checked live) |

Gating mirrors config/blueprint writes: confirm unless `--yes`/`$ABCTL_APPROVE`. These are
genuine tenant mutations (they consume/reassign licenses), so **live verification is
deferred until a fresh content token exists** — they can't be safely exercised against real
licenses before then. The `/status` response shape is modeled and will be confirmed live.
No abgui write UI is planned. The CLI commands remain hidden developer/reference functionality and must not
be used against the primary organizational unit while Apple Business built-in device management owns it.
