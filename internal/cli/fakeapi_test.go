package cli

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// A FAKE TENANT for driving whole commands.
//
// Until now `internal/cli` could only test pure helpers, because every command builds a client
// and a client needs credentials. That gap is why the two worst defects of this project's life
// shipped: a write path that recorded the baseline from bytes it SENT rather than bytes Apple
// stored, and a name→id lookup that downloaded every profile in the tenant and blew its command
// budget. Neither is exotic; both are obvious the moment anything actually runs the command.
//
// No live credentials are needed. `config.build` reads AB_TOKEN_URL and AB_API_BASE from the
// process environment, and a locally generated EC key mints a real ES256 assertion against a
// local token endpoint — exactly what internal/ab/auth_test.go already does. So: two httptest
// servers, an env pointed at them, and cobra commands run end to end.
//
// The handler COUNTS requests by path, which is the point. "Does this command work" and "does
// this command make 1 request or 200" are different questions, and only the second one catches
// the class of bug that made `adopt` time out.

// fakeAPI is a stand-in Apple Business API plus its token endpoint.
type fakeAPI struct {
	t *testing.T

	mu sync.Mutex
	// requests counts GET/POST/PATCH/DELETE by "METHOD /path" (query string stripped), so a
	// test can assert on fan-out rather than only on the final answer.
	requests map[string]int
	// configs is the tenant's CUSTOM_SETTING store, keyed by id.
	configs map[string]*fakeAPIConfig
	// dropWrites reproduces the defect the read-back exists for: Apple answers 2xx and keeps
	// the old bytes.
	dropWrites bool

	api   *httptest.Server
	token *httptest.Server
}

type fakeAPIConfig struct {
	ID      string
	Name    string
	XML     string
	Updated string
}

func newFakeAPI(t *testing.T) *fakeAPI {
	t.Helper()
	f := &fakeAPI{t: t, requests: map[string]int{}, configs: map[string]*fakeAPIConfig{}}

	f.token = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"fake-bearer","expires_in":3600}`))
	}))
	f.api = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(func() {
		f.api.Close()
		f.token.Close()
	})
	return f
}

// addConfig seeds a live CUSTOM_SETTING config.
func (f *fakeAPI) addConfig(id, name, xml string) *fakeAPIConfig {
	f.mu.Lock()
	defer f.mu.Unlock()
	c := &fakeAPIConfig{ID: id, Name: name, XML: xml, Updated: "2026-01-01T00:00:00Z"}
	f.configs[id] = c
	return c
}

func (f *fakeAPI) count(key string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.requests[key]
}

// countMatching sums every recorded request whose key contains sub.
func (f *fakeAPI) countMatching(sub string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for k, v := range f.requests {
		if strings.Contains(k, sub) {
			n += v
		}
	}
	return n
}

func (f *fakeAPI) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.requests[r.Method+" "+r.URL.Path]++
	// The list endpoint is asked for profile XML via fields[]; recording that separately is
	// what lets a test assert "this command must not download the whole tenant".
	if r.Method == http.MethodGet && strings.Contains(r.URL.RawQuery, "customSettingsValues") {
		f.requests["GET-with-xml "+r.URL.Path]++
	}
	f.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	path := strings.TrimPrefix(r.URL.Path, "/v1")

	switch {
	case r.Method == http.MethodGet && path == "/configurations":
		f.listConfigs(w, strings.Contains(r.URL.RawQuery, "customSettingsValues"))
	case r.Method == http.MethodGet && strings.HasPrefix(path, "/configurations/"):
		f.getConfig(w, strings.TrimPrefix(path, "/configurations/"))
	case r.Method == http.MethodPatch && strings.HasPrefix(path, "/configurations/"):
		f.patchConfig(w, r, strings.TrimPrefix(path, "/configurations/"))
	case r.Method == http.MethodPost && path == "/configurations":
		f.postConfig(w, r)
	case r.Method == http.MethodGet && path == "/blueprints":
		_, _ = w.Write([]byte(`{"data":[]}`))
	default:
		// Anything unmodelled is a hard failure rather than an empty 200: a silent {} would
		// let a command "pass" a test by taking a path the fake never described.
		w.WriteHeader(http.StatusNotFound)
		_, _ = fmt.Fprintf(w, `{"errors":[{"detail":"fake tenant has no route for %s %s"}]}`, r.Method, path)
	}
}

func (f *fakeAPI) listConfigs(w http.ResponseWriter, withXML bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	items := make([]map[string]any, 0, len(f.configs))
	for _, c := range f.configs {
		attrs := map[string]any{"name": c.Name, "type": "CUSTOM_SETTING", "updatedDateTime": c.Updated}
		if withXML {
			attrs["customSettingsValues"] = map[string]any{"configurationProfile": c.XML}
		}
		items = append(items, map[string]any{"id": c.ID, "type": "configurations", "attributes": attrs})
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"data": items})
}

func (f *fakeAPI) getConfig(w http.ResponseWriter, id string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	c, ok := f.configs[id]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"errors":[{"detail":"no such configuration"}]}`))
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{
		"id": c.ID, "type": "configurations",
		"attributes": map[string]any{
			"name": c.Name, "type": "CUSTOM_SETTING", "updatedDateTime": c.Updated,
			"customSettingsValues": map[string]any{"configurationProfile": c.XML},
		},
	}})
}

