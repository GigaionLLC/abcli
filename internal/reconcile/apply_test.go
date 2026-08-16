package reconcile

import (
	"errors"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/gitops"
	"github.com/GigaionLLC/abcli/internal/hash"
	"github.com/GigaionLLC/abcli/internal/state"
)

// fakes implements Applier + Archiver + FileStore, recording an ordered event log
// so tests can assert both *what* happened and *in what order* (archive-before-write).
// relOps additionally records each membership call's relationship + member type,
// so per-collection tests can assert the API relation without disturbing the
// event-log format older tests pin.
//
// stored models Apple's side of a write: a successful POST/PATCH puts the bytes in
// stored[id] and the read-back returns them. dropWrites reproduces the real defect
// this engine now guards against — Apple answers 2xx but keeps the old bytes.
type fakes struct {
	events      []string
	relOps      []string
	files       map[string]string
	stored      map[string]string // id → the profile XML Apple "persisted"
	updatedTS   string            // updatedDateTime echoed by a write response
	readBackTS  string            // updatedDateTime reported by a read-back
	dropWrites  bool              // 2xx, but nothing is persisted (the silent drop)
	readBackErr bool              // the confirming GET fails (network / rate limit)
	createErr   bool
	updateErr   bool
	deleteErr   bool
	writeErr    bool
	removeErr   bool
	archiveErr  bool
	bpCreateErr bool
	bpAddErr    bool
	bpRemoveErr bool
	// bpSpecs is the fake gitops/blueprints/ tree — the manifests an adopt row
	// rewrites. Adopt is a LOCAL write, so it lands here and never in events'
	// tenant calls.
	bpSpecs     map[string]gitops.BlueprintSpec
	bpSpecErr   bool // LoadBlueprints fails (unreadable/malformed manifest)
	bpSpecWrErr bool // WriteBlueprintSpec fails (read-only tree)
	// members is the tenant's actual blueprint membership, keyed "<bpID>/<rel>".
	members map[string]map[string]bool
	// dropMembership: Apple answers 2xx to an attach and does not apply it — the
	// membership analogue of dropWrites, and what the verification pass must catch.
	dropMembership bool
	bpRelErr       bool // the verifying re-read itself fails
}

func newFakes() *fakes {
	return &fakes{
		files:      map[string]string{},
		stored:     map[string]string{},
		bpSpecs:    map[string]gitops.BlueprintSpec{},
		members:    map[string]map[string]bool{},
		updatedTS:  "ts-server",
		readBackTS: "ts-server",
	}
}

func (f *fakes) CreateConfiguration(name, xml string, _ []string) (string, string, error) {
	if f.createErr {
		return "", "", errors.New("create boom")
	}
	f.events = append(f.events, "create:"+name)
	if !f.dropWrites {
		f.stored["id-"+name] = xml
	}
	return "id-" + name, f.updatedTS, nil
}

func (f *fakes) UpdateConfiguration(id, _, xml string) (string, error) {
	if f.updateErr {
		return "", errors.New("update boom")
	}
	f.events = append(f.events, "update:"+id)
	if !f.dropWrites {
		f.stored[id] = xml
	}
	return f.updatedTS, nil
}

// FetchCustomSettingDetail is the post-write read-back: it reports what Apple
// actually stored, which is *not* necessarily what the write sent.
func (f *fakes) FetchCustomSettingDetail(id string) (ab.LiveConfig, error) {
	f.events = append(f.events, "readback:"+id)
	if f.readBackErr {
		return ab.LiveConfig{}, errors.New("readback boom")
	}
	return ab.LiveConfig{ID: id, XML: f.stored[id], Updated: f.readBackTS}, nil
}

func (f *fakes) DeleteConfiguration(id string) error {
	if f.deleteErr {
		return errors.New("delete boom")
	}
	f.events = append(f.events, "delete:"+id)
	return nil
}

func (f *fakes) Archive(name, reason string, _ []byte, _ map[string]string) (string, error) {
	if f.archiveErr {
		return "", errors.New("archive boom")
	}
	f.events = append(f.events, "archive:"+name+":"+reason)
	return "/arch/" + name, nil
}

func (f *fakes) WriteConfig(name string, content []byte) error {
	if f.writeErr {
		return errors.New("write boom")
	}
	f.events = append(f.events, "writefile:"+name)
	f.files[name] = string(content)
	return nil
}

func (f *fakes) RemoveConfig(name string) error {
	if f.removeErr {
		return errors.New("remove boom")
	}
	f.events = append(f.events, "removefile:"+name)
	delete(f.files, name)
	return nil
}

