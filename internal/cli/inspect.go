package cli

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/gdmf"
)

// --- singular `get` inspection commands (Apple Business API v2 surface, Phase A) ---

// inspectGetCmds builds the singular/detail `get` subcommands (registered by newGetCmd).
func inspectGetCmds() []*cobra.Command {
	var devJSON, devCare bool
	device := &cobra.Command{
		Use: "device <serial|id>", Short: "Get one org device (full attributes + assigned MDM server)", Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error { return getDevice(a[0], devCare, devJSON) },
	}
	device.Flags().BoolVar(&devJSON, "json", false, "JSON output")
	device.Flags().BoolVar(&devCare, "applecare", false, "include AppleCare coverage (one extra API call)")

	mdmDevices := readCmd("mdmdevices", "List built-in-MDM devices", (*ab.Client).ListMDMDevices,
		[]string{"SERIAL", "NAME", "FAMILY", "ENROLLED USER"}, func(r ab.Resource) []string {
			return []string{r.AttrStr("serialNumber"), r.AttrStr("deviceName"), r.AttrStr("productFamily"), r.AttrStr("enrolledUserId")}
		})

	var mdJSON bool
	mdmDevice := &cobra.Command{
		Use: "mdmdevice <serial|id>", Short: "Get one built-in-MDM device (attributes + last-reported posture)", Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error { return getMDMDevice(a[0], mdJSON) },
	}
	mdmDevice.Flags().BoolVar(&mdJSON, "json", false, "JSON output")

	var uJSON bool
	user := &cobra.Command{
		Use: "user <email|id>", Short: "Get one user (read-only; identity is not API-writable)", Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error { return getUser(a[0], uJSON) },
	}
	user.Flags().BoolVar(&uJSON, "json", false, "JSON output")

	var gJSON, gMembers bool
	group := &cobra.Command{
		Use: "usergroup <name|id>", Short: "Get one user group", Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error { return getUserGroup(a[0], gMembers, gJSON) },
	}
	group.Flags().BoolVar(&gJSON, "json", false, "JSON output")
	group.Flags().BoolVar(&gMembers, "members", false, "list member emails (one API call per member)")

	var appJSON bool
	app := &cobra.Command{
		Use: "app <name|id>", Short: "Get one owned app (Apps & Books)", Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error { return getApp(a[0], appJSON) },
	}
	app.Flags().BoolVar(&appJSON, "json", false, "JSON output")

	var pkgJSON bool
	pkg := &cobra.Command{
		Use: "package <name|id>", Short: "Get one package (custom app/pkg)", Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error { return getPackage(a[0], pkgJSON) },
	}
	pkg.Flags().BoolVar(&pkgJSON, "json", false, "JSON output")

	var srvJSON, srvDevices bool
	server := &cobra.Command{
		Use: "mdmserver <name|id>", Short: "Get one MDM server", Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error { return getMDMServer(a[0], srvDevices, srvJSON) },
	}
	server.Flags().BoolVar(&srvJSON, "json", false, "JSON output")
	server.Flags().BoolVar(&srvDevices, "devices", false, "list the serial numbers of the server's assigned devices")

	return []*cobra.Command{device, mdmDevices, mdmDevice, user, group, app, pkg, server}
}

// printKV renders label/value detail lines aligned with a tabwriter (the
// many-field sibling of the fixed-width labels in getConfiguration).
func printKV(pairs [][2]string) {
	tw := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	for _, p := range pairs {
		_, _ = fmt.Fprintf(tw, "%s\t%s\n", p[0], p[1])
	}
	_ = tw.Flush()
}

// attrJoin renders a list attribute (e.g. imei[]) as a comma-joined string.
func attrJoin(a map[string]any, key string) string {
	items, _ := a[key].([]any)
	parts := make([]string, 0, len(items))
	for _, it := range items {
		parts = append(parts, fmt.Sprintf("%v", it))
	}
	return strings.Join(parts, ", ")
}

// boolAttr renders a boolean posture attribute as enabled/disabled ("" when unreported).
func boolAttr(a map[string]any, key string) string {
	v, ok := a[key].(bool)
	if !ok {
		return ""
	}
	if v {
		return "enabled"
	}
	return "disabled"
}

