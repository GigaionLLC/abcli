package gitops

import (
	"os"
	"path/filepath"
	"strings"
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
	// a bare-named config (a live ABM name without the extension) IS a config
	_ = os.WriteFile(filepath.Join(tr.LibDir, "WiFi-Corp"), []byte("W"), 0o644)
	// other extensions and dotfiles are ignored
	_ = os.WriteFile(filepath.Join(tr.LibDir, "note.txt"), []byte("nope"), 0o644)
	_ = os.WriteFile(filepath.Join(tr.LibDir, ".gitkeep"), []byte(""), 0o644)

	got, err := tr.LoadDesired()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || string(got["x.mobileconfig"]) != "X" || string(got["WiFi-Corp"]) != "W" {
		t.Fatalf("LoadDesired = %v, want {x.mobileconfig:X, WiFi-Corp:W}", got)
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

// TestBlueprintSpecMemberSemantics pins the pointer-slice contract on the five
// optional member keys: an absent key (or an explicit null) is UNMANAGED and
// Members reports managed=false, while a present key — even an empty list —
// manages the collection. Configurations keeps its always-managed semantics.
func TestBlueprintSpecMemberSemantics(t *testing.T) {
	dir := t.TempDir()
	tr := NewTree(dir)
	if err := os.MkdirAll(tr.BlueprintsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifest := "name: Sales\n" +
		"configurations:\n  - wifi.mobileconfig\n" +
		"apps: []\n" + // present-but-empty → managed to zero
		"devices:\n  - C02AAA\n" + // present with members → managed
		"users:\n" // explicit null → UNMANAGED (same as absent)
	if err := os.WriteFile(filepath.Join(tr.BlueprintsDir, "sales.yml"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := tr.LoadBlueprints()
	if err != nil {
		t.Fatal(err)
	}
	s := got["Sales"]

	if names, managed := s.Members("configurations"); !managed || len(names) != 1 || names[0] != "wifi.mobileconfig" {
		t.Errorf("configurations = %v managed=%v, want always-managed [wifi.mobileconfig]", names, managed)
	}
	if names, managed := s.Members("apps"); !managed || len(names) != 0 {
		t.Errorf("apps: [] = %v managed=%v, want managed-to-zero", names, managed)
	}
	if names, managed := s.Members("devices"); !managed || len(names) != 1 || names[0] != "C02AAA" {
		t.Errorf("devices = %v managed=%v, want managed [C02AAA]", names, managed)
	}
	for _, unmanaged := range []string{"users", "packages", "groups"} {
		if _, managed := s.Members(unmanaged); managed {
			t.Errorf("%s must be UNMANAGED (null or absent key)", unmanaged)
		}
	}
	if _, managed := s.Members("nonsense"); managed {
		t.Error("an unknown collection key must be unmanaged")
	}
}

// TestBlueprintSpecMembersRoundTrip: WriteBlueprintSpec preserves the
// managed-vs-unmanaged distinction on disk — a managed-empty key is written as
// `key: []` (still managed after reload) and a nil key stays absent.
func TestBlueprintSpecMembersRoundTrip(t *testing.T) {
	dir := t.TempDir()
	tr := NewTree(dir)
	apps := []string{}
	devices := []string{"C02AAA", "C02BBB"}
	if err := tr.WriteBlueprintSpec(BlueprintSpec{
		Name:           "Sales",
		ID:             "id-1",
		Configurations: []string{"wifi.mobileconfig"},
		Apps:           &apps,
		Devices:        &devices,
		// Packages/Users/Groups nil → keys must not appear in the file
	}); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(tr.BlueprintsDir, "sales.yml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "apps: []") {
		t.Errorf("managed-empty apps must be written as `apps: []`:\n%s", raw)
	}
	for _, absent := range []string{"packages:", "users:", "groups:"} {
		if strings.Contains(string(raw), absent) {
			t.Errorf("unmanaged key %q must be omitted from the manifest:\n%s", absent, raw)
		}
	}

	got, err := tr.LoadBlueprints()
	if err != nil {
		t.Fatal(err)
	}
	s := got["Sales"]
	if names, managed := s.Members("apps"); !managed || len(names) != 0 {
		t.Errorf("apps after round-trip = %v managed=%v, want managed-to-zero", names, managed)
	}
	if names, managed := s.Members("devices"); !managed || len(names) != 2 {
		t.Errorf("devices after round-trip = %v managed=%v", names, managed)
	}
	if _, managed := s.Members("users"); managed {
		t.Error("users must stay unmanaged after round-trip")
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

// TestWithMemberIsAdditiveAndRespectsManagedKeys pins the adopt write: it ADDS
// (sorted, de-duplicated) without disturbing the rest of the manifest, and it
// refuses an unmanaged optional collection rather than flipping it to managed —
// which would put every other live member of that collection at risk of a prune.
func TestWithMemberIsAdditiveAndRespectsManagedKeys(t *testing.T) {
	apps := []string{"Pages"}
	base := BlueprintSpec{
		Name:           "Sales",
		ID:             "bp-1",
		Description:    "the sales fleet",
		Configurations: []string{"wifi.mobileconfig"},
		Apps:           &apps,
		// Packages/Devices/Users/Groups stay nil == unmanaged
	}

	got, ok := base.WithMember("configurations", "old.mobileconfig")
	if !ok {
		t.Fatal("configurations is always managed — the add must succeed")
	}
	if len(got.Configurations) != 2 || got.Configurations[0] != "old.mobileconfig" || got.Configurations[1] != "wifi.mobileconfig" {
		t.Errorf("configurations = %v, want the sorted union", got.Configurations)
	}
	if got.Description != "the sales fleet" || got.ID != "bp-1" {
		t.Error("the rest of the manifest must survive an adopt")
	}
	if got.Apps == nil || len(*got.Apps) != 1 {
		t.Errorf("a managed collection the adopt did not target must be untouched: %v", got.Apps)
	}

	// Idempotent: adopting a member the manifest already declares is a no-op success.
	again, ok := got.WithMember("configurations", "old.mobileconfig")
	if !ok || len(again.Configurations) != 2 {
		t.Errorf("re-adopting must be a no-op success, got ok=%v %v", ok, again.Configurations)
	}

	// A managed-but-empty key still accepts members (present == managed).
	empty := []string{}
	withEmpty := BlueprintSpec{Name: "Kiosk", Packages: &empty}
	if got, ok := withEmpty.WithMember("packages", "Suite.pkg"); !ok || len(*got.Packages) != 1 {
		t.Errorf("packages: [] is MANAGED and must accept an adopt, got ok=%v", ok)
	}

	// Unmanaged (absent key) is refused, and stays absent.
	if got, ok := base.WithMember("devices", "C02XYZ"); ok || got.Devices != nil {
		t.Errorf("an unmanaged collection must be refused, got ok=%v devices=%v", ok, got.Devices)
	}
	if got, ok := base.WithMember("nonsense", "x"); ok {
		t.Errorf("an unknown collection key must be refused, got %+v", got)
	}
}