func (f *fakes) CreateBlueprint(name, description string, members map[string][]string) (*ab.Resource, error) {
	if f.bpCreateErr {
		return nil, errors.New("create blueprint boom")
	}
	// Record inlined membership deterministically (sorted rel, ids in plan order)
	// so tests can assert exactly what rode along in the create POST.
	rels := make([]string, 0, len(members))
	for rel := range members {
		rels = append(rels, rel)
	}
	sort.Strings(rels)
	inline := ""
	for _, rel := range rels {
		inline += ";" + rel + "=" + strings.Join(members[rel], ",")
	}
	f.events = append(f.events, "createbp:"+name+":"+description+inline)
	id := "bp-" + name
	// Inlined members really are attached by the create, so the fake tenant must hold
	// them — otherwise the post-apply membership check reads an empty relationship and
	// correctly reports every inlined member as not applied.
	if !f.dropMembership {
		for _, rel := range rels {
			if f.members[id+"/"+rel] == nil {
				f.members[id+"/"+rel] = map[string]bool{}
			}
			for _, mid := range members[rel] {
				f.members[id+"/"+rel][mid] = true
			}
		}
	}
	return &ab.Resource{Type: "blueprints", ID: id}, nil
}

func (f *fakes) AddBlueprintMembers(bpID, rel, memberType string, ids []string) error {
	if f.bpAddErr {
		return errors.New("attach boom")
	}
	f.events = append(f.events, "attach:"+bpID+":"+strings.Join(ids, ","))
	f.relOps = append(f.relOps, "POST:"+rel+":"+memberType)
	if !f.dropMembership {
		if f.members[bpID+"/"+rel] == nil {
			f.members[bpID+"/"+rel] = map[string]bool{}
		}
		for _, id := range ids {
			f.members[bpID+"/"+rel][id] = true
		}
	}
	return nil
}

func (f *fakes) RemoveBlueprintMembers(bpID, rel, memberType string, ids []string) error {
	if f.bpRemoveErr {
		return errors.New("detach boom")
	}
	f.events = append(f.events, "detach:"+bpID+":"+strings.Join(ids, ","))
	f.relOps = append(f.relOps, "DELETE:"+rel+":"+memberType)
	for _, id := range ids {
		delete(f.members[bpID+"/"+rel], id)
	}
	return nil
}

// BlueprintRelationship is what the post-apply membership check reads. It reports the
// fake tenant's ACTUAL membership, so `dropMembership` can model Apple accepting a write
// and not applying it — the membership analogue of dropWrites.
func (f *fakes) BlueprintRelationship(bpID, rel string) ([]ab.Resource, error) {
	if f.bpRelErr {
		return nil, errors.New("relationship read boom")
	}
	f.events = append(f.events, "relread:"+bpID+"/"+rel)
	out := []ab.Resource{}
	for id := range f.members[bpID+"/"+rel] {
		out = append(out, ab.Resource{ID: id})
	}
	return out, nil
}

func (f *fakes) LoadBlueprints() (map[string]gitops.BlueprintSpec, error) {
	if f.bpSpecErr {
		return nil, errors.New("load blueprints boom")
	}
	out := make(map[string]gitops.BlueprintSpec, len(f.bpSpecs))
	for k, v := range f.bpSpecs {
		out[k] = v
	}
	return out, nil
}

func (f *fakes) WriteBlueprintSpec(s gitops.BlueprintSpec) error {
	if f.bpSpecWrErr {
		return errors.New("write blueprint boom")
	}
	f.events = append(f.events, "writespec:"+s.Name)
	f.bpSpecs[s.Name] = s
	return nil
}

func engineWith(f *fakes) *Engine { return &Engine{Client: f, Archiver: f, Files: f} }

func statusOf(res *Result, name string) (Action, string) {
	for _, o := range res.Outcomes {
		if o.Name == name {
			return o.Action, o.Status
		}
	}
	return "", "absent"
}

