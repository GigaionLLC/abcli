package vpp

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestServiceConfigAndAuthHeader: the token is sent as `Authorization: Bearer <token>`,
// and the config (urls + limits) decodes.
func TestServiceConfigAndAuthHeader(t *testing.T) {
	var gotAuth, gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotPath = r.Header.Get("Authorization"), r.URL.Path
		_, _ = w.Write([]byte(`{"urls":{"getAssets":"https://x/assets","associateAssets":"https://x/assets/associate"},
			"limits":{"maxAssets":25,"maxSerialNumbers":1000},"notificationTypes":["ASSET_COUNT"],"locationName":"HQ"}`))
	}))
	defer srv.Close()

	sc, err := NewClient("TOKEN123", srv.URL).ServiceConfig()
	if err != nil {
		t.Fatal(err)
	}
	if gotAuth != "Bearer TOKEN123" {
		t.Errorf("Authorization = %q, want %q", gotAuth, "Bearer TOKEN123")
	}
	if gotPath != "/service/config" {
		t.Errorf("path = %q", gotPath)
	}
	if sc.Limits["maxAssets"] != 25 || sc.URLs["getAssets"] == "" || sc.LocationName != "HQ" {
		t.Errorf("parsed config = %+v", sc)
	}
}

// TestGetAssetsPaginatesAndFilters: pagination accumulates across pages and the filter is
// sent as a query param; the documented asset fields decode.
func TestGetAssetsPaginatesAndFilters(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("productType") != "App" {
			t.Errorf("filter not forwarded: %q", r.URL.RawQuery)
		}
		switch r.URL.Query().Get("pageIndex") {
		case "0":
			_, _ = w.Write([]byte(`{"assets":[{"adamId":"1","productType":"App","pricingParam":"STDQ",
				"availableCount":10,"assignedCount":5,"retiredCount":0,"totalCount":15,
				"deviceAssignable":true,"revocable":true,"supportedPlatforms":["iOS"]}],
				"currentPageIndex":0,"totalPages":2}`))
		case "1":
			_, _ = w.Write([]byte(`{"assets":[{"adamId":"2","productType":"App","availableCount":3,"totalCount":3}],
				"currentPageIndex":1,"totalPages":2}`))
		default:
			t.Errorf("unexpected pageIndex %q", r.URL.Query().Get("pageIndex"))
			_, _ = w.Write([]byte(`{"assets":[],"totalPages":2}`))
		}
	}))
	defer srv.Close()

	assets, err := NewClient("t", srv.URL).GetAssets(AssetFilter{ProductType: "App"})
	if err != nil {
		t.Fatal(err)
	}
	if len(assets) != 2 || assets[0].AdamID != "1" || assets[1].AdamID != "2" {
		t.Fatalf("got %d assets: %+v", len(assets), assets)
	}
	a := assets[0]
	if a.TotalCount != 15 || a.AvailableCount != 10 || a.AssignedCount != 5 || !a.DeviceAssignable ||
		a.PricingParam != "STDQ" || len(a.SupportedPlatforms) != 1 {
		t.Errorf("asset[0] decoded wrong: %+v", a)
	}
}

// TestErrors: HTTP 401 → a clear auth error; an errorNumber inside a 200 body → APIError;
// a missing token → an error before any request.
func TestErrors(t *testing.T) {
	s401 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer s401.Close()
	if _, err := NewClient("t", s401.URL).GetAssets(AssetFilter{}); err == nil || !strings.Contains(err.Error(), "401") {
		t.Errorf("want a 401 error, got %v", err)
	}

	sErr := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"errorNumber":9722,"errorMessage":"Invalid authentication token"}`))
	}))
	defer sErr.Close()
	if _, err := NewClient("t", sErr.URL).ServiceConfig(); err == nil || !strings.Contains(err.Error(), "9722") {
		t.Errorf("want a 9722 error, got %v", err)
	}

	if _, err := NewClient("", "http://unused.invalid").ServiceConfig(); err == nil {
		t.Error("want an error when no token is set")
	}
}

func TestLastPage(t *testing.T) {
	cases := []struct {
		page, total, got int
		want             bool
	}{
		{0, 1, 5, true},  // single page
		{0, 2, 5, false}, // more pages
		{1, 2, 5, true},  // last page
		{0, 3, 0, true},  // empty page → stop
	}
	for _, c := range cases {
		if got := lastPage(c.page, c.total, c.got); got != c.want {
			t.Errorf("lastPage(%d,%d,%d)=%v, want %v", c.page, c.total, c.got, got, c.want)
		}
	}
}
