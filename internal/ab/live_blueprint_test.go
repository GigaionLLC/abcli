//go:build live_blueprint

// Opt-in LIVE blueprint-membership test (Phase 3 groundwork). Compiled only with
// `-tags=live_blueprint`, runs only with ABCTL_LIVE_BLUEPRINT=1 plus live creds.
//
// It creates a throwaway test blueprint whose required member is a THROWAWAY test
// user (ABCTL_TEST_USER, default "testuser1") — never a real account — then uses
// abctl's Add/RemoveBlueprintMembers on the *configurations* relationship to answer
// the design's open "relationships replace-vs-merge" question, and tears everything
// down. It never touches devices, and with the test user holding 0 devices nothing
// deploys anywhere. The throwaway user itself is left for manual console cleanup
// (the API cannot delete users — verified read-only).
package ab

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/GigaionLLC/abcli/internal/config"
)

func liveClient(t *testing.T) *Client {
	t.Helper()
	if os.Getenv("ABCTL_LIVE_BLUEPRINT") != "1" {
		t.Skip("opt-in: set ABCTL_LIVE_BLUEPRINT=1 to run the live blueprint test")
	}
	id, key := os.Getenv("AB_CLIENT_ID"), os.Getenv("AB_PRIVATE_KEY")
	if id == "" || key == "" {
		t.Skip("live credentials not set (AB_CLIENT_ID + AB_PRIVATE_KEY)")
	}
	return NewClient(&config.Config{
		ClientID: id, KeyPath: key, Scope: "business.api",
		TokenURL: "https://account.apple.com/auth/oauth2/token",
		TokenAud: "https://account.apple.com/auth/oauth2/v2/token",
		APIBase:  "https://api-business.apple.com/v1/",
		EnvDir:   t.TempDir(),
	})
}

// TestLiveBlueprintMembership: create blueprint (throwaway user member) → attach
// config A → attach config B → observe whether the relationship MERGES or REPLACES
// → detach A → verify → tear down.
func TestLiveBlueprintMembership(t *testing.T) {
	c := liveClient(t)

	// Resolve the throwaway member user (never a real account).
	want := os.Getenv("ABCTL_TEST_USER")
	if want == "" {
		want = "testuser1"
	}
	users, err := c.list("users?limit=100")
	if err != nil {
		t.Fatalf("list users: %v", err)
	}
	var userID, userLabel string
	for _, u := range users {
		if strings.Contains(u.AttrStr("firstName"), want) || strings.Contains(u.AttrStr("email"), want) {
			userID, userLabel = u.ID, u.AttrStr("email")
			break
		}
	}
	if userID == "" {
		t.Skipf("throwaway member user %q not found — create it in the console first", want)
	}
	t.Logf("member = throwaway user %q (id %s)", userLabel, userID)

	// One top-level teardown, ordered: blueprint first (drops its relationships),
	// then the configs. Runs even on t.Fatalf (via Goexit).
	var bpID, cfgA, cfgB string
	defer func() {
		if bpID != "" {
			if st, rb, err := c.rawWrite("DELETE", "blueprints/"+bpID, nil); err != nil || (st != 200 && st != 202 && st != 204) {
				t.Errorf("CLEANUP: delete blueprint %s → HTTP %d err=%v %s (delete it manually)", bpID, st, err, string(rb))
			} else {
				t.Logf("cleanup: deleted blueprint %s (HTTP %d)", bpID, st)
			}
		}
		for _, id := range []string{cfgA, cfgB} {
			if id != "" {
				if err := c.DeleteConfiguration(id); err != nil {
					t.Errorf("CLEANUP: delete config %s: %v (delete it manually)", id, err)
				}
			}
		}
	}()

	// 1. Two throwaway configs (blueprint create needs content, so make them first).
	cfgA = mustCreateConfig(t, c, "zz-abctl-bpcfgA")
	cfgB = mustCreateConfig(t, c, "zz-abctl-bpcfgB")
	t.Logf("created configs A=%s B=%s", cfgA, cfgB)

	// 2. Create the blueprint — create REQUIRES both a member (the throwaway user)
	//    AND content (config A), else 409 MISSING_MEMBERS / MISSING_RESOURCES.
	bpName := fmt.Sprintf("zz-abctl-bp-%d", time.Now().UTC().Unix())
	bpID = createBlueprint(t, c, bpName, userID, cfgA)
	t.Logf("created blueprint %q (id %s) with member=user + content=configA", bpName, bpID)

	// 3. Verify A present at create.
	got := blueprintConfigIDs(t, c, bpID)
	t.Logf("at create: %v", got)
	if !contains(got, cfgA) {
		t.Fatalf("A not attached at create: %v", got)
	}

	// 4. Attach B — the replace-vs-merge probe (per-member POST of a second member).
	if err := c.AddBlueprintMembers(bpID, "configurations", "configurations", []string{cfgB}); err != nil {
		t.Fatalf("attach B: %v", err)
	}
	got = blueprintConfigIDs(t, c, bpID)
	t.Logf("after attach B: %v", got)
	switch {
	case contains(got, cfgA) && contains(got, cfgB):
		t.Logf("RESULT: per-member POST **MERGES** (A and B both present) — relationship add is additive; converge with per-member POST/DELETE is correct.")
	case contains(got, cfgB) && !contains(got, cfgA):
		t.Logf("RESULT: per-member POST **REPLACES** (only B present) — a single POST overwrites the member set; abctl MUST send the full desired set, not per-member.")
	default:
		t.Errorf("unexpected relationship state after attach B: %v", got)
	}

	// 5. Detach A, verify convergence.
	if err := c.RemoveBlueprintMembers(bpID, "configurations", "configurations", []string{cfgA}); err != nil {
		t.Fatalf("detach A: %v", err)
	}
	got = blueprintConfigIDs(t, c, bpID)
	t.Logf("after detach A: %v", got)
	if contains(got, cfgA) {
		t.Errorf("A still attached after detach: %v", got)
	}

	t.Logf("blueprint membership round-trip OK — see RESULT above")
}

