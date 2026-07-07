package cli

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
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

func newSeedCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "seed",
		Short: "Download live configs → gitops/ tree + baseline (reads ABM, writes local files)",
		Args:  cobra.NoArgs,
		RunE:  func(*cobra.Command, []string) error { return runSeed() },
	}
}

func newValidateCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "validate",
		Short: "Validate the gitops/ profiles ($ABCTL_VALIDATOR, else a built-in check)",
		Args:  cobra.NoArgs,
		RunE:  func(*cobra.Command, []string) error { return runValidate() },
	}
}

func newDiffCmd() *cobra.Command {
	var asJSON, exitOnDiff, gitSourceOfTruth bool
	c := &cobra.Command{
		Use:   "diff",
		Short: "3-way plan: git desired vs baseline vs live ABM (configs + blueprint membership)",
		Args:  cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			pc, err := loadPlan(gitSourceOfTruth)
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
	c.Flags().BoolVar(&gitSourceOfTruth, "git-source-of-truth", false, "treat gitops/ as authoritative; do not pull live-only Apple configs into git")
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
}

func newSyncCmd() *cobra.Command {
	var fl syncFlags
	var dryRun bool // accepted for symmetry; --apply is what switches on writes
	c := &cobra.Command{
		Use:   "sync",
		Short: "Reconcile configs + blueprint membership: dry-run plan by default, gated --apply to execute",
		Long: "sync reconciles the git desired state with the live tenant: CUSTOM_SETTING configs\n" +
			"(3-way, newest-wins) and each blueprint's config membership (git-authoritative).\n" +
			"Read-only by default: it prints the plan and exits. Pass --apply to execute it —\n" +
			"every overwrite/delete archives the live version first, and you are asked to confirm\n" +
			"unless --yes (or $ABCTL_APPROVE) is set. --prune (off by default) allows deleting live\n" +
			"configs removed from git and detaching blueprint members removed from git;\n" +
			"--limit-writes N caps tenant writes as a circuit breaker. --git-source-of-truth treats\n" +
			"gitops/ as the complete desired state and applies/deletes so Apple matches it.",
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
	c.Flags().BoolVar(&fl.gitSourceOfTruth, "git-source-of-truth", false, "treat gitops/ as authoritative; apply implies --prune so Apple matches git")
	return c
}

// runSync computes the 3-way plan, prints it, and — only with --apply — executes
// it: confirm (unless --yes/$ABCTL_APPROVE) → archive-before-overwrite apply →
// save the updated baseline. Dry-run is the default and writes nothing.
func runSync(fl syncFlags) error {
	pc, err := loadPlan(fl.gitSourceOfTruth)
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
		ok, err := confirmApply(len(pc.plan.Items) + pc.bpPlan.ReconcilableCount())
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
	// Phase 1: configs. Save the baseline even on partial success.
	res := eng.Apply(pc.plan, pc.desired, pc.live, pc.base, opts)
	if err := pc.base.Save(pc.tree.StateFile); err != nil {
		return fmt.Errorf("apply ran but saving the baseline failed (re-run sync to reconcile): %w", err)
	}

	// Phase 2: blueprint membership. Recompute with config IDs from the post-apply
	// baseline so a config just created in phase 1 resolves and can be attached.
	cfgIDByName := make(map[string]string, len(pc.base.Configs))
	cfgNameByID := make(map[string]string, len(pc.base.Configs))
	for name, e := range pc.base.Configs {
		if e.ABMID != "" {
			cfgIDByName[name] = e.ABMID
			cfgNameByID[e.ABMID] = name
		}
	}
	liveBPs := pc.liveBPs
	if fl.gitSourceOfTruth {
		fmt.Fprintln(os.Stderr, "refreshing live state after config writes for git-source-of-truth blueprint reconciliation...")
		liveAfter, err := pc.c.FetchCustomSettingsWithProgress(func(line string) {
			fmt.Fprintln(os.Stderr, "refreshing live state: "+line)
		})
		if err != nil {
			return err
		}
		for _, l := range liveAfter {
			if l.ID != "" {
				cfgIDByName[l.Name] = l.ID
				cfgNameByID[l.ID] = l.Name
			}
		}
		liveBPs, err = fetchLiveBlueprintsForPlan(pc.c, cfgNameByID)
		if err != nil {
			return err
		}
	}
	bpPlan := reconcile.ComputeBlueprints(pc.bpDesired, liveBPs, cfgIDByName)
	bpRes := eng.ApplyBlueprints(bpPlan, opts, res.Writes)

	if machine {
		if err := render(planFmt, map[string]any{"configs": res, "blueprints": bpRes}, nil, nil); err != nil {
			return err
		}
	} else {
		printApplyResult(res)
		printBlueprintResult(bpRes)
	}
	if res.Errors > 0 || bpRes.Errors > 0 {
		return ExitError{Code: 1}
	}
	return nil
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
	printTable([]string{"STATUS", "BP-ACTION", "BLUEPRINT", "CONFIG", "DETAIL"}, rows)
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

// confirmApply prompts on stdin; only a literal "yes" proceeds.
func confirmApply(n int) (bool, error) {
	fmt.Fprintf(os.Stderr, "\nApply %d change(s) to the LIVE Apple Business tenant? Type 'yes' to proceed: ", n)
	sc := bufio.NewScanner(os.Stdin)
	if !sc.Scan() {
		return false, sc.Err()
	}
	return strings.EqualFold(strings.TrimSpace(sc.Text()), "yes"), nil
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

func runSeed() error {
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
	bps, err := c.ListBlueprints()
	if err != nil {
		return err
	}
	for _, bp := range bps {
		// Propagate a relationship-fetch error rather than silently seeding an empty
		// membership: a git-authoritative `configurations: []` written from a failed
		// fetch would make a later `sync --apply --prune` detach every real config.
		links, err := c.BlueprintRelationship(bp.ID, "configurations")
		if err != nil {
			return fmt.Errorf("seed: fetching blueprint %q membership: %w", bp.AttrStr("name"), err)
		}
		names := make([]string, 0, len(links))
		for _, ln := range links {
			if n, ok := idToName[ln.ID]; ok {
				names = append(names, n)
			} else {
				names = append(names, ln.ID)
			}
		}
		sort.Strings(names)
		if err := t.WriteBlueprintSpec(gitops.BlueprintSpec{
			Name:           bp.AttrStr("name"),
			ID:             bp.ID,
			Description:    bp.AttrStr("description"),
			Configurations: names,
		}); err != nil {
			return err
		}
	}
	fmt.Printf("seeded %d configuration(s) → %s\n", len(live), rel(t.LibDir))
	fmt.Printf("baseline           → %s\n", rel(t.StateFile))
	fmt.Printf("%d blueprint(s)     → %s\n", len(bps), rel(t.BlueprintsDir))
	fmt.Fprintln(os.Stderr, "review the tree, then `git add gitops/` to commit the desired state + baseline.")
	return nil
}

func runValidate() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	t := gitops.NewTree(cfg.EnvDir)
	files, _ := filepath.Glob(filepath.Join(t.LibDir, "*.mobileconfig"))
	if len(files) == 0 {
		fmt.Println("no profiles in", rel(t.LibDir), "(run `abctl seed` first)")
		return nil
	}
	if v := resolveValidator(); len(v) > 0 {
		cmd := exec.Command(v[0], append(append([]string{}, v[1:]...), t.LibDir)...)
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		if err := cmd.Run(); err != nil {
			if ee, ok := err.(*exec.ExitError); ok {
				return ExitError{Code: ee.ExitCode()}
			}
			return err
		}
		return nil
	}
	bad := 0
	for _, f := range files {
		b, _ := os.ReadFile(f)
		s := string(b)
		switch {
		case len(b) >= 1<<20:
			fmt.Printf("FAIL %s: >= 1 MB (ABM cap)\n", filepath.Base(f))
			bad++
		case !strings.Contains(s, "<key>PayloadType</key>") || !strings.Contains(s, "Configuration") || !strings.Contains(s, "PayloadContent"):
			fmt.Printf("FAIL %s: missing Configuration/PayloadContent structure\n", filepath.Base(f))
			bad++
		}
	}
	fmt.Printf("%d profile(s): %d ok, %d failed (built-in check; set $ABCTL_VALIDATOR for deep validation)\n", len(files), len(files)-bad, bad)
	if bad > 0 {
		return ExitError{Code: 1}
	}
	return nil
}

func resolveValidator() []string {
	if v := os.Getenv("ABCTL_VALIDATOR"); v != "" {
		return strings.Fields(v)
	}
	return nil
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
	bpDesired   map[string]gitops.BlueprintSpec
	liveBPs     []ab.LiveBlueprint
	cfgIDByName map[string]string // config name → ABM id (from live, pre-apply)
	bpPlan      *reconcile.BlueprintPlan
}

// loadPlan reads git desired + baseline + live for both configs and blueprints and
// computes the two 3-way plans. Shared by diff and sync so both see an identical plan.
func loadPlan(gitSourceOfTruth bool) (*planCtx, error) {
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
	fmt.Fprintln(os.Stderr, "building plan: fetching live configurations from Apple...")
	live, err := c.FetchCustomSettingsWithProgress(func(line string) {
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
	liveBPs, err := fetchLiveBlueprintsForPlan(c, cfgNameByID)
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
	bpPlan := reconcile.ComputeBlueprints(bpDesired, liveBPs, cfgIDByName)
	fmt.Fprintf(os.Stderr, "building plan: computed %d blueprint membership change(s).\n", len(bpPlan.Items))
	return &planCtx{
		c: c, cfg: cfg, tree: t, desired: desired, base: base, live: live,
		plan:        cfgPlan,
		bpDesired:   bpDesired,
		liveBPs:     liveBPs,
		cfgIDByName: cfgIDByName,
		bpPlan:      bpPlan,
	}, nil
}

func fetchLiveBlueprintsForPlan(c *ab.Client, configNameByID map[string]string) ([]ab.LiveBlueprint, error) {
	fmt.Fprintln(os.Stderr, "building plan: fetching live blueprints from Apple...")
	bps, err := c.ListBlueprints()
	if err != nil {
		return nil, err
	}
	fmt.Fprintf(os.Stderr, "building plan: fetched %d live blueprint(s).\n", len(bps))
	out := make([]ab.LiveBlueprint, 0, len(bps))
	for i, bp := range bps {
		name := bp.AttrStr("name")
		if name == "" {
			name = bp.ID
		}
		fmt.Fprintf(os.Stderr, "building plan: fetching blueprint membership %d/%d: %s\n", i+1, len(bps), name)
		links, err := c.BlueprintRelationship(bp.ID, "configurations")
		if err != nil {
			return nil, err
		}
		names := make([]string, 0, len(links))
		for _, l := range links {
			if n, ok := configNameByID[l.ID]; ok {
				names = append(names, n)
			} else {
				names = append(names, l.ID)
			}
		}
		sort.Strings(names)
		out = append(out, ab.LiveBlueprint{Name: bp.AttrStr("name"), ID: bp.ID, Configs: names})
	}
	return out, nil
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
		printTable([]string{"BP-ACTION", "BLUEPRINT", "CONFIG", "DETAIL"}, rows)
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
