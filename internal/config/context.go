package config

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"gopkg.in/yaml.v3"
)

// Context is one named Apple Business connection (client id + key + endpoints),
// stored in ~/.abctl/contexts.yaml so an operator can switch between organizations/tenants.
// The json tags mirror the yaml tags so `context get -o json|yaml` emits lowercase
// snake_case (client_id/key/api_base/…) consistent with every other payload — not the
// Go field names. Only the key PATH is ever surfaced, never key material.
type Context struct {
	ClientID string `yaml:"client_id" json:"client_id"`
	KeyPath  string `yaml:"key" json:"key"` // path to the EC private key (resolved relative to the file if not absolute)
	APIBase  string `yaml:"api_base,omitempty" json:"api_base,omitempty"`
	Scope    string `yaml:"scope,omitempty" json:"scope,omitempty"`
	TokenURL string `yaml:"token_url,omitempty" json:"token_url,omitempty"`
	TokenAud string `yaml:"token_aud,omitempty" json:"token_aud,omitempty"`
}

// Contexts is the on-disk store: a set of named contexts + the active one.
type Contexts struct {
	Current  string             `yaml:"current,omitempty" json:"current,omitempty"`
	Contexts map[string]Context `yaml:"contexts" json:"contexts"`
}

// ContextsPath is ~/.abctl/contexts.yaml, overridable via $ABCTL_CONTEXTS (tests/CI).
func ContextsPath() string {
	if p := os.Getenv("ABCTL_CONTEXTS"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".abctl", "contexts.yaml")
	}
	return filepath.Join(home, ".abctl", "contexts.yaml")
}

// LoadContexts reads the context store; a missing file yields an empty store.
func LoadContexts() (*Contexts, error) {
	s := &Contexts{Contexts: map[string]Context{}}
	b, err := os.ReadFile(ContextsPath())
	if os.IsNotExist(err) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := yaml.Unmarshal(b, s); err != nil {
		return nil, fmt.Errorf("parse %s: %w", ContextsPath(), err)
	}
	if s.Contexts == nil {
		s.Contexts = map[string]Context{}
	}
	return s, nil
}

// Save writes the context store (0600, creating ~/.abctl).
func (s *Contexts) Save() error {
	p := ContextsPath()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	b, err := yaml.Marshal(s)
	if err != nil {
		return err
	}
	return os.WriteFile(p, b, 0o600)
}

// Names returns the context names, sorted.
func (s *Contexts) Names() []string {
	out := make([]string, 0, len(s.Contexts))
	for n := range s.Contexts {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// loadFromContext resolves a Config from a named context. used=true when a context
// was selected (explicitly, via $ABCTL_CONTEXT, or the store's active one), so the
// caller does NOT fall back to .env. A selected-but-missing context is an error.
func loadFromContext(explicit string) (cfg *Config, used bool, err error) {
	name := explicit
	if name == "" {
		name = os.Getenv("ABCTL_CONTEXT")
	}
	store, err := LoadContexts()
	if err != nil {
		return nil, false, err
	}
	explicitlyAsked := name != ""
	if name == "" {
		name = store.Current
	}
	if name == "" {
		return nil, false, nil // no context in play → caller uses .env / env
	}
	ctx, ok := store.Contexts[name]
	if !ok {
		if explicitlyAsked {
			return nil, true, fmt.Errorf("context %q not found in %s", name, ContextsPath())
		}
		// A stale `current` shouldn't wedge the CLI — fall through to .env.
		return nil, false, nil
	}
	c, err := ctx.toConfig(name)
	return c, true, err
}

func (c Context) toConfig(name string) (*Config, error) {
	if c.ClientID == "" {
		return nil, fmt.Errorf("context %q: client_id not set", name)
	}
	if c.KeyPath == "" {
		return nil, fmt.Errorf("context %q: key not set", name)
	}
	kp := c.KeyPath
	if !filepath.IsAbs(kp) {
		// Relative key paths resolve against the contexts file's directory.
		kp = filepath.Join(filepath.Dir(ContextsPath()), kp)
	}
	// The gitops tree resolves against the current working directory in context mode
	// (like git) — a context is a connection, not a repo location.
	dir, _ := os.Getwd()
	return &Config{
		ClientID: c.ClientID,
		KeyPath:  kp,
		Scope:    orDefault(c.Scope, DefaultScope),
		TokenURL: orDefault(c.TokenURL, DefaultTokenURL),
		TokenAud: orDefault(c.TokenAud, DefaultTokenAud),
		APIBase:  orDefault(c.APIBase, DefaultAPIBase),
		EnvDir:   dir,
	}, nil
}