// TestApplyActions drives one of every action through Apply and checks the tenant
// calls, the git-file effects, and the resulting baseline.
func TestApplyActions(t *testing.T) {
	f := newFakes()
	desired := map[string][]byte{
		"new.mobileconfig":    []byte("NEW"),
		"upd.mobileconfig":    []byte("UPD-NEW"),
		"delgit.mobileconfig": []byte("STILL-IN-GIT"),
	}
	live := []ab.LiveConfig{
		{Name: "upd.mobileconfig", ID: "id-upd", XML: "UPD-OLD", Updated: "t0"},
		{Name: "pull.mobileconfig", ID: "id-pull", XML: "PULLED", Updated: "t1"},
		{Name: "pullnew.mobileconfig", ID: "id-pn", XML: "CONSOLE", Updated: "t1"},
	}
	base := &state.State{Configs: map[string]state.Entry{
		"upd.mobileconfig":    {ABMID: "id-upd", Hash: hash.Raw([]byte("UPD-OLD")), UpdatedDateTime: "t0"},
		"pull.mobileconfig":   {ABMID: "id-pull", Hash: hash.Raw([]byte("PULL-OLD")), UpdatedDateTime: "t0"},
		"delgit.mobileconfig": {ABMID: "id-dg", Hash: hash.Raw([]byte("STILL-IN-GIT")), UpdatedDateTime: "t0"},
	}}
	plan := &Plan{Items: []Item{
		{Name: "new.mobileconfig", Action: Create},
		{Name: "upd.mobileconfig", Action: Update},
		{Name: "pull.mobileconfig", Action: Pull},
		{Name: "pullnew.mobileconfig", Action: PullNew},
		{Name: "delgit.mobileconfig", Action: DeleteGit},
	}}

	res := engineWith(f).Apply(plan, desired, live, base, Opts{})

	if res.Errors != 0 || res.Skipped != 0 {
		t.Fatalf("errors=%d skipped=%d, want 0/0: %+v", res.Errors, res.Skipped, res.Outcomes)
	}
	if res.Writes != 2 { // create + update; pull/pullnew/delgit are local
		t.Errorf("writes=%d, want 2", res.Writes)
	}
	// Create → baseline gets server id + hash of desired.
	if e := base.Configs["new.mobileconfig"]; e.ABMID != "id-new.mobileconfig" || e.Hash != hash.Raw([]byte("NEW")) || e.UpdatedDateTime != "ts-server" {
		t.Errorf("create baseline = %+v", e)
	}
	// Update → archived first, then patched, baseline hash advances.
	if e := base.Configs["upd.mobileconfig"]; e.Hash != hash.Raw([]byte("UPD-NEW")) || e.UpdatedDateTime != "ts-server" {
		t.Errorf("update baseline = %+v", e)
	}
	// Pull / PullNew → git file written, baseline matches live.
	if f.files["pull.mobileconfig"] != "PULLED" || f.files["pullnew.mobileconfig"] != "CONSOLE" {
		t.Errorf("pulled files = %v", f.files)
	}
	if e := base.Configs["pullnew.mobileconfig"]; e.ABMID != "id-pn" || e.Hash != hash.Raw([]byte("CONSOLE")) {
		t.Errorf("pullnew baseline = %+v", e)
	}
	// DeleteGit → git file removed, baseline entry gone.
	if _, ok := base.Configs["delgit.mobileconfig"]; ok {
		t.Error("delgit baseline entry should be removed")
	}
	// Archive must precede the update it protects.
	if got := indexOf(f.events, "archive:upd.mobileconfig:"+reasonReplaced); got < 0 || got > indexOf(f.events, "update:id-upd") {
		t.Errorf("archive did not precede update: %v", f.events)
	}
}

