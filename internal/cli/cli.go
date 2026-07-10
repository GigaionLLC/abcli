// Package cli is the abctl command surface, built on Cobra.
package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/GigaionLLC/abcli/internal/ab"
	"github.com/GigaionLLC/abcli/internal/config"
)

// version is injected at build time via -ldflags "-X .../internal/cli.version=...".
var version = "dev"

// flagContext is the global --context selector (empty → $ABCTL_CONTEXT, then the
// active context in ~/.abctl/contexts.yaml, then .env / process env).
var flagContext string

// ExitError lets a command request a specific process exit code (e.g. 3 = changes pending).
type ExitError struct{ Code int }

func (e ExitError) Error() string { return fmt.Sprintf("exit status %d", e.Code) }

// Execute runs the root command and returns its error (ExitError carries a code).
func Execute() error { return newRoot().Execute() }

func newRoot() *cobra.Command {
	root := &cobra.Command{
		Use:   "abctl",
		Short: "CLI for the Apple Business API — GitOps sync + imperative config management",
		Long: "abctl manages Apple Business built-in-MDM CUSTOM_SETTING profiles and Blueprints:\n" +
			"a git-declarative sync engine (seed/diff/sync) plus imperative commands\n" +
			"(get/create/edit/delete/apply). Read-only by default; every write is gated.",
		Version:       version,
		SilenceErrors: true, // main prints errors + maps ExitError to an exit code
		SilenceUsage:  true,
		PersistentPreRunE: func(cmd *cobra.Command, _ []string) error {
			return checkOutputFlag(cmd)
		},
	}
	root.PersistentFlags().StringVarP(&flagOutput, "output", "o", "table", "output format: table|json|yaml|csv (csv: list commands only)")
	root.PersistentFlags().StringVar(&flagContext, "context", "", "connection context (see `abctl context`); else $ABCTL_CONTEXT / .env")
	root.AddCommand(
		newAuthCmd(), newGetCmd(), newContextCmd(), newVersionCmd(),
		newSeedCmd(), newValidateCmd(), newDiffCmd(), newSyncCmd(),
		newCreateCmd(), newReplaceCmd(), newEditCmd(), newDeleteCmd(),
		newApplyCmd(), newPullCmd(), newAttachCmd(), newDetachCmd(), newStatusCmd(),
		newAssignCmd(), newUnassignCmd(), newAPICmd(), newVPPCmd(),
	)
	return root
}

func mustClient() (*ab.Client, *config.Config, error) {
	cfg, err := config.Resolve(flagContext)
	if err != nil {
		return nil, nil, err
	}
	return ab.NewClient(cfg), cfg, nil
}
