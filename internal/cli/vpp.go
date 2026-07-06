package cli

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"github.com/GigaionLLC/abcli/internal/vpp"
)

func newVPPCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "vpp",
		Short: "Apps & Books (VPP) license inventory — read-only (App and Book Management API v2)",
		Long: "vpp reads the organization's Apps & Books license inventory from Apple's App and\n" +
			"Book Management API (vpp.itunes.apple.com/mdm/v2) — a SEPARATE service from the\n" +
			"Business API, authenticated with a content token (sToken) from Apple Business\n" +
			"Manager → Apps and Books → content token. Read-only.\n" +
			"Token resolution: --vpp-token, else $AB_VPP_TOKEN, else $AB_VPP_TOKEN_FILE (a path).",
	}
	c.PersistentFlags().String("vpp-token", "", "VPP content token (sToken); else $AB_VPP_TOKEN / $AB_VPP_TOKEN_FILE")
	c.AddCommand(
		newVPPConfigCmd(), newVPPAssetsCmd(), newVPPAssignmentsCmd(), newVPPUsersCmd(),
		newVPPManageCmd("associate"), newVPPManageCmd("disassociate"), newVPPStatusCmd(),
	)
	return c
}

func vppClient(cmd *cobra.Command) (*vpp.Client, error) {
	flag, _ := cmd.Flags().GetString("vpp-token")
	token, err := resolveVPPToken(flag)
	if err != nil {
		return nil, err
	}
	return vpp.NewClient(token, os.Getenv("AB_VPP_BASE")), nil
}

// resolveVPPToken: --vpp-token › $AB_VPP_TOKEN › $AB_VPP_TOKEN_FILE.
func resolveVPPToken(flag string) (string, error) {
	if flag != "" {
		return strings.TrimSpace(flag), nil
	}
	if t := os.Getenv("AB_VPP_TOKEN"); t != "" {
		return strings.TrimSpace(t), nil
	}
	if p := os.Getenv("AB_VPP_TOKEN_FILE"); p != "" {
		b, err := os.ReadFile(p)
		if err != nil {
			return "", fmt.Errorf("reading $AB_VPP_TOKEN_FILE: %w", err)
		}
		return strings.TrimSpace(string(b)), nil
	}
	return "", fmt.Errorf("no VPP content token: set --vpp-token, $AB_VPP_TOKEN, or $AB_VPP_TOKEN_FILE " +
		"(Apple Business Manager → Apps and Books → download a content token)")
}

func newVPPConfigCmd() *cobra.Command {
	var asJSON bool
	c := &cobra.Command{
		Use:   "config",
		Short: "Show VPP service config + limits (validates the content token)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cl, err := vppClient(cmd)
			if err != nil {
				return err
			}
			sc, err := cl.ServiceConfig()
			if err != nil {
				return err
			}
			// GET /service/config is lenient — it returns even for a REVOKED token — so
			// probe a data endpoint (assets) to truly validate the token before saying OK.
			assets, aerr := cl.GetAssets(vpp.AssetFilter{})
			if aerr != nil {
				return fmt.Errorf("service config reachable, but the content token is not valid for data: %w", aerr)
			}
			if asJSON || flagOutput != "table" {
				return render(outFmt(asJSON), sc, nil, nil)
			}
			fmt.Println("VPP content token OK ✓")
			if sc.LocationName != "" {
				fmt.Printf("  location   %s\n", sc.LocationName)
			}
			if sc.TokenExpiration != "" {
				fmt.Printf("  expires    %s\n", sc.TokenExpiration)
			}
			fmt.Printf("  endpoints  %d\n", len(sc.URLs))
			fmt.Printf("  maxAssets  %d\n", sc.Limits["maxAssets"])
			fmt.Printf("  assets     %d reachable\n", len(assets))
			return nil
		},
	}
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	return c
}

