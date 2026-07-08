package ab

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// testClient wires a Client to a test server with a static, non-expiring token
// (no minting / no network to Apple).
func testClient(url string) *Client {
	return &Client{
		apiBase: url + "/",
		ts:      &TokenSource{token: "test-token", expiry: time.Now().Add(time.Hour)},
		hc:      &http.Client{Timeout: 5 * time.Second},
	}
}

func TestListPaginationAnd429Retry(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("missing/wrong bearer: %q", r.Header.Get("Authorization"))
		}
		if calls == 1 { // first call: rate-limited, retry immediately (Retry-After: 0)
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(http.StatusTooManyRequests)
			fmt.Fprint(w, `{"error":"rate"}`)
			return
		}
		if r.URL.Query().Get("cursor") == "" { // page 1 → nextCursor
			fmt.Fprint(w, `{"data":[{"type":"configurations","id":"1","attributes":{"name":"a","type":"CUSTOM_SETTING"}}],"meta":{"paging":{"nextCursor":"C2"}}}`)
			return
		}
		fmt.Fprint(w, `{"data":[{"type":"configurations","id":"2","attributes":{"name":"b","type":"CUSTOM_SETTING"}}],"meta":{"paging":{"nextCursor":""}}}`)
	}))
	defer srv.Close()

	got, err := testClient(srv.URL).ListConfigurations()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d configs, want 2 (pagination should have followed nextCursor)", len(got))
	}
	if calls != 3 {
		t.Fatalf("server calls = %d, want 3 (1 rate-limited retry + 2 pages)", calls)
	}
	if got[0].AttrStr("name") != "a" || got[1].AttrStr("name") != "b" {
		t.Errorf("unexpected names: %q, %q", got[0].AttrStr("name"), got[1].AttrStr("name"))
	}
}

func TestAPIError403Hint(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		fmt.Fprint(w, `{"errors":[{"status":"403"}]}`)
	}))
	defer srv.Close()
	_, err := testClient(srv.URL).ListBlueprints()
	if err == nil {
		t.Fatal("expected error on 403")
	}
	if ae, ok := err.(*APIError); !ok || ae.Status != 403 {
		t.Fatalf("want *APIError 403, got %T %v", err, err)
	}
}

// TestCreateConfiguration checks the POST body, the 201 handling, and that the
// server-assigned id + updatedDateTime are parsed back out of the response.
func TestCreateConfiguration(t *testing.T) {
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/configurations" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		if ct := r.Header.Get("Content-Type"); ct != "application/json" {
			t.Errorf("Content-Type = %q, want application/json", ct)
		}
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(http.StatusCreated)
		fmt.Fprint(w, `{"data":{"type":"configurations","id":"new-id","attributes":{"name":"z","updatedDateTime":"2026-07-04T12:00:00Z"}}}`)
	}))
	defer srv.Close()

	id, updated, err := testClient(srv.URL).CreateConfiguration("z.mobileconfig", "<xml/>", nil)
	if err != nil {
		t.Fatal(err)
	}
	if id != "new-id" || updated != "2026-07-04T12:00:00Z" {
		t.Fatalf("got id=%q updated=%q, want new-id / 2026-07-04T12:00:00Z", id, updated)
	}
	data, _ := gotBody["data"].(map[string]any)
	attrs, _ := data["attributes"].(map[string]any)
	if attrs["type"] != "CUSTOM_SETTING" {
		t.Errorf("create must send type=CUSTOM_SETTING, got %v", attrs["type"])
	}
	csv, _ := attrs["customSettingsValues"].(map[string]any)
	if csv["configurationProfile"] != "<xml/>" {
		t.Errorf("configurationProfile = %v, want raw <xml/>", csv["configurationProfile"])
	}
}

// TestCreateConfigurationRejectsMissingID guards against writing an empty ABMID
// into the baseline: a 2xx whose body carries no resource id must be an error.
func TestCreateConfigurationRejectsMissingID(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusCreated)
		fmt.Fprint(w, `{"data":{"type":"configurations","attributes":{}}}`) // no id
	}))
	defer srv.Close()
	_, _, err := testClient(srv.URL).CreateConfiguration("z", "<x/>", nil)
	if err == nil {
		t.Fatal("expected an error when the create response carries no id")
	}
}

func TestFetchCustomSettingsMetadataOmitsProfileXML(t *testing.T) {
	var gotFields string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.URL.Path != "/configurations" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		gotFields = r.URL.Query().Get("fields[configurations]")
		fmt.Fprint(w, `{"data":[{"type":"configurations","id":"id-1","attributes":{"name":"A.mobileconfig","type":"CUSTOM_SETTING","updatedDateTime":"t1"}},{"type":"configurations","id":"id-2","attributes":{"name":"Native","type":"OTHER"}}]}`)
	}))
	defer srv.Close()

	live, err := testClient(srv.URL).FetchCustomSettingsMetadata(nil)
	if err != nil {
		t.Fatal(err)
	}
	if gotFields != "name,type,updatedDateTime" {
		t.Fatalf("fields = %q, want metadata-only fields", gotFields)
	}
	if len(live) != 1 || live[0].Name != "A.mobileconfig" || live[0].XML != "" || live[0].Hash != "" {
		t.Fatalf("unexpected metadata result: %#v", live)
	}
}

