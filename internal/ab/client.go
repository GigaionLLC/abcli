package ab

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/GigaionLLC/abcli/internal/config"
)

// Client is a thin Apple Business API client (read methods for Phase 0).
type Client struct {
	apiBase string
	ts      *TokenSource
	hc      *http.Client
}

// NewClient builds an Apple Business API client from the resolved config.
func NewClient(cfg *config.Config) *Client {
	hc := &http.Client{Timeout: 60 * time.Second}
	return &Client{
		apiBase: strings.TrimRight(cfg.APIBase, "/") + "/",
		ts:      NewTokenSource(cfg, hc),
		hc:      hc,
	}
}

// TokenSource exposes the underlying bearer-token source (for whoami/health checks).
func (c *Client) TokenSource() *TokenSource { return c.ts }

// APIError carries a non-2xx response.
type APIError struct {
	Status int
	Body   string
}

func (e *APIError) Error() string {
	msg := fmt.Sprintf("API %d", e.Status)
	if e.Status == 403 {
		msg += " (forbidden — grant 'View/Manage Blueprints' + 'View/Create device configurations' to the API account, then regenerate the key)"
	}
	if e.Body != "" {
		b := e.Body
		if len(b) > 400 {
			b = b[:400]
		}
		msg += ": " + b
	}
	return msg
}

// Raw issues an authenticated request. For replayable (nil-body) requests it
// re-mints once on 401 and backs off on 429/5xx (respecting Retry-After).
func (c *Client) Raw(method, path string, body io.Reader) (int, []byte, error) {
	u := c.apiBase + strings.TrimLeft(path, "/")
	replayable := body == nil // only GETs (no body to re-send) are safe to retry
	var status int
	var respBody []byte
	for attempt := 0; ; attempt++ {
		tok, err := c.ts.Token()
		if err != nil {
			return 0, nil, err
		}
		req, err := http.NewRequest(method, u, body)
		if err != nil {
			return 0, nil, err
		}
		req.Header.Set("Authorization", "Bearer "+tok)
		req.Header.Set("Accept", "application/json")
		resp, err := c.hc.Do(req)
		if err != nil {
			return 0, nil, err
		}
		respBody, _ = io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		status = resp.StatusCode
		if replayable && attempt < 5 {
			switch status {
			case 401:
				c.ts.Invalidate()
				continue
			case 429, 500, 502, 503, 504:
				time.Sleep(backoff(resp.Header.Get("Retry-After"), attempt))
				continue
			}
		}
		return status, respBody, nil
	}
}

func backoff(retryAfter string, attempt int) time.Duration {
	if retryAfter != "" {
		if secs, err := strconv.Atoi(strings.TrimSpace(retryAfter)); err == nil && secs >= 0 {
			return time.Duration(secs) * time.Second
		}
	}
	d := time.Duration(1<<uint(attempt)) * time.Second // 1,2,4,8,16s
	if d > 30*time.Second {
		d = 30 * time.Second
	}
	return d
}

func (c *Client) getJSON(path string, out any) error {
	st, b, err := c.Raw("GET", path, nil)
	if err != nil {
		return err
	}
	if st < 200 || st >= 300 {
		return &APIError{Status: st, Body: string(b)}
	}
	if out != nil {
		return json.Unmarshal(b, out)
	}
	return nil
}

// Resource is a JSON:API resource object.
type Resource struct {
	Type       string          `json:"type"`
	ID         string          `json:"id"`
	Attributes json.RawMessage `json:"attributes"`
}

// Attr decodes attributes into a generic map (for table output / string fields).
func (r Resource) Attr() map[string]any {
	m := map[string]any{}
	_ = json.Unmarshal(r.Attributes, &m)
	return m
}

// AttrStr returns a string attribute (empty if absent/non-string).
func (r Resource) AttrStr(key string) string {
	if v, ok := r.Attr()[key].(string); ok {
		return v
	}
	return ""
}

type listResp struct {
	Data []Resource `json:"data"`
	Meta struct {
		Paging struct {
			NextCursor string `json:"nextCursor"`
		} `json:"paging"`
	} `json:"meta"`
}

type oneResp struct {
	Data Resource `json:"data"`
}

// list follows cursor pagination (meta.paging.nextCursor), capped at 100 pages.
func (c *Client) list(path string) ([]Resource, error) {
	return c.listWithProgress(path, nil)
}

