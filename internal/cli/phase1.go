package cli

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/archive"
	"github.com/GigaionLLC/abcli/internal/config"
	"github.com/GigaionLLC/abcli/internal/gitops"
	"github.com/GigaionLLC/abcli/internal/hash"
	"github.com/GigaionLLC/abcli/internal/reconcile"
	"github.com/GigaionLLC/abcli/internal/state"
)

const (
	refreshSmart    = "smart"
	refreshFull     = "full"
	refreshMetadata = "metadata-only"

	verifyTargeted = "targeted"
	verifyFull     = "full"
	verifyNone     = "none"
)

func newSeedCmd() *cobra.Command {
	var bpMembership bool
	c := &cobra.Command{
		Use:   "seed",
		Short: "Download live configs → gitops/ tree + baseline (reads ABM, writes local files)",
		Long: "seed materializes the live tenant into the local gitops tree. By default a blueprint\n" +
			"manifest tracks configuration membership only; --blueprint-membership additionally\n" +
			"writes the apps/packages/devices/users/groups keys from live, making all six member\n" +
			"collections MANAGED (sync will then attach/detach them to match git). A key you later\n" +
			"delete from a manifest becomes unmanaged again and is never touched.",
		Args: cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error { return runSeed(bpMembership) },
	}
	c.Flags().BoolVar(&bpMembership, "blueprint-membership", false,
		"also write apps/packages/devices/users/groups membership into blueprint manifests (all six collections become managed)")
	return c
}

func newDiffCmd() *cobra.Command {
	var asJSON, exitOnDiff, gitSourceOfTruth bool
	var refresh string
	c := &cobra.Command{
		Use:   "diff",
		Short: "3-way plan: git desired vs baseline vs live ABM (configs + blueprint membership)",
		Args:  cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			if err := validateRefreshMode(refresh); err != nil {
				return err
			}
			pc, err := loadPlan(gitSourceOfTruth, refresh, false) // diff never writes
			if err != nil {
				return err
			}
			if err := printFullPlan(pc, planFormat(asJSON)); err != nil {
				return err
			}
			if exitOnDiff && pc.hasChanges() {
				return ExitError{Code: 3}
			}
			return nil
		},
	}
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	c.Flags().BoolVar(&exitOnDiff, "exit-on-diff", false, "exit 3 if changes are pending")
	c.Flags().BoolVar(&gitSourceOfTruth, "git-source-of-truth", false,
		"treat gitops/ as authoritative: plan DELETE/detach for Apple-only configs and blueprint members instead of pulling/adopting them into git")
	c.Flags().StringVar(&refresh, "refresh", refreshSmart, "live refresh mode: smart, full, metadata-only")
	return c
}

// syncFlags carries the resolved `sync` flags into runSync.
type syncFlags struct {
	asJSON           bool
	apply            bool
	exitOnDiff       bool
	prune            bool
	yes              bool
	limitWrites      int
	platforms        string
	gitSourceOfTruth bool
	refresh          string
	verify           string
}

func newSyncCmd() *cobra.Command {
	var fl syncFlags
	var dryRun bool // accepted for symmetry; --apply is what switches on writes
	c := &cobra.Command{
		Use:   "sync",
		Short: "Reconcile configs + blueprint membership: dry-run plan by default, gated --apply to execute",
		Long: "sync reconciles the git desired state with the live tenant: CUSTOM_SETTING configs\n" +
			"(3-way, newest-wins) and each blueprint's member collections. Both halves follow the\n" +
			"same rule: by default sync is ADDITIVE, so a config that exists only in Apple is pulled\n" +
			"into git and a member attached only in Apple is adopted into its blueprint manifest;\n" +
			"with --git-source-of-truth gitops/ is the complete desired state, so the same two are\n" +
			"deleted and detached instead (both gated behind --prune).\n" +
			"Configurations are always managed; apps/packages/devices/users/groups are managed\n" +
			"only when the manifest carries that key (seed --blueprint-membership writes all six;\n" +
			"an absent key is never touched). A blueprint that exists only in git is created;\n" +
			"an ABM-only blueprint is reported for adoption, never deleted.\n" +
			"Read-only by default: it prints the plan and exits. Pass --apply to execute it —\n" +
			"every overwrite/delete archives the live version first, and you are asked to confirm\n" +
			"unless --yes (or $ABCTL_APPROVE) is set. --prune (off by default) allows deleting live\n" +
			"configs removed from git and detaching blueprint members removed from git;\n" +
			"--limit-writes N caps tenant writes as a circuit breaker. --git-source-of-truth treats\n" +
			"gitops/ as the complete desired state and applies/deletes so Apple matches it.\n" +
			"After --apply the configs just written are read back from Apple and compared to git\n" +
			"(--verify; a mismatch is reported and exits 1) — a 2xx write response alone does not\n" +
			"prove Apple persisted the profile.",
		Args: cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error { return runSync(fl) },
	}
	c.Flags().BoolVar(&fl.asJSON, "json", false, "JSON output")
	c.Flags().BoolVar(&fl.apply, "apply", false, "apply the plan to the live tenant (default: dry-run, plan only)")
	c.Flags().BoolVar(&dryRun, "dry-run", true, "plan only, no writes (default; --apply overrides)")
	c.Flags().BoolVar(&fl.exitOnDiff, "exit-on-diff", false, "exit 3 if changes are pending (dry-run, for CI gating)")
	c.Flags().BoolVar(&fl.prune, "prune", false, "allow deleting live configs removed from git (off by default)")
	c.Flags().BoolVar(&fl.yes, "yes", false, "skip the interactive confirmation (also honored: $ABCTL_APPROVE=1)")
	c.Flags().IntVar(&fl.limitWrites, "limit-writes", 0, "circuit breaker: max tenant writes this run (0 = unlimited)")
	c.Flags().StringVar(&fl.platforms, "platforms", "", "comma-separated configuredForPlatforms for created configs (default PLATFORM_MACOS)")
	c.Flags().BoolVar(&fl.gitSourceOfTruth, "git-source-of-truth", false,
		"treat gitops/ as authoritative for configs AND blueprint membership; apply implies --prune so Apple matches git")
	c.Flags().StringVar(&fl.refresh, "refresh", refreshSmart, "live refresh mode: smart, full, metadata-only")
	c.Flags().StringVar(&fl.verify, "verify", verifyTargeted,
		"post-apply verification: targeted (re-read just the configs written), full (re-read every config), none")
	return c
}

