// Package ab is the Apple Business API client: ES256 client-assertion auth +
// typed read methods. Auth OMITS the JWT `kid` (verified live: a kid -> invalid_client).
package ab

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/GigaionLLC/abcli/internal/config"
)

// TokenSource mints and caches a bearer token from an ES256 client assertion.
type TokenSource struct {
	cfg       *config.Config
	hc        *http.Client
	cachePath string

	mu     sync.Mutex
	token  string
	expiry time.Time
}

// NewTokenSource caches the bearer in a stable, per-credential file (see tokenCachePath).
func NewTokenSource(cfg *config.Config, hc *http.Client) *TokenSource {
	return &TokenSource{
		cfg:       cfg,
		hc:        hc,
		cachePath: tokenCachePath(cfg),
	}
}

// tokenCachePath returns a stable, writable, per-credential bearer-cache path that does NOT
// depend on the current working directory. The old <EnvDir>/secrets/ location was cwd-relative
// (EnvDir = cwd in context/env mode), so a GUI — which has no control over its cwd and often
// runs from "/" — could never persist the cache and re-minted a token on EVERY call, tripping
// Apple's token-endpoint rate limit (429). The cache lives under the user cache dir (falling
// back to ~/.abctl), keyed by client_id + token URL so distinct tenants never share a bearer.
func tokenCachePath(cfg *config.Config) string {
	base, err := os.UserCacheDir()
	if err != nil || base == "" {
		if home, herr := os.UserHomeDir(); herr == nil {
			base = filepath.Join(home, ".abctl")
		} else {
			base = "." // last resort — still better than a non-writable cwd
		}
	}
	sum := sha256.Sum256([]byte(cfg.ClientID + "\x00" + cfg.TokenURL))
	return filepath.Join(base, "abctl", "token-"+hex.EncodeToString(sum[:8])+".json")
}

type cacheFile struct {
	Token  string    `json:"access_token"`
	Expiry time.Time `json:"expiry"`
}

// Token returns a valid bearer, minting/refreshing if <60s remain.
func (ts *TokenSource) Token() (string, error) {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	if ts.token == "" {
		ts.loadCache()
	}
	if ts.token != "" && time.Until(ts.expiry) > 60*time.Second {
		return ts.token, nil
	}
	if err := ts.mint(); err != nil {
		return "", err
	}
	return ts.token, nil
}

// Expiry returns the cached token expiry (after a successful Token()).
func (ts *TokenSource) Expiry() time.Time { ts.mu.Lock(); defer ts.mu.Unlock(); return ts.expiry }

// Invalidate forces a re-mint on the next Token() (e.g., after a 401).
func (ts *TokenSource) Invalidate() { ts.mu.Lock(); ts.token = ""; ts.mu.Unlock() }

func (ts *TokenSource) loadCache() {
	b, err := os.ReadFile(ts.cachePath)
	if err != nil {
		return
	}
	var c cacheFile
	if json.Unmarshal(b, &c) == nil {
		ts.token, ts.expiry = c.Token, c.Expiry
	}
}

func (ts *TokenSource) saveCache() {
	if err := os.MkdirAll(filepath.Dir(ts.cachePath), 0o700); err != nil {
		return // best-effort: a missing cache dir just means we re-mint next time
	}
	b, _ := json.Marshal(cacheFile{Token: ts.token, Expiry: ts.expiry})
	_ = os.WriteFile(ts.cachePath, b, 0o600)
}