func (c *Client) listWithProgress(path string, progress func(string)) ([]Resource, error) {
	var all []Resource
	cursor := ""
	for i := 0; i < 100; i++ {
		p := path
		if cursor != "" {
			sep := "?"
			if strings.Contains(p, "?") {
				sep = "&"
			}
			p += sep + "cursor=" + url.QueryEscape(cursor)
		}
		if progress != nil {
			progress(fmt.Sprintf("requesting Apple API page %d: %s", i+1, pathSummary(path)))
		}
		var lr listResp
		if err := c.getJSON(p, &lr); err != nil {
			return nil, err
		}
		all = append(all, lr.Data...)
		if progress != nil {
			progress(fmt.Sprintf("received %d item(s) from Apple API page %d; %d total so far", len(lr.Data), i+1, len(all)))
		}
		if cursor = lr.Meta.Paging.NextCursor; cursor == "" {
			break
		}
	}
	return all, nil
}

func pathSummary(path string) string {
	if before, _, ok := strings.Cut(path, "?"); ok {
		return before
	}
	return path
}

// --- read methods ---

// ListConfigurations returns all configurations (every type; only CUSTOM_SETTING is writable).
func (c *Client) ListConfigurations() ([]Resource, error) { return c.list("configurations?limit=1000") }

// GetConfiguration fetches a single configuration by ID.
func (c *Client) GetConfiguration(id string) (*Resource, error) {
	var o oneResp
	if err := c.getJSON("configurations/"+url.PathEscape(id), &o); err != nil {
		return nil, err
	}
	return &o.Data, nil
}

// ListBlueprints returns all blueprints.
func (c *Client) ListBlueprints() ([]Resource, error) { return c.list("blueprints?limit=1000") }

// GetBlueprint fetches a single blueprint by ID.
func (c *Client) GetBlueprint(id string) (*Resource, error) {
	var o oneResp
	if err := c.getJSON("blueprints/"+url.PathEscape(id), &o); err != nil {
		return nil, err
	}
	return &o.Data, nil
}

// BlueprintRelationship returns linkage IDs for a blueprint member relation.
func (c *Client) BlueprintRelationship(id, rel string) ([]Resource, error) {
	return c.list(fmt.Sprintf("blueprints/%s/relationships/%s?limit=1000", url.PathEscape(id), rel))
}

// LiveBlueprint is a blueprint with the NAMES of its attached configurations.
type LiveBlueprint struct {
	Name    string
	ID      string
	Configs []string // attached config names, sorted; an unresolved id passes through as-is
}

// FetchBlueprints lists all blueprints and resolves each one's attached
// configuration IDs to names via configNameByID. One list call plus one
// relationship call per blueprint (blueprints are few — cheaper than a GET/config).
func (c *Client) FetchBlueprints(configNameByID map[string]string) ([]LiveBlueprint, error) {
	bps, err := c.ListBlueprints()
	if err != nil {
		return nil, err
	}
	out := make([]LiveBlueprint, 0, len(bps))
	for _, bp := range bps {
		links, err := c.BlueprintRelationship(bp.ID, "configurations")
		if err != nil {
			return nil, err
		}
		names := make([]string, 0, len(links))
		for _, l := range links {
			if n, ok := configNameByID[l.ID]; ok {
				names = append(names, n)
			} else {
				names = append(names, l.ID)
			}
		}
		sort.Strings(names)
		out = append(out, LiveBlueprint{Name: bp.AttrStr("name"), ID: bp.ID, Configs: names})
	}
	return out, nil
}

// ListDevices returns the organization's devices (orgDevices).
func (c *Client) ListDevices() ([]Resource, error) { return c.list("orgDevices?limit=1000") }

// ListUsers returns the organization's users (read-only; identity is not API-writable).
func (c *Client) ListUsers() ([]Resource, error) { return c.list("users?limit=1000") }

// ListUserGroups returns the organization's user groups (read-only).
func (c *Client) ListUserGroups() ([]Resource, error) { return c.list("userGroups?limit=1000") }

// ListApps returns the organization's apps (Apps & Books; read-only).
func (c *Client) ListApps() ([]Resource, error) { return c.list("apps?limit=1000") }

