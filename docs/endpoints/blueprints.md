# Blueprints — `/v1/blueprints` (Apple Business only)

*Verified 2026-07-04 (Apple DocC JSON + live testing agree on paths/verbs/bodies — all HIGH confidence). Not present in the Apple School Manager API.*

A Blueprint is the deploy target: it references configurations/apps/packages and is assigned to
devices/users/groups. **Permissions:** READ = `View Blueprints`; WRITE = `Manage Blueprints`.

**Resource (JSON:API):**
```
{ type:"blueprints", id,
  attributes:{ name, description, status(ACTIVE|TO_BE_DELETED), appLicenseDeficient(bool),
               createdDateTime, updatedDateTime },
  relationships:{ apps, configurations, packages, orgDevices, users, userGroups } }
```
**No `default` attribute** — a "default platform assignment" is a separate Devices privilege, not a Blueprint attribute.

## CRUD
| Op | Method | Path | Perm | OK |
|---|---|---|---|---|
| List | GET | `/v1/blueprints` | View Blueprints | 200 |
| Create | POST | `/v1/blueprints` | Manage Blueprints | 201 |
| Get | GET | `/v1/blueprints/{id}` | View Blueprints | 200 |
| Update | PATCH | `/v1/blueprints/{id}` | Manage Blueprints | 200 |
| Delete | DELETE | `/v1/blueprints/{id}` | Manage Blueprints | 204 |

Create body: `{ "data": { "type":"blueprints", "attributes":{ "name":"<required>", "description":"<opt>" }, "relationships":{ "users":{ "data":[{ "type":"users","id":"<id>" }] }, "configurations":{ "data":[{ "type":"configurations","id":"<id>" }] } } } }`. **Create REQUIRES BOTH (verified live 2026-07-05):** (1) ≥1 **member** from `orgDevices`/`users`/`userGroups` — else `409 ENTITY_ERROR…MISSING_MEMBERS`; **and** (2) ≥1 **content** resource from `apps`/`packages`/`configurations` — else `409 ENTITY_ERROR.RELATIONSHIP.INVALID.MISSING_RESOURCES` ("missing the required 'apps/packages/configurations' resource. At least one must be provided."). A member-only or content-only create is rejected. Update = same shape + `data.id`. `DELETE /v1/blueprints/{id}` → **204** (immediate; a referenced config can then be deleted).

## Member (relationship) ops — the "move a device between groups" primitive
Pattern `/v1/blueprints/{id}/relationships/<relation>` for **six** relations: `orgDevices`, `configurations`, `apps`, `packages`, `userGroups`, `users`. (Device relation is **`orgDevices`**, not `devices`.)

| Op | Method | Path | Body | OK |
|---|---|---|---|---|
| Get IDs | GET | `.../relationships/<relation>` | none | 200 → linkages `data:[{type,id}]` |
| Add | POST | `.../relationships/<relation>` | `{ "data":[{ "type":"<relation>","id":"..." }] }` | 204 |
| Remove | DELETE | `.../relationships/<relation>` | **DELETE with body** `{ "data":[{ "type":"<relation>","id":"..." }] }` | 204 |

- GET returns **linkage IDs only** → resolve via `GET /v1/orgDevices/{id}`, `/v1/configurations/{id}`, etc.
- ✅ **`relationships` POST MERGES (verified live 2026-07-05).** A per-member `POST` to `.../relationships/configurations` is **additive** — POSTing config B to a blueprint already holding config A yields `[A, B]`, not `[B]`. `DELETE`-with-body removes exactly the listed member (`[A,B]` DELETE A → `[B]`). ⇒ abctl's converge-by-explicit-per-member-`POST`/`DELETE` strategy is correct. (Tested on the `configurations` relation with a throwaway user member; the device-side "does assigning to a new Blueprint reassign a device away from its current one" question still needs a real test device.)

**Deploy a profile = two phases:** (1) `POST /v1/configurations` (upload the `.mobileconfig` resource), then (2) `POST /v1/blueprints/{id}/relationships/configurations` with `{data:[{type:"configurations",id}]}`. Creating a config does **not** deploy it.

**Open:** exact GET query params (filter/sort/fields/limit/cursor) not enumerated (pagination via `links.next` confirmed); per-role checkmark matrix for `Manage Blueprints` not fully extracted.
