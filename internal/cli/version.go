package cli

import (
	"fmt"
	"runtime"
	"runtime/debug"
	"strings"

	"github.com/spf13/cobra"
)

// capabilities lists the machine-contract features THIS abctl build supports, so a GUI
// or script can enable/disable UI and enforce a minimum without sniffing individual
// flags. Append-only tokens (never rename/remove one — a client keys off the string).
var capabilities = []string{
	"auth-whoami-json",      // P1: auth whoami --json
	"write-json",            // P4: create/replace/delete/attach/detach --json
	"context-json",          // P5: context get -o json (snake_case)
	"plan-json",             // P7: diff/sync honor -o json|yaml
	"list-empty-array",      // N3: empty lists serialize as []
	"version-json",          // P2: this command
	"blueprint-counts-json", // P6: get blueprint --json member counts
	// VPP content-token capabilities are intentionally NOT advertised: the `vpp` path is
	// disabled by default (no content token under Apple Business Essentials). They are
	// re-added when ABCTL_ENABLE_VPP-gated support is re-enabled for 3rd-party-MDM orgs.
}

// versionInfo is the machine-readable build identity + capability set (P2). A GUI reads
// it to detect the embedded binary, enforce a minimum version, and gate features.
type versionInfo struct {
	Version      string   `json:"version"`
	Commit       string   `json:"commit,omitempty"`
	BuildTime    string   `json:"buildTime,omitempty"`
	GoVersion    string   `json:"goVersion"`
	Capabilities []string `json:"capabilities"`
}

func newVersionCmd() *cobra.Command {
	var asJSON bool
	c := &cobra.Command{
		Use:   "version",
		Short: "Print the abctl version + capabilities (--json for machine output)",
		Args:  cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			vi := buildVersionInfo()
			if asJSON || flagOutput != "table" {
				return render(outFmt(asJSON), vi, nil, nil)
			}
			fmt.Printf("abctl %s\n", vi.Version)
			if vi.Commit != "" {
				fmt.Printf("  commit       %s\n", vi.Commit)
			}
			if vi.BuildTime != "" {
				fmt.Printf("  built        %s\n", vi.BuildTime)
			}
			fmt.Printf("  go           %s\n", vi.GoVersion)
			fmt.Printf("  capabilities %s\n", strings.Join(vi.Capabilities, ", "))
			return nil
		},
	}
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	return c
}

// buildVersionInfo assembles the version payload. commit/buildTime come from the Go
// build's embedded VCS stamp (present for `go build` from a git checkout) — no ldflags
// needed beyond the existing version injection.
func buildVersionInfo() versionInfo {
	vi := versionInfo{Version: version, GoVersion: runtime.Version(), Capabilities: capabilities}
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, s := range bi.Settings {
			switch s.Key {
			case "vcs.revision":
				vi.Commit = s.Value
			case "vcs.time":
				vi.BuildTime = s.Value
			}
		}
	}
	return vi
}