// runSync computes the 3-way plan, prints it, and — only with --apply — executes
// it: confirm (unless --yes/$ABCTL_APPROVE) → archive-before-overwrite apply →
// save the updated baseline. Dry-run is the default and writes nothing.
func runSync(fl syncFlags) error {
	if err := validateRefreshMode(fl.refresh); err != nil {
		return err
	}
	if err := validateVerifyMode(fl.verify); err != nil {
		return err
	}
	// metadata-only never populates LiveConfig.XML, and every actionable item needs it:
	// an update archives the live profile first, a pull writes those bytes into git, a
	// prune archives before deleting. Applying in this mode fails item by item and leaves
	// the baseline untouched, so the identical plan comes back next run — loud, but a
	// dead end. Refuse it here, where the remedy is one flag away.
	if fl.apply && fl.refresh == refreshMetadata {
		return fmt.Errorf("--refresh=metadata-only cannot be applied: it never fetches profile XML, "+
			"which every write needs to archive, pull or prune. Use --refresh=%s (the default) or --refresh=%s",
			refreshSmart, refreshFull)
	}
	pc, err := loadPlan(fl.gitSourceOfTruth, fl.refresh, fl.apply)
	if err != nil {
		return err
	}
	if fl.apply && fl.gitSourceOfTruth {
		fl.prune = true
	}
	planFmt := planFormat(fl.asJSON) // "", "json", or "yaml" — honors -o and --json (P7)
	machine := planFmt != ""

	if !fl.apply { // dry-run: plan only
		if err := printFullPlan(pc, planFmt); err != nil {
			return err
		}
		fmt.Fprintln(os.Stderr, "dry-run: plan only, no tenant writes (pass --apply to execute).")
		if fl.exitOnDiff && pc.hasChanges() {
			return ExitError{Code: 3}
		}
		return nil
	}

	// --apply path.
	if !pc.hasChanges() { // nothing to act on (reported-only rows, if any, still shown)
		if machine {
			return render(planFmt, map[string]any{"configs": &reconcile.Result{Outcomes: []reconcile.Outcome{}}, "blueprints": &reconcile.BlueprintResult{Outcomes: []reconcile.BlueprintOutcome{}}}, nil, nil)
		}
		return printFullPlan(pc, "")
	}
	if !machine { // show the plan as context before we write
		_ = printFullPlan(pc, "")
	}
	if !fl.yes && !envApproved() {
		ok, err := confirmApply(pc)
		if err != nil {
			return err
		}
		if !ok {
			fmt.Fprintln(os.Stderr, "aborted — no changes applied.")
			return ExitError{Code: 1}
		}
	}

	eng := &reconcile.Engine{
		Client:   pc.c,
		Archiver: cliArchiver{root: pc.tree.ArchiveDir, now: time.Now},
		Files:    pc.tree,
	}
	opts := reconcile.Opts{
		Prune:       fl.prune,
		LimitWrites: fl.limitWrites,
		Platforms:   parsePlatforms(fl.platforms),
		Progress: func(line string) {
			fmt.Fprintln(os.Stderr, line)
		},
		GitTime: gitTimeResolver(pc.tree),
	}
	// Phase 1: configs. Save the baseline even on partial success. From here on the
	// tenant has already changed, so EVERY failure exit goes through finishApply —
	// the operator must get the receipt of what was written before the error.
	res := eng.Apply(pc.plan, pc.desired, pc.live, pc.base, opts)
	if err := pc.base.Save(pc.tree.StateFile); err != nil {
		return finishApply(machine, planFmt, res, nil, nil,
			fmt.Errorf("apply ran but saving the baseline failed (re-run sync to reconcile): %w", err))
	}

	// Phase 2: blueprint membership. Recompute with config IDs from the post-apply
	// baseline so a config just created in phase 1 resolves and can be attached.
	// The other member collections' maps are reused from the plan — the config
	// phase never creates apps/packages/devices/users/groups.
	cfgIDByName := make(map[string]string, len(pc.base.Configs))
	cfgNameByID := make(map[string]string, len(pc.base.Configs))
	for name, e := range pc.base.Configs {
		if e.ABMID != "" {
			cfgIDByName[name] = e.ABMID
			cfgNameByID[e.ABMID] = name
		}
	}
	nameByID := withCollection(pc.memberNameByID, ab.CollectionConfigurations, cfgNameByID)
	idByName := withCollection(pc.memberIDByName, ab.CollectionConfigurations, cfgIDByName)

	// Post-apply verification. A 2xx write response is NOT proof the bytes landed:
	// Apple Business accepts a configuration PATCH and then silently declines to
	// persist an out-of-spec profile (confirmed live — an outer PayloadVersion != 1,
	// where the spec requires exactly 1, left the stored XML and updatedDateTime
	// frozen while every run re-planned the identical change). So the writes are
	// read back and compared to the desired bytes; the baseline can't answer this,
	// since reconcile records it from the bytes we SENT.
	written := writtenConfigs(res)
	liveBPs := pc.liveBPs
	var liveAfter []ab.LiveConfig
	switch fl.verify {
	case verifyFull:
		fmt.Fprintln(os.Stderr, "post-apply verification: full live configuration and blueprint refresh...")
		fetched, err := fetchLiveConfigsForPlan(pc.c, pc.desired, pc.base, refreshFull, true, func(line string) {
			fmt.Fprintln(os.Stderr, "post-apply verification: "+line)
		})
		if err != nil {
			return finishApply(machine, planFmt, res, nil, nil, err)
		}
		liveAfter = fetched
		for _, l := range liveAfter {
			if l.ID != "" {
				cfgIDByName[l.Name] = l.ID
				cfgNameByID[l.ID] = l.Name
			}
		}
		liveBPs, err = fetchLiveBlueprintsForPlan(pc.c, pc.bpCollections, nameByID)
		if err != nil {
			return finishApply(machine, planFmt, res, nil, nil, err)
		}
	case verifyTargeted:
		fmt.Fprintf(os.Stderr, "post-apply verification: %d of %d written configuration(s) confirmed during the apply; re-reading the rest + refreshing blueprint membership...\n",
			confirmedCount(written), len(written))
		var err error
		liveBPs, err = fetchLiveBlueprintsForPlan(pc.c, pc.bpCollections, nameByID)
		if err != nil {
			return finishApply(machine, planFmt, res, nil, nil, err)
		}
	case verifyNone:
		fmt.Fprintln(os.Stderr, "post-apply verification: the apply's own read-back still ran; this only skips the second look.")
	}
	// Costs, per mode, on top of the ONE read-back the apply already spent per config
	// written (reconcile.push): full adds none — it diffs the refresh it had to fetch
	// anyway; targeted adds one GET only for a write the apply could NOT confirm
	// (normally zero); none adds none and reaches no verdict. --verify=none does not
	// make the run silent about a dropped write — the apply itself still fails one.
	mismatches := verifyApply(fl.verify, pc.c, written, pc.desired, pc.base, liveAfter, func(line string) {
		fmt.Fprintln(os.Stderr, "post-apply verification: "+line)
	})
	reportVerification(os.Stderr, fl.verify, written, mismatches)

	bpPlan := reconcile.ComputeBlueprints(pc.bpDesired, liveBPs, idByName, membershipMode(fl.gitSourceOfTruth))
	bpRes := eng.ApplyBlueprints(bpPlan, opts, res.Writes)

	var cause error
	if len(mismatches) > 0 {
		// git and the tenant do NOT agree — or could not be shown to agree — whatever
		// the write responses said. Fail the run (after the receipt) so CI stops instead
		// of looping on the same diff.
		cause = ExitError{Code: 1}
	}
	return finishApply(machine, planFmt, res, bpRes, newVerificationReport(fl.verify, written, mismatches), cause)
}