func newVPPAssetsCmd() *cobra.Command {
	var asJSON, noNames bool
	var typ, pricing, adamID string
	c := &cobra.Command{
		Use:   "assets",
		Short: "List owned apps/books + license counts (names resolved via iTunes lookup)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cl, err := vppClient(cmd)
			if err != nil {
				return err
			}
			assets, err := cl.GetAssets(vpp.AssetFilter{ProductType: typ, PricingParam: pricing, AdamID: adamID})
			if err != nil {
				return err
			}
			resolveAssetNames(assets, noNames) // best-effort; leaves Name blank on failure
			if asJSON || flagOutput != "table" {
				return render(outFmt(asJSON), asList(assets), nil, nil)
			}
			rows := make([][]string, 0, len(assets))
			for _, a := range assets {
				rows = append(rows, []string{a.Name, a.AdamID, a.ProductType, a.PricingParam,
					strconv.Itoa(a.AvailableCount), strconv.Itoa(a.AssignedCount), strconv.Itoa(a.TotalCount)})
			}
			printTable([]string{"NAME", "ADAM_ID", "TYPE", "PRICING", "AVAILABLE", "ASSIGNED", "TOTAL"}, rows)
			fmt.Fprintf(os.Stderr, "%d asset(s)\n", len(assets))
			return nil
		},
	}
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	c.Flags().BoolVar(&noNames, "no-names", false, "skip resolving app/book names via the public iTunes lookup")
	c.Flags().StringVar(&typ, "type", "", "filter by product type: App | Book")
	c.Flags().StringVar(&pricing, "pricing", "", "filter by pricing: STDQ | PLUS")
	c.Flags().StringVar(&adamID, "adam-id", "", "filter by product adamId")
	return c
}

// resolveAssetNames fills in each asset's Name from the public iTunes lookup (best-effort:
// network/lookup failures leave names blank rather than failing the command).
func resolveAssetNames(assets []vpp.Asset, skip bool) {
	if skip || len(assets) == 0 {
		return
	}
	ids := make([]string, 0, len(assets))
	for _, a := range assets {
		ids = append(ids, a.AdamID)
	}
	names, err := vpp.NewLookup(os.Getenv("AB_ITUNES_BASE")).Names(ids)
	if err != nil && len(names) == 0 {
		return
	}
	for i := range assets {
		if n := names[assets[i].AdamID]; n != "" {
			assets[i].Name = n
		}
	}
}

func newVPPAssignmentsCmd() *cobra.Command {
	var asJSON bool
	var adamID, serial, user string
	c := &cobra.Command{
		Use:   "assignments",
		Short: "List license assignments (asset → device/user)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cl, err := vppClient(cmd)
			if err != nil {
				return err
			}
			items, err := cl.GetAssignments(vpp.AssignmentFilter{AdamID: adamID, SerialNumber: serial, ClientUserID: user})
			if err != nil {
				return err
			}
			if asJSON || flagOutput != "table" {
				return render(outFmt(asJSON), asList(items), nil, nil)
			}
			rows := make([][]string, 0, len(items))
			for _, a := range items {
				rows = append(rows, []string{a.AdamID, a.PricingParam, a.SerialNumber, a.ClientUserID})
			}
			printTable([]string{"ADAM_ID", "PRICING", "SERIAL", "CLIENT_USER_ID"}, rows)
			fmt.Fprintf(os.Stderr, "%d assignment(s)\n", len(items))
			return nil
		},
	}
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	c.Flags().StringVar(&adamID, "adam-id", "", "filter by product adamId")
	c.Flags().StringVar(&serial, "serial", "", "filter by device serial number")
	c.Flags().StringVar(&user, "user", "", "filter by clientUserId")
	return c
}

