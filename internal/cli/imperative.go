package cli

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/config"
	"github.com/GigaionLLC/abcli/internal/gitops"
	"github.com/GigaionLLC/abcli/internal/hash"
	"github.com/GigaionLLC/abcli/internal/reconcile"
	"github.com/GigaionLLC/abcli/internal/state"
)

// writeFlags are the common flags for imperative write commands. Every write is
// gated (confirm unless --yes/$ABCTL_APPROVE) and, by default, mutates the local
// gitops tree + baseline inline so no drift window opens (see docs/imperative-cli.md).
type writeFlags struct {
	file        string
	platforms   string
	yes         bool
	noWriteTree bool
	force       bool
	json        bool
}

// imp bundles the client + on-disk tree + baseline for an imperative write.
type imp struct {
	c    *ab.Client
	cfg  *config.Config
	tree *gitops.Tree
	base *state.State

	// configIndexCache is the tenant's name↔id list, fetched at most once per command.
	// `apply -f` is the reason it exists: it resolves names once per DOCUMENT, so a 20-doc
	// bulk file listed the whole tenant twenty times. nil means "not fetched yet"; an empty
	// tenant caches as a non-nil empty slice, so an empty result is not refetched forever.
	configIndexCache []ab.LiveConfig
}

// configIndex returns the cached metadata list, fetching it on first use.
func (i *imp) configIndex() ([]ab.LiveConfig, error) {
	if i.configIndexCache != nil {
		return i.configIndexCache, nil
	}
	index, err := liveConfigIndex(i.c)
	if err != nil {
		return nil, err
	}
	if index == nil {
		index = []ab.LiveConfig{} // distinguish "empty tenant" from "never fetched"
	}
	i.configIndexCache = index
	return index, nil
}

// noteCreatedConfig keeps the cache truthful after a create, so a later document in the same
// `apply -f` run can resolve a config an earlier document just made. Appending beats
// invalidating: a bulk file that creates ten configs would otherwise re-list ten times.
func (i *imp) noteCreatedConfig(id, name string) {
	if i.configIndexCache == nil {
		return // nothing cached yet; the next configIndex() will fetch a list that includes it
	}
	i.configIndexCache = append(i.configIndexCache, ab.LiveConfig{ID: id, Name: name})
}

func newImp() (*imp, error) {
	c, cfg, err := mustClient()
	if err != nil {
		return nil, err
	}
	t := gitops.NewTree(cfg.EnvDir)
	base, err := state.Load(t.StateFile)
	if err != nil {
		return nil, err
	}
	return &imp{c: c, cfg: cfg, tree: t, base: base}, nil
}

func (i *imp) archiver() cliArchiver { return cliArchiver{root: i.tree.ArchiveDir, now: time.Now} }

// approved reports whether the write may proceed without an interactive prompt.
func approved(yes bool) bool { return yes || envApproved() }

func confirmWrite(desc string) (bool, error) {
	fmt.Fprintf(os.Stderr, "%s — apply to the LIVE Apple Business tenant? Type 'yes': ", desc)
	sc := bufio.NewScanner(os.Stdin)
	if !sc.Scan() {
		return false, sc.Err()
	}
	return strings.EqualFold(strings.TrimSpace(sc.Text()), "yes"), nil
}

// configName ensures the .mobileconfig suffix (the config identity == the lib/
// filename == the ABM name; LoadDesired only globs *.mobileconfig).
func configName(name string) string {
	if strings.HasSuffix(name, ".mobileconfig") {
		return name
	}
	return name + ".mobileconfig"
}

// readFileArg reads a file path, or stdin when the path is "-".
func readFileArg(path string) ([]byte, error) {
	if path == "-" {
		return io.ReadAll(os.Stdin)
	}
	return os.ReadFile(path)
}