// finishApply renders the apply receipt — the per-item table, or the machine-format
// object under --json/-o — and only THEN returns the terminating error. Every
// --apply exit path after eng.Apply goes through it: the tenant has already been
// written to by that point, so a later failure (baseline save, a verification fetch,
// a verification mismatch) must never swallow the record of WHAT was written. The
// operator previously got a single error line and no way to tell which profiles had
// changed. cause wins over the item-error exit code because it carries the diagnosis;
// a nil cause falls back to the existing contract (exit 1 on any item error).
//
// ver is the machine-readable verification verdict (nil when the run ended before
// verification could run) — without it, `--json` could describe a clean converge and
// still exit 1, with the reason only in stderr prose.
func finishApply(machine bool, planFmt string, res *reconcile.Result, bpRes *reconcile.BlueprintResult, ver *verificationReport, cause error) error {
	if bpRes == nil { // the blueprint phase never ran — keep the machine shape stable
		bpRes = &reconcile.BlueprintResult{Outcomes: []reconcile.BlueprintOutcome{}}
	}
	if machine {
		doc := map[string]any{"configs": res, "blueprints": bpRes}
		if ver != nil { // absent only when the run died before verification could run
			doc["verification"] = ver
		}
		if err := render(planFmt, doc, nil, nil); err != nil && cause == nil {
			cause = err
		}
	} else {
		printApplyResult(res)
		printBlueprintResult(bpRes)
	}
	if cause != nil {
		return cause
	}
	if res.Errors > 0 || bpRes.Errors > 0 {
		return ExitError{Code: 1}
	}
	return nil
}

// verificationReport is the post-apply read-back as DATA — the third key of the
// `--json` / `-o` receipt, next to configs and blueprints.
//
// Without it `sync --apply --json` could emit a document in which every outcome is
// "done" and errors == 0 and then exit 1, leaving the reason nowhere a machine could
// read it (the verdict was stderr prose only, which is why abgui had to grep stderr
// for the word FAILED). Consumers that decode only the two older keys are unaffected.
type verificationReport struct {
	Mode       string           `json:"mode"`     // targeted | full | none
	Written    int              `json:"written"`  // configs this run pushed to Apple
	Verified   int              `json:"verified"` // of those, shown to match git (always 0 for mode "none")
	Mismatches []verifyMismatch `json:"mismatches"`
}

// newVerificationReport pairs the verdict with the mode that produced it. An empty
// (never nil) mismatch list keeps the JSON shape stable for a consumer that indexes
// it, and "none" reports zero verified rather than claiming writes it never checked.
func newVerificationReport(mode string, written []writtenConfig, mismatches []verifyMismatch) *verificationReport {
	out := &verificationReport{Mode: mode, Written: len(written), Mismatches: []verifyMismatch{}}
	if mismatches != nil {
		out.Mismatches = mismatches
	}
	if mode != verifyNone {
		out.Verified = len(written) - len(out.Mismatches)
	}
	return out
}

// configDetailReader is the read-back half of the tenant API that post-apply
// verification needs (satisfied by *ab.Client) — an interface so the verifier is
// unit-testable without a live tenant.
type configDetailReader interface {
	FetchCustomSettingDetail(id string) (ab.LiveConfig, error)
}

// verifyMismatch is one written config that could NOT be shown to match git after
// the apply: its live bytes demonstrably differ, or they could not be read back at
// all. An unverifiable write is deliberately not counted as a verified one.
//
// Observed separates those two: true means a difference was actually SEEN (the
// stored hash differs, or the config is missing from the tenant), false means the
// question went unanswered. Only the first justifies telling an operator their
// profile did not land — see reportVerification.
type verifyMismatch struct {
	Name     string `json:"name"`
	Detail   string `json:"detail"`
	Observed bool   `json:"observed"`
}

// writtenConfig is one config this run PUSHED to Apple, carrying the verdict the
// apply's own confirming read-back already reached for it, and the configuration id
// the write used. Keeping the verdict is what stops post-apply verification from
// fetching the same profile a second time; keeping the id is what lets it fetch the
// ones the apply could NOT confirm — those have no baseline entry to look the id up
// in, because reconcile deliberately does not record one for an unconfirmed write.
type writtenConfig struct {
	Name     string
	ABMID    string
	Verified reconcile.Verification
}

// writtenConfigs lists the configs this run actually PUSHED to Apple: completed
// create/update outcomes only. pull/delete-git outcomes touch the git tree, not the
// tenant, and a pruned config is gone by design — none of them have desired bytes
// to read back.
func writtenConfigs(res *reconcile.Result) []writtenConfig {
	if res == nil {
		return nil
	}
	out := make([]writtenConfig, 0, len(res.Outcomes))
	for _, o := range res.Outcomes {
		if o.Status == "done" && (o.Action == reconcile.Create || o.Action == reconcile.Update) {
			out = append(out, writtenConfig{Name: o.Name, ABMID: o.ABMID, Verified: o.Verified})
		}
	}
	return out
}

// confirmedCount reports how many writes the apply already read back and matched.
func confirmedCount(written []writtenConfig) int {
	n := 0
	for _, w := range written {
		if w.Verified == reconcile.VerifyConfirmed {
			n++
		}
	}
	return n
}

// verifyApply dispatches the post-apply read-back by mode: full compares the
// written configs against the live refresh already fetched for id harvesting,
// targeted re-reads the configs whose write is not already confirmed, none
// verifies nothing.
func verifyApply(mode string, r configDetailReader, written []writtenConfig, desired map[string][]byte, base *state.State, liveAfter []ab.LiveConfig, progress func(string)) []verifyMismatch {
	switch mode {
	case verifyFull:
		return verifyAgainstLive(written, desired, liveAfter)
	case verifyTargeted:
		return verifyWrittenConfigs(r, written, desired, base, progress)
	}
	return nil // verifyNone — the operator opted out; no reads, no verdict
}

// verifyWrittenConfigs re-reads the configs this run wrote whose write is not
// ALREADY confirmed. The apply confirms each write as it makes it (reconcile.push
// reads the profile back before it will record a baseline), so re-fetching a
// config it already matched byte-for-byte would ask Apple the same question twice
// and could never return a different answer — pure duplicate traffic, and AGENT.md
// is explicit that Apple rate-limits hard. What is left is the write the apply
// could NOT confirm (its read-back failed, or returned no XML): that one is worth a
// second attempt, because nobody has an answer for it yet.
//
// Targeted also stays targeted: never a fan-out over every configuration in the
// tenant, because re-listing 39 profiles to confirm one write is exactly the chatty
// traffic AGENT.md forbids.
func verifyWrittenConfigs(r configDetailReader, written []writtenConfig, desired map[string][]byte, base *state.State, progress func(string)) []verifyMismatch {
	if r == nil {
		return nil
	}
	pending := make([]writtenConfig, 0, len(written))
	for _, w := range written {
		if w.Verified != reconcile.VerifyConfirmed {
			pending = append(pending, w)
		}
	}
	var out []verifyMismatch
	for i, w := range pending {
		want, ok := desired[w.Name]
		if !ok { // a tenant write with no git source shouldn't exist — nothing to compare
			continue
		}
		// The apply's own id first, the baseline only as a fallback. An unconfirmed
		// CREATE has no baseline entry at all (reconcile writes one only for a write it
		// verified), so deriving the id from the baseline made verification impossible
		// in exactly the case it exists for — and reported that as a dropped write.
		id := w.ABMID
		if id == "" && base != nil {
			id = base.Configs[w.Name].ABMID
		}
		if id == "" {
			out = append(out, verifyMismatch{Name: w.Name, Detail: "no configuration id was recorded for the write — it cannot be re-read from Apple"})
			continue
		}
		if progress != nil {
			progress(fmt.Sprintf("re-reading unconfirmed configuration %d/%d: %s", i+1, len(pending), w.Name))
		}
		live, err := r.FetchCustomSettingDetail(id)
		if err != nil {
			// A failed read-back is not evidence of a good write. Record it and keep
			// going, so one flaky GET neither aborts the blueprint phase nor hides the
			// verdict on the other writes.
			out = append(out, verifyMismatch{Name: w.Name, Detail: "re-reading the configuration from Apple failed: " + err.Error()})
			continue
		}
		if m, bad := compareWritten(w.Name, want, live); bad {
			out = append(out, m)
		}
	}
	return out
}

