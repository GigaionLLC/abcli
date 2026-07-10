package ab

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
)

func boolPtr(b bool) *bool    { return &b }
func strPtr(s string) *string { return &s }

// captureServer records the last method/path/decoded-JSON-body and replies with
// the given status + body.
func captureServer(t *testing.T, status int, respBody string, method, path *string, gotBody *map[string]any) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*method, *path = r.Method, r.URL.Path
		*gotBody = nil
		_ = json.NewDecoder(r.Body).Decode(gotBody)
		w.WriteHeader(status)
		fmt.Fprint(w, respBody)
	}))
}

// TestCreateBlueprint locks the POST body ({data:{type:blueprints, attributes:{name,
// description}}}) and that the created resource is parsed back out of the 201.
func TestCreateBlueprint(t *testing.T) {
	var method, path string
	var gotBody map[string]any
	srv := captureServer(t, http.StatusCreated,
		`{"data":{"type":"blueprints","id":"bp-new","attributes":{"name":"Sales Macs","description":"fleet"}}}`,
		&method, &path, &gotBody)
	defer srv.Close()

	bp, err := testClient(srv.URL).CreateBlueprint("Sales Macs", "fleet")
	if err != nil {
		t.Fatal(err)
	}
	if bp.ID != "bp-new" || bp.AttrStr("name") != "Sales Macs" {
		t.Fatalf("got id=%q name=%q, want bp-new / Sales Macs", bp.ID, bp.AttrStr("name"))
	}
	if method != "POST" || path != "/blueprints" {
		t.Fatalf("got %s %s, want POST /blueprints", method, path)
	}
	want := map[string]any{"data": map[string]any{
		"type":       "blueprints",
		"attributes": map[string]any{"name": "Sales Macs", "description": "fleet"},
	}}
	if !reflect.DeepEqual(gotBody, want) {
		t.Errorf("body = %#v, want %#v", gotBody, want)
	}
}

// TestCreateBlueprintOmitsEmptyDescription guards against sending description:""
// (Apple treats absent and empty differently).
func TestCreateBlueprintOmitsEmptyDescription(t *testing.T) {
	var method, path string
	var gotBody map[string]any
	srv := captureServer(t, http.StatusCreated,
		`{"data":{"type":"blueprints","id":"bp-new","attributes":{"name":"Bare"}}}`,
		&method, &path, &gotBody)
	defer srv.Close()

	if _, err := testClient(srv.URL).CreateBlueprint("Bare", ""); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"data": map[string]any{
		"type":       "blueprints",
		"attributes": map[string]any{"name": "Bare"},
	}}
	if !reflect.DeepEqual(gotBody, want) {
		t.Errorf("body = %#v, want %#v (no description key)", gotBody, want)
	}
}

// TestCreateBlueprintRejectsMissingID mirrors the CreateConfiguration guard: a 2xx
// whose body carries no resource id must be an error.
func TestCreateBlueprintRejectsMissingID(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusCreated)
		fmt.Fprint(w, `{"data":{"type":"blueprints","attributes":{}}}`) // no id
	}))
	defer srv.Close()
	if _, err := testClient(srv.URL).CreateBlueprint("x", ""); err == nil {
		t.Fatal("expected an error when the create response carries no id")
	}
}

// TestUpdateBlueprintPartial checks a name-only PATCH sends exactly {name} (no
// description key) with the id echoed in the body.
func TestUpdateBlueprintPartial(t *testing.T) {
	var method, path string
	var gotBody map[string]any
	srv := captureServer(t, http.StatusOK,
		`{"data":{"type":"blueprints","id":"bp-1","attributes":{"name":"Renamed"}}}`,
		&method, &path, &gotBody)
	defer srv.Close()

	if err := testClient(srv.URL).UpdateBlueprint("bp-1", strPtr("Renamed"), nil); err != nil {
		t.Fatal(err)
	}
	if method != "PATCH" || path != "/blueprints/bp-1" {
		t.Fatalf("got %s %s, want PATCH /blueprints/bp-1", method, path)
	}
	want := map[string]any{"data": map[string]any{
		"type":       "blueprints",
		"id":         "bp-1",
		"attributes": map[string]any{"name": "Renamed"},
	}}
	if !reflect.DeepEqual(gotBody, want) {
		t.Errorf("body = %#v, want %#v", gotBody, want)
	}
}

