package cli

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"

	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"

	"github.com/GigaionLLC/abcli/internal/hash"
	"github.com/GigaionLLC/abcli/internal/state"
)

// applyYes is the shared --yes for `apply -f` / `delete -f`.
var applyYes bool

// Spec is a versioned abctl resource document (`get --yaml` output is valid input).
//
//	apiVersion: abctl/v1
//	kind: Configuration|Blueprint
//	metadata: { name: <name> }
//	spec: { profile|profileFile|platforms | configurations: [...] }
type Spec struct {
	APIVersion string `yaml:"apiVersion"`
	Kind       string `yaml:"kind"`
	Metadata   struct {
		Name string `yaml:"name"`
	} `yaml:"metadata"`
	Spec struct {
		Platforms      []string `yaml:"platforms,omitempty"`
		Profile        string   `yaml:"profile,omitempty"`
		ProfileFile    string   `yaml:"profileFile,omitempty"`
		Configurations []string `yaml:"configurations,omitempty"`
	} `yaml:"spec"`

	srcDir string // dir of the source file (to resolve profileFile)
}

type applyOpts struct {
	delete bool
	dryRun bool
	yes    bool
	force  bool
}

func newApplyCmd() *cobra.Command {
	var files []string
	var dryRun, force bool
	c := &cobra.Command{
		Use:   "apply -f <file.yml> [-f …]",
		Short: "Apply abctl/v1 resource specs (upsert; incremental, never deletes)",
		Long: "apply upserts each Configuration/Blueprint doc in the given spec file(s): creates or\n" +
			"replaces configs, attaches listed configs to blueprints. It NEVER deletes resources\n" +
			"absent from the file (that is `sync --prune` or `delete -f`). Multi-doc `---` files and\n" +
			"repeated -f are the bulk path.",
		Args: cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			if len(files) == 0 {
				return fmt.Errorf("need at least one -f <file.yml>")
			}
			return runApplyFiles(files, applyOpts{dryRun: dryRun, yes: applyYes, force: force})
		},
	}
	c.Flags().StringArrayVarP(&files, "file", "f", nil, "spec file (repeatable; '-' for stdin)")
	c.Flags().BoolVar(&dryRun, "dry-run", false, "parse + validate only, no writes")
	c.Flags().BoolVar(&applyYes, "yes", false, "skip confirmation (also: $ABCTL_APPROVE=1)")
	c.Flags().BoolVar(&force, "force", false, "skip client-side profile validation")
	return c
}

func runApplyFiles(files []string, opts applyOpts) error {
	specs, err := parseSpecFiles(files)
	if err != nil {
		return err
	}
	if len(specs) == 0 {
		fmt.Fprintln(os.Stderr, "no resources found in the spec file(s).")
		return nil
	}
	verb := "apply"
	if opts.delete {
		verb = "delete"
	}
	for _, s := range specs {
		fmt.Fprintf(os.Stderr, "  %s %s/%s\n", verb, s.Kind, s.Metadata.Name)
	}
	if opts.dryRun {
		for _, s := range specs { // honor "validate" — resolve profileFile + structural check
			if s.Kind != "Configuration" || opts.delete {
				continue
			}
			content, err := s.profileBytes()
			if err != nil {
				return err
			}
			if !opts.force {
				if err := validateProfile(content); err != nil {
					return fmt.Errorf("%s/%s: %w", s.Kind, s.Metadata.Name, err)
				}
			}
		}
		fmt.Fprintf(os.Stderr, "dry-run: %d resource(s) validated, no writes.\n", len(specs))
		return nil
	}
	if !opts.yes && !envApproved() {
		ok, err := confirmWrite(fmt.Sprintf("%s %d resource(s)", verb, len(specs)))
		if err != nil || !ok {
			fmt.Fprintln(os.Stderr, "aborted.")
			return ExitError{Code: 1}
		}
	}
	i, err := newImp()
	if err != nil {
		return err
	}
	var errs int
	for _, s := range specs {
		if err := applyOneSpec(i, s, opts); err != nil {
			fmt.Fprintf(os.Stderr, "  ✗ %s/%s: %v\n", s.Kind, s.Metadata.Name, err)
			errs++
			continue
		}
	}
	if errs > 0 {
		return ExitError{Code: 1}
	}
	return nil
}

func applyOneSpec(i *imp, s Spec, opts applyOpts) error {
	switch s.Kind {
	case "Configuration":
		if opts.delete {
			return runDeleteConfig(s.Metadata.Name, writeFlags{yes: true})
		}
		content, err := s.profileBytes()
		if err != nil {
			return err
		}
		if !opts.force {
			if err := validateProfile(content); err != nil {
				return err
			}
		}
		return upsertConfig(i, configName(s.Metadata.Name), content, s.Spec.Platforms)
	case "Blueprint":
		if opts.delete {
			return fmt.Errorf("blueprint delete is console-only (identity members are API-read-only)")
		}
		return applyBlueprintSpec(i, s)
	default:
		return fmt.Errorf("unknown kind %q (want Configuration|Blueprint)", s.Kind)
	}
}

