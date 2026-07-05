package config

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestContextJSONLowercaseKeys covers P5: `context get -o json` must emit lowercase
// snake_case keys (matching the yaml + every other payload), never the Go field names.
func TestContextJSONLowercaseKeys(t *testing.T) {
	b, err := json.Marshal(Context{
		ClientID: "BUSINESSAPI.x", KeyPath: "/keys/k.pem", APIBase: "https://api", Scope: "business.api",
	})
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	for _, want := range []string{`"client_id"`, `"key"`, `"api_base"`, `"scope"`} {
		if !strings.Contains(s, want) {
			t.Errorf("Context JSON missing %s: %s", want, s)
		}
	}
	for _, bad := range []string{"ClientID", "KeyPath", "APIBase", "Scope"} {
		if strings.Contains(s, bad) {
			t.Errorf("Go field name %q leaked into JSON: %s", bad, s)
		}
	}
	// The key PATH may appear (it is not secret); key MATERIAL never does.
	if !strings.Contains(s, "/keys/k.pem") {
		t.Errorf("key path should be present: %s", s)
	}
}
