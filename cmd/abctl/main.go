// Command abctl is a GitOps CLI for the Apple Business API (Configurations +
// Blueprints). Read-only by default; writes are gated. See docs/design-abctl.md.
package main

import (
	"errors"
	"fmt"
	"os"

	"github.com/GigaionLLC/abcli/internal/cli"
)

func main() {
	err := cli.Execute()
	if err == nil {
		return
	}
	var ec cli.ExitError
	if errors.As(err, &ec) {
		os.Exit(ec.Code)
	}
	fmt.Fprintln(os.Stderr, "Error:", err)
	os.Exit(1)
}
