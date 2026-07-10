package reconcile

import (
	"sort"
	"time"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/hash"
	"github.com/GigaionLLC/abcli/internal/state"
)

// Archive reasons recorded on the pre-overwrite copy of a live profile.
const (
	reasonReplaced = "replaced"             // git changed, live didn't → git replaces live
	reasonNewer    = "overwritten-by-newer" // both changed, git is newer → git wins the conflict
	reasonPruned   = "pruned"               // removed from git, --prune → deleted from live
)

// Applier is the subset of the Apple Business write API the executor needs. It is
// an interface so Apply can be unit-tested with a fake — no production writes.
type Applier interface {
	CreateConfiguration(name, xml string, platforms []string) (id, updated string, err error)
	UpdateConfiguration(id, name, xml string) (updated string, err error)
	DeleteConfiguration(id string) error
	CreateBlueprint(name, description string) (*ab.Resource, error)
	AddBlueprintMembers(bpID, rel, memberType string, ids []string) error
	RemoveBlueprintMembers(bpID, rel, memberType string, ids []string) error
}

// Archiver files a pre-overwrite live profile + sidecar (see internal/archive).
// Injected so Apply stays disk-free and testable; it returns the archive path.
type Archiver interface {
	Archive(name, reason string, xml []byte, meta map[string]string) (path string, err error)
}

// FileStore is the git-side profile tree (see internal/gitops). Pull writes a
// file; an ABM-side delete removes one.
type FileStore interface {
	WriteConfig(name string, content []byte) error
	RemoveConfig(name string) error
}

// Opts tunes one apply run.
type Opts struct {
	Prune       bool     // enable DeleteABM (off by default — never prune unasked)
	LimitWrites int      // circuit breaker: max tenant writes per run (0 = unlimited)
	Platforms   []string // configuredForPlatforms for newly-created configs
	Progress    func(string)
	// GitTime resolves the git-side timestamp of a config (last commit time, else
	// file mtime) for newest-wins conflict resolution. ok=false → the timestamp is
	// unknown, so the conflict is skipped rather than guessed (never clobber a side
	// on missing information).
	GitTime func(name string) (t time.Time, ok bool)
}

// Engine executes a reconcile plan against a live tenant. It archives before
// every overwrite or delete and keeps the committed baseline exact so the next
// 3-way diff is correct.
type Engine struct {
	Client   Applier
	Archiver Archiver
	Files    FileStore
}

// Outcome records what happened to one planned item.
type Outcome struct {
	Name    string `json:"name"`
	Action  Action `json:"action"` // the effective action (a Conflict resolves to Update or Pull)
	Status  string `json:"status"` // "done" | "skipped" | "error"
	Detail  string `json:"detail"`
	Archive string `json:"archive,omitempty"` // archive path, when one was written
}

// Result summarizes an apply run.
type Result struct {
	Outcomes []Outcome `json:"outcomes"`
	Writes   int       `json:"writes"`  // tenant writes performed (POST/PATCH/DELETE)
	Errors   int       `json:"errors"`  // items that failed
	Skipped  int       `json:"skipped"` // items intentionally not applied (prune off / limit reached / unresolved)
}

// actionRank orders execution: creates/updates before pulls, deletes after, and
// prune (DeleteABM) strictly last — a device should never be left pointing at a
// config that a later step is about to remove.
var actionRank = map[Action]int{
	Create: 0, Update: 1, Conflict: 2, Pull: 3, PullNew: 4, DeleteGit: 5, DeleteABM: 6,
}

