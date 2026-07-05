// Package archive is the audit safety net for bidirectional sync. Before abctl
// overwrites or deletes any live configuration, it downloads the current live
// version and files it here — so every live state that was ever replaced leaves
// a permanent, greppable record. Git already versions git-side edits; this
// captures the *console* side that a conflict-loss or prune would otherwise erase.
package archive

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// tsLayout is a filesystem-safe UTC timestamp (no colons — Windows-safe) with a
// trailing Z, e.g. 20260704T120000Z.
const tsLayout = "20060102T150405Z"

// Write files a pre-overwrite live profile under
//
//	<root>/<name>/<UTC-timestamp>--<reason>.mobileconfig
//
// alongside a matching .json sidecar recording the metadata (name, reason,
// archivedAt, plus any extra fields in meta). It returns the path of the written
// .mobileconfig. name and reason are sanitized for the filesystem; the on-disk
// name stays human-readable. now is injected for deterministic testing.
func Write(root, name, reason string, xml []byte, meta map[string]string, now time.Time) (string, error) {
	safeName := safe(name)
	if safeName == "" {
		safeName = "unnamed"
	}
	safeReason := safe(reason)
	if safeReason == "" {
		safeReason = "replaced"
	}
	dir := filepath.Join(root, safeName)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	// The stem is <UTC-ts>--<reason>; it omits the config name, so two different
	// live names that sanitize to the same subdir and are archived in the same
	// second with the same reason would collide. Probe for a free stem and add a
	// numeric suffix on collision so an archived version is never silently lost.
	tsStem := now.UTC().Format(tsLayout) + "--" + safeReason
	stem := tsStem
	for i := 1; ; i++ {
		if _, err := os.Stat(filepath.Join(dir, stem+".mobileconfig")); os.IsNotExist(err) {
			break
		}
		stem = fmt.Sprintf("%s-%d", tsStem, i)
	}
	profilePath := filepath.Join(dir, stem+".mobileconfig")
	if err := os.WriteFile(profilePath, xml, 0o644); err != nil {
		return "", err
	}

	sidecar := map[string]string{
		"name":       name,
		"reason":     reason,
		"archivedAt": now.UTC().Format(time.RFC3339),
		"file":       filepath.Base(profilePath),
	}
	for k, v := range meta { // caller-supplied fields (abm_id, hash, updatedDateTime …); never override the core keys
		if _, reserved := sidecar[k]; !reserved {
			sidecar[k] = v
		}
	}
	sb, err := json.MarshalIndent(sidecar, "", "  ")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(dir, stem+".json"), append(sb, '\n'), 0o644); err != nil {
		return "", err
	}
	return profilePath, nil
}

// safe reduces s to a filesystem-safe component: path separators and other
// awkward characters become '-', with the ".mobileconfig" suffix (which config
// names carry) trimmed so the archive subdir reads as the bare config name. A
// result that collides with a Windows reserved device name (CON, NUL, COM1 …) is
// suffixed with '_' so os.MkdirAll can't fail on it.
func safe(s string) string {
	s = strings.TrimSuffix(s, ".mobileconfig")
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_', r == '.':
			b.WriteRune(r)
		case r == ' ':
			b.WriteRune('-')
		default:
			b.WriteRune('-')
		}
	}
	out := strings.Trim(b.String(), "-.")
	if isReservedWindowsName(out) {
		out += "_"
	}
	return out
}

// isReservedWindowsName reports whether s (case-insensitive) is a Windows reserved
// device name, which cannot be used as a file or directory name on Windows.
func isReservedWindowsName(s string) bool {
	u := strings.ToUpper(s)
	switch u {
	case "CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$":
		return true
	}
	if len(u) == 4 && (strings.HasPrefix(u, "COM") || strings.HasPrefix(u, "LPT")) && u[3] >= '1' && u[3] <= '9' {
		return true
	}
	return false
}
