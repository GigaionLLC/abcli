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
	EnvDir   string // directory containing the .env (secrets/ paths resolve against it)
}

// Load resolves the Apple Business config. Search order: $ABCTL_ENV, then the
// nearest .env found by walking up from the current working directory; if none is
// found it falls back to the process environment (AB_* variables) — the 12-factor
// path used in CI/CD, where secrets come from the runner environment, not a file.
func Load() (*Config, error) {
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
		Scope:    orDefault(get("AB_SCOPE"), "business.api"),
		TokenURL: orDefault(get("AB_TOKEN_URL"), "https://account.apple.com/auth/oauth2/token"),
		TokenAud: orDefault(get("AB_TOKEN_AUD"), "https://account.apple.com/auth/oauth2/v2/token"),
		APIBase:  orDefault(get("AB_API_BASE"), "https://api-business.apple.com/v1/"),
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