// Apply executes the plan. Every error is captured per-item in the Result (Errors
// count) rather than aborting the run, so independent configs still converge; the
// baseline (base) is mutated in place and should be saved by the caller only after
// Apply returns. Archiving always precedes the write it protects — if the archive
// fails, the write is skipped so the audit trail is never bypassed.
func (e *Engine) Apply(p *Plan, desired map[string][]byte, live []ab.LiveConfig, base *state.State, opts Opts) *Result {
	liveByName := make(map[string]ab.LiveConfig, len(live))
	for _, l := range live {
		liveByName[l.Name] = l
	}

	items := append([]Item(nil), p.Items...)
	sort.SliceStable(items, func(i, j int) bool {
		if ri, rj := actionRank[items[i].Action], actionRank[items[j].Action]; ri != rj {
			return ri < rj
		}
		return items[i].Name < items[j].Name
	})

	res := &Result{Outcomes: []Outcome{}}
	for _, it := range items {
		progress(opts, "applying config "+string(it.Action)+": "+it.Name)
		l := liveByName[it.Name]
		switch it.Action {
		case Create:
			e.push(res, opts, it.Name, Create, desired[it.Name], ab.LiveConfig{}, "", base)
		case Update:
			e.push(res, opts, it.Name, Update, desired[it.Name], l, reasonReplaced, base)
		case Conflict:
			e.conflict(res, opts, it.Name, desired[it.Name], l, base)
		case Pull, PullNew:
			e.pull(res, opts, it.Name, it.Action, l, base)
		case DeleteGit:
			e.deleteGit(res, opts, it.Name, base)
		case DeleteABM:
			e.deleteABM(res, opts, it.Name, l, base)
		}
	}
	return res
}

// conflict applies newest-wins: git's timestamp vs the live updatedDateTime.
func (e *Engine) conflict(res *Result, opts Opts, name string, want []byte, l ab.LiveConfig, base *state.State) {
	if opts.GitTime == nil {
		e.skip(res, name, Conflict, "conflict unresolved: no git-timestamp resolver")
		return
	}
	gitT, ok := opts.GitTime(name)
	if !ok {
		e.skip(res, name, Conflict, "conflict unresolved: git timestamp unknown")
		return
	}
	liveT, err := time.Parse(time.RFC3339Nano, l.Updated)
	if err != nil {
		e.skip(res, name, Conflict, "conflict unresolved: unparseable live updatedDateTime "+l.Updated)
		return
	}
	if gitT.Before(liveT) { // live is strictly newer → live wins → pull into git
		e.pull(res, opts, name, Pull, l, base)
		return
	}
	// git is newer or exactly ties → git wins → push over live (archive first)
	e.push(res, opts, name, Update, want, l, reasonNewer, base)
}

// push creates (Create) or updates (Update) the live config. For an update it
// archives the current live version first. Both consume the write budget.
func (e *Engine) push(res *Result, opts Opts, name string, act Action, want []byte, l ab.LiveConfig, reason string, base *state.State) {
	if !e.budget(opts, res.Writes) {
		e.skip(res, name, act, "skipped: --limit-writes reached")
		return
	}
	if act == Create {
		progress(opts, "creating configuration in ABM: "+name)
		id, updated, err := e.Client.CreateConfiguration(name, string(want), opts.Platforms)
		if err != nil {
			e.fail(res, name, act, "create failed: "+err.Error())
			return
		}
		res.Writes++
		base.Configs[name] = state.Entry{ABMID: id, Hash: hash.Raw(want), UpdatedDateTime: updated}
		res.Outcomes = append(res.Outcomes, Outcome{Name: name, Action: Create, Status: "done", Detail: "created on ABM (id " + id + ")"})
		return
	}
	// Update: archive the live version before overwriting it.
	if l.XML == "" {
		e.fail(res, name, act, "live profile XML unavailable for archive (use --refresh=full or smart refresh)")
		return
	}
	progress(opts, "archiving current ABM configuration: "+name)
	archPath, err := e.Archiver.Archive(name, reason, []byte(l.XML), map[string]string{
		"abm_id": l.ID, "hash": l.ContentHash(), "updatedDateTime": l.Updated,
	})
	if err != nil {
		e.fail(res, name, act, "archive failed (write skipped to preserve the audit trail): "+err.Error())
		return
	}
	progress(opts, "patching configuration in ABM: "+name)
	updated, err := e.Client.UpdateConfiguration(l.ID, name, string(want))
	if err != nil {
		e.fail(res, name, act, "update failed: "+err.Error())
		return
	}
	res.Writes++
	base.Configs[name] = state.Entry{ABMID: l.ID, Hash: hash.Raw(want), UpdatedDateTime: updated}
	res.Outcomes = append(res.Outcomes, Outcome{Name: name, Action: Update, Status: "done", Detail: "patched ABM (" + reason + ")", Archive: archPath})
}

