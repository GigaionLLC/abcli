package vpp

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// DefaultLookupBase is Apple's PUBLIC iTunes lookup API — no auth — which resolves an App
// Store id (the VPP `adamId`) to its human name. VPP's own asset response carries only
// adamIds; this fills in names so `vpp assets` reads like "Keynote", not "409183694".
const DefaultLookupBase = "https://itunes.apple.com/lookup"

// Lookup resolves adamId → name via the public iTunes lookup API.
type Lookup struct {
	Base string
	HTTP *http.Client
}

// NewLookup builds a name resolver. base defaults to DefaultLookupBase (override for tests
// via $AB_ITUNES_BASE).
func NewLookup(base string) *Lookup {
	if base == "" {
		base = DefaultLookupBase
	}
	return &Lookup{Base: base, HTTP: &http.Client{Timeout: 30 * time.Second}}
}

type lookupResponse struct {
	ResultCount int `json:"resultCount"`
	Results     []struct {
		TrackID   int64  `json:"trackId"`
		TrackName string `json:"trackName"`
	} `json:"results"`
}

// Names resolves adamIds to names (best-effort). Missing/unresolvable ids are simply
// absent from the returned map; a batch that fails returns whatever resolved plus the
// error, so callers can degrade gracefully (show ids without names).
func (l *Lookup) Names(ids []string) (map[string]string, error) {
	out := make(map[string]string, len(ids))
	const batch = 150 // keep the id list (and URL) a sane length
	for i := 0; i < len(ids); i += batch {
		end := i + batch
		if end > len(ids) {
			end = len(ids)
		}
		if err := l.lookupChunk(ids[i:end], out); err != nil {
			return out, err
		}
	}
	return out, nil
}

func (l *Lookup) lookupChunk(ids []string, out map[string]string) error {
	q := url.Values{}
	q.Set("id", strings.Join(ids, ",")) // lookup by id returns the item regardless of type
	resp, err := l.HTTP.Get(l.Base + "?" + q.Encode())
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("iTunes lookup HTTP %d", resp.StatusCode)
	}
	var lr lookupResponse
	if err := json.Unmarshal(body, &lr); err != nil {
		return fmt.Errorf("decode iTunes lookup: %w", err)
	}
	for _, r := range lr.Results {
		if r.TrackName != "" {
			out[strconv.FormatInt(r.TrackID, 10)] = r.TrackName
		}
	}
	return nil
}
