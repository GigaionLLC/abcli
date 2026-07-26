package cli

import (
	"errors"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/gitops"
	"github.com/GigaionLLC/abcli/internal/hash"
	"github.com/GigaionLLC/abcli/internal/reconcile"
	"github.com/GigaionLLC/abcli/internal/state"
)

// TestEnvApproved verifies the write-confirmation bypass parses the value: only a
// truthy $ABCTL_APPROVE approves; 0/false/no/off/empty must NOT bypass the gate.
func TestEnvApproved(t *testing.T) {
	cases := map[string]bool{
		"1": true, "true": true, "TRUE": true, "yes": true, "Y": true, "on": true,
		"": false, "0": false, "false": false, "no": false, "off": false, "banana": false,
	}
	for v, want := range cases {
		t.Setenv("ABCTL_APPROVE", v)
		if got := envApproved(); got != want {
			t.Errorf("envApproved(%q) = %v, want %v", v, got, want)
		}
	}
}

func TestParsePlatforms(t *testing.T) {
	if got := parsePlatforms(""); got != nil {
		t.Errorf("parsePlatforms(\"\") = %v, want nil", got)
	}
	if got := parsePlatforms("   "); got != nil {
		t.Errorf("parsePlatforms(whitespace) = %v, want nil", got)
	}
	got := parsePlatforms("PLATFORM_MACOS, PLATFORM_IOS ,")
	if len(got) != 2 || got[0] != "PLATFORM_MACOS" || got[1] != "PLATFORM_IOS" {
		t.Errorf("parsePlatforms = %v, want [PLATFORM_MACOS PLATFORM_IOS]", got)
	}
}

// TestManagedBlueprintCollections covers the lazy-fetch gate: configurations
// always, plus exactly the optional collections some manifest manages (a
// present-but-empty key counts; a nil key never does), in stable order.
func TestManagedBlueprintCollections(t *testing.T) {
	strs := func(ss ...string) *[]string { return &ss }

	// No manifests at all → configurations only (no full-tenant lists).
	if got := managedBlueprintCollections(nil); len(got) != 1 || got[0] != ab.CollectionConfigurations {
		t.Errorf("no specs → %v, want [configurations]", got)
	}

	specs := map[string]gitops.BlueprintSpec{
		"Sales": {Name: "Sales", Configurations: []string{"wifi.mobileconfig"}, Devices: strs("C02AAA")},
		"Eng":   {Name: "Eng", Users: strs()}, // present-but-empty still MANAGES users
	}
	got := managedBlueprintCollections(specs)
	want := []string{ab.CollectionConfigurations, ab.CollectionDevices, ab.CollectionUsers}
	if len(got) != len(want) {
		t.Fatalf("managed collections = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("managed collections = %v, want %v (stable ab.BlueprintCollections order)", got, want)
		}
	}
}

// TestManagedListPinsEmpty: seed --blueprint-membership must write `key: []`
// (managed) even for an empty live membership — never a nil pointer that would
// leave the collection unmanaged.
func TestManagedListPinsEmpty(t *testing.T) {
	if p := managedList(nil); p == nil || *p == nil || len(*p) != 0 {
		t.Errorf("managedList(nil) = %v, want non-nil pointer to empty slice", p)
	}
	if p := managedList([]string{"a"}); p == nil || len(*p) != 1 || (*p)[0] != "a" {
		t.Errorf("managedList([a]) = %v", p)
	}
}

// TestInvertMemberMaps: the name→id direction mirrors id→name per collection,
// and a display name shared by >1 id inverts to "" (present-but-empty — the
// ambiguity sentinel that blocks attaches and suppresses detaches) rather than
// to whichever id map iteration visits last.
func TestInvertMemberMaps(t *testing.T) {
	got := invertMemberMaps(map[string]map[string]string{
		ab.CollectionDevices: {"d-1": "C02AAA", "d-2": "C02BBB"},
		ab.CollectionUsers:   {"u-1": "ann@x.co"},
		ab.CollectionApps:    {"a-1": "Keynote", "a-2": "Keynote", "a-3": "Numbers"},
	})
	if m := got[ab.CollectionDevices]; len(m) != 2 || m["C02AAA"] != "d-1" || m["C02BBB"] != "d-2" {
		t.Errorf("devices inverted = %v", m)
	}
	if m := got[ab.CollectionUsers]; len(m) != 1 || m["ann@x.co"] != "u-1" {
		t.Errorf("users inverted = %v", m)
	}
	m := got[ab.CollectionApps]
	if m["Numbers"] != "a-3" {
		t.Errorf("apps inverted = %v", m)
	}
	if id, ok := m["Keynote"]; !ok || id != "" {
		t.Errorf("duplicate name Keynote = %q (present=%v), want present-but-empty (ambiguous)", id, ok)
	}
}

