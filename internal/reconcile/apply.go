package reconcile

import (
	"sort"
	"time"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/gitops"
	"github.com/GigaionLLC/abcli/internal/hash"
	"github.com/GigaionLLC/abcli/internal/state"
)

// Archive reasons recorded on the pre-overwrite copy of a live profile.
const (
	reasonReplaced = "replaced"             // git changed, live didn't → git replaces live
	reasonNewer    = "overwritten-by-newer" // both changed, git is newer → git wins the conflict
	reasonPruned   = "pruned"               // removed from git, --prune → deleted from live
)

// notPersisted reports a write Apple acknowledged but did not store. Apple answers
// the POST/PATCH 2xx and then silently discards a profile that violates its schema:
// the live bytes never change, so the next run recomputes the identical change and
// the GitOps sync loops forever (one operator saw exactly this, one profile of 39,
// its live updatedDateTime frozen across every attempt while the other eight edits
// in the same run converged). The message names the top cause because that is what
// makes it actionable — the outer Configuration PayloadVersion must be exactly 1
// (https://developer.apple.com/documentation/devicemanagement/toplevel).
const notPersisted = "write accepted (2xx) but Apple did not persist it — the stored profile still differs from git. " +
	"Apple silently drops profiles that violate its schema; check that the TOP-LEVEL Configuration PayloadVersion " +
	"is exactly 1 (Apple requires 1; a value of 2 reproduces this exactly)."

// NotPersistedMessage is the operator-facing diagnosis of a 2xx write Apple did not
// store. Exported so the imperative commands (which issue the same writes against the
// same API) report it in the same words as the reconcile engine — one incident, one
// explanation, one place to improve it.
const NotPersistedMessage = notPersisted

// Applier is the subset of the Apple Business write API the executor needs. It is
// an interface so Apply can be unit-tested with a fake — no production writes.
type Applier interface {
	CreateConfiguration(name, xml string, platforms []string) (id, updated string, err error)
	UpdateConfiguration(id, name, xml string) (updated string, err error)
	// FetchCustomSettingDetail re-reads one configuration *with its profile XML* so a
	// write can be confirmed against what Apple actually stored (see push). The name
	// and signature are *ab.Client's own, so the real client keeps satisfying Applier
	// with no adapter.
	FetchCustomSettingDetail(id string) (ab.LiveConfig, error)
	DeleteConfiguration(id string) error
	CreateBlueprint(name, description string, members map[string][]string) (*ab.Resource, error)
	AddBlueprintMembers(bpID, rel, memberType string, ids []string) error
	RemoveBlueprintMembers(bpID, rel, memberType string, ids []string) error
}

// Archiver files a pre-overwrite live profile + sidecar (see internal/archive).
// Injected so Apply stays disk-free and testable; it returns the archive path.
type Archiver interface {
	Archive(name, reason string, xml []byte, meta map[string]string) (path string, err error)
}