// validateProfile is the pre-write structural check. It runs the SAME inspector
// `abctl validate` runs (checkProfile → inspectProfile), not a lesser one.
//
// It used to be three substring tests and a size cap, which meant the one rule the
// project added *because* of a live incident — a top-level PayloadVersion that is
// not exactly 1, which Apple accepts with a 2xx and then silently declines to store
// — was enforced by `abctl validate` and by nothing on the path that actually
// writes. `create`, `replace`, `edit` and `apply -f` would all cheerfully push the
// exact profile shape known to be dropped.
//
// Warnings are deliberately not fatal here: they are advice, and `--force` remains
// the way past a hard error.
func validateProfile(b []byte) error {
	pr := checkProfile("", libFile{name: "profile", data: b})
	if len(pr.Errors) == 0 {
		return nil
	}
	msgs := make([]string, 0, len(pr.Errors))
	for _, e := range pr.Errors {
		msgs = append(msgs, e.Code+": "+e.Message)
	}
	return fmt.Errorf("profile failed validation (use --force to skip):\n  - %s", strings.Join(msgs, "\n  - "))
}

// confirmStored re-reads a config abctl just created or replaced and reports whether
// Apple actually kept the bytes that were sent.
//
// A 2xx is NOT proof. Apple accepts the write and then silently declines to persist a
// profile that violates its schema, leaving both the stored bytes and updatedDateTime
// untouched. Recording the bytes we SENT as the baseline turns that into a permanent
// lie: the next `--refresh=smart` run finds a baseline whose id and timestamp match
// live, reuses the cached hash, never fetches the real XML, and reports "in sync"
// forever while Apple holds the old profile. The reconcile engine learned this from a
// live incident (see reconcile.push); the imperative commands issue the same writes
// against the same API and need the same proof.
//
// The verdicts are reconcile's, deliberately — one incident, one vocabulary:
//   - VerifyConfirmed   the stored bytes match; the returned config is authoritative
//   - VerifyNotPersisted Apple kept something else; the write did not take
//   - VerifyUnconfirmed  the read-back gave no answer. This is NOT evidence of
//     failure — a GET that failed says nothing about the PATCH — so the caller must
//     report it as unverified rather than failed.
func (i *imp) confirmStored(id string, sent []byte) (ab.LiveConfig, reconcile.Verification) {
	stored, err := i.c.FetchCustomSettingDetail(id)
	switch {
	case err != nil:
		return ab.LiveConfig{}, reconcile.VerifyUnconfirmed
	case stored.ContentHash() == "":
		// A detail response with no profile XML cannot be compared, and must not be
		// used to accuse Apple of dropping a write it may well have stored.
		return ab.LiveConfig{}, reconcile.VerifyUnconfirmed
	case stored.ContentHash() != hash.Raw(sent):
		return stored, reconcile.VerifyNotPersisted
	default:
		return stored, reconcile.VerifyConfirmed
	}
}

// recordWrite writes the profile into the git tree and records the baseline from what
// APPLE STORED, never from what was sent. It returns the error the command should exit
// with — non-nil only when Apple did not persist the write.
//
// On VerifyNotPersisted the tree file and the baseline are still written: the tree holds
// the operator's intent, the baseline holds Apple's reality, and the difference between
// them is exactly what makes the next `diff` show the drift and offer to retry. Writing
// neither would leave the operator with a failed command and no record of what they
// meant; writing the sent bytes into the baseline is the bug this exists to prevent.
func (i *imp) recordWrite(name, id string, sent []byte, stored ab.LiveConfig, v reconcile.Verification, noWriteTree bool) error {
	if !noWriteTree {
		if err := i.tree.WriteConfig(name, sent); err != nil {
			return err
		}
		// No baseline at all when the read-back gave no answer: a baseline is a claim
		// that git and Apple agreed at a known instant, and an unconfirmed write cannot
		// support that claim. Its absence makes the next run re-read, which is right.
		if v != reconcile.VerifyUnconfirmed {
			i.base.Configs[name] = state.Entry{ABMID: id, Hash: stored.ContentHash(), UpdatedDateTime: stored.Updated}
			if err := i.base.Save(i.tree.StateFile); err != nil {
				return err
			}
		}
	}
	switch v {
	case reconcile.VerifyNotPersisted:
		return fmt.Errorf("%s (stored updatedDateTime %s)", reconcile.NotPersistedMessage, stored.Updated)
	case reconcile.VerifyUnconfirmed:
		fmt.Fprintf(os.Stderr, "warning: %q was written but could not be read back to confirm it landed; "+
			"the baseline was left alone so the next `abctl diff` re-checks it.\n", name)
	}
	return nil
}

