package ab

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
)

// TestGetterPaths locks each single-resource getter to its endpoint path.
func TestGetterPaths(t *testing.T) {
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		if r.Method != "GET" {
			t.Errorf("method = %s, want GET", r.Method)
		}
		fmt.Fprint(w, `{"data":{"type":"t","id":"x","attributes":{"name":"n"}}}`)
	}))
	defer srv.Close()
	c := testClient(srv.URL)

	cases := []struct {
		name string
		call func(string) (*Resource, error)
		want string
	}{
		{"GetDevice", c.GetDevice, "/orgDevices/x"},
		{"GetMDMDevice", c.GetMDMDevice, "/mdmDevices/x"},
		{"GetMDMDeviceDetails", c.GetMDMDeviceDetails, "/mdmDevices/x/details"},
		{"GetUser", c.GetUser, "/users/x"},
		{"GetUserGroup", c.GetUserGroup, "/userGroups/x"},
		{"GetApp", c.GetApp, "/apps/x"},
		{"GetPackage", c.GetPackage, "/packages/x"},
		{"GetMDMServer", c.GetMDMServer, "/mdmServers/x"},
		{"GetOrgDeviceActivity", c.GetOrgDeviceActivity, "/orgDeviceActivities/x"},
	}
	for _, tc := range cases {
		got, err := tc.call("x")
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if got.ID != "x" {
			t.Errorf("%s: id = %q, want x", tc.name, got.ID)
		}
		if gotPath != tc.want {
			t.Errorf("%s path = %q, want %q", tc.name, gotPath, tc.want)
		}
	}
}

// TestDeviceAssignedServer covers the three outcomes: assigned (resource),
// unassigned (Apple 404 → nil, nil — NOT an error), and a real error (403).
func TestDeviceAssignedServer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/orgDevices/ASSIGNED1/assignedServer":
			fmt.Fprint(w, `{"data":{"type":"mdmServers","id":"srv-1","attributes":{"serverName":"HQ"}}}`)
		case "/orgDevices/LOOSE1/assignedServer":
			w.WriteHeader(http.StatusNotFound)
			fmt.Fprint(w, `{"errors":[{"status":"404"}]}`)
		default:
			w.WriteHeader(http.StatusForbidden)
		}
	}))
	defer srv.Close()
	c := testClient(srv.URL)

	got, err := c.DeviceAssignedServer("ASSIGNED1")
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || got.ID != "srv-1" || got.AttrStr("serverName") != "HQ" {
		t.Fatalf("assigned server = %#v, want srv-1/HQ", got)
	}

	got, err = c.DeviceAssignedServer("LOOSE1")
	if err != nil {
		t.Fatalf("unassigned device (404) must not error, got %v", err)
	}
	if got != nil {
		t.Fatalf("unassigned device server = %#v, want nil", got)
	}

	if _, err = c.DeviceAssignedServer("FORBIDDEN1"); err == nil {
		t.Fatal("non-404 error must surface, got nil")
	}
}

