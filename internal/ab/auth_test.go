package ab

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/GigaionLLC/abcli/internal/config"
)

func TestSignES256_Verifies(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	msg := []byte("eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0")
	sigB64, err := signES256(key, msg)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := base64.RawURLEncoding.DecodeString(sigB64)
	if err != nil {
		t.Fatalf("signature not base64url: %v", err)
	}
	if len(raw) != 64 {
		t.Fatalf("ES256 sig length = %d, want 64 (raw R||S)", len(raw))
	}
	r := new(big.Int).SetBytes(raw[:32])
	s := new(big.Int).SetBytes(raw[32:])
	sum := sha256.Sum256(msg)
	if !ecdsa.Verify(&key.PublicKey, sum[:], r, s) {
		t.Error("signature did not verify against the public key")
	}
}

func TestBackoff(t *testing.T) {
	if got := backoff("2", 0); got != 2*time.Second {
		t.Errorf("Retry-After honored: got %v, want 2s", got)
	}
	if got := backoff("", 3); got != 8*time.Second {
		t.Errorf("exponential: got %v, want 8s", got)
	}
	if got := backoff("", 20); got != 30*time.Second {
		t.Errorf("cap: got %v, want 30s", got)
	}
}

// writeKeyFile writes a fresh P-256 key to a temp file in the given PEM encoding and returns
// its path. enc: "sec1", "pkcs8", "two-block" (EC PARAMETERS + SEC1), or "encrypted".
func writeKeyFile(t *testing.T, enc string) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sec1, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	var buf []byte
	switch enc {
	case "sec1":
		buf = pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: sec1})
	case "pkcs8":
		p8, err := x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			t.Fatal(err)
		}
		buf = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: p8})
	case "two-block":
		// A leading EC PARAMETERS block (named-curve OID for P-256) then the SEC1 key —
		// the exact shape OpenSSL/some ABM downloads use that broke first-block-only decode.
		params := []byte{0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07}
		buf = append(pem.EncodeToMemory(&pem.Block{Type: "EC PARAMETERS", Bytes: params}),
			pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: sec1})...)
	case "encrypted":
		buf = pem.EncodeToMemory(&pem.Block{Type: "ENCRYPTED PRIVATE KEY", Bytes: sec1})
	default:
		t.Fatalf("unknown enc %q", enc)
	}
	path := filepath.Join(t.TempDir(), enc+".pem")
	if err := os.WriteFile(path, buf, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadECKey_AcceptsSEC1PKCS8AndTwoBlock(t *testing.T) {
	for _, enc := range []string{"sec1", "pkcs8", "two-block"} {
		t.Run(enc, func(t *testing.T) {
			k, err := loadECKey(writeKeyFile(t, enc))
			if err != nil {
				t.Fatalf("loadECKey(%s) failed: %v", enc, err)
			}
			if k == nil || k.Curve != elliptic.P256() {
				t.Fatalf("loadECKey(%s) returned an unexpected key", enc)
			}
		})
	}
}

func TestLoadECKey_EncryptedGivesConvertHint(t *testing.T) {
	_, err := loadECKey(writeKeyFile(t, "encrypted"))
	if err == nil || !strings.Contains(err.Error(), "encrypted") || !strings.Contains(err.Error(), "pkcs8") {
		t.Fatalf("want an 'encrypted' error with a convert hint, got: %v", err)
	}
}

func TestTokenCachePath_StablePerCredentialAndCwdIndependent(t *testing.T) {
	a := &config.Config{ClientID: "BUSINESSAPI.aaa", TokenURL: "https://t/x"}
	b := &config.Config{ClientID: "BUSINESSAPI.bbb", TokenURL: "https://t/x"}

	p1 := tokenCachePath(a)
	if !filepath.IsAbs(p1) {
		t.Errorf("cache path should be absolute, got %q", p1)
	}
	if !strings.Contains(p1, "abctl") || !strings.HasPrefix(filepath.Base(p1), "token-") {
		t.Errorf("unexpected cache path %q", p1)
	}
	if tokenCachePath(a) != p1 {
		t.Error("cache path must be stable for the same credential")
	}
	if tokenCachePath(b) == p1 {
		t.Error("distinct client_ids must not share a cache file")
	}
	// The whole point of the fix: independent of the current working directory. Chdir to a
	// stable existing dir (not a temp dir we'd have to remove while it's the cwd — Windows
	// refuses that).
	orig, _ := os.Getwd()
	t.Cleanup(func() { _ = os.Chdir(orig) })
	if err := os.Chdir(os.TempDir()); err != nil {
		t.Skip("cannot chdir to verify cwd-independence:", err)
	}
	if tokenCachePath(a) != p1 {
		t.Error("cache path must not depend on cwd")
	}
}

func TestMint_BacksOffOn429ThenCaches(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if atomic.AddInt32(&calls, 1) == 1 {
			w.Header().Set("Retry-After", "0") // retry immediately (keep the test fast)
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte(`{"error":"invalid_request","error_description":"Too many requests"}`))
			return
		}
		_, _ = w.Write([]byte(`{"access_token":"minted-bearer","expires_in":3600}`))
	}))
	defer srv.Close()

	cachePath := filepath.Join(t.TempDir(), "sub", "tok.json") // dir doesn't exist yet
	ts := &TokenSource{
		cfg: &config.Config{
			ClientID: "BUSINESSAPI.x", KeyPath: writeKeyFile(t, "sec1"),
			TokenURL: srv.URL, TokenAud: "aud", Scope: "business.api",
		},
		hc:        srv.Client(),
		cachePath: cachePath,
	}
	tok, err := ts.Token()
	if err != nil {
		t.Fatalf("Token() after a 429 retry: %v", err)
	}
	if tok != "minted-bearer" {
		t.Errorf("token = %q, want minted-bearer", tok)
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Errorf("server calls = %d, want 2 (1 rate-limited + 1 success)", got)
	}
	if _, err := os.Stat(cachePath); err != nil {
		t.Errorf("mint should have created the cache dir + file: %v", err)
	}
}