func (ts *TokenSource) mint() error {
	key, err := loadECKey(ts.cfg.KeyPath)
	if err != nil {
		return err
	}
	now := time.Now()
	header := map[string]string{"alg": "ES256", "typ": "JWT"} // OMIT kid — verified: a kid -> invalid_client
	claims := map[string]any{
		"sub": ts.cfg.ClientID,
		"iss": ts.cfg.ClientID,
		"aud": ts.cfg.TokenAud, // must be the /v2/token form
		"iat": now.Unix(),
		"exp": now.Add(179 * 24 * time.Hour).Unix(), // strictly < iat+180d
		"jti": newJTI(),
	}
	hb, _ := json.Marshal(header)
	cb, _ := json.Marshal(claims)
	signingInput := b64(hb) + "." + b64(cb)
	sig, err := signES256(key, []byte(signingInput))
	if err != nil {
		return err
	}
	jwt := signingInput + "." + sig

	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	form.Set("client_id", ts.cfg.ClientID)
	form.Set("client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
	form.Set("client_assertion", jwt)
	form.Set("scope", ts.cfg.Scope)

	// Apple rate-limits the token endpoint (429). The bearer cache makes minting rare, but a
	// burst can still 429 — back off and retry (respecting Retry-After) rather than hard-fail.
	// Progress goes to stderr (never stdout, which carries JSON) so a caller — the CLI or the
	// GUI streaming this — can see what's happening during a slow authenticate.
	fmt.Fprintln(os.Stderr, "authenticating with Apple…")
	for attempt := 0; ; attempt++ {
		req, _ := http.NewRequest("POST", ts.cfg.TokenURL, strings.NewReader(form.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		resp, err := ts.hc.Do(req)
		if err != nil {
			return err
		}
		var tr struct {
			AccessToken string `json:"access_token"`
			ExpiresIn   int    `json:"expires_in"`
			Error       string `json:"error"`
			ErrorDesc   string `json:"error_description"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&tr)
		retryAfter := resp.Header.Get("Retry-After")
		status := resp.StatusCode
		_ = resp.Body.Close()

		if status == 200 && tr.AccessToken != "" {
			ts.token = tr.AccessToken
			ts.expiry = now.Add(time.Duration(tr.ExpiresIn) * time.Second)
			ts.saveCache()
			return nil
		}
		if (status == 429 || status >= 500) && attempt < maxTokenMintRetries {
			d := backoff(retryAfter, attempt)
			fmt.Fprintf(os.Stderr, "authentication rate-limited by Apple (HTTP %d); retrying in %s…\n",
				status, d.Round(time.Second))
			time.Sleep(d)
			continue
		}
		msg := tr.Error
		if tr.ErrorDesc != "" {
			msg += ": " + tr.ErrorDesc
		}
		if msg == "" {
			msg = fmt.Sprintf("HTTP %d", status)
		}
		return fmt.Errorf("token request failed (%d): %s", status, msg)
	}
}

// maxTokenMintRetries bounds the mint backoff so a persistently rate-limited endpoint can't
// hang a caller indefinitely (the GUI also has its own subprocess timeout).
const maxTokenMintRetries = 4

// signES256 produces a JWS ES256 signature: raw R||S, each left-padded to 32 bytes.
func signES256(key *ecdsa.PrivateKey, msg []byte) (string, error) {
	h := sha256.Sum256(msg)
	r, s, err := ecdsa.Sign(rand.Reader, key, h[:])
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(append(padTo(r, 32), padTo(s, 32)...)), nil
}

func padTo(n *big.Int, size int) []byte {
	b := n.Bytes()
	if len(b) >= size {
		return b
	}
	out := make([]byte, size)
	copy(out[size-len(b):], b)
	return out
}

func loadECKey(path string) (*ecdsa.PrivateKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	// Walk EVERY PEM block, not just the first. OpenSSL (and some Apple Business Manager
	// downloads) emit an EC key as two blocks — a leading "EC PARAMETERS" block followed by
	// the "EC PRIVATE KEY". Decoding only the first block grabbed EC PARAMETERS and failed,
	// which is why converting to single-block PKCS#8 "fixed" it. Skip non-key blocks and take
	// the first block that parses as an EC private key (SEC1 or PKCS#8).
	var sawEncrypted, sawBlock bool
	for rest := raw; ; {
		var blk *pem.Block
		blk, rest = pem.Decode(rest)
		if blk == nil {
			break
		}
		sawBlock = true
		if strings.Contains(blk.Type, "ENCRYPTED") {
			sawEncrypted = true
			continue
		}
		if k, err := x509.ParseECPrivateKey(blk.Bytes); err == nil { // SEC1
			return k, nil
		}
		if k, err := x509.ParsePKCS8PrivateKey(blk.Bytes); err == nil { // PKCS#8
			if ek, ok := k.(*ecdsa.PrivateKey); ok {
				return ek, nil
			}
		}
		// otherwise: a non-key block (e.g. "EC PARAMETERS") or a non-EC key — keep scanning
	}
	if sawEncrypted {
		return nil, fmt.Errorf("key %s is encrypted; provide an unencrypted EC key "+
			"(convert with: openssl pkcs8 -topk8 -nocrypt -in %s -out key_pkcs8.pem)", path, path)
	}
	if !sawBlock {
		return nil, fmt.Errorf("no PEM block in %s", path)
	}
	return nil, fmt.Errorf("no unencrypted EC private key (PKCS#8 or SEC1) found in %s", path)
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func newJTI() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return base64.RawURLEncoding.EncodeToString(b[:])
}