// TestCanonicalizeBlueprintMembers: manifest entries written as an accepted
// alias (user's managed Apple Account, address/serial case variants) are
// rewritten to the canonical live name before diffing, so `sync --prune` can't
// detach a member the manifest actually lists. Ambiguous ("") and unknown
// aliases, and unmanaged collections, stay untouched.
func TestCanonicalizeBlueprintMembers(t *testing.T) {
	strs := func(ss ...string) *[]string { return &ss }
	specs := map[string]gitops.BlueprintSpec{
		"Sales": {
			Name:    "Sales",
			Users:   strs("Bob@AppleID.x.co", "ann@x.co", "dup@x.co", "ghost@x.co"),
			Devices: strs("c02aaa"),
		},
		"Eng": {Name: "Eng"}, // users/devices unmanaged (nil) → untouched
	}
	canonicalizeBlueprintMembers(specs, map[string]map[string]string{
		ab.CollectionUsers: {
			"bob@appleid.x.co": "bob@x.co", // managed Apple Account → canonical email
			"ann@x.co":         "ann@x.co", // already canonical
			"dup@x.co":         "",         // ambiguous alias — leave as written
		},
		ab.CollectionDevices: {"c02aaa": "C02AAA"},
	})
	gotUsers := *specs["Sales"].Users
	wantUsers := []string{"bob@x.co", "ann@x.co", "dup@x.co", "ghost@x.co"}
	for i := range wantUsers {
		if gotUsers[i] != wantUsers[i] {
			t.Fatalf("users = %v, want %v", gotUsers, wantUsers)
		}
	}
	if got := *specs["Sales"].Devices; got[0] != "C02AAA" {
		t.Errorf("devices = %v, want serial canonicalized to C02AAA", got)
	}
	if specs["Eng"].Users != nil || specs["Eng"].Devices != nil {
		t.Error("unmanaged collections must stay nil")
	}
}

// fakeConfigReader stands in for the tenant during post-apply verification: it
// records every id read back (so a test can prove targeted verification stayed
// targeted — Apple rate-limits hard) and serves canned live configs.
type fakeConfigReader struct {
	byID  map[string]ab.LiveConfig
	errs  map[string]error
	calls []string
}

func (f *fakeConfigReader) FetchCustomSettingDetail(id string) (ab.LiveConfig, error) {
	f.calls = append(f.calls, id)
	if err := f.errs[id]; err != nil {
		return ab.LiveConfig{}, err
	}
	lc, ok := f.byID[id]
	if !ok {
		return ab.LiveConfig{}, errors.New("no such configuration: " + id)
	}
	return lc, nil
}

// applyResult builds a Result whose outcomes are (name, action, status) triples.
func applyResult(rows ...[3]string) *reconcile.Result {
	res := &reconcile.Result{Outcomes: []reconcile.Outcome{}}
	for _, r := range rows {
		res.Outcomes = append(res.Outcomes, reconcile.Outcome{
			Name: r[0], Action: reconcile.Action(r[1]), Status: r[2], Detail: "test",
		})
		switch r[2] {
		case "error":
			res.Errors++
		case "skipped":
			res.Skipped++
		}
	}
	return res
}

// TestWrittenConfigsOnlyTenantWrites: verification must read back exactly what the
// apply PUSHED to Apple — completed create/update outcomes. Pull/delete-git touch
// only the git tree, a prune deletes the config, and skipped/errored items never
// reached the tenant, so none of them are read back.
func TestWrittenConfigsOnlyTenantWrites(t *testing.T) {
	res := applyResult(
		[3]string{"a.mobileconfig", string(reconcile.Update), "done"},
		[3]string{"b.mobileconfig", string(reconcile.Create), "done"},
		[3]string{"c.mobileconfig", string(reconcile.Update), "error"},
		[3]string{"d.mobileconfig", string(reconcile.Update), "skipped"},
		[3]string{"e.mobileconfig", string(reconcile.Pull), "done"},
		[3]string{"f.mobileconfig", string(reconcile.DeleteABM), "done"},
		[3]string{"g.mobileconfig", string(reconcile.DeleteGit), "done"},
	)
	got := writtenConfigs(res)
	want := []string{"a.mobileconfig", "b.mobileconfig"}
	if len(got) != len(want) {
		t.Fatalf("writtenConfigs = %v, want %v", got, want)
	}
	for i := range want {
		if got[i].Name != want[i] {
			t.Fatalf("writtenConfigs = %v, want %v", got, want)
		}
	}
	if writtenConfigs(nil) != nil {
		t.Error("writtenConfigs(nil) must be nil")
	}

	// The apply's own read-back verdict must ride along, so verification can tell a
	// write that is already confirmed from one that still needs checking.
	verdicts := &reconcile.Result{Outcomes: []reconcile.Outcome{
		{Name: "ok.mobileconfig", Action: reconcile.Update, Status: "done", Verified: reconcile.VerifyConfirmed},
		{Name: "unsure.mobileconfig", Action: reconcile.Create, Status: "done", Verified: reconcile.VerifyUnconfirmed},
	}}
	gotV := writtenConfigs(verdicts)
	if len(gotV) != 2 || gotV[0].Verified != reconcile.VerifyConfirmed || gotV[1].Verified != reconcile.VerifyUnconfirmed {
		t.Errorf("writtenConfigs lost the read-back verdicts: %+v", gotV)
	}
}