func createBlueprint(t *testing.T, c *Client, name, userID, configID string) string {
	t.Helper()
	body := map[string]any{"data": map[string]any{
		"type":       "blueprints",
		"attributes": map[string]any{"name": name, "description": "abctl throwaway test — safe to delete"},
		"relationships": map[string]any{
			"users":          map[string]any{"data": []map[string]string{{"type": "users", "id": userID}}},
			"configurations": map[string]any{"data": []map[string]string{{"type": "configurations", "id": configID}}},
		},
	}}
	st, rb, err := c.rawWrite("POST", "blueprints", body)
	if err != nil {
		t.Fatalf("create blueprint transport: %v", err)
	}
	if st != 200 && st != 201 {
		t.Fatalf("create blueprint → HTTP %d: %s", st, string(rb))
	}
	var o oneResp
	if err := json.Unmarshal(rb, &o); err != nil {
		t.Fatalf("decode blueprint: %v", err)
	}
	if o.Data.ID == "" {
		t.Fatalf("blueprint create returned no id: %s", string(rb))
	}
	return o.Data.ID
}

func mustCreateConfig(t *testing.T, c *Client, prefix string) string {
	t.Helper()
	name := fmt.Sprintf("%s-%d.mobileconfig", prefix, time.Now().UTC().UnixNano())
	id, _, err := c.CreateConfiguration(name, bpProfile("abctl bp test", bpUUID(t), bpUUID(t)), nil)
	if err != nil {
		t.Fatalf("create config %s: %v", name, err)
	}
	return id
}

func blueprintConfigIDs(t *testing.T, c *Client, bpID string) []string {
	t.Helper()
	links, err := c.BlueprintRelationship(bpID, "configurations")
	if err != nil {
		t.Fatalf("get blueprint configs: %v", err)
	}
	ids := make([]string, 0, len(links))
	for _, l := range links {
		ids = append(ids, l.ID)
	}
	sort.Strings(ids)
	return ids
}

