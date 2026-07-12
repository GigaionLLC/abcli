# Read-only endpoints — Users, Groups, Apps, Packages, Audit, Devices (ABM)

*Verified 2026-07-04. All GET, all `Authorization: Bearer`, paginated via `links.next`.*

## Users & User Groups — **Implicit Permission** (every API account has these; cannot be revoked)
| Endpoint | Path | Response |
|---|---|---|
| List users | `GET /v1/users` | `UsersResponse` data[] of `User` |
| Get user | `GET /v1/users/{id}` | `UserResponse` |
| List groups | `GET /v1/userGroups` | `UserGroupsResponse` |
| Get group | `GET /v1/userGroups/{id}` | `UserGroupResponse` |
| Group members | `GET /v1/userGroups/{id}/relationships/users` | **linkages only** `{type:"users",id}` → resolve via `/v1/users/{id}` |

> **Identity is READ-ONLY via this API (verified live 2026-07-05).** `POST /v1/users` and `POST /v1/userGroups`
> both return `403 FORBIDDEN_ERROR — "The resource '…' does not allow 'CREATE'. Allowed operations are:
> GET_COLLECTION, GET_INSTANCE"`. There is **no create/update/delete** for users or userGroups — so abctl
> cannot create a throwaway member. Users/groups are created only in the **Apple Business console**, via
> **federated identity** (Google/Microsoft auto-provision on first sign-in), or via **SCIM** (a separate User
> Management protocol, not this API). ⇒ a blueprint's required member must be console-created or a real device.

`User`: `firstName,lastName,email,managedAppleId,status,roles[](role+organizationalUnit),phoneNumbers[]`. `UserGroup`: `name,status,groupType,created/updatedDateTime`.

## Apps & Packages
| Endpoint | Path | Permission (verbatim) |
|---|---|---|
| Get Apps | `GET /v1/apps` (+ `/{id}`) | **View Apps.** |
| Get Packages | `GET /v1/packages` (+ `/{id}`) | **View and manage devices using built-in device management.** |

`App`: `name,bundleId,version,supportedOS,isCustomApp`. `/v1/apps` = the organization's
licensed/Blueprint-assignable apps. `abctl` deliberately does not fall back to the VPP content-token API:
that token connects an external MDM and is outside the built-in-management product boundary. Surface the
license-deficiency information provided by Apple Business/Blueprints rather than claiming full VPP license
counts. **Packages is a device-management privilege, not an Apps permission.** *(Open: whether `/v1/apps` is
the full Apps & Books catalog or only Blueprint-linked.)*

## Audit Events
`GET /v1/auditEvents` — permission **"Access audit events using the Admin API."**
- **Required** query: `filter[startTimestamp]` + `filter[endTimestamp]` (ISO 8601). ⚠️ Use the **`Timestamp`** spelling — the `filter[startDateTime]`/`endDateTime` variants seen in some references do NOT match the docs; the docs win.
- Optional: `filter[actorId]`, `filter[subjectId]`, `filter[eventType]` (`CONFIG_SETTINGS_CREATED/UPDATED/DELETED`, `DEVICE_ASSIGNED_TO_SERVER`, …). Use to reconcile that API-driven changes landed.

## Devices / MDM assignment (on BOTH Business + School)
- **Read** (`View device management services…`): `GET /v1/orgDevices`, `/v1/orgDevices/{id}`, `/v1/mdmServers`, `/v1/mdmServers/{id}/relationships/devices`, `/v1/orgDevices/{id}/relationships/assignedServer`, `/v1/orgDeviceActivities/{id}`.
- **Write** (`Assign devices to device management services.`): `POST /v1/orgDeviceActivities` (`activityType` = `ASSIGN_DEVICES` / `UNASSIGN_DEVICES`) — bulk device↔MDM-server assignment.
