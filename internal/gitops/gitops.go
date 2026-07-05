// Package gitops is the on-disk desired-state tree: lib/ profiles, blueprint
// manifests, and the committed baseline. Config identity = the config `name`
// (which is the .mobileconfig filename, matching how the console names uploads).
package gitops

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Tree is the on-disk desired-state layout rooted at <envDir>/gitops.
type Tree struct {
	Root          string
	LibDir        string
	StateFile     string
	BlueprintsDir string
	ArchiveDir    string
}

// NewTree roots the gitops tree at <envDir>/gitops (next to .env/secrets).
func NewTree(envDir string) *Tree {
	root := filepath.Join(envDir, "gitops")
	return &Tree{
		Root:          root,
		LibDir:        filepath.Join(root, "lib", "macos", "configuration-profiles"),
		StateFile:     filepath.Join(root, "state", "sync-state.json"),
		BlueprintsDir: filepath.Join(root, "blueprints"),
		ArchiveDir:    filepath.Join(root, "archive"),
	}
}

// LoadDesired reads lib/*.mobileconfig → name → content.
func (t *Tree) LoadDesired() (map[string][]byte, error) {
	out := map[string][]byte{}
	entries, err := os.ReadDir(t.LibDir)
	if os.IsNotExist(err) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".mobileconfig") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(t.LibDir, e.Name()))
		if err != nil {
			return nil, err
		}
		out[e.Name()] = b
	}
	return out, nil
}

// WriteConfig writes a profile into lib/ under the given name.
func (t *Tree) WriteConfig(name string, content []byte) error {
	if err := os.MkdirAll(t.LibDir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(t.LibDir, name), content, 0o644)
}

// RemoveConfig deletes a profile from lib/ (used when a config was removed from
// ABM → the git file is pruned). A missing file is not an error (idempotent).
func (t *Tree) RemoveConfig(name string) error {
	err := os.Remove(filepath.Join(t.LibDir, name))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

// BlueprintSpec is the git desired-state for one blueprint: its identity and the
// set of configuration names attached to it. Device/user/group membership is NOT
// tracked here — identity is API-read-only (console/federation-managed), so a
// blueprint's members live in the console, not in git.
type BlueprintSpec struct {
	Name           string   `yaml:"name"`
	ID             string   `yaml:"id,omitempty"`
	Description    string   `yaml:"description,omitempty"`
	Configurations []string `yaml:"configurations"`
}

// LoadBlueprints reads blueprints/*.yml → blueprint name → spec. A malformed file
// is a hard error (so a typo can't silently drop a blueprint from the plan).
func (t *Tree) LoadBlueprints() (map[string]BlueprintSpec, error) {
	out := map[string]BlueprintSpec{}
	entries, err := os.ReadDir(t.BlueprintsDir)
	if os.IsNotExist(err) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		if ext := strings.ToLower(filepath.Ext(e.Name())); e.IsDir() || (ext != ".yml" && ext != ".yaml") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(t.BlueprintsDir, e.Name()))
		if err != nil {
			return nil, err
		}
		var s BlueprintSpec
		if err := yaml.Unmarshal(b, &s); err != nil {
			return nil, fmt.Errorf("parse blueprint %s: %w", e.Name(), err)
		}
		if s.Name == "" {
			return nil, fmt.Errorf("blueprint %s: missing required 'name'", e.Name())
		}
		if _, dup := out[s.Name]; dup {
			return nil, fmt.Errorf("duplicate blueprint name %q (in %s)", s.Name, e.Name())
		}
		out[s.Name] = s
	}
	return out, nil
}

// WriteBlueprintSpec marshals a spec to blueprints/<slug>.yml. The filename slug
// is derived from the name (falling back to the id when the name has no slug-safe
// characters), and collisions are disambiguated with a numeric suffix so two
// distinct blueprints whose names sanitize to the same slug never overwrite each
// other. Re-writing the same blueprint (matched by name) reuses its file.
func (t *Tree) WriteBlueprintSpec(s BlueprintSpec) error {
	if err := os.MkdirAll(t.BlueprintsDir, 0o755); err != nil {
		return err
	}
	b, err := yaml.Marshal(s)
	if err != nil {
		return err
	}
	slug := Sanitize(s.Name)
	if slug == "" { // a name with no [a-z0-9] chars (e.g. all non-ASCII) → fall back to the id
		if slug = "bp-" + Sanitize(s.ID); slug == "bp-" {
			slug = "blueprint"
		}
	}
	stem := slug
	for i := 1; ; i++ {
		path := filepath.Join(t.BlueprintsDir, stem+".yml")
		existing, err := os.ReadFile(path)
		if os.IsNotExist(err) {
			return os.WriteFile(path, b, 0o644)
		}
		if err != nil {
			return err
		}
		var cur BlueprintSpec // the file exists — reuse it only if it's this same blueprint
		if yaml.Unmarshal(existing, &cur) == nil && cur.Name == s.Name {
			return os.WriteFile(path, b, 0o644)
		}
		stem = fmt.Sprintf("%s-%d", slug, i)
	}
}

// Sanitize turns a blueprint name into a safe filename slug.
func Sanitize(s string) string {
	s = strings.ToLower(s)
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == ' ' || r == '-' || r == '_':
			b.WriteRune('-')
		}
	}
	return strings.Trim(b.String(), "-")
}