// TestApplyWriteConfirmation drives the post-write read-back matrix on the Update
// path. Apple answers a POST/PATCH 2xx and then silently discards a profile that
// violates its schema (an outer PayloadVersion of 2 does exactly that), so a
// baseline recorded from the desired bytes books the dropped write as success and
// every later run recomputes the identical change. The baseline may therefore only
// come from OBSERVED state — or not be written at all.
func TestApplyWriteConfirmation(t *testing.T) {
	const oldXML, newXML = "OLD", "NEW"
	oldHash, newHash := hash.Raw([]byte(oldXML)), hash.Raw([]byte(newXML))

	cases := []struct {
		name       string
		setup      func(*fakes)
		status     string
		detailHas  []string
		wantHash   string // baseline hash expected after the run
		wantTS     string // baseline updatedDateTime expected after the run
		wantReadBk bool   // a confirming GET was (not) worth issuing
		wantVerify Verification
	}{
		{
			name:       "persisted: baseline records the OBSERVED hash and timestamp",
			setup:      func(f *fakes) { f.readBackTS = "ts-observed" },
			status:     "done",
			detailHas:  []string{"patched ABM"},
			wantHash:   newHash,
			wantTS:     "ts-observed", // read-back's timestamp, not the PATCH echo
			wantReadBk: true,
			wantVerify: VerifyConfirmed,
		},
		{
			name:       "silently dropped: read-back still holds the pre-write bytes",
			setup:      func(f *fakes) { f.dropWrites = true },
			status:     "error",
			detailHas:  []string{"did not persist", "PayloadVersion"},
			wantHash:   oldHash, // baseline must NOT advance
			wantTS:     "t0",
			wantReadBk: true,
			wantVerify: VerifyNotPersisted,
		},
		{
			// The frozen timestamp is corroboration, not the verdict: the read-back is
			// still issued and its answer is what fails the write.
			name:       "unchanged echoed timestamp corroborates the read-back's mismatch",
			setup:      func(f *fakes) { f.dropWrites, f.updatedTS, f.readBackTS = true, "t0", "t0" },
			status:     "error",
			detailHas:  []string{"did not persist", "echoed the unchanged updatedDateTime", "PayloadVersion"},
			wantHash:   oldHash,
			wantTS:     "t0",
			wantReadBk: true,
			wantVerify: VerifyNotPersisted,
		},
		{
			// The regression the early return caused: a PATCH that stores nothing because
			// the bytes are ALREADY what git wants cannot bump updatedDateTime either. The
			// read-back overrules the hint, the baseline advances, and the run converges
			// instead of failing forever with a false PayloadVersion accusation. (Compute
			// reaches this via a Conflict resolved to Update over identical content.)
			name:       "no-op write with a frozen timestamp is confirmed by the read-back",
			setup:      func(f *fakes) { f.updatedTS, f.readBackTS = "t0", "t0" },
			status:     "done",
			detailHas:  []string{"patched ABM"},
			wantHash:   newHash,
			wantTS:     "t0",
			wantReadBk: true,
			wantVerify: VerifyConfirmed,
		},
		{
			// Neither signal is conclusive alone; together they are. A frozen timestamp
			// AND no readable profile is the dropped write, not a flaky GET.
			name:       "frozen timestamp plus an unreadable read-back is the dropped write",
			setup:      func(f *fakes) { f.updatedTS, f.readBackErr = "t0", true },
			status:     "error",
			detailHas:  []string{"did not persist", "echoed the unchanged updatedDateTime", "readback boom"},
			wantHash:   oldHash,
			wantTS:     "t0",
			wantReadBk: true,
			wantVerify: VerifyNotPersisted,
		},
		{
			name:       "read-back error is done-but-unverified, never a failed write",
			setup:      func(f *fakes) { f.readBackErr = true },
			status:     "done",
			detailHas:  []string{"NOT VERIFIED", "readback boom"},
			wantHash:   oldHash, // no optimistic baseline that could mask real drift
			wantTS:     "t0",
			wantReadBk: true,
			wantVerify: VerifyUnconfirmed,
		},
		{
			name:       "read-back without profile XML is unverified, not an accusation",
			setup:      func(f *fakes) { f.dropWrites = true; f.stored["id-u"] = "" },
			status:     "done",
			detailHas:  []string{"NOT VERIFIED", "no profile XML"},
			wantHash:   oldHash,
			wantTS:     "t0",
			wantReadBk: true,
			wantVerify: VerifyUnconfirmed,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFakes()
			f.stored["id-u"] = oldXML // what Apple holds before the write
			tc.setup(f)
			desired := map[string][]byte{"u.mobileconfig": []byte(newXML)}
			live := []ab.LiveConfig{{Name: "u.mobileconfig", ID: "id-u", XML: oldXML, Updated: "t0"}}
			base := &state.State{Configs: map[string]state.Entry{
				"u.mobileconfig": {ABMID: "id-u", Hash: oldHash, UpdatedDateTime: "t0"},
			}}
			plan := &Plan{Items: []Item{{Name: "u.mobileconfig", Action: Update}}}

			res := engineWith(f).Apply(plan, desired, live, base, Opts{})

			var got Outcome
			for _, o := range res.Outcomes {
				if o.Name == "u.mobileconfig" {
					got = o
				}
			}
			if got.Status != tc.status {
				t.Fatalf("status = %q (%q), want %q", got.Status, got.Detail, tc.status)
			}
			for _, want := range tc.detailHas {
				if !strings.Contains(got.Detail, want) {
					t.Errorf("detail %q must mention %q", got.Detail, want)
				}
			}
			// The PATCH itself happened either way: it consumed the write budget and
			// its pre-overwrite archive is still the operator's evidence.
			if res.Writes != 1 {
				t.Errorf("writes = %d, want 1 (the PATCH was issued)", res.Writes)
			}
			if got.Archive != "/arch/u.mobileconfig" {
				t.Errorf("archive = %q, want the pre-overwrite copy path", got.Archive)
			}
			if e := base.Configs["u.mobileconfig"]; e.Hash != tc.wantHash || e.UpdatedDateTime != tc.wantTS {
				t.Errorf("baseline = %+v, want hash %s / ts %s", e, tc.wantHash, tc.wantTS)
			}
			if didRead := indexOf(f.events, "readback:id-u") >= 0; didRead != tc.wantReadBk {
				t.Errorf("read-back issued = %v, want %v: %v", didRead, tc.wantReadBk, f.events)
			}
			// The verdict rides on the outcome so a caller can report the write without
			// asking Apple the same question a second time (AGENT.md: rate limits).
			if got.Verified != tc.wantVerify {
				t.Errorf("verified = %q, want %q", got.Verified, tc.wantVerify)
			}
			// So does the id — including on the outcomes whose baseline entry is
			// deliberately not written, which is exactly when a caller has no other
			// source for it (internal/cli re-reads unconfirmed writes by this id).
			if got.ABMID != "id-u" {
				t.Errorf("outcome ABMID = %q, want id-u on every create/update outcome", got.ABMID)
			}
			// Exactly one confirming GET per write, never more.
			if n := countOf(f.events, "readback:id-u"); n > 1 {
				t.Errorf("read-back issued %d times, want at most 1: %v", n, f.events)
			}
			// The confirming GET is a read: it must never be counted as a tenant write.
			if idx := indexOf(f.events, "readback:id-u"); idx >= 0 && idx < indexOf(f.events, "update:id-u") {
				t.Errorf("read-back must follow the write: %v", f.events)
			}
		})
	}
}

