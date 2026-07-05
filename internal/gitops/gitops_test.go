package gitops

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSanitize(t *testing.T) {
	cases := map[string]string{
		"Default MacOS Group": "default-macos-group",
		"Group_1":             "group-1",
		"  Trim Me  ":         "trim-me",
	}
	for in, want := range cases {
		if got := Sanitize(in); got != want {
			t.Errorf("Sanitize(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLoadDesired(t *testing.T) {
	dir := t.TempDir()
	tr := NewTree(dir)
	if err := os.MkdirAll(tr.LibDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tr.LibDir, "x.mobileconfig"), []byte("X"), 0o644); err != nil {
		t.Fatal(err)
	}
	// non-.mobileconfig files are ignored
	_ = os.WriteFile(filepath.Join(tr.LibDir, "note.txt"), []byte("nope"), 0o644)

	got, err := tr.LoadDesired()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || string(got["x.mobileconfig"]) != "X" {
		t.Fatalf("LoadDesired = %v, want {x.mobileconfig: X}", got)
	}
}

func TestBlueprintSpecRoundTrip(t *testing.T) {
	dir := t.TempDir()
	tr := NewTree(dir)
	specs := []BlueprintSpec{
		{Name: "Sales Team", ID: "id-1", Description: "field sales", Configurations: []string{"wifi.mobileconfig", "vpn.mobileconfig"}},
		{Name: "Eng", ID: "id-2", Configurations: []string{"dock.mobileconfig"}},
	}
	for _, s := range specs {
		if err := tr.WriteBlueprintSpec(s); err != nil {
			t.Fatal(err)
		}
	}
	// a non-.yml file is ignored
	_ = os.WriteFile(filepath.Join(tr.BlueprintsDir, "notes.txt"), []byte("nope"), 0o644)

	got, err := tr.LoadBlueprints()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("LoadBlueprints returned %d, want 2: %v", len(got), got)
	}
	if s := got["Sales Team"]; s.ID != "id-1" || s.Description != "field sales" ||
		len(s.Configurations) != 2 || s.Configurations[0] != "wifi.mobileconfig" {
		t.Errorf("Sales Team round-trip = %+v", s)
	}
	if got["Eng"].Configurations[0] != "dock.mobileconfig" {
		t.Errorf("Eng round-trip = %+v", got["Eng"])
	}
}

func TestLoadBlueprintsRejectsMissingName(t *testing.T) {
	dir := t.TempDir()
	tr := NewTree(dir)
	if err := os.MkdirAll(tr.BlueprintsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tr.BlueprintsDir, "bad.yml"), []byte("configurations:\n  - x.mobileconfig\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := tr.LoadBlueprints(); err == nil {
		t.Fatal("expected an error for a manifest missing 'name'")
	}
}

func TestLoadBlueprintsMissingDir(t *testing.T) {
	got, err := NewTree(t.TempDir()).LoadBlueprints()
	if err != nil || len(got) != 0 {
		t.Fatalf("missing blueprints dir → %v, %v; want empty, nil", got, err)
	}
}

// TestWriteBlueprintSpecNoCollision: two distinct names that sanitize to the same
// slug must not overwrite each other, and both must load back.
func TestWriteBlueprintSpecNoCollision(t *testing.T) {
	dir := t.TempDir()
	tr := NewTree(dir)
	if err := tr.WriteBlueprintSpec(BlueprintSpec{Name: "Sales (US)", ID: "id-1", Configurations: []string{"a.mobileconfig"}}); err != nil {
		t.Fatal(err)
	}
	if err := tr.WriteBlueprintSpec(BlueprintSpec{Name: "Sales US", ID: "id-2", Configurations: []string{"b.mobileconfig"}}); err != nil {
		t.Fatal(err)
	}
	got, err := tr.LoadBlueprints()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("slug-colliding names collapsed to %d files, want 2: %v", len(got), got)
	}
	if got["Sales (US)"].ID != "id-1" || got["Sales US"].ID != "id-2" {
		t.Errorf("collision lost data: %+v", got)
	}
	// Re-writing the same blueprint (by name) must reuse its file, not fork a new one.
	if err := tr.WriteBlueprintSpec(BlueprintSpec{Name: "Sales (US)", ID: "id-1", Configurations: []string{"a.mobileconfig", "c.mobileconfig"}}); err != nil {
		t.Fatal(err)
	}
	got, _ = tr.LoadBlueprints()
	if len(got) != 2 || len(got["Sales (US)"].Configurations) != 2 {
		t.Errorf("re-write should update in place, got %d files / %+v", len(got), got["Sales (US)"])
	}
}

// TestLoadBlueprintsAcceptsYaml: a hand-authored .yaml manifest is loaded (not
// silently dropped).
func TestLoadBlueprintsAcceptsYaml(t *testing.T) {
	dir := t.TempDir()
	tr := NewTree(dir)
	if err := os.MkdirAll(tr.BlueprintsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tr.BlueprintsDir, "kiosk.yaml"),
		[]byte("name: Kiosk\nconfigurations:\n  - lockdown.mobileconfig\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := tr.LoadBlueprints()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := got["Kiosk"]; !ok {
		t.Errorf("a .yaml manifest must be loaded, got %v", got)
	}
}
