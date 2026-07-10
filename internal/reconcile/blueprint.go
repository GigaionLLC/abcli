package reconcile

import (
	"sort"
	"strings"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/gitops"
)

// Blueprint reconcile is git-authoritative for a blueprint's member collections:
// members listed in the git manifest are attached; members attached in ABM but
// absent from git are detached (gated behind --prune). Configurations are always
// managed and only ever touch CUSTOM_SETTING configs abctl owns — a
// native/console-only config attached in ABM is never detached. The other five
// collections (apps/packages/devices/users/groups) are managed only when their
// manifest key is present (see gitops.BlueprintSpec), and a live member that
// doesn't resolve to an addressable name is likewise never touched. A blueprint
// that exists only in git is CREATED (Apple Business API v2.0, 2026-04-14) and
// its members attached; GitOps never deletes a blueprint — an ABM-only blueprint
// is reported for adoption, and deletion stays imperative-only.

// BlueprintAction is the reconcile verb for a blueprint or one of its members.
type BlueprintAction string

// Blueprint reconcile actions. Attach/detach verbs are collection-qualified;
// the configurations pair keeps its original values ("attach-config" /
// "detach-config") so existing JSON consumers are unaffected.
const (
	Attach        BlueprintAction = "attach-config" // member in git, not in ABM → POST membership (per collection below)
	Detach        BlueprintAction = "detach-config" // member in ABM, not in git → DELETE membership (gated --prune)
	AttachApp     BlueprintAction = "attach-app"
	DetachApp     BlueprintAction = "detach-app"
	AttachPackage BlueprintAction = "attach-package"
	DetachPackage BlueprintAction = "detach-package"
	AttachDevice  BlueprintAction = "attach-device"
	DetachDevice  BlueprintAction = "detach-device"
	AttachUser    BlueprintAction = "attach-user"
	DetachUser    BlueprintAction = "detach-user"
	AttachGroup   BlueprintAction = "attach-group"
	DetachGroup   BlueprintAction = "detach-group"
	BlueprintNew  BlueprintAction = "blueprint-new"   // blueprint in git, not in ABM → POST blueprints, then attach members
	BlueprintGone BlueprintAction = "blueprint-adopt" // blueprint in ABM, not in git → run seed to adopt (reported)
)

// IsAttach / IsDetach classify a membership verb regardless of collection.
func (a BlueprintAction) IsAttach() bool { return strings.HasPrefix(string(a), "attach-") }

// IsDetach reports whether the action is a membership detach (any collection).
func (a BlueprintAction) IsDetach() bool { return strings.HasPrefix(string(a), "detach-") }

// attachActionByCollection / detachActionByCollection pick the verb for a
// manifest collection key (ab.Collection*).
var attachActionByCollection = map[string]BlueprintAction{
	ab.CollectionConfigurations: Attach,
	ab.CollectionApps:           AttachApp,
	ab.CollectionPackages:       AttachPackage,
	ab.CollectionDevices:        AttachDevice,
	ab.CollectionUsers:          AttachUser,
	ab.CollectionGroups:         AttachGroup,
}

var detachActionByCollection = map[string]BlueprintAction{
	ab.CollectionConfigurations: Detach,
	ab.CollectionApps:           DetachApp,
	ab.CollectionPackages:       DetachPackage,
	ab.CollectionDevices:        DetachDevice,
	ab.CollectionUsers:          DetachUser,
	ab.CollectionGroups:         DetachGroup,
}

// bpNouns is the per-collection wording: short is used in plan details
// ("config in git…"), long in apply progress ("attaching configuration…").
// The empty key covers legacy items that predate the Collection field.
var bpNouns = map[string]struct{ short, long string }{
	"":                          {"config", "configuration"},
	ab.CollectionConfigurations: {"config", "configuration"},
	ab.CollectionApps:           {"app", "app"},
	ab.CollectionPackages:       {"package", "package"},
	ab.CollectionDevices:        {"device", "device"},
	ab.CollectionUsers:          {"user", "user"},
	ab.CollectionGroups:         {"user group", "user group"},
}

// ambiguousDetail explains a member name shared by more than one tenant
// resource: resolving it would pick an id nondeterministically (the imperative
// resolvers error on the same ambiguity), so the row stays blocked instead.
func ambiguousDetail(collection string) string {
	return "blocked: " + bpNouns[collection].short + " name is ambiguous (shared by multiple resources in the organization) — rename the duplicates, or manage this member imperatively via `abctl attach`/`detach` by id"
}