// TestApplyCreateWriteConfirmation mirrors the matrix on the Create path, where a
// mismatch must leave NO baseline entry at all — an optimistic one would claim a
// config is synced that Apple never stored.
func TestApplyCreateWriteConfirmation(t *testing.T) {
	desired := map[string][]byte{"n.mobileconfig": []byte("NEW")}
	plan := &Plan{Items: []Item{{Name: "n.mobileconfig", Action: Create}}}

	// Apple accepted the POST but holds different bytes → error, no baseline entry.
	f := newFakes()
	f.dropWrites = true
	f.stored["id-n.mobileconfig"] = "SOMETHING-ELSE"
	base := &state.State{Configs: map[string]state.Entry{}}
	res := engineWith(f).Apply(plan, desired, nil, base, Opts{})
	if res.Errors != 1 || res.Writes != 1 {
		t.Fatalf("dropped create → errors=%d writes=%d, want 1/1: %+v", res.Errors, res.Writes, res.Outcomes)
	}
	if _, ok := base.Configs["n.mobileconfig"]; ok {
		t.Error("a create Apple did not persist must not leave a baseline entry")
	}
	if !strings.Contains(res.Outcomes[0].Detail, "PayloadVersion") {
		t.Errorf("detail %q must name the likely cause", res.Outcomes[0].Detail)
	}
	// A create with no baseline entry is the ONLY place the new id exists — without it
	// on the outcome, nothing downstream could re-read the configuration Apple made.
	if res.Outcomes[0].ABMID != "id-n.mobileconfig" {
		t.Errorf("dropped create ABMID = %q, want the id the POST returned", res.Outcomes[0].ABMID)
	}

	// Confirmed create → baseline from the read-back (id + observed hash + observed ts).
	f = newFakes()
	f.readBackTS = "ts-observed"
	base = &state.State{Configs: map[string]state.Entry{}}
	res = engineWith(f).Apply(plan, desired, nil, base, Opts{})
	if res.Errors != 0 {
		t.Fatalf("confirmed create → errors=%d: %+v", res.Errors, res.Outcomes)
	}
	e := base.Configs["n.mobileconfig"]
	if e.ABMID != "id-n.mobileconfig" || e.Hash != hash.Raw([]byte("NEW")) || e.UpdatedDateTime != "ts-observed" {
		t.Errorf("create baseline = %+v, want the observed read-back state", e)
	}
}

// TestApplyLimitWritesConfirmation pins that the confirming GET rides along with the
// write it confirms: it neither consumes the write budget nor fires for items the
// budget skipped (Apple rate-limits hard — one extra GET per real write, no more).
func TestApplyLimitWritesConfirmation(t *testing.T) {
	f := newFakes()
	desired := map[string][]byte{
		"a.mobileconfig": []byte("A"),
		"b.mobileconfig": []byte("B"),
		"c.mobileconfig": []byte("C"),
	}
	base := &state.State{Configs: map[string]state.Entry{}}
	plan := &Plan{Items: []Item{
		{Name: "a.mobileconfig", Action: Create},
		{Name: "b.mobileconfig", Action: Create},
		{Name: "c.mobileconfig", Action: Create},
	}}

	res := engineWith(f).Apply(plan, desired, nil, base, Opts{LimitWrites: 2})

	if res.Writes != 2 || res.Skipped != 1 {
		t.Fatalf("writes=%d skipped=%d, want 2/1 (GETs are not writes)", res.Writes, res.Skipped)
	}
	reads := 0
	for _, ev := range f.events {
		if strings.HasPrefix(ev, "readback:") {
			reads++
		}
	}
	if reads != 2 {
		t.Errorf("read-backs = %d, want 2 (one per config actually written)", reads)
	}
	if indexOf(f.events, "readback:id-c.mobileconfig") >= 0 {
		t.Error("a config skipped by --limit-writes must not be read back")
	}
}