// upsertConfig creates the config if absent in ABM, else archives + replaces it.
func upsertConfig(i *imp, name string, content []byte, platforms []string) error {
	live, err := i.c.FetchCustomSettings()
	if err != nil {
		return err
	}
	var existing *struct {
		id, xml, updated string
	}
	for _, l := range live {
		if l.Name == name {
			existing = &struct{ id, xml, updated string }{l.ID, l.XML, l.Updated}
			break
		}
	}
	if existing == nil {
		id, updated, err := i.c.CreateConfiguration(name, string(content), platforms)
		if err != nil {
			return err
		}
		return i.recordConfig(name, id, content, updated)
	}
	if _, err := i.archiver().Archive(name, "replaced", []byte(existing.xml), map[string]string{
		"abm_id": existing.id, "hash": hash.Raw([]byte(existing.xml)), "updatedDateTime": existing.updated,
	}); err != nil {
		return fmt.Errorf("archive failed (PATCH skipped): %w", err)
	}
	updated, err := i.c.UpdateConfiguration(existing.id, name, string(content))
	if err != nil {
		return err
	}
	return i.recordConfig(name, existing.id, content, updated)
}

func (i *imp) recordConfig(name, id string, content []byte, updated string) error {
	if err := i.tree.WriteConfig(name, content); err != nil {
		return err
	}
	i.base.Configs[name] = state.Entry{ABMID: id, Hash: hash.Raw(content), UpdatedDateTime: updated}
	return i.base.Save(i.tree.StateFile)
}

// applyBlueprintSpec attaches every config listed in the spec that isn't already
// attached (upsert-only — apply never detaches; use sync --prune for that).
func applyBlueprintSpec(i *imp, s Spec) error {
	bp, err := i.c.ResolveBlueprint(s.Metadata.Name)
	if err != nil {
		return err
	}
	live, err := i.c.FetchCustomSettings()
	if err != nil {
		return err
	}
	idByName := map[string]string{}
	for _, l := range live {
		idByName[l.Name] = l.ID
	}
	attached, _ := i.c.BlueprintRelationship(bp.ID, "configurations")
	have := map[string]bool{}
	for _, r := range attached {
		have[r.ID] = true
	}
	var attachedN int
	for _, cfg := range s.Spec.Configurations {
		id := idByName[configName(cfg)]
		if id == "" {
			id = idByName[cfg]
		}
		if id == "" {
			return fmt.Errorf("config %q not found in ABM (create it first)", cfg)
		}
		if have[id] {
			continue
		}
		if err := i.c.AddBlueprintMembers(bp.ID, "configurations", "configurations", []string{id}); err != nil {
			return err
		}
		attachedN++
	}
	// Mirror the ABM membership into the git manifest (full live set) so the tree
	// stays == live and a later `sync --prune` never reverts this attach.
	if err := i.syncBlueprintManifest(bp.AttrStr("name"), bp.ID, live); err != nil {
		fmt.Fprintf(os.Stderr, "  warning: attached on ABM but local manifest update failed: %v\n", err)
	}
	fmt.Fprintf(os.Stderr, "  ✓ Blueprint/%s: %d config(s) attached\n", s.Metadata.Name, attachedN)
	return nil
}

func (s Spec) profileBytes() ([]byte, error) {
	if s.Spec.Profile != "" {
		return []byte(s.Spec.Profile), nil
	}
	if s.Spec.ProfileFile != "" {
		p := s.Spec.ProfileFile
		if !filepath.IsAbs(p) {
			p = filepath.Join(s.srcDir, p)
		}
		return os.ReadFile(p)
	}
	return nil, fmt.Errorf("config %q: spec needs `profile` (inline XML) or `profileFile`", s.Metadata.Name)
}

func parseSpecFiles(files []string) ([]Spec, error) {
	var out []Spec
	for _, f := range files {
		var raw []byte
		var dir string
		var err error
		if f == "-" {
			raw, err = io.ReadAll(os.Stdin)
		} else {
			raw, err = os.ReadFile(f)
			dir = filepath.Dir(f)
		}
		if err != nil {
			return nil, err
		}
		dec := yaml.NewDecoder(bytes.NewReader(raw))
		for {
			var s Spec
			if err := dec.Decode(&s); err != nil {
				if err == io.EOF {
					break
				}
				return nil, fmt.Errorf("parse %s: %w", f, err)
			}
			if s.Kind == "" && s.Metadata.Name == "" {
				continue // empty document
			}
			if s.APIVersion != "abctl/v1" {
				return nil, fmt.Errorf("%s: apiVersion must be 'abctl/v1' (got %q)", f, s.APIVersion)
			}
			if s.Metadata.Name == "" {
				return nil, fmt.Errorf("%s: a %s doc is missing metadata.name", f, s.Kind)
			}
			s.srcDir = dir
			out = append(out, s)
		}
	}
	sort.SliceStable(out, func(a, b int) bool { return out[a].Kind > out[b].Kind }) // Configurations before Blueprints
	return out, nil
}
