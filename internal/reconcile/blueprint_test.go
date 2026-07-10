package reconcile

import (
	"strings"
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

// cfgOnly wraps a config name→id map into the per-collection map ComputeBlueprints
// takes (the pre-A5 tests managed configurations only).
func cfgOnly(m map[string]string) map[string]map[string]string {
	return map[string]map[string]string{ab.CollectionConfigurations: m}
}

func TestApplyBlueprintsReportsProgress(t *testing.T) {
	f := newFakes()
	plan := &BlueprintPlan{Items: []BlueprintItem{
		{Blueprint: "Sales", BPID: "bp-sales", Action: Attach, Config: "vpn.mobileconfig", ConfigID: "c-vpn"},
	}}
	var progress []string

	res := engineWith(f).ApplyBlueprints(plan, Opts{
		Progress: func(line string) { progress = append(progress, line) },
	}, 0)

	if res.Errors != 0 || res.Writes != 1 {
		t.Fatalf("apply blueprints = errors %d writes %d, want 0/1", res.Errors, res.Writes)
	}
	if indexOf(progress, "applying blueprint attach-config: Sales / vpn.mobileconfig") < 0 {
		t.Fatalf("missing blueprint apply progress line: %v", progress)
	}
	if indexOf(progress, "attaching configuration to blueprint: Sales / vpn.mobileconfig") < 0 {
		t.Fatalf("missing blueprint attach progress line: %v", progress)
	}
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

	p := ComputeBlueprints(desired, live, cfgOnly(cfgIDByName))

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
	// The reported-only row is BlueprintGone (adopt): since API v2.0 landed,
	// BlueprintNew plans a real CREATE and is no longer reported-only.
	mkPlan := func() *BlueprintPlan {
		return &BlueprintPlan{Items: []BlueprintItem{
			{Blueprint: "Sales", BPID: "bp-sales", Action: Detach, Config: "old.mobileconfig", ConfigID: "c-old"},
			{Blueprint: "Sales", BPID: "bp-sales", Action: Attach, Config: "vpn.mobileconfig", ConfigID: "c-vpn"},
			{Blueprint: "Ghost", BPID: "bp-ghost", Action: BlueprintGone, Detail: "reported"},
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

// TestBlueprintReconcilable checks that reported-only rows and missing-id
// attaches don't count as reconcilable changes (so --exit-on-diff / --apply
// don't act on them), while blueprint-new — a real CREATE since API v2.0 — does.
func TestBlueprintReconcilable(t *testing.T) {
	reported := &BlueprintPlan{Items: []BlueprintItem{
		{Blueprint: "Ghost", Action: BlueprintGone},
		{Blueprint: "Sales", Action: Attach, Config: "new.mobileconfig", ConfigID: ""},
		{Blueprint: "Sales", Action: AttachDevice, Collection: ab.CollectionDevices, Config: "C02NOPE", ConfigID: ""},
	}}
	if reported.HasReconcilableChanges() || reported.ReconcilableCount() != 0 {
		t.Error("reported rows and missing-id attaches must not be reconcilable")
	}
	if !reported.HasChanges() {
		t.Error("HasChanges still counts blocked/reported rows (for display)")
	}
	actionable := &BlueprintPlan{Items: []BlueprintItem{
		{Blueprint: "Sales", Action: Attach, Config: "vpn.mobileconfig", ConfigID: "c-vpn"},
		{Blueprint: "Sales", Action: Detach, Config: "old.mobileconfig", ConfigID: "c-old"},
		{Blueprint: "NewBP", Action: BlueprintNew},
		// An attach targeting a blueprint created this same run (no BPID yet) is
		// actionable — apply resolves the id from the create.
		{Blueprint: "NewBP", Action: AttachUser, Collection: ab.CollectionUsers, Config: "kim@x.co", ConfigID: "u-kim"},
		{Blueprint: "Ghost", Action: BlueprintGone},
	}}
	if !actionable.HasReconcilableChanges() || actionable.ReconcilableCount() != 4 {
		t.Errorf("reconcilable count = %d, want 4 (attach+detach+create+new-bp attach, not the reported row)", actionable.ReconcilableCount())
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

// strs builds the pointer-to-slice a manifest's optional member key decodes to
// (strs() = present-but-empty = manage to zero; a nil field = unmanaged).
func strs(ss ...string) *[]string { return &ss }

// TestComputeBlueprintsAllCollections drives one blueprint managing all six
// collections through the diff: attach for git-only members, detach for
// live-only members, blocked attach for a member the tenant doesn't know, and
// no touch for an in-sync or unresolvable-live member — per collection.
func TestComputeBlueprintsAllCollections(t *testing.T) {
	desired := map[string]gitops.BlueprintSpec{
		"Sales": {
			Name:           "Sales",
			Configurations: []string{"wifi.mobileconfig", "vpn.mobileconfig"},
			Apps:           strs("Keynote", "GhostApp"), // GhostApp not in the tenant → blocked
			Packages:       strs("Tool.pkg"),
			Devices:        strs("C02AAA", "C02BBB"),
			Users:          strs("ann@x.co"),
			Groups:         strs("Eng", "Design"),
		},
	}
	live := []ab.LiveBlueprint{{
		Name: "Sales", ID: "bp-sales",
		Configs:  []string{"wifi.mobileconfig", "old.mobileconfig"},
		Apps:     []string{"Numbers"},
		Packages: []string{"Old.pkg"},
		// raw-device-id-1 didn't resolve to a serial (id passthrough) → never detached
		Devices: []string{"C02BBB", "C02OLD", "raw-device-id-1"},
		Users:   []string{"bob@x.co"},
		Groups:  []string{"Eng", "Legacy"},
	}}
	idByName := map[string]map[string]string{
		ab.CollectionConfigurations: {"wifi.mobileconfig": "c-wifi", "vpn.mobileconfig": "c-vpn", "old.mobileconfig": "c-old"},
		ab.CollectionApps:           {"Keynote": "a-key", "Numbers": "a-num"},
		ab.CollectionPackages:       {"Tool.pkg": "p-tool", "Old.pkg": "p-old"},
		ab.CollectionDevices:        {"C02AAA": "d-aaa", "C02BBB": "d-bbb", "C02OLD": "d-old"},
		ab.CollectionUsers:          {"ann@x.co": "u-ann", "bob@x.co": "u-bob"},
		ab.CollectionGroups:         {"Eng": "g-eng", "Design": "g-des", "Legacy": "g-leg"},
	}

	p := ComputeBlueprints(desired, live, idByName)

	want := []struct {
		member     string
		action     BlueprintAction
		collection string
		id         string
	}{
		{"vpn.mobileconfig", Attach, ab.CollectionConfigurations, "c-vpn"},
		{"old.mobileconfig", Detach, ab.CollectionConfigurations, "c-old"},
		{"Keynote", AttachApp, ab.CollectionApps, "a-key"},
		{"GhostApp", AttachApp, ab.CollectionApps, ""}, // blocked: no tenant id
		{"Numbers", DetachApp, ab.CollectionApps, "a-num"},
		{"Tool.pkg", AttachPackage, ab.CollectionPackages, "p-tool"},
		{"Old.pkg", DetachPackage, ab.CollectionPackages, "p-old"},
		{"C02AAA", AttachDevice, ab.CollectionDevices, "d-aaa"},
		{"C02OLD", DetachDevice, ab.CollectionDevices, "d-old"},
		{"ann@x.co", AttachUser, ab.CollectionUsers, "u-ann"},
		{"bob@x.co", DetachUser, ab.CollectionUsers, "u-bob"},
		{"Design", AttachGroup, ab.CollectionGroups, "g-des"},
		{"Legacy", DetachGroup, ab.CollectionGroups, "g-leg"},
	}
	for _, w := range want {
		it, ok := bpItem(p, "Sales", w.member)
		if !ok || it.Action != w.action || it.Collection != w.collection || it.ConfigID != w.id || it.BPID != "bp-sales" {
			t.Errorf("Sales/%s = %+v (ok=%v), want action=%s collection=%s id=%q", w.member, it, ok, w.action, w.collection, w.id)
		}
	}
	// In-sync members (per collection) and the unresolvable live device produce no items.
	for _, absent := range []string{"wifi.mobileconfig", "C02BBB", "Eng", "raw-device-id-1"} {
		if it, ok := bpItem(p, "Sales", absent); ok {
			t.Errorf("Sales/%s must not appear in the plan, got %+v", absent, it)
		}
	}
	if len(p.Items) != len(want) {
		t.Errorf("plan has %d items, want %d: %+v", len(p.Items), len(want), p.Items)
	}
}

// TestComputeBlueprintsAmbiguousNames pins the ambiguity sentinel: a display
// name shared by more than one tenant resource resolves to "" in idByName, so
// its attach is BLOCKED (never a write against an arbitrary duplicate) with an
// ambiguity-specific detail, and a live-only occurrence is never planned for
// detach (whose id could belong to the other duplicate).
func TestComputeBlueprintsAmbiguousNames(t *testing.T) {
	desired := map[string]gitops.BlueprintSpec{
		"Sales": {
			Name:  "Sales",
			Apps:  strs("Keynote"), // "Keynote" exists twice in the tenant
			Users: strs(),          // managed to zero — the live dup below is the prune candidate
		},
	}
	live := []ab.LiveBlueprint{{
		Name: "Sales", ID: "bp-sales",
		Apps:  []string{},
		Users: []string{"dup@x.co"}, // shared address, live-only
	}}
	idByName := map[string]map[string]string{
		ab.CollectionApps:  {"Keynote": ""}, // ambiguous sentinel (invertMemberMaps)
		ab.CollectionUsers: {"dup@x.co": ""},
	}

	p := ComputeBlueprints(desired, live, idByName)

	it, ok := bpItem(p, "Sales", "Keynote")
	if !ok || it.Action != AttachApp || it.ConfigID != "" || it.IsActionable() {
		t.Fatalf("ambiguous attach = %+v (ok=%v), want blocked attach-app", it, ok)
	}
	if !strings.Contains(it.Detail, "ambiguous") {
		t.Errorf("ambiguous attach detail = %q, want it to say the name is ambiguous", it.Detail)
	}
	if it, ok := bpItem(p, "Sales", "dup@x.co"); ok {
		t.Errorf("ambiguous live-only member must never be planned for detach, got %+v", it)
	}
	if p.HasReconcilableChanges() {
		t.Error("a plan of only ambiguous rows must not be reconcilable (--exit-on-diff must converge)")
	}
}

// TestComputeBlueprintsUnmanagedVsEmpty pins the pointer-slice contract at the
// plan level: a nil key (unmanaged) never yields an item even when live has
// members, while a present-but-empty key manages the collection to zero.
func TestComputeBlueprintsUnmanagedVsEmpty(t *testing.T) {
	desired := map[string]gitops.BlueprintSpec{
		"Sales": {
			Name:           "Sales",
			Configurations: []string{"wifi.mobileconfig"},
			// Apps/Packages/Devices/Groups nil → UNMANAGED
			Users: strs(), // present-but-empty → manage to zero
		},
	}
	live := []ab.LiveBlueprint{{
		Name: "Sales", ID: "bp-sales",
		Configs: []string{"wifi.mobileconfig"},
		Apps:    []string{"Numbers"},
		Devices: []string{"C02OLD"},
		Users:   []string{"bob@x.co"},
	}}
	idByName := map[string]map[string]string{
		ab.CollectionConfigurations: {"wifi.mobileconfig": "c-wifi"},
		ab.CollectionApps:           {"Numbers": "a-num"},
		ab.CollectionDevices:        {"C02OLD": "d-old"},
		ab.CollectionUsers:          {"bob@x.co": "u-bob"},
	}

	p := ComputeBlueprints(desired, live, idByName)

	if it, ok := bpItem(p, "Sales", "Numbers"); ok {
		t.Errorf("unmanaged apps key must never plan a detach, got %+v", it)
	}
	if it, ok := bpItem(p, "Sales", "C02OLD"); ok {
		t.Errorf("unmanaged devices key must never plan a detach, got %+v", it)
	}
	it, ok := bpItem(p, "Sales", "bob@x.co")
	if !ok || it.Action != DetachUser || it.ConfigID != "u-bob" {
		t.Errorf("users: [] must manage to zero (detach bob) = %+v (ok=%v)", it, ok)
	}
	if len(p.Items) != 1 {
		t.Errorf("plan = %+v, want exactly the one user detach", p.Items)
	}
}

// TestComputeBlueprintsCreatePath: a git-only blueprint plans a real CREATE
// (carrying the manifest description) followed by its member attaches, which
// have no BPID yet (apply resolves it from the create).
func TestComputeBlueprintsCreatePath(t *testing.T) {
	desired := map[string]gitops.BlueprintSpec{
		"NewBP": {
			Name:           "NewBP",
			Description:    "fresh from git",
			Configurations: []string{"wifi.mobileconfig"},
			Devices:        strs("C02AAA"),
			Apps:           strs("GhostApp"), // unknown in the tenant → blocked attach
		},
	}
	idByName := map[string]map[string]string{
		ab.CollectionConfigurations: {"wifi.mobileconfig": "c-wifi"},
		ab.CollectionDevices:        {"C02AAA": "d-aaa"},
		ab.CollectionApps:           {},
	}

	p := ComputeBlueprints(desired, nil, idByName)

	create, ok := bpItem(p, "NewBP", "")
	if !ok || create.Action != BlueprintNew || create.Description != "fresh from git" || create.BPID != "" {
		t.Fatalf("create item = %+v (ok=%v)", create, ok)
	}
	if !create.IsActionable() {
		t.Error("blueprint-new must be actionable (a real CREATE since API v2.0)")
	}
	if it, ok := bpItem(p, "NewBP", "wifi.mobileconfig"); !ok || it.Action != Attach || it.ConfigID != "c-wifi" || it.BPID != "" || !it.IsActionable() {
		t.Errorf("NewBP/wifi attach = %+v (ok=%v), want actionable attach with empty BPID", it, ok)
	}
	if it, ok := bpItem(p, "NewBP", "C02AAA"); !ok || it.Action != AttachDevice || it.ConfigID != "d-aaa" || it.IsActionable() != true {
		t.Errorf("NewBP/C02AAA attach = %+v (ok=%v)", it, ok)
	}
	if it, ok := bpItem(p, "NewBP", "GhostApp"); !ok || it.Action != AttachApp || it.ConfigID != "" || it.IsActionable() {
		t.Errorf("NewBP/GhostApp blocked attach = %+v (ok=%v)", it, ok)
	}
}

// TestApplyBlueprintsCreateThenAttach: the create runs FIRST, its fresh id feeds
// the attaches (per collection, on the right API relationship), and all three
// consume the shared write budget.
func TestApplyBlueprintsCreateThenAttach(t *testing.T) {
	mkPlan := func() *BlueprintPlan {
		return &BlueprintPlan{Items: []BlueprintItem{
			{Blueprint: "NewBP", Action: AttachDevice, Collection: ab.CollectionDevices, Config: "C02AAA", ConfigID: "d-aaa"},
			{Blueprint: "NewBP", Action: Attach, Collection: ab.CollectionConfigurations, Config: "wifi.mobileconfig", ConfigID: "c-wifi"},
			{Blueprint: "NewBP", Action: BlueprintNew, Description: "fresh from git"},
		}}
	}

	f := newFakes()
	res := engineWith(f).ApplyBlueprints(mkPlan(), Opts{}, 0)
	if res.Errors != 0 || res.Writes != 3 || res.Skipped != 0 {
		t.Fatalf("create-then-attach = errors %d writes %d skipped %d, want 0/3/0: %+v", res.Errors, res.Writes, res.Skipped, res.Outcomes)
	}
	create := indexOf(f.events, "createbp:NewBP:fresh from git")
	aCfg := indexOf(f.events, "attach:bp-NewBP:c-wifi")
	aDev := indexOf(f.events, "attach:bp-NewBP:d-aaa")
	if create < 0 || aCfg < 0 || aDev < 0 || create > aCfg || create > aDev {
		t.Errorf("create must precede the attaches it feeds: %v", f.events)
	}
	if indexOf(f.relOps, "POST:configurations:configurations") < 0 || indexOf(f.relOps, "POST:orgDevices:orgDevices") < 0 {
		t.Errorf("attaches must hit the collection's relationship: %v", f.relOps)
	}

	// --limit-writes is shared: with a budget of 1 only the create runs, and the
	// attaches skip benignly (budget for the config one, no-id for none).
	f = newFakes()
	res = engineWith(f).ApplyBlueprints(mkPlan(), Opts{LimitWrites: 1}, 0)
	if res.Writes != 1 || res.Skipped != 2 || res.Errors != 0 {
		t.Errorf("budget=1 → writes=%d skipped=%d errors=%d, want 1/2/0", res.Writes, res.Skipped, res.Errors)
	}
	if indexOf(f.events, "createbp:NewBP:fresh from git") != 0 || len(f.events) != 1 {
		t.Errorf("budget=1 must spend the only write on the create: %v", f.events)
	}

	// Budget already exhausted by phase 1 → the create skips, and the attaches
	// skip too (their blueprint has no id) — nothing touches the tenant.
	f = newFakes()
	res = engineWith(f).ApplyBlueprints(mkPlan(), Opts{LimitWrites: 2}, 2)
	if res.Writes != 0 || res.Skipped != 3 || res.Errors != 0 {
		t.Errorf("exhausted budget → writes=%d skipped=%d errors=%d, want 0/3/0", res.Writes, res.Skipped, res.Errors)
	}
	if len(f.events) != 0 {
		t.Errorf("no tenant call expected when the budget is spent: %v", f.events)
	}
}

// TestApplyBlueprintsCreateFailureSkipsAttaches: a failed CREATE is one error;
// the attaches that depended on its id skip benignly (resumable next run).
func TestApplyBlueprintsCreateFailureSkipsAttaches(t *testing.T) {
	f := newFakes()
	f.bpCreateErr = true
	plan := &BlueprintPlan{Items: []BlueprintItem{
		{Blueprint: "NewBP", Action: BlueprintNew, Description: "d"},
		{Blueprint: "NewBP", Action: Attach, Collection: ab.CollectionConfigurations, Config: "wifi.mobileconfig", ConfigID: "c-wifi"},
		{Blueprint: "NewBP", Action: AttachUser, Collection: ab.CollectionUsers, Config: "ann@x.co", ConfigID: "u-ann"},
	}}
	res := engineWith(f).ApplyBlueprints(plan, Opts{}, 0)
	if res.Errors != 1 || res.Skipped != 2 || res.Writes != 0 {
		t.Errorf("create failure → errors=%d skipped=%d writes=%d, want 1/2/0: %+v", res.Errors, res.Skipped, res.Writes, res.Outcomes)
	}
	if len(f.events) != 0 {
		t.Errorf("no membership call may run when the create failed: %v", f.events)
	}
}

// TestApplyBlueprintsPerCollectionPruneGate: detaches in every collection honor
// the --prune gate, and with prune on each hits its own API relationship.
func TestApplyBlueprintsPerCollectionPruneGate(t *testing.T) {
	mkPlan := func() *BlueprintPlan {
		return &BlueprintPlan{Items: []BlueprintItem{
			{Blueprint: "Sales", BPID: "bp-sales", Action: DetachApp, Collection: ab.CollectionApps, Config: "Numbers", ConfigID: "a-num"},
			{Blueprint: "Sales", BPID: "bp-sales", Action: DetachPackage, Collection: ab.CollectionPackages, Config: "Tool.pkg", ConfigID: "p-tool"},
			{Blueprint: "Sales", BPID: "bp-sales", Action: DetachDevice, Collection: ab.CollectionDevices, Config: "C02OLD", ConfigID: "d-old"},
			{Blueprint: "Sales", BPID: "bp-sales", Action: DetachUser, Collection: ab.CollectionUsers, Config: "bob@x.co", ConfigID: "u-bob"},
			{Blueprint: "Sales", BPID: "bp-sales", Action: DetachGroup, Collection: ab.CollectionGroups, Config: "Eng", ConfigID: "g-eng"},
		}}
	}

	f := newFakes()
	res := engineWith(f).ApplyBlueprints(mkPlan(), Opts{}, 0)
	if res.Writes != 0 || res.Skipped != 5 || len(f.events) != 0 {
		t.Errorf("prune off → writes=%d skipped=%d events=%v, want 0/5/none", res.Writes, res.Skipped, f.events)
	}

	f = newFakes()
	res = engineWith(f).ApplyBlueprints(mkPlan(), Opts{Prune: true}, 0)
	if res.Writes != 5 || res.Errors != 0 {
		t.Fatalf("prune on → writes=%d errors=%d, want 5/0: %+v", res.Writes, res.Errors, res.Outcomes)
	}
	for _, rel := range []string{"apps", "packages", "orgDevices", "users", "userGroups"} {
		if indexOf(f.relOps, "DELETE:"+rel+":"+rel) < 0 {
			t.Errorf("missing DELETE on relationship %s: %v", rel, f.relOps)
		}
	}
}

// TestApplyBlueprintsLegacyItemDefaultsToConfigurations: an item with no
// Collection (pre-A5 plan shape) still targets the configurations relationship.
func TestApplyBlueprintsLegacyItemDefaultsToConfigurations(t *testing.T) {
	f := newFakes()
	plan := &BlueprintPlan{Items: []BlueprintItem{
		{Blueprint: "Sales", BPID: "bp-sales", Action: Attach, Config: "vpn.mobileconfig", ConfigID: "c-vpn"},
	}}
	res := engineWith(f).ApplyBlueprints(plan, Opts{}, 0)
	if res.Writes != 1 || res.Errors != 0 {
		t.Fatalf("legacy attach → writes=%d errors=%d, want 1/0", res.Writes, res.Errors)
	}
	if indexOf(f.relOps, "POST:configurations:configurations") != 0 {
		t.Errorf("legacy item must default to the configurations relationship: %v", f.relOps)
	}
}