// verifyAgainstLive compares the written configs against the full post-apply
// refresh (--verify=full). That fetch previously served only to harvest ids for
// membership resolution — the live bytes it already carries are the read-back.
// It re-checks every written config, including ones the apply already confirmed:
// the bytes are already in hand (the refresh was paid for regardless), so the
// second opinion is free — unlike targeted, it costs no extra request.
func verifyAgainstLive(written []writtenConfig, desired map[string][]byte, liveAfter []ab.LiveConfig) []verifyMismatch {
	byName := make(map[string]ab.LiveConfig, len(liveAfter))
	for _, l := range liveAfter {
		byName[l.Name] = l
	}
	var out []verifyMismatch
	for _, w := range written {
		want, ok := desired[w.Name]
		if !ok {
			continue
		}
		live, found := byName[w.Name]
		if !found {
			// Observed: the tenant listed its configurations and this one — which this
			// run just wrote — was not among them. That IS a difference from desired.
			out = append(out, verifyMismatch{Name: w.Name, Observed: true,
				Detail: "the configuration is absent from the post-apply live refresh"})
			continue
		}
		if m, bad := compareWritten(w.Name, want, live); bad {
			out = append(out, m)
		}
	}
	return out
}

// compareWritten is the proof itself: the desired bytes vs what Apple stored.
func compareWritten(name string, want []byte, live ab.LiveConfig) (verifyMismatch, bool) {
	got := live.ContentHash()
	if got == "" {
		return verifyMismatch{Name: name, Detail: "Apple returned no profile XML on the read-back — the write could not be confirmed"}, true
	}
	if got == hash.Raw(want) {
		return verifyMismatch{}, false
	}
	detail := "live content hash " + shortHash(got) + " != desired " + shortHash(hash.Raw(want))
	if live.Updated != "" {
		// A frozen updatedDateTime is Apple's tell that the PATCH was accepted (2xx)
		// and then dropped; it is the fastest thing for an operator to confirm.
		detail += "; live updatedDateTime " + live.Updated
	}
	return verifyMismatch{Name: name, Detail: detail, Observed: true}, true
}

func shortHash(h string) string {
	if len(h) > 12 {
		return h[:12]
	}
	return h
}

// reportVerification prints the read-back verdict to w (stderr in the command).
// The per-config FAILED line is the wording operators grep for and CI matches on
// (abgui mines the same word out of stderr — see SyncFailure.verdictLines), so both
// kinds of failure carry it — but they say DIFFERENT things: a difference that was
// actually observed is reported as "still differs", while a read-back that produced
// no answer is reported as "could NOT be verified". Stating a difference nobody
// measured, and attaching the PayloadVersion hint to it, sends the operator hunting
// for a defect in a profile that may well have landed perfectly.
//
// The trailing hint names the failure mode this check exists for — Apple answers 2xx
// and silently drops a profile whose top-level PayloadVersion isn't exactly 1, which
// makes a GitOps loop re-plan the identical change forever — so it is printed only
// when a real difference was seen.
func reportVerification(w io.Writer, mode string, written []writtenConfig, mismatches []verifyMismatch) {
	if mode == verifyNone {
		return
	}
	if len(mismatches) == 0 {
		if len(written) > 0 {
			_, _ = fmt.Fprintf(w, "post-apply verification: %d written configuration(s) confirmed live on Apple Business.\n", len(written))
		}
		return
	}
	observed := 0
	for _, m := range mismatches {
		if m.Observed {
			observed++
			_, _ = fmt.Fprintf(w, "post-apply verification FAILED: %s still differs from desired on Apple Business\n", m.Name)
		} else {
			_, _ = fmt.Fprintf(w, "post-apply verification FAILED: %s could NOT be verified — Apple was not asked, or did not answer, with a comparable profile\n", m.Name)
		}
		if m.Detail != "" {
			_, _ = fmt.Fprintf(w, "  %s\n", m.Detail)
		}
	}
	if observed > 0 {
		_, _ = fmt.Fprintf(w, "post-apply verification: %d of %d written configuration(s) did not land. Apple can accept a PATCH with 2xx and silently not persist an out-of-spec profile — check the top-level (outer) PayloadVersion is exactly 1.\n",
			observed, len(written))
	}
	if unread := len(mismatches) - observed; unread > 0 {
		_, _ = fmt.Fprintf(w, "post-apply verification: %d of %d written configuration(s) could not be checked, so this run cannot claim the tenant matches git — re-run sync to check them.\n",
			unread, len(written))
	}
}

func printBlueprintResult(res *reconcile.BlueprintResult) {
	if len(res.Outcomes) == 0 {
		return
	}
	rows := make([][]string, 0, len(res.Outcomes))
	for _, o := range res.Outcomes {
		rows = append(rows, []string{o.Status, string(o.Action), o.Blueprint, o.Config, o.Detail})
	}
	fmt.Println()
	printTable([]string{"STATUS", "BP-ACTION", "BLUEPRINT", "MEMBER", "DETAIL"}, rows)
	fmt.Fprintf(os.Stderr, "blueprints: %d write(s), %d skipped, %d error(s)\n", res.Writes, res.Skipped, res.Errors)
}

// envApproved reports whether $ABCTL_APPROVE holds an affirmative value. Parsing
// the value (not mere presence) means ABCTL_APPROVE=0/false/no correctly does NOT
// bypass the write-confirmation gate — only a truthy value does.
func envApproved() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("ABCTL_APPROVE"))) {
	case "1", "true", "yes", "y", "on":
		return true
	}
	return false
}