// writes is the test spelling of the apply's write list. Callers that don't care
// about the verdict get the pre-verification default (unconfirmed), which is the
// conservative one: it makes verification actually go and look.
func writes(names ...string) []writtenConfig {
	out := make([]writtenConfig, 0, len(names))
	for _, n := range names {
		out = append(out, writtenConfig{Name: n, Verified: reconcile.VerifyUnconfirmed})
	}
	return out
}

// TestVerifyApplyTargetedReadsBackOnlyWrittenConfigs: the default verify mode now
// re-reads the configs it wrote (the dropped-write detector) and NOTHING else — one
// detail GET per write, never a fan-out over the whole tenant.
func TestVerifyApplyTargetedReadsBackOnlyWrittenConfigs(t *testing.T) {
	desired := map[string][]byte{
		"a.mobileconfig":     []byte("<plist>A</plist>"),
		"b.mobileconfig":     []byte("<plist>B</plist>"),
		"idle.mobileconfig":  []byte("<plist>IDLE</plist>"),
		"other.mobileconfig": []byte("<plist>OTHER</plist>"),
	}
	base := &state.State{Configs: map[string]state.Entry{
		"a.mobileconfig":     {ABMID: "cfg-a"},
		"b.mobileconfig":     {ABMID: "cfg-b"},
		"idle.mobileconfig":  {ABMID: "cfg-idle"},
		"other.mobileconfig": {ABMID: "cfg-other"},
	}}
	r := &fakeConfigReader{byID: map[string]ab.LiveConfig{
		"cfg-a": {Name: "a.mobileconfig", ID: "cfg-a", XML: "<plist>A</plist>", Updated: "2026-07-25T10:00:00.000Z"},
		"cfg-b": {Name: "b.mobileconfig", ID: "cfg-b", XML: "<plist>B</plist>", Updated: "2026-07-25T10:00:01.000Z"},
	}}
	written := writes("a.mobileconfig", "b.mobileconfig")

	got := verifyApply(verifyTargeted, r, written, desired, base, nil, nil)
	if len(got) != 0 {
		t.Fatalf("live bytes match desired, want no mismatches, got %+v", got)
	}
	if len(r.calls) != 2 || r.calls[0] != "cfg-a" || r.calls[1] != "cfg-b" {
		t.Errorf("read back %v, want exactly [cfg-a cfg-b] (targeted must not fan out)", r.calls)
	}
}

// TestVerifyApplyTargetedSkipsWritesTheApplyConfirmed: the apply reads every write
// back before it will record a baseline, so a write it already matched byte-for-byte
// must NOT be fetched a second time — the answer cannot differ, and Apple rate-limits
// hard. Only the write the apply could not confirm is worth another request.
func TestVerifyApplyTargetedSkipsWritesTheApplyConfirmed(t *testing.T) {
	desired := map[string][]byte{
		"confirmed.mobileconfig": []byte("<plist>OK</plist>"),
		"unsure.mobileconfig":    []byte("<plist>UNSURE</plist>"),
	}
	base := &state.State{Configs: map[string]state.Entry{
		"confirmed.mobileconfig": {ABMID: "cfg-confirmed"},
		"unsure.mobileconfig":    {ABMID: "cfg-unsure"},
	}}
	r := &fakeConfigReader{byID: map[string]ab.LiveConfig{
		"cfg-confirmed": {Name: "confirmed.mobileconfig", ID: "cfg-confirmed", XML: "<plist>OK</plist>"},
		"cfg-unsure":    {Name: "unsure.mobileconfig", ID: "cfg-unsure", XML: "<plist>UNSURE</plist>"},
	}}
	written := []writtenConfig{
		{Name: "confirmed.mobileconfig", Verified: reconcile.VerifyConfirmed},
		{Name: "unsure.mobileconfig", Verified: reconcile.VerifyUnconfirmed},
	}

	if ms := verifyApply(verifyTargeted, r, written, desired, base, nil, nil); len(ms) != 0 {
		t.Fatalf("mismatches = %+v, want none", ms)
	}
	if len(r.calls) != 1 || r.calls[0] != "cfg-unsure" {
		t.Errorf("read back %v, want exactly [cfg-unsure] — the confirmed write must not be fetched twice", r.calls)
	}
}

