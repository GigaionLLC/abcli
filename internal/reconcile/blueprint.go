package reconcile

import (
	"fmt"
	"sort"
	"strings"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/gitops"
)

// Blueprint reconcile follows the run's MembershipMode, which mirrors what
// --git-source-of-truth means for configs. Under GitAuthoritative, git is the
// complete desired state: members listed in the manifest are attached, and
// members attached in ABM but absent from git are detached (gated behind
// --prune). Under Bidirectional (the default), sync is additive: an ABM-only
// member is ADOPTED into the manifest instead — the membership counterpart of
// pulling a console-created config into git. Without that, the switch governed
// configs only, and a config attached through the console (or by `abctl attach`
// against a different tree) re-proposed the same detach on every run with no
// in-product way to say "this belongs in git". Configurations are always
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
	AdoptConfig   BlueprintAction = "adopt-config" // member in ABM, not in git → write it INTO the manifest (local, no tenant write)
	AdoptApp      BlueprintAction = "adopt-app"
	AdoptPackage  BlueprintAction = "adopt-package"
	AdoptDevice   BlueprintAction = "adopt-device"
	AdoptUser     BlueprintAction = "adopt-user"
	AdoptGroup    BlueprintAction = "adopt-group"
	BlueprintNew  BlueprintAction = "blueprint-new"   // blueprint in git, not in ABM → POST blueprints, then attach members
	BlueprintGone BlueprintAction = "blueprint-adopt" // blueprint in ABM, not in git → run seed to adopt (reported)
)

// IsAttach / IsDetach / IsAdopt classify a membership verb regardless of collection.
func (a BlueprintAction) IsAttach() bool { return strings.HasPrefix(string(a), "attach-") }

// IsDetach reports whether the action is a membership detach (any collection).
func (a BlueprintAction) IsDetach() bool { return strings.HasPrefix(string(a), "detach-") }

// IsAdopt reports whether the action writes a live member into the git manifest.
// The "adopt-" prefix is deliberately distinct from the blueprint-level
// "blueprint-adopt" (a reported-only row), so this never matches that.
func (a BlueprintAction) IsAdopt() bool { return strings.HasPrefix(string(a), "adopt-") }

// MembershipMode selects what a member attached in ABM but absent from the git
// manifest means for this run — the membership half of --git-source-of-truth.
type MembershipMode int

const (
	// Bidirectional is the default: sync is additive/newest-wins, so an ABM-only
	// member is adopted INTO the manifest (mirrors pull-new-git for configs).
	Bidirectional MembershipMode = iota
	// GitAuthoritative is --git-source-of-truth: the manifest is the complete
	// desired state, so an ABM-only member is detached (gated behind --prune).
	GitAuthoritative
)

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