// confirmApply prompts on stdin; only a literal "yes" proceeds. It splits the
// count by WHERE each change lands: not every planned row is a tenant write —
// pulls write git, and so does an adopt — and a gate that calls a local file
// write "a change to the LIVE tenant" trains people to stop reading it.
func confirmApply(pc *planCtx) (bool, error) {
	tenant, local := pc.applyCounts()
	switch {
	case tenant == 0:
		fmt.Fprintf(os.Stderr, "\nApply %d change(s) to LOCAL files in gitops/ only (nothing is written to Apple Business)? Type 'yes' to proceed: ", local)
	case local == 0:
		fmt.Fprintf(os.Stderr, "\nApply %d change(s) to the LIVE Apple Business tenant? Type 'yes' to proceed: ", tenant)
	default:
		fmt.Fprintf(os.Stderr, "\nApply %d change(s) — %d to the LIVE Apple Business tenant, %d to local files in gitops/? Type 'yes' to proceed: ",
			tenant+local, tenant, local)
	}
	sc := bufio.NewScanner(os.Stdin)
	if !sc.Scan() {
		return false, sc.Err()
	}
	return strings.EqualFold(strings.TrimSpace(sc.Text()), "yes"), nil
}

// applyCounts splits the actionable plan into tenant writes and local (gitops/)
// writes. The local side is the pull family — a config that only exists in ABM,
// or one deleted there — plus every blueprint adopt row.
func (pc *planCtx) applyCounts() (tenant, local int) {
	for _, it := range pc.plan.Items {
		switch it.Action {
		case reconcile.Pull, reconcile.PullNew, reconcile.DeleteGit:
			local++
		default:
			tenant++
		}
	}
	for _, it := range pc.bpPlan.Items {
		if !it.IsActionable() {
			continue
		}
		if it.Action.IsAdopt() {
			local++
		} else {
			tenant++
		}
	}
	return tenant, local
}

func printApplyResult(res *reconcile.Result) {
	if len(res.Outcomes) > 0 {
		rows := make([][]string, 0, len(res.Outcomes))
		for _, o := range res.Outcomes {
			rows = append(rows, []string{o.Status, string(o.Action), o.Name, o.Detail})
		}
		printTable([]string{"STATUS", "ACTION", "NAME", "DETAIL"}, rows)
	}
	fmt.Fprintf(os.Stderr, "applied: %d write(s), %d skipped, %d error(s)\n", res.Writes, res.Skipped, res.Errors)
}

// cliArchiver adapts internal/archive to the reconcile.Archiver interface.
type cliArchiver struct {
	root string
	now  func() time.Time
}

func (a cliArchiver) Archive(name, reason string, xml []byte, meta map[string]string) (string, error) {
	return archive.Write(a.root, name, reason, xml, meta, a.now())
}

// gitTimeResolver returns the git-side timestamp of a config for newest-wins
// conflict resolution. When the working-tree file is CLEAN (matches HEAD) its last
// commit time is used — authoritative across machines. When it is dirty (modified,
// staged, or untracked — including a still-gitignored gitops/ tree) the commit time
// is stale, so the file's mtime (the real time of the uncommitted edit) is used
// instead; otherwise a local edit could silently lose a conflict to the console.
// ok=false only when the file is absent — the engine then skips the conflict
// rather than guessing.
func gitTimeResolver(t *gitops.Tree) func(string) (time.Time, bool) {
	return func(name string) (time.Time, bool) {
		mtime, haveMtime := time.Time{}, false
		if fi, err := os.Stat(filepath.Join(t.LibDir, name)); err == nil {
			mtime, haveMtime = fi.ModTime(), true
		}
		// A clean, committed file → use its commit time. A dirty/untracked file →
		// prefer mtime (git log would report a stale pre-edit commit time).
		if st, err := exec.Command("git", "-C", t.LibDir, "status", "--porcelain", "--", name).Output(); err == nil {
			dirty := strings.TrimSpace(string(st)) != ""
			if !dirty {
				if out, err := exec.Command("git", "-C", t.LibDir, "log", "-1", "--format=%cI", "--", name).Output(); err == nil {
					if s := strings.TrimSpace(string(out)); s != "" {
						if ct, err := time.Parse(time.RFC3339, s); err == nil {
							return ct, true
						}
					}
				}
			}
		}
		if haveMtime { // dirty, untracked, or git unavailable → the on-disk edit time
			return mtime, true
		}
		return time.Time{}, false
	}
}

func parsePlatforms(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func newAPICmd() *cobra.Command {
	var method, input string
	var fields []string
	var yes bool
	c := &cobra.Command{
		Use:   "api <path>",
		Short: "Raw authenticated request (GET by default; non-GET writes are gated)",
		Long: "api is the escape hatch to the Apple Business API. GET is read-only and unrestricted;\n" +
			"any other method is a WRITE, gated behind --yes/$ABCTL_APPROVE. Build a JSON body with\n" +
			"repeated -F key=value (@file reads the value from a file), or send a whole body file with\n" +
			"--input (or '-' for stdin). The leading /v1/ is optional.",
		Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error { return runAPI(method, a[0], fields, input, yes) },
	}
	c.Flags().StringVarP(&method, "method", "X", "GET", "HTTP method")
	c.Flags().StringArrayVarP(&fields, "field", "F", nil, "body field key=value (@file for value-from-file); builds a flat JSON body")
	c.Flags().StringVar(&input, "input", "", "send this file as the raw request body ('-' = stdin); overrides -F")
	c.Flags().BoolVar(&yes, "yes", false, "confirm a non-GET (write) request (also: $ABCTL_APPROVE=1)")
	return c
}

func runSeed(withMembership bool) error {
	c, cfg, err := mustClient()
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "fetching live configurations...")
	live, err := c.FetchCustomSettings()
	if err != nil {
		return err
	}
	t := gitops.NewTree(cfg.EnvDir)
	st := &state.State{Configs: map[string]state.Entry{}}
	idToName := map[string]string{}
	for _, l := range live {
		if err := t.WriteConfig(l.Name, []byte(l.XML)); err != nil {
			return err
		}
		st.Configs[l.Name] = state.Entry{ABMID: l.ID, Hash: hash.Raw([]byte(l.XML)), UpdatedDateTime: l.Updated}
		idToName[l.ID] = l.Name
	}
	if err := st.Save(t.StateFile); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "fetching blueprints…")
	collections := []string{ab.CollectionConfigurations}
	nameByID := map[string]map[string]string{ab.CollectionConfigurations: idToName}
	if withMembership {
		collections = ab.BlueprintCollections
		fmt.Fprintln(os.Stderr, "resolving blueprint member names (apps/packages/devices/users/groups)…")
		maps, _, err := c.FetchBlueprintMemberMaps(ab.BlueprintCollections[1:], nil)
		if err != nil {
			return fmt.Errorf("seed: resolving blueprint member names: %w", err)
		}
		for col, m := range maps {
			nameByID[col] = m
		}
	}
	// A plain re-seed refreshes identity + configurations only — the five optional
	// member keys carry the operator's declared desired state, so they are carried
	// over from the existing manifests rather than silently dropped (unmanaged).
	existing, err := t.LoadBlueprints()
	if err != nil {
		return fmt.Errorf("seed: reading existing blueprint manifests: %w", err)
	}
	// Propagate a membership-fetch error rather than silently seeding an empty
	// membership: a git-authoritative `configurations: []` written from a failed
	// fetch would make a later `sync --apply --prune` detach every real member.
	bps, err := c.FetchBlueprints(collections, nameByID, nil)
	if err != nil {
		return fmt.Errorf("seed: fetching blueprint membership: %w", err)
	}
	for _, bp := range bps {
		spec := gitops.BlueprintSpec{
			Name:           bp.Name,
			ID:             bp.ID,
			Description:    bp.Description,
			Configurations: bp.Configs,
		}
		if withMembership { // write all five optional keys — present (even empty) = managed
			spec.Apps = managedList(bp.Apps)
			spec.Packages = managedList(bp.Packages)
			spec.Devices = managedList(bp.Devices)
			spec.Users = managedList(bp.Users)
			spec.Groups = managedList(bp.Groups)
		} else if prev, ok := existing[bp.Name]; ok { // preserve managed keys as-is
			spec.Apps, spec.Packages, spec.Devices, spec.Users, spec.Groups =
				prev.Apps, prev.Packages, prev.Devices, prev.Users, prev.Groups
		}
		if err := t.WriteBlueprintSpec(spec); err != nil {
			return err
		}
	}
	fmt.Printf("seeded %d configuration(s) → %s\n", len(live), rel(t.LibDir))
	fmt.Printf("baseline           → %s\n", rel(t.StateFile))
	fmt.Printf("%d blueprint(s)     → %s\n", len(bps), rel(t.BlueprintsDir))
	if withMembership {
		fmt.Fprintln(os.Stderr, "blueprint manifests now MANAGE all six member collections (delete a key to unmanage it).")
	}
	fmt.Fprintln(os.Stderr, "review the tree, then `git add gitops/` to commit the desired state + baseline.")
	return nil
}

