package cli

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/spf13/cobra"

	"github.com/GigaionLLC/abcli/internal/config"
	"github.com/GigaionLLC/abcli/internal/gitops"
)

const (
	// profileSizeCap is the Apple Business per-configuration limit: a profile at or
	// above it is rejected on upload, so it is a hard local failure too.
	profileSizeCap = 1 << 20
	// profileSizeWarn is the "getting close to the cap" line (half of it).
	profileSizeWarn = 512 << 10
	// validatorOutputCap bounds what an external validator can push into the machine
	// report — a chatty linter must not produce an unbounded JSON payload for a GUI.
	validatorOutputCap = 16 << 10
	// maxPlistDepth stops the recursive plist walker on a pathologically nested file
	// instead of exhausting the stack.
	maxPlistDepth = 64
)

// validationIssue is one thing wrong with a profile: a stable code a GUI/script
// can branch on plus one plain sentence for a human.
type validationIssue struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// profileReport is the verdict for one lib/ file. Warnings never fail it — only
// errors do, so `ok` is exactly "this profile can be pushed to Apple Business".
type profileReport struct {
	Name         string            `json:"name"`
	Path         string            `json:"path"`
	Bytes        int               `json:"bytes"`
	OK           bool              `json:"ok"`
	Identifier   string            `json:"identifier,omitempty"`
	DisplayName  string            `json:"displayName,omitempty"`
	PayloadTypes []string          `json:"payloadTypes"`
	Errors       []validationIssue `json:"errors"`
	Warnings     []validationIssue `json:"warnings"`
}

