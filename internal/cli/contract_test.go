package cli

import (
	"encoding/json"
	"io"
	"os"
	"strings"
	"testing"
)

// TestPlanFormat covers P7: diff/sync must honor the global -o json/-o yaml, with the
// per-command --json shorthand winning, else "" (human tables).
func TestPlanFormat(t *testing.T) {
	orig := flagOutput
	t.Cleanup(func() { flagOutput = orig })
	cases := []struct {
		global    string
		shorthand bool
		want      string
	}{
		{"table", false, ""},
		{"table", true, "json"},
		{"json", false, "json"},
		{"yaml", false, "yaml"},
		{"yaml", true, "json"}, // --json shorthand wins over -o yaml
	}
	for _, c := range cases {
		flagOutput = c.global
		if got := planFormat(c.shorthand); got != c.want {
			t.Errorf("planFormat(global=%s, shorthand=%v) = %q, want %q", c.global, c.shorthand, got, c.want)
		}
	}
}

// TestWantsMachine covers P4: a write emits machine output for --json or any non-table -o.
func TestWantsMachine(t *testing.T) {
	orig := flagOutput
	t.Cleanup(func() { flagOutput = orig })
	flagOutput = "table"
	if wantsMachine(false) {
		t.Error("table + no shorthand should be human output")
	}
	if !wantsMachine(true) {
		t.Error("--json shorthand should request machine output")
	}
	flagOutput = "json"
	if !wantsMachine(false) {
		t.Error("-o json should request machine output")
	}
	flagOutput = "yaml"
	if !wantsMachine(false) {
		t.Error("-o yaml should request machine output")
	}
}

// TestAsListMarshalsEmptyAsArray covers N3: an empty result serializes as [] not null.
func TestAsListMarshalsEmptyAsArray(t *testing.T) {
	var nilSlice []int
	if b, _ := json.Marshal(asList(nilSlice)); string(b) != "[]" {
		t.Errorf("asList(nil) marshaled to %s, want []", b)
	}
	if b, _ := json.Marshal(asList([]int{1, 2})); string(b) != "[1,2]" {
		t.Errorf("asList([1,2]) marshaled to %s, want [1,2]", b)
	}
}

// TestEmitWriteJSON covers P4: emitWrite prints a valid, decode-able outcome on stdout,
// stamps status=done, and uses the exact keys the GUI decodes against.
func TestEmitWriteJSON(t *testing.T) {
	out := captureStdout(t, func() error {
		return emitWrite(writeOutcome{
			Action: "create", Name: "WiFi.mobileconfig", ID: "id-1",
			UpdatedDateTime: "2026-01-02T03:04:05Z", TreeUpdated: true,
		}, true)
	})
	var o writeOutcome
	if err := json.Unmarshal([]byte(out), &o); err != nil {
		t.Fatalf("emitWrite did not produce valid JSON: %v\n%s", err, out)
	}
	if o.Action != "create" || o.ID != "id-1" || o.Status != "done" || !o.TreeUpdated {
		t.Errorf("decoded outcome = %+v", o)
	}
	for _, k := range []string{`"action"`, `"status"`, `"treeUpdated"`, `"updatedDateTime"`} {
		if !strings.Contains(out, k) {
			t.Errorf("missing key %s in %s", k, out)
		}
	}
}

// TestWriteOutcomeOmitsEmptyFields: attach/detach outcomes carry no id/updated/archive,
// so those keys must be omitted (omitempty) while blueprint is present.
func TestWriteOutcomeOmitsEmptyFields(t *testing.T) {
	b, _ := json.Marshal(writeOutcome{Action: "attach", Name: "x", Blueprint: "Fleet", Status: "done", TreeUpdated: true})
	s := string(b)
	if strings.Contains(s, "updatedDateTime") || strings.Contains(s, "archive") || strings.Contains(s, `"id"`) {
		t.Errorf("empty fields not omitted: %s", s)
	}
	if !strings.Contains(s, `"blueprint":"Fleet"`) {
		t.Errorf("blueprint missing: %s", s)
	}
}

// TestWhoamiResultJSONShape covers P1: the connection-test payload has stable snake_case keys.
func TestWhoamiResultJSONShape(t *testing.T) {
	b, _ := json.Marshal(whoamiResult{
		Authenticated: true, ClientID: "BUSINESSAPI.x", APIBase: "https://api",
		TokenExpires: "2026-01-01T00:00:00Z", Configurations: 3, Blueprints: 2,
	})
	s := string(b)
	for _, k := range []string{`"authenticated":true`, `"client_id"`, `"api_base"`, `"token_expires"`, `"configurations":3`, `"blueprints":2`} {
		if !strings.Contains(s, k) {
			t.Errorf("whoamiResult JSON missing %s: %s", k, s)
		}
	}
}

// captureStdout redirects os.Stdout for the duration of fn and returns what it wrote.
func captureStdout(t *testing.T, fn func() error) string {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	runErr := fn()
	_ = w.Close()
	os.Stdout = old
	b, _ := io.ReadAll(r)
	if runErr != nil {
		t.Fatalf("fn returned error: %v", runErr)
	}
	return string(b)
}