func contains(ss []string, s string) bool {
	for _, x := range ss {
		if x == s {
			return true
		}
	}
	return false
}

// bpProfile is a small valid Configuration profile with one inert managed-pref
// payload (distinct name from the integration_write helper to avoid any collision
// under a combined build).
func bpProfile(display, topUUID, innerUUID string) string {
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

func bpUUID(t *testing.T) string {
	t.Helper()
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatalf("uuid: %v", err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func resolveTestUser(t *testing.T, c *Client) string {
	t.Helper()
	want := os.Getenv("ABCTL_TEST_USER")
	if want == "" {
		want = "testuser1"
	}
	users, err := c.list("users?limit=100")
	if err != nil {
		t.Fatalf("list users: %v", err)
	}
	for _, u := range users {
		if strings.Contains(u.AttrStr("firstName"), want) || strings.Contains(u.AttrStr("email"), want) {
			return u.ID
		}
	}
	t.Skipf("throwaway member user %q not found — create it in the console first", want)
	return ""
}

func mustCreateConfigNamed(t *testing.T, c *Client, name string) string {
	t.Helper()
	id, _, err := c.CreateConfiguration(name, bpProfile("abctl gitops test", bpUUID(t), bpUUID(t)), nil)
	if err != nil {
		t.Fatalf("create config %s: %v", name, err)
	}
	return id
}

// gitopsPrefix scopes the CLI-drive scaffolding so teardown can find it.
const gitopsPrefix = "zz-abctl-gitops"

// TestLiveBPGitOpsSetup creates (and LEAVES) a blueprint + two configs for an
// out-of-band `abctl` CLI end-to-end drive (seed → edit manifest → sync --apply).
// Cleaned up by TestLiveBPGitOpsTeardown. Gated by ABCTL_LIVE_BLUEPRINT=1.
func TestLiveBPGitOpsSetup(t *testing.T) {
	c := liveClient(t)
	userID := resolveTestUser(t, c)
	cfgA := mustCreateConfigNamed(t, c, gitopsPrefix+"-a.mobileconfig")
	cfgB := mustCreateConfigNamed(t, c, gitopsPrefix+"-b.mobileconfig")
	bpID := createBlueprint(t, c, gitopsPrefix+"-bp", userID, cfgA)
	t.Logf("SETUP OK: blueprint %q id=%s member=%s content=cfgA(%s); cfgB(%s) left unattached",
		gitopsPrefix+"-bp", bpID, userID, cfgA, cfgB)
}

// TestLiveBPGitOpsTeardown deletes everything the setup + CLI drive created (by
// name prefix): the blueprint(s) first, then the configs.
func TestLiveBPGitOpsTeardown(t *testing.T) {
	c := liveClient(t)
	bps, err := c.ListBlueprints()
	if err != nil {
		t.Fatalf("list blueprints: %v", err)
	}
	for _, bp := range bps {
		if !strings.HasPrefix(bp.AttrStr("name"), gitopsPrefix) {
			continue
		}
		if st, rb, err := c.rawWrite("DELETE", "blueprints/"+bp.ID, nil); err != nil || (st != 200 && st != 202 && st != 204) {
			t.Errorf("delete blueprint %s → %d %v %s", bp.ID, st, err, string(rb))
		} else {
			t.Logf("deleted blueprint %q", bp.AttrStr("name"))
		}
	}
	live, err := c.FetchCustomSettings()
	if err != nil {
		t.Fatalf("list configs: %v", err)
	}
	for _, l := range live {
		if !strings.HasPrefix(l.Name, gitopsPrefix) {
			continue
		}
		if err := c.DeleteConfiguration(l.ID); err != nil {
			t.Errorf("delete config %s: %v", l.Name, err)
		} else {
			t.Logf("deleted config %q", l.Name)
		}
	}
}
