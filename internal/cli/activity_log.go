package cli

import (
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"time"
)

const maxActivityLog = 64 << 20

// allowedActivityLogURL permits only HTTPS (Apple's presigned CSV) or loopback HTTP
// (the httptest server); everything else — other schemes, an empty host, non-loopback
// HTTP — is refused. It is applied to the initial URL AND to every redirect hop.
func allowedActivityLogURL(u *url.URL) bool {
	if u == nil || u.Host == "" {
		return false
	}
	return u.Scheme == "https" || (u.Scheme == "http" && u.Hostname() == "127.0.0.1")
}

// downloadActivityLog downloads Apple's presigned result CSV to an explicitly named
// local file. It never overwrites an existing file and removes partial output on failure.
func downloadActivityLog(rawURL, path string) error {
	u, err := url.Parse(rawURL)
	if err != nil || !allowedActivityLogURL(u) {
		return fmt.Errorf("activity result log has an invalid URL")
	}
	// The initial-URL scheme check alone is bypassable because http.Client follows
	// redirects; re-validate every hop so a downgrade to http or an internal host can't
	// defeat the HTTPS/loopback-only rule.
	client := &http.Client{
		Timeout: 60 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return fmt.Errorf("activity result log exceeded the redirect limit")
			}
			if !allowedActivityLogURL(req.URL) {
				return fmt.Errorf("activity result log redirected to an unsupported URL")
			}
			return nil
		},
	}
	resp, err := client.Get(u.String())
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("activity result log HTTP %d", resp.StatusCode)
	}
	if resp.ContentLength > maxActivityLog {
		return fmt.Errorf("activity result log exceeds %d MiB", maxActivityLog>>20)
	}
	path, err = filepath.Abs(path)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	ok := false
	defer func() {
		_ = f.Close()
		if !ok {
			_ = os.Remove(path)
		}
	}()
	n, err := io.Copy(f, io.LimitReader(resp.Body, maxActivityLog+1))
	if err != nil {
		return err
	}
	if n > maxActivityLog {
		return fmt.Errorf("activity result log exceeds %d MiB", maxActivityLog>>20)
	}
	if err := f.Close(); err != nil {
		return err
	}
	ok = true
	fmt.Fprintf(os.Stderr, "downloaded activity result log to %s\n", path)
	return nil
}
