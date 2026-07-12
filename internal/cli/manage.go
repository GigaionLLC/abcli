package cli

import (
	"fmt"
	"os"
	"os/signal"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/gitops"
)

// --- imperative blueprint / MDM-server lifecycle + device assignment (Phase A) ---
//
// Every write here follows the standard gate (confirm unless --yes/$ABCTL_APPROVE).
// MDM-server lifecycle is tenant-only. Blueprint existence is git-authoritative on
// the CREATE side (`sync --apply` creates a manifest-only blueprint) but deletion
// stays imperative-only — so `delete blueprint` on a manifest-backed blueprint
// warns that the next sync would recreate it. There is no tree write in this file.

// --- create/edit/delete blueprint ---

func newCreateBlueprintCmd() *cobra.Command {
	var description string
	var configs, apps, packages, devices, users, groups []string
	var yes, jsonOut bool
	cmd := &cobra.Command{
		Use:   "blueprint <name>",
		Short: "Create a blueprint (POST) with its initial members inlined",
		Long: "Create a blueprint. Apple requires a create to carry at least one device/user/group\n" +
			"member plus content (a member-less POST returns 409 MISSING_MEMBERS — live-verified\n" +
			"2026-07-05), so pass the initial membership here; grow it later with `abctl attach`.",
		Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error {
			members := map[string][]string{"config": configs, "app": apps, "package": packages,
				"device": devices, "user": users, "group": groups}
			return runCreateBlueprint(a[0], description, members, yes, jsonOut)
		},
	}
	cmd.Flags().StringVar(&description, "description", "", "blueprint description")
	cmd.Flags().StringArrayVar(&configs, "config", nil, "configuration to include (name|id, repeatable)")
	cmd.Flags().StringArrayVar(&apps, "app", nil, "app to include (name|id, repeatable)")
	cmd.Flags().StringArrayVar(&packages, "package", nil, "package to include (name|id, repeatable)")
	cmd.Flags().StringArrayVar(&devices, "device", nil, "device member (serial|id, repeatable)")
	cmd.Flags().StringArrayVar(&users, "user", nil, "user member (email|id, repeatable)")
	cmd.Flags().StringArrayVar(&groups, "group", nil, "user-group member (name|id, repeatable)")
	cmd.Flags().BoolVar(&yes, "yes", false, "skip confirmation (also honored: $ABCTL_APPROVE=1)")
	cmd.Flags().BoolVar(&jsonOut, "json", false, "JSON output (machine-readable write outcome)")
	return cmd
}

func runCreateBlueprint(name, description string, memberArgs map[string][]string, yes, jsonOut bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	// Resolve every member to an ABM id up front — a typo aborts before the gate,
	// not after the create. rel names match the API relationship collections.
	members := map[string][]string{}
	total := 0
	for nounKey, values := range memberArgs {
		for _, v := range values {
			var rel, id string
			if nounKey == "config" {
				r, err := c.ResolveConfig(v)
				if err != nil {
					return err
				}
				rel, id = "configurations", r.ID
			} else {
				k, ok := memberKindFor(nounKey)
				if !ok {
					return fmt.Errorf("unknown member kind %q", nounKey)
				}
				r, err := k.resolve(c, v)
				if err != nil {
					return err
				}
				rel, id = k.rel, r.ID
			}
			members[rel] = append(members[rel], id)
			total++
		}
	}
	if !approved(yes) {
		ok, err := confirmWrite(fmt.Sprintf("create blueprint %s (%d member(s) inlined)", name, total))
		if err != nil || !ok {
			fmt.Fprintln(os.Stderr, "aborted.")
			return ExitError{Code: 1}
		}
	}
	bp, err := c.CreateBlueprint(name, description, members)
	if err != nil {
		return err
	}
	if wantsMachine(jsonOut) {
		return emitWrite(writeOutcome{Action: "create", Name: name, ID: bp.ID}, jsonOut)
	}
	fmt.Fprintf(os.Stderr, "created blueprint %q (id %s)\n", name, bp.ID)
	return nil
}