func treeNote(noWriteTree bool) string {
	if noWriteTree {
		return " (tenant only — NOT written to the git tree; will show as drift until `abctl pull`)"
	}
	return " (git tree + baseline updated)"
}

// writeOutcome is the machine-readable result of a single imperative write (P4): a
// GUI/script learns the new id, the archived pre-overwrite copy, and whether the git
// tree was updated, instead of scraping the human stderr sentence. Errors surface as a
// nonzero exit (+ stderr), so Status is always "done" when this is emitted.
type writeOutcome struct {
	Action          string `json:"action"` // create|replace|edit|delete|attach|detach
	Name            string `json:"name"`
	ID              string `json:"id,omitempty"`
	Status          string `json:"status"`
	UpdatedDateTime string `json:"updatedDateTime,omitempty"` // ABM time after create/replace
	Archive         string `json:"archive,omitempty"`         // archived pre-overwrite copy (replace/delete)
	Blueprint       string `json:"blueprint,omitempty"`       // target blueprint (attach/detach)
	TreeUpdated     bool   `json:"treeUpdated"`
	// TreeError names why the local tree update failed when TreeUpdated is false
	// DESPITE the tree write having been requested. The tenant write succeeded (this
	// document is only emitted on success), so this is not an error exit — but a
	// caller that reports the write as fully done would be lying, and the drift it
	// leaves behind resurfaces on every later diff.
	TreeError string `json:"treeError,omitempty"`
	// Verified is the read-back verdict for a create/replace (reconcile.Verification):
	// "confirmed", "not-persisted", or "unconfirmed". A 2xx from Apple is not proof the
	// profile was stored, so a caller that reports success without reading this is
	// reporting the tenant's acknowledgement rather than its state.
	Verified string `json:"verified,omitempty"`
}

// wantsMachine reports whether a machine format (the --json shorthand or a global
// -o json/-o yaml) was requested for a write command.
func wantsMachine(jsonShorthand bool) bool { return jsonShorthand || flagOutput != "table" }

// emitWrite prints a write outcome as json/yaml on stdout (P4); the human stderr line is
// skipped by the caller so the machine payload is the only thing on stdout.
func emitWrite(o writeOutcome, jsonShorthand bool) error {
	o.Status = "done"
	return render(outFmt(jsonShorthand), o, nil, nil)
}

// --- create ---

func newCreateCmd() *cobra.Command {
	c := &cobra.Command{Use: "create", Short: "Create a resource on Apple Business (imperative)"}
	c.AddCommand(newCreateConfigCmd(), newCreateBlueprintCmd(), newCreateMDMServerCmd())
	return c
}

func newCreateConfigCmd() *cobra.Command {
	var fl writeFlags
	cmd := &cobra.Command{
		Use:     "config <name> -f <profile.mobileconfig>",
		Aliases: []string{"configuration"},
		Short:   "Create a CUSTOM_SETTING configuration from a .mobileconfig (POST)",
		Args:    cobra.ExactArgs(1),
		RunE:    func(_ *cobra.Command, a []string) error { return runCreateConfig(a[0], fl) },
	}
	addWriteFlags(cmd, &fl, true)
	return cmd
}