// TestUpdateBlueprintClearsDescription pins the documented clear path
// (`abctl edit blueprint --description ""`): a non-nil pointer to the empty
// string must send attributes:{description:""} — a future omit-empty cleanup
// (mirroring CreateBlueprint) would silently break the clear.
func TestUpdateBlueprintClearsDescription(t *testing.T) {
	var method, path string
	var gotBody map[string]any
	srv := captureServer(t, http.StatusOK,
		`{"data":{"type":"blueprints","id":"bp-1","attributes":{"name":"Sales"}}}`,
		&method, &path, &gotBody)
	defer srv.Close()

	if err := testClient(srv.URL).UpdateBlueprint("bp-1", nil, strPtr("")); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"data": map[string]any{
		"type":       "blueprints",
		"id":         "bp-1",
		"attributes": map[string]any{"description": ""},
	}}
	if !reflect.DeepEqual(gotBody, want) {
		t.Errorf("body = %#v, want %#v (empty description must be SENT to clear it)", gotBody, want)
	}
}

// TestUpdateBlueprintNoFieldsIsNoOp verifies neither-field-provided makes no API call.
func TestUpdateBlueprintNoFieldsIsNoOp(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls++
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	if err := testClient(srv.URL).UpdateBlueprint("bp-1", nil, nil); err != nil {
		t.Fatal(err)
	}
	if calls != 0 {
		t.Fatalf("calls = %d, want 0 (nothing to PATCH)", calls)
	}
}

// TestDeleteBlueprint checks that a 204 is accepted (no error).
func TestDeleteBlueprint(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "DELETE" || r.URL.Path != "/blueprints/gone" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	if err := testClient(srv.URL).DeleteBlueprint("gone"); err != nil {
		t.Fatal(err)
	}
}

// TestAssignDevices locks the exact orgDeviceActivities POST body: activityType
// plus the mdmServer/devices relationships, and that the activity id comes back.
func TestAssignDevices(t *testing.T) {
	var method, path string
	var gotBody map[string]any
	srv := captureServer(t, http.StatusCreated,
		`{"data":{"type":"orgDeviceActivities","id":"act-1","attributes":{"status":"IN_PROGRESS"}}}`,
		&method, &path, &gotBody)
	defer srv.Close()

	actID, err := testClient(srv.URL).AssignDevices("srv-1", []string{"dev-1", "dev-2"})
	if err != nil {
		t.Fatal(err)
	}
	if actID != "act-1" {
		t.Fatalf("activity id = %q, want act-1", actID)
	}
	if method != "POST" || path != "/orgDeviceActivities" {
		t.Fatalf("got %s %s, want POST /orgDeviceActivities", method, path)
	}
	want := map[string]any{"data": map[string]any{
		"type":       "orgDeviceActivities",
		"attributes": map[string]any{"activityType": "ASSIGN_DEVICES"},
		"relationships": map[string]any{
			"mdmServer": map[string]any{"data": map[string]any{"type": "mdmServers", "id": "srv-1"}},
			"devices": map[string]any{"data": []any{
				map[string]any{"type": "orgDevices", "id": "dev-1"},
				map[string]any{"type": "orgDevices", "id": "dev-2"},
			}},
		},
	}}
	if !reflect.DeepEqual(gotBody, want) {
		t.Errorf("body = %#v, want %#v", gotBody, want)
	}
}

// TestUnassignDevices checks the UNASSIGN_DEVICES activityType and the no-activity-id
// guard (the caller cannot poll without it).
func TestUnassignDevices(t *testing.T) {
	var method, path string
	var gotBody map[string]any
	srv := captureServer(t, http.StatusCreated,
		`{"data":{"type":"orgDeviceActivities","id":"act-2","attributes":{"status":"IN_PROGRESS"}}}`,
		&method, &path, &gotBody)
	defer srv.Close()

	actID, err := testClient(srv.URL).UnassignDevices("srv-1", []string{"dev-1"})
	if err != nil {
		t.Fatal(err)
	}
	if actID != "act-2" {
		t.Fatalf("activity id = %q, want act-2", actID)
	}
	data, _ := gotBody["data"].(map[string]any)
	attrs, _ := data["attributes"].(map[string]any)
	if attrs["activityType"] != "UNASSIGN_DEVICES" {
		t.Errorf("activityType = %v, want UNASSIGN_DEVICES", attrs["activityType"])
	}
}

// TestAssignDevicesRejectsMissingActivityID guards the async-poll handle: a 2xx
// whose body carries no activity id must be an error.
func TestAssignDevicesRejectsMissingActivityID(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusCreated)
		fmt.Fprint(w, `{"data":{"type":"orgDeviceActivities","attributes":{}}}`) // no id
	}))
	defer srv.Close()
	if _, err := testClient(srv.URL).AssignDevices("srv-1", []string{"dev-1"}); err == nil {
		t.Fatal("expected an error when the activity response carries no id")
	}
}