func newEditBlueprintCmd() *cobra.Command {
	var rename, description string
	var yes, jsonOut bool
	cmd := &cobra.Command{
		Use:   "blueprint <name|id> [--rename N] [--description D]",
		Short: "Rename a blueprint and/or set its description (PATCH)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, a []string) error {
			// Changed (not non-empty) so `--description ""` can clear the description.
			var newName, newDesc *string
			if cmd.Flags().Changed("rename") {
				newName = &rename
			}
			if cmd.Flags().Changed("description") {
				newDesc = &description
			}
			return runEditBlueprint(a[0], newName, newDesc, yes, jsonOut)
		},
	}
	cmd.Flags().StringVar(&rename, "rename", "", "new blueprint name")
	cmd.Flags().StringVar(&description, "description", "", "new blueprint description")
	cmd.Flags().BoolVar(&yes, "yes", false, "skip confirmation (also honored: $ABCTL_APPROVE=1)")
	cmd.Flags().BoolVar(&jsonOut, "json", false, "JSON output (machine-readable write outcome)")
	return cmd
}

func runEditBlueprint(nameOrID string, newName, newDesc *string, yes, jsonOut bool) error {
	if newName == nil && newDesc == nil {
		return fmt.Errorf("nothing to change — pass --rename and/or --description")
	}
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	bp, err := c.ResolveBlueprint(nameOrID)
	if err != nil {
		return err
	}
	name := bp.AttrStr("name")
	if !approved(yes) {
		ok, err := confirmWrite("edit blueprint " + name)
		if err != nil || !ok {
			fmt.Fprintln(os.Stderr, "aborted.")
			return ExitError{Code: 1}
		}
	}
	if err := c.UpdateBlueprint(bp.ID, newName, newDesc); err != nil {
		return err
	}
	if newName != nil {
		name = *newName
	}
	if wantsMachine(jsonOut) {
		return emitWrite(writeOutcome{Action: "edit", Name: name, ID: bp.ID}, jsonOut)
	}
	fmt.Fprintf(os.Stderr, "updated blueprint %q\n", name)
	return nil
}

func newDeleteBlueprintCmd() *cobra.Command {
	var yes, jsonOut bool
	cmd := &cobra.Command{
		Use:   "blueprint <name|id>",
		Short: "Delete a blueprint (prints its member counts before the confirm)",
		Args:  cobra.ExactArgs(1),
		RunE:  func(_ *cobra.Command, a []string) error { return runDeleteBlueprint(a[0], yes, jsonOut) },
	}
	cmd.Flags().BoolVar(&yes, "yes", false, "skip confirmation (also honored: $ABCTL_APPROVE=1)")
	cmd.Flags().BoolVar(&jsonOut, "json", false, "JSON output (machine-readable write outcome)")
	return cmd
}

func runDeleteBlueprint(nameOrID string, yes, jsonOut bool) error {
	c, cfg, err := mustClient()
	if err != nil {
		return err
	}
	bp, err := c.ResolveBlueprint(nameOrID)
	if err != nil {
		return err
	}
	name := bp.AttrStr("name")
	// Blast radius before the gate: the six member collections this delete unhooks.
	counts := make([]string, 0, len(blueprintRels))
	for _, rel := range blueprintRels {
		links, err := c.BlueprintRelationship(bp.ID, rel)
		if err != nil {
			return err
		}
		counts = append(counts, fmt.Sprintf("%s %d", rel, len(links)))
	}
	fmt.Fprintf(os.Stderr, "blueprint %q members: %s\n", name, strings.Join(counts, ", "))
	// A manifest-backed blueprint would be recreated by the next `sync --apply`
	// (a git-only blueprint plans a real CREATE) — say so before the confirm.
	// Best-effort: an unreadable tree just skips the note.
	if all, lerr := gitops.NewTree(cfg.EnvDir).LoadBlueprints(); lerr == nil {
		if _, tracked := all[name]; tracked {
			fmt.Fprintf(os.Stderr, "note: %q has a manifest in gitops/blueprints/ — also remove that file, or the next `sync --apply` will recreate the blueprint.\n", name)
		}
	}
	if !approved(yes) {
		ok, err := confirmWrite("DELETE blueprint " + name)
		if err != nil || !ok {
			fmt.Fprintln(os.Stderr, "aborted.")
			return ExitError{Code: 1}
		}
	}
	if err := c.DeleteBlueprint(bp.ID); err != nil {
		return err
	}
	if wantsMachine(jsonOut) {
		return emitWrite(writeOutcome{Action: "delete", Name: name, ID: bp.ID}, jsonOut)
	}
	fmt.Fprintf(os.Stderr, "deleted blueprint %q\n", name)
	return nil
}

// --- create/edit/delete mdmserver ---