// ListPackages returns the organization's packages (custom apps/pkgs; read-only). The
// endpoint is gated by the built-in-device-management permission, so it may 403 for an
// account without it.
func (c *Client) ListPackages() ([]Resource, error) { return c.list("packages?limit=1000") }

// ListMDMServers returns the organization's MDM servers (read-only).
func (c *Client) ListMDMServers() ([]Resource, error) { return c.list("mdmServers?limit=1000") }

// AuditEvents returns audit events between the start and end timestamps (ISO 8601).
func (c *Client) AuditEvents(start, end string) ([]Resource, error) {
	return c.list(fmt.Sprintf("auditEvents?filter[startTimestamp]=%s&filter[endTimestamp]=%s&limit=1000",
		url.QueryEscape(start), url.QueryEscape(end)))
}

// ResolveConfig finds a configuration by id (UUID) or by its `name` attribute.
func (c *Client) ResolveConfig(nameOrID string) (*Resource, error) {
	if looksLikeID(nameOrID) {
		if r, err := c.GetConfiguration(nameOrID); err == nil {
			return r, nil
		}
	}
	cfgs, err := c.ListConfigurations()
	if err != nil {
		return nil, err
	}
	for i := range cfgs {
		if cfgs[i].AttrStr("name") == nameOrID {
			return &cfgs[i], nil
		}
	}
	return nil, fmt.Errorf("configuration %q not found (by name or id)", nameOrID)
}

// ResolveBlueprint finds a blueprint by id (UUID) or by its `name` attribute.
func (c *Client) ResolveBlueprint(nameOrID string) (*Resource, error) {
	if looksLikeID(nameOrID) {
		if r, err := c.GetBlueprint(nameOrID); err == nil {
			return r, nil
		}
	}
	bps, err := c.ListBlueprints()
	if err != nil {
		return nil, err
	}
	for i := range bps {
		if bps[i].AttrStr("name") == nameOrID {
			return &bps[i], nil
		}
	}
	return nil, fmt.Errorf("blueprint %q not found (by name or id)", nameOrID)
}

func looksLikeID(s string) bool { return len(s) == 36 && strings.Count(s, "-") == 4 }

// ResolveApp finds an owned app by id, bundleId, or name. id/bundleId are unique so they
// win immediately; name may collide, so a name that matches >1 app is an error (caller
// should use the id/bundleId). App ids are numeric adamIds, not UUIDs, so looksLikeID never
// matches — always list and match here.
func (c *Client) ResolveApp(nameOrID string) (*Resource, error) {
	apps, err := c.ListApps()
	if err != nil {
		return nil, err
	}
	var byName []*Resource
	for i := range apps {
		if apps[i].ID == nameOrID || apps[i].AttrStr("bundleId") == nameOrID {
			return &apps[i], nil
		}
		if apps[i].AttrStr("name") == nameOrID {
			byName = append(byName, &apps[i])
		}
	}
	switch len(byName) {
	case 1:
		return byName[0], nil
	case 0:
		return nil, fmt.Errorf("app %q not found (by name, bundleId, or id)", nameOrID)
	default:
		return nil, fmt.Errorf("app name %q is ambiguous (%d owned apps share it) — use the app id or bundleId", nameOrID, len(byName))
	}
}

// LiveConfig is a CUSTOM_SETTING configuration with its raw profile XML.
type LiveConfig struct {
	Name    string
	ID      string
	XML     string
	Updated string
}

// FetchCustomSettings returns all CUSTOM_SETTING configs with their raw XML.
// Uses one list call with fields[] (incl. customSettingsValues) to avoid a GET
// per config; falls back to a per-config GET only if the list came back sparse.
func (c *Client) FetchCustomSettings() ([]LiveConfig, error) {
	list, err := c.list("configurations?fields[configurations]=name,type,updatedDateTime,customSettingsValues&limit=1000")
	if err != nil {
		return nil, err
	}
	var out []LiveConfig
	for _, r := range list {
		if !strings.EqualFold(r.AttrStr("type"), "CUSTOM_SETTING") {
			continue
		}
		lc := LiveConfig{Name: r.AttrStr("name"), ID: r.ID, Updated: r.AttrStr("updatedDateTime")}
		if csv, ok := r.Attr()["customSettingsValues"].(map[string]any); ok {
			lc.XML, _ = csv["configurationProfile"].(string)
		}
		if lc.XML == "" { // list was sparse for this one — fetch its detail
			if full, err := c.GetConfiguration(r.ID); err == nil {
				if csv, ok := full.Attr()["customSettingsValues"].(map[string]any); ok {
					lc.XML, _ = csv["configurationProfile"].(string)
				}
			}
		}
		out = append(out, lc)
	}
	return out, nil
}

