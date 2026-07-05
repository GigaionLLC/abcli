package cli

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/GigaionLLC/abcli/internal/hash"
	"github.com/GigaionLLC/abcli/internal/state"
)

// runEditor opens path in $VISUAL/$EDITOR (fallback: notepad on Windows, vi else).
func runEditor(path string) error {
	ed := os.Getenv("VISUAL")
	if ed == "" {
		ed = os.Getenv("EDITOR")
	}
	if ed == "" {
		if runtime.GOOS == "windows" {
			ed = "notepad"
		} else {
			ed = "vi"
		}
	}
	parts := strings.Fields(ed)
	cmd := exec.Command(parts[0], append(parts[1:], path)...) //nolint:gosec // operator's own $EDITOR
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}

// --- attach / detach a config to/from a blueprint ---

func newAttachCmd() *cobra.Command { return membershipCmd("attach") }
func newDetachCmd() *cobra.Command { return membershipCmd("detach") }

func membershipCmd(verb string) *cobra.Command {
	var blueprint string
	var yes, noWriteTree, jsonOut bool
	c := &cobra.Command{
		Use:   verb + " config <name|id> --blueprint <name|id>",
		Short: verb + " a configuration " + map[string]string{"attach": "to", "detach": "from"}[verb] + " a blueprint",
		Args:  cobra.ExactArgs(2), // "config" <name>
		RunE: func(_ *cobra.Command, a []string) error {
			if a[0] != "config" && a[0] != "configuration" {
				return fmt.Errorf("usage: abctl %s config <name|id> --blueprint <bp>", verb)
			}
			return runMembership(verb, a[1], blueprint, yes, noWriteTree, jsonOut)
		},
	}
	c.Flags().StringVar(&blueprint, "blueprint", "", "target blueprint (name or id)")
	c.Flags().BoolVar(&yes, "yes", false, "skip confirmation (also: $ABCTL_APPROVE=1)")
	c.Flags().BoolVar(&noWriteTree, "no-write-tree", false, "do not update the local blueprint manifest")
	c.Flags().BoolVar(&jsonOut, "json", false, "JSON output (machine-readable write outcome)")
	_ = c.MarkFlagRequired("blueprint")
	return c
}

func runMembership(verb, configArg, blueprintArg string, yes, noWriteTree, jsonOut bool) error {
	i, err := newImp()
	if err != nil {
		return err
	}
	live, err := i.c.FetchCustomSettings()
	if err != nil {
		return err
	}
	lc, ok := findLiveConfig(live, configArg)
	if !ok {
		return fmt.Errorf("CUSTOM_SETTING config %q not found (by name or id)", configArg)
	}
	bp, err := i.c.ResolveBlueprint(blueprintArg)
	if err != nil {
		return err
	}
	bpName := bp.AttrStr("name")
	if !approved(yes) {
		ok, err := confirmWrite(fmt.Sprintf("%s %s %s blueprint %s", verb, lc.Name,
			map[string]string{"attach": "to", "detach": "from"}[verb], bpName))
		if err != nil || !ok {
			fmt.Fprintln(os.Stderr, "aborted.")
			return ExitError{Code: 1}
		}
	}
	if verb == "attach" {
		err = i.c.AddBlueprintMembers(bp.ID, "configurations", "configurations", []string{lc.ID})
	} else {
		err = i.c.RemoveBlueprintMembers(bp.ID, "configurations", "configurations", []string{lc.ID})
	}
	if err != nil {
		return err
	}
	if !noWriteTree {
		// Rewrite the manifest to the FULL post-write live membership (not a delta),
		// so the tree can never omit members that `sync --prune` would then detach.
		if err := i.syncBlueprintManifest(bpName, bp.ID, live); err != nil {
			fmt.Fprintf(os.Stderr, "warning: membership changed on ABM but the local manifest update failed: %v\n", err)
		}
	}
	if wantsMachine(jsonOut) {
		return emitWrite(writeOutcome{Action: verb, Name: lc.Name, ID: lc.ID, Blueprint: bpName, TreeUpdated: !noWriteTree}, jsonOut)
	}
	fmt.Fprintf(os.Stderr, "%sed %q %s blueprint %q\n", verb, lc.Name,
		map[string]string{"attach": "to", "detach": "from"}[verb], bpName)
	return nil
}

// --- pull: adopt live config(s) into the git tree (scoped seed) ---

func newPullCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "pull [config <name|id>]",
		Short: "Adopt live config(s) into the git tree + baseline (a scoped `seed`)",
		Long:  "pull re-materializes what's live on Apple into the local gitops tree — the way to adopt an edit made in the Apple Business console. With no argument it pulls all CUSTOM_SETTING configs.",
		Args:  cobra.RangeArgs(0, 2),
		RunE: func(_ *cobra.Command, a []string) error {
			target := ""
			if len(a) == 2 && (a[0] == "config" || a[0] == "configuration") {
				target = a[1]
			} else if len(a) != 0 {
				return fmt.Errorf("usage: abctl pull [config <name|id>]")
			}
			return runPull(target)
		},
	}
	return c
}