func runCreateConfig(name string, fl writeFlags) error {
	name = configName(name)
	content, err := readFileArg(fl.file)
	if err != nil {
		return err
	}
	if !fl.force {
		if err := validateProfile(content); err != nil {
			return err
		}
	}
	i, err := newImp()
	if err != nil {
		return err
	}
	if !approved(fl.yes) {
		ok, err := confirmWrite("create config " + name)
		if err != nil || !ok {
			fmt.Fprintln(os.Stderr, "aborted.")
			return ExitError{Code: 1}
		}
	}
	id, updated, err := i.c.CreateConfiguration(name, string(content), parsePlatforms(fl.platforms))
	if err != nil {
		return err
	}
	stored, verdict := i.confirmStored(id, content)
	if stored.Updated != "" {
		updated = stored.Updated // Apple's stored timestamp beats the one the write echoed
	}
	if err := i.recordWrite(name, id, content, stored, verdict, fl.noWriteTree); err != nil {
		return err
	}
	if wantsMachine(fl.json) {
		return emitWrite(writeOutcome{Action: "create", Name: name, ID: id, UpdatedDateTime: updated,
			TreeUpdated: !fl.noWriteTree, Verified: string(verdict)}, fl.json)
	}
	fmt.Fprintf(os.Stderr, "created %q (id %s)%s\n", name, id, treeNote(fl.noWriteTree))
	return nil
}

// --- replace (PATCH) ---

func newReplaceCmd() *cobra.Command {
	c := &cobra.Command{Use: "replace", Short: "Replace a resource's contents on Apple Business (imperative)"}
	c.AddCommand(newReplaceConfigCmd())
	return c
}

func newReplaceConfigCmd() *cobra.Command {
	var fl writeFlags
	cmd := &cobra.Command{
		Use:     "config <name|id> -f <profile.mobileconfig>",
		Aliases: []string{"configuration"},
		Short:   "Replace a CUSTOM_SETTING configuration's profile (archive live, then PATCH)",
		Args:    cobra.ExactArgs(1),
		RunE:    func(_ *cobra.Command, a []string) error { return runReplaceConfig(a[0], fl) },
	}
	addWriteFlags(cmd, &fl, true)
	return cmd
}

func runReplaceConfig(nameOrID string, fl writeFlags) error {
	content, err := readFileArg(fl.file)
	if err != nil {
		return err
	}
	if !fl.force {
		if err := validateProfile(content); err != nil {
			return err
		}
	}
	i, err := newImp()
	if err != nil {
		return err
	}
	lc, err := resolveLiveConfig(i.c, nameOrID)
	if err != nil {
		return err
	}
	if !approved(fl.yes) {
		ok, err := confirmWrite("replace config " + lc.Name)
		if err != nil || !ok {
			fmt.Fprintln(os.Stderr, "aborted.")
			return ExitError{Code: 1}
		}
	}
	// archive-before-overwrite, then PATCH.
	arch, err := i.archiver().Archive(lc.Name, "replaced", []byte(lc.XML), map[string]string{
		"abm_id": lc.ID, "hash": hash.Raw([]byte(lc.XML)), "updatedDateTime": lc.Updated,
	})
	if err != nil {
		return fmt.Errorf("archive failed (PATCH skipped to keep the audit trail): %w", err)
	}
	updated, err := i.c.UpdateConfiguration(lc.ID, lc.Name, string(content))
	if err != nil {
		return err
	}
	stored, verdict := i.confirmStored(lc.ID, content)
	if stored.Updated != "" {
		updated = stored.Updated // Apple's stored timestamp beats the one the write echoed
	}
	if err := i.recordWrite(lc.Name, lc.ID, content, stored, verdict, fl.noWriteTree); err != nil {
		return err
	}
	if wantsMachine(fl.json) {
		return emitWrite(writeOutcome{Action: "replace", Name: lc.Name, ID: lc.ID, UpdatedDateTime: updated,
			Archive: arch, TreeUpdated: !fl.noWriteTree, Verified: string(verdict)}, fl.json)
	}
	fmt.Fprintf(os.Stderr, "replaced %q%s\n", lc.Name, treeNote(fl.noWriteTree))
	return nil
}

// --- edit ($EDITOR) ---

func newEditCmd() *cobra.Command {
	c := &cobra.Command{Use: "edit", Short: "Edit a resource (config: $EDITOR; blueprint/mdmserver: flags)"}
	c.AddCommand(newEditConfigCmd(), newEditBlueprintCmd(), newEditMDMServerCmd())
	return c
}

