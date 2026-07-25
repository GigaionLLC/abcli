# Apple app provisioning automation — research handoff

> **Research date:** 2026-07-15  
> **Purpose:** preserve the current Apple-supported options for assigning App Store content to device serial
> numbers and users. This is a decision/reference handoff, not authorization to expand `abctl` into an
> external MDM. The durable product boundary remains in [design-abctl.md](design-abctl.md).

## Executive conclusion

Apple exposes two supported automation paths, and they must not be conflated:

1. **Apple Business built-in device management:** use the **Apple Business API** to put an owned app and its
   target devices/users/groups in a Blueprint. Apple performs license allocation and managed installation.
   This is the supported `abctl` path.
2. **External MDM:** use the **App, Book, and Subscription Management API v2** (the successor to VPP web
   services) to assign a license to a literal serial number or MDM-defined user, then use an MDM command or
   declarative configuration to install the app. License association alone does not install anything.

There is no documented Apple API for acquiring free or paid app licenses. Acquisition remains a portal
operation; automation can resume after the license inventory changes.

The April 2026 change did **not** make VPP free or require Apple to be the organization's "primary MDM."
Apple launched the free Apple Business service on 2026-04-14 and included the device-management features
formerly sold through Apple Business Essentials. Apple permits multiple device-management services, with one
service controlling a given enrolled device. The apparent lock is an Apps & Books **content-token /
organizational-unit ownership rule**, not a global primary-MDM rule.