// intAttr renders a numeric attribute (JSON numbers decode as float64) as an integer string.
func intAttr(a map[string]any, key string) string {
	if f, ok := a[key].(float64); ok {
		return strconv.Itoa(int(f))
	}
	return ""
}

// storageUsed renders "used of total" in GB from the byte-count posture attributes.
func storageUsed(a map[string]any) string {
	free, fok := a["storageFreeCapacity"].(float64)
	total, tok := a["storageTotalCapacity"].(float64)
	if !fok || !tok || total <= 0 {
		return ""
	}
	return fmt.Sprintf("%.1f GB used of %.1f GB", (total-free)/1e9, total/1e9)
}

// --- get device ---

func getDevice(serialOrID string, appleCare, asJSON bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	dev, err := c.ResolveDevice(serialOrID)
	if err != nil {
		return err
	}
	var server *ab.Resource
	if dev.AttrStr("status") == "ASSIGNED" {
		if server, err = c.DeviceAssignedServer(dev.ID); err != nil {
			return err
		}
	}
	var coverage []ab.Resource
	if appleCare {
		if coverage, err = c.DeviceAppleCare(dev.ID); err != nil {
			return err
		}
	}
	if asJSON || flagOutput != "table" {
		data := map[string]any{"device": dev, "assignedServer": server} // server nil → null (unassigned)
		if appleCare {
			data["appleCare"] = asList(coverage)
		}
		return render(outFmt(asJSON), data, nil, nil)
	}
	a := dev.Attr()
	rows := [][2]string{
		{"serial", dev.AttrStr("serialNumber")},
		{"id", dev.ID},
		{"model", dev.AttrStr("deviceModel")},
		{"family", dev.AttrStr("productFamily")},
		{"product type", dev.AttrStr("productType")},
		{"capacity", dev.AttrStr("deviceCapacity")},
		{"color", dev.AttrStr("color")},
		{"status", dev.AttrStr("status")},
		{"part number", dev.AttrStr("partNumber")},
		{"order number", dev.AttrStr("orderNumber")},
		{"ordered", dev.AttrStr("orderDateTime")},
		{"purchase source", strings.TrimSpace(dev.AttrStr("purchaseSourceType") + " " + dev.AttrStr("purchaseSourceId"))},
		{"added to org", dev.AttrStr("addedToOrgDateTime")},
		{"released", dev.AttrStr("releasedFromOrgDateTime")},
		{"released by", strings.TrimSpace(dev.AttrStr("releaserEntityType") + " " + dev.AttrStr("releaserId"))},
		{"updated", dev.AttrStr("updatedDateTime")},
		{"imei", attrJoin(a, "imei")},
		{"meid", attrJoin(a, "meid")},
		{"eid", dev.AttrStr("eid")},
		{"wifi mac", dev.AttrStr("wifiMacAddress")},
		{"bluetooth mac", dev.AttrStr("bluetoothMacAddress")},
		{"ethernet mac", attrJoin(a, "ethernetMacAddress")},
	}
	if dev.AttrStr("status") == "ASSIGNED" {
		name := "(none)"
		if server != nil {
			name = server.AttrStr("serverName")
		}
		rows = append(rows, [2]string{"assigned server", name})
	}
	printKV(rows)
	if appleCare {
		printAppleCare(coverage)
	}
	return nil
}

// printAppleCare renders AppleCare coverage records as a table section.
func printAppleCare(coverage []ab.Resource) {
	fmt.Println("applecare")
	if len(coverage) == 0 {
		fmt.Println("  (no coverage records)")
		return
	}
	rows := make([][]string, 0, len(coverage))
	for _, cv := range coverage {
		rows = append(rows, []string{cv.AttrStr("description"), cv.AttrStr("status"), cv.AttrStr("paymentType"), cv.AttrStr("endDateTime")})
	}
	printTable([]string{"COVERAGE", "STATUS", "PAYMENT", "ENDS"}, rows)
}

// --- get mdmdevice ---