func newEditConfigCmd() *cobra.Command {
	var fl writeFlags
	cmd := &cobra.Command{
		Use:     "config <name|id>",
		Aliases: []string{"configuration"},
		Short:   "Fetch a config, open it in $EDITOR, and PATCH on save",
		Args:    cobra.ExactArgs(1),
		RunE:    func(_ *cobra.Command, a []string) error { return runEditConfig(a[0], fl) },
	}
	cmd.Flags().BoolVar(&fl.yes, "yes", false, "skip confirmation")
	cmd.Flags().BoolVar(&fl.noWriteTree, "no-write-tree", false, "do not update the local gitops tree/baseline")
	cmd.Flags().BoolVar(&fl.force, "force", false, "skip client-side validation")
	return cmd
}

func runEditConfig(nameOrID string, fl writeFlags) error {
	i, err := newImp()
	if err != nil {
		return err
	}
	lc, err := resolveLiveConfig(i.c, nameOrID)
	if err != nil {
		return err
	}
	edited, err := editInEditor([]byte(lc.XML), "abctl-"+gitops.Sanitize(lc.Name)+"-*.mobileconfig")
	if err != nil {
		return err
	}
	if string(edited) == lc.XML {
		fmt.Fprintln(os.Stderr, "no changes — nothing to apply.")
		return nil
	}
	if !fl.force {
		if err := validateProfile(edited); err != nil {
			return err
		}
	}
	fl.file = "" // signal: content already in hand
	return applyReplaceResolved(i, lc, edited, fl)
}

// applyReplaceResolved performs the archive+PATCH+tree write for an already-resolved config.
func applyReplaceResolved(i *imp, lc ab.LiveConfig, content []byte, fl writeFlags) error {
	if !approved(fl.yes) {
		ok, err := confirmWrite("update config " + lc.Name)
		if err != nil || !ok {
			fmt.Fprintln(os.Stderr, "aborted.")
			return ExitError{Code: 1}
		}
	}
	if _, err := i.archiver().Archive(lc.Name, "replaced", []byte(lc.XML), map[string]string{
		"abm_id": lc.ID, "hash": hash.Raw([]byte(lc.XML)), "updatedDateTime": lc.Updated,
	}); err != nil {
		return fmt.Errorf("archive failed (PATCH skipped): %w", err)
	}
	if _, err := i.c.UpdateConfiguration(lc.ID, lc.Name, string(content)); err != nil {
		return err
	}
	stored, verdict := i.confirmStored(lc.ID, content)
	if err := i.recordWrite(lc.Name, lc.ID, content, stored, verdict, fl.noWriteTree); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "updated %q%s\n", lc.Name, treeNote(fl.noWriteTree))
	return nil
}

// --- delete (DELETE) ---

func newDeleteCmd() *cobra.Command {
	var fileFlag string
	c := &cobra.Command{
		Use:   "delete",
		Short: "Delete a resource on Apple Business (imperative), or a set via -f",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if fileFlag != "" {
				return runApplyFiles([]string{fileFlag}, applyOpts{delete: true, yes: applyYes})
			}
			return cmd.Help()
		},
	}
	c.PersistentFlags().StringVarP(&fileFlag, "file", "f", "", "delete every resource declared in this abctl/v1 spec file")
	c.PersistentFlags().BoolVar(&applyYes, "yes", false, "skip confirmation")
	c.AddCommand(newDeleteConfigCmd(), newDeleteBlueprintCmd(), newDeleteMDMServerCmd())
	return c
}

func newDeleteConfigCmd() *cobra.Command {
	var fl writeFlags
	cmd := &cobra.Command{
		Use:     "config <name|id>",
		Aliases: []string{"configuration"},
		Short:   "Delete a CUSTOM_SETTING configuration (archive live, then DELETE)",
		Args:    cobra.ExactArgs(1),
		RunE:    func(_ *cobra.Command, a []string) error { return runDeleteConfig(a[0], fl) },
	}
	cmd.Flags().BoolVar(&fl.yes, "yes", false, "skip confirmation")
	cmd.Flags().BoolVar(&fl.noWriteTree, "no-write-tree", false, "do not update the local gitops tree/baseline")
	cmd.Flags().BoolVar(&fl.json, "json", false, "JSON output (machine-readable write outcome)")
	return cmd
}

