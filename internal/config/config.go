// Package config loads the Apple Business API settings from the gitignored .env.
package config

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Config is the resolved Apple Business API configuration.
type Config struct {
	ClientID string
	KeyPath  string // absolute path to the unencrypted EC private key (PKCS#8 or SEC1)
	Scope    string
	TokenURL string
	TokenAud string
	APIBase  string
	EnvDir   string // base dir the gitops tree + secrets/ paths resolve against
}

// Default Apple Business endpoints/scope (used when unset in a context/.env/env).
const (
	DefaultScope    = "business.api"
	DefaultTokenURL = "https://account.apple.com/auth/oauth2/token"
	DefaultTokenAud = "https://account.apple.com/auth/oauth2/v2/token"
	DefaultAPIBase  = "https://api-business.apple.com/v1/"
)

// Load resolves config with no explicit context selector.
func Load() (*Config, error) { return Resolve("") }

// Resolve resolves the Apple Business config. Precedence: (1) a named connection
// context — the explicit selector, else $ABCTL_CONTEXT, else the active context in
// ~/.abctl/contexts.yaml; then (2) $ABCTL_ENV / the nearest .env walking up from the
// cwd; then (3) the process environment (AB_* — the 12-factor CI path).
func Resolve(explicitContext string) (*Config, error) {
	if cfg, used, err := loadFromContext(explicitContext); used || err != nil {
		return cfg, err
	}
	return loadFromEnv()
}

func loadFromEnv() (*Config, error) {
	path, err := findEnv()
	if err != nil {
		// No .env file — read AB_* from the process environment. Relative key paths
		// and the gitops tree resolve against the current working directory.
		dir, _ := os.Getwd()
		return build(os.Getenv, dir, "environment")
	}
	m, err := parseEnv(path)
	if err != nil {
		return nil, err
	}
	return build(func(k string) string { return m[k] }, filepath.Dir(path), path)
}

// build assembles a Config from a key getter (a .env map or os.Getenv). dir is the
// directory relative key paths / the gitops tree resolve against; src names the
// source for error messages.
func build(get func(string) string, dir, src string) (*Config, error) {
	c := &Config{
		ClientID: get("AB_CLIENT_ID"),
		Scope:    orDefault(get("AB_SCOPE"), DefaultScope),
		TokenURL: orDefault(get("AB_TOKEN_URL"), DefaultTokenURL),
		TokenAud: orDefault(get("AB_TOKEN_AUD"), DefaultTokenAud),
		APIBase:  orDefault(get("AB_API_BASE"), DefaultAPIBase),
		EnvDir:   dir,
	}
	if c.ClientID == "" {
		return nil, fmt.Errorf("AB_CLIENT_ID not set (%s)", src)
	}
	kp := get("AB_PRIVATE_KEY")
	if kp == "" {
		return nil, fmt.Errorf("AB_PRIVATE_KEY not set (%s)", src)
	}
	if !filepath.IsAbs(kp) && dir != "" {
		kp = filepath.Join(dir, kp)
	}
	c.KeyPath = kp
	return c, nil
}

func findEnv() (string, error) {
	if p := os.Getenv("ABCTL_ENV"); p != "" {
		return p, nil
	}
	cwd, err := os.Getwd()
	if err == nil {
		for d := cwd; ; {
			cand := filepath.Join(d, ".env")
			if fileExists(cand) {
				return cand, nil
			}
			parent := filepath.Dir(d)
			if parent == d {
				break
			}
			d = parent
		}
	}
	return "", fmt.Errorf("could not locate .env (set $ABCTL_ENV or run inside the repo)")
}

func parseEnv(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	m := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.Index(line, "=")
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		if i := strings.Index(val, " #"); i >= 0 { // strip inline comment
			val = strings.TrimSpace(val[:i])
		}
		val = strings.Trim(val, `"'`)
		m[key] = val
	}
	return m, sc.Err()
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return v
}
