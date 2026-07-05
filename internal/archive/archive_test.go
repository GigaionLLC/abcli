package archive

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWrite(t *testing.T) {
	root := t.TempDir()
	now := time.Date(2026, 7, 4, 12, 0, 0, 0, time.UTC)

	path, err := Write(root, "wifi.mobileconfig", "overwritten-by-newer", []byte("<xml/>"),
		map[string]string{"abm_id": "id-1", "hash": "abc"}, now)
	if err != nil {
		t.Fatal(err)
	}

	// Path is <root>/wifi/20260704T120000Z--overwritten-by-newer.mobileconfig
	// (the .mobileconfig suffix is trimmed from the subdir name).
	wantPath := filepath.Join(root, "wifi", "20260704T120000Z--overwritten-by-newer.mobileconfig")
	if path != wantPath {
		t.Fatalf("path = %q, want %q", path, wantPath)
	}
	// The timestamp must be Windows-safe: no colons in the generated filename
	// (the drive-letter colon in the temp root is not ours to control).
	if strings.Contains(filepath.Base(path), ":") {
		t.Errorf("archive filename contains a colon (not Windows-safe): %q", filepath.Base(path))
	}

	body, err := os.ReadFile(path)
	if err != nil || string(body) != "<xml/>" {
		t.Fatalf("profile body = %q (err %v), want <xml/>", body, err)
	}

	sidecar := strings.TrimSuffix(path, ".mobileconfig") + ".json"
	sb, err := os.ReadFile(sidecar)
	if err != nil {
		t.Fatalf("sidecar missing: %v", err)
	}
	var meta map[string]string
	if err := json.Unmarshal(sb, &meta); err != nil {
		t.Fatal(err)
	}
	if meta["name"] != "wifi.mobileconfig" || meta["reason"] != "overwritten-by-newer" {
		t.Errorf("sidecar name/reason = %q/%q", meta["name"], meta["reason"])
	}
	if meta["abm_id"] != "id-1" || meta["hash"] != "abc" {
		t.Errorf("sidecar dropped caller meta: %v", meta)
	}
	if meta["archivedAt"] != "2026-07-04T12:00:00Z" {
		t.Errorf("archivedAt = %q, want 2026-07-04T12:00:00Z", meta["archivedAt"])
	}
	if meta["file"] != filepath.Base(path) {
		t.Errorf("sidecar file = %q, want %q", meta["file"], filepath.Base(path))
	}
}

// TestWriteReservedKeysNotOverridden ensures caller meta can't clobber the core
// audit fields (name/reason/archivedAt/file).
func TestWriteReservedKeysNotOverridden(t *testing.T) {
	root := t.TempDir()
	now := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	path, err := Write(root, "a", "pruned", []byte("x"),
		map[string]string{"name": "SPOOFED", "reason": "SPOOFED"}, now)
	if err != nil {
		t.Fatal(err)
	}
	sb, _ := os.ReadFile(strings.TrimSuffix(path, ".mobileconfig") + ".json")
	var meta map[string]string
	_ = json.Unmarshal(sb, &meta)
	if meta["name"] != "a" || meta["reason"] != "pruned" {
		t.Errorf("reserved keys were overridden by caller meta: %v", meta)
	}
}

// TestWriteSanitizesNastyNames ensures a name with path separators cannot escape
// the archive root.
func TestWriteSanitizesNastyNames(t *testing.T) {
	root := t.TempDir()
	now := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	path, err := Write(root, "../../etc/passwd", "replaced", []byte("x"), nil, now)
	if err != nil {
		t.Fatal(err)
	}
	rootAbs, _ := filepath.Abs(root)
	pathAbs, _ := filepath.Abs(path)
	if !strings.HasPrefix(pathAbs, rootAbs+string(filepath.Separator)) {
		t.Fatalf("archive escaped its root: %q not under %q", pathAbs, rootAbs)
	}
}

// TestWriteNoCollisionSameSecond ensures two archives that land on the same subdir,
// second, and reason do not overwrite each other — the audit record must survive.
func TestWriteNoCollisionSameSecond(t *testing.T) {
	root := t.TempDir()
	now := time.Date(2026, 7, 4, 12, 0, 0, 0, time.UTC)
	p1, err := Write(root, "wifi.mobileconfig", "pruned", []byte("FIRST"), nil, now)
	if err != nil {
		t.Fatal(err)
	}
	p2, err := Write(root, "wifi.mobileconfig", "pruned", []byte("SECOND"), nil, now)
	if err != nil {
		t.Fatal(err)
	}
	if p1 == p2 {
		t.Fatalf("same-second archives collided on one path: %q", p1)
	}
	if b, _ := os.ReadFile(p1); string(b) != "FIRST" {
		t.Errorf("first archive was overwritten: got %q, want FIRST", b)
	}
	if b, _ := os.ReadFile(p2); string(b) != "SECOND" {
		t.Errorf("second archive content = %q, want SECOND", b)
	}
}

// TestWriteReservedWindowsName ensures a config whose name sanitizes to a Windows
// reserved device name (e.g. NUL) can still be archived (subdir gets a suffix).
func TestWriteReservedWindowsName(t *testing.T) {
	root := t.TempDir()
	now := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	path, err := Write(root, "NUL", "replaced", []byte("x"), nil, now)
	if err != nil {
		t.Fatalf("archiving a config named NUL must not fail: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("archive not written for reserved name: %v", err)
	}
}
