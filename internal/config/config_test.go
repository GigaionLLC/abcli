package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoad(t *testing.T) {
	dir := t.TempDir()
	env := filepath.Join(dir, ".env")
	body := "AB_CLIENT_ID=BUSINESSAPI.abc   # inline comment\n" +
		"# a full-line comment\n" +
		"AB_PRIVATE_KEY=secrets/k.pem\n" +
		"AB_SCOPE=\"business.api\"\n"
	if err := os.WriteFile(env, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ABCTL_ENV", env)

	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.ClientID != "BUSINESSAPI.abc" {
		t.Errorf("ClientID = %q (inline comment not stripped?)", c.ClientID)
	}
	if c.KeyPath != filepath.Join(dir, "secrets/k.pem") {
		t.Errorf("KeyPath = %q, want resolved relative to .env dir", c.KeyPath)
	}
	if c.Scope != "business.api" {
		t.Errorf("Scope = %q (quotes not stripped?)", c.Scope)
	}
	if c.APIBase != "https://api-business.apple.com/v1/" {
		t.Errorf("APIBase default = %q", c.APIBase)
	}
}

func TestLoadMissingClientID(t *testing.T) {
	dir := t.TempDir()
	env := filepath.Join(dir, ".env")
	_ = os.WriteFile(env, []byte("AB_PRIVATE_KEY=k.pem\n"), 0o600)
	t.Setenv("ABCTL_ENV", env)
	if _, err := Load(); err == nil {
		t.Error("expected an error when AB_CLIENT_ID is missing")
	}
}

// TestLoadFromEnvVars: with no .env in scope, Load falls back to the process
// environment (the CI/CD path).
func TestLoadFromEnvVars(t *testing.T) {
	t.Setenv("ABCTL_CONTEXTS", filepath.Join(t.TempDir(), "none.yaml")) // no context in play
	t.Chdir(t.TempDir())                                                // a dir with no .env up the tree
	t.Setenv("ABCTL_ENV", "")                                           // and no explicit override
	absKey := filepath.Join(t.TempDir(), "abs-key.pem")
	t.Setenv("AB_CLIENT_ID", "BUSINESSAPI.env")
	t.Setenv("AB_PRIVATE_KEY", absKey)

	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.ClientID != "BUSINESSAPI.env" {
		t.Errorf("ClientID = %q, want it from the environment", c.ClientID)
	}
	if c.KeyPath != absKey {
		t.Errorf("KeyPath = %q, want the absolute env value passed through", c.KeyPath)
	}
	if c.APIBase != "https://api-business.apple.com/v1/" {
		t.Errorf("APIBase default = %q", c.APIBase)
	}
	if c.EnvDir == "" {
		t.Error("EnvDir should be the cwd in environment mode (for the gitops tree)")
	}
}

// TestLoadFromEnvVarsRelativeKey: a relative key path resolves against the cwd.
func TestLoadFromEnvVarsRelativeKey(t *testing.T) {
	t.Setenv("ABCTL_CONTEXTS", filepath.Join(t.TempDir(), "none.yaml"))
	t.Chdir(t.TempDir())
	t.Setenv("ABCTL_ENV", "")
	t.Setenv("AB_CLIENT_ID", "BUSINESSAPI.env")
	t.Setenv("AB_PRIVATE_KEY", "secrets/k.pem")

	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.KeyPath != filepath.Join(c.EnvDir, "secrets/k.pem") {
		t.Errorf("relative key = %q, want joined with cwd (%q)", c.KeyPath, c.EnvDir)
	}
}
