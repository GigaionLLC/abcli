//go:build integration_write

// This file is compiled only with `-tags=integration_write`, so neither the
// normal test suite nor the read-only `-tags=integration` suite ever touches it.
// It performs a LIVE WRITE round-trip against a real Apple Business tenant and is
// double-gated: it self-skips unless BOTH the credentials are present AND the
// operator has opted in with ABCTL_LIVE_WRITE=1.
//
// It targets a throwaway, UNATTACHED CUSTOM_SETTING config (name prefixed `zz-`)
// that is never attached to any Blueprint — so it deploys to no device or user
// (verified-safe path, see docs/design-abctl.md §8). It cleans up best-effort: a
// deferred delete of this run's config, plus a start-of-run sweep of the whole
// `zz-abctl-livetest-` namespace to reclaim any orphan a prior run leaked when its
// create response was lost. It NEVER creates/attaches blueprints, devices, or members.
package ab

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/GigaionLLC/abcli/internal/config"
	"github.com/GigaionLLC/abcli/internal/hash"
)

// TestLiveWriteRoundTrip: create → download (byte-identical GET round-trip) →
// update → download → delete → confirm gone. Runs only under
// `-tags=integration_write`, only with ABCTL_LIVE_WRITE=1, and only when
// AB_CLIENT_ID + AB_PRIVATE_KEY are set; otherwise it skips.
func TestLiveWriteRoundTrip(t *testing.T) {
	if os.Getenv("ABCTL_LIVE_WRITE") != "1" {
		t.Skip("live WRITE round-trip is opt-in: set ABCTL_LIVE_WRITE=1 to run (it writes to a real tenant)")
	}
	clientID, keyPath := os.Getenv("AB_CLIENT_ID"), os.Getenv("AB_PRIVATE_KEY")
	if clientID == "" || keyPath == "" {
		t.Skip("live credentials not set (AB_CLIENT_ID + AB_PRIVATE_KEY); skipping live write test")
	}

	cfg := &config.Config{
		ClientID: clientID,
		KeyPath:  keyPath,
		Scope:    "business.api",
		TokenURL: "https://account.apple.com/auth/oauth2/token",
		TokenAud: "https://account.apple.com/auth/oauth2/v2/token",
		APIBase:  "https://api-business.apple.com/v1/",
		EnvDir:   t.TempDir(),
	}
	c := NewClient(cfg)

	// Reclaim any orphan a prior run leaked (a create whose response was lost, so
	// its id was never known to delete). Bounded to our own throwaway namespace and
	// a single list call (no per-item GET loop).
	sweepLiveTestStrays(t, c)

	name := fmt.Sprintf("zz-abctl-livetest-%d.mobileconfig", time.Now().UTC().Unix())
	xml1 := minimalProfile("abctl livetest", uuid4(t), uuid4(t))

	// CREATE.
	id, createdTS, err := c.CreateConfiguration(name, xml1, nil)
	if err != nil {
		t.Fatalf("create failed: %v", err)
	}
	if id == "" {
		t.Fatal("create returned an empty id")
	}
	t.Logf("created unattached config %q (id %s, updated %q)", name, id, createdTS)

	// Best-effort cleanup: always try to delete, so a mid-test failure never
	// leaves a stray config behind. The explicit delete below flips `deleted`.
	deleted := false
	defer func() {
		if deleted {
			return
		}
		if err := c.DeleteConfiguration(id); err != nil {
			t.Errorf("CLEANUP FAILED — manually delete config %q (id %s): %v", name, id, err)
		}
	}()

	// DOWNLOAD + byte-identical round-trip (the drift-hash invariant).
	gotXML, _ := fetchProfile(t, c, id)
	if hash.Raw([]byte(gotXML)) != hash.Raw([]byte(xml1)) {
		t.Fatalf("create round-trip is not byte-identical:\n sent %d bytes (%s)\n got  %d bytes (%s)",
			len(xml1), hash.Raw([]byte(xml1)), len(gotXML), hash.Raw([]byte(gotXML)))
	}

	// UPDATE.
	xml2 := minimalProfile("abctl livetest v2", uuid4(t), uuid4(t))
	if _, err := c.UpdateConfiguration(id, name, xml2); err != nil {
		t.Fatalf("update failed: %v", err)
	}
	gotXML2, _ := fetchProfile(t, c, id)
	if hash.Raw([]byte(gotXML2)) != hash.Raw([]byte(xml2)) {
		t.Fatalf("update round-trip is not byte-identical: got hash %s, want %s",
			hash.Raw([]byte(gotXML2)), hash.Raw([]byte(xml2)))
	}

	// DELETE.
	if err := c.DeleteConfiguration(id); err != nil {
		t.Fatalf("delete failed: %v", err)
	}
	deleted = true

	// CONFIRM GONE.
	st, _, err := c.Raw("GET", "configurations/"+id, nil)
	if err != nil {
		t.Fatalf("post-delete GET errored: %v", err)
	}
	if st != 404 {
		t.Errorf("after delete, GET config → HTTP %d, want 404", st)
	}
	t.Logf("live write round-trip OK (create→download→update→download→delete→404)")
}