// blockedDetail explains an attach with no resolvable member id, per collection.
// Configs can be created by the config phase; the other collections cannot, so
// the remedy differs.
func blockedDetail(collection string) string {
	switch collection {
	case "", ab.CollectionConfigurations:
		return "blocked: config is listed on this blueprint but has no ABM id; create/sync the config first, or remove it from the blueprint manifest if obsolete"
	case ab.CollectionDevices:
		return "blocked: device is listed on this blueprint but was not found in the organization (by serial number); fix the manifest, or remove it if obsolete"
	case ab.CollectionUsers:
		return "blocked: user is listed on this blueprint but was not found in the organization (by email/managed Apple Account); fix the manifest, or remove it if obsolete"
	default:
		return "blocked: " + bpNouns[collection].short + " is listed on this blueprint but was not found in the organization (by name); fix the manifest, or remove it if obsolete"
	}
}

// BlueprintItem is one planned blueprint change.
type BlueprintItem struct {
	Blueprint  string          `json:"blueprint"`
	BPID       string          `json:"bp_id,omitempty"` // empty for a git-only blueprint (filled by the create at apply time)
	Action     BlueprintAction `json:"action"`
	Collection string          `json:"collection,omitempty"` // member collection key (ab.Collection*); empty on blueprint-level rows and legacy items (= configurations)
	// Config / ConfigID carry the MEMBER display name and ABM id for every
	// collection — the JSON keys predate non-config membership and are kept
	// stable for existing consumers (abgui decodes them).
	Config      string `json:"config,omitempty"`
	ConfigID    string `json:"config_id,omitempty"`
	Description string `json:"description,omitempty"` // blueprint-new: the manifest description the create sends
	Detail      string `json:"detail"`
}

// BlueprintPlan is the ordered set of planned blueprint changes.
type BlueprintPlan struct {
	Items []BlueprintItem `json:"items"`
}

// HasChanges reports whether the plan contains any items (actionable or reported).
func (p *BlueprintPlan) HasChanges() bool { return len(p.Items) > 0 }

// IsActionable reports whether sync can perform this item in the current run.
// blueprint-new is a real CREATE (API v2.0). An attach needs a resolved member
// id — an empty id means the row is blocked until the member exists in ABM (a
// config not yet created/adopted, or a member name the tenant doesn't know).
func (it BlueprintItem) IsActionable() bool {
	return it.Action == BlueprintNew || it.Action.IsDetach() || (it.Action.IsAttach() && it.ConfigID != "")
}

// HasReconcilableChanges reports whether the plan has drift that sync can act on.
// Reported-only rows and attach rows without a member id are excluded, so
// --exit-on-diff does not loop forever and --apply does not confirm then skip.
func (p *BlueprintPlan) HasReconcilableChanges() bool {
	for _, it := range p.Items {
		if it.IsActionable() {
			return true
		}
	}
	return false
}

// ReconcilableCount is the number of items apply can perform (for a confirm prompt).
func (p *BlueprintPlan) ReconcilableCount() int {
	n := 0
	for _, it := range p.Items {
		if it.IsActionable() {
			n++
		}
	}
	return n
}

// ComputeBlueprints diffs the git blueprint manifests against live ABM
// blueprints, per managed member collection. idByName maps collection key →
// member display name → ABM id; for configurations it is built from the sync
// baseline (or the post-apply baseline, so freshly-created configs resolve) — an
// ownership gate, not a full-tenant list. A blueprint is matched by name across
// git and ABM; a git-only blueprint plans a CREATE followed by its member
// attaches, and an ABM-only blueprint is reported for adoption (never deleted).
func ComputeBlueprints(desired map[string]gitops.BlueprintSpec, live []ab.LiveBlueprint, idByName map[string]map[string]string) *BlueprintPlan {
	liveByName := make(map[string]ab.LiveBlueprint, len(live))
	for _, l := range live {
		liveByName[l.Name] = l
	}
	names := map[string]struct{}{}
	for n := range desired {
		names[n] = struct{}{}
	}
	for n := range liveByName {
		names[n] = struct{}{}
	}
	ordered := make([]string, 0, len(names))
	for n := range names {
		ordered = append(ordered, n)
	}
	sort.Strings(ordered)

	p := &BlueprintPlan{Items: []BlueprintItem{}}
	for _, n := range ordered {
		d, hasD := desired[n]
		l, hasL := liveByName[n]
		switch {
		case hasD && hasL:
			p.diffMembership(n, l.ID, d, &l, idByName)
		case hasD && !hasL:
			p.Items = append(p.Items, BlueprintItem{Blueprint: n, Action: BlueprintNew, Description: d.Description,
				Detail: "in git, not in ABM → create blueprint (membership attaches follow)"})
			p.diffMembership(n, "", d, nil, idByName) // no live side → attach-only, against the id the create yields
		case !hasD && hasL:
			p.Items = append(p.Items, BlueprintItem{Blueprint: n, BPID: l.ID, Action: BlueprintGone,
				Detail: "in ABM, not in git — run `abctl seed` to adopt it (or add a manifest)"})
		}
	}
	return p
}

