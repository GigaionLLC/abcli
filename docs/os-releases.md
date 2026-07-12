# Apple software releases (GDMF)

`abctl get os-releases` reads Apple's public GDMF software-update catalog at
`https://gdmf.apple.com/v2/pmv`. It is independent of tenant authentication and performs no writes.

```sh
abctl get os-releases
abctl get os-releases --platform macOS
abctl get os-releases --catalog managed
abctl get os-releases --catalog public --device MacBookPro18,3
abctl get os-releases --include-expired -o json
abctl status device C02EXAMPLE --releases -o json
```

Filters are case-insensitive. `--catalog` accepts:

- `managed`: releases in `AssetSets`, available to device-management services.
- `public`: releases in `PublicAssetSets`, available through the public update flow.
- `rsr`: public Rapid Security Responses.

Expired releases are omitted by default when GDMF supplies an expiration date in the past. Releases with no
expiration date remain visible. The default endpoint is cached under the user's cache directory for six hours;
stale entries use ETag conditional revalidation when Apple supplies one. `AB_GDMF_URL` overrides the endpoint
for tests and disables the default persistent cache.

## Interpretation boundary

The catalog says that Apple lists a release for a platform or product identifier. It does **not** prove that a
specific device is eligible, that Apple Business scheduled the update, or that the device installed it. Any
future comparison with built-in-MDM posture must retain that distinction and show catalog freshness.

The GDMF schema is modeled from `micromdm/apple-device-services` and tested with local fixtures. The upstream
schema is hand-maintained, so runtime decoding tolerates missing optional fields and Apple documentation/live
responses remain authoritative.
