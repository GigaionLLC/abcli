package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
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

func TestValidateProfile(t *testing.T) {
	good := []byte(`<plist><key>PayloadType</key><string>Configuration</string>PayloadContent</plist>`)
	if err := validateProfile(good); err != nil {
		t.Errorf("valid profile rejected: %v", err)
	}
	if err := validateProfile([]byte("nope")); err == nil {
		t.Error("expected structural validation to fail on garbage")
	}
	if err := validateProfile(make([]byte, 1<<20)); err == nil {
		t.Error("expected >=1MB profile to be rejected")
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
