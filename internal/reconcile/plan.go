// Package reconcile computes the 3-way plan (git desired ↔ committed baseline ↔
// live ABM) for bidirectional, newest-wins sync. Phase 1 computes + reports the
// plan only; Phase 2 executes it.
package reconcile

import (
	"sort"
	"time"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/hash"
	"github.com/GigaionLLC/abcli/internal/state"
)

// Action is the reconcile verb chosen for one config in the plan.
type Action string

// Reconcile actions, one per planned change to a config.
const (
	Create    Action = "create-abm"   // new in git → POST
	Update    Action = "update-abm"   // changed in git → PATCH
	Pull      Action = "pull-git"     // changed in ABM → write into git
	PullNew   Action = "pull-new-git" // new in ABM (console-created) → write into git
	DeleteABM Action = "delete-abm"   // removed from git → DELETE (prune, gated)
	DeleteGit Action = "delete-git"   // removed from ABM → remove git file
	Conflict  Action = "conflict"     // changed in BOTH → newest-wins (resolved at apply)
)

// Item is one planned change: the config name, the action, and a human-readable detail.
type Item struct {
	Name   string `json:"name"`
	Action Action `json:"action"`
	Detail string `json:"detail"`
}

// Plan is the ordered set of changes the reconcile produced.
type Plan struct {
	Items []Item `json:"items"`
}

// HasChanges reports whether the plan contains any changes.
func (p *Plan) HasChanges() bool { return len(p.Items) > 0 }

// Compute diffs desired (git lib/) vs baseline (state) vs live (ABM). Only
// changed items are returned; unchanged configs are omitted.
func Compute(desired map[string][]byte, base *state.State, live []ab.LiveConfig) *Plan {
	liveByName := make(map[string]ab.LiveConfig, len(live))
	for _, l := range live {
		liveByName[l.Name] = l
	}
	names := map[string]struct{}{}
	for n := range desired {
		names[n] = struct{}{}
	}
	for n := range base.Configs {
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

	p := &Plan{Items: []Item{}}
	for _, n := range ordered {
		d, hasD := desired[n]
		b, hasB := base.Configs[n]
		l, hasL := liveByName[n]

		gitChanged := hasD && (!hasB || hash.Raw(d) != b.Hash)
		abmChanged := hasL && (!hasB || hash.Raw([]byte(l.XML)) != b.Hash || liveTimeChanged(b.UpdatedDateTime, l.Updated))

		switch {
		case hasD && hasL:
			switch {
			case gitChanged && abmChanged:
				p.add(n, Conflict, "changed in BOTH git and ABM (ABM updated "+l.Updated+") — newest-wins")
			case gitChanged:
				p.add(n, Update, "changed in git → PATCH ABM")
			case abmChanged:
				p.add(n, Pull, "changed in ABM (updated "+l.Updated+") → pull into git")
			}
		case hasD && !hasL:
			if hasB {
				p.add(n, DeleteGit, "deleted in ABM → remove from git")
			} else {
				p.add(n, Create, "new in git → POST ABM")
			}
		case !hasD && hasL:
			if hasB {
				p.add(n, DeleteABM, "removed from git → DELETE ABM (prune; gated)")
			} else {
				p.add(n, PullNew, "new in ABM (console-created) → pull into git")
			}
		}
	}
	return p
}

func (p *Plan) add(name string, a Action, detail string) {
	p.Items = append(p.Items, Item{Name: name, Action: a, Detail: detail})
}

// liveTimeChanged reports whether the live updatedDateTime differs from the
// baseline's. It is only a *hint* (the raw hash is the exact drift signal), so it
// stays conservative: an empty baseline timestamp (a write response that omitted
// it — see internal/ab) is treated as "no change" rather than forcing a phantom
// pull, and two timestamps are compared as instants (not raw strings) so a
// serialization difference (Z vs +00:00, fractional precision) between the write
// response and the list endpoint doesn't read as drift.
func liveTimeChanged(baseTS, liveTS string) bool {
	if baseTS == "" || liveTS == "" {
		return false
	}
	if bt, err1 := time.Parse(time.RFC3339Nano, baseTS); err1 == nil {
		if lt, err2 := time.Parse(time.RFC3339Nano, liveTS); err2 == nil {
			return !bt.Equal(lt)
		}
	}
	return baseTS != liveTS // unparseable on either side → exact-string fallback
}