func newCreateMDMServerCmd() *cobra.Command {
	var name, certPath, certName string
	var disown, yes, jsonOut bool
	cmd := &cobra.Command{
		Use:   "mdmserver --name <name> --cert <pem-path>",
		Short: "Create an MDM server from its push-certificate PEM (POST)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			var d *bool
			if cmd.Flags().Changed("disown") {
				d = &disown
			}
			return runCreateMDMServer(name, certPath, certName, d, yes, jsonOut)
		},
	}
	cmd.Flags().StringVar(&name, "name", "", "server name")
	cmd.Flags().StringVar(&certPath, "cert", "", "path to the server certificate PEM ('-' for stdin)")
	cmd.Flags().StringVar(&certName, "cert-name", "", "certificate display name (default: the server name)")
	cmd.Flags().BoolVar(&disown, "disown", false, "enableMdmDisownFlag (omitted unless set, letting Apple default)")
	cmd.Flags().BoolVar(&yes, "yes", false, "skip confirmation (also honored: $ABCTL_APPROVE=1)")
	cmd.Flags().BoolVar(&jsonOut, "json", false, "JSON output (machine-readable write outcome)")
	_ = cmd.MarkFlagRequired("name")
	_ = cmd.MarkFlagRequired("cert")
	return cmd
}

func runCreateMDMServer(name, certPath, certName string, disown *bool, yes, jsonOut bool) error {
	pem, err := readFileArg(certPath) // key material — sent to Apple verbatim, never logged
	if err != nil {
		return err
	}
	if certName == "" {
		certName = name
	}
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	if !approved(yes) {
		ok, err := confirmWrite("create MDM server " + name)
		if err != nil || !ok {
			fmt.Fprintln(os.Stderr, "aborted.")
			return ExitError{Code: 1}
		}
	}
	srv, err := c.CreateMDMServer(name, certName, pem, disown)
	if err != nil {
		return err
	}
	if wantsMachine(jsonOut) {
		return emitWrite(writeOutcome{Action: "create", Name: name, ID: srv.ID}, jsonOut)
	}
	fmt.Fprintf(os.Stderr, "created MDM server %q (id %s)\n", name, srv.ID)
	return nil
}

func newEditMDMServerCmd() *cobra.Command {
	var rename string
	var disown, yes, jsonOut bool
	cmd := &cobra.Command{
		Use:   "mdmserver <name|id> [--rename N] [--disown=true|false]",
		Short: "Rename an MDM server and/or set its disown flag (PATCH)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, a []string) error {
			var newName *string
			var newDisown *bool
			if cmd.Flags().Changed("rename") {
				newName = &rename
			}
			if cmd.Flags().Changed("disown") {
				newDisown = &disown
			}
			return runEditMDMServer(a[0], newName, newDisown, yes, jsonOut)
		},
	}
	cmd.Flags().StringVar(&rename, "rename", "", "new server name")
	cmd.Flags().BoolVar(&disown, "disown", false, "enableMdmDisownFlag")
	cmd.Flags().BoolVar(&yes, "yes", false, "skip confirmation (also honored: $ABCTL_APPROVE=1)")
	cmd.Flags().BoolVar(&jsonOut, "json", false, "JSON output (machine-readable write outcome)")
	return cmd
}

func runEditMDMServer(nameOrID string, newName *string, newDisown *bool, yes, jsonOut bool) error {
	if newName == nil && newDisown == nil {
		return fmt.Errorf("nothing to change — pass --rename and/or --disown")
	}
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	srv, err := c.ResolveMDMServer(nameOrID)
	if err != nil {
		return err
	}
	name := srv.AttrStr("serverName")
	if !approved(yes) {
		ok, err := confirmWrite("edit MDM server " + name)
		if err != nil || !ok {
			fmt.Fprintln(os.Stderr, "aborted.")
			return ExitError{Code: 1}
		}
	}
	if err := c.UpdateMDMServer(srv.ID, newName, newDisown); err != nil {
		return err
	}
	if newName != nil {
		name = *newName
	}
	if wantsMachine(jsonOut) {
		return emitWrite(writeOutcome{Action: "edit", Name: name, ID: srv.ID}, jsonOut)
	}
	fmt.Fprintf(os.Stderr, "updated MDM server %q\n", name)
	return nil
}

func newDeleteMDMServerCmd() *cobra.Command {
	var yes, jsonOut bool
	cmd := &cobra.Command{
		Use:   "mdmserver <name|id>",
		Short: "Delete an MDM server (Apple refuses while devices are still assigned)",
		Args:  cobra.ExactArgs(1),
		RunE:  func(_ *cobra.Command, a []string) error { return runDeleteMDMServer(a[0], yes, jsonOut) },
	}
	cmd.Flags().BoolVar(&yes, "yes", false, "skip confirmation (also honored: $ABCTL_APPROVE=1)")
	cmd.Flags().BoolVar(&jsonOut, "json", false, "JSON output (machine-readable write outcome)")
	return cmd
}

