//go:build integration

package vpp

import (
	"os"
	"testing"
)

// TestLiveVPPReadOnly hits the real App and Book Management API. It self-skips unless
// $AB_VPP_TOKEN is set, so it's safe in CI/forks. Run: go test -tags=integration ./internal/vpp/
func TestLiveVPPReadOnly(t *testing.T) {
	token := os.Getenv("AB_VPP_TOKEN")
	if token == "" {
		t.Skip("AB_VPP_TOKEN not set — skipping the live VPP read-only test")
	}
	c := NewClient(token, os.Getenv("AB_VPP_BASE"))

	sc, err := c.ServiceConfig()
	if err != nil {
		t.Fatalf("service config: %v", err)
	}
	t.Logf("VPP OK — location=%q endpoints=%d maxAssets=%d", sc.LocationName, len(sc.URLs), sc.Limits["maxAssets"])

	assets, err := c.GetAssets(AssetFilter{})
	if err != nil {
		t.Fatalf("get assets: %v", err)
	}
	t.Logf("assets=%d", len(assets))
	for i, a := range assets {
		if i >= 3 {
			break
		}
		t.Logf("  %s %s avail=%d assigned=%d total=%d", a.ProductType, a.AdamID, a.AvailableCount, a.AssignedCount, a.TotalCount)
	}
}
