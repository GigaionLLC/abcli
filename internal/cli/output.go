package cli

import (
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

// flagOutput is the global output format: "table" (default), "json", "yaml", or
// "csv" (LIST commands only — see csvCapable/checkOutputFlag).
var flagOutput = "table"

// csvListOnlyMsg is the ONE wording for the csv-is-list-only gate — checkOutputFlag
// rejects it up front and render's guard is the belt-and-suspenders path for the
// same condition, so the two messages must never drift apart.
const csvListOnlyMsg = "-o csv is only supported by list commands (e.g. `abctl get devices -o csv`)"

// outFmt resolves the effective format for a command, letting a per-command --json
// shorthand (kept for back-compat) win over the global -o/--output.
func outFmt(jsonShorthand bool) string {
	if jsonShorthand {
		return "json"
	}
	return flagOutput
}

// planFormat resolves the output format for the diff/sync PLAN: the per-command --json
// shorthand OR the global -o json/-o yaml, else "" (the human tables). Without this,
// `diff -o json` / `sync -o yaml` would silently print a table (the -o flag was ignored).
func planFormat(jsonShorthand bool) string {
	if jsonShorthand || flagOutput == "json" {
		return "json"
	}
	if flagOutput == "yaml" {
		return "yaml"
	}
	return ""
}

// asList returns s as a non-nil slice, so an empty result serializes as `[]` (not the
// `null` a nil slice marshals to) — GUIs and `jq` pipelines then never special-case null.
func asList[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

// render prints data in the resolved format: a table (headers+rows) by default,
// the table columns as RFC-4180 CSV, or the structured value as JSON/YAML.
func render(format string, data any, headers []string, rows [][]string) error {
	switch format {
	case "json":
		return printJSON(data)
	case "yaml":
		return printYAML(data)
	case "csv":
		if len(headers) == 0 { // no table columns to emit — a single-resource/write command
			return errors.New(csvListOnlyMsg)
		}
		return printCSV(headers, rows)
	default:
		printTable(headers, rows)
		return nil
	}
}

func validOutput(f string) error {
	switch f {
	case "table", "json", "yaml", "csv":
		return nil
	}
	return fmt.Errorf("invalid --output %q (want table|json|yaml|csv)", f)
}

// checkOutputFlag validates the global -o value and rejects csv for any command
// not marked csvCapable — csv only makes sense where the output is a flat table.
func checkOutputFlag(cmd *cobra.Command) error {
	if err := validOutput(flagOutput); err != nil {
		return err
	}
	if flagOutput == "csv" && cmd.Annotations["output-csv"] != "true" {
		return errors.New(csvListOnlyMsg)
	}
	return nil
}

// csvCapable marks a LIST command as supporting -o csv (checkOutputFlag rejects
// csv everywhere else).
func csvCapable(c *cobra.Command) *cobra.Command {
	if c.Annotations == nil {
		c.Annotations = map[string]string{}
	}
	c.Annotations["output-csv"] = "true"
	return c
}

func printJSON(v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	return nil
}

// printYAML renders v as YAML by round-tripping through JSON first, so json tags
// and json.RawMessage fields (e.g. ab.Resource.Attributes) serialize cleanly.
func printYAML(v any) error {
	j, err := json.Marshal(v)
	if err != nil {
		return err
	}
	var m any
	if err := json.Unmarshal(j, &m); err != nil {
		return err
	}
	b, err := yaml.Marshal(m)
	if err != nil {
		return err
	}
	fmt.Print(string(b))
	return nil
}

// printCSV writes the table columns as CSV on stdout (header row first).
// encoding/csv applies RFC-4180 quoting (commas, quotes, newlines); row values
// are additionally neutralized against spreadsheet formula injection.
func printCSV(headers []string, rows [][]string) error {
	w := csv.NewWriter(os.Stdout)
	if err := w.Write(headers); err != nil {
		return err
	}
	safe := make([]string, 0, len(headers))
	for _, r := range rows {
		safe = safe[:0]
		for _, f := range r {
			safe = append(safe, csvSanitize(f))
		}
		if err := w.Write(safe); err != nil {
			return err
		}
	}
	w.Flush()
	return w.Error()
}

// csvSanitize neutralizes spreadsheet formula injection: tenant-controlled
// values (config/app/package/group names, audit actors, …) starting with '=',
// '+', '-', '@', tab, or CR are interpreted as formulas when the exported CSV
// is opened in Excel/LibreOffice/Google Sheets, so such cells get a leading
// single quote — the standard mitigation, rendered as a literal by spreadsheets.
func csvSanitize(field string) string {
	if field == "" {
		return field
	}
	switch field[0] {
	case '=', '+', '-', '@', '\t', '\r':
		return "'" + field
	}
	return field
}

func printTable(headers []string, rows [][]string) {
	tw := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	_, _ = fmt.Fprintln(tw, strings.Join(headers, "\t"))
	for _, r := range rows {
		_, _ = fmt.Fprintln(tw, strings.Join(r, "\t"))
	}
	_ = tw.Flush()
}
