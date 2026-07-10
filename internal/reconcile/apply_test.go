package reconcile

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/hash"
	"github.com/GigaionLLC/abcli/internal/state"
)

// fakes implements Applier + Archiver + FileStore, recording an ordered event log
// so tests can assert both *what* happened and *in what order* (archive-before-write).
// relOps additionally records each membership call's relationship + member type,
// so per-collection tests can assert the API relation without disturbing the
// event-log format older tests pin.
type fakes struct {
	events      []string
	relOps      []string
	files       map[string]string
	updatedTS   string
	createErr   bool
	updateErr   bool
	deleteErr   bool
	writeErr    bool
	removeErr   bool
	archiveErr  bool
	bpCreateErr bool
	bpAddErr    bool
	bpRemoveErr bool
}

func newFakes() *fakes { return &fakes{files: map[string]string{}, updatedTS: "ts-server"} }

func (f *fakes) CreateConfiguration(name, _ string, _ []string) (string, string, error) {
	if f.createErr {
		return "", "", errors.New("create boom")
	}
	f.events = append(f.events, "create:"+name)
	return "id-" + name, f.updatedTS, nil
}

func (f *fakes) UpdateConfiguration(id, _, _ string) (string, error) {
	if f.updateErr {
		return "", errors.New("update boom")
	}
	f.events = append(f.events, "update:"+id)
	return f.updatedTS, nil
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

func (f *fakes) CreateBlueprint(name, description string) (*ab.Resource, error) {
	if f.bpCreateErr {
		return nil, errors.New("create blueprint boom")
	}
	f.events = append(f.events, "createbp:"+name+":"+description)
	return &ab.Resource{Type: "blueprints", ID: "bp-" + name}, nil
}

func (f *fakes) AddBlueprintMembers(bpID, rel, memberType string, ids []string) error {
	if f.bpAddErr {
		return errors.New("attach boom")
	}
	f.events = append(f.events, "attach:"+bpID+":"+strings.Join(ids, ","))
	f.relOps = append(f.relOps, "POST:"+rel+":"+memberType)
	return nil
}

func (f *fakes) RemoveBlueprintMembers(bpID, rel, memberType string, ids []string) error {
	if f.bpRemoveErr {
		return errors.New("detach boom")
	}
	f.events = append(f.events, "detach:"+bpID+":"+strings.Join(ids, ","))
	f.relOps = append(f.relOps, "DELETE:"+rel+":"+memberType)
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