// resolveMDMDevice finds a built-in-MDM device by id or serial number (serials
// compare case-insensitively). The API has no by-serial lookup, so it lists and
// matches — mirroring ab.ResolveDevice.
func resolveMDMDevice(c *ab.Client, serialOrID string) (*ab.Resource, error) {
	devs, err := c.ListMDMDevices()
	if err != nil {
		return nil, err
	}
	var bySerial []*ab.Resource
	for i := range devs {
		if devs[i].ID == serialOrID {
			return &devs[i], nil
		}
		if strings.EqualFold(devs[i].AttrStr("serialNumber"), serialOrID) {
			bySerial = append(bySerial, &devs[i])
		}
	}
	switch len(bySerial) {
	case 1:
		return bySerial[0], nil
	case 0:
		return nil, fmt.Errorf("built-in-MDM device %q not found (by serial number or id) — the device may not be enrolled in built-in MDM", serialOrID)
	default:
		return nil, fmt.Errorf("built-in-MDM device serial %q is ambiguous (%d devices share it) — use the device id", serialOrID, len(bySerial))
	}
}

func getMDMDevice(serialOrID string, asJSON bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	dev, err := resolveMDMDevice(c, serialOrID)
	if err != nil {
		return err
	}
	details, err := c.GetMDMDeviceDetails(dev.ID)
	if err != nil {
		return err
	}
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), map[string]any{"device": dev, "details": details}, nil, nil)
	}
	a := details.Attr()
	printKV([][2]string{
		{"name", dev.AttrStr("deviceName")},
		{"serial", dev.AttrStr("serialNumber")},
		{"id", dev.ID},
		{"family", dev.AttrStr("productFamily")},
		{"model", details.AttrStr("deviceModel")},
		{"os", strings.TrimSpace(details.AttrStr("platform") + " " + details.AttrStr("osVersion"))},
		{"enrolled user", dev.AttrStr("enrolledUserId")},
		{"last check-in", details.AttrStr("lastCheckInDateTime")},
		{"filevault", boolAttr(a, "isFileVaultEnabled")},
		{"firewall", boolAttr(a, "isFirewallEnabled")},
		{"storage", storageUsed(a)},
		{"lock", details.AttrStr("deviceLockStatus")},
		{"erase", details.AttrStr("deviceEraseStatus")},
		{"lost mode", details.AttrStr("lostModeStatus")},
	})
	return nil
}

// --- get user / usergroup ---

func getUser(emailOrID string, asJSON bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	u, err := c.ResolveUser(emailOrID)
	if err != nil {
		return err
	}
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), u, nil, nil)
	}
	a := u.Attr()
	name := strings.Join(strings.Fields(u.AttrStr("firstName")+" "+u.AttrStr("middleName")+" "+u.AttrStr("lastName")), " ")
	external := ""
	if b, ok := a["isExternalUser"].(bool); ok {
		external = strconv.FormatBool(b)
	}
	printKV([][2]string{
		{"name", name},
		{"id", u.ID},
		{"email", u.AttrStr("email")},
		{"managed account", u.AttrStr("managedAppleAccount")},
		{"status", u.AttrStr("status")},
		{"external", external},
		{"roles", userRoles(a)},
		{"phone", attrJoin(a, "phoneNumbers")},
		{"employee number", u.AttrStr("employeeNumber")},
		{"cost center", u.AttrStr("costCenter")},
		{"division", u.AttrStr("division")},
		{"department", u.AttrStr("department")},
		{"job title", u.AttrStr("jobTitle")},
		{"started", u.AttrStr("startDateTime")},
		{"created", u.AttrStr("createdDateTime")},
		{"updated", u.AttrStr("updatedDateTime")},
	})
	return nil
}

// userRoles renders roleOuList ([{roleName, ouId}]) as a comma-joined role list.
func userRoles(a map[string]any) string {
	rl, _ := a["roleOuList"].([]any)
	var out []string
	for _, r := range rl {
		if m, ok := r.(map[string]any); ok {
			if n, _ := m["roleName"].(string); n != "" {
				out = append(out, n)
			}
		}
	}
	return strings.Join(out, ", ")
}