// patchConfig models Apple's accept-and-maybe-drop behaviour. With dropWrites the response is a
// clean 2xx and the stored bytes do not move — the exact incident the read-back guards.
func (f *fakeAPI) patchConfig(w http.ResponseWriter, r *http.Request, id string) {
	body, _ := readBody(r)
	f.mu.Lock()
	defer f.mu.Unlock()
	c, ok := f.configs[id]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"errors":[{"detail":"no such configuration"}]}`))
		return
	}
	if !f.dropWrites {
		c.XML = profileFromBody(body)
		c.Updated = "2026-02-02T00:00:00Z"
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{
		"id": c.ID, "type": "configurations",
		"attributes": map[string]any{"name": c.Name, "updatedDateTime": c.Updated},
	}})
}

func (f *fakeAPI) postConfig(w http.ResponseWriter, r *http.Request) {
	body, _ := readBody(r)
	f.mu.Lock()
	defer f.mu.Unlock()
	id := fmt.Sprintf("cfg-%d", len(f.configs)+1)
	name, _ := body["data"].(map[string]any)["attributes"].(map[string]any)["name"].(string)
	c := &fakeAPIConfig{ID: id, Name: name, Updated: "2026-02-02T00:00:00Z"}
	if !f.dropWrites {
		c.XML = profileFromBody(body)
	}
	f.configs[id] = c
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{
		"id": id, "type": "configurations",
		"attributes": map[string]any{"name": name, "updatedDateTime": c.Updated},
	}})
}

func readBody(r *http.Request) (map[string]any, error) {
	var m map[string]any
	err := json.NewDecoder(r.Body).Decode(&m)
	return m, err
}

func profileFromBody(body map[string]any) string {
	data, _ := body["data"].(map[string]any)
	attrs, _ := data["attributes"].(map[string]any)
	csv, _ := attrs["customSettingsValues"].(map[string]any)
	xml, _ := csv["configurationProfile"].(string)
	return xml
}

// use points abctl's config resolution at this fake tenant and gives it a temporary workspace,
// returning the workspace root. Everything is per-test via t.Setenv/t.TempDir.
func (f *fakeAPI) use(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sec1, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	keyPath := filepath.Join(dir, "key.pem")
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: sec1}), 0o600); err != nil {
		t.Fatal(err)
	}

	// An explicit context selector would send abctl to ~/.abctl; the env path keeps the test
	// hermetic. ABCTL_ENV pins the .env (and therefore the gitops tree) inside the temp dir.
	envPath := filepath.Join(dir, ".env")
	env := fmt.Sprintf("AB_CLIENT_ID=BUSINESSAPI.test\nAB_PRIVATE_KEY=%s\nAB_TOKEN_URL=%s\nAB_API_BASE=%s/v1/\n",
		keyPath, f.token.URL, f.api.URL)
	if err := os.WriteFile(envPath, []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ABCTL_ENV", envPath)
	t.Setenv("ABCTL_CONTEXT", "")   // never fall through to the developer's real contexts file
	t.Setenv("ABCTL_APPROVE", "1")  // the gate is tested separately; these tests exercise behaviour
	t.Setenv("XDG_CACHE_HOME", dir) // keep the bearer cache out of the real one
	flagContext = ""
	return dir
}