// managedList pins a live member list into a manifest key: the returned pointer
// is always non-nil, so the key is written even when empty (`key: []`) — which
// is exactly what makes the collection MANAGED for future syncs.
func managedList(names []string) *[]string {
	if names == nil {
		names = []string{}
	}
	return &names
}

func validateRefreshMode(mode string) error {
	switch mode {
	case refreshSmart, refreshFull, refreshMetadata:
		return nil
	default:
		return fmt.Errorf("invalid --refresh %q (want smart, full, or metadata-only)", mode)
	}
}

func validateVerifyMode(mode string) error {
	switch mode {
	case verifyTargeted, verifyFull, verifyNone:
		return nil
	default:
		return fmt.Errorf("invalid --verify %q (want targeted, full, or none)", mode)
	}
}

// willWrite says whether THIS run may actually pull, archive or prune. It gates the
// per-config profile fetch in smart mode: a dry run compares nothing it keeps, so paying
// a request per live-only config buys a hash that is thrown away.
func fetchLiveConfigsForPlan(c *ab.Client, desired map[string][]byte, base *state.State, refresh string, willWrite bool, progress func(string)) ([]ab.LiveConfig, error) {
	switch refresh {
	case refreshFull:
		return c.FetchCustomSettingsWithProgress(progress)
	case refreshMetadata:
		live, err := c.FetchCustomSettingsMetadata(progress)
		if err != nil {
			return nil, err
		}
		reuseCachedLiveHashes(live, base, progress)
		return live, nil
	case refreshSmart:
		return fetchLiveConfigsSmart(c, desired, base, willWrite, progress)
	default:
		return nil, fmt.Errorf("invalid refresh mode %q", refresh)
	}
}

// The git-source-of-truth flag is deliberately NOT a parameter: it used to force a detail
// fetch for every live-only config, but under that mode such a config is a DELETE, and a
// delete needs the bytes only when the run will actually archive them — which is precisely
// what willWrite already says. Two flags meaning one thing is how the dry-run path ended up
// fetching profiles it discarded.
func fetchLiveConfigsSmart(c *ab.Client, desired map[string][]byte, base *state.State, willWrite bool, progress func(string)) ([]ab.LiveConfig, error) {
	live, err := c.FetchCustomSettingsMetadata(progress)
	if err != nil {
		return nil, err
	}
	fetched, cached := 0, 0
	for i := range live {
		l := &live[i]
		baseEntry, hasBase := base.Configs[l.Name]
		desiredXML, hasDesired := desired[l.Name]
		if hasBase && baseEntry.ABMID == l.ID && sameAppleTime(baseEntry.UpdatedDateTime, l.Updated) {
			l.Hash = baseEntry.Hash
		}
		// Fetch a profile only where its BYTES are actually used.
		//
		// The order matters: an unconditional `needDetail := l.Hash == ""` first would make
		// every other condition unreachable on an unseeded workspace, because with no baseline
		// nothing has a cached hash. That is precisely the case worth optimizing, so the
		// live-only branch has to be the one that decides.
		needDetail := false
		switch {
		case hasDesired:
			// Present on both sides, so the plan is decided by comparing hashes: the live
			// hash must be real. Refetch when it was never cached, and when the cached hash
			// disagrees with git — that disagreement is what an apply would act on, so it is
			// confirmed against the actual bytes rather than trusted.
			needDetail = l.Hash == "" || hash.Raw(desiredXML) != l.Hash
		case willWrite:
			// Live-only. The PLAN never needs these bytes — reconcile.Compute picks pull-new
			// vs delete from the BASELINE, not from a hash — but an apply does, to write them
			// into git or to archive before deleting. A dry run (`diff`, the CI plan job,
			// `sync` without --apply) writes and archives nothing, and paying one request per
			// live-only config to compute a hash it then discards is what turned the FAST
			// mode into 1+N requests where `--refresh=full` is a single list call.
			needDetail = true
		}
		if !needDetail {
			cached++
			if progress != nil {
				progress("reusing cached profile hash: " + l.Name)
			}
			continue
		}
		if progress != nil {
			progress(fmt.Sprintf("fetching profile XML detail %d/%d: %s", i+1, len(live), l.Name))
		}
		full, err := c.FetchCustomSettingDetail(l.ID)
		if err != nil {
			return nil, err
		}
		live[i] = full
		fetched++
	}
	if progress != nil {
		progress(fmt.Sprintf("smart refresh reused %d cached profile hash(es), fetched %d profile detail(s)", cached, fetched))
	}
	return live, nil
}

func reuseCachedLiveHashes(live []ab.LiveConfig, base *state.State, progress func(string)) {
	reused := 0
	for i := range live {
		if b, ok := base.Configs[live[i].Name]; ok && b.ABMID == live[i].ID && sameAppleTime(b.UpdatedDateTime, live[i].Updated) {
			live[i].Hash = b.Hash
			reused++
		}
	}
	if progress != nil {
		progress(fmt.Sprintf("metadata-only refresh reused %d cached profile hash(es); uncached profiles have unknown content", reused))
	}
}

func sameAppleTime(a, b string) bool {
	if a == "" || b == "" {
		return a == b
	}
	at, errA := time.Parse(time.RFC3339Nano, a)
	bt, errB := time.Parse(time.RFC3339Nano, b)
	if errA == nil && errB == nil {
		return at.Equal(bt)
	}
	return a == b
}