func getUserGroup(nameOrID string, members, asJSON bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	g, err := c.ResolveUserGroup(nameOrID)
	if err != nil {
		return err
	}
	var emails []string
	if members {
		ids, err := c.UserGroupUserIDs(g.ID)
		if err != nil {
			return err
		}
		// N+1 by design: one GetUser per member id (groups are small; there is no
		// bulk id→user endpoint). An unresolvable member id passes through as-is.
		for _, id := range ids {
			u, err := c.GetUser(id)
			if err != nil {
				emails = append(emails, id)
				continue
			}
			e := u.AttrStr("email")
			if e == "" {
				e = u.AttrStr("managedAppleAccount")
			}
			if e == "" {
				e = id
			}
			emails = append(emails, e)
		}
		sort.Strings(emails)
	}
	if asJSON || flagOutput != "table" {
		data := map[string]any{"group": g}
		if members {
			data["members"] = asList(emails)
		}
		return render(outFmt(asJSON), data, nil, nil)
	}
	printKV([][2]string{
		{"name", g.AttrStr("name")},
		{"id", g.ID},
		{"members", intAttr(g.Attr(), "totalMemberCount")},
	})
	if members {
		fmt.Println("members")
		for _, e := range emails {
			fmt.Println("  " + e)
		}
	}
	return nil
}

// --- get app / package / mdmserver ---

func getApp(nameOrID string, asJSON bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	app, err := c.ResolveApp(nameOrID)
	if err != nil {
		return err
	}
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), app, nil, nil)
	}
	printKV([][2]string{
		{"name", app.AttrStr("name")},
		{"id", app.ID},
		{"bundle id", app.AttrStr("bundleId")},
	})
	return nil
}

func getPackage(nameOrID string, asJSON bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	pkg, err := c.ResolvePackage(nameOrID)
	if err != nil {
		return err
	}
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), pkg, nil, nil)
	}
	printKV([][2]string{
		{"name", pkg.AttrStr("name")},
		{"id", pkg.ID},
		{"bundle id", pkg.AttrStr("bundleId")},
		{"version", pkg.AttrStr("version")},
	})
	return nil
}

func getMDMServer(nameOrID string, withDevices, asJSON bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	srv, err := c.ResolveMDMServer(nameOrID)
	if err != nil {
		return err
	}
	var serials []string
	if withDevices {
		ids, err := c.MDMServerDeviceIDs(srv.ID)
		if err != nil {
			return err
		}
		if len(ids) > 0 {
			// One ListDevices for the id→serial map — NOT a GetDevice per id.
			devs, err := c.ListDevices()
			if err != nil {
				return err
			}
			serialByID := make(map[string]string, len(devs))
			for _, d := range devs {
				serialByID[d.ID] = d.AttrStr("serialNumber")
			}
			for _, id := range ids {
				if s := serialByID[id]; s != "" {
					serials = append(serials, s)
				} else {
					serials = append(serials, id)
				}
			}
			sort.Strings(serials)
		}
	}
	if asJSON || flagOutput != "table" {
		data := map[string]any{"server": srv}
		if withDevices {
			data["devices"] = asList(serials)
			data["deviceCount"] = len(serials)
		}
		return render(outFmt(asJSON), data, nil, nil)
	}
	printKV([][2]string{
		{"name", srv.AttrStr("serverName")},
		{"id", srv.ID},
		{"type", srv.AttrStr("serverType")},
		{"created", srv.AttrStr("createdDateTime")},
		{"updated", srv.AttrStr("updatedDateTime")},
	})
	if withDevices {
		fmt.Printf("devices  %d\n", len(serials))
		for _, s := range serials {
			fmt.Println("  " + s)
		}
	}
	return nil
}

// --- status device (registered beside status config/audit in deploy.go) ---