// TestVerifyApplyTargetedRetriesAnUnconfirmedWrite: when the apply's read-back did
// not produce an answer, the second attempt is the one that can. If it still cannot,
// that is reported rather than passing silently.
func TestVerifyApplyTargetedRetriesAnUnconfirmedWrite(t *testing.T) {
	desired := map[string][]byte{"flaky.mobileconfig": []byte("<plist>NEW</plist>")}
	base := &state.State{Configs: map[string]state.Entry{"flaky.mobileconfig": {ABMID: "cfg-flaky"}}}
	written := []writtenConfig{{Name: "flaky.mobileconfig", Verified: reconcile.VerifyUnconfirmed}}

	// The retry succeeds and the bytes match → the write is vindicated.
	ok := &fakeConfigReader{byID: map[string]ab.LiveConfig{
		"cfg-flaky": {Name: "flaky.mobileconfig", ID: "cfg-flaky", XML: "<plist>NEW</plist>"},
	}}
	if ms := verifyApply(verifyTargeted, ok, written, desired, base, nil, nil); len(ms) != 0 {
		t.Errorf("a successful retry must clear the write, got %+v", ms)
	}
	if len(ok.calls) != 1 {
		t.Errorf("retry made %v calls, want 1", ok.calls)
	}

	// The retry reveals Apple never stored it → the incident is caught here too.
	dropped := &fakeConfigReader{byID: map[string]ab.LiveConfig{
		"cfg-flaky": {Name: "flaky.mobileconfig", ID: "cfg-flaky", XML: "<plist>OLD</plist>", Updated: "2026-07-19T19:42:05.476Z"},
	}}
	ms := verifyApply(verifyTargeted, dropped, written, desired, base, nil, nil)
	if len(ms) != 1 || ms[0].Name != "flaky.mobileconfig" {
		t.Fatalf("mismatches = %+v, want the dropped write caught on retry", ms)
	}
}

// TestVerifyApplyTargetedCatchesDroppedWrite is THE incident: Apple answered the
// PATCH 2xx, kept the old bytes, and froze updatedDateTime, so every run re-planned
// the same change. The read-back must report it with the FAILED line, and the run
// must exit non-zero — after the receipt is rendered.
func TestVerifyApplyTargetedCatchesDroppedWrite(t *testing.T) {
	desired := map[string][]byte{"ManagedLoginItems-Policy.mobileconfig": []byte("<plist>NEW</plist>")}
	base := &state.State{Configs: map[string]state.Entry{
		"ManagedLoginItems-Policy.mobileconfig": {ABMID: "cfg-mli"},
	}}
	r := &fakeConfigReader{byID: map[string]ab.LiveConfig{
		// what Apple actually still stores: the pre-PATCH bytes, frozen timestamp
		"cfg-mli": {Name: "ManagedLoginItems-Policy.mobileconfig", ID: "cfg-mli", XML: "<plist>OLD</plist>", Updated: "2026-07-19T19:42:05.476Z"},
	}}
	written := writes("ManagedLoginItems-Policy.mobileconfig")

	ms := verifyApply(verifyTargeted, r, written, desired, base, nil, nil)
	if len(ms) != 1 || ms[0].Name != "ManagedLoginItems-Policy.mobileconfig" {
		t.Fatalf("mismatches = %+v, want the dropped write reported", ms)
	}
	if !strings.Contains(ms[0].Detail, "2026-07-19T19:42:05.476Z") {
		t.Errorf("detail %q must surface the frozen live updatedDateTime", ms[0].Detail)
	}

	var sb strings.Builder
	reportVerification(&sb, verifyTargeted, written, ms)
	wantLine := "post-apply verification FAILED: ManagedLoginItems-Policy.mobileconfig still differs from desired on Apple Business"
	if !strings.Contains(sb.String(), wantLine) {
		t.Errorf("report =\n%s\nwant the line %q", sb.String(), wantLine)
	}
	if !strings.Contains(sb.String(), "PayloadVersion") {
		t.Errorf("report =\n%s\nwant the out-of-spec-profile hint", sb.String())
	}

	// A mismatch fails the run — but only through finishApply, so the receipt lands first.
	out, err := captureStdoutErr(t, func() error {
		return finishApply(false, "", applyResult([3]string{"ManagedLoginItems-Policy.mobileconfig", string(reconcile.Update), "done"}), nil,
			newVerificationReport(verifyTargeted, written, ms), ExitError{Code: 1})
	})
	var ee ExitError
	if !errors.As(err, &ee) || ee.Code != 1 {
		t.Errorf("finishApply err = %v, want ExitError{1}", err)
	}
	if !strings.Contains(out, "ManagedLoginItems-Policy.mobileconfig") {
		t.Errorf("receipt =\n%s\nwant the written config listed despite the verification failure", out)
	}
}