// FetchCustomSettingsWithProgress returns live CUSTOM_SETTING configurations while reporting
// long-running list and per-profile detail fetch progress through progress.
func (c *Client) FetchCustomSettingsWithProgress(progress func(string)) ([]LiveConfig, error) {
	if progress != nil {
		progress("requesting configurations list from Apple with profile XML fields")
	}
	list, err := c.listWithProgress("configurations?fields[configurations]=name,type,updatedDateTime,customSettingsValues&limit=1000", progress)
	if err != nil {
		return nil, err
	}
	if progress != nil {
		progress(fmt.Sprintf("examining %d configuration record(s) from Apple", len(list)))
	}
	var out []LiveConfig
	missingProfileXML := 0
	for i, r := range list {
		name := r.AttrStr("name")
		if name == "" {
			name = r.ID
		}
		if !strings.EqualFold(r.AttrStr("type"), "CUSTOM_SETTING") {
			if progress != nil {
				progress(fmt.Sprintf("skipping non-CUSTOM_SETTING configuration %d/%d: %s", i+1, len(list), name))
			}
			continue
		}
		if progress != nil {
			progress(fmt.Sprintf("processing CUSTOM_SETTING configuration %d/%d: %s", i+1, len(list), name))
		}
		lc := LiveConfig{Name: r.AttrStr("name"), ID: r.ID, Updated: r.AttrStr("updatedDateTime")}
		if csv, ok := r.Attr()["customSettingsValues"].(map[string]any); ok {
			lc.XML, _ = csv["configurationProfile"].(string)
		}
		if lc.XML == "" { // list was sparse for this one; fetch its detail.
			missingProfileXML++
			if progress != nil {
				if missingProfileXML == 1 {
					progress("Apple's configuration list omitted profile XML; fetching per-profile detail as needed")
				}
				progress(fmt.Sprintf("fetching profile XML detail %d/%d: %s", i+1, len(list), name))
			}
			if full, err := c.GetConfiguration(r.ID); err == nil {
				if csv, ok := full.Attr()["customSettingsValues"].(map[string]any); ok {
					lc.XML, _ = csv["configurationProfile"].(string)
				}
			}
		}
		out = append(out, lc)
	}
	if progress != nil {
		if missingProfileXML > 0 {
			progress(fmt.Sprintf("fetched profile XML detail for %d configuration profile(s)", missingProfileXML))
		}
		progress(fmt.Sprintf("collected %d live CUSTOM_SETTING configuration profile(s)", len(out)))
	}
	return out, nil
}

// --- write methods (Phase 2) ---

// rawWrite sends a JSON body, retrying on 401 (re-mint) and 429 (rate-limited →
// the request was rejected before processing, so a resend is safe). It does NOT
// retry 5xx (a write may have partially applied).
func (c *Client) rawWrite(method, path string, payload any) (int, []byte, error) {
	var body []byte
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return 0, nil, err
		}
		body = b
	}
	for attempt := 0; ; attempt++ {
		tok, err := c.ts.Token()
		if err != nil {
			return 0, nil, err
		}
		var rdr io.Reader
		if body != nil {
			rdr = bytes.NewReader(body)
		}
		req, err := http.NewRequest(method, c.apiBase+strings.TrimLeft(path, "/"), rdr)
		if err != nil {
			return 0, nil, err
		}
		req.Header.Set("Authorization", "Bearer "+tok)
		req.Header.Set("Accept", "application/json")
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		resp, err := c.hc.Do(req)
		if err != nil {
			return 0, nil, err
		}
		rb, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if attempt < 5 {
			switch resp.StatusCode {
			case 401:
				c.ts.Invalidate()
				continue
			case 429:
				time.Sleep(backoff(resp.Header.Get("Retry-After"), attempt))
				continue
			}
		}
		return resp.StatusCode, rb, nil
	}
}