var adoptActionByCollection = map[string]BlueprintAction{
	ab.CollectionConfigurations: AdoptConfig,
	ab.CollectionApps:           AdoptApp,
	ab.CollectionPackages:       AdoptPackage,
	ab.CollectionDevices:        AdoptDevice,
	ab.CollectionUsers:          AdoptUser,
	ab.CollectionGroups:         AdoptGroup,
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
// config not yet created/adopted, or a member name the tenant doesn't know). An
// adopt is a LOCAL manifest write and is only ever planned for a member that
// already resolved, so it is always performable.
func (it BlueprintItem) IsActionable() bool {
	return it.Action == BlueprintNew || it.Action.IsDetach() || it.Action.IsAdopt() ||
		(it.Action.IsAttach() && it.ConfigID != "")
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
// mode decides what an ABM-only MEMBER means: detach (GitAuthoritative) or
// adopt into the manifest (Bidirectional).
func ComputeBlueprints(desired map[string]gitops.BlueprintSpec, live []ab.LiveBlueprint, idByName map[string]map[string]string, mode MembershipMode) *BlueprintPlan {
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
			p.diffMembership(n, l.ID, d, &l, idByName, mode)
		case hasD && !hasL:
			p.Items = append(p.Items, BlueprintItem{Blueprint: n, Action: BlueprintNew, Description: d.Description,
				Detail: "in git, not in ABM → create blueprint (resolvable members ride inside the create; Apple rejects a member-less create)"})
			p.diffMembership(n, "", d, nil, idByName, mode) // no live side → attach-only, against the id the create yields
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
func (p *BlueprintPlan) diffMembership(bp, bpID string, d gitops.BlueprintSpec, live *ab.LiveBlueprint, idByName map[string]map[string]string, mode MembershipMode) {
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
		for _, m := range sortedKeys(liveSet) { // in ABM, not in git → detach or adopt, per mode
			if _, in := gitSet[m]; in {
				continue
			}
			id, known := ids[m]
			if !known || id == "" {
				// The live member has no UNIQUE addressable name here (configs: not a
				// baseline-managed CUSTOM_SETTING, e.g. native/console-only; others: an
				// id that didn't resolve to a tenant resource, or a name shared by >1
				// resource — detaching by that name could remove the wrong duplicate)
				// — never touch it. This gates ADOPT too: a manifest entry that can't
				// resolve back to an id would just become a blocked attach next run.
				continue
			}
			it := BlueprintItem{Blueprint: bp, BPID: bpID, Collection: col, Config: m, ConfigID: id}
			if mode == Bidirectional {
				it.Action = adoptActionByCollection[col]
				it.Detail = noun + " attached in ABM, not in git → adopt into the blueprint manifest (local write; turn on git source of truth to detach instead)"
			} else {
				it.Action = detachActionByCollection[col]
				it.Detail = noun + " attached in ABM, not in git → detach (gated --prune)"
			}
			p.Items = append(p.Items, it)
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
// then attach, then the ABM-only verbs (adopt/detach — mutually exclusive within
// a run, since the mode picks one), reported items last.
func bpRank(a BlueprintAction) int {
	switch {
	case a == BlueprintNew:
		return 0
	case a.IsAttach():
		return 1
	case a.IsAdopt():
		return 2
	case a.IsDetach():
		return 3
	default: // BlueprintGone — reported, not applied
		return 4
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
	// What each membership write claimed, checked in one pass at the end.
	var claims []membershipClaim

	// Members inlined into each blueprint-new create. Apple rejects a member-less
	// create (409 MISSING_MEMBERS / MISSING_RESOURCES — live-verified 2026-07-05,
	// HANDOFF.md), so every attach item for a git-only blueprint whose member id is
	// already resolvable rides along in the create POST itself. Those attach items
	// are then reported as satisfied-by-create instead of re-POSTed (the merge
	// would be a no-op, but it would still spend rate limit and --limit-writes).
	newBlueprints := map[string]bool{}
	for _, it := range items {
		if it.Action == BlueprintNew {
			newBlueprints[it.Blueprint] = true
		}
	}
	inlineMembers := map[string]map[string][]string{} // blueprint name → rel → ids
	for _, it := range items {
		if !newBlueprints[it.Blueprint] || !it.Action.IsAttach() || it.ConfigID == "" {
			continue
		}
		rel := ab.BlueprintRel(it.Collection)
		if rel == "" {
			continue
		}
		if inlineMembers[it.Blueprint] == nil {
			inlineMembers[it.Blueprint] = map[string][]string{}
		}
		inlineMembers[it.Blueprint][rel] = append(inlineMembers[it.Blueprint][rel], it.ConfigID)
	}
	createdInline := map[string]bool{} // blueprint name → create succeeded and inlined its members

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
			r, err := e.Client.CreateBlueprint(it.Blueprint, it.Description, inlineMembers[it.Blueprint])
			if err != nil {
				e.bpFail(res, it, "create blueprint failed: "+err.Error())
				continue
			}
			res.Writes++
			createdIDs[it.Blueprint] = r.ID
			if len(inlineMembers[it.Blueprint]) > 0 {
				createdInline[it.Blueprint] = true
			}
			e.bpDone(res, it, "created blueprint on ABM (id "+r.ID+", members inlined)")
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
			if createdInline[it.Blueprint] {
				// This member was carried inside the create POST above — done, not a
				// separate write (relationships POST merges, so re-attaching would be a
				// harmless but rate-limited no-op).
				e.bpDone(res, it, "attached "+it.Config+" (inlined in the blueprint create)")
				// Reported done on the strength of the create's 2xx, so it is exactly the
				// kind of claim the verification pass below exists to check.
				claims = append(claims, membershipClaim{outcome: len(res.Outcomes), bpID: bpID, rel: rel, memberID: it.ConfigID, present: true})
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
			claims = append(claims, membershipClaim{outcome: len(res.Outcomes), bpID: bpID, rel: rel, memberID: it.ConfigID, present: true})
		case it.Action.IsAdopt():
			// A LOCAL write: it changes gitops/blueprints/<bp>.yml, never the tenant.
			// So it spends no rate limit, is not counted in res.Writes, and is not
			// gated by --limit-writes or --prune — none of which are about local
			// files. (--prune in particular gates REMOVING things; adopt only adds.)
			progress(opts, "adopting "+noun.long+" into the blueprint manifest: "+target)
			if err := e.adoptMember(it); err != nil {
				e.bpFail(res, it, "adopt into the blueprint manifest failed: "+err.Error())
				continue
			}
			e.bpDone(res, it, "recorded "+it.Config+" in the git manifest for "+it.Blueprint+" (local file; commit gitops/ to keep it)")
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
			claims = append(claims, membershipClaim{outcome: len(res.Outcomes), bpID: it.BPID, rel: rel, memberID: it.ConfigID, present: false})
		default: // BlueprintGone — reported, not applied
			e.bpSkip(res, it, it.Detail)
		}
	}
	e.verifyMembership(res, claims, opts)
	return res
}

// membershipClaim is one membership write and what it asserted about the tenant.
// `outcome` is the 1-based position of the row in res.Outcomes, so a failed check can
// downgrade the exact row that made the claim.
type membershipClaim struct {
	// outcome is the 1-based index of the row this claim belongs to — captured AFTER the
	// row is appended, so `res.Outcomes[outcome-1]` is that row and not the one before it.
	outcome  int
	bpID     string
	rel      string
	memberID string
	present  bool // true for an attach, false for a detach
}

// verifyMembership re-reads the relationships that were written and confirms the tenant
// actually holds what each write claimed.
//
// The project's rule is that a 2xx is not proof — Apple acknowledges a configuration
// write and then silently declines to store it, which is why every config write reads
// back. Membership writes had no such check: `attached` was reported on the response
// code alone, and a member inlined into a blueprint create was reported attached purely
// because the create returned 2xx.
//
// The cost is deliberately per RELATIONSHIP, not per member: attaching twenty configs to
// one blueprint is one extra GET, not twenty. Apple rate-limits hard, and a verification
// that scales with the number of writes would discourage its own use.
//
// A read that FAILS downgrades the row to "not verified" rather than failing it — a GET
// that errored says nothing about the POST, the same posture the config read-back takes.
func (e *Engine) verifyMembership(res *BlueprintResult, claims []membershipClaim, opts Opts) {
	if len(claims) == 0 {
		return
	}
	type relKey struct{ bpID, rel string }
	live := map[relKey]map[string]bool{}
	unreadable := map[relKey]string{}

	for _, c := range claims {
		key := relKey{c.bpID, c.rel}
		if _, done := live[key]; done {
			continue
		}
		if _, failed := unreadable[key]; failed {
			continue
		}
		progress(opts, "verifying blueprint membership: "+c.rel)
		members, err := e.Client.BlueprintRelationship(c.bpID, c.rel)
		if err != nil {
			unreadable[key] = err.Error()
			continue
		}
		set := make(map[string]bool, len(members))
		for _, m := range members {
			set[m.ID] = true
		}
		live[key] = set
	}

	for _, c := range claims {
		if c.outcome <= 0 || c.outcome > len(res.Outcomes) {
			continue
		}
		row := &res.Outcomes[c.outcome-1]
		key := relKey{c.bpID, c.rel}
		if reason, failed := unreadable[key]; failed {
			row.Detail += " — NOT VERIFIED (re-read failed: " + reason + ")"
			continue
		}
		if live[key][c.memberID] == c.present {
			continue // the tenant holds what the write claimed
		}
		verb := "attach"
		if !c.present {
			verb = "detach"
		}
		row.Status = "error"
		row.Detail += " — but Apple does not reflect it: the " + verb +
			" was accepted (2xx) and the membership did not change. Re-run sync; if it repeats, " +
			"the member or the blueprint may have been changed in the console mid-run."
		res.Errors++
	}
}

// adoptMember records one live member in its blueprint manifest. The existing
// manifest is loaded and only this collection's list GAINS the name — see
// gitops.BlueprintSpec.WithMember for why the write is additive rather than a
// rewrite from live, and why an unmanaged collection is refused.
//
// A blueprint with no manifest yet is not adopted here: writing one would
// declare `configurations:` (always-managed) from a single member, making every
// other live config on it a --prune detach candidate the moment git source of
// truth is switched on. That case already has its own reported row
// (blueprint-adopt → run `abctl seed`).
func (e *Engine) adoptMember(it BlueprintItem) error {
	if e.Files == nil {
		return fmt.Errorf("no gitops tree available to write")
	}
	all, err := e.Files.LoadBlueprints()
	if err != nil {
		return fmt.Errorf("reading existing blueprint manifests: %w", err)
	}
	spec, ok := all[it.Blueprint]
	if !ok {
		return fmt.Errorf("blueprint %q has no manifest in gitops/blueprints — run `abctl seed` to adopt the blueprint itself first", it.Blueprint)
	}
	col := it.Collection
	if col == "" { // legacy items predate the Collection field (= configurations)
		col = ab.CollectionConfigurations
	}
	next, added := spec.WithMember(col, it.Config)
	if !added {
		return fmt.Errorf("blueprint %q's manifest does not manage %s membership (add the key with `abctl seed --blueprint-membership`)", it.Blueprint, col)
	}
	if next.ID == "" {
		next.ID = it.BPID
	}
	return e.Files.WriteBlueprintSpec(next)
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
