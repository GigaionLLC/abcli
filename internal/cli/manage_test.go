package cli

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/GigaionLLC/abcli/internal/ab"
)

// TestMemberKindFor covers A4: attach/detach noun normalization (singular/plural,
// the usergroup aliases) and the relationship/member-type pairs from the API contract.
func TestMemberKindFor(t *testing.T) {
	cases := []struct {
		noun string
		rel  string
	}{
		{"app", "apps"}, {"apps", "apps"},
		{"package", "packages"}, {"packages", "packages"},
		{"device", "orgDevices"}, {"devices", "orgDevices"},
		{"user", "users"}, {"users", "users"},
		{"group", "userGroups"}, {"groups", "userGroups"},
		{"usergroup", "userGroups"}, {"usergroups", "userGroups"},
	}
	for _, c := range cases {
		k, ok := memberKindFor(c.noun)
		if !ok || k.rel != c.rel {
			t.Errorf("memberKindFor(%q) = (%q, %v), want rel %q", c.noun, k.rel, ok, c.rel)
		}
	}
	if _, ok := memberKindFor("blueprint"); ok {
		t.Error("memberKindFor(blueprint) should not resolve")
	}
}

// TestDeviceIDsFromList covers A4: assign/unassign resolves serials via ONE device
// list — exact id wins, serials match case-insensitively, misses and shared serials error.
func TestDeviceIDsFromList(t *testing.T) {
	devs := []ab.Resource{
		{ID: "dev-1", Attributes: []byte(`{"serialNumber":"C02ABC"}`)},
		{ID: "dev-2", Attributes: []byte(`{"serialNumber":"C02XYZ"}`)},
		{ID: "dev-3", Attributes: []byte(`{"serialNumber":"DUPSER"}`)},
		{ID: "dev-4", Attributes: []byte(`{"serialNumber":"DUPSER"}`)},
	}
	ids, err := deviceIDsFromList(devs, []string{"c02abc", "dev-2"})
	if err != nil || len(ids) != 2 || ids[0] != "dev-1" || ids[1] != "dev-2" {
		t.Errorf("deviceIDsFromList = %v, %v; want [dev-1 dev-2]", ids, err)
	}
	if _, err := deviceIDsFromList(devs, []string{"NOPE"}); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Errorf("missing serial = %v, want a not-found error", err)
	}
	if _, err := deviceIDsFromList(devs, []string{"DUPSER"}); err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Errorf("shared serial = %v, want an ambiguity error", err)
	}
	if _, err := deviceIDsFromList(devs, []string{"dev-3"}); err != nil {
		t.Errorf("id lookup must bypass the serial ambiguity: %v", err)
	}
}

// TestEditRequiresFlags covers A4: `edit blueprint`/`edit mdmserver` with no change
// flags fail fast (before any client/API work).
func TestEditRequiresFlags(t *testing.T) {
	if err := runEditBlueprint("Fleet", nil, nil, true, false); err == nil || !strings.Contains(err.Error(), "--rename") {
		t.Errorf("runEditBlueprint(no flags) = %v, want a nothing-to-change error", err)
	}
	if err := runEditMDMServer("Main", nil, nil, true, false); err == nil || !strings.Contains(err.Error(), "--rename") {
		t.Errorf("runEditMDMServer(no flags) = %v, want a nothing-to-change error", err)
	}
}

// TestActivityOutcomeJSONShape covers A4: the assign/unassign payload has stable
// camelCase keys, and the wait-only status keys are omitted when empty.
func TestActivityOutcomeJSONShape(t *testing.T) {
	b, _ := json.Marshal(activityOutcome{Action: "assign", Server: "Main MDM", Devices: 2, ActivityID: "act-1"})
	s := string(b)
	for _, k := range []string{`"action":"assign"`, `"server":"Main MDM"`, `"devices":2`, `"activityId":"act-1"`} {
		if !strings.Contains(s, k) {
			t.Errorf("activityOutcome JSON missing %s: %s", k, s)
		}
	}
	if strings.Contains(s, `"status"`) || strings.Contains(s, `"subStatus"`) {
		t.Errorf("empty wait fields not omitted: %s", s)
	}
	b, _ = json.Marshal(activityOutcome{Action: "unassign", Server: "x", Devices: 1, ActivityID: "a", Status: "COMPLETED", SubStatus: "ok"})
	if !strings.Contains(string(b), `"status":"COMPLETED"`) || !strings.Contains(string(b), `"subStatus":"ok"`) {
		t.Errorf("wait fields missing: %s", b)
	}
}
