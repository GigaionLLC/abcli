package cli

import (
	"testing"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/gitops"
)

// TestEnvApproved verifies the write-confirmation bypass parses the value: only a
// truthy $ABCTL_APPROVE approves; 0/false/no/off/empty must NOT bypass the gate.
func TestEnvApproved(t *testing.T) {
	cases := map[string]bool{
		"1": true, "true": true, "TRUE": true, "yes": true, "Y": true, "on": true,
		"": false, "0": false, "false": false, "no": false, "off": false, "banana": false,
	}
	for v, want := range cases {
		t.Setenv("ABCTL_APPROVE", v)
		if got := envApproved(); got != want {
			t.Errorf("envApproved(%q) = %v, want %v", v, got, want)
		}
	}
}

func TestParsePlatforms(t *testing.T) {
	if got := parsePlatforms(""); got != nil {
		t.Errorf("parsePlatforms(\"\") = %v, want nil", got)
	}
	if got := parsePlatforms("   "); got != nil {
		t.Errorf("parsePlatforms(whitespace) = %v, want nil", got)
	}
	got := parsePlatforms("PLATFORM_MACOS, PLATFORM_IOS ,")
	if len(got) != 2 || got[0] != "PLATFORM_MACOS" || got[1] != "PLATFORM_IOS" {
		t.Errorf("parsePlatforms = %v, want [PLATFORM_MACOS PLATFORM_IOS]", got)
	}
}

// TestManagedBlueprintCollections covers the lazy-fetch gate: configurations
// always, plus exactly the optional collections some manifest manages (a
// present-but-empty key counts; a nil key never does), in stable order.
func TestManagedBlueprintCollections(t *testing.T) {
	strs := func(ss ...string) *[]string { return &ss }

	// No manifests at all → configurations only (no full-tenant lists).
	if got := managedBlueprintCollections(nil); len(got) != 1 || got[0] != ab.CollectionConfigurations {
		t.Errorf("no specs → %v, want [configurations]", got)
	}

	specs := map[string]gitops.BlueprintSpec{
		"Sales": {Name: "Sales", Configurations: []string{"wifi.mobileconfig"}, Devices: strs("C02AAA")},
		"Eng":   {Name: "Eng", Users: strs()}, // present-but-empty still MANAGES users
	}
	got := managedBlueprintCollections(specs)
	want := []string{ab.CollectionConfigurations, ab.CollectionDevices, ab.CollectionUsers}
	if len(got) != len(want) {
		t.Fatalf("managed collections = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("managed collections = %v, want %v (stable ab.BlueprintCollections order)", got, want)
		}
	}
}

// TestManagedListPinsEmpty: seed --blueprint-membership must write `key: []`
// (managed) even for an empty live membership — never a nil pointer that would
// leave the collection unmanaged.
func TestManagedListPinsEmpty(t *testing.T) {
	if p := managedList(nil); p == nil || *p == nil || len(*p) != 0 {
		t.Errorf("managedList(nil) = %v, want non-nil pointer to empty slice", p)
	}
	if p := managedList([]string{"a"}); p == nil || len(*p) != 1 || (*p)[0] != "a" {
		t.Errorf("managedList([a]) = %v", p)
	}
}

// TestInvertMemberMaps: the name→id direction mirrors id→name per collection,
// and a display name shared by >1 id inverts to "" (present-but-empty — the
// ambiguity sentinel that blocks attaches and suppresses detaches) rather than
// to whichever id map iteration visits last.
func TestInvertMemberMaps(t *testing.T) {
	got := invertMemberMaps(map[string]map[string]string{
		ab.CollectionDevices: {"d-1": "C02AAA", "d-2": "C02BBB"},
		ab.CollectionUsers:   {"u-1": "ann@x.co"},
		ab.CollectionApps:    {"a-1": "Keynote", "a-2": "Keynote", "a-3": "Numbers"},
	})
	if m := got[ab.CollectionDevices]; len(m) != 2 || m["C02AAA"] != "d-1" || m["C02BBB"] != "d-2" {
		t.Errorf("devices inverted = %v", m)
	}
	if m := got[ab.CollectionUsers]; len(m) != 1 || m["ann@x.co"] != "u-1" {
		t.Errorf("users inverted = %v", m)
	}
	m := got[ab.CollectionApps]
	if m["Numbers"] != "a-3" {
		t.Errorf("apps inverted = %v", m)
	}
	if id, ok := m["Keynote"]; !ok || id != "" {
		t.Errorf("duplicate name Keynote = %q (present=%v), want present-but-empty (ambiguous)", id, ok)
	}
}

// TestCanonicalizeBlueprintMembers: manifest entries written as an accepted
// alias (user's managed Apple Account, address/serial case variants) are
// rewritten to the canonical live name before diffing, so `sync --prune` can't
// detach a member the manifest actually lists. Ambiguous ("") and unknown
// aliases, and unmanaged collections, stay untouched.
func TestCanonicalizeBlueprintMembers(t *testing.T) {
	strs := func(ss ...string) *[]string { return &ss }
	specs := map[string]gitops.BlueprintSpec{
		"Sales": {
			Name:    "Sales",
			Users:   strs("Bob@AppleID.x.co", "ann@x.co", "dup@x.co", "ghost@x.co"),
			Devices: strs("c02aaa"),
		},
		"Eng": {Name: "Eng"}, // users/devices unmanaged (nil) → untouched
	}
	canonicalizeBlueprintMembers(specs, map[string]map[string]string{
		ab.CollectionUsers: {
			"bob@appleid.x.co": "bob@x.co", // managed Apple Account → canonical email
			"ann@x.co":         "ann@x.co", // already canonical
			"dup@x.co":         "",         // ambiguous alias — leave as written
		},
		ab.CollectionDevices: {"c02aaa": "C02AAA"},
	})
	gotUsers := *specs["Sales"].Users
	wantUsers := []string{"bob@x.co", "ann@x.co", "dup@x.co", "ghost@x.co"}
	for i := range wantUsers {
		if gotUsers[i] != wantUsers[i] {
			t.Fatalf("users = %v, want %v", gotUsers, wantUsers)
		}
	}
	if got := *specs["Sales"].Devices; got[0] != "C02AAA" {
		t.Errorf("devices = %v, want serial canonicalized to C02AAA", got)
	}
	if specs["Eng"].Users != nil || specs["Eng"].Devices != nil {
		t.Error("unmanaged collections must stay nil")
	}
}