// FileStore is the git-side desired-state tree (see internal/gitops). Pull writes
// a profile; an ABM-side delete removes one; an adopt row records a live
// blueprint member in its manifest. Every method here writes LOCAL files only —
// nothing in this interface reaches the tenant.
type FileStore interface {
	WriteConfig(name string, content []byte) error
	RemoveConfig(name string) error
	LoadBlueprints() (map[string]gitops.BlueprintSpec, error)
	WriteBlueprintSpec(gitops.BlueprintSpec) error
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

// Verification is the verdict of the confirming read-back a create/update performs
// (see push). It is recorded on the Outcome so a caller can report on the write
// WITHOUT re-reading the config: the GET has already happened, and Apple rate-limits
// hard, so a second identical fetch buys nothing.
type Verification string

// Read-back verdicts. Only create/update outcomes carry one; everything else (pull,
// delete, skip, a write that never reached Apple) leaves it empty.
const (
	// VerifyConfirmed: read back from Apple and byte-identical to git. This is the
	// only verdict that lets the baseline be written.
	VerifyConfirmed Verification = "confirmed"
	// VerifyNotPersisted: Apple answered 2xx and did NOT store the profile — the
	// stored bytes still differ, or the write echoed an unchanged updatedDateTime.
	VerifyNotPersisted Verification = "not-persisted"
	// VerifyUnconfirmed: the read-back itself did not produce an answer (it failed,
	// or came back without profile XML). This says nothing about the write, which
	// may well have landed — it is NOT evidence of failure.
	VerifyUnconfirmed Verification = "unconfirmed"
)

// Outcome records what happened to one planned item.
type Outcome struct {
	Name    string `json:"name"`
	Action  Action `json:"action"` // the effective action (a Conflict resolves to Update or Pull)
	Status  string `json:"status"` // "done" | "skipped" | "error"
	Detail  string `json:"detail"`
	Archive string `json:"archive,omitempty"` // archive path, when one was written
	// ABMID is the configuration id the write targeted (Update) or created (Create).
	// It is recorded on EVERY create/update outcome, including the ones whose baseline
	// entry is deliberately not written (see push) — a caller that wants to re-read an
	// unconfirmed write has no other source for the id, since the baseline only ever
	// describes a confirmed one.
	ABMID string `json:"abm_id,omitempty"`
	// Verified is the read-back verdict for a create/update (empty for everything
	// else). "done" + VerifyUnconfirmed is a real state: the write was made, the
	// confirmation was not obtained, and the baseline was deliberately left alone.
	Verified Verification `json:"verified,omitempty"`
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

// push creates (Create) or updates (Update) the live config, then CONFIRMS the
// write by reading back what Apple stored. For an update it archives the current
// live version first. Both consume the write budget.
//
// The read-back is the whole point: this function used to record the baseline
// optimistically from the desired bytes (Hash: hash.Raw(want)), so a write Apple
// accepted-and-dropped (see notPersisted) was booked as success and the drift came
// back on the very next run, forever. The baseline must describe what Apple stored,
// never what we intended, so it is now written from the OBSERVED read-back — or not
// written at all.
//
// Rate limits (AGENT.md): this costs exactly ONE extra GET per config *actually
// written* — never per planned item, never for pulls, skips or budget-capped items,
// and never twice for the same write (internal/cli only re-reads what this could not
// confirm). Tenant writes are rare and human-gated behind --apply, so the added
// traffic is bounded by the number of real changes and stays well inside Apple's
// limits.
func (e *Engine) push(res *Result, opts Opts, name string, act Action, want []byte, l ab.LiveConfig, reason string, base *state.State) {
	if !e.budget(opts, res.Writes) {
		e.skip(res, name, act, "skipped: --limit-writes reached")
		return
	}

	// Perform the write. Both branches converge on the confirmation step below with:
	// id (what to read back), prevUpdated (the pre-apply timestamp, empty for a
	// create), updated (the timestamp the write response echoed), detail + archPath
	// (the success reporting).
	var id, prevUpdated, updated, archPath, detail string
	if act == Create {
		progress(opts, "creating configuration in ABM: "+name)
		newID, ts, err := e.Client.CreateConfiguration(name, string(want), opts.Platforms)
		if err != nil {
			e.fail(res, name, act, "create failed: "+err.Error())
			return
		}
		res.Writes++
		id, updated, detail = newID, ts, "created on ABM (id "+newID+")"
	} else {
		// Update: archive the live version before overwriting it.
		if l.XML == "" {
			e.fail(res, name, act, "live profile XML unavailable for archive (use --refresh=full or smart refresh)")
			return
		}
		progress(opts, "archiving current ABM configuration: "+name)
		path, err := e.Archiver.Archive(name, reason, []byte(l.XML), map[string]string{
			"abm_id": l.ID, "hash": l.ContentHash(), "updatedDateTime": l.Updated,
		})
		if err != nil {
			e.fail(res, name, act, "archive failed (write skipped to preserve the audit trail): "+err.Error())
			return
		}
		archPath = path
		progress(opts, "patching configuration in ABM: "+name)
		ts, err := e.Client.UpdateConfiguration(l.ID, name, string(want))
		if err != nil {
			e.fail(res, name, act, "update failed: "+err.Error())
			return
		}
		res.Writes++
		id, prevUpdated, updated, detail = l.ID, l.Updated, ts, "patched ABM ("+reason+")"
	}

	// unverified records a write we could not check. It is deliberately "done", not
	// "error": a read-back that never happened says nothing about the write, which
	// may well have landed, so failing the run would cry wolf. The baseline is left
	// alone for the same reason it is not written on a mismatch — an optimistic entry
	// claims a convergence nobody observed and would hide a genuinely dropped write
	// (exactly the incident above), while a stale entry costs at most one redundant,
	// archived re-write next run. Re-doing a gated write is recoverable; masking
	// drift is not.
	unverified := func(why string) {
		res.Outcomes = append(res.Outcomes, Outcome{Name: name, Action: act, Status: "done",
			Detail:   detail + " — NOT VERIFIED (" + why + "); baseline left unchanged so the next run re-checks it",
			Archive:  archPath,
			ABMID:    id,
			Verified: VerifyUnconfirmed})
	}

	// The echoed timestamp is CORROBORATION, never the verdict on its own. Apple bumps
	// updatedDateTime on every change it stores, so a write response echoing the
	// pre-apply value is a strong hint the write did not take — but by that same
	// reasoning a PATCH that stores nothing *because nothing changed* cannot bump it
	// either, and that case is reachable: Compute yields Conflict whenever both sides
	// moved relative to a stale baseline, which resolves to an Update whose bytes are
	// already byte-identical to what Apple holds. Failing on the hint alone would then
	// blame the operator's PayloadVersion for a profile that already matches git, and —
	// since a failure never advances the baseline — do it again on every future run.
	// So the authoritative read-back below always happens, and the frozen timestamp is
	// only allowed to decide when the read-back itself produces no answer.
	frozen := unchangedTimestamp(prevUpdated, updated)
	frozenSignal := "the write response echoed the unchanged updatedDateTime " + updated
	frozenNote := ""
	if frozen {
		frozenNote = "; " + frozenSignal
	}

	// unreadable turns "the read-back gave no answer" into a verdict: normally
	// unverified (a GET that failed says nothing about the write), but with the frozen
	// timestamp beside it the two independent signals agree and it is a dropped write.
	unreadable := func(why string) {
		if frozen {
			e.dropped(res, name, act, id, notPersisted+" (signal: "+frozenSignal+"; "+why+")", archPath)
			return
		}
		unverified(why)
	}

	if id == "" { // nothing to read back — never GET /configurations/ with an empty id
		unreadable("the write response carried no configuration id")
		return
	}
	progress(opts, "verifying the stored configuration in ABM: "+name)
	stored, err := e.Client.FetchCustomSettingDetail(id)
	switch {
	case err != nil:
		unreadable("read-back failed: " + err.Error())
	case stored.ContentHash() == "":
		// Detail response without profile XML: we cannot compare, so we must not
		// accuse Apple of dropping a write it may have stored. Same posture as above.
		unreadable("read-back returned no profile XML to compare")
	case stored.ContentHash() != hash.Raw(want):
		// Apple kept different bytes than we sent. Same raw-hash signal the planner
		// uses, so "match" here means the next Compute really will see convergence.
		e.dropped(res, name, act, id,
			notPersisted+" (signal: the stored profile still differs after the write; stored updatedDateTime "+stored.Updated+frozenNote+")", archPath)
	default:
		// The stored bytes ARE what git wants — including when the timestamp never
		// moved, because a no-op write is a converged config, not a dropped one.
		base.Configs[name] = state.Entry{ABMID: id, Hash: stored.ContentHash(), UpdatedDateTime: stored.Updated}
		res.Outcomes = append(res.Outcomes, Outcome{Name: name, Action: act, Status: "done", Detail: detail, Archive: archPath, ABMID: id, Verified: VerifyConfirmed})
	}
}

// unchangedTimestamp reports whether a write response carried the very same
// updatedDateTime the config had before the write. Both sides must be present (a
// write response may omit the field — see internal/ab), and the comparison is by
// instant rather than by string so a serialization difference (Z vs +00:00,
// fractional precision) between the write response and the list endpoint is not
// mistaken for progress.
func unchangedTimestamp(before, after string) bool {
	return before != "" && after != "" && !liveTimeChanged(before, after)
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
	e.failWithArchive(res, name, act, detail, "")
}

// failWithArchive records a failure that nonetheless produced an archive. A write
// rejected *after* the pre-overwrite copy was filed still has that copy, and the
// operator needs the path: it is the evidence that the live bytes never moved.
func (e *Engine) failWithArchive(res *Result, name string, act Action, detail, archive string) {
	res.Errors++
	res.Outcomes = append(res.Outcomes, Outcome{Name: name, Action: act, Status: "error", Detail: detail, Archive: archive})
}

// dropped records the accepted-but-not-persisted write: a failure whose verdict is
// known, so callers can report it without re-reading the config. The id rides along
// for the same reason it does on a successful write — it is the only handle an
// operator (or a later check) has on the configuration Apple did not store.
func (e *Engine) dropped(res *Result, name string, act Action, id, detail, archive string) {
	res.Errors++
	res.Outcomes = append(res.Outcomes, Outcome{Name: name, Action: act, Status: "error",
		Detail: detail, Archive: archive, ABMID: id, Verified: VerifyNotPersisted})
}

func progress(opts Opts, line string) {
	if opts.Progress != nil {
		opts.Progress(line)
	}
}
