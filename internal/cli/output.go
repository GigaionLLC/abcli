package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"gopkg.in/yaml.v3"
)

// flagOutput is the global output format: "table" (default), "json", or "yaml".
var flagOutput = "table"

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
// or the structured value as JSON/YAML.
func render(format string, data any, headers []string, rows [][]string) error {
	switch format {
	case "json":
		return printJSON(data)
	case "yaml":
		return printYAML(data)
	default:
		printTable(headers, rows)
		return nil
	}
}

func validOutput(f string) error {
	switch f {
	case "table", "json", "yaml":
		return nil
	}
	return fmt.Errorf("invalid --output %q (want table|json|yaml)", f)
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

func printTable(headers []string, rows [][]string) {
	tw := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	_, _ = fmt.Fprintln(tw, strings.Join(headers, "\t"))
	for _, r := range rows {
		_, _ = fmt.Fprintln(tw, strings.Join(r, "\t"))
	}
	_ = tw.Flush()
}
