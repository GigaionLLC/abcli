# Configurations — `/v1/configurations`

*Verified 2026-07-04 (Apple DocC JSON + Apple Support + live testing). All headers: `Authorization: Bearer <token>`, `Accept: application/json`.*

**This is the programmatic `.mobileconfig` push path.** Full CRUD, but **only `CUSTOM_SETTING` (custom
`.mobileconfig`) configs can be created/updated via API** — every other type is read-only.

| Endpoint | Method | Path | Permission | Conf |
|---|---|---|---|---|
| List | GET | `/v1/configurations` | View device configurations (read) | high |
| Get | GET | `/v1/configurations/{id}` | View device configurations | high |
| Create | POST | `/v1/configurations` | Create, edit, and delete device configurations (write) | high |
| Update | PATCH | `/v1/configurations/{id}` | Create, edit, and delete device configurations | high |
| Delete | DELETE | `/v1/configurations/{id}` | Create, edit, and delete device configurations | high |

*WRITE permission string confirmed verbatim (support guide); READ string medium.*

**List** — query `fields[configurations]` ⊆ `[type,name,configuredForPlatforms,customSettingsValues,createdDateTime,updatedDateTime]`, `limit` ≤1000. Returns `ConfigurationsResponse` (`data[]`), **all** types (native typed configs visible read-only). Paginated via `links.next`.

**Get** — `200 → ConfigurationResponse`. For `CUSTOM_SETTING`: `attributes.customSettingsValues.{configurationProfile, filename}`.

**Create (`CUSTOM_SETTING` only)** — authoritative body:
```json
{ "data": {
    "type": "configurations",
    "attributes": {
      "name": "<REQUIRED string>",
      "type": "CUSTOM_SETTING",
      "configuredForPlatforms": ["PLATFORM_MACOS"],
      "customSettingsValues": {
        "configurationProfile": "<RAW .mobileconfig XML, starting <?xml …>",
        "filename": "Settings.mobileconfig"
      }
    } } }
```
- **Required:** `data.type="configurations"`, `attributes.name`, `attributes.type="CUSTOM_SETTING"`.
- Discriminator is **`type`** (NOT `configurationType`); profile nests under **`customSettingsValues`** (NOT a flat `payload`/`displayName`). `configuredForPlatforms` optional (auto-detected).
- `201 → ConfigurationResponse`. Errors `400/401/403/409/422/429`; **`422` = profile validation failure**.
- ✅ **RESOLVED live 2026-07-04:** `configurationProfile` is **RAW XML**, not base64. `GET /v1/configurations/{id}` returns it starting `<?xml version="1…` and it **round-trips** (so drift can be byte-compared). Send the raw `.mobileconfig` XML string on create/update (schema labels the type `byte`, but the live API uses raw XML — verify once on your first live POST that create accepts raw too).
- ⚠️ **Some third-party references show the wrong create body** (a flat `configurationType`, omitting `customSettingsValues`). Use the schema above: discriminator `type` + nested `customSettingsValues`.

**Update (`CUSTOM_SETTING` only)** — same envelope + `data.id`; updatable `name`, `configuredForPlatforms`, `customSettingsValues.*`. `200`.

**Delete** — `204`. No explicit type restriction documented on delete.

**Profile constraints (HIGH — Apple support):** `.mobileconfig` extension, **< 1 MB**, ≥1 platform common to ALL payloads. Apple validates before saving → API `422`. (`abctl validate` checks these before upload.)

**ConfigurationType enum (23; only `CUSTOM_SETTING` writable):** `AIR_DROP, AIR_PRINT, APP_ACCESS, APPLE_INTELLIGENCE_SIRI, APPLICATION_LAYER_FIREWALL, AUTHENTICATION_SCREEN_LOCK, CERTIFICATE, CONFERENCE_ROOM_DISPLAY, CONTENT_CACHING, CUSTOM_PROFILE, CUSTOM_SETTING, DATA_MANAGEMENT, ENERGY_SAVER, FILE_VAULT, GATE_KEEPER, ICLOUD, LOGIN_WINDOW, MEDIA_MANAGEMENT, SOFTWARE_UPDATE, VPN, WEB_CLIP, WEB_FILTER, WIFI`. *(`CUSTOM_PROFILE` ≠ `CUSTOM_SETTING`; the former is read-only.)* Note: only `CUSTOM_SETTING` (your own `.mobileconfig`) is API-writable, so author managed settings as payloads inside a custom profile.

**Deploy step (separate):** create only *uploads the resource*. A **Blueprint deploys it** — attach via `POST /v1/blueprints/{id}/relationships/configurations` (see [blueprints.md](blueprints.md)).
