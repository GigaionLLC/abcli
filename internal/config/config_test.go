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
