// Package vpp is a read client for Apple's App and Book Management API v2
// (vpp.itunes.apple.com/mdm/v2) — the Apps & Books license inventory: which apps/books
// the organization owns licenses for, how many are free/assigned, and to whom.
//
// It authenticates with a content token (sToken) sent as `Authorization: Bearer <token>`
// — a DIFFERENT credential from the ES256 client-assertion the Apple Business API
// (internal/ab) uses. The legacy POST /mdm/getVPP…Srv API (sToken in the body) is in
// maintenance mode; this uses v2 only. See docs/vpp-design.md.
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

// DefaultBase is the App and Book Management API v2 root.
const DefaultBase = "https://vpp.itunes.apple.com/mdm/v2"

// maxPages caps pagination so a misbehaving server can't loop forever.
const maxPages = 1000

// Client talks to the VPP v2 API with a static Bearer content token.
type Client struct {
	Token string
	Base  string
	HTTP  *http.Client
}

// NewClient builds a client. base defaults to DefaultBase (override for tests).
func NewClient(token, base string) *Client {
	if base == "" {
		base = DefaultBase
	}
	return &Client{
		Token: token,
		Base:  strings.TrimRight(base, "/"),
		HTTP:  &http.Client{Timeout: 60 * time.Second},
	}
}

// APIError is Apple's error envelope. Some errors also arrive inside an HTTP 200 body.
type APIError struct {
	ErrorNumber  int    `json:"errorNumber"`
	ErrorMessage string `json:"errorMessage"`
}

func (e APIError) Error() string {
	return fmt.Sprintf("VPP API error %d: %s", e.ErrorNumber, e.ErrorMessage)
}

// get performs an authenticated GET and decodes the JSON body into out.
func (c *Client) get(path string, q url.Values, out any) error {
	if c.Token == "" {
		return fmt.Errorf("no VPP content token (set --vpp-token, $AB_VPP_TOKEN, or $AB_VPP_TOKEN_FILE)")
	}
	u := c.Base + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	req.Header.Set("Accept", "application/json")

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode == http.StatusUnauthorized {
		return fmt.Errorf("VPP auth failed (HTTP 401): the content token is missing, invalid, or expired")
	}
	if resp.StatusCode/100 != 2 {
		if e := parseError(body); e != nil {
			return fmt.Errorf("%w (HTTP %d)", e, resp.StatusCode)
		}
		return fmt.Errorf("VPP API HTTP %d: %s", resp.StatusCode, snippet(body))
	}
	// Some errors arrive as a 200 carrying an errorNumber (e.g. 9722 bad auth format).
	if e := parseError(body); e != nil {
		return e
	}
	if out != nil {
		if err := json.Unmarshal(body, out); err != nil {
			return fmt.Errorf("decode VPP response: %w", err)
		}
	}
	return nil
}

func parseError(body []byte) error {
	var e APIError
	if json.Unmarshal(body, &e) == nil && e.ErrorNumber != 0 {
		return e
	}
	return nil
}

func snippet(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return s
}

// --- service config (token validator + endpoint/limits discovery) ---

// ServiceConfig is GET /service/config: the discovered endpoint URLs, limits, etc.
type ServiceConfig struct {
	URLs              map[string]string `json:"urls"`
	Limits            map[string]int    `json:"limits"`
	NotificationTypes []string          `json:"notificationTypes"`
	LocationName      string            `json:"locationName,omitempty"`
	UID               string            `json:"uId,omitempty"`
	TokenExpiration   string            `json:"tokenExpirationDate,omitempty"`
}

// ServiceConfig fetches the service configuration (and thereby validates the token).
func (c *Client) ServiceConfig() (*ServiceConfig, error) {
	var sc ServiceConfig
	if err := c.get("/service/config", nil, &sc); err != nil {
		return nil, err
	}
	return &sc, nil
}

// --- assets (owned apps/books + license counts) ---

// Asset is one owned app or book with its license counts.
type Asset struct {
	AdamID             string   `json:"adamId"`
	ProductType        string   `json:"productType"`  // App | Book
	PricingParam       string   `json:"pricingParam"` // STDQ | PLUS
	AvailableCount     int      `json:"availableCount"`
	AssignedCount      int      `json:"assignedCount"`
	RetiredCount       int      `json:"retiredCount"`
	TotalCount         int      `json:"totalCount"`
	DeviceAssignable   bool     `json:"deviceAssignable"`
	Revocable          bool     `json:"revocable"`
	SupportedPlatforms []string `json:"supportedPlatforms"`
}

