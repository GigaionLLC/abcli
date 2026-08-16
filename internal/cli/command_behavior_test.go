package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GigaionLLC/abcli/internal/gitops"
	"github.com/GigaionLLC/abcli/internal/hash"
	"github.com/GigaionLLC/abcli/internal/state"
)

// End-to-end tests for whole commands against the fake tenant (faketenant_test.go).
//
// Each of these locks a defect that reached a release. They need no credentials and no network,
// which is the point: every one of these bugs was reachable by running the command once.

const testProfileV1 = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadIdentifier</key><string>com.example.wifi</string>
  <key>PayloadUUID</key><string>1A2B3C4D-0000-0000-0000-000000000001</string>
  <key>PayloadContent</key><array/>
</dict></plist>`

const testProfileV1Edited = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadIdentifier</key><string>com.example.wifi</string>
  <key>PayloadUUID</key><string>1A2B3C4D-0000-0000-0000-000000000002</string>
  <key>PayloadContent</key><array/>
</dict></plist>`

func writeTempProfile(t *testing.T, dir, name, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func loadBaseline(t *testing.T, root string) *state.State {
	t.Helper()
	tree := gitops.NewTree(root)
	base, err := state.Load(tree.StateFile)
	if err != nil {
		t.Fatalf("reading baseline: %v", err)
	}
	return base
}

// A `replace` whose bytes Apple silently drops must FAIL and must not record a baseline that
// claims agreement.
//
// This is the incident the whole read-back exists for. The old code wrote
// `Hash: hash.Raw(content)` — the bytes it SENT — so the baseline asserted a state Apple was
// not in. The next `--refresh=smart` run then matched id and timestamp, reused that hash,
// never fetched the real XML, and reported "in sync" forever while Apple held the old profile.
// A poisoned entry is self-sustaining: nothing re-reads it.
func TestReplaceFailsWhenAppleDropsTheWrite(t *testing.T) {
	tenant := newFakeAPI(t)
	tenant.addConfig("cfg-1", "wifi.mobileconfig", testProfileV1)
	root := tenant.use(t)
	tenant.dropWrites = true // 2xx, stored bytes unchanged

	file := writeTempProfile(t, t.TempDir(), "new.mobileconfig", testProfileV1Edited)
	err := runReplaceConfig("wifi.mobileconfig", writeFlags{file: file, yes: true})
	if err == nil {
		t.Fatal("a write Apple did not persist must fail, not report success")
	}
	if !strings.Contains(err.Error(), "did not persist") {
		t.Errorf("error should name the accept-and-drop case, got: %v", err)
	}

	base := loadBaseline(t, root)
	entry, ok := base.Configs["wifi.mobileconfig"]
	if !ok {
		return // no baseline at all is also acceptable — nothing false was recorded
	}
	// If a baseline WAS written it must describe Apple's reality (the old bytes), never the
	// bytes we sent — that difference is what makes the next diff show the drift.
	if entry.Hash == hashOf(testProfileV1Edited) {
		t.Error("baseline recorded the bytes SENT; the next smart refresh would report 'in sync' forever")
	}
}

// The happy path still records a baseline, from the read-back.
func TestReplaceRecordsBaselineFromTheReadBack(t *testing.T) {
	tenant := newFakeAPI(t)
	tenant.addConfig("cfg-1", "wifi.mobileconfig", testProfileV1)
	root := tenant.use(t)

	file := writeTempProfile(t, t.TempDir(), "new.mobileconfig", testProfileV1Edited)
	if err := runReplaceConfig("wifi.mobileconfig", writeFlags{file: file, yes: true}); err != nil {
		t.Fatalf("replace: %v", err)
	}
	entry, ok := loadBaseline(t, root).Configs["wifi.mobileconfig"]
	if !ok {
		t.Fatal("a confirmed write must record a baseline")
	}
	if entry.Hash != hashOf(testProfileV1Edited) {
		t.Errorf("baseline hash = %q, want the stored (== sent) profile's hash", entry.Hash)
	}
	if entry.UpdatedDateTime != "2026-02-02T00:00:00Z" {
		t.Errorf("baseline timestamp = %q, want Apple's stored one", entry.UpdatedDateTime)
	}
}

// Resolving ONE config by name must not download every profile in the tenant.
//
// This is the `adopt` trap generalised: `FetchCustomSettings` asks for `customSettingsValues`
// on the whole tenant. On a real tenant that outran abgui's command budget and the command
// silently did nothing. Counting requests is the only way this class of bug is a test failure
// rather than a bug report.
func TestReplaceDoesNotDownloadEveryProfileInTheTenant(t *testing.T) {
	tenant := newFakeAPI(t)
	for _, n := range []string{"a", "b", "c", "d", "e", "f", "g", "h"} {
		tenant.addConfig("cfg-"+n, n+".mobileconfig", testProfileV1)
	}
	tenant.use(t)

	file := writeTempProfile(t, t.TempDir(), "new.mobileconfig", testProfileV1Edited)
	if err := runReplaceConfig("a.mobileconfig", writeFlags{file: file, yes: true}); err != nil {
		t.Fatalf("replace: %v", err)
	}

	if n := tenant.countMatching("GET-with-xml"); n != 0 {
		t.Errorf("replace requested tenant-wide profile XML %d time(s); it needs one config's bytes, not everyone's", n)
	}
	// One detail GET to archive the old bytes, one to confirm the write. Never one per config.
	if n := tenant.countMatching("GET /v1/configurations/"); n > 3 {
		t.Errorf("replace made %d per-config GETs; expected at most 3 (archive + read-back)", n)
	}
}

// `status config` reads nothing but names and ids, so it must not pay for profile bytes either.
func TestStatusConfigDoesNotDownloadProfiles(t *testing.T) {
	tenant := newFakeAPI(t)
	for _, n := range []string{"a", "b", "c"} {
		tenant.addConfig("cfg-"+n, n+".mobileconfig", testProfileV1)
	}
	tenant.use(t)

	if err := runStatusConfig("a.mobileconfig", true); err != nil {
		t.Fatalf("status config: %v", err)
	}
	if n := tenant.countMatching("GET-with-xml"); n != 0 {
		t.Errorf("status config requested profile XML %d time(s); it only reports coverage", n)
	}
}

// A profile Apple is known to drop must be refused BEFORE the write, by the same inspector
// `abctl validate` uses. The write path used to check three substrings and a size cap.
func TestCreateRefusesAProfileAppleWouldSilentlyDrop(t *testing.T) {
	tenant := newFakeAPI(t)
	tenant.use(t)

	bad := strings.Replace(testProfileV1, "<key>PayloadVersion</key><integer>1</integer>",
		"<key>PayloadVersion</key><integer>2</integer>", 1)
	file := writeTempProfile(t, t.TempDir(), "bad.mobileconfig", bad)

	err := runCreateConfig("bad", writeFlags{file: file, yes: true})
	if err == nil {
		t.Fatal("a top-level PayloadVersion of 2 must be refused before it reaches Apple")
	}
	if !strings.Contains(err.Error(), "payload-version") {
		t.Errorf("error should name the rule, got: %v", err)
	}
	if n := tenant.count("POST /v1/configurations"); n != 0 {
		t.Errorf("the profile reached Apple %d time(s) despite failing validation", n)
	}
}

// `--refresh=metadata-only` can never populate profile XML, which every write needs. Refusing it
// up front beats failing item by item and re-planning the identical work on the next run.
func TestApplyRefusesMetadataOnlyRefresh(t *testing.T) {
	err := runSync(syncFlags{apply: true, refresh: refreshMetadata, verify: verifyTargeted, yes: true})
	if err == nil {
		t.Fatal("--apply with --refresh=metadata-only must be refused")
	}
	if !strings.Contains(err.Error(), "metadata-only") {
		t.Errorf("error should name the mode, got: %v", err)
	}
}

// hashOf mirrors the raw-content hash the reconciler and the baseline both use.
func hashOf(s string) string { return hash.Raw([]byte(s)) }

// A dry run must not fetch a profile per live-only config.
//
// This is the regression the willWrite gate exists to prevent, and it was inert on the first
// attempt: an unconditional `needDetail := l.Hash == ""` ran first, and on an unseeded workspace
// nothing has a cached hash, so every live config was fetched anyway. That is the exact case the
// optimization was for — hence a test rather than a comment.
func TestDiffOnAnUnseededWorkspaceDoesNotFetchEveryProfile(t *testing.T) {
	tenant := newFakeAPI(t)
	for _, n := range []string{"a", "b", "c", "d", "e"} {
		tenant.addConfig("cfg-"+n, n+".mobileconfig", testProfileV1)
	}
	tenant.use(t) // empty workspace: no lib/, no baseline

	if _, err := loadPlan(false, refreshSmart, false); err != nil {
		t.Fatalf("loadPlan: %v", err)
	}
	if n := tenant.countMatching("GET /v1/configurations/"); n != 0 {
		t.Errorf("a dry-run plan fetched %d per-config profile(s); it compares nothing it keeps", n)
	}
}

// The same run WITH writes still gets the bytes it needs to pull or archive.
func TestApplyPlanStillFetchesProfilesItWillWrite(t *testing.T) {
	tenant := newFakeAPI(t)
	tenant.addConfig("cfg-a", "a.mobileconfig", testProfileV1)
	tenant.use(t)

	if _, err := loadPlan(false, refreshSmart, true); err != nil {
		t.Fatalf("loadPlan: %v", err)
	}
	if n := tenant.countMatching("GET /v1/configurations/"); n == 0 {
		t.Error("a run that will pull must fetch the bytes it is going to write into git")
	}
}
