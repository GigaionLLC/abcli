package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GigaionLLC/abcli/internal/ab"
)

func TestConfigName(t *testing.T) {
	if got := configName("wifi"); got != "wifi.mobileconfig" {
		t.Errorf("configName(wifi) = %q", got)
	}
	if got := configName("wifi.mobileconfig"); got != "wifi.mobileconfig" {
		t.Errorf("configName already-suffixed = %q", got)
	}
}

// wellFormedProfile is the minimum Apple actually accepts: a top-level dict with the
// four required keys and a PayloadVersion of exactly 1.
func wellFormedProfile(payloadVersion string) []byte {
	return []byte(`<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadVersion</key><integer>` + payloadVersion + `</integer>
  <key>PayloadIdentifier</key><string>com.example.test</string>
  <key>PayloadUUID</key><string>2B9E1A54-9E1D-4E7E-9B0E-9A1B2C3D4E5F</string>
  <key>PayloadContent</key><array/>
</dict></plist>`)
}

func TestValidateProfile(t *testing.T) {
	if err := validateProfile(wellFormedProfile("1")); err != nil {
		t.Errorf("valid profile rejected: %v", err)
	}
	if err := validateProfile([]byte("nope")); err == nil {
		t.Error("expected structural validation to fail on garbage")
	}
	if err := validateProfile(make([]byte, 1<<20)); err == nil {
		t.Error("expected >=1MB profile to be rejected")
	}
}

// TestValidateProfileRejectsBadPayloadVersion is the regression lock for the incident
// that motivated all of the read-back machinery: Apple accepts a profile whose TOP-LEVEL
// PayloadVersion is not 1 with a 2xx and then silently declines to store it, so the sync
// loops forever on a change that never lands. `abctl validate` has caught this since
// v0.4.19; the WRITE path did not, which meant create/replace/edit/apply -f would happily
// push the exact shape known to be dropped. Catching it here costs no API call at all.
func TestValidateProfileRejectsBadPayloadVersion(t *testing.T) {
	err := validateProfile(wellFormedProfile("2"))
	if err == nil {
		t.Fatal("a top-level PayloadVersion of 2 must be rejected before the write")
	}
	if !strings.Contains(err.Error(), "payload-version") {
		t.Errorf("error should name the payload-version rule, got: %v", err)
	}
	// The remedy has to be reachable: --force is how an operator overrides a hard error.
	if !strings.Contains(err.Error(), "--force") {
		t.Errorf("error should point at --force, got: %v", err)
	}
}

func TestApiBody(t *testing.T) {
	// nil when no fields/input
	if b, err := apiBody(nil, ""); err != nil || b != nil {
		t.Errorf("empty apiBody = %v, %v; want nil,nil", b, err)
	}
	// flat fields → map
	b, err := apiBody([]string{"name=wifi", "type=CUSTOM_SETTING"}, "")
	if err != nil {
		t.Fatal(err)
	}
	m, ok := b.(map[string]any)
	if !ok || m["name"] != "wifi" || m["type"] != "CUSTOM_SETTING" {
		t.Errorf("apiBody fields = %#v", b)
	}
	// bad field
	if _, err := apiBody([]string{"noequals"}, ""); err == nil {
		t.Error("expected error on a field without '='")
	}
	// --input file → raw JSON
	dir := t.TempDir()
	f := filepath.Join(dir, "body.json")
	_ = os.WriteFile(f, []byte(`{"data":1}`), 0o644)
	raw, err := apiBody(nil, f)
	if err != nil {
		t.Fatal(err)
	}
	rm, ok := raw.(json.RawMessage)
	if !ok || string(rm) != `{"data":1}` {
		t.Errorf("apiBody input = %#v", raw)
	}
}

func TestApplyFilter(t *testing.T) {
	items := []ab.Resource{
		{ID: "1", Attributes: []byte(`{"name":"Corp Wi-Fi","type":"CUSTOM_SETTING"}`)},
		{ID: "2", Attributes: []byte(`{"name":"VPN","type":"CUSTOM_SETTING"}`)},
		{ID: "3", Attributes: []byte(`{"name":"Passcode","type":"NATIVE"}`)},
	}
	got := applyFilter(items, []string{"name=wi"}) // case-insensitive substring
	if len(got) != 1 || got[0].ID != "1" {
		t.Errorf("filter name=wi → %d items", len(got))
	}
	got = applyFilter(items, []string{"type=CUSTOM_SETTING"})
	if len(got) != 2 {
		t.Errorf("filter type → %d items, want 2", len(got))
	}
	if len(applyFilter(items, nil)) != 3 {
		t.Error("no filters must pass everything through")
	}
}
