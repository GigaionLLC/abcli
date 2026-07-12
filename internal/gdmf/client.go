// Package gdmf reads Apple's public software-update catalog.
package gdmf

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	// DefaultURL is Apple's public software-update catalog endpoint.
	DefaultURL = "https://gdmf.apple.com/v2/pmv"
	maxBody    = 16 << 20
)

// Client fetches and conditionally caches Apple's GDMF catalog.
type Client struct {
	URL       string
	HTTP      *http.Client
	CachePath string
	CacheTTL  time.Duration
}

type cacheEntry struct {
	FetchedAt time.Time       `json:"fetchedAt"`
	ETag      string          `json:"etag,omitempty"`
	Body      json.RawMessage `json:"body"`
}

// Catalog is the top-level GDMF response split into managed, public, and RSR sets.
type Catalog struct {
	AssetSets                    map[string][]Release `json:"AssetSets"`
	PublicAssetSets              map[string][]Release `json:"PublicAssetSets"`
	PublicRapidSecurityResponses map[string][]Release `json:"PublicRapidSecurityResponses"`
}

// Release is one Apple software release in a GDMF asset set.
type Release struct {
	ProductVersion   string   `json:"ProductVersion"`
	Build            string   `json:"Build"`
	PostingDate      string   `json:"PostingDate"`
	ExpirationDate   string   `json:"ExpirationDate,omitempty"`
	SupportedDevices []string `json:"SupportedDevices,omitempty"`
}

// Entry is the stable, flattened representation exposed by abctl.
type Entry struct {
	Platform         string   `json:"platform"`
	ProductVersion   string   `json:"productVersion"`
	Build            string   `json:"build"`
	PostingDate      string   `json:"postingDate"`
	ExpirationDate   string   `json:"expirationDate,omitempty"`
	SupportedDevices []string `json:"supportedDevices,omitempty"`
	Catalog          string   `json:"catalog"` // managed|public|rsr
	Expired          bool     `json:"expired"`
}

// New returns a bounded GDMF client. The default endpoint enables persistent caching;
// an override URL is intentionally uncached unless the caller supplies CachePath.
func New(url string) *Client {
	if strings.TrimSpace(url) == "" {
		url = DefaultURL
	}
	c := &Client{URL: url, HTTP: &http.Client{Timeout: 30 * time.Second}, CacheTTL: 6 * time.Hour}
	if url == DefaultURL {
		if dir, err := os.UserCacheDir(); err == nil {
			c.CachePath = filepath.Join(dir, "abctl", "gdmf.json")
		}
	}
	return c
}

// Fetch returns the catalog, using a fresh cache or ETag revalidation when configured.
func (c *Client) Fetch() (*Catalog, error) {
	cached, _ := c.readCache()
	if cached != nil && time.Since(cached.FetchedAt) < c.CacheTTL {
		return decodeCatalog(cached.Body)
	}
	req, err := http.NewRequest(http.MethodGet, c.URL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	if cached != nil && cached.ETag != "" {
		req.Header.Set("If-None-Match", cached.ETag)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode == http.StatusNotModified && cached != nil {
		cached.FetchedAt = time.Now().UTC()
		_ = c.writeCache(cached)
		return decodeCatalog(cached.Body)
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("GDMF HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBody+1))
	if err != nil {
		return nil, err
	}
	if len(body) > maxBody {
		return nil, fmt.Errorf("GDMF catalog exceeds %d MiB", maxBody>>20)
	}
	out, err := decodeCatalog(body)
	if err != nil {
		return nil, err
	}
	_ = c.writeCache(&cacheEntry{FetchedAt: time.Now().UTC(), ETag: resp.Header.Get("ETag"), Body: body})
	return out, nil
}

func decodeCatalog(body []byte) (*Catalog, error) {
	var out Catalog
	dec := json.NewDecoder(bytes.NewReader(body))
	if err := dec.Decode(&out); err != nil {
		return nil, fmt.Errorf("decode GDMF catalog: %w", err)
	}
	return &out, nil
}

func (c *Client) readCache() (*cacheEntry, error) {
	if c.CachePath == "" {
		return nil, nil
	}
	b, err := os.ReadFile(c.CachePath)
	if err != nil {
		return nil, err
	}
	var entry cacheEntry
	if err := json.Unmarshal(b, &entry); err != nil {
		return nil, err
	}
	return &entry, nil
}

func (c *Client) writeCache(entry *cacheEntry) error {
	if c.CachePath == "" {
		return nil
	}
	b, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(c.CachePath), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(c.CachePath), "gdmf-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer func() { _ = os.Remove(tmpPath) }()
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, c.CachePath); err == nil {
		return nil
	}
	// Windows cannot atomically replace an existing destination with Rename.
	if err := os.Remove(c.CachePath); err != nil && !os.IsNotExist(err) {
		return err
	}
	return os.Rename(tmpPath, c.CachePath)
}

// Entries flattens all catalog sets and evaluates expiration relative to now.
func (c *Catalog) Entries(now time.Time) []Entry {
	var out []Entry
	add := func(kind string, sets map[string][]Release) {
		for platform, releases := range sets {
			for _, r := range releases {
				expired := false
				if t, err := time.Parse("2006-01-02", r.ExpirationDate); err == nil {
					expired = t.Before(now.UTC().Truncate(24 * time.Hour))
				}
				out = append(out, Entry{Platform: platform, ProductVersion: r.ProductVersion, Build: r.Build,
					PostingDate: r.PostingDate, ExpirationDate: r.ExpirationDate,
					SupportedDevices: r.SupportedDevices, Catalog: kind, Expired: expired})
			}
		}
	}
	add("managed", c.AssetSets)
	add("public", c.PublicAssetSets)
	add("rsr", c.PublicRapidSecurityResponses)
	return out
}