// APIWrite issues an authenticated non-GET request with a JSON body (used by the
// gated `api` passthrough). A nil payload sends no body. It retries 401 (re-mint)
// and 429, never 5xx (a write may have partially applied).
func (c *Client) APIWrite(method, path string, payload any) (int, []byte, error) {
	return c.rawWrite(method, path, payload)
}

// CreateConfiguration POSTs a CUSTOM_SETTING config with the raw .mobileconfig XML.
// It returns the new config's ID and its server-assigned updatedDateTime (parsed
// from the 201 body) so the caller can record an exact baseline with no extra GET.
func (c *Client) CreateConfiguration(name, xml string, platforms []string) (id, updated string, err error) {
	if len(platforms) == 0 {
		platforms = []string{"PLATFORM_MACOS"}
	}
	body := map[string]any{"data": map[string]any{
		"type": "configurations",
		"attributes": map[string]any{
			"name":                   name,
			"type":                   "CUSTOM_SETTING",
			"configuredForPlatforms": platforms,
			"customSettingsValues":   map[string]any{"configurationProfile": xml, "filename": name},
		},
	}}
	st, rb, err := c.rawWrite("POST", "configurations", body)
	if err != nil {
		return "", "", err
	}
	if st != 200 && st != 201 {
		return "", "", &APIError{Status: st, Body: string(rb)}
	}
	var o oneResp
	if err := json.Unmarshal(rb, &o); err != nil {
		return "", "", err
	}
	if o.Data.ID == "" { // a 2xx with no resource id would poison the baseline (empty ABMID)
		return "", "", &APIError{Status: st, Body: "create succeeded but the response carried no resource id: " + string(rb)}
	}
	return o.Data.ID, o.Data.AttrStr("updatedDateTime"), nil
}

// UpdateConfiguration PATCHes a CUSTOM_SETTING config's name + profile XML and
// returns the server-assigned updatedDateTime (parsed from the 200 body).
func (c *Client) UpdateConfiguration(id, name, xml string) (updated string, err error) {
	body := map[string]any{"data": map[string]any{
		"type":       "configurations",
		"id":         id,
		"attributes": map[string]any{"name": name, "customSettingsValues": map[string]any{"configurationProfile": xml, "filename": name}},
	}}
	st, rb, err := c.rawWrite("PATCH", "configurations/"+url.PathEscape(id), body)
	if err != nil {
		return "", err
	}
	if st < 200 || st >= 300 {
		return "", &APIError{Status: st, Body: string(rb)}
	}
	var o oneResp
	if err := json.Unmarshal(rb, &o); err != nil {
		// A 2xx with an unparseable body still means the write succeeded; the
		// caller falls back to a hash-only baseline (empty updatedDateTime).
		return "", nil
	}
	return o.Data.AttrStr("updatedDateTime"), nil
}

// DeleteConfiguration deletes a configuration by id.
func (c *Client) DeleteConfiguration(id string) error {
	st, rb, err := c.rawWrite("DELETE", "configurations/"+url.PathEscape(id), nil)
	if err != nil {
		return err
	}
	if st != 204 && st != 200 {
		return &APIError{Status: st, Body: string(rb)}
	}
	return nil
}

// AddBlueprintMembers / RemoveBlueprintMembers converge a blueprint relation via
// explicit per-member ops (correct whether Apple merges or replaces). Gated in the
// engine — not used by autonomous config-only apply.
func (c *Client) AddBlueprintMembers(bpID, rel, memberType string, ids []string) error {
	return c.blueprintMembers("POST", bpID, rel, memberType, ids)
}

// RemoveBlueprintMembers detaches members (per-member DELETE) from a blueprint relation.
func (c *Client) RemoveBlueprintMembers(bpID, rel, memberType string, ids []string) error {
	return c.blueprintMembers("DELETE", bpID, rel, memberType, ids)
}

func (c *Client) blueprintMembers(method, bpID, rel, memberType string, ids []string) error {
	data := make([]map[string]string, 0, len(ids))
	for _, id := range ids {
		data = append(data, map[string]string{"type": memberType, "id": id})
	}
	st, rb, err := c.rawWrite(method, fmt.Sprintf("blueprints/%s/relationships/%s", url.PathEscape(bpID), rel), map[string]any{"data": data})
	if err != nil {
		return err
	}
	if st != 204 && st != 200 {
		return &APIError{Status: st, Body: string(rb)}
	}
	return nil
}