func runPull(target string) error {
	i, err := newImp()
	if err != nil {
		return err
	}
	live, err := i.c.FetchCustomSettings()
	if err != nil {
		return err
	}
	n := 0
	for _, l := range live {
		if target != "" && l.Name != target && l.ID != target && l.Name != configName(target) {
			continue
		}
		if err := i.tree.WriteConfig(l.Name, []byte(l.XML)); err != nil {
			return err
		}
		i.base.Configs[l.Name] = state.Entry{ABMID: l.ID, Hash: hash.Raw([]byte(l.XML)), UpdatedDateTime: l.Updated}
		n++
	}
	if target != "" && n == 0 {
		return fmt.Errorf("config %q not found live", target)
	}
	if err := i.base.Save(i.tree.StateFile); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "pulled %d config(s) → %s (review, then `git add gitops/`)\n", n, rel(i.tree.LibDir))
	return nil
}

// --- status (honest proxies — NOT on-device install verification) ---

func newStatusCmd() *cobra.Command {
	c := &cobra.Command{Use: "status", Short: "Assignment / changelog status (desired-state proxies, not on-device install)"}
	c.AddCommand(newStatusConfigCmd(), newStatusAuditCmd())
	return c
}

func newStatusConfigCmd() *cobra.Command {
	var asJSON bool
	c := &cobra.Command{
		Use:     "config <name|id>",
		Aliases: []string{"configuration"},
		Short:   "Which blueprints carry a config, and how many devices they target",
		Args:    cobra.ExactArgs(1),
		RunE:    func(_ *cobra.Command, a []string) error { return runStatusConfig(a[0], asJSON) },
	}
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	return c
}

func runStatusConfig(nameOrID string, asJSON bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	lc, err := resolveLiveConfig(c, nameOrID)
	if err != nil {
		return err
	}
	bps, err := c.ListBlueprints()
	if err != nil {
		return err
	}
	type cov struct {
		Blueprint string `json:"blueprint"`
		Devices   int    `json:"devices"`
	}
	var carriers []cov
	totalDevices := 0
	for _, bp := range bps {
		links, _ := c.BlueprintRelationship(bp.ID, "configurations")
		on := false
		for _, l := range links {
			if l.ID == lc.ID {
				on = true
				break
			}
		}
		if !on {
			continue
		}
		devs, _ := c.BlueprintRelationship(bp.ID, "orgDevices")
		carriers = append(carriers, cov{Blueprint: bp.AttrStr("name"), Devices: len(devs)})
		totalDevices += len(devs)
	}
	fmt.Fprintln(os.Stderr, "NOTE: desired-state / assignment intent — NOT on-device install confirmation (the Apple Business API cannot report per-device install status).")
	data := map[string]any{"config": lc.Name, "blueprints": carriers, "targeted_devices": totalDevices}
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), data, nil, nil)
	}
	rows := make([][]string, 0, len(carriers))
	for _, c := range carriers {
		rows = append(rows, []string{c.Blueprint, fmt.Sprintf("%d", c.Devices)})
	}
	printTable([]string{"BLUEPRINT", "DEVICES"}, rows)
	fmt.Fprintf(os.Stderr, "%s: attached to %d blueprint(s), targeting %d device(s)\n", lc.Name, len(carriers), totalDevices)
	return nil
}

func newStatusAuditCmd() *cobra.Command {
	var asJSON bool
	var since, typ, actor string
	c := &cobra.Command{
		Use:   "audit",
		Short: "Config/device change history from auditEvents (the 'did my change land' proxy)",
		Args:  cobra.NoArgs,
		RunE:  func(_ *cobra.Command, _ []string) error { return runStatusAudit(since, typ, actor, asJSON) },
	}
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	c.Flags().StringVar(&since, "since", "24h", "look-back window (e.g. 24h, 7d)")
	c.Flags().StringVar(&typ, "type", "", "filter by eventType (e.g. CONFIG_SETTINGS_UPDATED)")
	c.Flags().StringVar(&actor, "actor", "", "filter by actor (substring)")
	return c
}

func runStatusAudit(since, typ, actor string, asJSON bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	dur, err := parseSince(since)
	if err != nil {
		return err
	}
	end := time.Now().UTC()
	items, err := c.AuditEvents(end.Add(-dur).Format(time.RFC3339), end.Format(time.RFC3339))
	if err != nil {
		return err
	}
	filtered := items[:0:0]
	for _, it := range items {
		a := it.Attr()
		if typ != "" && !strings.EqualFold(it.AttrStr("eventType"), typ) {
			continue
		}
		if actor != "" {
			an, _ := a["actorName"].(string)
			ai, _ := a["actorId"].(string)
			if !strings.Contains(strings.ToLower(an+" "+ai), strings.ToLower(actor)) {
				continue
			}
		}
		filtered = append(filtered, it)
	}
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), filtered, nil, nil)
	}
	rows := make([][]string, 0, len(filtered))
	for _, it := range filtered {
		a := it.Attr()
		t, _ := a["eventTime"].(string)
		if t == "" {
			t, _ = a["createdDateTime"].(string)
		}
		actorName, _ := a["actorName"].(string)
		if actorName == "" {
			actorName, _ = a["actorId"].(string)
		}
		rows = append(rows, []string{t, it.AttrStr("eventType"), actorName})
	}
	printTable([]string{"TIME", "EVENT", "ACTOR"}, rows)
	fmt.Fprintf(os.Stderr, "%d event(s) in last %s%s\n", len(filtered), since, filterNote(typ, actor))
	return nil
}

func filterNote(typ, actor string) string {
	var p []string
	if typ != "" {
		p = append(p, "type="+typ)
	}
	if actor != "" {
		p = append(p, "actor~"+actor)
	}
	if len(p) == 0 {
		return ""
	}
	return " (" + strings.Join(p, ", ") + ")"
}
