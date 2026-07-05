package cli

import (
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"
)

func newAuthCmd() *cobra.Command {
	auth := &cobra.Command{Use: "auth", Short: "Authentication (ES256 client-assertion; the JWT omits kid)"}

	whoami := &cobra.Command{
		Use:   "whoami",
		Short: "Verify auth and print a tenant summary",
		Args:  cobra.NoArgs,
		RunE:  func(*cobra.Command, []string) error { return authWhoami() },
	}

	var raw bool
	token := &cobra.Command{
		Use:   "token",
		Short: "Show the cached bearer expiry (--raw prints the token)",
		Args:  cobra.NoArgs,
		RunE:  func(*cobra.Command, []string) error { return authToken(raw) },
	}
	token.Flags().BoolVar(&raw, "raw", false, "print the bearer token itself")

	auth.AddCommand(whoami, token)
	return auth
}

func authWhoami() error {
	c, cfg, err := mustClient()
	if err != nil {
		return err
	}
	if _, err := c.TokenSource().Token(); err != nil {
		return fmt.Errorf("auth failed: %w", err)
	}
	bps, err := c.ListBlueprints()
	if err != nil {
		return fmt.Errorf("token OK but API call failed: %w", err)
	}
	cfgs, err := c.ListConfigurations()
	if err != nil {
		return err
	}
	exp := c.TokenSource().Expiry()
	fmt.Println("Authenticated ✓")
	fmt.Printf("  client_id      %s\n", cfg.ClientID)
	fmt.Printf("  api_base       %s\n", cfg.APIBase)
	fmt.Printf("  token_expires  %s (%s)\n", exp.Format(time.RFC3339), time.Until(exp).Round(time.Second))
	fmt.Printf("  configurations %d\n", len(cfgs))
	fmt.Printf("  blueprints     %d\n", len(bps))
	return nil
}

func authToken(raw bool) error {
	c, _, err := mustClient()
	if err != nil {
		return err
	}
	tok, err := c.TokenSource().Token()
	if err != nil {
		return err
	}
	if raw {
		fmt.Println(tok)
		return nil
	}
	exp := c.TokenSource().Expiry()
	fmt.Printf("bearer cached; expires %s (%s)\n", exp.Format(time.RFC3339), time.Until(exp).Round(time.Second))
	fmt.Fprintln(os.Stderr, "(use --raw to print the token itself)")
	return nil
}