func TestFetchCustomSettingDetailIncludesHash(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.URL.Path != "/configurations/id-1" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		fmt.Fprint(w, `{"data":{"type":"configurations","id":"id-1","attributes":{"name":"A.mobileconfig","type":"CUSTOM_SETTING","updatedDateTime":"t1","customSettingsValues":{"configurationProfile":"<xml/>"}}}}`)
	}))
	defer srv.Close()

	live, err := testClient(srv.URL).FetchCustomSettingDetail("id-1")
	if err != nil {
		t.Fatal(err)
	}
	if live.XML != "<xml/>" || live.ContentHash() == "" || live.Hash != live.ContentHash() {
		t.Fatalf("detail did not include XML/hash: %#v", live)
	}
}

// TestUpdateConfiguration checks the PATCH path and that updatedDateTime is returned.
func TestUpdateConfiguration(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "PATCH" || r.URL.Path != "/configurations/the-id" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		fmt.Fprint(w, `{"data":{"type":"configurations","id":"the-id","attributes":{"updatedDateTime":"2026-07-05T09:30:00Z"}}}`)
	}))
	defer srv.Close()

	updated, err := testClient(srv.URL).UpdateConfiguration("the-id", "z.mobileconfig", "<xml2/>")
	if err != nil {
		t.Fatal(err)
	}
	if updated != "2026-07-05T09:30:00Z" {
		t.Fatalf("updated = %q, want 2026-07-05T09:30:00Z", updated)
	}
}

// TestDeleteConfiguration checks that a 204 is accepted (no error).
func TestDeleteConfiguration(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "DELETE" || r.URL.Path != "/configurations/gone" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	if err := testClient(srv.URL).DeleteConfiguration("gone"); err != nil {
		t.Fatal(err)
	}
}

// TestWriteRetriesOn429 verifies a rate-limited write is resent (safe: 429 means
// the request was rejected before processing).
func TestWriteRetriesOn429(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls++
		if calls == 1 {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.WriteHeader(http.StatusCreated)
		fmt.Fprint(w, `{"data":{"id":"x","attributes":{"updatedDateTime":"t"}}}`)
	}))
	defer srv.Close()
	if _, _, err := testClient(srv.URL).CreateConfiguration("a", "<x/>", nil); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("calls = %d, want 2 (1 rate-limited retry + 1 success)", calls)
	}
}

// appsServer serves a small owned-app catalog on GET /apps: two distinct apps plus a
// duplicate-named pair (to exercise the name-ambiguity path).
func appsServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/apps" {
			t.Errorf("unexpected path %q, want /apps", r.URL.Path)
		}
		fmt.Fprint(w, `{"data":[
			{"type":"apps","id":"361285480","attributes":{"name":"Keynote","bundleId":"com.apple.Keynote"}},
			{"type":"apps","id":"409201541","attributes":{"name":"Pages","bundleId":"com.apple.Pages"}},
			{"type":"apps","id":"111","attributes":{"name":"Twins","bundleId":"com.x.one"}},
			{"type":"apps","id":"222","attributes":{"name":"Twins","bundleId":"com.x.two"}}
		],"meta":{"paging":{"nextCursor":""}}}`)
	}))
}

// TestResolveApp checks id/bundleId win immediately, a unique name resolves, an ambiguous
// name errors, and an unknown value errors.
func TestResolveApp(t *testing.T) {
	srv := appsServer(t)
	defer srv.Close()
	c := testClient(srv.URL)

	cases := []struct {
		arg, wantID string
	}{
		{"361285480", "361285480"},       // by id (adamId)
		{"com.apple.Pages", "409201541"}, // by bundleId
		{"Keynote", "361285480"},         // by unique name
	}
	for _, tc := range cases {
		got, err := c.ResolveApp(tc.arg)
		if err != nil {
			t.Fatalf("ResolveApp(%q): %v", tc.arg, err)
		}
		if got.ID != tc.wantID {
			t.Errorf("ResolveApp(%q).ID = %q, want %q", tc.arg, got.ID, tc.wantID)
		}
	}
	if _, err := c.ResolveApp("Twins"); err == nil {
		t.Error("ResolveApp(ambiguous name) should error, got nil")
	}
	if _, err := c.ResolveApp("Nope"); err == nil {
		t.Error("ResolveApp(unknown) should error, got nil")
	}
}

// TestAddBlueprintMembersApps locks the built-in-MDM Apps & Books write: a POST to
// /blueprints/{id}/relationships/apps carrying {data:[{type:apps,id}]}.
func TestAddBlueprintMembersApps(t *testing.T) {
	var gotBody map[string]any
	var method, path string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method, path = r.Method, r.URL.Path
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	if err := testClient(srv.URL).AddBlueprintMembers("bp-1", "apps", "apps", []string{"361285480"}); err != nil {
		t.Fatal(err)
	}
	if method != "POST" || path != "/blueprints/bp-1/relationships/apps" {
		t.Fatalf("got %s %s, want POST /blueprints/bp-1/relationships/apps", method, path)
	}
	data, _ := gotBody["data"].([]any)
	if len(data) != 1 {
		t.Fatalf("body data len = %d, want 1", len(data))
	}
	m, _ := data[0].(map[string]any)
	if m["type"] != "apps" || m["id"] != "361285480" {
		t.Errorf("member = %v, want {type:apps, id:361285480}", m)
	}
}

// TestWriteErrorMapsAPIError verifies a non-2xx write surfaces a typed *APIError.
func TestWriteErrorMapsAPIError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprint(w, `{"errors":[{"code":"PARAMETER_ERROR.INVALID"}]}`)
	}))
	defer srv.Close()
	_, _, err := testClient(srv.URL).CreateConfiguration("bad", "<x/>", nil)
	if ae, ok := err.(*APIError); !ok || ae.Status != 400 {
		t.Fatalf("want *APIError 400, got %T %v", err, err)
	}
}