// planCtx bundles everything a reconcile needs: the client, the on-disk tree, the
// three inputs to the diff (git desired / committed baseline / live), and the plan.
type planCtx struct {
	c       *ab.Client
	cfg     *config.Config
	tree    *gitops.Tree
	desired map[string][]byte
	base    *state.State
	live    []ab.LiveConfig
	plan    *reconcile.Plan
	// blueprints
	bpDesired     map[string]gitops.BlueprintSpec
	liveBPs       []ab.LiveBlueprint
	cfgIDByName   map[string]string // config name → ABM id (from live, pre-apply)
	bpCollections []string          // member collections the plan fetches: configurations + every collection some manifest manages
	// memberNameByID / memberIDByName resolve member id ↔ display name per
	// collection. The configurations entry is ownership-scoped (baseline); the
	// other collections are full-tenant maps, fetched lazily (see bpCollections).
	memberNameByID map[string]map[string]string
	memberIDByName map[string]map[string]string
	bpPlan         *reconcile.BlueprintPlan
}

// loadPlan reads git desired + baseline + live for both configs and blueprints and
// computes the two 3-way plans. Shared by diff and sync so both see an identical plan.
func loadPlan(gitSourceOfTruth bool, refresh string, willWrite bool) (*planCtx, error) {
	fmt.Fprintln(os.Stderr, "building plan: loading connection and workspace settings...")
	c, cfg, err := mustClient()
	if err != nil {
		return nil, err
	}
	t := gitops.NewTree(cfg.EnvDir)
	fmt.Fprintln(os.Stderr, "building plan: reading desired configuration profiles from gitops/lib...")
	desired, err := t.LoadDesired()
	if err != nil {
		return nil, err
	}
	fmt.Fprintf(os.Stderr, "building plan: loaded %d desired configuration profile(s).\n", len(desired))
	fmt.Fprintln(os.Stderr, "building plan: reading sync baseline from gitops/state...")
	base, err := state.Load(t.StateFile)
	if err != nil {
		return nil, err
	}
	fmt.Fprintf(os.Stderr, "building plan: loaded %d baseline configuration record(s).\n", len(base.Configs))
	fmt.Fprintf(os.Stderr, "building plan: fetching live configurations from Apple (%s refresh)...\n", refresh)
	live, err := fetchLiveConfigsForPlan(c, desired, base, refresh, willWrite, func(line string) {
		fmt.Fprintln(os.Stderr, "building plan: "+line)
	})
	if err != nil {
		return nil, err
	}
	fmt.Fprintf(os.Stderr, "building plan: fetched %d live CUSTOM_SETTING configuration(s).\n", len(live))
	// Resolve config name↔id from the committed BASELINE (the configs abctl manages),
	// not from every live config. This keeps the blueprint detach gate (C5: never
	// touch a config we don't own) consistent between `diff` and `--apply`, and lets
	// a console-created config stay an opaque id in live blueprint membership so it is
	// never proposed for detach.
	cfgIDByName := make(map[string]string, len(base.Configs))
	cfgNameByID := make(map[string]string, len(base.Configs))
	for name, e := range base.Configs {
		if e.ABMID != "" {
			cfgIDByName[name] = e.ABMID
			cfgNameByID[e.ABMID] = name
		}
	}
	if gitSourceOfTruth {
		for _, l := range live {
			if l.ID != "" {
				cfgIDByName[l.Name] = l.ID
				cfgNameByID[l.ID] = l.Name
			}
		}
	}
	fmt.Fprintf(os.Stderr, "building plan: resolved %d managed configuration id(s).\n", len(cfgIDByName))
	fmt.Fprintln(os.Stderr, "building plan: reading desired blueprint manifests from gitops/blueprints...")
	bpDesired, err := t.LoadBlueprints()
	if err != nil {
		return nil, err
	}
	fmt.Fprintf(os.Stderr, "building plan: loaded %d desired blueprint manifest(s).\n", len(bpDesired))
	// Resolve member id↔name maps LAZILY: only for the collections some manifest
	// actually manages (an unmanaged collection costs no tenant list call).
	bpCollections := managedBlueprintCollections(bpDesired)
	memberNameByID := map[string]map[string]string{ab.CollectionConfigurations: cfgNameByID}
	if len(bpCollections) > 1 {
		fmt.Fprintf(os.Stderr, "building plan: resolving blueprint member names for managed collection(s): %s...\n",
			strings.Join(bpCollections[1:], ", "))
		maps, aliases, err := c.FetchBlueprintMemberMaps(bpCollections[1:], func(line string) {
			fmt.Fprintln(os.Stderr, "building plan: "+line)
		})
		if err != nil {
			return nil, err
		}
		for col, m := range maps {
			memberNameByID[col] = m
		}
		// Manifest entries may use an alias (user's managed Apple Account, serial
		// case) — rewrite them to the canonical live names before diffing.
		canonicalizeBlueprintMembers(bpDesired, aliases)
	}
	memberIDByName := invertMemberMaps(memberNameByID)
	memberIDByName[ab.CollectionConfigurations] = cfgIDByName // ownership-scoped, not inverted from live
	liveBPs, err := fetchLiveBlueprintsForPlan(c, bpCollections, memberNameByID)
	if err != nil {
		return nil, err
	}
	fmt.Fprintln(os.Stderr, "building plan: computing configuration drift...")
	var cfgPlan *reconcile.Plan
	if gitSourceOfTruth {
		fmt.Fprintln(os.Stderr, "building plan: git-source-of-truth mode is enabled; live-only Apple configs will not be pulled into git.")
		cfgPlan = reconcile.ComputeGitSourceOfTruth(desired, live)
	} else {
		cfgPlan = reconcile.Compute(desired, base, live)
	}
	fmt.Fprintf(os.Stderr, "building plan: computed %d configuration change(s).\n", len(cfgPlan.Items))
	fmt.Fprintln(os.Stderr, "building plan: computing blueprint membership drift...")
	bpPlan := reconcile.ComputeBlueprints(bpDesired, liveBPs, memberIDByName, membershipMode(gitSourceOfTruth))
	fmt.Fprintf(os.Stderr, "building plan: computed %d blueprint membership change(s).\n", len(bpPlan.Items))
	return &planCtx{
		c: c, cfg: cfg, tree: t, desired: desired, base: base, live: live,
		plan:           cfgPlan,
		bpDesired:      bpDesired,
		liveBPs:        liveBPs,
		cfgIDByName:    cfgIDByName,
		bpCollections:  bpCollections,
		memberNameByID: memberNameByID,
		memberIDByName: memberIDByName,
		bpPlan:         bpPlan,
	}, nil
}

// membershipMode maps --git-source-of-truth onto the blueprint half of the
// reconcile, so ONE flag means the same thing on both sides: with it, git is the
// complete desired state (an ABM-only config is deleted, an ABM-only member is
// detached); without it, sync is additive (an ABM-only config is pulled into
// git, an ABM-only member is adopted into its manifest).
func membershipMode(gitSourceOfTruth bool) reconcile.MembershipMode {
	if gitSourceOfTruth {
		return reconcile.GitAuthoritative
	}
	return reconcile.Bidirectional
}

// managedBlueprintCollections returns the member collections the plan must
// fetch: configurations always (Phase-1 semantics), plus every optional
// collection at least one manifest manages — in ab.BlueprintCollections order,
// so the fetch plan is deterministic.
func managedBlueprintCollections(specs map[string]gitops.BlueprintSpec) []string {
	out := []string{ab.CollectionConfigurations}
	for _, col := range ab.BlueprintCollections {
		if col == ab.CollectionConfigurations {
			continue
		}
		for _, s := range specs {
			if _, managed := s.Members(col); managed {
				out = append(out, col)
				break
			}
		}
	}
	return out
}