func newStatusDeviceCmd() *cobra.Command {
	var asJSON, appleCare, releases bool
	c := &cobra.Command{
		Use:   "device <serial|id>",
		Short: "One device end-to-end: MDM server, blueprints + their configs, built-in-MDM posture",
		Args:  cobra.ExactArgs(1),
		RunE:  func(_ *cobra.Command, a []string) error { return runStatusDevice(a[0], appleCare, releases, asJSON) },
	}
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	c.Flags().BoolVar(&appleCare, "applecare", false, "include AppleCare coverage (one extra API call)")
	c.Flags().BoolVar(&releases, "releases", false, "compare last-reported OS with Apple's release catalog")
	return c
}

func runStatusDevice(serialOrID string, appleCare, releases, asJSON bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	dev, err := c.ResolveDevice(serialOrID)
	if err != nil {
		return err
	}
	server, err := c.DeviceAssignedServer(dev.ID) // nil when unassigned (Apple answers 404)
	if err != nil {
		return err
	}
	// Blueprints containing the device: one relationship call per blueprint
	// (blueprints are few — same shape as `status config`).
	bps, err := c.ListBlueprints()
	if err != nil {
		return err
	}
	type bpCov struct {
		Blueprint      string   `json:"blueprint"`
		Configurations []string `json:"configurations"`
	}
	var carriers []bpCov
	var cfgNameByID map[string]string // lazy: fetched once, only if a blueprint matches
	for _, bp := range bps {
		// Propagate relationship errors: a swallowed failure here would render as
		// "blueprints (none)" — an affirmatively false coverage statement.
		links, err := c.BlueprintRelationship(bp.ID, "orgDevices")
		if err != nil {
			return fmt.Errorf("checking blueprint %q device membership: %w", bp.AttrStr("name"), err)
		}
		on := false
		for _, l := range links {
			if l.ID == dev.ID {
				on = true
				break
			}
		}
		if !on {
			continue
		}
		if cfgNameByID == nil {
			cfgNameByID = map[string]string{}
			cfgs, err := c.ListConfigurations()
			if err != nil {
				return fmt.Errorf("resolving configuration names: %w", err)
			}
			for _, cf := range cfgs {
				cfgNameByID[cf.ID] = cf.AttrStr("name")
			}
		}
		cfgLinks, err := c.BlueprintRelationship(bp.ID, "configurations")
		if err != nil {
			return fmt.Errorf("fetching blueprint %q configurations: %w", bp.AttrStr("name"), err)
		}
		names := make([]string, 0, len(cfgLinks))
		for _, l := range cfgLinks {
			if n := cfgNameByID[l.ID]; n != "" {
				names = append(names, n)
			} else {
				names = append(names, l.ID)
			}
		}
		sort.Strings(names)
		carriers = append(carriers, bpCov{Blueprint: bp.AttrStr("name"), Configurations: names})
	}
	// Built-in-MDM posture — present only when the serial is enrolled in built-in
	// MDM. The endpoint can be denied outright (accounts without the built-in
	// device-management permission), so a list failure marks the section
	// UNAVAILABLE rather than aborting — but it must never render as the
	// affirmatively false "(not enrolled)".
	var mdmDev, mdmDetails *ab.Resource
	mdms, mdmErr := c.ListMDMDevices()
	if mdmErr == nil {
		for i := range mdms {
			if strings.EqualFold(mdms[i].AttrStr("serialNumber"), dev.AttrStr("serialNumber")) {
				mdmDev = &mdms[i]
				mdmDetails, _ = c.GetMDMDeviceDetails(mdms[i].ID)
				break
			}
		}
	}
	var coverage []ab.Resource
	if appleCare {
		if coverage, err = c.DeviceAppleCare(dev.ID); err != nil {
			return err
		}
	}
	var releaseInfo map[string]any
	if releases && mdmDetails == nil {
		releaseInfo = map[string]any{"error": "built-in-MDM posture is unavailable; no reported OS to compare"}
	} else if releases {
		cat, fetchErr := gdmf.New(os.Getenv("AB_GDMF_URL")).Fetch()
		if fetchErr != nil {
			releaseInfo = map[string]any{"error": fetchErr.Error()}
		} else {
			platform, product := mdmDetails.AttrStr("platform"), dev.AttrStr("productType")
			latest := map[string]gdmf.Entry{}
			for _, entry := range cat.Entries(time.Now()) {
				if entry.Expired || !strings.EqualFold(entry.Platform, platform) || (product != "" && !containsFold(entry.SupportedDevices, product)) {
					continue
				}
				old, ok := latest[entry.Catalog]
				if !ok || entry.PostingDate > old.PostingDate {
					latest[entry.Catalog] = entry
				}
			}
			releaseInfo = map[string]any{"reportedVersion": mdmDetails.AttrStr("osVersion"), "platform": platform,
				"productType":    product,
				"interpretation": "catalog comparison only; not eligibility, scheduling, or installation proof"}
			for kind, entry := range latest { // only catalogs with a real match — absent kinds stay out of JSON
				releaseInfo[kind] = entry
			}
		}
	}
	fmt.Fprintln(os.Stderr, "NOTE: desired-state / assignment intent + last-reported MDM posture — NOT live on-device verification (the Apple Business API cannot report per-device install status).")
	if asJSON || flagOutput != "table" {
		var mdm map[string]any
		if mdmErr != nil {
			mdm = map[string]any{"error": mdmErr.Error()}
		} else if mdmDev != nil {
			mdm = map[string]any{"device": mdmDev, "details": mdmDetails}
		}
		data := map[string]any{
			"device": dev, "assignedServer": server, "blueprints": asList(carriers), "mdm": mdm,
		}
		if appleCare {
			data["appleCare"] = asList(coverage)
		}
		if releases {
			data["releases"] = releaseInfo
		}
		return render(outFmt(asJSON), data, nil, nil)
	}
	serverName := "(none)"
	if server != nil {
		serverName = server.AttrStr("serverName")
	}
	printKV([][2]string{
		{"serial", dev.AttrStr("serialNumber")},
		{"model", dev.AttrStr("deviceModel")},
		{"status", dev.AttrStr("status")},
		{"mdm server", serverName},
	})
	if len(carriers) == 0 {
		fmt.Println("blueprints  (none)")
	} else {
		rows := make([][]string, 0, len(carriers))
		for _, cv := range carriers {
			rows = append(rows, []string{cv.Blueprint, strings.Join(cv.Configurations, ", ")})
		}
		printTable([]string{"BLUEPRINT", "CONFIGURATIONS"}, rows)
	}
	switch {
	case mdmErr != nil:
		fmt.Printf("built-in MDM  (unavailable: %v)\n", mdmErr)
	case mdmDev != nil && mdmDetails != nil:
		a := mdmDetails.Attr()
		fmt.Println("built-in MDM (last reported)")
		printKV([][2]string{
			{"  os", strings.TrimSpace(mdmDetails.AttrStr("platform") + " " + mdmDetails.AttrStr("osVersion"))},
			{"  last check-in", mdmDetails.AttrStr("lastCheckInDateTime")},
			{"  filevault", boolAttr(a, "isFileVaultEnabled")},
			{"  firewall", boolAttr(a, "isFirewallEnabled")},
			{"  storage", storageUsed(a)},
			{"  lock", mdmDetails.AttrStr("deviceLockStatus")},
			{"  erase", mdmDetails.AttrStr("deviceEraseStatus")},
			{"  lost mode", mdmDetails.AttrStr("lostModeStatus")},
		})
	case mdmDev != nil:
		fmt.Println("built-in MDM  enrolled (posture unavailable)")
	default:
		fmt.Println("built-in MDM  (not enrolled)")
	}
	if appleCare {
		printAppleCare(coverage)
	}
	if releases {
		fmt.Println("software releases (catalog comparison only; not eligibility/install proof)")
		if errText, _ := releaseInfo["error"].(string); errText != "" {
			fmt.Println("  unavailable  " + errText)
		} else {
			for _, kind := range []string{"managed", "public", "rsr"} {
				if entry, ok := releaseInfo[kind].(gdmf.Entry); ok && entry.Build != "" {
					fmt.Printf("  %-9s  %s (%s)\n", kind, entry.ProductVersion, entry.Build)
				}
			}
		}
	}
	return nil
}
