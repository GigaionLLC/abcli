package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseSpecFiles(t *testing.T) {
	f := filepath.Join(t.TempDir(), "specs.yml")
	body := "apiVersion: abctl/v1\n" +
		"kind: Configuration\n" +
		"metadata:\n  name: wifi\n" +
		"spec:\n  profile: |\n    <plist>PayloadType Configuration PayloadContent</plist>\n" +
		"---\n" +
		"apiVersion: abctl/v1\n" +
		"kind: Blueprint\n" +
		"metadata:\n  name: Sales\n" +
		"spec:\n  configurations: [wifi.mobileconfig]\n"
	if err := os.WriteFile(f, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	specs, err := parseSpecFiles([]string{f})
	if err != nil {
		t.Fatal(err)
	}
	if len(specs) != 2 {
		t.Fatalf("got %d specs, want 2", len(specs))
	}
	if specs[0].Kind != "Configuration" { // Configurations sort before Blueprints
		t.Errorf("order: first kind = %q, want Configuration", specs[0].Kind)
	}
	pb, err := specs[0].profileBytes()
	if err != nil || !strings.Contains(string(pb), "PayloadContent") {
		t.Errorf("profileBytes = %q (err %v)", pb, err)
	}
	if specs[1].Kind != "Blueprint" || len(specs[1].Spec.Configurations) != 1 {
		t.Errorf("blueprint spec = %+v", specs[1])
	}
}

func TestParseSpecRejectsBadVersion(t *testing.T) {
	f := filepath.Join(t.TempDir(), "x.yml")
	_ = os.WriteFile(f, []byte("apiVersion: v1\nkind: Configuration\nmetadata:\n  name: x\n"), 0o644)
	if _, err := parseSpecFiles([]string{f}); err == nil {
		t.Error("expected an error for a non-abctl/v1 apiVersion")
	}
}

func TestProfileFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "p.mobileconfig"), []byte("XML"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := Spec{srcDir: dir}
	s.Metadata.Name = "x"
	s.Spec.ProfileFile = "p.mobileconfig"
	b, err := s.profileBytes()
	if err != nil || string(b) != "XML" {
		t.Errorf("profileFile → %q (err %v)", b, err)
	}
	// a spec with neither profile nor profileFile is an error
	if _, err := (Spec{}).profileBytes(); err == nil {
		t.Error("expected error when neither profile nor profileFile is set")
	}
}

func TestOutFmtAndValidate(t *testing.T) {
	orig := flagOutput
	t.Cleanup(func() { flagOutput = orig })

	flagOutput = "table"
	if outFmt(false) != "table" || outFmt(true) != "json" {
		t.Error("outFmt: table default / --json shorthand wrong")
	}
	flagOutput = "yaml"
	if outFmt(false) != "yaml" {
		t.Error("outFmt should honor global yaml")
	}
	if err := validOutput("json"); err != nil {
		t.Errorf("json should be valid: %v", err)
	}
	if validOutput("xml") == nil {
		t.Error("xml should be invalid")
	}
}