// sweepLiveTestStrays deletes any leftover zz-abctl-livetest-* configs from prior
// runs (best-effort; one list call, our namespace only).
func sweepLiveTestStrays(t *testing.T, c *Client) {
	t.Helper()
	all, err := c.FetchCustomSettings()
	if err != nil {
		t.Logf("stray-sweep skipped (list failed): %v", err)
		return
	}
	for _, l := range all {
		if !strings.HasPrefix(l.Name, "zz-abctl-livetest-") {
			continue
		}
		if err := c.DeleteConfiguration(l.ID); err != nil {
			t.Logf("stray-sweep: could not delete %q (%s): %v", l.Name, l.ID, err)
		} else {
			t.Logf("stray-sweep: reclaimed orphan %q", l.Name)
		}
	}
}

// fetchProfile GETs one config with its raw profile XML + updatedDateTime.
func fetchProfile(t *testing.T, c *Client, id string) (xml, updated string) {
	t.Helper()
	st, b, err := c.Raw("GET", "configurations/"+id+"?fields[configurations]=name,updatedDateTime,customSettingsValues", nil)
	if err != nil {
		t.Fatalf("fetch config %s failed: %v", id, err)
	}
	if st != 200 {
		t.Fatalf("fetch config %s: HTTP %d", id, st)
	}
	var o struct {
		Data Resource `json:"data"`
	}
	if err := json.Unmarshal(b, &o); err != nil {
		t.Fatalf("decode config %s: %v", id, err)
	}
	csv, _ := o.Data.Attr()["customSettingsValues"].(map[string]any)
	xml, _ = csv["configurationProfile"].(string)
	return xml, o.Data.AttrStr("updatedDateTime")
}

// minimalProfile returns a small, valid Configuration profile carrying one benign
// managed-preferences payload (a made-up domain no app reads, so it is inert even
// if deployed — and this test never attaches it to anything). topUUID/innerUUID
// identify the outer profile and the inner payload. The API validates uploads, so
// PayloadContent must hold ≥1 real payload (an empty array → 400 PARAMETER_ERROR).
func minimalProfile(display, topUUID, innerUUID string) string {
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadType</key>
			<string>com.apple.ManagedClient.preferences</string>
			<key>PayloadIdentifier</key>
			<string>com.gigaionllc.abctl.livetest.pref.` + innerUUID + `</string>
			<key>PayloadUUID</key>
			<string>` + innerUUID + `</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>PayloadDisplayName</key>
			<string>abctl test preference</string>
			<key>PayloadContent</key>
			<dict>
				<key>com.gigaionllc.abctl.livetest</key>
				<dict>
					<key>Forced</key>
					<array>
						<dict>
							<key>mcx_preference_settings</key>
							<dict>
								<key>abctlProbe</key>
								<true/>
							</dict>
						</dict>
					</array>
				</dict>
			</dict>
		</dict>
	</array>
	<key>PayloadDisplayName</key>
	<string>` + display + `</string>
	<key>PayloadIdentifier</key>
	<string>com.gigaionllc.abctl.livetest.` + topUUID + `</string>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>` + topUUID + `</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
</dict>
</plist>
`
}

// uuid4 generates a random RFC 4122 v4 UUID.
func uuid4(t *testing.T) string {
	t.Helper()
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatalf("uuid: %v", err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