// diffMembership plans the attach/detach items for one blueprint across every
// collection the manifest manages (an unmanaged collection is never touched —
// its live membership is not even fetched). live == nil means the blueprint
// doesn't exist in ABM yet (blueprint-new), so only attaches are planned.
func (p *BlueprintPlan) diffMembership(bp, bpID string, d gitops.BlueprintSpec, live *ab.LiveBlueprint, idByName map[string]map[string]string) {
	for _, col := range ab.BlueprintCollections {
		gitNames, managed := d.Members(col)
		if !managed {
			continue
		}
		var liveNames []string
		if live != nil {
			liveNames = live.Members(col)
		}
		ids := idByName[col]
		noun := bpNouns[col].short
		gitSet, liveSet := toSet(gitNames), toSet(liveNames)
		for _, m := range sortedKeys(gitSet) { // attach: in git, not in ABM
			if _, in := liveSet[m]; in {
				continue
			}
			id, known := ids[m]
			it := BlueprintItem{Blueprint: bp, BPID: bpID, Action: attachActionByCollection[col],
				Collection: col, Config: m, ConfigID: id}
			switch {
			case known && id == "": // name shared by >1 tenant resource — blocked, never guessed
				it.Detail = ambiguousDetail(col)
			case id == "":
				it.Detail = blockedDetail(col)
			default:
				it.Detail = noun + " in git, not attached in ABM → attach"
			}
			p.Items = append(p.Items, it)
		}
		for _, m := range sortedKeys(liveSet) { // detach: in ABM, not in git
			if _, in := gitSet[m]; in {
				continue
			}
			id, known := ids[m]
			if !known || id == "" {
				// The live member has no UNIQUE addressable name here (configs: not a
				// baseline-managed CUSTOM_SETTING, e.g. native/console-only; others: an
				// id that didn't resolve to a tenant resource, or a name shared by >1
				// resource — detaching by that name could remove the wrong duplicate)
				// — never touch it.
				continue
			}
			p.Items = append(p.Items, BlueprintItem{Blueprint: bp, BPID: bpID, Action: detachActionByCollection[col],
				Collection: col, Config: m, ConfigID: id,
				Detail: noun + " attached in ABM, not in git → detach (gated --prune)"})
		}
	}
}

// BlueprintOutcome records what happened to one planned blueprint item.
type BlueprintOutcome struct {
	Blueprint string          `json:"blueprint"`
	Config    string          `json:"config,omitempty"`
	Action    BlueprintAction `json:"action"`
	Status    string          `json:"status"` // "done" | "skipped" | "error"
	Detail    string          `json:"detail"`
}

// BlueprintResult summarizes a blueprint apply run.
type BlueprintResult struct {
	Outcomes []BlueprintOutcome `json:"outcomes"`
	Writes   int                `json:"writes"`
	Errors   int                `json:"errors"`
	Skipped  int                `json:"skipped"`
}

// bpRank orders execution: creates first (attaches need the fresh blueprint id),
// then attach before detach; reported items last.
func bpRank(a BlueprintAction) int {
	switch {
	case a == BlueprintNew:
		return 0
	case a.IsAttach():
		return 1
	case a.IsDetach():
		return 2
	default: // BlueprintGone — reported, not applied
		return 3
	}
}