type assetsPage struct {
	Assets           []Asset `json:"assets"`
	CurrentPageIndex int     `json:"currentPageIndex"`
	TotalPages       int     `json:"totalPages"`
}

// AssetFilter narrows GetAssets (all optional; empty fields = no filter).
type AssetFilter struct {
	ProductType  string // App | Book
	PricingParam string // STDQ | PLUS
	AdamID       string
}

// GetAssets returns every asset matching the filter, following pagination.
func (c *Client) GetAssets(f AssetFilter) ([]Asset, error) {
	q := url.Values{}
	setNonEmpty(q, "productType", f.ProductType)
	setNonEmpty(q, "pricingParam", f.PricingParam)
	setNonEmpty(q, "adamId", f.AdamID)
	var all []Asset
	for page := 0; page < maxPages; page++ {
		q.Set("pageIndex", strconv.Itoa(page))
		var p assetsPage
		if err := c.get("/assets", q, &p); err != nil {
			return nil, err
		}
		all = append(all, p.Assets...)
		if lastPage(page, p.TotalPages, len(p.Assets)) {
			break
		}
	}
	return all, nil
}

// --- assignments (asset → device/user) ---

// Assignment is one license assignment.
type Assignment struct {
	AdamID       string `json:"adamId"`
	PricingParam string `json:"pricingParam"`
	SerialNumber string `json:"serialNumber,omitempty"`
	ClientUserID string `json:"clientUserId,omitempty"`
}

type assignmentsPage struct {
	Assignments      []Assignment `json:"assignments"`
	CurrentPageIndex int          `json:"currentPageIndex"`
	TotalPages       int          `json:"totalPages"`
}

// AssignmentFilter narrows GetAssignments.
type AssignmentFilter struct {
	AdamID       string
	SerialNumber string
	ClientUserID string
}

// GetAssignments returns every assignment matching the filter, following pagination.
func (c *Client) GetAssignments(f AssignmentFilter) ([]Assignment, error) {
	q := url.Values{}
	setNonEmpty(q, "adamId", f.AdamID)
	setNonEmpty(q, "serialNumber", f.SerialNumber)
	setNonEmpty(q, "clientUserId", f.ClientUserID)
	var all []Assignment
	for page := 0; page < maxPages; page++ {
		q.Set("pageIndex", strconv.Itoa(page))
		var p assignmentsPage
		if err := c.get("/assignments", q, &p); err != nil {
			return nil, err
		}
		all = append(all, p.Assignments...)
		if lastPage(page, p.TotalPages, len(p.Assignments)) {
			break
		}
	}
	return all, nil
}

// --- users (registered VPP users) ---

// User is a registered Managed Apple ID VPP user.
type User struct {
	ClientUserID string `json:"clientUserId"`
	Email        string `json:"email,omitempty"`
	Status       string `json:"status,omitempty"`
	InviteURL    string `json:"inviteUrl,omitempty"`
}

type usersPage struct {
	Users            []User `json:"users"`
	CurrentPageIndex int    `json:"currentPageIndex"`
	TotalPages       int    `json:"totalPages"`
}

// GetUsers returns every registered VPP user, following pagination.
func (c *Client) GetUsers() ([]User, error) {
	q := url.Values{}
	var all []User
	for page := 0; page < maxPages; page++ {
		q.Set("pageIndex", strconv.Itoa(page))
		var p usersPage
		if err := c.get("/users", q, &p); err != nil {
			return nil, err
		}
		all = append(all, p.Users...)
		if lastPage(page, p.TotalPages, len(p.Users)) {
			break
		}
	}
	return all, nil
}

// lastPage reports whether pagination should stop after the page just fetched. Uses the
// REQUESTED page index (reliable) rather than the server's echoed currentPageIndex.
func lastPage(page, totalPages, gotThisPage int) bool {
	return totalPages <= 1 || page+1 >= totalPages || gotThisPage == 0
}

func setNonEmpty(q url.Values, key, val string) {
	if val != "" {
		q.Set(key, val)
	}
}
