# Upcoming release

Theme: **visibility and operational confidence for Apple Business built-in device management**.

## User-facing additions

- **OS Releases:** browse Apple's managed, public, and Rapid Security Response catalogs; filter by platform,
  build, catalog, or supported product identifier; expired releases are hidden by default.
- **Device release comparison:** from a device posture report, compare its last-reported OS with the newest
  matching managed/public catalog entries. This is explicitly catalog context, not eligibility or install proof.
- **Assignment results:** activity status includes created/completed timestamps, detailed status/substatus, and
  Apple's presigned result CSV. The CLI can download it to a new explicitly named file.
- **Audit filtering:** narrow tenant activity by time window, event-type substring, and actor name/id.
- **System Health:** see the bundled CLI version, tenant/API identity, token expiration, capability count, and
  cached inventory totals.
- **What's New:** an in-app summary of this product release. Apple's developer API changelog remains a
  maintainer input rather than a user menu.

## Safety and scope

- GDMF is read-only, response-bounded, TLS-verified, and cached for six hours with ETag revalidation.
- Activity downloads require an explicit destination, require HTTPS, never overwrite, cap size at 64 MiB, and
  remove partial files after errors.
- VPP content-token and legacy DEP integrations remain unsupported because they operate external MDM services,
  outside this product's Apple Business built-in-management boundary.

## Release gates

- `go test ./...`, `go vet ./...`, and `git diff --check` must pass.
- macOS CI must compile and test `abgui` and build the app bundle.
- Manually inspect the OS Releases, device comparison, assignment result, System Health, and What's New screens.
- Live-check GDMF from a normal macOS trust store and live-verify assign/unassign using a throwaway device.
- Do not claim the newer tenant write verbs are supported until their existing live-verification checklist is
  complete.
