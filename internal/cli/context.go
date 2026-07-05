package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/GigaionLLC/abcli/internal/config"
)

func newContextCmd() *cobra.Command {
	c := &cobra.Command{
		Use:     "context",
		Aliases: []string{"ctx"},
		Short:   "Manage connection contexts (kubeconfig-style; ~/.abctl/contexts.yaml)",
		Long: "A context is a named Apple Business connection (client id + key + endpoints).\n" +
			"Switch tenants with `abctl context use <name>` or the global --context/$ABCTL_CONTEXT.\n" +
			"With no context selected, abctl falls back to .env / the AB_* process environment.",
	}
	c.AddCommand(newCtxSetCmd(), newCtxUseCmd(), newCtxGetCmd(), newCtxListCmd(), newCtxCurrentCmd(), newCtxDeleteCmd())
	return c
}

func newCtxSetCmd() *cobra.Command {
	var ctx config.Context
	var use bool
	cmd := &cobra.Command{
		Use:   "set <name>",
		Short: "Create or update a context",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error {
			store, err := config.LoadContexts()
			if err != nil {
				return err
			}
			existing := store.Contexts[a[0]]
			if ctx.ClientID != "" {
				existing.ClientID = ctx.ClientID
			}
			if ctx.KeyPath != "" {
				existing.KeyPath = ctx.KeyPath
			}
			if ctx.APIBase != "" {
				existing.APIBase = ctx.APIBase
			}
			if ctx.Scope != "" {
				existing.Scope = ctx.Scope
			}
			if ctx.TokenURL != "" {
				existing.TokenURL = ctx.TokenURL
			}
			if ctx.TokenAud != "" {
				existing.TokenAud = ctx.TokenAud
			}
			if existing.ClientID == "" || existing.KeyPath == "" {
				return fmt.Errorf("context %q needs at least --client-id and --key", a[0])
			}
			store.Contexts[a[0]] = existing
			if use || store.Current == "" {
				store.Current = a[0]
			}
			if err := store.Save(); err != nil {
				return err
			}
			fmt.Fprintf(os.Stderr, "context %q saved to %s%s\n", a[0], config.ContextsPath(),
				map[bool]string{true: " (now current)", false: ""}[store.Current == a[0]])
			return nil
		},
	}
	cmd.Flags().StringVar(&ctx.ClientID, "client-id", "", "AB_CLIENT_ID (BUSINESSAPI.<uuid>)")
	cmd.Flags().StringVar(&ctx.KeyPath, "key", "", "path to the EC private key (.pem)")
	cmd.Flags().StringVar(&ctx.APIBase, "api-base", "", "override API base URL")
	cmd.Flags().StringVar(&ctx.Scope, "scope", "", "override OAuth scope")
	cmd.Flags().StringVar(&ctx.TokenURL, "token-url", "", "override token URL")
	cmd.Flags().StringVar(&ctx.TokenAud, "token-aud", "", "override token audience")
	cmd.Flags().BoolVar(&use, "use", false, "make this the current context")
	return cmd
}

func newCtxUseCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "use <name>",
		Short: "Set the current context",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error {
			store, err := config.LoadContexts()
			if err != nil {
				return err
			}
			if _, ok := store.Contexts[a[0]]; !ok {
				return fmt.Errorf("context %q not found (see `abctl context list`)", a[0])
			}
			store.Current = a[0]
			if err := store.Save(); err != nil {
				return err
			}
			fmt.Fprintf(os.Stderr, "current context → %q\n", a[0])
			return nil
		},
	}
}

func newCtxGetCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "get [<name>]",
		Short: "Show a context (default: the current one)",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(_ *cobra.Command, a []string) error {
			store, err := config.LoadContexts()
			if err != nil {
				return err
			}
			name := store.Current
			if len(a) == 1 {
				name = a[0]
			}
			ctx, ok := store.Contexts[name]
			if !ok {
				return fmt.Errorf("context %q not found", name)
			}
			return render(outFmt(false), map[string]any{"name": name, "context": ctx},
				[]string{"FIELD", "VALUE"}, [][]string{
					{"name", name}, {"client_id", ctx.ClientID}, {"key", ctx.KeyPath},
					{"api_base", ctx.APIBase}, {"scope", ctx.Scope},
				})
		},
	}
}

func newCtxListCmd() *cobra.Command {
	return &cobra.Command{
		Use:     "list",
		Aliases: []string{"ls"},
		Short:   "List contexts",
		Args:    cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			store, err := config.LoadContexts()
			if err != nil {
				return err
			}
			names := store.Names()
			if flagOutput != "table" {
				return render(flagOutput, map[string]any{"current": store.Current, "contexts": names}, nil, nil)
			}
			if len(names) == 0 {
				fmt.Println("no contexts — `abctl context set <name> --client-id … --key …`")
				return nil
			}
			rows := make([][]string, 0, len(names))
			for _, n := range names {
				marker := ""
				if n == store.Current {
					marker = "*"
				}
				rows = append(rows, []string{marker, n, store.Contexts[n].ClientID})
			}
			printTable([]string{"CURRENT", "NAME", "CLIENT_ID"}, rows)
			return nil
		},
	}
}

func newCtxCurrentCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "current",
		Short: "Print the current context name",
		Args:  cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			store, err := config.LoadContexts()
			if err != nil {
				return err
			}
			if store.Current == "" {
				fmt.Fprintln(os.Stderr, "no current context (using .env / environment)")
				return nil
			}
			fmt.Println(store.Current)
			return nil
		},
	}
}

func newCtxDeleteCmd() *cobra.Command {
	return &cobra.Command{
		Use:     "delete <name>",
		Aliases: []string{"rm"},
		Short:   "Delete a context",
		Args:    cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, a []string) error {
			store, err := config.LoadContexts()
			if err != nil {
				return err
			}
			if _, ok := store.Contexts[a[0]]; !ok {
				return fmt.Errorf("context %q not found", a[0])
			}
			delete(store.Contexts, a[0])
			if store.Current == a[0] {
				store.Current = ""
			}
			if err := store.Save(); err != nil {
				return err
			}
			fmt.Fprintf(os.Stderr, "context %q deleted\n", a[0])
			return nil
		},
	}
}
