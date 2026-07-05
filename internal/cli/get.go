package cli

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/GigaionLLC/abcli/internal/ab"
)

func newGetCmd() *cobra.Command {
	get := &cobra.Command{Use: "get", Short: "Read-only inspection (table by default, --json for machine output)"}

	var cJSON bool
	var cType string
	configs := &cobra.Command{
		Use: "configurations", Aliases: []string{"configs"}, Short: "List configurations", Args: cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error { return getConfigurations(cJSON, cType) },
	}
	configs.Flags().BoolVar(&cJSON, "json", false, "JSON output")
	configs.Flags().StringVar(&cType, "type", "", "filter by config type (e.g. CUSTOM_SETTING)")

	var oJSON, profile bool
	oneCfg := &cobra.Command{
		Use: "configuration <name|id>", Aliases: []string{"config"}, Short: "Get one configuration", Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error { return getConfiguration(a[0], oJSON, profile) },
	}
	oneCfg.Flags().BoolVar(&oJSON, "json", false, "JSON output")
	oneCfg.Flags().BoolVar(&profile, "profile", false, "dump the raw .mobileconfig XML")

	var bJSON bool
	bps := &cobra.Command{Use: "blueprints", Aliases: []string{"bp"}, Short: "List blueprints", Args: cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error { return getBlueprints(bJSON) }}
	bps.Flags().BoolVar(&bJSON, "json", false, "JSON output")

	var bpJSON bool
	bp := &cobra.Command{Use: "blueprint <name|id>", Short: "Get one blueprint (with member counts)", Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error { return getBlueprint(a[0], bpJSON) }}
	bp.Flags().BoolVar(&bpJSON, "json", false, "JSON output")

	var dJSON bool
	dev := &cobra.Command{Use: "devices", Short: "List org devices", Args: cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error { return getDevices(dJSON) }}
	dev.Flags().BoolVar(&dJSON, "json", false, "JSON output")

	var aJSON bool
	var since string
	aud := &cobra.Command{Use: "audit", Short: "List audit events", Args: cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error { return getAudit(since, aJSON) }}
	aud.Flags().BoolVar(&aJSON, "json", false, "JSON output")
	aud.Flags().StringVar(&since, "since", "24h", "look-back window (e.g. 24h, 7d, 90d)")

	get.AddCommand(configs, oneCfg, bps, bp, dev, aud)
	get.AddCommand(
		readCmd("users", "List users", (*ab.Client).ListUsers,
			[]string{"NAME", "EMAIL", "ROLES"}, func(r ab.Resource) []string {
				a := r.Attr()
				name := strings.TrimSpace(fmt.Sprintf("%v %v", a["firstName"], a["lastName"]))
				return []string{name, r.AttrStr("email"), fmt.Sprintf("%v", a["roles"])}
			}),
		readCmd("usergroups", "List user groups", (*ab.Client).ListUserGroups,
			[]string{"NAME", "ID", "MEMBERS"}, func(r ab.Resource) []string {
				return []string{r.AttrStr("name"), r.ID, fmt.Sprintf("%v", r.Attr()["totalMemberCount"])}
			}),
		readCmd("apps", "List apps (Apps & Books)", (*ab.Client).ListApps,
			[]string{"NAME", "BUNDLE_ID", "ID"}, func(r ab.Resource) []string {
				return []string{r.AttrStr("name"), r.AttrStr("bundleId"), r.ID}
			}),
		readCmd("mdmservers", "List MDM servers", (*ab.Client).ListMDMServers,
			[]string{"NAME", "TYPE", "ID"}, func(r ab.Resource) []string {
				return []string{r.AttrStr("serverName"), r.AttrStr("serverType"), r.ID}
			}),
	)
	return get
}

// readCmd builds a read-only `get <resource>` subcommand: fetch, optional
// --filter (attribute substring), then render as table/json/yaml.
func readCmd(use, short string, list func(*ab.Client) ([]ab.Resource, error), cols []string, row func(ab.Resource) []string) *cobra.Command {
	var asJSON bool
	var filters []string
	c := &cobra.Command{
		Use: use, Short: short, Args: cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			cl, _, err := mustClient()
			if err != nil {
				return err
			}
			items, err := list(cl)
			if err != nil {
				return err
			}
			items = applyFilter(items, filters)
			if asJSON || flagOutput != "table" {
				return render(outFmt(asJSON), items, nil, nil)
			}
			rows := make([][]string, 0, len(items))
			for _, it := range items {
				rows = append(rows, row(it))
			}
			printTable(cols, rows)
			fmt.Fprintf(os.Stderr, "%d %s\n", len(items), use)
			return nil
		},
	}
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	c.Flags().StringArrayVar(&filters, "filter", nil, "keep items whose attribute contains a value: key=substr (repeatable, AND)")
	return c
}

