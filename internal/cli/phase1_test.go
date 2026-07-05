package cli

import "testing"

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