// TestVerifyApplyTargetedUnverifiableWrites: a read-back that fails (transient API
// error) or a write with no recorded id is NOT evidence of a good write — both are
// reported rather than silently passing, and neither aborts the remaining reads.
func TestVerifyApplyTargetedUnverifiableWrites(t *testing.T) {
	desired := map[string][]byte{
		"boom.mobileconfig":  []byte("<plist>BOOM</plist>"),
		"noid.mobileconfig":  []byte("<plist>NOID</plist>"),
		"good.mobileconfig":  []byte("<plist>GOOD</plist>"),
		"empty.mobileconfig": []byte("<plist>EMPTY</plist>"),
	}
	base := &state.State{Configs: map[string]state.Entry{
		"boom.mobileconfig":  {ABMID: "cfg-boom"},
		"noid.mobileconfig":  {}, // apply recorded no id — unverifiable
		"good.mobileconfig":  {ABMID: "cfg-good"},
		"empty.mobileconfig": {ABMID: "cfg-empty"},
	}}
	r := &fakeConfigReader{
		byID: map[string]ab.LiveConfig{
			"cfg-good":  {Name: "good.mobileconfig", ID: "cfg-good", XML: "<plist>GOOD</plist>"},
			"cfg-empty": {Name: "empty.mobileconfig", ID: "cfg-empty"}, // Apple returned no XML
		},
		errs: map[string]error{"cfg-boom": errors.New("429 rate limited")},
	}
	ms := verifyApply(verifyTargeted, r, writes("boom.mobileconfig", "noid.mobileconfig", "good.mobileconfig", "empty.mobileconfig"), desired, base, nil, nil)
	if len(ms) != 3 {
		t.Fatalf("mismatches = %+v, want boom + noid + empty reported (good verified)", ms)
	}
	if ms[0].Name != "boom.mobileconfig" || !strings.Contains(ms[0].Detail, "429") {
		t.Errorf("read failure not reported: %+v", ms[0])
	}
	if ms[1].Name != "noid.mobileconfig" || !strings.Contains(ms[1].Detail, "no configuration id") {
		t.Errorf("missing id not reported: %+v", ms[1])
	}
	if ms[2].Name != "empty.mobileconfig" {
		t.Errorf("empty read-back not reported: %+v", ms[2])
	}
	if len(r.calls) != 3 { // noid never reached the API; the 429 didn't abort the rest
		t.Errorf("read back %v, want 3 GETs (the failed one must not stop the others)", r.calls)
	}
}

// TestVerifyApplyRereadsAnUnconfirmedCreateByItsOwnID: a CREATE whose confirming
// read-back failed transiently leaves NO baseline entry — the apply refuses to record
// a convergence it never observed — so the configuration id exists only on the
// outcome. Verification must use that one. Deriving it from the baseline made the
// retry impossible in exactly the case verification exists for, and reported a
// healthy create plus one flaky GET to the operator as a dropped write.
func TestVerifyApplyRereadsAnUnconfirmedCreateByItsOwnID(t *testing.T) {
	desired := map[string][]byte{"fresh.mobileconfig": []byte("<plist>FRESH</plist>")}
	base := &state.State{Configs: map[string]state.Entry{}} // deliberately empty
	r := &fakeConfigReader{byID: map[string]ab.LiveConfig{
		"cfg-fresh": {Name: "fresh.mobileconfig", ID: "cfg-fresh", XML: "<plist>FRESH</plist>"},
	}}
	written := []writtenConfig{{Name: "fresh.mobileconfig", ABMID: "cfg-fresh", Verified: reconcile.VerifyUnconfirmed}}

	if ms := verifyApply(verifyTargeted, r, written, desired, base, nil, nil); len(ms) != 0 {
		t.Fatalf("mismatches = %+v, want none — the retry could read the create back", ms)
	}
	if len(r.calls) != 1 || r.calls[0] != "cfg-fresh" {
		t.Errorf("read back %v, want [cfg-fresh] resolved from the outcome's own id", r.calls)
	}
	// …and the apply really does carry the id out on an unconfirmed write.
	got := writtenConfigs(&reconcile.Result{Outcomes: []reconcile.Outcome{
		{Name: "fresh.mobileconfig", Action: reconcile.Create, Status: "done", ABMID: "cfg-fresh", Verified: reconcile.VerifyUnconfirmed},
	}})
	if len(got) != 1 || got[0].ABMID != "cfg-fresh" {
		t.Errorf("writtenConfigs dropped the id: %+v", got)
	}
}

// TestReportVerificationSeparatesObservedFromUnverifiable: "still differs from
// desired" is a statement of fact, so it may only be printed about a difference that
// was actually measured — and the PayloadVersion hint, which accuses a named profile
// of being out of spec, rides only on those. A read-back that produced no answer says
// exactly that instead. Both keep the FAILED marker CI and abgui grep for.
func TestReportVerificationSeparatesObservedFromUnverifiable(t *testing.T) {
	var sb strings.Builder
	reportVerification(&sb, verifyTargeted, writes("seen.mobileconfig", "unknown.mobileconfig"), []verifyMismatch{
		{Name: "seen.mobileconfig", Detail: "live content hash aaa != desired bbb", Observed: true},
		{Name: "unknown.mobileconfig", Detail: "re-reading the configuration from Apple failed: 429 rate limited"},
	})
	out := sb.String()
	if !strings.Contains(out, "post-apply verification FAILED: seen.mobileconfig still differs from desired") {
		t.Errorf("report =\n%s\nwant the observed difference stated as one", out)
	}
	if !strings.Contains(out, "post-apply verification FAILED: unknown.mobileconfig could NOT be verified") {
		t.Errorf("report =\n%s\nwant the unread config reported as unverified", out)
	}
	if strings.Contains(out, "unknown.mobileconfig still differs") {
		t.Errorf("report =\n%s\nmust not claim a difference that was never observed", out)
	}
	if !strings.Contains(out, "1 of 2 written configuration(s) did not land") {
		t.Errorf("report =\n%s\nwant the did-not-land count to be the OBSERVED count", out)
	}

	// Nothing observed → no PayloadVersion accusation at all, but still a FAILED line
	// (the run cannot claim the tenant matches git).
	var unread strings.Builder
	reportVerification(&unread, verifyTargeted, writes("unknown.mobileconfig"),
		[]verifyMismatch{{Name: "unknown.mobileconfig", Detail: "429 rate limited"}})
	if strings.Contains(unread.String(), "PayloadVersion") {
		t.Errorf("report =\n%s\nmust not blame the profile when nothing was compared", unread.String())
	}
	if !strings.Contains(unread.String(), "FAILED") || !strings.Contains(unread.String(), "could not be checked") {
		t.Errorf("report =\n%s\nwant the FAILED marker and the honest summary", unread.String())
	}
}