// TestApplyConflictNewestWins checks both directions and the unresolved case.
func TestApplyConflictNewestWins(t *testing.T) {
	live := []ab.LiveConfig{{Name: "c.mobileconfig", ID: "id-c", XML: "LIVE", Updated: "2026-07-04T12:00:00Z"}}
	mkBase := func() *state.State {
		return &state.State{Configs: map[string]state.Entry{
			"c.mobileconfig": {ABMID: "id-c", Hash: hash.Raw([]byte("OLD")), UpdatedDateTime: "2026-07-01T00:00:00Z"},
		}}
	}
	desired := map[string][]byte{"c.mobileconfig": []byte("GIT")}
	plan := &Plan{Items: []Item{{Name: "c.mobileconfig", Action: Conflict}}}

	// git newer → push (archive + patch)
	f := newFakes()
	gitNewer := func(string) (time.Time, bool) { return time.Date(2026, 7, 5, 0, 0, 0, 0, time.UTC), true }
	res := engineWith(f).Apply(plan, desired, live, mkBase(), Opts{GitTime: gitNewer})
	if act, st := statusOf(res, "c.mobileconfig"); act != Update || st != "done" {
		t.Errorf("git-newer conflict → %s/%s, want update/done", act, st)
	}
	if indexOf(f.events, "archive:c.mobileconfig:"+reasonNewer) < 0 || indexOf(f.events, "update:id-c") < 0 {
		t.Errorf("git-newer conflict must archive+patch: %v", f.events)
	}

	// live newer → pull (no tenant write)
	f = newFakes()
	gitOlder := func(string) (time.Time, bool) { return time.Date(2026, 7, 2, 0, 0, 0, 0, time.UTC), true }
	res = engineWith(f).Apply(plan, desired, live, mkBase(), Opts{GitTime: gitOlder})
	if act, st := statusOf(res, "c.mobileconfig"); act != Pull || st != "done" {
		t.Errorf("live-newer conflict → %s/%s, want pull/done", act, st)
	}
	if res.Writes != 0 || f.files["c.mobileconfig"] != "LIVE" {
		t.Errorf("live-newer conflict must pull, no write: writes=%d files=%v", res.Writes, f.files)
	}

	// tie → git wins (>=)
	f = newFakes()
	tie := func(string) (time.Time, bool) { return time.Date(2026, 7, 4, 12, 0, 0, 0, time.UTC), true }
	res = engineWith(f).Apply(plan, desired, live, mkBase(), Opts{GitTime: tie})
	if act, _ := statusOf(res, "c.mobileconfig"); act != Update {
		t.Errorf("tie conflict → %s, want update (git wins on tie)", act)
	}

	// unknown git time → skipped, nothing touched
	f = newFakes()
	unknown := func(string) (time.Time, bool) { return time.Time{}, false }
	res = engineWith(f).Apply(plan, desired, live, mkBase(), Opts{GitTime: unknown})
	if _, st := statusOf(res, "c.mobileconfig"); st != "skipped" {
		t.Errorf("unknown-git-time conflict → %s, want skipped", st)
	}
	if res.Writes != 0 || len(f.events) != 0 {
		t.Errorf("unresolved conflict must touch nothing: writes=%d events=%v", res.Writes, f.events)
	}

	// nil resolver → skipped (no panic)
	f = newFakes()
	res = engineWith(f).Apply(plan, desired, live, mkBase(), Opts{})
	if _, st := statusOf(res, "c.mobileconfig"); st != "skipped" {
		t.Errorf("nil GitTime conflict → %s, want skipped", st)
	}
}

// TestApplyPruneGate verifies DeleteABM is a no-op without --prune and a gated,
// archived delete with it.
func TestApplyPruneGate(t *testing.T) {
	live := []ab.LiveConfig{{Name: "gone.mobileconfig", ID: "id-gone", XML: "LIVE", Updated: "t0"}}
	mkBase := func() *state.State {
		return &state.State{Configs: map[string]state.Entry{
			"gone.mobileconfig": {ABMID: "id-gone", Hash: hash.Raw([]byte("LIVE")), UpdatedDateTime: "t0"},
		}}
	}
	plan := &Plan{Items: []Item{{Name: "gone.mobileconfig", Action: DeleteABM}}}

	// prune off → skipped, live untouched, baseline retained
	f := newFakes()
	base := mkBase()
	res := engineWith(f).Apply(plan, nil, live, base, Opts{Prune: false})
	if _, st := statusOf(res, "gone.mobileconfig"); st != "skipped" {
		t.Errorf("prune off → %s, want skipped", st)
	}
	if len(f.events) != 0 || res.Writes != 0 {
		t.Errorf("prune off must not write: events=%v", f.events)
	}
	if _, ok := base.Configs["gone.mobileconfig"]; !ok {
		t.Error("prune off must retain the baseline entry")
	}

	// prune on → archive then delete, baseline entry removed
	f = newFakes()
	base = mkBase()
	res = engineWith(f).Apply(plan, nil, live, base, Opts{Prune: true})
	if _, st := statusOf(res, "gone.mobileconfig"); st != "done" {
		t.Errorf("prune on → %s, want done", st)
	}
	if indexOf(f.events, "archive:gone.mobileconfig:"+reasonPruned) != 0 || indexOf(f.events, "delete:id-gone") != 1 {
		t.Errorf("prune must archive-then-delete in order: %v", f.events)
	}
	if _, ok := base.Configs["gone.mobileconfig"]; ok {
		t.Error("prune on must remove the baseline entry")
	}
}