// applyFilter keeps resources whose string attribute for key contains the value
// (case-insensitive). Multiple filters are ANDed. This is client-side inventory
// filtering — NOT a live query (the Apple Business API has no query engine).
func applyFilter(items []ab.Resource, filters []string) []ab.Resource {
	if len(filters) == 0 {
		return items
	}
	out := items[:0:0]
	for _, it := range items {
		keep := true
		for _, f := range filters {
			k, v, ok := strings.Cut(f, "=")
			if !ok {
				continue
			}
			if !strings.Contains(strings.ToLower(fmt.Sprintf("%v", it.Attr()[k])), strings.ToLower(v)) {
				keep = false
				break
			}
		}
		if keep {
			out = append(out, it)
		}
	}
	return out
}

func getConfigurations(asJSON bool, typ string) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	items, err := c.ListConfigurations()
	if err != nil {
		return err
	}
	if typ != "" {
		f := items[:0:0]
		for _, it := range items {
			if strings.EqualFold(it.AttrStr("type"), typ) {
				f = append(f, it)
			}
		}
		items = f
	}
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), items, nil, nil)
	}
	rows := make([][]string, 0, len(items))
	for _, it := range items {
		rows = append(rows, []string{it.AttrStr("name"), it.AttrStr("type"), it.AttrStr("updatedDateTime")})
	}
	printTable([]string{"NAME", "TYPE", "UPDATED"}, rows)
	fmt.Fprintf(os.Stderr, "%d configuration(s)\n", len(items))
	return nil
}

func getConfiguration(nameOrID string, asJSON, profile bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	r, err := c.ResolveConfig(nameOrID)
	if err != nil {
		return err
	}
	full, err := c.GetConfiguration(r.ID)
	if err != nil {
		return err
	}
	if profile {
		csv, _ := full.Attr()["customSettingsValues"].(map[string]any)
		if csv == nil {
			return fmt.Errorf("%q has no customSettingsValues (type %s is not a custom profile)", nameOrID, full.AttrStr("type"))
		}
		xml, _ := csv["configurationProfile"].(string)
		if xml == "" {
			return fmt.Errorf("no configurationProfile content on %q", nameOrID)
		}
		fmt.Print(xml)
		if !strings.HasSuffix(xml, "\n") {
			fmt.Println()
		}
		return nil
	}
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), full, nil, nil)
	}
	fmt.Printf("name     %s\n", full.AttrStr("name"))
	fmt.Printf("id       %s\n", full.ID)
	fmt.Printf("type     %s\n", full.AttrStr("type"))
	fmt.Printf("created  %s\n", full.AttrStr("createdDateTime"))
	fmt.Printf("updated  %s\n", full.AttrStr("updatedDateTime"))
	return nil
}

func getBlueprints(asJSON bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	items, err := c.ListBlueprints()
	if err != nil {
		return err
	}
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), items, nil, nil)
	}
	rows := make([][]string, 0, len(items))
	for _, it := range items {
		rows = append(rows, []string{it.AttrStr("name"), it.AttrStr("status"), it.ID})
	}
	printTable([]string{"NAME", "STATUS", "ID"}, rows)
	fmt.Fprintf(os.Stderr, "%d blueprint(s)\n", len(items))
	return nil
}

func getBlueprint(nameOrID string, asJSON bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	r, err := c.ResolveBlueprint(nameOrID)
	if err != nil {
		return err
	}
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), r, nil, nil)
	}
	configs, _ := c.BlueprintRelationship(r.ID, "configurations")
	devices, _ := c.BlueprintRelationship(r.ID, "orgDevices")
	fmt.Printf("name     %s\n", r.AttrStr("name"))
	fmt.Printf("id       %s\n", r.ID)
	fmt.Printf("status   %s\n", r.AttrStr("status"))
	fmt.Printf("configs  %d\n", len(configs))
	fmt.Printf("devices  %d\n", len(devices))
	return nil
}

func getDevices(asJSON bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	items, err := c.ListDevices()
	if err != nil {
		return err
	}
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), items, nil, nil)
	}
	rows := make([][]string, 0, len(items))
	for _, it := range items {
		rows = append(rows, []string{it.AttrStr("serialNumber"), it.AttrStr("productFamily"), it.AttrStr("deviceModel")})
	}
	printTable([]string{"SERIAL", "FAMILY", "MODEL"}, rows)
	fmt.Fprintf(os.Stderr, "%d device(s)\n", len(items))
	return nil
}

func getAudit(since string, asJSON bool) error {
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
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), items, nil, nil)
	}
	rows := make([][]string, 0, len(items))
	for _, it := range items {
		a := it.Attr()
		t, _ := a["eventTime"].(string)
		if t == "" {
			t, _ = a["createdDateTime"].(string)
		}
		actor, _ := a["actorName"].(string)
		if actor == "" {
			actor, _ = a["actorId"].(string)
		}
		rows = append(rows, []string{t, it.AttrStr("eventType"), actor})
	}
	printTable([]string{"TIME", "EVENT", "ACTOR"}, rows)
	fmt.Fprintf(os.Stderr, "%d event(s) in last %s\n", len(items), since)
	return nil
}

func parseSince(s string) (time.Duration, error) {
	if strings.HasSuffix(s, "d") {
		n, err := strconv.Atoi(strings.TrimSuffix(s, "d"))
		if err != nil {
			return 0, fmt.Errorf("bad --since %q", s)
		}
		return time.Duration(n) * 24 * time.Hour, nil
	}
	return time.ParseDuration(s)
}