// invertMemberMaps flips id→name maps into name→id maps, per collection. Names
// are canonical and non-empty by construction (see ab.FetchBlueprintMemberMaps),
// so a git manifest addresses members by exactly the names live membership
// resolves to — but they are NOT necessarily unique: two tenant resources can
// share a display name (e.g. the iOS and macOS builds of one app). Resolving a
// shared name would pick an id nondeterministically, so it is kept with an
// EMPTY id instead: the plan then blocks its attach and never plans its detach
// (see reconcile.diffMembership), mirroring the imperative resolvers' ambiguity
// errors rather than writing against an arbitrary duplicate.
func invertMemberMaps(nameByID map[string]map[string]string) map[string]map[string]string {
	out := make(map[string]map[string]string, len(nameByID))
	for col, m := range nameByID {
		inv := make(map[string]string, len(m))
		for id, name := range m {
			if _, dup := inv[name]; dup {
				inv[name] = "" // ambiguous — blocked, never resolved to one id
				continue
			}
			inv[name] = id
		}
		out[col] = inv
	}
	return out
}

// canonicalizeBlueprintMembers rewrites manifest member entries to the
// canonical display name live membership resolves to, using the alias maps
// from ab.FetchBlueprintMemberMaps (users: a managed-Apple-Account alias or
// address case variant → the canonical email; devices: serial case). Without
// this, a manifest addressing a member by an alias the imperative resolvers
// accept would never match the canonical live name byte-for-byte — sync would
// plan a blocked attach for the alias AND a --prune detach of the very member
// the manifest declares. An alias that is ambiguous (maps to "") or unknown is
// left untouched.
func canonicalizeBlueprintMembers(specs map[string]gitops.BlueprintSpec, canonicalByAlias map[string]map[string]string) {
	for _, spec := range specs {
		for col, byAlias := range canonicalByAlias {
			if len(byAlias) == 0 {
				continue
			}
			names, managed := spec.Members(col)
			if !managed {
				continue
			}
			for i, n := range names {
				if canon := byAlias[strings.ToLower(n)]; canon != "" && canon != n {
					names[i] = canon
				}
			}
		}
	}
}

// withCollection returns a shallow copy of the per-collection maps with one
// collection's map replaced (the replacement is stored by reference, so later
// mutations of it — e.g. the verify=full config-map refresh — are visible).
func withCollection(maps map[string]map[string]string, col string, m map[string]string) map[string]map[string]string {
	out := make(map[string]map[string]string, len(maps)+1)
	for k, v := range maps {
		out[k] = v
	}
	out[col] = m
	return out
}

func fetchLiveBlueprintsForPlan(c *ab.Client, collections []string, nameByID map[string]map[string]string) ([]ab.LiveBlueprint, error) {
	fmt.Fprintln(os.Stderr, "building plan: fetching live blueprints from Apple...")
	return c.FetchBlueprints(collections, nameByID, func(line string) {
		fmt.Fprintln(os.Stderr, "building plan: "+line)
	})
}

// hasChanges reports whether sync has anything to *act on* — config changes or
// reconcilable (attach/detach) blueprint changes. Reported-only blueprint
// rows (blueprint-new / blueprint-adopt) are excluded so they don't force
// --exit-on-diff to loop or make --apply confirm-then-do-nothing.
func (pc *planCtx) hasChanges() bool {
	return pc.plan.HasChanges() || pc.bpPlan.HasReconcilableChanges()
}

// printFullPlan renders both plans: a combined JSON object under --json, else a
// config table followed by a blueprint table. It shows ALL items, including
// reported-only rows (which are useful even though sync won't apply them).
func printFullPlan(pc *planCtx, format string) error {
	if format == "json" || format == "yaml" {
		return render(format, map[string]any{"configs": asList(pc.plan.Items), "blueprints": asList(pc.bpPlan.Items)}, nil, nil)
	}
	if !pc.plan.HasChanges() && !pc.bpPlan.HasChanges() {
		fmt.Println("in sync — no changes.")
		return nil
	}
	if pc.plan.HasChanges() {
		rows := make([][]string, 0, len(pc.plan.Items))
		for _, it := range pc.plan.Items {
			rows = append(rows, []string{string(it.Action), it.Name, it.Detail})
		}
		printTable([]string{"ACTION", "NAME", "DETAIL"}, rows)
	}
	if pc.bpPlan.HasChanges() {
		if pc.plan.HasChanges() {
			fmt.Println()
		}
		rows := make([][]string, 0, len(pc.bpPlan.Items))
		for _, it := range pc.bpPlan.Items {
			rows = append(rows, []string{string(it.Action), it.Blueprint, it.Config, it.Detail})
		}
		printTable([]string{"BP-ACTION", "BLUEPRINT", "MEMBER", "DETAIL"}, rows)
	}
	fmt.Fprintf(os.Stderr, "%d config change(s), %d blueprint change(s)\n", len(pc.plan.Items), len(pc.bpPlan.Items))
	return nil
}

func runAPI(method, path string, fields []string, input string, yes bool) error {
	method = strings.ToUpper(method)
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	// The API base already includes the version segment (…/v1/), so accept a path
	// with or without a leading "/v1/": `abctl api /v1/users` and `abctl api users` both work.
	path = strings.TrimPrefix(strings.TrimLeft(path, "/"), "v1/")

	var st int
	var b []byte
	if method == "GET" {
		st, b, err = c.Raw("GET", path, nil)
	} else {
		if !yes && !envApproved() {
			ok, cErr := confirmWrite(method + " /v1/" + path)
			if cErr != nil || !ok {
				fmt.Fprintln(os.Stderr, "aborted.")
				return ExitError{Code: 1}
			}
		}
		payload, pErr := apiBody(fields, input)
		if pErr != nil {
			return pErr
		}
		st, b, err = c.APIWrite(method, path, payload)
	}
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "HTTP %d\n", st)
	fmt.Println(string(b))
	if st < 200 || st >= 300 {
		return ExitError{Code: 1}
	}
	return nil
}

// apiBody builds the request body for `api`: the raw --input file (as-is JSON), or
// a flat JSON object from -F key=value pairs (@file reads the value from a file).
func apiBody(fields []string, input string) (any, error) {
	if input != "" {
		raw, err := readFileArg(input)
		if err != nil {
			return nil, err
		}
		return json.RawMessage(raw), nil
	}
	if len(fields) == 0 {
		return nil, nil
	}
	m := map[string]any{}
	for _, f := range fields {
		k, v, ok := strings.Cut(f, "=")
		if !ok {
			return nil, fmt.Errorf("bad -F %q (want key=value)", f)
		}
		if strings.HasPrefix(v, "@") {
			raw, err := os.ReadFile(v[1:])
			if err != nil {
				return nil, err
			}
			v = string(raw)
		}
		m[k] = v
	}
	return m, nil
}

func rel(p string) string {
	if wd, err := os.Getwd(); err == nil {
		if r, err := filepath.Rel(wd, p); err == nil && !strings.HasPrefix(r, "..") {
			return r
		}
	}
	return p
}