// ApplyBlueprints executes the blueprint plan: create git-only blueprints, then
// attach (always) and detach (only with --prune) members via per-member
// POST/DELETE (the relationship is additive/merges, so this converges). An
// attach whose blueprint was created this run resolves its id from that create;
// if the create failed or was skipped, the attach skips benignly. priorWrites is
// the tenant writes already spent this run (e.g. by config apply) so
// --limit-writes is a single shared budget. Reported-only items (adopt) are
// surfaced as skips.
func (e *Engine) ApplyBlueprints(p *BlueprintPlan, opts Opts, priorWrites int) *BlueprintResult {
	items := append([]BlueprintItem(nil), p.Items...)
	sort.SliceStable(items, func(i, j int) bool {
		if ri, rj := bpRank(items[i].Action), bpRank(items[j].Action); ri != rj {
			return ri < rj
		}
		return items[i].Blueprint < items[j].Blueprint
	})

	res := &BlueprintResult{Outcomes: []BlueprintOutcome{}}
	createdIDs := map[string]string{} // blueprint name → id created this run
	for _, it := range items {
		target := it.Blueprint
		if it.Config != "" {
			target += " / " + it.Config
		}
		noun := bpNouns[it.Collection] // .short in details, .long in progress lines
		progress(opts, "applying blueprint "+string(it.Action)+": "+target)
		switch {
		case it.Action == BlueprintNew:
			if !e.budget(opts, priorWrites+res.Writes) {
				e.bpSkip(res, it, "skipped: --limit-writes reached")
				continue
			}
			progress(opts, "creating blueprint in ABM: "+it.Blueprint)
			r, err := e.Client.CreateBlueprint(it.Blueprint, it.Description)
			if err != nil {
				e.bpFail(res, it, "create blueprint failed: "+err.Error())
				continue
			}
			res.Writes++
			createdIDs[it.Blueprint] = r.ID
			e.bpDone(res, it, "created blueprint on ABM (id "+r.ID+")")
		case it.Action.IsAttach():
			if it.ConfigID == "" {
				// The member isn't addressable in ABM yet (a config that is brand-new in
				// git, throttled by --limit-writes in phase 1, or a dangling manifest
				// reference). This is a benign, resumable state — a skip, not an error
				// that aborts.
				e.bpSkip(res, it, "skipped: "+noun.short+" "+it.Config+" has no ABM id; "+blockedRemedy(it.Collection))
				continue
			}
			bpID := it.BPID
			if bpID == "" {
				bpID = createdIDs[it.Blueprint]
			}
			if bpID == "" { // the blueprint-new item failed or was skipped this run
				e.bpSkip(res, it, "skipped: blueprint "+it.Blueprint+" has no ABM id (create failed or was skipped) — re-run sync")
				continue
			}
			rel := ab.BlueprintRel(it.Collection)
			if rel == "" {
				e.bpFail(res, it, "unknown member collection "+it.Collection)
				continue
			}
			if !e.budget(opts, priorWrites+res.Writes) {
				e.bpSkip(res, it, "skipped: --limit-writes reached")
				continue
			}
			progress(opts, "attaching "+noun.long+" to blueprint: "+target)
			if err := e.Client.AddBlueprintMembers(bpID, rel, rel, []string{it.ConfigID}); err != nil {
				e.bpFail(res, it, "attach failed: "+err.Error())
				continue
			}
			res.Writes++
			e.bpDone(res, it, "attached "+it.Config)
		case it.Action.IsDetach():
			if !opts.Prune {
				e.bpSkip(res, it, "skipped: prune off (pass --prune to detach from ABM)")
				continue
			}
			if it.ConfigID == "" {
				e.bpFail(res, it, "detach skipped: unknown "+noun.short+" id for "+it.Config)
				continue
			}
			rel := ab.BlueprintRel(it.Collection)
			if rel == "" {
				e.bpFail(res, it, "unknown member collection "+it.Collection)
				continue
			}
			if !e.budget(opts, priorWrites+res.Writes) {
				e.bpSkip(res, it, "skipped: --limit-writes reached")
				continue
			}
			progress(opts, "detaching "+noun.long+" from blueprint: "+target)
			if err := e.Client.RemoveBlueprintMembers(it.BPID, rel, rel, []string{it.ConfigID}); err != nil {
				e.bpFail(res, it, "detach failed: "+err.Error())
				continue
			}
			res.Writes++
			e.bpDone(res, it, "detached "+it.Config)
		default: // BlueprintGone — reported, not applied
			e.bpSkip(res, it, it.Detail)
		}
	}
	return res
}

// blockedRemedy is the apply-time remedy for an attach with no member id (the
// plan-time equivalent is blockedDetail).
func blockedRemedy(collection string) string {
	switch collection {
	case "", ab.CollectionConfigurations:
		return "create/sync the config first, or remove it from the blueprint manifest if obsolete"
	default:
		return "fix the blueprint manifest, or remove it if obsolete"
	}
}

func (e *Engine) bpDone(res *BlueprintResult, it BlueprintItem, detail string) {
	res.Outcomes = append(res.Outcomes, BlueprintOutcome{Blueprint: it.Blueprint, Config: it.Config, Action: it.Action, Status: "done", Detail: detail})
}

func (e *Engine) bpSkip(res *BlueprintResult, it BlueprintItem, detail string) {
	res.Skipped++
	res.Outcomes = append(res.Outcomes, BlueprintOutcome{Blueprint: it.Blueprint, Config: it.Config, Action: it.Action, Status: "skipped", Detail: detail})
}

func (e *Engine) bpFail(res *BlueprintResult, it BlueprintItem, detail string) {
	res.Errors++
	res.Outcomes = append(res.Outcomes, BlueprintOutcome{Blueprint: it.Blueprint, Config: it.Config, Action: it.Action, Status: "error", Detail: detail})
}

func toSet(ss []string) map[string]struct{} {
	m := make(map[string]struct{}, len(ss))
	for _, s := range ss {
		m[s] = struct{}{}
	}
	return m
}

func sortedKeys(m map[string]struct{}) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}