// pull writes the live version into the git tree (no tenant write).
func (e *Engine) pull(res *Result, opts Opts, name string, act Action, l ab.LiveConfig, base *state.State) {
	if l.XML == "" {
		e.fail(res, name, act, "live profile XML unavailable for pull (use --refresh=full or smart refresh)")
		return
	}
	progress(opts, "writing live configuration into git: "+name)
	if err := e.Files.WriteConfig(name, []byte(l.XML)); err != nil {
		e.fail(res, name, act, "pull (write git file) failed: "+err.Error())
		return
	}
	base.Configs[name] = state.Entry{ABMID: l.ID, Hash: l.ContentHash(), UpdatedDateTime: l.Updated}
	res.Outcomes = append(res.Outcomes, Outcome{Name: name, Action: act, Status: "done", Detail: "pulled into git"})
}

// deleteGit removes a git file whose config vanished from ABM (no tenant write).
func (e *Engine) deleteGit(res *Result, opts Opts, name string, base *state.State) {
	progress(opts, "removing git file for missing ABM configuration: "+name)
	if err := e.Files.RemoveConfig(name); err != nil {
		e.fail(res, name, DeleteGit, "delete git file failed: "+err.Error())
		return
	}
	delete(base.Configs, name)
	res.Outcomes = append(res.Outcomes, Outcome{Name: name, Action: DeleteGit, Status: "done", Detail: "removed git file (gone from ABM)"})
}

// deleteABM prunes a live config removed from git — gated behind --prune, archived first.
func (e *Engine) deleteABM(res *Result, opts Opts, name string, l ab.LiveConfig, base *state.State) {
	if !opts.Prune {
		e.skip(res, name, DeleteABM, "skipped: prune off (pass --prune to delete from ABM)")
		return
	}
	if !e.budget(opts, res.Writes) {
		e.skip(res, name, DeleteABM, "skipped: --limit-writes reached")
		return
	}
	if l.XML == "" {
		e.fail(res, name, DeleteABM, "live profile XML unavailable for archive (use --refresh=full or smart refresh)")
		return
	}
	progress(opts, "archiving configuration before ABM delete: "+name)
	archPath, err := e.Archiver.Archive(name, reasonPruned, []byte(l.XML), map[string]string{
		"abm_id": l.ID, "hash": l.ContentHash(), "updatedDateTime": l.Updated,
	})
	if err != nil {
		e.fail(res, name, DeleteABM, "archive failed (delete skipped to preserve the audit trail): "+err.Error())
		return
	}
	progress(opts, "deleting configuration from ABM: "+name)
	if err := e.Client.DeleteConfiguration(l.ID); err != nil {
		e.fail(res, name, DeleteABM, "delete ABM failed: "+err.Error())
		return
	}
	res.Writes++
	delete(base.Configs, name)
	res.Outcomes = append(res.Outcomes, Outcome{Name: name, Action: DeleteABM, Status: "done", Detail: "deleted from ABM (pruned)", Archive: archPath})
}

// budget reports whether another tenant write is within the --limit-writes cap.
func (e *Engine) budget(opts Opts, writes int) bool {
	return opts.LimitWrites <= 0 || writes < opts.LimitWrites
}

func (e *Engine) skip(res *Result, name string, act Action, detail string) {
	res.Skipped++
	res.Outcomes = append(res.Outcomes, Outcome{Name: name, Action: act, Status: "skipped", Detail: detail})
}

func (e *Engine) fail(res *Result, name string, act Action, detail string) {
	res.Errors++
	res.Outcomes = append(res.Outcomes, Outcome{Name: name, Action: act, Status: "error", Detail: detail})
}

func progress(opts Opts, line string) {
	if opts.Progress != nil {
		opts.Progress(line)
	}
}
