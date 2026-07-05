//go:build integration

// This file is compiled only with `-tags=integration`, so the normal
// (credential-free, fully mocked) test suite never runs it. It performs a
// READ-ONLY smoke test against a live Apple Business tenant and self-skips
// when credentials are absent — so it is safe to leave wired into CI.
package ab

import (
	"os"
	"testing"

	"github.com/GigaionLLC/abcli/internal/config"
)

// TestLiveReadOnly authenticates against a real Apple Business tenant and issues
// a single READ request (never a write). It runs only under `-tags=integration`
// and only when AB_CLIENT_ID + AB_PRIVATE_KEY are set; otherwise it skips.
//
// It reads `/v1/users`, which is an *implicit* permission on every API account
// (cannot be revoked), so it is the most portable endpoint to smoke-test and is
// unaffected by Included-MDM / Terms-&-Conditions gating on other resources.
func TestLiveReadOnly(t *testing.T) {
	clientID, keyPath := os.Getenv("AB_CLIENT_ID"), os.Getenv("AB_PRIVATE_KEY")
	if clientID == "" || keyPath == "" {
		t.Skip("live credentials not set (AB_CLIENT_ID + AB_PRIVATE_KEY); skipping live integration test")
	}

	cfg := &config.Config{
		ClientID: clientID,
		KeyPath:  keyPath,
		Scope:    "business.api",
		TokenURL: "https://account.apple.com/auth/oauth2/token",
		TokenAud: "https://account.apple.com/auth/oauth2/v2/token",
		APIBase:  "https://api-business.apple.com/v1/",
		EnvDir:   t.TempDir(), // token cache goes to a throwaway dir
	}
	c := NewClient(cfg)

	if _, err := c.TokenSource().Token(); err != nil {
		t.Fatalf("token mint failed (auth chain): %v", err)
	}

	status, _, err := c.Raw("GET", "users?limit=1", nil)
	if err != nil {
		t.Fatalf("live read (GET users) failed: %v", err)
	}
	if status != 200 {
		t.Fatalf("live read (GET users): got HTTP %d, want 200", status)
	}
	t.Logf("live read-only smoke OK (auth + GET users -> %d)", status)
}
