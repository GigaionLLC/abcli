package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestContextRoundTripAndResolve(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ABCTL_CONTEXTS", filepath.Join(dir, "contexts.yaml"))

	store, err := LoadContexts()
	if err != nil {
		t.Fatal(err)
	}
	key := filepath.Join(dir, "key.pem") // absolute on this OS
	store.Contexts["prod"] = Context{ClientID: "BUSINESSAPI.prod", KeyPath: key}
	store.Contexts["staging"] = Context{ClientID: "BUSINESSAPI.staging", KeyPath: key, APIBase: "https://x/"}
	store.Current = "prod"
	if err := store.Save(); err != nil {
		t.Fatal(err)
	}

	// no explicit context → the active ("prod") one, with defaults filled in.
	cfg, err := Resolve("")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ClientID != "BUSINESSAPI.prod" || cfg.KeyPath != key {
		t.Errorf("resolved %+v", cfg)
	}
	if cfg.APIBase != DefaultAPIBase || cfg.Scope != DefaultScope {
		t.Errorf("defaults not applied: %+v", cfg)
	}

	// explicit context overrides + honors its own api_base override.
	cfg, err = Resolve("staging")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ClientID != "BUSINESSAPI.staging" || cfg.APIBase != "https://x/" {
		t.Errorf("explicit context = %+v", cfg)
	}

	// an explicit missing context is an error (not a silent fallback).
	if _, err := Resolve("nope"); err == nil {
		t.Error("expected an error resolving a missing explicit context")
	}
}

func TestResolveFallsBackToEnvWhenNoContext(t *testing.T) {
	// A contexts file that doesn't exist → no context selected → env-var fallback.
	t.Setenv("ABCTL_CONTEXTS", filepath.Join(t.TempDir(), "absent.yaml"))
	t.Chdir(t.TempDir())
	t.Setenv("ABCTL_ENV", "")
	t.Setenv("AB_CLIENT_ID", "BUSINESSAPI.env")
	t.Setenv("AB_PRIVATE_KEY", filepath.Join(t.TempDir(), "k.pem"))

	cfg, err := Resolve("")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ClientID != "BUSINESSAPI.env" {
		t.Errorf("expected env-var fallback, got %+v", cfg)
	}
}

func TestContextsSaveIsPrivate(t *testing.T) {
	p := filepath.Join(t.TempDir(), "contexts.yaml")
	t.Setenv("ABCTL_CONTEXTS", p)
	s := &Contexts{Contexts: map[string]Context{"a": {ClientID: "x", KeyPath: "k"}}}
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	// 0600 on POSIX; Windows ignores the bits but the file must at least be readable back.
	if fi.Mode().Perm()&0o077 != 0 && os.Getenv("OS") != "Windows_NT" {
		t.Errorf("contexts file mode = %v, want 0600", fi.Mode().Perm())
	}
	got, _ := LoadContexts()
	if got.Contexts["a"].ClientID != "x" {
		t.Errorf("round-trip lost data: %+v", got)
	}
}