// TestVerifyApplyFullDiffsTheRefresh: --verify=full already re-fetches live configs
// but used them only to harvest ids. It must now diff them: drifted bytes and a
// config that vanished from the tenant are both mismatches, with no extra GETs.
func TestVerifyApplyFullDiffsTheRefresh(t *testing.T) {
	desired := map[string][]byte{
		"a.mobileconfig":    []byte("<plist>A</plist>"),
		"gone.mobileconfig": []byte("<plist>GONE</plist>"),
		"ok.mobileconfig":   []byte("<plist>OK</plist>"),
	}
	liveAfter := []ab.LiveConfig{
		{Name: "a.mobileconfig", ID: "cfg-a", XML: "<plist>STALE</plist>", Updated: "2026-07-19T19:42:05.476Z"},
		{Name: "ok.mobileconfig", ID: "cfg-ok", XML: "<plist>OK</plist>"},
		{Name: "untouched.mobileconfig", ID: "cfg-u", XML: "<plist>WHATEVER</plist>"},
	}
	r := &fakeConfigReader{}
	ms := verifyApply(verifyFull, r, writes("a.mobileconfig", "gone.mobileconfig", "ok.mobileconfig"), desired, nil, liveAfter, nil)
	if len(ms) != 2 {
		t.Fatalf("mismatches = %+v, want the drifted and the absent config", ms)
	}
	if ms[0].Name != "a.mobileconfig" || !strings.Contains(ms[0].Detail, "!=") {
		t.Errorf("drift not reported: %+v", ms[0])
	}
	if ms[1].Name != "gone.mobileconfig" || !strings.Contains(ms[1].Detail, "absent") {
		t.Errorf("absent config not reported: %+v", ms[1])
	}
	if len(r.calls) != 0 {
		t.Errorf("full verification made %v extra GETs; the refresh it already paid for is the read-back", r.calls)
	}
}

// TestVerifyApplyNoneSkipsEverything: --verify=none stays an explicit opt-out — no
// read-back calls, no verdict, no output, even when live has clearly drifted.
func TestVerifyApplyNoneSkipsEverything(t *testing.T) {
	desired := map[string][]byte{"a.mobileconfig": []byte("<plist>A</plist>")}
	base := &state.State{Configs: map[string]state.Entry{"a.mobileconfig": {ABMID: "cfg-a"}}}
	r := &fakeConfigReader{byID: map[string]ab.LiveConfig{
		"cfg-a": {Name: "a.mobileconfig", ID: "cfg-a", XML: "<plist>DRIFTED</plist>"},
	}}
	liveAfter := []ab.LiveConfig{{Name: "a.mobileconfig", ID: "cfg-a", XML: "<plist>DRIFTED</plist>"}}
	written := writes("a.mobileconfig")

	if ms := verifyApply(verifyNone, r, written, desired, base, liveAfter, nil); ms != nil {
		t.Errorf("verify=none returned %+v, want no verdict", ms)
	}
	if len(r.calls) != 0 {
		t.Errorf("verify=none made API calls: %v", r.calls)
	}
	var sb strings.Builder
	reportVerification(&sb, verifyNone, written, nil)
	if sb.String() != "" {
		t.Errorf("verify=none printed %q, want nothing", sb.String())
	}
}

// TestFinishApplyAlwaysRendersTheReceipt is the receipt bug: a failure AFTER the
// tenant was written (baseline save, a verification fetch) used to `return err` and
// the per-item results were never rendered — the operator got one error line and no
// record of what changed. Now the table/JSON always lands first, and the error is
// still returned.
func TestFinishApplyAlwaysRendersTheReceipt(t *testing.T) {
	res := applyResult(
		[3]string{"a.mobileconfig", string(reconcile.Update), "done"},
		[3]string{"b.mobileconfig", string(reconcile.Create), "done"},
	)
	fetchErr := errors.New("post-apply refresh failed: 503")

	out, err := captureStdoutErr(t, func() error { return finishApply(false, "", res, nil, nil, fetchErr) })
	if !errors.Is(err, fetchErr) {
		t.Errorf("err = %v, want the fetch error preserved", err)
	}
	for _, want := range []string{"a.mobileconfig", "b.mobileconfig", "ACTION"} {
		if !strings.Contains(out, want) {
			t.Errorf("table receipt =\n%s\nwant it to contain %q", out, want)
		}
	}

	// Machine output keeps a stable shape even though the blueprint phase never ran.
	out, err = captureStdoutErr(t, func() error { return finishApply(true, "json", res, nil, nil, fetchErr) })
	if !errors.Is(err, fetchErr) {
		t.Errorf("json err = %v, want the fetch error preserved", err)
	}
	for _, want := range []string{`"configs"`, `"blueprints"`, "a.mobileconfig"} {
		if !strings.Contains(out, want) {
			t.Errorf("json receipt =\n%s\nwant it to contain %s", out, want)
		}
	}
	// A run that died before verification ran has no verdict to report — and must not
	// invent one, since an absent key and "checked, all good" are different claims.
	if strings.Contains(out, `"verification"`) {
		t.Errorf("json receipt =\n%s\nwant NO verification key when verification never ran", out)
	}
}