// TestDeviceAppleCare checks the coverage list path and decode.
func TestDeviceAppleCare(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/orgDevices/SER123/appleCareCoverage" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		fmt.Fprint(w, `{"data":[
			{"type":"appleCareCoverage","id":"cov-1","attributes":{"status":"ACTIVE","paymentType":"PAID_IN_FULL"}},
			{"type":"appleCareCoverage","id":"cov-2","attributes":{"status":"EXPIRED"}}
		],"meta":{"paging":{"nextCursor":""}}}`)
	}))
	defer srv.Close()

	cov, err := testClient(srv.URL).DeviceAppleCare("SER123")
	if err != nil {
		t.Fatal(err)
	}
	if len(cov) != 2 || cov[0].AttrStr("status") != "ACTIVE" {
		t.Fatalf("unexpected coverage: %#v", cov)
	}
}

// TestListMDMDevices checks the mdmDevices list path.
func TestListMDMDevices(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/mdmDevices" {
			t.Errorf("unexpected path %q, want /mdmDevices", r.URL.Path)
		}
		fmt.Fprint(w, `{"data":[{"type":"mdmDevices","id":"d1","attributes":{"serialNumber":"SER1","deviceName":"Mac"}}],"meta":{"paging":{"nextCursor":""}}}`)
	}))
	defer srv.Close()

	devs, err := testClient(srv.URL).ListMDMDevices()
	if err != nil {
		t.Fatal(err)
	}
	if len(devs) != 1 || devs[0].AttrStr("serialNumber") != "SER1" {
		t.Fatalf("unexpected devices: %#v", devs)
	}
}

// TestUserGroupUserIDsPagination checks the linkage list follows nextCursor
// and flattens the member ids in order.
func TestUserGroupUserIDsPagination(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path != "/userGroups/grp-1/relationships/users" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		if r.URL.Query().Get("cursor") == "" { // page 1 → nextCursor
			fmt.Fprint(w, `{"data":[{"type":"users","id":"u1"},{"type":"users","id":"u2"}],"meta":{"paging":{"nextCursor":"C2"}}}`)
			return
		}
		fmt.Fprint(w, `{"data":[{"type":"users","id":"u3"}],"meta":{"paging":{"nextCursor":""}}}`)
	}))
	defer srv.Close()

	ids, err := testClient(srv.URL).UserGroupUserIDs("grp-1")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"u1", "u2", "u3"}; !reflect.DeepEqual(ids, want) {
		t.Fatalf("ids = %v, want %v", ids, want)
	}
	if calls != 2 {
		t.Fatalf("server calls = %d, want 2 (pagination should have followed nextCursor)", calls)
	}
}

// TestMDMServerDeviceIDs checks the server→devices linkage path and id flattening.
func TestMDMServerDeviceIDs(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/mdmServers/srv-1/relationships/devices" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		fmt.Fprint(w, `{"data":[{"type":"orgDevices","id":"SER1"},{"type":"orgDevices","id":"SER2"}],"meta":{"paging":{"nextCursor":""}}}`)
	}))
	defer srv.Close()

	ids, err := testClient(srv.URL).MDMServerDeviceIDs("srv-1")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"SER1", "SER2"}; !reflect.DeepEqual(ids, want) {
		t.Fatalf("ids = %v, want %v", ids, want)
	}
}

// TestResolveDevice checks id exact wins, serials resolve case-insensitively,
// and an unknown value errors.
func TestResolveDevice(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/orgDevices" {
			t.Errorf("unexpected path %q, want /orgDevices", r.URL.Path)
		}
		fmt.Fprint(w, `{"data":[
			{"type":"orgDevices","id":"dev-1","attributes":{"serialNumber":"C02ABC123"}},
			{"type":"orgDevices","id":"dev-2","attributes":{"serialNumber":"C02DEF456"}}
		],"meta":{"paging":{"nextCursor":""}}}`)
	}))
	defer srv.Close()
	c := testClient(srv.URL)

	cases := []struct {
		arg, wantID string
	}{
		{"dev-1", "dev-1"},     // by id
		{"C02DEF456", "dev-2"}, // by serial
		{"c02abc123", "dev-1"}, // serial is case-insensitive
	}
	for _, tc := range cases {
		got, err := c.ResolveDevice(tc.arg)
		if err != nil {
			t.Fatalf("ResolveDevice(%q): %v", tc.arg, err)
		}
		if got.ID != tc.wantID {
			t.Errorf("ResolveDevice(%q).ID = %q, want %q", tc.arg, got.ID, tc.wantID)
		}
	}
	if _, err := c.ResolveDevice("NOPE"); err == nil {
		t.Error("ResolveDevice(unknown) should error, got nil")
	}
}

// TestResolveUser checks id wins, email/managedAppleAccount resolve
// case-insensitively, a shared email errors, and an unknown value errors.
func TestResolveUser(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/users" {
			t.Errorf("unexpected path %q, want /users", r.URL.Path)
		}
		fmt.Fprint(w, `{"data":[
			{"type":"users","id":"u-1","attributes":{"email":"ana@example.com","managedAppleAccount":"ana@appleid.example.com"}},
			{"type":"users","id":"u-2","attributes":{"email":"dup@example.com"}},
			{"type":"users","id":"u-3","attributes":{"email":"dup@example.com"}}
		],"meta":{"paging":{"nextCursor":""}}}`)
	}))
	defer srv.Close()
	c := testClient(srv.URL)

	cases := []struct {
		arg, wantID string
	}{
		{"u-2", "u-2"},                     // by id
		{"ANA@EXAMPLE.COM", "u-1"},         // email is case-insensitive
		{"ana@appleid.example.com", "u-1"}, // by managed Apple Account
	}
	for _, tc := range cases {
		got, err := c.ResolveUser(tc.arg)
		if err != nil {
			t.Fatalf("ResolveUser(%q): %v", tc.arg, err)
		}
		if got.ID != tc.wantID {
			t.Errorf("ResolveUser(%q).ID = %q, want %q", tc.arg, got.ID, tc.wantID)
		}
	}
	if _, err := c.ResolveUser("dup@example.com"); err == nil {
		t.Error("ResolveUser(shared email) should error, got nil")
	}
	if _, err := c.ResolveUser("nobody@example.com"); err == nil {
		t.Error("ResolveUser(unknown) should error, got nil")
	}
}

// TestResolveUserGroup checks the UUID fast path skips the list call, names
// resolve via the list, and a shared name errors.
func TestResolveUserGroup(t *testing.T) {
	const gid = "12345678-1234-1234-1234-123456789012"
	listCalls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/userGroups/" + gid:
			fmt.Fprint(w, `{"data":{"type":"userGroups","id":"`+gid+`","attributes":{"name":"Sales"}}}`)
		case "/userGroups":
			listCalls++
			fmt.Fprint(w, `{"data":[
				{"type":"userGroups","id":"`+gid+`","attributes":{"name":"Sales"}},
				{"type":"userGroups","id":"grp-2","attributes":{"name":"Twins"}},
				{"type":"userGroups","id":"grp-3","attributes":{"name":"Twins"}}
			],"meta":{"paging":{"nextCursor":""}}}`)
		default:
			t.Errorf("unexpected path %q", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()
	c := testClient(srv.URL)

	got, err := c.ResolveUserGroup(gid)
	if err != nil {
		t.Fatal(err)
	}
	if got.AttrStr("name") != "Sales" {
		t.Errorf("ResolveUserGroup(uuid).name = %q, want Sales", got.AttrStr("name"))
	}
	if listCalls != 0 {
		t.Errorf("uuid resolve made %d list call(s), want 0 (direct GET)", listCalls)
	}
	got, err = c.ResolveUserGroup("Sales")
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != gid {
		t.Errorf("ResolveUserGroup(name).ID = %q, want %q", got.ID, gid)
	}
	if _, err := c.ResolveUserGroup("Twins"); err == nil {
		t.Error("ResolveUserGroup(shared name) should error, got nil")
	}
	if _, err := c.ResolveUserGroup("Nope"); err == nil {
		t.Error("ResolveUserGroup(unknown) should error, got nil")
	}
}

// TestResolvePackage checks id/name resolution and the shared-name error.
func TestResolvePackage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/packages" {
			t.Errorf("unexpected path %q, want /packages", r.URL.Path)
		}
		fmt.Fprint(w, `{"data":[
			{"type":"packages","id":"pkg-1","attributes":{"name":"Munki"}},
			{"type":"packages","id":"pkg-2","attributes":{"name":"Twins"}},
			{"type":"packages","id":"pkg-3","attributes":{"name":"Twins"}}
		],"meta":{"paging":{"nextCursor":""}}}`)
	}))
	defer srv.Close()
	c := testClient(srv.URL)

	for _, tc := range []struct{ arg, wantID string }{{"pkg-2", "pkg-2"}, {"Munki", "pkg-1"}} {
		got, err := c.ResolvePackage(tc.arg)
		if err != nil {
			t.Fatalf("ResolvePackage(%q): %v", tc.arg, err)
		}
		if got.ID != tc.wantID {
			t.Errorf("ResolvePackage(%q).ID = %q, want %q", tc.arg, got.ID, tc.wantID)
		}
	}
	if _, err := c.ResolvePackage("Twins"); err == nil {
		t.Error("ResolvePackage(shared name) should error, got nil")
	}
	if _, err := c.ResolvePackage("Nope"); err == nil {
		t.Error("ResolvePackage(unknown) should error, got nil")
	}
}

// TestResolveMDMServer checks id/serverName resolution and the shared-name error.
func TestResolveMDMServer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/mdmServers" {
			t.Errorf("unexpected path %q, want /mdmServers", r.URL.Path)
		}
		fmt.Fprint(w, `{"data":[
			{"type":"mdmServers","id":"srv-1","attributes":{"serverName":"HQ"}},
			{"type":"mdmServers","id":"srv-2","attributes":{"serverName":"Twins"}},
			{"type":"mdmServers","id":"srv-3","attributes":{"serverName":"Twins"}}
		],"meta":{"paging":{"nextCursor":""}}}`)
	}))
	defer srv.Close()
	c := testClient(srv.URL)

	for _, tc := range []struct{ arg, wantID string }{{"srv-2", "srv-2"}, {"HQ", "srv-1"}} {
		got, err := c.ResolveMDMServer(tc.arg)
		if err != nil {
			t.Fatalf("ResolveMDMServer(%q): %v", tc.arg, err)
		}
		if got.ID != tc.wantID {
			t.Errorf("ResolveMDMServer(%q).ID = %q, want %q", tc.arg, got.ID, tc.wantID)
		}
	}
	if _, err := c.ResolveMDMServer("Twins"); err == nil {
		t.Error("ResolveMDMServer(shared name) should error, got nil")
	}
	if _, err := c.ResolveMDMServer("Nope"); err == nil {
		t.Error("ResolveMDMServer(unknown) should error, got nil")
	}
}