func runDeleteConfig(nameOrID string, fl writeFlags) error {
	i, err := newImp()
	if err != nil {
		return err
	}
	lc, err := resolveLiveConfig(i.c, nameOrID)
	if err != nil {
		return err
	}
	if !approved(fl.yes) {
		ok, err := confirmWrite("DELETE config " + lc.Name)
		if err != nil || !ok {
			fmt.Fprintln(os.Stderr, "aborted.")
			return ExitError{Code: 1}
		}
	}
	arch, err := i.archiver().Archive(lc.Name, "deleted", []byte(lc.XML), map[string]string{
		"abm_id": lc.ID, "hash": hash.Raw([]byte(lc.XML)), "updatedDateTime": lc.Updated,
	})
	if err != nil {
		return fmt.Errorf("archive failed (DELETE skipped to keep the audit trail): %w", err)
	}
	if err := i.c.DeleteConfiguration(lc.ID); err != nil {
		return err
	}
	if !fl.noWriteTree {
		if err := i.tree.RemoveConfig(lc.Name); err != nil {
			return err
		}
		delete(i.base.Configs, lc.Name)
		if err := i.base.Save(i.tree.StateFile); err != nil {
			return err
		}
	}
	if wantsMachine(fl.json) {
		return emitWrite(writeOutcome{Action: "delete", Name: lc.Name, ID: lc.ID, Archive: arch, TreeUpdated: !fl.noWriteTree}, fl.json)
	}
	fmt.Fprintf(os.Stderr, "deleted %q%s\n", lc.Name, treeNote(fl.noWriteTree))
	return nil
}

// resolveLiveConfig finds ONE live CUSTOM_SETTING config by name or id, with its XML.
//
// Two requests, not 1+N: a metadata-only list to turn the name into an id, then a single
// detail fetch for that one config. It used to call FetchCustomSettings, which asks Apple
// for `customSettingsValues` — the profile XML — for EVERY config in the tenant, and falls
// back to a per-config GET whenever the list comes back sparse. That is the trap `adopt`
// hit: the caller wants one profile and pays for all of them, and on a real tenant the
// command outran abgui's budget and appeared to do nothing at all.
//
// Callers here genuinely need the XML (it is what gets archived before an overwrite), so
// unlike liveConfigIndex this still fetches a profile — exactly one.
func resolveLiveConfig(c *ab.Client, nameOrID string) (ab.LiveConfig, error) {
	index, err := liveConfigIndex(c)
	if err != nil {
		return ab.LiveConfig{}, err
	}
	found, ok := findLiveConfig(index, nameOrID)
	if !ok {
		return ab.LiveConfig{}, fmt.Errorf("CUSTOM_SETTING config %q not found (by name or id)", nameOrID)
	}
	detail, err := c.FetchCustomSettingDetail(found.ID)
	if err != nil {
		return ab.LiveConfig{}, fmt.Errorf("reading configuration %q: %w", found.Name, err)
	}
	// The list is authoritative for the name (the detail response has been seen to omit
	// fields); the detail is authoritative for the bytes.
	if detail.Name == "" {
		detail.Name = found.Name
	}
	return detail, nil
}

func findLiveConfig(live []ab.LiveConfig, nameOrID string) (ab.LiveConfig, bool) {
	want := configName(nameOrID)
	for _, l := range live {
		if l.Name == nameOrID || l.Name == want || l.ID == nameOrID {
			return l, true
		}
	}
	return ab.LiveConfig{}, false
}

