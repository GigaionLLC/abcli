package reconcile

import (
	"testing"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/gitops"
)

// bpItem finds the plan item for a (blueprint, config) pair.
func bpItem(p *BlueprintPlan, bp, cfg string) (BlueprintItem, bool) {
	for _, it := range p.Items {
		if it.Blueprint == bp && it.Config == cfg {
			return it, true
		}
	}
	return BlueprintItem{}, false
}

// bpOutcome finds the outcome for a (blueprint, config) pair.
func bpOutcome(res *BlueprintResult, bp, cfg string) (BlueprintOutcome, bool) {
	for _, o := range res.Outcomes {
		if o.Blueprint == bp && o.Config == cfg {
			return o, true
		}
	}
	return BlueprintOutcome{}, false
}

func TestComputeBlueprints(t *testing.T) {
	desired := map[string]gitops.BlueprintSpec{
		"Sales": {Name: "Sales", Configurations: []string{"wifi.mobileconfig", "vpn.mobileconfig", "new.mobileconfig"}},
		"NewBP": {Name: "NewBP", Configurations: []string{"wifi.mobileconfig"}},
	}
	live := []ab.LiveBlueprint{
		// wifi in-sync; old must detach; native-id-999 is unmanaged (must NOT detach)
		{Name: "Sales", ID: "bp-sales", Configs: []string{"wifi.mobileconfig", "old.mobileconfig", "native-id-999"}},
		{Name: "Ghost", ID: "bp-ghost", Configs: []string{}},
	}
	cfgIDByName := map[string]string{
		"wifi.mobileconfig": "c-wifi",
		"vpn.mobileconfig":  "c-vpn",
		"old.mobileconfig":  "c-old",
		// "new.mobileconfig" intentionally absent — not yet created in ABM
	}

	p := ComputeBlueprints(desired, live, cfgIDByName)

	// Sales: attach vpn (known id), attach new (unknown id → empty), detach old.
	if it, ok := bpItem(p, "Sales", "vpn.mobileconfig"); !ok || it.Action != Attach || it.ConfigID != "c-vpn" || it.BPID != "bp-sales" {
		t.Errorf("Sales/vpn attach = %+v (ok=%v)", it, ok)
	}
	if it, ok := bpItem(p, "Sales", "new.mobileconfig"); !ok || it.Action != Attach || it.ConfigID != "" {
		t.Errorf("Sales/new attach (not-yet-in-ABM) = %+v (ok=%v)", it, ok)
	}
	if it, ok := bpItem(p, "Sales", "old.mobileconfig"); !ok || it.Action != Detach || it.ConfigID != "c-old" {
		t.Errorf("Sales/old detach = %+v (ok=%v)", it, ok)
	}
	// wifi is in-sync → no item.
	if _, ok := bpItem(p, "Sales", "wifi.mobileconfig"); ok {
		t.Error("wifi is in-sync and must not appear in the plan")
	}
	// native-id-999 is unmanaged → must NOT be a detach.
	if _, ok := bpItem(p, "Sales", "native-id-999"); ok {
		t.Error("an unmanaged (non-CUSTOM_SETTING) config must never be detached")
	}
	// NewBP in git only → BlueprintNew (reported). Ghost in ABM only → BlueprintGone.
	if it, ok := bpItem(p, "NewBP", ""); !ok || it.Action != BlueprintNew {
		t.Errorf("NewBP = %+v (ok=%v)", it, ok)
	}
	if it, ok := bpItem(p, "Ghost", ""); !ok || it.Action != BlueprintGone {
		t.Errorf("Ghost = %+v (ok=%v)", it, ok)
	}
}

func TestApplyBlueprintsPruneGate(t *testing.T) {
	mkPlan := func() *BlueprintPlan {
		return &BlueprintPlan{Items: []BlueprintItem{
			{Blueprint: "Sales", BPID: "bp-sales", Action: Detach, Config: "old.mobileconfig", ConfigID: "c-old"},
			{Blueprint: "Sales", BPID: "bp-sales", Action: Attach, Config: "vpn.mobileconfig", ConfigID: "c-vpn"},
			{Blueprint: "NewBP", Action: BlueprintNew, Detail: "reported"},
		}}
	}

	// prune off → attach happens, detach skipped, reported skipped.
	f := newFakes()
	res := engineWith(f).ApplyBlueprints(mkPlan(), Opts{}, 0)
	if res.Writes != 1 {
		t.Errorf("prune-off writes = %d, want 1 (attach only)", res.Writes)
	}
	if o, _ := bpOutcome(res, "Sales", "vpn.mobileconfig"); o.Status != "done" {
		t.Errorf("attach status = %q, want done", o.Status)
	}
	if o, _ := bpOutcome(res, "Sales", "old.mobileconfig"); o.Status != "skipped" {
		t.Errorf("detach (prune off) status = %q, want skipped", o.Status)
	}
	if indexOf(f.events, "detach:bp-sales:c-old") >= 0 {
		t.Error("detach must not run with prune off")
	}

	// prune on → both, attach ordered before detach.
	f = newFakes()
	res = engineWith(f).ApplyBlueprints(mkPlan(), Opts{Prune: true}, 0)
	if res.Writes != 2 {
		t.Errorf("prune-on writes = %d, want 2", res.Writes)
	}
	if a, d := indexOf(f.events, "attach:bp-sales:c-vpn"), indexOf(f.events, "detach:bp-sales:c-old"); a < 0 || d < 0 || a > d {
		t.Errorf("attach must precede detach: %v", f.events)
	}
}

