package cli

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/GigaionLLC/abcli/internal/gdmf"
)

func newOSReleasesCmd() *cobra.Command {
	var platform, catalog, device string
	var includeExpired, asJSON bool
	c := &cobra.Command{Use: "os-releases", Short: "List Apple software releases (GDMF; read-only)", Args: cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			return getOSReleases(platform, catalog, device, includeExpired, asJSON)
		}}
	c.Flags().StringVar(&platform, "platform", "", "platform (for example macOS or iOS)")
	c.Flags().StringVar(&catalog, "catalog", "", "catalog: managed|public|rsr")
	c.Flags().StringVar(&device, "device", "", "supported device product type (for example MacBookPro18,3)")
	c.Flags().BoolVar(&includeExpired, "include-expired", false, "include releases whose signing expiration has passed")
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	return csvCapable(c)
}

func getOSReleases(platform, catalog, device string, includeExpired, asJSON bool) error {
	url := os.Getenv("AB_GDMF_URL")
	cat, err := gdmf.New(url).Fetch()
	if err != nil {
		return err
	}
	entries := cat.Entries(time.Now())
	out := entries[:0:0]
	for _, e := range entries {
		if platform != "" && !strings.EqualFold(e.Platform, platform) {
			continue
		}
		if catalog != "" && !strings.EqualFold(e.Catalog, catalog) {
			continue
		}
		if !includeExpired && e.Expired {
			continue
		}
		if device != "" && !containsFold(e.SupportedDevices, device) {
			continue
		}
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].PostingDate != out[j].PostingDate {
			return out[i].PostingDate > out[j].PostingDate
		}
		if out[i].Platform != out[j].Platform {
			return out[i].Platform < out[j].Platform
		}
		return out[i].Build < out[j].Build
	})
	cols := []string{"PLATFORM", "VERSION", "BUILD", "CATALOG", "POSTED", "EXPIRES", "DEVICES"}
	rows := make([][]string, 0, len(out))
	for _, e := range out {
		rows = append(rows, []string{e.Platform, e.ProductVersion, e.Build, e.Catalog, e.PostingDate,
			e.ExpirationDate, fmt.Sprintf("%d", len(e.SupportedDevices))})
	}
	if asJSON || flagOutput != "table" {
		return render(outFmt(asJSON), asList(out), cols, rows)
	}
	printTable(cols, rows)
	fmt.Fprintf(os.Stderr, "%d Apple software release(s)\n", len(out))
	return nil
}

func containsFold(items []string, want string) bool {
	for _, item := range items {
		if strings.EqualFold(item, want) {
			return true
		}
	}
	return false
}