// syncBlueprintManifest rewrites blueprints/<name>.yml to the blueprint's ACTUAL
// post-write live config membership, so the git manifest always equals live (never
// a partial set that a later `sync --prune` would treat as configs to detach).
// live is the current CUSTOM_SETTING list (for id→name resolution).
// removed names the config a DETACH just took off the blueprint, or "" for an attach.
// It is excluded from the union below: without it, detaching a config that the manifest
// still declares would re-add it from the manifest and the detach would never stick.
func (i *imp) syncBlueprintManifest(bpName, bpID string, live []ab.LiveConfig, removed string) error {
	links, err := i.c.BlueprintRelationship(bpID, "configurations")
	if err != nil {
		return err
	}
	nameByID := make(map[string]string, len(live))
	for _, l := range live {
		nameByID[l.ID] = l.Name
	}
	names := make([]string, 0, len(links))
	for _, ln := range links {
		if n, ok := nameByID[ln.ID]; ok {
			names = append(names, n) // a managed CUSTOM_SETTING → its name
		} else {
			names = append(names, ln.ID) // a native/console config abctl doesn't own → pass its id through
		}
	}
	sort.Strings(names)
	// Start from the existing manifest so its description AND any managed member
	// keys (apps/packages/devices/users/groups — pointer-slice semantics, see
	// gitops.BlueprintSpec) survive the rewrite; only the config membership is
	// refreshed here. A failed load MUST abort — writing from a zero-value spec
	// would silently unmanage every member collection the user had managed.
	all, err := i.tree.LoadBlueprints()
	if err != nil {
		return fmt.Errorf("reading existing blueprint manifests: %w", err)
	}
	spec := all[bpName]
	// UNION with what the manifest already declares, rather than replacing it.
	//
	// A plain rewrite from live discards any config the operator has declared in git but
	// not yet attached — a pending `attach-config` row in the plan — so attaching A would
	// silently delete B's intent, and no later sync would ever propose it again. The
	// rewrite-from-live rule is still right for the member that was just written (that
	// one IS live now); it was only ever wrong about the entries it did not touch.
	//
	// A DETACH still has to remove its member, so the removed one is excluded explicitly
	// rather than trusting the union to drop it.
	attachedNames := toStringSet(names)
	for _, declared := range spec.Configurations {
		if _, isAttached := attachedNames[declared]; !isAttached && declared != removed {
			names = append(names, declared)
		}
	}
	sort.Strings(names)
	spec.Name, spec.ID, spec.Configurations = bpName, bpID, names
	return i.tree.WriteBlueprintSpec(spec)
}

// toStringSet is the membership test used above; a map keeps the union linear rather
// than quadratic on a blueprint with many configurations.
func toStringSet(ss []string) map[string]struct{} {
	m := make(map[string]struct{}, len(ss))
	for _, s := range ss {
		m[s] = struct{}{}
	}
	return m
}

func addWriteFlags(cmd *cobra.Command, fl *writeFlags, needFile bool) {
	cmd.Flags().StringVarP(&fl.file, "file", "f", "", "path to the .mobileconfig ('-' for stdin)")
	cmd.Flags().StringVar(&fl.platforms, "platforms", "", "configuredForPlatforms (default PLATFORM_MACOS)")
	cmd.Flags().BoolVar(&fl.yes, "yes", false, "skip confirmation (also honored: $ABCTL_APPROVE=1)")
	cmd.Flags().BoolVar(&fl.noWriteTree, "no-write-tree", false, "do not update the local gitops tree/baseline")
	cmd.Flags().BoolVar(&fl.force, "force", false, "skip client-side validation")
	cmd.Flags().BoolVar(&fl.json, "json", false, "JSON output (machine-readable write outcome)")
	if needFile {
		_ = cmd.MarkFlagRequired("file")
	}
}

// editInEditor writes content to a temp file, opens $EDITOR (default: vi/notepad),
// and returns the edited bytes.
func editInEditor(content []byte, pattern string) ([]byte, error) {
	f, err := os.CreateTemp("", pattern)
	if err != nil {
		return nil, err
	}
	name := f.Name()
	defer func() { _ = os.Remove(name) }()
	if _, err := f.Write(content); err != nil {
		_ = f.Close()
		return nil, err
	}
	_ = f.Close()
	if err := runEditor(name); err != nil {
		return nil, err
	}
	return os.ReadFile(name)
}
