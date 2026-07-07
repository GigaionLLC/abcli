package reconcile

import (
	"testing"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/hash"
	"github.com/GigaionLLC/abcli/internal/state"
)

func h(s string) string { return hash.Raw([]byte(s)) }

// TestCompute exercises every branch of the 3-way (git ↔ baseline ↔ live) diff.
func TestCompute(t *testing.T) {
	desired := map[string][]byte{
		"insync.mobileconfig": []byte("A"),  // unchanged everywhere → no-op
		"gitchg.mobileconfig": []byte("B2"), // baseline B1 → git changed
		"abmchg.mobileconfig": []byte("C"),  // baseline C, live changed
		"both.mobileconfig":   []byte("D2"), // baseline D1; both sides changed
		"gitnew.mobileconfig": []byte("E"),  // not in baseline/live → new in git
		"delgit.mobileconfig": []byte("G"),  // in baseline, absent from live → deleted in ABM
		// delabm intentionally absent from desired (removed from git)
	}
	base := &state.State{Configs: map[string]state.Entry{
		"insync.mobileconfig": {Hash: h("A"), UpdatedDateTime: "t0"},
		"gitchg.mobileconfig": {Hash: h("B1"), UpdatedDateTime: "t0"},
		"abmchg.mobileconfig": {Hash: h("C"), UpdatedDateTime: "t0"},
		"both.mobileconfig":   {Hash: h("D1"), UpdatedDateTime: "t0"},
		"delabm.mobileconfig": {Hash: h("F"), UpdatedDateTime: "t0"},
		"delgit.mobileconfig": {Hash: h("G"), UpdatedDateTime: "t0"},
	}}
	live := []ab.LiveConfig{
		{Name: "insync.mobileconfig", XML: "A", Updated: "t0"},
		{Name: "gitchg.mobileconfig", XML: "B1", Updated: "t0"},
		{Name: "abmchg.mobileconfig", XML: "C2", Updated: "t1"},
		{Name: "both.mobileconfig", XML: "D3", Updated: "t1"},
		{Name: "abmnew.mobileconfig", XML: "H", Updated: "t1"}, // not in baseline → console-created
		{Name: "delabm.mobileconfig", XML: "F", Updated: "t0"}, // removed from git
	}

	got := map[string]Action{}
	for _, it := range Compute(desired, base, live).Items {
		got[it.Name] = it.Action
	}
	want := map[string]Action{
		"gitchg.mobileconfig": Update,
		"abmchg.mobileconfig": Pull,
		"both.mobileconfig":   Conflict,
		"gitnew.mobileconfig": Create,
		"delgit.mobileconfig": DeleteGit,
		"abmnew.mobileconfig": PullNew,
		"delabm.mobileconfig": DeleteABM,
	}
	for name, w := range want {
		if got[name] != w {
			t.Errorf("%s: got %q, want %q", name, got[name], w)
		}
	}
	if _, listed := got["insync.mobileconfig"]; listed {
		t.Error("in-sync config must not appear in the plan")
	}
	if len(got) != len(want) {
		t.Errorf("plan has %d items, want %d: %v", len(got), len(want), got)
	}
}

func TestComputeGitSourceOfTruth(t *testing.T) {
	desired := map[string][]byte{
		"same.mobileconfig":   []byte("A"),
		"patch.mobileconfig":  []byte("GIT"),
		"create.mobileconfig": []byte("NEW"),
	}
	live := []ab.LiveConfig{
		{Name: "same.mobileconfig", XML: "A", Updated: "t1"},
		{Name: "patch.mobileconfig", XML: "LIVE", Updated: "t1"},
		{Name: "delete.mobileconfig", XML: "OLD", Updated: "t1"},
	}

	got := map[string]Action{}
	for _, it := range ComputeGitSourceOfTruth(desired, live).Items {
		got[it.Name] = it.Action
	}
	want := map[string]Action{
		"patch.mobileconfig":  Update,
		"create.mobileconfig": Create,
		"delete.mobileconfig": DeleteABM,
	}
	for name, w := range want {
		if got[name] != w {
			t.Errorf("%s: got %q, want %q", name, got[name], w)
		}
	}
	if _, listed := got["same.mobileconfig"]; listed {
		t.Error("matching live config must not appear in git-source-of-truth plan")
	}
	if len(got) != len(want) {
		t.Errorf("plan has %d items, want %d: %v", len(got), len(want), got)
	}
}

// TestComputeEmptyBaselineTimestamp: a baseline whose updatedDateTime is empty (a
// write response that omitted it) must NOT be read as an ABM change when the hash
// still matches — otherwise every post-apply sync shows a phantom pull.
func TestComputeEmptyBaselineTimestamp(t *testing.T) {
	desired := map[string][]byte{"x.mobileconfig": []byte("A")}
	base := &state.State{Configs: map[string]state.Entry{
		"x.mobileconfig": {Hash: h("A"), UpdatedDateTime: ""},
	}}
	live := []ab.LiveConfig{{Name: "x.mobileconfig", XML: "A", Updated: "2026-07-04T12:00:00Z"}}
	if items := Compute(desired, base, live).Items; len(items) != 0 {
		t.Errorf("empty baseline timestamp + matching hash must be in-sync, got %v", items)
	}
}

// TestComputeTimestampSerializationTolerant: the same instant serialized two ways
// (Z vs +00:00 with fractional seconds) must not read as a change.
func TestComputeTimestampSerializationTolerant(t *testing.T) {
	desired := map[string][]byte{"x.mobileconfig": []byte("A")}
	base := &state.State{Configs: map[string]state.Entry{
		"x.mobileconfig": {Hash: h("A"), UpdatedDateTime: "2026-07-04T12:00:00Z"},
	}}
	live := []ab.LiveConfig{{Name: "x.mobileconfig", XML: "A", Updated: "2026-07-04T12:00:00.000+00:00"}}
	if items := Compute(desired, base, live).Items; len(items) != 0 {
		t.Errorf("same instant, different serialization must be in-sync, got %v", items)
	}
}

// TestComputeGenuineLiveChangeStillDetected: a real content change is still caught
// via the hash even when the timestamp guard is conservative.
func TestComputeGenuineLiveChangeStillDetected(t *testing.T) {
	desired := map[string][]byte{"x.mobileconfig": []byte("A")}
	base := &state.State{Configs: map[string]state.Entry{
		"x.mobileconfig": {Hash: h("A"), UpdatedDateTime: "2026-07-04T12:00:00Z"},
	}}
	live := []ab.LiveConfig{{Name: "x.mobileconfig", XML: "A2", Updated: "2026-07-05T00:00:00Z"}}
	got := map[string]Action{}
	for _, it := range Compute(desired, base, live).Items {
		got[it.Name] = it.Action
	}
	if got["x.mobileconfig"] != Pull {
		t.Errorf("genuine live content change → %q, want pull", got["x.mobileconfig"])
	}
}