// treeIssue is a problem with the tree rather than with one profile — a blueprint
// referencing a configuration that is not in lib/, an unparseable manifest, or a
// stray file sync will ignore.
type treeIssue struct {
	Level   string `json:"level"` // "error" | "warning"
	Scope   string `json:"scope"` // "blueprints" | "lib"
	Target  string `json:"target,omitempty"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

// validationReport is the machine contract for `validate --json`: everything the
// GUI's pre-flight sheet renders, and the single `ok` the exit code keys off.
type validationReport struct {
	OK                bool            `json:"ok"`
	LibDir            string          `json:"libDir"`
	Checked           int             `json:"checked"`
	Passed            int             `json:"passed"`
	Failed            int             `json:"failed"`
	WarningCount      int             `json:"warnings"`
	Profiles          []profileReport `json:"profiles"`
	TreeIssues        []treeIssue     `json:"treeIssues"`
	Validator         string          `json:"validator"` // "built-in" | "external"
	ValidatorCommand  string          `json:"validatorCommand,omitempty"`
	ValidatorExitCode *int            `json:"validatorExitCode,omitempty"`
	ValidatorOutput   string          `json:"validatorOutput,omitempty"`
}

func newValidateCmd() *cobra.Command {
	var asJSON bool
	c := &cobra.Command{
		Use:   "validate",
		Short: "Check the local gitops/ profiles + blueprint references (no credentials, no tenant calls)",
		Long: "validate is the pre-sync check, and it reads local files only: no credentials,\n" +
			"no Apple Business calls, works offline. Every lib/ profile is parsed as an XML\n" +
			"plist and checked for the Configuration/PayloadContent structure, a\n" +
			"PayloadIdentifier, a top-level PayloadVersion of exactly 1 (Apple accepts an\n" +
			"upload that violates it and then silently never stores it), the 1 MiB Apple\n" +
			"Business size cap, and an identifier shared with another profile; every\n" +
			"blueprint manifest is checked for configurations it references that are missing\n" +
			"from lib/ — the mistake that makes a sync attach nothing. Exit 1 means something\n" +
			"failed; warnings never fail the run.\n" +
			"$ABCTL_VALIDATOR runs your own linter over lib/ instead (on --json its output\n" +
			"joins the report), and --json / -o json|yaml emits the machine report on stdout\n" +
			"even when the exit code is 1.",
		Args: cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error { return runValidate(asJSON) },
	}
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	return c
}

// runValidate is deliberately credential-free (config.TreeDir, never config.Load):
// verifying local files must work offline, in CI, and before an operator has ever
// configured a tenant. The exit-code contract is unchanged — 1 when anything
// failed — on BOTH the human and the machine path, and the JSON report is printed
// on stdout BEFORE that non-zero exit so a GUI can decode it anyway.
func runValidate(asJSON bool) error {
	t := gitops.NewTree(config.TreeDir(flagContext))
	format := outFmt(asJSON)
	validator := resolveValidator()

	if format != "json" && format != "yaml" {
		if len(validator) > 0 {
			// Unchanged human behavior: the external validator owns stdout, stderr,
			// and the exit code (an empty lib/ never invoked it and still doesn't).
			files, _ := loadLibProfiles(t)
			if len(files) == 0 {
				fmt.Println("no profiles in", rel(t.LibDir), "(run `abctl seed` first)")
				return nil
			}
			return runExternalValidator(validator, t.LibDir)
		}
		rep := buildValidationReport(t)
		printValidationReport(rep)
		if !rep.OK {
			return ExitError{Code: 1}
		}
		return nil
	}

	rep := buildValidationReport(t)
	if len(validator) > 0 {
		// The machine report carries BOTH passes, so a GUI can show the structural
		// rows and the linter's raw output side by side.
		foldExternalValidator(&rep, validator, t.LibDir)
	}
	if err := render(format, rep, nil, nil); err != nil {
		return err
	}
	if !rep.OK {
		return ExitError{Code: 1}
	}
	return nil
}

// buildValidationReport runs the built-in pass over the whole tree: every lib/
// profile, then the cross-file checks (duplicate identifiers) and the tree-level
// checks (blueprint references, stray files) that no single file can catch.
func buildValidationReport(t *gitops.Tree) validationReport {
	rep := validationReport{
		LibDir:     rel(t.LibDir),
		Validator:  "built-in",
		Profiles:   []profileReport{},
		TreeIssues: []treeIssue{},
	}
	files, ignored := loadLibProfiles(t)
	for _, f := range files {
		rep.Profiles = append(rep.Profiles, checkProfile(t.LibDir, f))
	}
	flagDuplicateIdentifiers(rep.Profiles)
	if len(files) == 0 {
		rep.TreeIssues = append(rep.TreeIssues, treeIssue{
			Level: "warning", Scope: "lib", Code: "empty-lib",
			Message: fmt.Sprintf("no profiles in %s (run `abctl seed` first)", rep.LibDir),
		})
	}
	for _, name := range ignored {
		rep.TreeIssues = append(rep.TreeIssues, treeIssue{
			Level: "warning", Scope: "lib", Target: name, Code: "ignored-file",
			Message: fmt.Sprintf("%q is ignored by sync (not a .mobileconfig)", name),
		})
	}
	rep.TreeIssues = append(rep.TreeIssues, checkBlueprintRefs(t, files)...)
	rep.finalize()
	return rep
}

// finalize rolls up the counters and the single `ok` verdict: no failing profile,
// no error-level tree issue. (An external validator can only turn it off later.)
func (r *validationReport) finalize() {
	r.Checked = len(r.Profiles)
	r.Passed, r.Failed, r.WarningCount = 0, 0, 0
	for _, p := range r.Profiles {
		if p.OK {
			r.Passed++
		} else {
			r.Failed++
		}
		r.WarningCount += len(p.Warnings)
	}
	treeErrors := 0
	for _, ti := range r.TreeIssues {
		if ti.Level == "error" {
			treeErrors++
		} else {
			r.WarningCount++
		}
	}
	r.OK = r.Failed == 0 && treeErrors == 0
}

// libFile is one candidate profile in lib/: its bytes, or the error that stopped
// us from reading it.
type libFile struct {
	name string
	data []byte
	err  error
}

// loadLibProfiles reads lib/ exactly the way sync does — gitops.Tree.LoadDesired
// owns the "what counts as a profile" rule, so validate and sync can never
// disagree about which files ship — and additionally returns the names lib/ holds
// that sync silently ignores. LoadDesired fails the whole directory on a single
// unreadable file, so that case degrades to reading each candidate on its own:
// the failure then lands on the offending file as `unreadable` instead of killing
// a run whose other rows are still worth having.
func loadLibProfiles(t *gitops.Tree) (files []libFile, ignored []string) {
	entries, err := os.ReadDir(t.LibDir)
	if err != nil {
		return nil, nil // no lib/ yet — the empty-lib tree warning says so
	}
	desired, loadErr := t.LoadDesired()
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || strings.HasPrefix(name, ".") {
			continue
		}
		if loadErr == nil {
			data, isProfile := desired[name]
			if !isProfile { // LoadDesired skipped it → so will sync
				ignored = append(ignored, name)
				continue
			}
			files = append(files, libFile{name: name, data: data})
			continue
		}
		// Fallback: mirror LoadDesired's extension rule (dirs/dotfiles are already
		// skipped above) and read the file on its own.
		if ext := strings.ToLower(filepath.Ext(name)); ext != "" && ext != ".mobileconfig" {
			ignored = append(ignored, name)
			continue
		}
		data, readErr := os.ReadFile(filepath.Join(t.LibDir, name))
		files = append(files, libFile{name: name, data: data, err: readErr})
	}
	return files, ignored
}

// checkProfile is the built-in structural pass over one file. Errors fail the
// profile (and therefore the run); warnings are advice.
func checkProfile(libDir string, f libFile) profileReport {
	pr := profileReport{
		Name:         f.name,
		Path:         rel(filepath.Join(libDir, f.name)),
		Bytes:        len(f.data),
		PayloadTypes: []string{},
		Errors:       []validationIssue{},
		Warnings:     []validationIssue{},
	}
	inspectProfile(&pr, f)
	pr.OK = len(pr.Errors) == 0
	return pr
}

// inspectProfile records everything it can before giving up, so one run names
// every problem in the file (an oversize profile and a parse failure are
// independent findings), and stops only where continuing is meaningless — there
// is nothing to walk in a file that is not XML.
func inspectProfile(pr *profileReport, f libFile) {
	fail := func(code, format string, a ...any) {
		pr.Errors = append(pr.Errors, validationIssue{Code: code, Message: fmt.Sprintf(format, a...)})
	}
	warn := func(code, format string, a ...any) {
		pr.Warnings = append(pr.Warnings, validationIssue{Code: code, Message: fmt.Sprintf(format, a...)})
	}
	if f.err != nil {
		fail("unreadable", "the file could not be read: %v", f.err)
		return
	}
	if len(f.data) == 0 {
		fail("empty", "the file is empty.")
		return
	}
	switch {
	case len(f.data) >= profileSizeCap:
		fail("size-cap", "the profile is %d KiB; Apple Business rejects a configuration of 1 MiB or more.", len(f.data)/1024)
	case len(f.data) >= profileSizeWarn:
		warn("approaching-size-cap", "the profile is %d KiB, close to the 1 MiB Apple Business cap.", len(f.data)/1024)
	}
	// The two non-XML shapes are worth naming precisely: a converted binary plist
	// and an exported *signed* profile are what operators most often drop in here.
	if bytes.HasPrefix(f.data, []byte("bplist00")) {
		fail("binary-plist", "this is a binary plist; Apple Business expects an XML .mobileconfig (convert it with `plutil -convert xml1`).")
		return
	}
	if f.data[0] == 0x30 {
		fail("signed-profile", "this looks like a signed (DER/PKCS#7) profile; Apple Business expects the unsigned XML .mobileconfig.")
		return
	}
	root, top, err := parsePlist(f.data)
	if err != nil {
		fail("xml-parse", "the XML is malformed: %v", err)
		return
	}
	if root != "plist" {
		if root == "" {
			fail("not-plist", "the file has no XML root element; an XML <plist> document was expected.")
		} else {
			fail("not-plist", "the root element is <%s>, not <plist>.", root)
		}
		return
	}
	// A <plist> wrapping something other than a <dict> has a nil map here, which
	// reads as "every top-level key is missing" — exactly the right verdict.
	pr.Identifier = top.dict["PayloadIdentifier"].text
	pr.DisplayName = top.dict["PayloadDisplayName"].text

	content, hasContent := top.dict["PayloadContent"]
	if !hasContent {
		fail("missing-payload-content", "the top-level dictionary has no PayloadContent key.")
	}
	switch ptype, hasType := top.dict["PayloadType"]; {
	case !hasType:
		fail("missing-payload-type", "the top-level dictionary has no PayloadType key.")
	case ptype.text != "Configuration":
		fail("not-configuration", "the top-level PayloadType is %q; Apple Business requires \"Configuration\".", ptype.text)
	}
	// The one check that exists because it already burned someone. Apple pins the
	// OUTER PayloadVersion to exactly 1 — it versions the profile FORMAT, not the
	// operator's content — and Apple Business answers a PATCH carrying any other
	// value with a 2xx and then does not persist the profile. The live bytes never
	// move, so a GitOps run recomputes the identical change forever and archives a
	// snapshot every pass; nothing downstream can see it without reading the stored
	// copy back. It is therefore an ERROR here, before anything is ever pushed.
	switch pv, hasVersion := top.dict["PayloadVersion"]; {
	case !hasVersion:
		fail("payload-version", "the top-level dictionary has no PayloadVersion; Apple requires it to be exactly 1 "+
			"(https://developer.apple.com/documentation/devicemanagement/toplevel). Add <key>PayloadVersion</key><integer>1</integer>.")
	case pv.text != "1":
		fail("payload-version", "the top-level PayloadVersion is %s; Apple requires exactly 1 — it is the version of the profile FORMAT, "+
			"not of your content (https://developer.apple.com/documentation/devicemanagement/toplevel). Apple Business accepts an upload "+
			"carrying any other value with a 2xx and then silently does not store the profile, so the live copy never changes and every "+
			"sync recomputes the same change forever. Set it back to <integer>1</integer> and track your own revisions in git.",
			describeScalar(pv))
	}
	// Missing and present-but-blank are the same failure to Apple: the identifier
	// is how a profile is addressed on the device.
	if pr.Identifier == "" {
		fail("missing-payload-identifier", "the top-level dictionary has no PayloadIdentifier; Apple Business identifies a profile by it.")
	}
	if _, ok := top.dict["PayloadUUID"]; !ok {
		warn("missing-payload-uuid", "the top-level dictionary has no PayloadUUID.")
	}
	if pr.DisplayName == "" {
		warn("missing-display-name", "the top-level dictionary has no PayloadDisplayName, so the console shows the file name instead.")
	}
	if hasContent {
		if len(content.array) == 0 {
			warn("no-inner-payloads", "the profile carries no inner payloads, so it configures nothing.")
		}
		for i, item := range content.array {
			pt := item.dict["PayloadType"].text // a nil map on a non-dict item reads as ""
			switch {
			case item.kind != "dict":
				warn("inner-payload-missing-type", "inner payload #%d is a <%s>, not a <dict>.", i+1, item.kind)
			case pt == "":
				warn("inner-payload-missing-type", "inner payload #%d has no PayloadType.", i+1)
			default:
				pr.PayloadTypes = append(pr.PayloadTypes, pt)
			}
			// Apple's CommonPayloadKeys documents the per-payload PayloadVersion as a
			// schema version whose allowed value is 1 as well, so a 2 here is still
			// wrong — but only the OUTER one is known to trigger the silent drop, so
			// this stays a warning. A payload that simply omits the key is not flagged:
			// the observed failure needs a present, out-of-spec value.
			if pv, ok := item.dict["PayloadVersion"]; ok && pv.text != "1" {
				warn("inner-payload-version", "inner payload %s has PayloadVersion %s; Apple defines the per-payload PayloadVersion as a schema version whose value is 1.",
					innerPayloadLabel(i, pt), describeScalar(pv))
			}
		}
	}
}

// innerPayloadLabel names an inner payload the way an operator finds it in the
// file — by PayloadType, falling back to its position when it has none.
func innerPayloadLabel(i int, payloadType string) string {
	if payloadType == "" {
		return fmt.Sprintf("#%d", i+1)
	}
	return fmt.Sprintf("%q", payloadType)
}

// describeScalar renders what a plist key ACTUALLY holds, for a message an
// operator can act on: the text of a scalar such as <integer>2</integer>, else
// the element itself, so a <true/> or a nested <dict> is never reported as an
// empty value.
func describeScalar(v plistValue) string {
	if v.text != "" {
		return v.text
	}
	return "<" + v.kind + ">"
}

// flagDuplicateIdentifiers adds a duplicate-identifier error to EVERY profile
// sharing a PayloadIdentifier, each naming the others: two configurations with
// the same identifier overwrite each other on the device, and flagging only one
// of them would hide half the conflict.
func flagDuplicateIdentifiers(profiles []profileReport) {
	byID := map[string][]int{}
	for i, p := range profiles {
		if p.Identifier != "" {
			byID[p.Identifier] = append(byID[p.Identifier], i)
		}
	}
	for id, idx := range byID {
		if len(idx) < 2 {
			continue
		}
		for _, i := range idx {
			others := make([]string, 0, len(idx)-1)
			for _, j := range idx {
				if j != i {
					others = append(others, profiles[j].Name)
				}
			}
			profiles[i].Errors = append(profiles[i].Errors, validationIssue{
				Code: "duplicate-identifier",
				Message: fmt.Sprintf("PayloadIdentifier %q is also declared by %s; two profiles sharing an identifier overwrite each other on the device.",
					id, strings.Join(others, ", ")),
			})
			profiles[i].OK = false
		}
	}
}

// checkBlueprintRefs is the high-value pre-sync check: a blueprint that lists a
// configuration missing from lib/ syncs cleanly and attaches nothing, so it is an
// error here. An unparseable manifest set yields ONE issue rather than aborting —
// the profile rows are still worth printing.
func checkBlueprintRefs(t *gitops.Tree, files []libFile) []treeIssue {
	specs, err := t.LoadBlueprints()
	if err != nil {
		return []treeIssue{{Level: "error", Scope: "blueprints", Code: "blueprint-parse", Message: err.Error()}}
	}
	inLib := make(map[string]bool, len(files))
	for _, f := range files {
		inLib[f.name] = true // the same key LoadDesired uses: the file name
	}
	names := make([]string, 0, len(specs))
	for n := range specs {
		names = append(names, n)
	}
	sort.Strings(names) // map order would shuffle the report between runs
	var out []treeIssue
	for _, name := range names {
		for _, cfg := range specs[name].Configurations {
			if inLib[cfg] {
				continue
			}
			out = append(out, treeIssue{
				Level: "error", Scope: "blueprints", Target: name, Code: "missing-config",
				Message: fmt.Sprintf("blueprint %q references configuration %q, which is not in lib/", name, cfg),
			})
		}
	}
	return out
}

// printValidationReport is the human view: tree issues first (a blueprint pointing
// at a missing configuration is the failure that silently attaches nothing), then
// only the profiles that have something to say, then the summary line scripts have
// always grepped.
func printValidationReport(rep validationReport) {
	for _, ti := range rep.TreeIssues {
		if ti.Level == "error" {
			fmt.Printf("ERROR %s\n", ti.Message)
		}
	}
	for _, ti := range rep.TreeIssues {
		if ti.Level != "error" {
			fmt.Printf("WARN  %s\n", ti.Message)
		}
	}
	for _, p := range rep.Profiles {
		if len(p.Errors) == 0 && len(p.Warnings) == 0 {
			continue
		}
		status := "WARN"
		if !p.OK {
			status = "FAIL"
		}
		fmt.Printf("%s %s\n", status, p.Name)
		for _, e := range p.Errors {
			fmt.Printf("     error   %s: %s\n", e.Code, e.Message)
		}
		for _, w := range p.Warnings {
			fmt.Printf("     warning %s: %s\n", w.Code, w.Message)
		}
	}
	fmt.Printf("%d profile(s): %d ok, %d failed, %d warning(s) in %s (built-in check; set $ABCTL_VALIDATOR for deep validation)\n",
		rep.Checked, rep.Passed, rep.Failed, rep.WarningCount, rep.LibDir)
}

func resolveValidator() []string {
	if v := os.Getenv("ABCTL_VALIDATOR"); v != "" {
		return strings.Fields(v)
	}
	return nil
}

// runExternalValidator execs $ABCTL_VALIDATOR against lib/, streaming its output
// and propagating its exit code as ours.
func runExternalValidator(argv []string, libDir string) error {
	cmd := exec.Command(argv[0], append(append([]string{}, argv[1:]...), libDir)...)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ExitError{Code: ee.ExitCode()}
		}
		return err
	}
	return nil
}

// foldExternalValidator runs $ABCTL_VALIDATOR for the machine report: its combined
// output is CAPTURED, never streamed (stdout belongs to the JSON report), and a
// non-zero exit fails the report exactly like a built-in error. A validator that
// cannot be started at all is recorded as exit -1 rather than passing silently.
func foldExternalValidator(rep *validationReport, argv []string, libDir string) {
	full := append(append([]string{}, argv...), libDir)
	rep.Validator = "external"
	rep.ValidatorCommand = strings.Join(full, " ")
	cmd := exec.Command(full[0], full[1:]...)
	var buf bytes.Buffer
	cmd.Stdout, cmd.Stderr = &buf, &buf
	code := 0
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			code = ee.ExitCode()
		} else {
			code = -1
			buf.WriteString(err.Error())
		}
	}
	rep.ValidatorExitCode = &code
	rep.ValidatorOutput = capValidatorOutput(buf.String())
	if code != 0 {
		rep.OK = false
	}
}

// capValidatorOutput bounds the captured validator output at 16 KiB so one chatty
// linter can't blow up the payload; the cut is trimmed back to a rune boundary so
// the JSON field stays valid UTF-8.
func capValidatorOutput(s string) string {
	if len(s) <= validatorOutputCap {
		return s
	}
	return strings.ToValidUTF8(s[:validatorOutputCap], "") + "… (truncated)"
}

// plistValue is the sliver of the plist data model the checks need: a dict, an
// array, or a scalar kept as its text. Apple ships .mobileconfig as an XML
// property list, so encoding/xml is enough — abctl takes on no plist dependency.
type plistValue struct {
	kind  string                // the XML element name: "dict", "array", "string", "key", …
	text  string                // scalar text; "" for containers
	dict  map[string]plistValue // kind == "dict"
	array []plistValue          // kind == "array"
}

// parsePlist returns the document's root element name and the value inside
// <plist>. A root that is not <plist> comes back named, with a zero value and no
// error, so the caller can report not-plist; an empty name means the file held no
// elements at all. The decoder stays Strict: Apple's own parser is a real XML
// parser, so anything it would reject should fail here too.
func parsePlist(data []byte) (string, plistValue, error) {
	dec := xml.NewDecoder(bytes.NewReader(data))
	for {
		tok, err := dec.Token()
		if errors.Is(err, io.EOF) {
			return "", plistValue{}, nil
		}
		if err != nil {
			return "", plistValue{}, err
		}
		se, ok := tok.(xml.StartElement)
		if !ok {
			continue // XML declaration, the plist DOCTYPE, comments, whitespace
		}
		if se.Name.Local != "plist" {
			return se.Name.Local, plistValue{}, nil
		}
		v, _, err := nextValue(dec, 0)
		return "plist", v, err
	}
}

// nextValue returns the next child VALUE of the element the decoder is currently
// inside; ok=false means that element's own end tag arrived first.
func nextValue(dec *xml.Decoder, depth int) (plistValue, bool, error) {
	for {
		tok, err := dec.Token()
		if err != nil {
			return plistValue{}, false, err // inside an element, so EOF here means malformed
		}
		switch t := tok.(type) {
		case xml.StartElement:
			v, err := parseValue(dec, t, depth+1)
			if err != nil {
				return plistValue{}, false, err
			}
			return v, true, nil
		case xml.EndElement:
			return plistValue{}, false, nil
		}
	}
}

// parseValue parses the element whose start tag was just consumed. A <dict> is
// the alternating <key>/<value> children the plist format specifies; anything
// that is not a dict or an array is kept as its text.
func parseValue(dec *xml.Decoder, start xml.StartElement, depth int) (plistValue, error) {
	v := plistValue{kind: start.Name.Local}
	if depth > maxPlistDepth {
		return v, fmt.Errorf("nested deeper than %d elements at <%s>", maxPlistDepth, v.kind)
	}
	switch v.kind {
	case "dict":
		v.dict = map[string]plistValue{}
		for {
			key, ok, err := nextValue(dec, depth)
			if err != nil || !ok {
				return v, err
			}
			if key.kind != "key" {
				return v, fmt.Errorf("<dict> holds <%s> where a <key> was expected", key.kind)
			}
			val, ok, err := nextValue(dec, depth)
			if err != nil {
				return v, err
			}
			if !ok {
				return v, fmt.Errorf("<key>%s</key> has no value element", key.text)
			}
			v.dict[key.text] = val
		}
	case "array":
		for {
			item, ok, err := nextValue(dec, depth)
			if err != nil || !ok {
				return v, err
			}
			v.array = append(v.array, item)
		}
	default:
		// A scalar (<string>/<integer>/<data>/<date>/<true/>/…): DecodeElement
		// consumes the element including its end tag and hands us its text.
		var text string
		if err := dec.DecodeElement(&text, &start); err != nil {
			return v, err
		}
		v.text = strings.TrimSpace(text)
	}
	return v, nil
}