// newVPPManageCmd builds `vpp associate` / `vpp disassociate` — GATED license writes.
func newVPPManageCmd(verb string) *cobra.Command {
	var adamIDs, serials, users []string
	var pricing string
	var yes, asJSON bool
	prep := map[string]string{"associate": "to", "disassociate": "from"}[verb]
	c := &cobra.Command{
		Use:   verb,
		Short: verb + " app/book licenses " + prep + " devices (--serial) and/or users (--user)",
		Long: verb + " assigns" + map[string]string{"associate": "", "disassociate": "/unassigns"}[verb] +
			" one or more assets " + prep + " devices and/or users. This is an ASYNC tenant write —\n" +
			"it returns an eventId; poll it with `abctl vpp status <eventId>`. Gated: confirm unless\n" +
			"--yes / $ABCTL_APPROVE. Limits: <=25 assets, <=1000 serials or users per call.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if len(adamIDs) == 0 {
				return fmt.Errorf("need at least one --adam-id")
			}
			if len(serials) == 0 && len(users) == 0 {
				return fmt.Errorf("need at least one --serial (device) or --user (clientUserId)")
			}
			cl, err := vppClient(cmd)
			if err != nil {
				return err
			}
			assets := make([]vpp.AssetRef, 0, len(adamIDs))
			for _, id := range adamIDs {
				assets = append(assets, vpp.AssetRef{AdamID: id, PricingParam: pricing})
			}
			if !approved(yes) {
				desc := fmt.Sprintf("%s %d asset(s) %s %d device(s) + %d user(s)", verb, len(adamIDs), prep, len(serials), len(users))
				ok, cerr := confirmWrite(desc)
				if cerr != nil || !ok {
					fmt.Fprintln(os.Stderr, "aborted.")
					return ExitError{Code: 1}
				}
			}
			var res *vpp.EventResult
			if verb == "associate" {
				res, err = cl.AssociateAssets(assets, serials, users)
			} else {
				res, err = cl.DisassociateAssets(assets, serials, users)
			}
			if err != nil {
				return err
			}
			if asJSON || flagOutput != "table" {
				return render(outFmt(asJSON), res, nil, nil)
			}
			fmt.Printf("%s queued ✓  eventId %s\n", verb, res.EventID)
			fmt.Fprintf(os.Stderr, "poll: abctl vpp status %s\n", res.EventID)
			return nil
		},
	}
	c.Flags().StringArrayVar(&adamIDs, "adam-id", nil, "product adamId (repeatable)")
	c.Flags().StringVar(&pricing, "pricing", "STDQ", "pricing param: STDQ | PLUS")
	c.Flags().StringArrayVar(&serials, "serial", nil, "device serial number (repeatable)")
	c.Flags().StringArrayVar(&users, "user", nil, "clientUserId (repeatable)")
	c.Flags().BoolVar(&yes, "yes", false, "skip confirmation (also: $ABCTL_APPROVE=1)")
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	return c
}

// newVPPStatusCmd polls an async associate/disassociate event.
func newVPPStatusCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "status <eventId>",
		Short: "Poll an async associate/disassociate event",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, a []string) error {
			cl, err := vppClient(cmd)
			if err != nil {
				return err
			}
			st, err := cl.EventStatus(a[0])
			if err != nil {
				return err
			}
			format := flagOutput
			if format == "table" { // no meaningful table for a raw event map
				format = "json"
			}
			return render(format, st, nil, nil)
		},
	}
	return c
}

func newVPPUsersCmd() *cobra.Command {
	var asJSON bool
	c := &cobra.Command{
		Use:   "users",
		Short: "List registered VPP users",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cl, err := vppClient(cmd)
			if err != nil {
				return err
			}
			users, err := cl.GetUsers()
			if err != nil {
				return err
			}
			if asJSON || flagOutput != "table" {
				return render(outFmt(asJSON), asList(users), nil, nil)
			}
			rows := make([][]string, 0, len(users))
			for _, u := range users {
				rows = append(rows, []string{u.ClientUserID, u.Email, u.Status})
			}
			printTable([]string{"CLIENT_USER_ID", "EMAIL", "STATUS"}, rows)
			fmt.Fprintf(os.Stderr, "%d user(s)\n", len(users))
			return nil
		},
	}
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	return c
}
