// Package ab is the Apple Business API client: ES256 client-assertion auth +
// typed read methods. Auth OMITS the JWT `kid` (verified live: a kid -> invalid_client).
package ab

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
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

// NewTokenSource caches the bearer at <EnvDir>/secrets/.token-cache.json (gitignored).
func NewTokenSource(cfg *config.Config, hc *http.Client) *TokenSource {
	return &TokenSource{
		cfg:       cfg,
		hc:        hc,
		cachePath: filepath.Join(cfg.EnvDir, "secrets", ".token-cache.json"),
	}
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

	req, _ := http.NewRequest("POST", ts.cfg.TokenURL, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := ts.hc.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	var tr struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
		Error       string `json:"error"`
		ErrorDesc   string `json:"error_description"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&tr)
	if resp.StatusCode != 200 || tr.AccessToken == "" {
		msg := tr.Error
		if tr.ErrorDesc != "" {
			msg += ": " + tr.ErrorDesc
		}
		if msg == "" {
			msg = resp.Status
		}
		return fmt.Errorf("token request failed (%d): %s", resp.StatusCode, msg)
	}
	ts.token = tr.AccessToken
	ts.expiry = now.Add(time.Duration(tr.ExpiresIn) * time.Second)
	ts.saveCache()
	return nil
}

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
	blk, _ := pem.Decode(raw)
	if blk == nil {
		return nil, fmt.Errorf("no PEM block in %s", path)
	}
	if strings.Contains(blk.Type, "ENCRYPTED") {
		return nil, fmt.Errorf("key %s is encrypted; provide an unencrypted PKCS#8/SEC1 EC key", path)
	}
	if k, err := x509.ParseECPrivateKey(blk.Bytes); err == nil { // SEC1
		return k, nil
	}
	if k, err := x509.ParsePKCS8PrivateKey(blk.Bytes); err == nil { // PKCS#8
		if ek, ok := k.(*ecdsa.PrivateKey); ok {
			return ek, nil
		}
		return nil, fmt.Errorf("PKCS#8 key in %s is not EC", path)
	}
	return nil, fmt.Errorf("could not parse EC private key in %s (need unencrypted PKCS#8 or SEC1)", path)
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func newJTI() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return base64.RawURLEncoding.EncodeToString(b[:])
}
