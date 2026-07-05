// Package cli is the abctl command surface, built on Cobra.
package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/config"
)

// version is injected at build time via -ldflags "-X .../internal/cli.version=...".
var version = "dev"

// ExitError lets a command request a specific process exit code (e.g. 3 = changes pending).
type ExitError struct{ Code int }

func (e ExitError) Error() string { return fmt.Sprintf("exit status %d", e.Code) }

// Execute runs the root command and returns its error (ExitError carries a code).
func Execute() error { return newRoot().Execute() }

func newRoot() *cobra.Command {
	root := &cobra.Command{
		Use:   "abctl",
		Short: "GitOps CLI for the Apple Business API (Configurations + Blueprints)",
		Long: "abctl syncs Apple Business built-in-MDM CUSTOM_SETTING profiles and Blueprints\n" +
			"against a git-declarative desired state. Read-only by default; writes are gated.",
		Version:       version,
		SilenceErrors: true, // main prints errors + maps ExitError to an exit code
		SilenceUsage:  true,
	}
	root.AddCommand(
		newAuthCmd(), newGetCmd(),
		newSeedCmd(), newValidateCmd(), newDiffCmd(), newSyncCmd(),
		newAPICmd(),
	)
	return root
}

func mustClient() (*ab.Client, *config.Config, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, nil, err
	}
	return ab.NewClient(cfg), cfg, nil
}

func printJSON(v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	return nil
}

func printTable(headers []string, rows [][]string) {
	tw := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	_, _ = fmt.Fprintln(tw, strings.Join(headers, "\t"))
	for _, r := range rows {
		_, _ = fmt.Fprintln(tw, strings.Join(r, "\t"))
	}
	_ = tw.Flush()
}
