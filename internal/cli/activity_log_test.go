package cli

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestDownloadActivityLog(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("serial,status\nC02,success\n"))
	}))
	defer s.Close()
	path := filepath.Join(t.TempDir(), "result.csv")
	if err := downloadActivityLog(s.URL, path); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil || string(b) != "serial,status\nC02,success\n" {
		t.Fatalf("file = %q, err=%v", b, err)
	}
	if err := downloadActivityLog(s.URL, path); err == nil {
		t.Fatal("expected existing-file refusal")
	}
}

func TestDownloadActivityLogRejectsUnsafeURL(t *testing.T) {
	if err := downloadActivityLog("http://example.com/result.csv", filepath.Join(t.TempDir(), "x")); err == nil {
		t.Fatal("expected non-HTTPS rejection")
	}
}

func TestDownloadActivityLogRejectsRedirectDowngrade(t *testing.T) {
	// The initial URL is allowed loopback http, but it redirects to a non-loopback http
	// host; CheckRedirect must refuse the hop rather than follow the downgrade.
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://example.com/evil.csv", http.StatusFound)
	}))
	defer s.Close()
	path := filepath.Join(t.TempDir(), "x")
	if err := downloadActivityLog(s.URL, path); err == nil {
		t.Fatal("expected redirect-to-unsafe-URL refusal")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("no partial file should remain, stat err=%v", err)
	}
}
