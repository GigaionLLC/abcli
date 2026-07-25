package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/GigaionLLC/abcli/internal/config"
	"github.com/GigaionLLC/abcli/internal/gitops"
)

// profileXML wraps top-level dict entries in the plist envelope Apple ships,
// DOCTYPE and all — the walker has to cope with the real thing.
func profileXML(inner string) string {
	return `<?xml version="1.0" encoding="UTF-8"?>` + "\n" +
		`<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">` + "\n" +
		"<plist version=\"1.0\">\n<dict>\n" + inner + "\n</dict>\n</plist>\n"
}

// goodProfile is a structurally complete profile with one inner payload.
func goodProfile(identifier string) string {
	return profileXML(`	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadType</key>
			<string>com.apple.wifi.managed</string>
			<key>PayloadIdentifier</key>
			<string>` + identifier + `.inner</string>
		</dict>
	</array>
	<key>PayloadDisplayName</key>
	<string>Corp Wi-Fi</string>
	<key>PayloadIdentifier</key>
	<string>` + identifier + `</string>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>6E8B0F2A-2E4E-4E3A-9C2F-2A0C7D3B1E55</string>
	<key>PayloadVersion</key>
	<integer>1</integer>`)
}

// newTestTree builds a throwaway gitops tree (lib/ + blueprints/) under t.TempDir()
// and returns it with the dir the tree is rooted at, so a case can also point
// config.TreeDir at it.
func newTestTree(t *testing.T) (*gitops.Tree, string) {
	t.Helper()
	dir := t.TempDir()
	tr := gitops.NewTree(dir)
	for _, d := range []string{tr.LibDir, tr.BlueprintsDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return tr, dir
}

func writeProfile(t *testing.T, tr *gitops.Tree, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(tr.LibDir, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeBlueprint(t *testing.T, tr *gitops.Tree, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(tr.BlueprintsDir, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// noCredentials puts the process in the state of a machine that has never been
// configured — no context store, no .env up the tree, no AB_* — with the cwd (and
// an empty local .env, so the walk-up can't reach a real one) at dir.
func noCredentials(t *testing.T, dir string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("# no credentials here\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ABCTL_CONTEXTS", filepath.Join(dir, "no-contexts.yaml"))
	t.Setenv("ABCTL_CONTEXT", "")
	t.Setenv("ABCTL_ENV", "")
	t.Setenv("AB_CLIENT_ID", "")
	t.Setenv("AB_PRIVATE_KEY", "")
	t.Setenv("ABCTL_VALIDATOR", "")
	t.Chdir(dir)
}

func hasCode(issues []validationIssue, code string) bool {
	for _, i := range issues {
		if i.Code == code {
			return true
		}
	}
	return false
}

func treeIssueWith(issues []treeIssue, code string) (treeIssue, bool) {
	for _, i := range issues {
		if i.Code == code {
			return i, true
		}
	}
	return treeIssue{}, false
}

// TestValidateGoodProfilePasses: a complete profile has no errors and no
// warnings, and the report surfaces the identity fields the GUI renders.
func TestValidateGoodProfilePasses(t *testing.T) {
	tr, _ := newTestTree(t)
	writeProfile(t, tr, "WiFi-Corp.mobileconfig", goodProfile("com.example.wifi"))
	writeBlueprint(t, tr, "sales.yml", "name: Sales\nconfigurations:\n  - WiFi-Corp.mobileconfig\n")

	rep := buildValidationReport(tr)
	if !rep.OK || rep.Checked != 1 || rep.Passed != 1 || rep.Failed != 0 || rep.WarningCount != 0 {
		t.Fatalf("clean tree report = %+v", rep)
	}
	p := rep.Profiles[0]
	if p.Name != "WiFi-Corp.mobileconfig" || !p.OK || p.Bytes == 0 {
		t.Errorf("profile row = %+v", p)
	}
	if p.Identifier != "com.example.wifi" || p.DisplayName != "Corp Wi-Fi" {
		t.Errorf("identity not parsed: identifier=%q displayName=%q", p.Identifier, p.DisplayName)
	}
	if len(p.PayloadTypes) != 1 || p.PayloadTypes[0] != "com.apple.wifi.managed" {
		t.Errorf("payloadTypes = %v, want the inner payload type", p.PayloadTypes)
	}
	if rep.Validator != "built-in" {
		t.Errorf("validator = %q, want built-in", rep.Validator)
	}
}

// TestValidateProfileErrors is the built-in error table: each malformed shape
// fails its own profile with its own code, and a failing profile fails the run.
func TestValidateProfileErrors(t *testing.T) {
	cases := []struct {
		name string
		body string
		code string
	}{
		{"empty file", "", "empty"},
		{"binary plist", "bplist00\x00\x01\x02", "binary-plist"},
		{"signed profile", "\x30\x82\x01\x02signed", "signed-profile"},
		{"malformed xml", "<plist><dict><key>PayloadType</key></plist>", "xml-parse"},
		{"not a plist", "<?xml version=\"1.0\"?>\n<manifest><item/></manifest>\n", "not-plist"},
		{"oversize", profileXML("\t<key>PayloadContent</key>\n\t<array/>\n\t<key>PayloadType</key>\n\t<string>Configuration</string>\n\t<key>PayloadIdentifier</key>\n\t<string>com.example.big</string>\n\t<key>Padding</key>\n\t<string>" + strings.Repeat("A", 1<<20) + "</string>"), "size-cap"},
		{"no payload content", profileXML("\t<key>PayloadType</key>\n\t<string>Configuration</string>\n\t<key>PayloadIdentifier</key>\n\t<string>com.example.nc</string>"), "missing-payload-content"},
		{"no payload type", profileXML("\t<key>PayloadContent</key>\n\t<array/>\n\t<key>PayloadIdentifier</key>\n\t<string>com.example.nt</string>"), "missing-payload-type"},
		{"wrong payload type", profileXML("\t<key>PayloadContent</key>\n\t<array/>\n\t<key>PayloadType</key>\n\t<string>com.apple.wifi.managed</string>\n\t<key>PayloadIdentifier</key>\n\t<string>com.example.wt</string>"), "not-configuration"},
		{"no identifier", profileXML("\t<key>PayloadContent</key>\n\t<array/>\n\t<key>PayloadType</key>\n\t<string>Configuration</string>"), "missing-payload-identifier"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tr, _ := newTestTree(t)
			writeProfile(t, tr, "Broken.mobileconfig", c.body)
			rep := buildValidationReport(tr)
			p := rep.Profiles[0]
			if !hasCode(p.Errors, c.code) {
				t.Fatalf("errors = %+v, want code %q", p.Errors, c.code)
			}
			if p.OK || rep.OK || rep.Failed != 1 || rep.Passed != 0 {
				t.Errorf("an error must fail the profile and the run: profile.ok=%v report=%+v", p.OK, rep)
			}
			for _, e := range p.Errors { // messages are for humans, not empty codes
				if e.Message == "" {
					t.Errorf("issue %q has no message", e.Code)
				}
			}
		})
	}
}

// profileOfSize builds a structurally valid profile padded to EXACTLY n bytes,
// so the size thresholds can be tested ON the boundary instead of near it.
func profileOfSize(t *testing.T, n int) string {
	t.Helper()
	body := func(pad string) string {
		return profileXML("\t<key>PayloadContent</key>\n\t<array/>\n\t<key>PayloadType</key>\n" +
			"\t<string>Configuration</string>\n\t<key>PayloadIdentifier</key>\n" +
			"\t<string>com.example.sized</string>\n\t<key>PayloadUUID</key>\n\t<string>SIZED</string>\n" +
			"\t<key>PayloadDisplayName</key>\n\t<string>Sized</string>\n\t<key>Padding</key>\n\t<string>" +
			pad + "</string>")
	}
	base := len(body("")) // the pad is ASCII, so length grows one-for-one
	if n < base {
		t.Fatalf("cannot build a %d-byte profile: the envelope alone is %d bytes", n, base)
	}
	return body(strings.Repeat("A", n-base))
}

// TestValidateSizeCapBoundary pins the exact thresholds, because an off-by-one
// here is invisible in ordinary fixtures: Apple Business rejects a configuration
// of 1 MiB OR MORE, so 1<<20 must fail and 1<<20-1 must pass. The warning
// threshold is pinned the same way.
func TestValidateSizeCapBoundary(t *testing.T) {
	cases := []struct {
		name     string
		size     int
		wantFail bool
		wantWarn bool
	}{
		{"just under the warn threshold", profileSizeWarn - 1, false, false},
		{"exactly at the warn threshold", profileSizeWarn, false, true},
		{"one byte under the cap", profileSizeCap - 1, false, true},
		{"exactly at the cap", profileSizeCap, true, false},
		{"one byte over the cap", profileSizeCap + 1, true, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tr, _ := newTestTree(t)
			writeProfile(t, tr, "Sized.mobileconfig", profileOfSize(t, c.size))

			rep := buildValidationReport(tr)
			p := rep.Profiles[0]
			if p.Bytes != c.size {
				t.Fatalf("fixture is %d bytes, wanted exactly %d", p.Bytes, c.size)
			}
			if got := hasCode(p.Errors, "size-cap"); got != c.wantFail {
				t.Errorf("size-cap error = %v, want %v at %d bytes (cap %d)", got, c.wantFail, c.size, profileSizeCap)
			}
			if p.OK == c.wantFail {
				t.Errorf("profile ok = %v at %d bytes", p.OK, c.size)
			}
			if got := hasCode(p.Warnings, "approaching-size-cap"); got != c.wantWarn {
				t.Errorf("approaching-size-cap warning = %v, want %v at %d bytes", got, c.wantWarn, c.size)
			}
		})
	}
}

// TestValidateUnreadableProfile: a file we cannot read fails as `unreadable`
// instead of taking the whole run down with it.
func TestValidateUnreadableProfile(t *testing.T) {
	pr := checkProfile("lib", libFile{name: "Locked.mobileconfig", err: os.ErrPermission})
	if pr.OK || !hasCode(pr.Errors, "unreadable") {
		t.Errorf("unreadable profile = %+v", pr)
	}
}

// TestValidateWarningsDoNotFail: a thin-but-legal profile only warns — `ok` stays
// true on the profile AND on the report (exit 0), while the warnings still count.
func TestValidateWarningsDoNotFail(t *testing.T) {
	tr, _ := newTestTree(t)
	writeProfile(t, tr, "Thin.mobileconfig", profileXML("\t<key>PayloadContent</key>\n\t<array/>\n\t<key>PayloadType</key>\n\t<string>Configuration</string>\n\t<key>PayloadIdentifier</key>\n\t<string>com.example.thin</string>"))

	rep := buildValidationReport(tr)
	p := rep.Profiles[0]
	if !p.OK || !rep.OK || rep.Failed != 0 {
		t.Fatalf("warnings must not fail anything: profile.ok=%v report=%+v", p.OK, rep)
	}
	for _, code := range []string{"missing-payload-uuid", "missing-display-name", "no-inner-payloads"} {
		if !hasCode(p.Warnings, code) {
			t.Errorf("warnings = %+v, want %q", p.Warnings, code)
		}
	}
	if len(p.Errors) != 0 {
		t.Errorf("errors = %+v, want none", p.Errors)
	}
	if rep.WarningCount != len(p.Warnings) {
		t.Errorf("report warnings = %d, want %d", rep.WarningCount, len(p.Warnings))
	}
}

// TestValidateInnerPayloadWarnings: an inner payload without a PayloadType is
// worth flagging, and it is not counted as a payload type.
func TestValidateInnerPayloadWarnings(t *testing.T) {
	tr, _ := newTestTree(t)
	writeProfile(t, tr, "Inner.mobileconfig", profileXML(`	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadIdentifier</key>
			<string>com.example.inner</string>
		</dict>
		<dict>
			<key>PayloadType</key>
			<string>com.apple.dock</string>
		</dict>
	</array>
	<key>PayloadDisplayName</key>
	<string>Inner</string>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadIdentifier</key>
	<string>com.example.inner.top</string>
	<key>PayloadUUID</key>
	<string>ABCD</string>`))

	p := buildValidationReport(tr).Profiles[0]
	if !p.OK || !hasCode(p.Warnings, "inner-payload-missing-type") {
		t.Fatalf("inner payload row = %+v", p)
	}
	if len(p.PayloadTypes) != 1 || p.PayloadTypes[0] != "com.apple.dock" {
		t.Errorf("payloadTypes = %v, want only the typed payload", p.PayloadTypes)
	}
}

// TestValidateDuplicateIdentifiers: BOTH files are flagged, each naming the
// other — reporting only one would hide half the conflict.
func TestValidateDuplicateIdentifiers(t *testing.T) {
	tr, _ := newTestTree(t)
	writeProfile(t, tr, "A.mobileconfig", goodProfile("com.example.dup"))
	writeProfile(t, tr, "B.mobileconfig", goodProfile("com.example.dup"))
	writeProfile(t, tr, "C.mobileconfig", goodProfile("com.example.unique"))

	rep := buildValidationReport(tr)
	if rep.OK || rep.Failed != 2 || rep.Passed != 1 {
		t.Fatalf("duplicate report = %+v", rep)
	}
	byName := map[string]profileReport{}
	for _, p := range rep.Profiles {
		byName[p.Name] = p
	}
	for name, other := range map[string]string{"A.mobileconfig": "B.mobileconfig", "B.mobileconfig": "A.mobileconfig"} {
		p := byName[name]
		if p.OK || !hasCode(p.Errors, "duplicate-identifier") {
			t.Fatalf("%s = %+v, want a duplicate-identifier error", name, p)
		}
		if !strings.Contains(p.Errors[0].Message, other) {
			t.Errorf("%s message %q does not name %s", name, p.Errors[0].Message, other)
		}
	}
	if c := byName["C.mobileconfig"]; !c.OK {
		t.Errorf("the unique profile must stay ok: %+v", c)
	}
}

// TestValidateBlueprintMissingConfig is the high-value pre-sync check: a
// blueprint listing a configuration that is not in lib/ would sync cleanly and
// attach nothing, so it is an error-level tree issue with the pinned wording.
func TestValidateBlueprintMissingConfig(t *testing.T) {
	tr, _ := newTestTree(t)
	writeProfile(t, tr, "WiFi-Corp.mobileconfig", goodProfile("com.example.wifi"))
	writeBlueprint(t, tr, "sales.yml", "name: Sales\nconfigurations:\n  - WiFi-Corp.mobileconfig\n  - VPN-Corp.mobileconfig\n")

	rep := buildValidationReport(tr)
	if rep.OK || rep.Failed != 0 || rep.Passed != 1 {
		t.Fatalf("tree errors must fail the run without failing a profile: %+v", rep)
	}
	ti, ok := treeIssueWith(rep.TreeIssues, "missing-config")
	if !ok {
		t.Fatalf("treeIssues = %+v, want a missing-config issue", rep.TreeIssues)
	}
	if ti.Level != "error" || ti.Scope != "blueprints" || ti.Target != "Sales" {
		t.Errorf("missing-config issue = %+v", ti)
	}
	want := `blueprint "Sales" references configuration "VPN-Corp.mobileconfig", which is not in lib/`
	if ti.Message != want {
		t.Errorf("message = %q, want %q", ti.Message, want)
	}
}

// TestValidateBlueprintParseError: an unparseable manifest set yields ONE issue
// and the profile rows survive — they are still worth having.
func TestValidateBlueprintParseError(t *testing.T) {
	tr, _ := newTestTree(t)
	writeProfile(t, tr, "WiFi-Corp.mobileconfig", goodProfile("com.example.wifi"))
	writeBlueprint(t, tr, "broken.yml", "configurations:\n  - WiFi-Corp.mobileconfig\n") // no name:

	rep := buildValidationReport(tr)
	if rep.OK || rep.Checked != 1 || rep.Passed != 1 {
		t.Fatalf("report = %+v, want a failing run whose profile row survived", rep)
	}
	ti, ok := treeIssueWith(rep.TreeIssues, "blueprint-parse")
	if !ok || ti.Level != "error" || ti.Scope != "blueprints" || ti.Message == "" {
		t.Errorf("treeIssues = %+v, want one error-level blueprint-parse issue", rep.TreeIssues)
	}
}

// TestValidateEmptyLibWarns: nothing to check is a warning, not a failure.
func TestValidateEmptyLibWarns(t *testing.T) {
	tr, _ := newTestTree(t)
	rep := buildValidationReport(tr)
	ti, ok := treeIssueWith(rep.TreeIssues, "empty-lib")
	if !ok || ti.Level != "warning" || ti.Scope != "lib" {
		t.Fatalf("treeIssues = %+v, want an empty-lib warning", rep.TreeIssues)
	}
	if !strings.Contains(ti.Message, "abctl seed") {
		t.Errorf("empty-lib message = %q, want the seed hint", ti.Message)
	}
	if !rep.OK || rep.Checked != 0 || rep.WarningCount != 1 {
		t.Errorf("empty lib report = %+v, want ok with one warning", rep)
	}
}

// TestValidateFileSetMatchesSync: validate checks exactly the files sync ships
// (extensionless files count; dotfiles are invisible) and warns about the rest.
func TestValidateFileSetMatchesSync(t *testing.T) {
	tr, _ := newTestTree(t)
	writeProfile(t, tr, "WiFi-Corp.mobileconfig", goodProfile("com.example.wifi"))
	writeProfile(t, tr, "Legacy Profile", goodProfile("com.example.legacy"))
	writeProfile(t, tr, "README.md", "not a profile")
	writeProfile(t, tr, ".DS_Store", "junk")

	rep := buildValidationReport(tr)
	desired, err := tr.LoadDesired()
	if err != nil {
		t.Fatal(err)
	}
	if rep.Checked != len(desired) {
		t.Errorf("checked %d file(s), sync would ship %d", rep.Checked, len(desired))
	}
	for _, p := range rep.Profiles {
		if _, ok := desired[p.Name]; !ok {
			t.Errorf("validate checked %q, which sync ignores", p.Name)
		}
	}
	ti, ok := treeIssueWith(rep.TreeIssues, "ignored-file")
	if !ok || ti.Target != "README.md" || ti.Level != "warning" {
		t.Fatalf("treeIssues = %+v, want an ignored-file warning for README.md", rep.TreeIssues)
	}
	if !rep.OK { // a stray file is advice, not a failure
		t.Errorf("an ignored file must not fail the run: %+v", rep)
	}
}

// TestParsePlistWalksDictsAndArrays covers the hand-rolled encoding/xml walker:
// nested dicts, arrays, and scalars all resolve, and a non-plist root is named
// rather than erroring.
func TestParsePlistWalksDictsAndArrays(t *testing.T) {
	root, v, err := parsePlist([]byte(profileXML(`	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadType</key>
			<string>com.apple.dock</string>
			<key>Nested</key>
			<dict>
				<key>Deep</key>
				<string>value</string>
			</dict>
		</dict>
	</array>
	<key>PayloadVersion</key>
	<integer>1</integer>
	<key>Removable</key>
	<true/>`)))
	if err != nil {
		t.Fatalf("parsePlist: %v", err)
	}
	if root != "plist" || v.kind != "dict" {
		t.Fatalf("root = %q, value kind = %q", root, v.kind)
	}
	content := v.dict["PayloadContent"]
	if content.kind != "array" || len(content.array) != 1 {
		t.Fatalf("PayloadContent = %+v", content)
	}
	inner := content.array[0]
	if inner.dict["PayloadType"].text != "com.apple.dock" {
		t.Errorf("inner PayloadType = %q", inner.dict["PayloadType"].text)
	}
	if got := inner.dict["Nested"].dict["Deep"].text; got != "value" {
		t.Errorf("nested dict value = %q, want value", got)
	}
	if v.dict["PayloadVersion"].text != "1" || v.dict["Removable"].kind != "true" {
		t.Errorf("scalars = %+v / %+v", v.dict["PayloadVersion"], v.dict["Removable"])
	}

	if root, _, err := parsePlist([]byte("<manifest/>")); err != nil || root != "manifest" {
		t.Errorf("non-plist root = (%q, %v), want (manifest, nil)", root, err)
	}
	if _, _, err := parsePlist([]byte("<plist><dict><key>a</key></dict>")); err == nil {
		t.Error("an unclosed document must be a parse error")
	}
}

// TestValidationReportMarshalsEmptyAsArrays covers N3 for this payload: a GUI
// decoding the report never has to special-case null.
func TestValidationReportMarshalsEmptyAsArrays(t *testing.T) {
	tr, _ := newTestTree(t)
	writeProfile(t, tr, "WiFi-Corp.mobileconfig", goodProfile("com.example.wifi"))
	b, err := json.MarshalIndent(buildValidationReport(tr), "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	out := string(b)
	for _, want := range []string{`"treeIssues": []`, `"errors": []`, `"warnings": []`, `"validator": "built-in"`} {
		if !strings.Contains(out, want) {
			t.Errorf("report JSON missing %s:\n%s", want, out)
		}
	}
	if strings.Contains(out, "null") {
		t.Errorf("report JSON contains null:\n%s", out)
	}
	// The validator fields stay out of the payload until one actually ran.
	for _, absent := range []string{"validatorCommand", "validatorExitCode", "validatorOutput"} {
		if strings.Contains(out, absent) {
			t.Errorf("built-in report should omit %s:\n%s", absent, out)
		}
	}

	// A profile carrying no inner payloads must still marshal payloadTypes as [].
	thin, _ := newTestTree(t)
	writeProfile(t, thin, "Thin.mobileconfig", profileXML("\t<key>PayloadContent</key>\n\t<array/>\n\t<key>PayloadType</key>\n\t<string>Configuration</string>\n\t<key>PayloadIdentifier</key>\n\t<string>com.example.thin</string>"))
	b, err = json.MarshalIndent(buildValidationReport(thin), "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if out = string(b); !strings.Contains(out, `"payloadTypes": []`) || strings.Contains(out, "null") {
		t.Errorf("a payload-less profile must marshal payloadTypes as []:\n%s", out)
	}

	// The empty workspace is the case a GUI meets FIRST (before `abctl seed`), and
	// it is the only one where `profiles` itself is empty — so pin it explicitly.
	empty, _ := newTestTree(t)
	b, err = json.MarshalIndent(buildValidationReport(empty), "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	out = string(b)
	if !strings.Contains(out, `"profiles": []`) {
		t.Errorf("an empty lib/ must marshal profiles as [], not null:\n%s", out)
	}
	if strings.Contains(out, "null") {
		t.Errorf("empty report contains null:\n%s", out)
	}
}

// TestRunValidateJSONPrintsReportAndExits1 is the whole command contract in one
// go: no credentials anywhere, the report lands on STDOUT so a GUI can decode it,
// and the run still exits 1 because the tree has problems.
func TestRunValidateJSONPrintsReportAndExits1(t *testing.T) {
	tr, dir := newTestTree(t)
	writeProfile(t, tr, "WiFi-Corp.mobileconfig", goodProfile("com.example.wifi"))
	writeProfile(t, tr, "Broken.mobileconfig", "<plist><dict><key>PayloadType</key></plist>")
	writeBlueprint(t, tr, "sales.yml", "name: Sales\nconfigurations:\n  - VPN-Corp.mobileconfig\n")
	noCredentials(t, dir)
	orig := flagOutput
	t.Cleanup(func() { flagOutput = orig })
	flagOutput = "table"

	var runErr error
	out := captureStdout(t, func() error { runErr = runValidate(true); return nil })

	var ee ExitError
	if !errors.As(runErr, &ee) || ee.Code != 1 {
		t.Fatalf("runValidate error = %v, want ExitError{1}", runErr)
	}
	var rep validationReport
	if err := json.Unmarshal([]byte(out), &rep); err != nil {
		t.Fatalf("stdout is not the JSON report: %v\n%s", err, out)
	}
	if rep.OK || rep.Checked != 2 || rep.Passed != 1 || rep.Failed != 1 {
		t.Errorf("report = %+v", rep)
	}
	if _, ok := treeIssueWith(rep.TreeIssues, "missing-config"); !ok {
		t.Errorf("treeIssues = %+v, want missing-config", rep.TreeIssues)
	}
	if strings.Contains(out, "null") {
		t.Errorf("JSON report contains null:\n%s", out)
	}
}

// TestRunValidateHumanPathExitsCleanOnWarnings: the same tree without errors
// prints the summary line scripts grep for and exits 0.
func TestRunValidateHumanPathExitsCleanOnWarnings(t *testing.T) {
	tr, dir := newTestTree(t)
	writeProfile(t, tr, "Thin.mobileconfig", profileXML("\t<key>PayloadContent</key>\n\t<array/>\n\t<key>PayloadType</key>\n\t<string>Configuration</string>\n\t<key>PayloadIdentifier</key>\n\t<string>com.example.thin</string>"))
	noCredentials(t, dir)
	orig := flagOutput
	t.Cleanup(func() { flagOutput = orig })
	flagOutput = "table"

	var runErr error
	out := captureStdout(t, func() error { runErr = runValidate(false); return nil })
	if runErr != nil {
		t.Fatalf("warnings must not change the exit code: %v", runErr)
	}
	if !strings.Contains(out, "1 profile(s): 1 ok, 0 failed") {
		t.Errorf("summary line missing from:\n%s", out)
	}
}

// TestTreeDirNeedsNoCredentials: validate resolves the tree with nothing
// configured — the cwd when no .env is in scope, else the .env's directory even
// though that .env carries no usable credentials.
func TestTreeDirNeedsNoCredentials(t *testing.T) {
	dir := t.TempDir()
	sub := filepath.Join(dir, "workspace", "nested")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ABCTL_CONTEXTS", filepath.Join(dir, "no-contexts.yaml"))
	t.Setenv("ABCTL_CONTEXT", "")
	t.Setenv("ABCTL_ENV", "")
	t.Setenv("AB_CLIENT_ID", "")
	t.Setenv("AB_PRIVATE_KEY", "")

	// A credential-less .env up the tree still marks the workspace root.
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("# nothing useful\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Chdir(sub)
	if got := config.TreeDir(""); !samePath(t, got, dir) {
		t.Errorf("TreeDir = %q, want the .env directory %q", got, dir)
	}

	// With no .env in scope at all it falls back to the cwd, so `validate` still runs.
	if err := os.Remove(filepath.Join(dir, ".env")); err != nil {
		t.Fatal(err)
	}
	if got := config.TreeDir(""); got == "" {
		t.Error("TreeDir returned empty with no .env; want the cwd")
	}
}

// TestValidateCapabilityToken: the GUI gates the Verify-configs sheet on this token.
func TestValidateCapabilityToken(t *testing.T) {
	for _, c := range buildVersionInfo().Capabilities {
		if c == "validate-json" {
			return
		}
	}
	t.Error("capabilities must advertise validate-json")
}

// TestHelperValidator is not a test: it is the stand-in $ABCTL_VALIDATOR the
// external-validator cases exec (the standard helper-process pattern, so the
// suite needs no shell and no fixture binary). It writes to BOTH streams and
// exits with the code the parent asked for. The guard env var is set with
// t.Setenv, which restores it before this file's own test run reaches here.
func TestHelperValidator(t *testing.T) {
	if os.Getenv("ABCTL_TEST_VALIDATOR_HELPER") != "1" {
		t.Skip("helper process for the external-validator cases; never run on its own")
	}
	fmt.Fprintln(os.Stdout, "helper-stdout "+os.Args[len(os.Args)-1])
	fmt.Fprintln(os.Stderr, "helper-stderr")
	if os.Getenv("ABCTL_TEST_VALIDATOR_FLOOD") == "1" {
		fmt.Fprint(os.Stdout, strings.Repeat("x", validatorOutputCap*2))
	}
	code, _ := strconv.Atoi(os.Getenv("ABCTL_TEST_VALIDATOR_EXIT"))
	os.Exit(code)
}

// helperValidator arms TestHelperValidator as $ABCTL_VALIDATOR and returns the
// argv string. $ABCTL_VALIDATOR is whitespace-split, so a test binary living
// under a path with a space cannot be addressed this way — skip rather than
// assert something false.
func helperValidator(t *testing.T, exitCode int) string {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Skipf("cannot locate the test binary: %v", err)
	}
	if strings.ContainsAny(exe, " \t") {
		t.Skipf("test binary path %q has whitespace; $ABCTL_VALIDATOR is whitespace-split", exe)
	}
	t.Setenv("ABCTL_TEST_VALIDATOR_HELPER", "1")
	t.Setenv("ABCTL_TEST_VALIDATOR_EXIT", strconv.Itoa(exitCode))
	return exe + " -test.run=^TestHelperValidator$"
}

// TestFoldExternalValidator: on the machine path the validator's output is
// CAPTURED (stdout belongs to the JSON report), both streams land in
// validatorOutput, and a non-zero exit fails the report even though every
// profile passed the built-in checks.
func TestFoldExternalValidator(t *testing.T) {
	for _, c := range []struct {
		name   string
		exit   int
		wantOK bool
	}{
		{"validator passes", 0, true},
		{"validator fails", 3, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			tr, _ := newTestTree(t)
			writeProfile(t, tr, "WiFi-Corp.mobileconfig", goodProfile("com.example.wifi"))
			argv := helperValidator(t, c.exit)

			rep := buildValidationReport(tr)
			if !rep.OK {
				t.Fatalf("the built-in pass should be clean here: %+v", rep)
			}
			foldExternalValidator(&rep, strings.Fields(argv), tr.LibDir)

			if rep.Validator != "external" || rep.ValidatorCommand == "" {
				t.Errorf("validator = %q, command = %q", rep.Validator, rep.ValidatorCommand)
			}
			if rep.ValidatorExitCode == nil || *rep.ValidatorExitCode != c.exit {
				t.Fatalf("validatorExitCode = %v, want %d", rep.ValidatorExitCode, c.exit)
			}
			if rep.OK != c.wantOK {
				t.Errorf("report ok = %v, want %v (exit %d)", rep.OK, c.wantOK, c.exit)
			}
			// Both streams captured — proof the output was not streamed past us.
			for _, want := range []string{"helper-stdout", "helper-stderr", tr.LibDir} {
				if !strings.Contains(rep.ValidatorOutput, want) {
					t.Errorf("validatorOutput %q missing %q", rep.ValidatorOutput, want)
				}
			}
			// A passing validator must leave the profile rows alone.
			if rep.Checked != 1 || rep.Passed != 1 {
				t.Errorf("built-in rows disturbed by the validator: %+v", rep)
			}
		})
	}
}

// TestFoldExternalValidatorUnstartable: a validator that cannot be exec'd at all
// is recorded as exit -1 and fails the report — never a silent pass.
func TestFoldExternalValidatorUnstartable(t *testing.T) {
	tr, dir := newTestTree(t)
	rep := buildValidationReport(tr)
	foldExternalValidator(&rep, []string{filepath.Join(dir, "no-such-validator")}, tr.LibDir)

	if rep.ValidatorExitCode == nil || *rep.ValidatorExitCode != -1 {
		t.Fatalf("validatorExitCode = %v, want -1", rep.ValidatorExitCode)
	}
	if rep.OK || rep.ValidatorOutput == "" {
		t.Errorf("an unstartable validator must fail the report with a reason: %+v", rep)
	}
}

// TestFoldExternalValidatorCapsOutput: a chatty linter cannot blow up a payload
// a GUI has to decode.
func TestFoldExternalValidatorCapsOutput(t *testing.T) {
	tr, _ := newTestTree(t)
	argv := helperValidator(t, 0)
	t.Setenv("ABCTL_TEST_VALIDATOR_FLOOD", "1")

	rep := buildValidationReport(tr)
	foldExternalValidator(&rep, strings.Fields(argv), tr.LibDir)

	if !strings.HasSuffix(rep.ValidatorOutput, "… (truncated)") {
		t.Fatalf("flooded output was not truncated (len %d)", len(rep.ValidatorOutput))
	}
	if len(rep.ValidatorOutput) > validatorOutputCap+len("… (truncated)") {
		t.Errorf("validatorOutput is %d bytes, over the %d cap", len(rep.ValidatorOutput), validatorOutputCap)
	}
}

// TestRunExternalValidatorPropagatesExitCode: the human path is unchanged — the
// validator owns the exit code, so CI gating on it keeps working.
func TestRunExternalValidatorPropagatesExitCode(t *testing.T) {
	tr, _ := newTestTree(t)
	argv := helperValidator(t, 7)

	err := runExternalValidator(strings.Fields(argv), tr.LibDir)
	var ee ExitError
	if !errors.As(err, &ee) || ee.Code != 7 {
		t.Fatalf("runExternalValidator error = %v, want ExitError{7}", err)
	}
	if err := runExternalValidator(strings.Fields(helperValidator(t, 0)), tr.LibDir); err != nil {
		t.Errorf("a passing validator must return nil, got %v", err)
	}
}

// TestCapValidatorOutput covers the truncation boundary directly, including a cut
// that lands mid-rune: the JSON field has to stay valid UTF-8.
func TestCapValidatorOutput(t *testing.T) {
	if got := capValidatorOutput("short"); got != "short" {
		t.Errorf("short output = %q, want it untouched", got)
	}
	atCap := strings.Repeat("a", validatorOutputCap)
	if got := capValidatorOutput(atCap); got != atCap {
		t.Errorf("output exactly at the cap must not be truncated (got %d bytes)", len(got))
	}
	over := capValidatorOutput(strings.Repeat("a", validatorOutputCap+1))
	if !strings.HasSuffix(over, "… (truncated)") {
		t.Errorf("over-cap output = %q, want the truncation marker", over[len(over)-20:])
	}
	// "→" is 3 bytes, so this cut lands inside a rune.
	multi := strings.Repeat("a", validatorOutputCap-1) + strings.Repeat("→", 8)
	if got := capValidatorOutput(multi); !utf8.ValidString(got) {
		t.Errorf("truncating mid-rune produced invalid UTF-8")
	}
}

// TestResolveValidatorIgnoresBlank: an ABCTL_VALIDATOR of only whitespace is not
// a command — it must fall back to the built-in pass, not exec argv[0] of an
// empty slice.
func TestResolveValidatorIgnoresBlank(t *testing.T) {
	t.Setenv("ABCTL_VALIDATOR", "   ")
	if v := resolveValidator(); len(v) != 0 {
		t.Errorf("resolveValidator() = %q, want empty for whitespace", v)
	}
	t.Setenv("ABCTL_VALIDATOR", "")
	if v := resolveValidator(); len(v) != 0 {
		t.Errorf("resolveValidator() = %q, want empty when unset", v)
	}
}

// samePath compares two paths through the symlinks a temp dir may sit behind
// (/var → /private/var on macOS).
func samePath(t *testing.T, a, b string) bool {
	t.Helper()
	ra, err := filepath.EvalSymlinks(a)
	if err != nil {
		ra = a
	}
	rb, err := filepath.EvalSymlinks(b)
	if err != nil {
		rb = b
	}
	return ra == rb
}
