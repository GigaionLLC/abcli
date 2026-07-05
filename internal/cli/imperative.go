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
}

// imp bundles the client + on-disk tree + baseline for an imperative write.
type imp struct {
	c    *ab.Client
	cfg  *config.Config
	tree *gitops.Tree
	base *state.State
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

// validateProfile is the built-in structural check (same as `abctl validate`).
func validateProfile(b []byte) error {
	s := string(b)
	if len(b) >= 1<<20 {
		return fmt.Errorf("profile is >= 1 MB (Apple Business cap)")
	}
	if !strings.Contains(s, "<key>PayloadType</key>") || !strings.Contains(s, "Configuration") || !strings.Contains(s, "PayloadContent") {
		return fmt.Errorf("profile is missing the Configuration/PayloadContent structure (use --force to skip)")
	}
	return nil
}

func treeNote(noWriteTree bool) string {
	if noWriteTree {
		return " (tenant only — NOT written to the git tree; will show as drift until `abctl pull`)"
	}
	return " (git tree + baseline updated)"
}

// --- create ---

func newCreateCmd() *cobra.Command {
	c := &cobra.Command{Use: "create", Short: "Create a resource on Apple Business (imperative)"}
	c.AddCommand(newCreateConfigCmd())
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
	if !fl.noWriteTree {
		if err := i.tree.WriteConfig(name, content); err != nil {
			return err
		}
		i.base.Configs[name] = state.Entry{ABMID: id, Hash: hash.Raw(content), UpdatedDateTime: updated}
		if err := i.base.Save(i.tree.StateFile); err != nil {
			return err
		}
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
	if _, err := i.archiver().Archive(lc.Name, "replaced", []byte(lc.XML), map[string]string{
		"abm_id": lc.ID, "hash": hash.Raw([]byte(lc.XML)), "updatedDateTime": lc.Updated,
	}); err != nil {
		return fmt.Errorf("archive failed (PATCH skipped to keep the audit trail): %w", err)
	}
	updated, err := i.c.UpdateConfiguration(lc.ID, lc.Name, string(content))
	if err != nil {
		return err
	}
	if !fl.noWriteTree {
		if err := i.tree.WriteConfig(lc.Name, content); err != nil {
			return err
		}
		i.base.Configs[lc.Name] = state.Entry{ABMID: lc.ID, Hash: hash.Raw(content), UpdatedDateTime: updated}
		if err := i.base.Save(i.tree.StateFile); err != nil {
			return err
		}
	}
	fmt.Fprintf(os.Stderr, "replaced %q%s\n", lc.Name, treeNote(fl.noWriteTree))
	return nil
}

// --- edit ($EDITOR) ---

func newEditCmd() *cobra.Command {
	c := &cobra.Command{Use: "edit", Short: "Edit a resource in $EDITOR (imperative)"}
	c.AddCommand(newEditConfigCmd())
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
	updated, err := i.c.UpdateConfiguration(lc.ID, lc.Name, string(content))
	if err != nil {
		return err
	}
	if !fl.noWriteTree {
		if err := i.tree.WriteConfig(lc.Name, content); err != nil {
			return err
		}
		i.base.Configs[lc.Name] = state.Entry{ABMID: lc.ID, Hash: hash.Raw(content), UpdatedDateTime: updated}
		if err := i.base.Save(i.tree.StateFile); err != nil {
			return err
		}
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
	c.AddCommand(newDeleteConfigCmd())
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
	if _, err := i.archiver().Archive(lc.Name, "deleted", []byte(lc.XML), map[string]string{
		"abm_id": lc.ID, "hash": hash.Raw([]byte(lc.XML)), "updatedDateTime": lc.Updated,
	}); err != nil {
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
	fmt.Fprintf(os.Stderr, "deleted %q%s\n", lc.Name, treeNote(fl.noWriteTree))
	return nil
}

// resolveLiveConfig finds a live CUSTOM_SETTING config (with its XML) by name or id.
func resolveLiveConfig(c *ab.Client, nameOrID string) (ab.LiveConfig, error) {
	live, err := c.FetchCustomSettings()
	if err != nil {
		return ab.LiveConfig{}, err
	}
	if lc, ok := findLiveConfig(live, nameOrID); ok {
		return lc, nil
	}
	return ab.LiveConfig{}, fmt.Errorf("CUSTOM_SETTING config %q not found (by name or id)", nameOrID)
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
func (i *imp) syncBlueprintManifest(bpName, bpID string, live []ab.LiveConfig) error {
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
	all, _ := i.tree.LoadBlueprints()
	return i.tree.WriteBlueprintSpec(gitops.BlueprintSpec{
		Name: bpName, ID: bpID, Description: all[bpName].Description, Configurations: names,
	})
}

func addWriteFlags(cmd *cobra.Command, fl *writeFlags, needFile bool) {
	cmd.Flags().StringVarP(&fl.file, "file", "f", "", "path to the .mobileconfig ('-' for stdin)")
	cmd.Flags().StringVar(&fl.platforms, "platforms", "", "configuredForPlatforms (default PLATFORM_MACOS)")
	cmd.Flags().BoolVar(&fl.yes, "yes", false, "skip confirmation (also honored: $ABCTL_APPROVE=1)")
	cmd.Flags().BoolVar(&fl.noWriteTree, "no-write-tree", false, "do not update the local gitops tree/baseline")
	cmd.Flags().BoolVar(&fl.force, "force", false, "skip client-side validation")
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