// TestFinishApplyJSONCarriesTheVerificationVerdict: `-o json` is the documented
// machine contract, and the exit code is not part of a parsed document. A run whose
// items are all "done" and whose errors are 0 can still exit 1 because the read-back
// failed — so the verdict has to be IN the document, not only in stderr prose.
func TestFinishApplyJSONCarriesTheVerificationVerdict(t *testing.T) {
	res := applyResult([3]string{"mli.mobileconfig", string(reconcile.Update), "done"})
	ver := newVerificationReport(verifyTargeted, writes("mli.mobileconfig"),
		[]verifyMismatch{{Name: "mli.mobileconfig", Detail: "live content hash abc != desired def", Observed: true}})

	out, err := captureStdoutErr(t, func() error { return finishApply(true, "json", res, nil, ver, ExitError{Code: 1}) })
	var ee ExitError
	if !errors.As(err, &ee) || ee.Code != 1 {
		t.Errorf("err = %v, want ExitError{1}", err)
	}
	for _, want := range []string{`"verification"`, `"mode": "targeted"`, `"written": 1`, `"verified": 0`, `"mismatches"`, `"observed": true`, "mli.mobileconfig"} {
		if !strings.Contains(out, want) {
			t.Errorf("json receipt =\n%s\nwant it to contain %s", out, want)
		}
	}

	// A clean verdict is still reported — a consumer must be able to tell "checked and
	// matched" from "not checked", which is what mode + verified say.
	clean := newVerificationReport(verifyTargeted, writes("a.mobileconfig", "b.mobileconfig"), nil)
	if clean.Verified != 2 || len(clean.Mismatches) != 0 {
		t.Errorf("clean report = %+v, want 2 verified and an empty (non-nil) mismatch list", clean)
	}
	// --verify=none checked nothing, so it claims nothing.
	if none := newVerificationReport(verifyNone, writes("a.mobileconfig"), nil); none.Verified != 0 || none.Written != 1 {
		t.Errorf("none report = %+v, want written 1 / verified 0", none)
	}
}

// TestFinishApplyExitContract: exit 0 clean, exit 1 on item errors (unchanged), and
// an explicit cause (verification mismatch / plumbing failure) wins over both.
func TestFinishApplyExitContract(t *testing.T) {
	clean := applyResult([3]string{"a.mobileconfig", string(reconcile.Update), "done"})
	broken := applyResult([3]string{"a.mobileconfig", string(reconcile.Update), "error"})
	bpBroken := &reconcile.BlueprintResult{Outcomes: []reconcile.BlueprintOutcome{}, Errors: 1}

	if _, err := captureStdoutErr(t, func() error { return finishApply(false, "", clean, nil, nil, nil) }); err != nil {
		t.Errorf("clean apply = %v, want nil (exit 0)", err)
	}
	var ee ExitError
	if _, err := captureStdoutErr(t, func() error { return finishApply(false, "", broken, nil, nil, nil) }); !errors.As(err, &ee) || ee.Code != 1 {
		t.Errorf("item error = %v, want ExitError{1}", err)
	}
	if _, err := captureStdoutErr(t, func() error { return finishApply(false, "", clean, bpBroken, nil, nil) }); !errors.As(err, &ee) || ee.Code != 1 {
		t.Errorf("blueprint error = %v, want ExitError{1}", err)
	}
	cause := errors.New("baseline save failed")
	if _, err := captureStdoutErr(t, func() error { return finishApply(false, "", broken, nil, nil, cause) }); !errors.Is(err, cause) {
		t.Errorf("err = %v, want the specific cause to win over the generic exit code", err)
	}
}

// fakeTenant is a whole write API: it satisfies BOTH reconcile.Applier (so the
// engine can run against it) and configDetailReader (so the CLI verifier can),
// which is the point — the two layers must be measured on ONE ledger.
type fakeTenant struct {
	stored  map[string]ab.LiveConfig // id → what Apple actually kept
	updated map[string]string        // id → timestamp the write response echoes
	gets    []string
}

func (f *fakeTenant) CreateConfiguration(name, xml string, _ []string) (string, string, error) {
	id := "cfg-" + name
	f.stored[id] = ab.LiveConfig{Name: name, ID: id, XML: xml, Updated: "2026-07-25T12:00:00Z"}
	return id, "2026-07-25T12:00:00Z", nil
}

