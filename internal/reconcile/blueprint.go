package reconcile

import (
	"sort"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/gitops"
)

// Blueprint reconcile is git-authoritative for a blueprint's CUSTOM_SETTING
// config membership: configs listed in the git manifest are attached; configs
// attached in ABM but absent from git are detached (gated behind --prune). It only
// ever touches CUSTOM_SETTING configs abctl owns — a native/console-only config
// attached in ABM is never detached. Blueprint create (needs an identity member,
// which is console-managed) and delete, and device/user/group membership, are out
// of scope here — they are reported, not applied.

// BlueprintAction is the reconcile verb for a blueprint or one of its config members.
type BlueprintAction string

// Blueprint reconcile actions.
const (
	Attach        BlueprintAction = "attach-config"   // config in git, not in ABM → POST membership
	Detach        BlueprintAction = "detach-config"   // config in ABM, not in git → DELETE membership (gated --prune)
	BlueprintNew  BlueprintAction = "blueprint-new"   // blueprint in git, not in ABM → can't auto-create (reported)
	BlueprintGone BlueprintAction = "blueprint-adopt" // blueprint in ABM, not in git → run seed to adopt (reported)
)

// BlueprintItem is one planned blueprint change.
type BlueprintItem struct {
	Blueprint string          `json:"blueprint"`
	BPID      string          `json:"bp_id,omitempty"`
	Action    BlueprintAction `json:"action"`
	Config    string          `json:"config,omitempty"`
	ConfigID  string          `json:"config_id,omitempty"`
	Detail    string          `json:"detail"`
}

// BlueprintPlan is the ordered set of planned blueprint changes.
type BlueprintPlan struct {
	Items []BlueprintItem `json:"items"`
}

// HasChanges reports whether the plan contains any items (actionable or reported).
func (p *BlueprintPlan) HasChanges() bool { return len(p.Items) > 0 }

// HasReconcilableChanges reports whether the plan has drift that sync can act on —
// an attach or a detach. Reported-only advisories (blueprint-new / blueprint-adopt,
// which sync never applies) are excluded, so they don't make --exit-on-diff loop
// forever or trigger a confirm-then-do-nothing apply.
func (p *BlueprintPlan) HasReconcilableChanges() bool {
	for _, it := range p.Items {
		if it.Action == Attach || it.Action == Detach {
			return true
		}
	}
	return false
}

// ReconcilableCount is the number of attach/detach items (for a confirm prompt).
func (p *BlueprintPlan) ReconcilableCount() int {
	n := 0
	for _, it := range p.Items {
		if it.Action == Attach || it.Action == Detach {
			n++
		}
	}
	return n
}

// ComputeBlueprints diffs the git blueprint manifests against live ABM blueprints,
// per config membership. cfgIDByName resolves a config NAME → its ABM id (built
// from live configs, or from the post-apply baseline so freshly-created configs
// resolve). A blueprint is matched by name across git and ABM.
func ComputeBlueprints(desired map[string]gitops.BlueprintSpec, live []ab.LiveBlueprint, cfgIDByName map[string]string) *BlueprintPlan {
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
			gitSet := toSet(d.Configurations)
			liveSet := toSet(l.Configs)
			for _, cfg := range sortedKeys(gitSet) { // attach: in git, not in ABM
				if _, in := liveSet[cfg]; in {
					continue
				}
				it := BlueprintItem{Blueprint: n, BPID: l.ID, Action: Attach, Config: cfg, ConfigID: cfgIDByName[cfg]}
				if it.ConfigID == "" {
					it.Detail = "config in git but not yet in ABM — will attach once the config is created"
				} else {
					it.Detail = "config in git, not attached in ABM → attach"
				}
				p.Items = append(p.Items, it)
			}
			for _, cfg := range sortedKeys(liveSet) { // detach: in ABM, not in git
				if _, in := gitSet[cfg]; in {
					continue
				}
				id, known := cfgIDByName[cfg]
				if !known {
					// Not a CUSTOM_SETTING abctl manages (e.g. a native/console config) — never touch it.
					continue
				}
				p.Items = append(p.Items, BlueprintItem{Blueprint: n, BPID: l.ID, Action: Detach, Config: cfg,
					ConfigID: id, Detail: "config attached in ABM, not in git → detach (gated --prune)"})
			}
		case hasD && !hasL:
			p.Items = append(p.Items, BlueprintItem{Blueprint: n, Action: BlueprintNew,
				Detail: "in git, not in ABM — blueprint create needs a member (device/user/group); create it in the console, then re-sync"})
		case !hasD && hasL:
			p.Items = append(p.Items, BlueprintItem{Blueprint: n, BPID: l.ID, Action: BlueprintGone,
				Detail: "in ABM, not in git — run `abctl seed` to adopt it (or add a manifest)"})
		}
	}
	return p
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

// bpRank orders execution: attach before detach; reported items last.
var bpRank = map[BlueprintAction]int{Attach: 0, Detach: 1, BlueprintNew: 2, BlueprintGone: 3}

// ApplyBlueprints executes the blueprint membership plan: attach (always) and
// detach (only with --prune) config members via per-member POST/DELETE (the
// relationship is additive/merges, so this converges). priorWrites is the tenant
// writes already spent this run (e.g. by config apply) so --limit-writes is a
// single shared budget. Reported-only items (create/adopt) are surfaced as skips.
func (e *Engine) ApplyBlueprints(p *BlueprintPlan, opts Opts, priorWrites int) *BlueprintResult {
	items := append([]BlueprintItem(nil), p.Items...)
	sort.SliceStable(items, func(i, j int) bool {
		if ri, rj := bpRank[items[i].Action], bpRank[items[j].Action]; ri != rj {
			return ri < rj
		}
		return items[i].Blueprint < items[j].Blueprint
	})

	res := &BlueprintResult{Outcomes: []BlueprintOutcome{}}
	for _, it := range items {
		switch it.Action {
		case Attach:
			if it.ConfigID == "" {
				// The config isn't in ABM yet (brand-new in git, throttled by
				// --limit-writes in phase 1, or a dangling manifest reference). This
				// is a benign, resumable state — a skip, not an error that aborts.
				e.bpSkip(res, it, "skipped: config "+it.Config+" not yet in ABM — will attach on a later sync")
				continue
			}
			if !e.budget(opts, priorWrites+res.Writes) {
				e.bpSkip(res, it, "skipped: --limit-writes reached")
				continue
			}
			if err := e.Client.AddBlueprintMembers(it.BPID, "configurations", "configurations", []string{it.ConfigID}); err != nil {
				e.bpFail(res, it, "attach failed: "+err.Error())
				continue
			}
			res.Writes++
			e.bpDone(res, it, "attached "+it.Config)
		case Detach:
			if !opts.Prune {
				e.bpSkip(res, it, "skipped: prune off (pass --prune to detach from ABM)")
				continue
			}
			if it.ConfigID == "" {
				e.bpFail(res, it, "detach skipped: unknown config id for "+it.Config)
				continue
			}
			if !e.budget(opts, priorWrites+res.Writes) {
				e.bpSkip(res, it, "skipped: --limit-writes reached")
				continue
			}
			if err := e.Client.RemoveBlueprintMembers(it.BPID, "configurations", "configurations", []string{it.ConfigID}); err != nil {
				e.bpFail(res, it, "detach failed: "+err.Error())
				continue
			}
			res.Writes++
			e.bpDone(res, it, "detached "+it.Config)
		default: // BlueprintNew / BlueprintGone — reported, not applied
			e.bpSkip(res, it, it.Detail)
		}
	}
	return res
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