// TestCreateMDMServer locks the POST body: serverName + serverCertificate{name,data}
// + enableMdmDisownFlag when provided.
func TestCreateMDMServer(t *testing.T) {
	var method, path string
	var gotBody map[string]any
	srv := captureServer(t, http.StatusCreated,
		`{"data":{"type":"mdmServers","id":"srv-new","attributes":{"serverName":"Fleet"}}}`,
		&method, &path, &gotBody)
	defer srv.Close()

	pem := []byte("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n")
	got, err := testClient(srv.URL).CreateMDMServer("Fleet", "push-cert", pem, boolPtr(true))
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != "srv-new" {
		t.Fatalf("id = %q, want srv-new", got.ID)
	}
	if method != "POST" || path != "/mdmServers" {
		t.Fatalf("got %s %s, want POST /mdmServers", method, path)
	}
	want := map[string]any{"data": map[string]any{
		"type": "mdmServers",
		"attributes": map[string]any{
			"serverName":          "Fleet",
			"serverCertificate":   map[string]any{"name": "push-cert", "data": string(pem)},
			"enableMdmDisownFlag": true,
		},
	}}
	if !reflect.DeepEqual(gotBody, want) {
		t.Errorf("body = %#v, want %#v", gotBody, want)
	}
}

// TestCreateMDMServerOmitsDisownWhenNil guards against sending an explicit flag
// Apple should default.
func TestCreateMDMServerOmitsDisownWhenNil(t *testing.T) {
	var method, path string
	var gotBody map[string]any
	srv := captureServer(t, http.StatusCreated,
		`{"data":{"type":"mdmServers","id":"srv-new","attributes":{}}}`,
		&method, &path, &gotBody)
	defer srv.Close()

	if _, err := testClient(srv.URL).CreateMDMServer("Fleet", "push-cert", []byte("PEM"), nil); err != nil {
		t.Fatal(err)
	}
	data, _ := gotBody["data"].(map[string]any)
	attrs, _ := data["attributes"].(map[string]any)
	if _, present := attrs["enableMdmDisownFlag"]; present {
		t.Errorf("enableMdmDisownFlag sent with nil disown: %v", attrs["enableMdmDisownFlag"])
	}
}

// TestUpdateMDMServerPartial checks a disown-only PATCH sends exactly
// {enableMdmDisownFlag} (no serverName key).
func TestUpdateMDMServerPartial(t *testing.T) {
	var method, path string
	var gotBody map[string]any
	srv := captureServer(t, http.StatusOK,
		`{"data":{"type":"mdmServers","id":"srv-1","attributes":{}}}`,
		&method, &path, &gotBody)
	defer srv.Close()

	if err := testClient(srv.URL).UpdateMDMServer("srv-1", nil, boolPtr(false)); err != nil {
		t.Fatal(err)
	}
	if method != "PATCH" || path != "/mdmServers/srv-1" {
		t.Fatalf("got %s %s, want PATCH /mdmServers/srv-1", method, path)
	}
	want := map[string]any{"data": map[string]any{
		"type":       "mdmServers",
		"id":         "srv-1",
		"attributes": map[string]any{"enableMdmDisownFlag": false},
	}}
	if !reflect.DeepEqual(gotBody, want) {
		t.Errorf("body = %#v, want %#v", gotBody, want)
	}
}

// TestDeleteMDMServer409Surfaced verifies Apple's devices-still-assigned refusal
// comes back as a typed *APIError carrying the 409 body verbatim.
func TestDeleteMDMServer409Surfaced(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "DELETE" || r.URL.Path != "/mdmServers/busy" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		w.WriteHeader(http.StatusConflict)
		fmt.Fprint(w, `{"errors":[{"code":"ENTITY_ERROR.RELATIONSHIP_EXISTS","detail":"devices are still assigned"}]}`)
	}))
	defer srv.Close()
	err := testClient(srv.URL).DeleteMDMServer("busy")
	ae, ok := err.(*APIError)
	if !ok || ae.Status != 409 {
		t.Fatalf("want *APIError 409, got %T %v", err, err)
	}
	if !json.Valid([]byte(ae.Body)) || ae.Body == "" {
		t.Fatalf("409 body not surfaced verbatim: %q", ae.Body)
	}
}