// TestApplyLimitWrites verifies the circuit breaker caps tenant writes and skips
// the rest, while local ops (pull) are unaffected.
func TestApplyLimitWrites(t *testing.T) {
	f := newFakes()
	desired := map[string][]byte{
		"a.mobileconfig": []byte("A"),
		"b.mobileconfig": []byte("B"),
		"c.mobileconfig": []byte("C"),
	}
	live := []ab.LiveConfig{{Name: "p.mobileconfig", ID: "id-p", XML: "P", Updated: "t0"}}
	base := &state.State{Configs: map[string]state.Entry{}}
	plan := &Plan{Items: []Item{
		{Name: "a.mobileconfig", Action: Create},
		{Name: "b.mobileconfig", Action: Create},
		{Name: "c.mobileconfig", Action: Create},
		{Name: "p.mobileconfig", Action: Pull},
	}}

	res := engineWith(f).Apply(plan, desired, live, base, Opts{LimitWrites: 2})
	if res.Writes != 2 {
		t.Errorf("writes=%d, want 2 (capped)", res.Writes)
	}
	if res.Skipped != 1 {
		t.Errorf("skipped=%d, want 1 (the 3rd create)", res.Skipped)
	}
	if f.files["p.mobileconfig"] != "P" {
		t.Error("local pull must still run despite the write cap")
	}
}

// TestApplyArchiveFailureBlocksWrite ensures a failed archive skips the write it
// was protecting — the audit trail is never bypassed.
func TestApplyArchiveFailureBlocksWrite(t *testing.T) {
	f := newFakes()
	f.archiveErr = true
	desired := map[string][]byte{"u.mobileconfig": []byte("NEW")}
	live := []ab.LiveConfig{{Name: "u.mobileconfig", ID: "id-u", XML: "OLD", Updated: "t0"}}
	base := &state.State{Configs: map[string]state.Entry{
		"u.mobileconfig": {ABMID: "id-u", Hash: hash.Raw([]byte("OLD")), UpdatedDateTime: "t0"},
	}}
	plan := &Plan{Items: []Item{{Name: "u.mobileconfig", Action: Update}}}

	res := engineWith(f).Apply(plan, desired, live, base, Opts{})
	if res.Errors != 1 || res.Writes != 0 {
		t.Errorf("archive-fail → errors=%d writes=%d, want 1/0", res.Errors, res.Writes)
	}
	if indexOf(f.events, "update:id-u") >= 0 {
		t.Error("update must NOT run when the pre-overwrite archive failed")
	}
	if e := base.Configs["u.mobileconfig"]; e.Hash != hash.Raw([]byte("OLD")) {
		t.Error("baseline must be untouched when the write was skipped")
	}
}

// TestApplyErrorIsIsolated ensures one failing item does not abort the others.
func TestApplyErrorIsIsolated(t *testing.T) {
	f := newFakes()
	f.createErr = true
	desired := map[string][]byte{
		"bad.mobileconfig":  []byte("X"),
		"good.mobileconfig": []byte("Y"),
	}
	live := []ab.LiveConfig{{Name: "good.mobileconfig", ID: "id-good", XML: "OLD", Updated: "t0"}}
	base := &state.State{Configs: map[string]state.Entry{
		"good.mobileconfig": {ABMID: "id-good", Hash: hash.Raw([]byte("OLD")), UpdatedDateTime: "t0"},
	}}
	plan := &Plan{Items: []Item{
		{Name: "bad.mobileconfig", Action: Create},
		{Name: "good.mobileconfig", Action: Pull},
	}}
	res := engineWith(f).Apply(plan, desired, live, base, Opts{})
	if res.Errors != 1 {
		t.Errorf("errors=%d, want 1", res.Errors)
	}
	if _, st := statusOf(res, "good.mobileconfig"); st != "done" {
		t.Errorf("the good item still ran? got %s", st)
	}
}