func (f *fakeTenant) UpdateConfiguration(id, name, xml string) (string, error) {
	f.stored[id] = ab.LiveConfig{Name: name, ID: id, XML: xml, Updated: "2026-07-25T12:00:00Z"}
	return f.updated[id], nil
}

func (f *fakeTenant) FetchCustomSettingDetail(id string) (ab.LiveConfig, error) {
	f.gets = append(f.gets, id)
	lc, ok := f.stored[id]
	if !ok {
		return ab.LiveConfig{}, errors.New("no such configuration: " + id)
	}
	return lc, nil
}

func (f *fakeTenant) DeleteConfiguration(string) error { return nil }
func (f *fakeTenant) CreateBlueprint(string, string, map[string][]string) (*ab.Resource, error) {
	return nil, errors.New("unused")
}
func (f *fakeTenant) AddBlueprintMembers(string, string, string, []string) error    { return nil }
func (f *fakeTenant) RemoveBlueprintMembers(string, string, string, []string) error { return nil }

// TestReadBackLedgerIsOneGetPerWrittenConfig measures the traffic the way Apple
// sees it: the engine's confirming read-back and the CLI's post-apply verification
// hit the same endpoint for the same ids, so they must be counted TOGETHER. The
// contract (AGENT.md: Apple rate-limits hard) is exactly one detail GET per config
// actually written, and none for configs that were not.
func TestReadBackLedgerIsOneGetPerWrittenConfig(t *testing.T) {
	const oldXML, newXML = "<plist>OLD</plist>", "<plist>NEW</plist>"
	tenant := &fakeTenant{
		stored: map[string]ab.LiveConfig{
			"cfg-upd":   {Name: "upd.mobileconfig", ID: "cfg-upd", XML: oldXML, Updated: "2026-07-01T00:00:00Z"},
			"cfg-quiet": {Name: "quiet.mobileconfig", ID: "cfg-quiet", XML: oldXML, Updated: "2026-07-01T00:00:00Z"},
		},
		updated: map[string]string{"cfg-upd": "2026-07-25T12:00:00Z"},
	}
	tree := gitops.NewTree(t.TempDir())
	eng := &reconcile.Engine{
		Client:   tenant,
		Archiver: cliArchiver{root: tree.ArchiveDir, now: time.Now},
		Files:    tree,
	}
	desired := map[string][]byte{
		"upd.mobileconfig":   []byte(newXML),
		"new.mobileconfig":   []byte(newXML),
		"quiet.mobileconfig": []byte(oldXML), // unchanged: never written, never read back
	}
	live := []ab.LiveConfig{
		{Name: "upd.mobileconfig", ID: "cfg-upd", XML: oldXML, Updated: "2026-07-01T00:00:00Z"},
		{Name: "quiet.mobileconfig", ID: "cfg-quiet", XML: oldXML, Updated: "2026-07-01T00:00:00Z"},
	}
	base := &state.State{Configs: map[string]state.Entry{
		"upd.mobileconfig":   {ABMID: "cfg-upd", Hash: hash.Raw([]byte(oldXML)), UpdatedDateTime: "2026-07-01T00:00:00Z"},
		"quiet.mobileconfig": {ABMID: "cfg-quiet", Hash: hash.Raw([]byte(oldXML)), UpdatedDateTime: "2026-07-01T00:00:00Z"},
	}}

	res := eng.Apply(reconcile.Compute(desired, base, live), desired, live, base, reconcile.Opts{})
	if res.Errors != 0 {
		t.Fatalf("unexpected apply errors: %+v", res.Outcomes)
	}
	written := writtenConfigs(res)
	if len(written) != 2 {
		t.Fatalf("written = %v, want the create and the update", written)
	}
	if ms := verifyApply(verifyTargeted, tenant, written, desired, base, nil, nil); len(ms) != 0 {
		t.Fatalf("verification reported mismatches on a tenant that stored the bytes: %+v", ms)
	}

	perID := map[string]int{}
	for _, id := range tenant.gets {
		perID[id]++
	}
	for _, id := range []string{"cfg-upd", "cfg-new.mobileconfig"} {
		if perID[id] != 1 {
			t.Errorf("GET ledger for %s = %d, want exactly 1 (engine read-back and CLI verification must not both fetch it)", id, perID[id])
		}
	}
	if perID["cfg-quiet"] != 0 {
		t.Errorf("an unwritten config was read back %d time(s): %v", perID["cfg-quiet"], tenant.gets)
	}
	if len(tenant.gets) != len(written) {
		t.Errorf("total read-back GETs = %d for %d written config(s): %v — one GET per write is the budget", len(tenant.gets), len(written), tenant.gets)
	}
}

// captureStdoutErr redirects os.Stdout for the duration of fn and returns what it
// printed together with fn's error — the receipt-before-error ORDER is the contract
// under test, so the error must not short-circuit the capture.
func captureStdoutErr(t *testing.T, fn func() error) (string, error) {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	runErr := fn()
	_ = w.Close()
	os.Stdout = old
	b, _ := io.ReadAll(r)
	return string(b), runErr
}
