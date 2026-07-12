package gdmf

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

func TestFetchAndFlatten(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Accept") != "application/json" {
			t.Errorf("Accept = %q", r.Header.Get("Accept"))
		}
		_, _ = w.Write([]byte(`{"AssetSets":{"macOS":[{"ProductVersion":"15.4","Build":"24E1","PostingDate":"2026-01-01","ExpirationDate":"2026-06-01","SupportedDevices":["Mac1,1"]}]},"PublicAssetSets":{},"PublicRapidSecurityResponses":{}}`))
	}))
	defer s.Close()
	c := New(s.URL)
	cat, err := c.Fetch()
	if err != nil {
		t.Fatal(err)
	}
	got := cat.Entries(time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC))
	if len(got) != 1 || got[0].Platform != "macOS" || got[0].Catalog != "managed" || !got[0].Expired {
		t.Fatalf("entries = %+v", got)
	}
}

func TestConditionalCache(t *testing.T) {
	calls := 0
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 2 {
			if r.Header.Get("If-None-Match") != `"v1"` {
				t.Errorf("If-None-Match = %q", r.Header.Get("If-None-Match"))
			}
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", `"v1"`)
		_, _ = w.Write([]byte(`{"AssetSets":{},"PublicAssetSets":{},"PublicRapidSecurityResponses":{}}`))
	}))
	defer s.Close()
	c := New(s.URL)
	c.CachePath = filepath.Join(t.TempDir(), "gdmf.json")
	c.CacheTTL = 0
	if _, err := c.Fetch(); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Fetch(); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("calls = %d", calls)
	}
	c.CacheTTL = time.Hour
	if _, err := c.Fetch(); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("fresh cache made network call: %d", calls)
	}
}

func TestFetchRejectsHTTPError(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(503) }))
	defer s.Close()
	if _, err := New(s.URL).Fetch(); err == nil {
		t.Fatal("expected error")
	}
}

func TestEntriesTolerateFuturePlatformsRSRAndMissingExpiration(t *testing.T) {
	cat := Catalog{
		PublicRapidSecurityResponses: map[string][]Release{"iOS": {{ProductVersion: "26.1 (a)", Build: "23A1", PostingDate: "2026-07-01"}}},
		PublicAssetSets:              map[string][]Release{"futureOS": {{ProductVersion: "1.0", Build: "1A1", SupportedDevices: []string{"Future1,1"}}}},
	}
	entries := cat.Entries(time.Now())
	if len(entries) != 2 {
		t.Fatalf("entries = %+v", entries)
	}
	foundFuture, foundRSR := false, false
	for _, entry := range entries {
		foundFuture = foundFuture || (entry.Platform == "futureOS" && entry.Catalog == "public")
		foundRSR = foundRSR || (entry.Platform == "iOS" && entry.Catalog == "rsr")
	}
	if !foundFuture || !foundRSR {
		t.Fatalf("future/RSR entries missing: %+v", entries)
	}
	for _, entry := range entries {
		if entry.Expired {
			t.Errorf("missing expiration marked expired: %+v", entry)
		}
	}
}

func TestFetchRejectsMalformedCatalog(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(`{"AssetSets":`)) }))
	defer s.Close()
	if _, err := New(s.URL).Fetch(); err == nil {
		t.Fatal("expected decode error")
	}
}