// TestApplyPruneArchiveFailureBlocksDelete mirrors the Update archive-failure test
// for the prune path: a failed pre-delete archive must skip the DELETE (the
// audit-trail-never-bypassed invariant applies to deletes too).
func TestApplyPruneArchiveFailureBlocksDelete(t *testing.T) {
	f := newFakes()
	f.archiveErr = true
	live := []ab.LiveConfig{{Name: "gone.mobileconfig", ID: "id-gone", XML: "LIVE", Updated: "t0"}}
	base := &state.State{Configs: map[string]state.Entry{
		"gone.mobileconfig": {ABMID: "id-gone", Hash: hash.Raw([]byte("LIVE")), UpdatedDateTime: "t0"},
	}}
	plan := &Plan{Items: []Item{{Name: "gone.mobileconfig", Action: DeleteABM}}}

	res := engineWith(f).Apply(plan, nil, live, base, Opts{Prune: true})
	if res.Errors != 1 || res.Writes != 0 {
		t.Errorf("archive-fail prune → errors=%d writes=%d, want 1/0", res.Errors, res.Writes)
	}
	if indexOf(f.events, "delete:id-gone") >= 0 {
		t.Error("DELETE must NOT run when the pre-delete archive failed")
	}
	if _, ok := base.Configs["gone.mobileconfig"]; !ok {
		t.Error("baseline entry must be retained when the delete was skipped")
	}
}

// TestApplyLocalWriteFailure verifies a failed git-file write (pull) is an isolated
// error that does NOT advance the baseline.
func TestApplyLocalWriteFailure(t *testing.T) {
	f := newFakes()
	f.writeErr = true
	live := []ab.LiveConfig{{Name: "p.mobileconfig", ID: "id-p", XML: "LIVE", Updated: "t1"}}
	base := &state.State{Configs: map[string]state.Entry{
		"p.mobileconfig": {ABMID: "id-p", Hash: hash.Raw([]byte("OLD")), UpdatedDateTime: "t0"},
	}}
	plan := &Plan{Items: []Item{{Name: "p.mobileconfig", Action: Pull}}}

	res := engineWith(f).Apply(plan, nil, live, base, Opts{})
	if res.Errors != 1 {
		t.Errorf("errors=%d, want 1", res.Errors)
	}
	if e := base.Configs["p.mobileconfig"]; e.Hash != hash.Raw([]byte("OLD")) || e.UpdatedDateTime != "t0" {
		t.Errorf("baseline must NOT advance when the pull write failed: %+v", e)
	}
}

// TestApplyDeleteGitFailure verifies a failed git-file remove is an isolated error
// that RETAINS the baseline entry.
func TestApplyDeleteGitFailure(t *testing.T) {
	f := newFakes()
	f.removeErr = true
	desired := map[string][]byte{"dg.mobileconfig": []byte("X")}
	base := &state.State{Configs: map[string]state.Entry{
		"dg.mobileconfig": {ABMID: "id-dg", Hash: hash.Raw([]byte("X")), UpdatedDateTime: "t0"},
	}}
	plan := &Plan{Items: []Item{{Name: "dg.mobileconfig", Action: DeleteGit}}}

	res := engineWith(f).Apply(plan, desired, nil, base, Opts{})
	if res.Errors != 1 {
		t.Errorf("errors=%d, want 1", res.Errors)
	}
	if _, ok := base.Configs["dg.mobileconfig"]; !ok {
		t.Error("baseline entry must be retained when the git remove failed")
	}
}

func TestApplyReportsProgress(t *testing.T) {
	f := newFakes()
	desired := map[string][]byte{"new.mobileconfig": []byte("NEW")}
	base := &state.State{Configs: map[string]state.Entry{}}
	plan := &Plan{Items: []Item{{Name: "new.mobileconfig", Action: Create}}}
	var progress []string

	res := engineWith(f).Apply(plan, desired, nil, base, Opts{
		Progress: func(line string) { progress = append(progress, line) },
	})

	if res.Errors != 0 || res.Writes != 1 {
		t.Fatalf("apply = errors %d writes %d, want 0/1", res.Errors, res.Writes)
	}
	if indexOf(progress, "applying config create-abm: new.mobileconfig") < 0 {
		t.Fatalf("missing apply progress line: %v", progress)
	}
	if indexOf(progress, "creating configuration in ABM: new.mobileconfig") < 0 {
		t.Fatalf("missing create progress line: %v", progress)
	}
}

func indexOf(ss []string, want string) int {
	for i, s := range ss {
		if s == want {
			return i
		}
	}
	return -1
}

// countOf reports how many times an event fired — the read-back budget is a COUNT,
// not a boolean: issuing the confirming GET twice would silently double the traffic.
func countOf(ss []string, want string) int {
	n := 0
	for _, s := range ss {
		if s == want {
			n++
		}
	}
	return n
}