func runDeleteMDMServer(nameOrID string, yes, jsonOut bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	srv, err := c.ResolveMDMServer(nameOrID)
	if err != nil {
		return err
	}
	name := srv.AttrStr("serverName")
	fmt.Fprintln(os.Stderr, "note: Apple refuses to delete an MDM server while devices are assigned to it (the 409 is surfaced verbatim) — `abctl unassign` them first.")
	if !approved(yes) {
		ok, err := confirmWrite("DELETE MDM server " + name)
		if err != nil || !ok {
			fmt.Fprintln(os.Stderr, "aborted.")
			return ExitError{Code: 1}
		}
	}
	if err := c.DeleteMDMServer(srv.ID); err != nil {
		return err
	}
	if wantsMachine(jsonOut) {
		return emitWrite(writeOutcome{Action: "delete", Name: name, ID: srv.ID}, jsonOut)
	}
	fmt.Fprintf(os.Stderr, "deleted MDM server %q\n", name)
	return nil
}

// --- assign / unassign devices to/from an MDM server (async orgDeviceActivities) ---

// activityWaitTimeout/activityPollEvery bound the --wait loop: Apple processes
// assignment activities asynchronously, usually within seconds.
const (
	activityPollEvery   = 5 * time.Second
	activityWaitTimeout = 10 * time.Minute
)

// activityOutcome is the machine-readable result of assign/unassign (the async
// sibling of writeOutcome): the activity id is what a GUI/script polls.
type activityOutcome struct {
	Action     string `json:"action"` // assign|unassign
	Server     string `json:"server"`
	Devices    int    `json:"devices"`
	ActivityID string `json:"activityId"`
	Status     string `json:"status,omitempty"`    // final status, only with --wait
	SubStatus  string `json:"subStatus,omitempty"` // only with --wait
}

func newAssignCmd() *cobra.Command   { return assignmentCmd("assign") }
func newUnassignCmd() *cobra.Command { return assignmentCmd("unassign") }

func assignmentCmd(verb string) *cobra.Command {
	var server string
	var yes, wait, jsonOut bool
	prep := map[string]string{"assign": "to", "unassign": "from"}[verb]
	c := &cobra.Command{
		Use:   verb + " --server <name|id> <serial...>",
		Short: verb + " org devices " + prep + " an MDM server (async — prints the activity id)",
		Args:  cobra.MinimumNArgs(1),
		RunE: func(_ *cobra.Command, a []string) error {
			return runAssignment(verb, server, a, yes, wait, jsonOut)
		},
	}
	c.Flags().StringVar(&server, "server", "", "target MDM server (name or id)")
	c.Flags().BoolVar(&yes, "yes", false, "skip confirmation (also: $ABCTL_APPROVE=1)")
	c.Flags().BoolVar(&wait, "wait", false, "poll the activity every 5s (up to 10m) until it completes")
	c.Flags().BoolVar(&jsonOut, "json", false, "JSON output (machine-readable activity outcome)")
	_ = c.MarkFlagRequired("server")
	return c
}

func runAssignment(verb, serverArg string, serials []string, yes, wait, jsonOut bool) error {
	prep := map[string]string{"assign": "to", "unassign": "from"}[verb]
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	srv, err := c.ResolveMDMServer(serverArg)
	if err != nil {
		return err
	}
	ids, err := resolveDeviceIDs(c, serials)
	if err != nil {
		return err
	}
	srvName := srv.AttrStr("serverName")
	if !approved(yes) {
		ok, err := confirmWrite(fmt.Sprintf("%s %d device(s) %s MDM server %s", verb, len(ids), prep, srvName))
		if err != nil || !ok {
			fmt.Fprintln(os.Stderr, "aborted.")
			return ExitError{Code: 1}
		}
	}
	var actID string
	if verb == "assign" {
		actID, err = c.AssignDevices(srv.ID, ids)
	} else {
		actID, err = c.UnassignDevices(srv.ID, ids)
	}
	if err != nil {
		return err
	}
	out := activityOutcome{Action: verb, Server: srvName, Devices: len(ids), ActivityID: actID}
	if wait {
		fmt.Fprintf(os.Stderr, "activity %s accepted — polling every %s (Ctrl-C stops waiting, not the activity)\n", actID, activityPollEvery)
		act, err := waitActivity(c, actID)
		if err != nil {
			return err
		}
		out.Status, out.SubStatus = act.AttrStr("status"), act.AttrStr("subStatus")
	}
	if wantsMachine(jsonOut) {
		return render(outFmt(jsonOut), out, nil, nil)
	}
	if wait {
		sub := ""
		if out.SubStatus != "" {
			sub = " (" + out.SubStatus + ")"
		}
		fmt.Fprintf(os.Stderr, "%s activity %s finished: %s%s — %d device(s) %s %q\n", verb, actID, out.Status, sub, len(ids), prep, srvName)
		return nil
	}
	fmt.Fprintf(os.Stderr, "%s activity %s accepted for %d device(s) %s %q — poll with `abctl status activity %s`\n",
		verb, actID, len(ids), prep, srvName, actID)
	return nil
}