func TestApplyBlueprintsLimitWritesSharesBudget(t *testing.T) {
	// priorWrites=2 already spent this run; LimitWrites=2 → no blueprint write allowed.
	f := newFakes()
	plan := &BlueprintPlan{Items: []BlueprintItem{
		{Blueprint: "Sales", BPID: "bp-sales", Action: Attach, Config: "vpn.mobileconfig", ConfigID: "c-vpn"},
	}}
	res := engineWith(f).ApplyBlueprints(plan, Opts{LimitWrites: 2}, 2)
	if res.Writes != 0 || res.Skipped != 1 {
		t.Errorf("shared budget: writes=%d skipped=%d, want 0/1", res.Writes, res.Skipped)
	}
	if len(f.events) != 0 {
		t.Errorf("no tenant call expected when budget already spent: %v", f.events)
	}
}

// TestApplyBlueprintsAttachMissingConfigID: a config not yet in ABM (empty id —
// brand-new, throttled, or dangling) is a benign SKIP, not an error that aborts.
func TestApplyBlueprintsAttachMissingConfigID(t *testing.T) {
	f := newFakes()
	plan := &BlueprintPlan{Items: []BlueprintItem{
		{Blueprint: "Sales", BPID: "bp-sales", Action: Attach, Config: "new.mobileconfig", ConfigID: ""},
	}}
	res := engineWith(f).ApplyBlueprints(plan, Opts{}, 0)
	if res.Errors != 0 || res.Skipped != 1 || res.Writes != 0 {
		t.Errorf("attach with no config id → errors=%d skipped=%d writes=%d, want 0/1/0", res.Errors, res.Skipped, res.Writes)
	}
	if len(f.events) != 0 {
		t.Error("no tenant call when the config id is unknown")
	}
}

// TestBlueprintReconcilable checks that reported-only advisories don't count as
// reconcilable changes (so --exit-on-diff / --apply don't act on them).
func TestBlueprintReconcilable(t *testing.T) {
	reported := &BlueprintPlan{Items: []BlueprintItem{
		{Blueprint: "NewBP", Action: BlueprintNew},
		{Blueprint: "Ghost", Action: BlueprintGone},
	}}
	if reported.HasReconcilableChanges() || reported.ReconcilableCount() != 0 {
		t.Error("reported-only advisories must not be reconcilable")
	}
	if !reported.HasChanges() {
		t.Error("HasChanges still counts advisories (for display)")
	}
	actionable := &BlueprintPlan{Items: []BlueprintItem{
		{Blueprint: "Sales", Action: Attach, Config: "vpn.mobileconfig", ConfigID: "c-vpn"},
		{Blueprint: "Sales", Action: Detach, Config: "old.mobileconfig", ConfigID: "c-old"},
		{Blueprint: "Ghost", Action: BlueprintGone},
	}}
	if !actionable.HasReconcilableChanges() || actionable.ReconcilableCount() != 2 {
		t.Errorf("reconcilable count = %d, want 2 (attach+detach, not the advisory)", actionable.ReconcilableCount())
	}
}

func TestApplyBlueprintsAttachError(t *testing.T) {
	f := newFakes()
	f.bpAddErr = true
	plan := &BlueprintPlan{Items: []BlueprintItem{
		{Blueprint: "Sales", BPID: "bp-sales", Action: Attach, Config: "vpn.mobileconfig", ConfigID: "c-vpn"},
	}}
	res := engineWith(f).ApplyBlueprints(plan, Opts{}, 0)
	if res.Errors != 1 || res.Writes != 0 {
		t.Errorf("attach error → errors=%d writes=%d, want 1/0", res.Errors, res.Writes)
	}
}
