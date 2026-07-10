package cli

import (
	"testing"
	"time"
)

func TestParseSince(t *testing.T) {
	if d, err := parseSince("7d"); err != nil || d != 7*24*time.Hour {
		t.Errorf("7d → %v, %v", d, err)
	}
	if d, err := parseSince("24h"); err != nil || d != 24*time.Hour {
		t.Errorf("24h → %v, %v", d, err)
	}
	if _, err := parseSince("nonsense"); err == nil {
		t.Error("expected an error for a bad --since value")
	}
}

func TestExitError(t *testing.T) {
	if (ExitError{Code: 3}).Error() == "" {
		t.Error("ExitError.Error() should be non-empty")
	}
}

func TestInspectAttrHelpers(t *testing.T) {
	a := map[string]any{
		"imei":                 []any{"35-1", "35-2"},
		"isFileVaultEnabled":   true,
		"isFirewallEnabled":    false,
		"totalMemberCount":     float64(12),
		"storageFreeCapacity":  float64(250e9),
		"storageTotalCapacity": float64(500e9),
		"roleOuList":           []any{map[string]any{"roleName": "ADMIN", "ouId": "ou-1"}, map[string]any{"roleName": "STAFF"}},
	}
	if got := attrJoin(a, "imei"); got != "35-1, 35-2" {
		t.Errorf("attrJoin(imei) = %q", got)
	}
	if got := attrJoin(a, "missing"); got != "" {
		t.Errorf("attrJoin(missing) = %q, want empty", got)
	}
	if got := boolAttr(a, "isFileVaultEnabled"); got != "enabled" {
		t.Errorf("boolAttr(filevault) = %q", got)
	}
	if got := boolAttr(a, "isFirewallEnabled"); got != "disabled" {
		t.Errorf("boolAttr(firewall) = %q", got)
	}
	if got := boolAttr(a, "missing"); got != "" {
		t.Errorf("boolAttr(missing) = %q, want empty (unreported)", got)
	}
	if got := intAttr(a, "totalMemberCount"); got != "12" {
		t.Errorf("intAttr = %q", got)
	}
	if got := storageUsed(a); got != "250.0 GB used of 500.0 GB" {
		t.Errorf("storageUsed = %q", got)
	}
	if got := storageUsed(map[string]any{}); got != "" {
		t.Errorf("storageUsed(no posture) = %q, want empty", got)
	}
	if got := userRoles(a); got != "ADMIN, STAFF" {
		t.Errorf("userRoles = %q", got)
	}
}