// resolveDeviceIDs resolves serials/ids to orgDevice ids via ONE ListDevices call
// (not N per-serial lookups — the API rate-limits hard).
func resolveDeviceIDs(c *ab.Client, args []string) ([]string, error) {
	devs, err := c.ListDevices()
	if err != nil {
		return nil, err
	}
	return deviceIDsFromList(devs, args)
}

// deviceIDsFromList matches each arg against the device list with ab.ResolveDevice's
// semantics: exact id wins, else case-insensitive serial; a serial shared by >1
// device is an error (use the device id).
func deviceIDsFromList(devs []ab.Resource, args []string) ([]string, error) {
	ids := make([]string, 0, len(args))
	for _, arg := range args {
		var bySerial []string
		id := ""
		for i := range devs {
			if devs[i].ID == arg {
				id = arg
				break
			}
			if strings.EqualFold(devs[i].AttrStr("serialNumber"), arg) {
				bySerial = append(bySerial, devs[i].ID)
			}
		}
		switch {
		case id != "":
		case len(bySerial) == 1:
			id = bySerial[0]
		case len(bySerial) == 0:
			return nil, fmt.Errorf("device %q not found (by serial number or id)", arg)
		default:
			return nil, fmt.Errorf("device serial %q is ambiguous (%d devices share it) — use the device id", arg, len(bySerial))
		}
		ids = append(ids, id)
	}
	return ids, nil
}

// waitActivity polls an orgDeviceActivity until its status leaves IN_PROGRESS,
// the timeout lapses, or the user interrupts (Ctrl-C stops the wait, never the
// activity — it keeps running on Apple's side either way).
func waitActivity(c *ab.Client, id string) (*ab.Resource, error) {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	defer signal.Stop(sig)
	deadline := time.Now().Add(activityWaitTimeout)
	for {
		act, err := c.GetOrgDeviceActivity(id)
		if err != nil {
			return nil, err
		}
		if st := act.AttrStr("status"); st != "" && st != "IN_PROGRESS" {
			return act, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("activity %s still IN_PROGRESS after %s — keep polling with `abctl status activity %s`", id, activityWaitTimeout, id)
		}
		select {
		case <-time.After(activityPollEvery):
		case <-sig:
			return nil, fmt.Errorf("interrupted — activity %s continues on Apple's side; poll with `abctl status activity %s`", id, id)
		}
	}
}

// --- status activity ---

func newStatusActivityCmd() *cobra.Command {
	var asJSON bool
	var download string
	c := &cobra.Command{
		Use:   "activity <id>",
		Short: "Status of a device assign/unassign activity (orgDeviceActivities)",
		Args:  cobra.ExactArgs(1),
		RunE:  func(_ *cobra.Command, a []string) error { return runStatusActivity(a[0], asJSON, download) },
	}
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	c.Flags().StringVar(&download, "download", "", "download the completed result CSV to this new file")
	return c
}

func runStatusActivity(id string, asJSON bool, download string) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	act, err := c.GetOrgDeviceActivity(id)
	if err != nil {
		return err
	}
	if download != "" {
		u := act.AttrStr("downloadUrl")
		if u == "" {
			return fmt.Errorf("activity %s has no result log yet (status %s)", id, act.AttrStr("status"))
		}
		if err := downloadActivityLog(u, download); err != nil {
			return err
		}
	}
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), act, nil, nil)
	}
	printKV([][2]string{
		{"id", act.ID},
		{"status", act.AttrStr("status")},
		{"substatus", act.AttrStr("subStatus")},
		{"created", act.AttrStr("createdDateTime")},
		{"completed", act.AttrStr("completedDateTime")},
		{"result log", act.AttrStr("downloadUrl")},
	})
	return nil
}