Sources: [Apple Business launch](https://www.apple.com/newsroom/2026/03/introducing-apple-business-a-new-all-in-one-platform-for-businesses-of-all-sizes/),
[device-management services](https://support.apple.com/guide/business/intro-to-device-management-services-axm659f6bd48/web),
[API changelog](https://developer.apple.com/documentation/apple-school-and-business-manager-api/apple-school-manager-and-apple-business-api-changelog).

## The provisioning lifecycle

Treat provisioning as four separate operations. No single Apple endpoint performs all four.

| Operation | Apple built-in management | External MDM |
|---|---|---|
| Acquire licenses | Apple Business portal | Apple Business portal |
| Resolve targets | Apple Business `/v1/orgDevices`, `/users`, `/userGroups` | MDM inventory/CMDB; optionally Apple Business inventory |
| Allocate a license | App + target membership in a Blueprint | `POST /mdm/v2/assets/associate` |
| Install/manage the app | Apple processes the Blueprint | MDM `AppManaged` declaration or `InstallApplication` command |
| Observe | `mdmDevices`, Blueprint `appLicenseDeficient`, richer portal status | VPP assignments/event status plus MDM-reported install state |

This separation explains the common false positive: a successful VPP association proves that a license is
allocated, not that the device received or installed the app.

## Path A — built-in management and Apple Business Blueprints

### What Apple added in 2026

Apple Business API **v2.0 (2026-04-14)** added app/package reads, built-in-MDM device reads, Blueprint CRUD,
and all six Blueprint relationships: `apps`, `packages`, `configurations`, `orgDevices`, `users`, and
`userGroups`. **v2.1 (2026-06-03)** added device-management-service create/update/delete.

Apple published **v2.2 on this research date (2026-07-15)** with three read-only organizational-unit
endpoints: list OUs, get an OU, and get the user IDs related to an OU. This improves OU discovery but does not
create OUs, transfer licenses, download/manage content tokens, or assign apps. `abctl` does not yet implement or
live-verify these new reads.

The app catalog endpoint is specifically a built-in-management surface. Apple's Get App Information page
directs organizations not using built-in management to the Apps & Books APIs instead.

Sources: [API changelog](https://developer.apple.com/documentation/apple-school-and-business-manager-api/apple-school-manager-and-apple-business-api-changelog),
[Get App Information](https://developer.apple.com/documentation/applebusinessapi/get-app-information),
[Get Organizational Units](https://developer.apple.com/documentation/applebusinessapi/get-organizational-units).

### Supported API flow

```text
GET  /v1/apps
GET  /v1/orgDevices
GET  /v1/users
GET  /v1/userGroups

POST /v1/blueprints
POST /v1/blueprints/{id}/relationships/apps
POST /v1/blueprints/{id}/relationships/orgDevices
POST /v1/blueprints/{id}/relationships/users
POST /v1/blueprints/{id}/relationships/userGroups

GET  /v1/mdmDevices
GET  /v1/blueprints/{id}
```

Resolve a serial number through `orgDevices` and send the returned resource ID in the Blueprint relationship;
do not assume the resource ID is the serial just because some Apple examples use identical-looking values.
Similarly, resolve users and groups through the Apple Business resources rather than passing an email or group
name directly to Apple.

A Blueprint create must contain both:

- at least one target member from `orgDevices`, `users`, or `userGroups`; and
- at least one content member from `apps`, `packages`, or `configurations`.

The repository live-verified this create constraint and the additive relationship-POST behavior on the
configuration relationship. See [endpoints/blueprints.md](endpoints/blueprints.md).

Sources: [Get organization devices](https://developer.apple.com/documentation/applebusinessapi/get-org-devices),
[add organization devices to a Blueprint](https://developer.apple.com/documentation/applebusinessapi/add-org-devices-to-a-blueprint),
[create a Blueprint](https://developer.apple.com/documentation/applebusinessapi/create-a-blueprint).

### Target semantics

- **Device/serial target:** intended for organization-owned Automated Device Enrollment devices, including
  shared, kiosk, and dedicated devices. It does not depend on a Managed Apple Account.
- **User target:** follows enrolled devices associated with the Managed Apple Account.
- **User-group target:** applies the Blueprint as group membership changes, making directory-driven scoping
  practical.
- **Personal/BYOD devices:** Apple does not expose the same serial-centric organization inventory; target the
  user through an appropriate account-driven enrollment flow.

Users and groups are read-only in the Apple Business API. Provision Managed Apple Accounts through federation
or SCIM, then resolve and attach them through the Blueprint API. A Blueprint user ID is unrelated to VPP's
`clientUserId` described below.

Sources: [enrollment methods](https://support.apple.com/guide/business/enrollment-methods-axma9a72e8a5/web),
[apply Blueprints](https://support.apple.com/guide/business/apply-blueprints-axm0d43737a4/web),
[SCIM identity sync](https://support.apple.com/guide/business/sync-user-accounts-identity-provider-axm526a05814/web).

### Portal-only and observability gaps

As of API v2.2, no documented endpoint was found for:

- acquiring initial or additional app licenses, including free apps;
- changing an app between automatic and manual installation;
- obtaining the portal's detailed per-device pending/installed/failed/rejected state or exact license counts;
- creating, updating, or deleting Apple Business users and user groups.

The API-visible health signals are useful but incomplete: `appLicenseDeficient` identifies a deficient
Blueprint, and `mdmDevices` provides last-reported device posture/check-in information. Do not label either as
proof that an app installed successfully.

Sources: [get licenses](https://support.apple.com/guide/business/get-licenses-for-apps-and-books-axmc21817890/web),
[configure app installation](https://support.apple.com/guide/business/configure-app-installation-axmf6ab5d3eb/web),
[monitor installation and licenses](https://support.apple.com/guide/business/monitor-app-installation-status-license-axm55bdc7f27/web).

### Existing `abctl` coverage

The repository already implements the required native primitives:

```text
abctl get apps|devices|users|usergroups|blueprints|mdmdevices
abctl attach app <name|adam-id|bundle-id> --blueprint <name|id>
abctl attach device <serial|id>           --blueprint <name|id>
abctl attach user <email|account|id>      --blueprint <name|id>
abctl attach group <name|id>              --blueprint <name|id>
```

GitOps Blueprint manifests can reconcile all six relationship collections. The optional `apps:`, `packages:`,
`devices:`, `users:`, and `groups:` keys are unmanaged when absent and authoritative when present; detaches
remain gated by `--prune`.

Current verification boundary:

- Blueprint create plus configuration membership/additive POST: live-verified.
- App/device/user/group resolvers and relationship writes: built, unit-tested, and gated, but not yet exercised
  end-to-end on a real enrolled test device.
- Exact on-device installation cannot currently be verified through the Apple Business API; confirm it in the
  Apple Business portal during the first controlled rollout.

## Path B — Apps & Books v2 plus an external MDM

### What the API actually does

The App, Book, and Subscription Management API v2 is the current successor to legacy VPP services:

```text
https://vpp.itunes.apple.com/mdm/v2
```

An app-to-device license association uses a literal hardware serial number:

```http
POST /assets/associate
Authorization: Bearer <complete-content-token>
Content-Type: application/json

{
  "assets": [{"adamId": "361309726", "pricingParam": "STDQ"}],
  "serialNumbers": ["C02EXAMPLE"]
}
```

The response is asynchronous. Poll `GET /status?eventId=...` and verify with
`GET /assignments?serialNumber=...`. `POST /assets/disassociate` removes specified assignments;
`POST /assets/revoke` removes all revocable assets for the specified targets.

Fetch `/service/config` regularly for the current URLs, notification types, and dynamic limits. Apple's
examples allow 25 assets and 1,000 serial numbers or client-user IDs per request, but the service response is
authoritative. Arrays have cross-product semantics: multiple assets multiplied by multiple users/serials can
create far more tasks than the input length suggests.

Sources: [getting started](https://developer.apple.com/documentation/devicemanagement/getting-started-with-the-management-api),
[associate assets](https://developer.apple.com/documentation/devicemanagement/associate-assets),
[manage assets](https://developer.apple.com/documentation/devicemanagement/managing-assets),
[upgrade from the legacy API](https://developer.apple.com/documentation/devicemanagement/upgrading-to-the-new-management-api).

### User identity is a separate namespace

VPP user assignment uses `clientUserId`, a stable identifier chosen by the MDM/client. It is not an Apple
Business `/v1/users/{id}`, email address, or Managed Apple Account identifier. The client creates and manages
the VPP distribution-user record through `/users/create`, `/users/update`, and `/users/retire`.

When a same-organization Managed Apple Account is supplied, association may complete immediately. Other users
can require an invitation flow. Creating this VPP record does not create an Apple Business user.

Source: [Managing users](https://developer.apple.com/documentation/devicemanagement/managing-users).

### License association still needs an install channel

After association, the enrolled device must receive either:

- a declarative `AppManaged` configuration, where supported; or
- the classic `InstallApplication` MDM command.

This requires an external MDM's enrollment, APNs, command/declaration, retry, and status infrastructure. A
standalone VPP script has no such channel. If a commercial MDM already owns the content token, prefer its API
so the same control plane coordinates both the license and installation.

Sources: [AppManaged](https://developer.apple.com/documentation/devicemanagement/appmanaged),
[Install Application](https://developer.apple.com/documentation/devicemanagement/install-application-command),
[managed-app deployment](https://support.apple.com/guide/deployment/distribute-managed-apps-dep575bfed86/web).

### Content-token and organizational-unit coexistence

Apple's supported coexistence model is:

1. Do not let a separate client manage the primary organizational unit's content token while built-in
   management owns that pool.
2. Create an additional organizational unit for the external-management lane.
3. Transfer **unassigned** licenses into it.
4. Download that OU's content token and let exactly one external MDM/client manage it.

Treat the secondary OU as an external-MDM license pool. Apple does not document using a secondary external
pool as the source for built-in Blueprint installation, so do not design around cross-pool behavior without
written Apple confirmation.

Content tokens expire after one year and can be invalidated by password changes or replacement downloads. Use
a dedicated least-privilege Managed Apple Account, store the complete token as a secret, and plan renewal and
takeover detection. A successful `/service/config` response is not sufficient proof that a token can access
data; validate with `/assets`.

Sources: [manage content tokens](https://support.apple.com/guide/business/manage-content-tokens-axme0f8659ec/web),
[configure organizational units](https://support.apple.com/guide/business/configure-organizational-units-axmfdbe2cb0d/web),
[transfer licenses](https://support.apple.com/guide/business/transfer-licenses-axm1242b0715/web),
[client configuration](https://developer.apple.com/documentation/devicemanagement/client-config-4szk1).

### Existing quarantined implementation

`internal/vpp` and the hidden `abctl vpp` commands currently cover:

- service config, assets, assignments, and users reads;
- associate/disassociate writes; and
- asynchronous status polling.

The outer Base64 `.vpptoken` contents, sent verbatim as the bearer token, were live-verified. The available
token was revoked, so real inventory and all VPP writes remain unverified. The implementation is hidden behind
`ABCTL_ENABLE_VPP=1` and is reference code, not a supported product feature.

If product scope ever explicitly expands to an external-OU integration, missing production pieces include:

- VPP user create/update/retire and invitation handling;
- `/client/config`, unique `mdmInfo`, notifications, and polling fallback;
- revoke-all and subscription endpoints if required;
- persistent reconciliation/idempotency state, rate-limit handling, retry/backoff, token renewal, and audit;
- an external MDM adapter or a deliberately separate installation control plane.

Do not enable the hidden commands or add an abgui token screen merely because the protocol is technically
available.

## Adjacent options and APIs

| Option | What it helps automate | Why it is not the complete answer |
|---|---|---|
| Apple Business API v2.1 MDM-service CRUD and `orgDeviceActivities` | Create/manage external service records and route organization devices | Assigns a device to a service, not an app to a device |
| Apple Business API v2.2 organizational-unit reads | Discover OUs and their user relationships | Read-only; no OU creation, license transfer, token management, or app assignment |
| Apps & Books Metadata for Organizations | Adam IDs, bundle IDs, versions, platforms, artwork | Catalog metadata only; no acquisition, license assignment, or install |
| SCIM/federation | Managed Apple Account lifecycle | Identity only; attach the resulting user through a Blueprint or MDM |
| App Store Connect API | The publisher workflow for the organization's own apps/builds/TestFlight | Not fleet distribution of arbitrary App Store apps |
| Apple Configurator + `cfgutil`/Automator | Scripted staging of physically attached iPhone/iPad/Apple TV devices | Local/physical, not remote fleet management or user targeting |
| Custom MDM/NanoMDM | Full command and declaration channel | Requires APNs, enrollment, ADE, certificates/SCEP, commands, status, security, and operations; it is a separate product |

An existing MDM's supported API is usually preferable to direct VPP work. Examples reviewed during this
research were Microsoft Graph/Intune app assignments, Jamf Pro device/app scoping, SimpleMDM app and assignment
groups, and Kandji/Iru Library Item assignments. These remain outside `abctl`'s current scope.

Sources: [Apps & Books metadata](https://developer.apple.com/documentation/devicemanagement/apps-and-books-for-organizations),
[App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi/),
[Apple Configurator app installation](https://support.apple.com/guide/apple-configurator-mac/add-apps-to-a-device-cad4cd08c03/mac),
[MDM vendor certificate](https://developer.apple.com/help/account/certificates/mdm-vendor-csr-signing-certificate),
[NanoMDM](https://github.com/micromdm/nanomdm).

## Recommended next action for this repository

Keep the native Blueprint route as the supported product path and live-verify it before adding more code:

1. In the Apple Business portal, acquire one free test app and set it to automatic installation.
2. Use one throwaway organization-owned ADE device enrolled in built-in management.
3. Confirm `abctl get apps`, `get devices`, and `get mdmdevices` resolve the app and device.
4. Dry-run and then attach the app plus device to a throwaway Blueprint with the existing gated commands or
   GitOps reconciler.
5. Confirm `appLicenseDeficient == false`, inspect Apple Business installation status, and verify on-device
   installation manually.
6. Detach and clean up through the same gated path.
7. Record the result in `HANDOFF.md`, `TODO.md`, and the relevant endpoint reference.

If a future human explicitly chooses external-MDM support, design it as a separate secondary-OU integration
with a clear token owner and installation adapter. Do not silently broaden the primary built-in-management
product boundary.
