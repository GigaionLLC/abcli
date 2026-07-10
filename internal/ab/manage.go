package ab

import (
	"encoding/json"
	"net/url"
)

// --- write methods (Phase A: blueprint / MDM-server lifecycle + device assignment) ---
//
// All writes go through the 429-safe rawWrite; every caller is gated in the CLI /
// engine (read-only by default).

// CreateBlueprint POSTs a new blueprint. description is optional (omitted when empty).
// members maps a relationship name (see BlueprintRel) to resolved ABM ids and is
// INLINED in the create request: live testing (2026-07-05, HANDOFF.md) showed Apple
// rejects a member-less create (`409 …MISSING_MEMBERS` / `MISSING_RESOURCES`), so a
// bare POST is only useful if Apple relaxes that — callers should inline what they
// can and surface the 409 verbatim otherwise. Post-create convergence still goes
// through Add/RemoveBlueprintMembers (relationships POST merges additively).
func (c *Client) CreateBlueprint(name, description string, members map[string][]string) (*Resource, error) {
	attrs := map[string]any{"name": name}
	if description != "" {
		attrs["description"] = description
	}
	data := map[string]any{
		"type":       "blueprints",
		"attributes": attrs,
	}
	rels := map[string]any{}
	for rel, ids := range members {
		if len(ids) == 0 {
			continue
		}
		refs := make([]map[string]string, 0, len(ids))
		for _, id := range ids {
			refs = append(refs, map[string]string{"type": rel, "id": id})
		}
		rels[rel] = map[string]any{"data": refs}
	}
	if len(rels) > 0 {
		data["relationships"] = rels
	}
	body := map[string]any{"data": data}
	st, rb, err := c.rawWrite("POST", "blueprints", body)
	if err != nil {
		return nil, err
	}
	if st != 200 && st != 201 {
		return nil, &APIError{Status: st, Body: string(rb)}
	}
	var o oneResp
	if err := json.Unmarshal(rb, &o); err != nil {
		return nil, err
	}
	if o.Data.ID == "" { // a 2xx with no resource id leaves the caller with nothing to reference
		return nil, &APIError{Status: st, Body: "create succeeded but the response carried no resource id: " + string(rb)}
	}
	return &o.Data, nil
}

// UpdateBlueprint PATCHes a blueprint's name and/or description. Only fields whose
// pointer is non-nil are sent; with neither provided it is a no-op (no API call).
func (c *Client) UpdateBlueprint(id string, name, description *string) error {
	attrs := map[string]any{}
	if name != nil {
		attrs["name"] = *name
	}
	if description != nil {
		attrs["description"] = *description
	}
	if len(attrs) == 0 {
		return nil
	}
	body := map[string]any{"data": map[string]any{
		"type":       "blueprints",
		"id":         id,
		"attributes": attrs,
	}}
	st, rb, err := c.rawWrite("PATCH", "blueprints/"+url.PathEscape(id), body)
	if err != nil {
		return err
	}
	if st < 200 || st >= 300 {
		return &APIError{Status: st, Body: string(rb)}
	}
	return nil
}

// DeleteBlueprint deletes a blueprint by id.
func (c *Client) DeleteBlueprint(id string) error {
	st, rb, err := c.rawWrite("DELETE", "blueprints/"+url.PathEscape(id), nil)
	if err != nil {
		return err
	}
	if st != 204 && st != 200 {
		return &APIError{Status: st, Body: string(rb)}
	}
	return nil
}

// AssignDevices POSTs an ASSIGN_DEVICES activity moving deviceIDs (orgDevice ids)
// onto the MDM server. It returns the activity id for status polling
// (GetOrgDeviceActivity) — the assignment completes asynchronously.
func (c *Client) AssignDevices(serverID string, deviceIDs []string) (string, error) {
	return c.deviceActivity("ASSIGN_DEVICES", serverID, deviceIDs)
}

// UnassignDevices POSTs an UNASSIGN_DEVICES activity removing deviceIDs (orgDevice
// ids) from the MDM server. It returns the activity id for status polling.
func (c *Client) UnassignDevices(serverID string, deviceIDs []string) (string, error) {
	return c.deviceActivity("UNASSIGN_DEVICES", serverID, deviceIDs)
}

func (c *Client) deviceActivity(activityType, serverID string, deviceIDs []string) (string, error) {
	devices := make([]map[string]string, 0, len(deviceIDs))
	for _, id := range deviceIDs {
		devices = append(devices, map[string]string{"type": "orgDevices", "id": id})
	}
	body := map[string]any{"data": map[string]any{
		"type":       "orgDeviceActivities",
		"attributes": map[string]any{"activityType": activityType},
		"relationships": map[string]any{
			"mdmServer": map[string]any{"data": map[string]string{"type": "mdmServers", "id": serverID}},
			"devices":   map[string]any{"data": devices},
		},
	}}
	st, rb, err := c.rawWrite("POST", "orgDeviceActivities", body)
	if err != nil {
		return "", err
	}
	if st != 200 && st != 201 {
		return "", &APIError{Status: st, Body: string(rb)}
	}
	var o oneResp
	if err := json.Unmarshal(rb, &o); err != nil {
		return "", err
	}
	if o.Data.ID == "" { // without the activity id the caller cannot poll the async result
		return "", &APIError{Status: st, Body: "activity accepted but the response carried no activity id: " + string(rb)}
	}
	return o.Data.ID, nil
}

// CreateMDMServer POSTs a new MDM server with its push-certificate PEM. disown is
// optional (nil = omit, let Apple default enableMdmDisownFlag). The PEM is sent to
// Apple verbatim and never logged.
func (c *Client) CreateMDMServer(name, certName string, certPEM []byte, disown *bool) (*Resource, error) {
	attrs := map[string]any{
		"serverName":        name,
		"serverCertificate": map[string]any{"name": certName, "data": string(certPEM)},
	}
	if disown != nil {
		attrs["enableMdmDisownFlag"] = *disown
	}
	body := map[string]any{"data": map[string]any{
		"type":       "mdmServers",
		"attributes": attrs,
	}}
	st, rb, err := c.rawWrite("POST", "mdmServers", body)
	if err != nil {
		return nil, err
	}
	if st != 200 && st != 201 {
		return nil, &APIError{Status: st, Body: string(rb)}
	}
	var o oneResp
	if err := json.Unmarshal(rb, &o); err != nil {
		return nil, err
	}
	if o.Data.ID == "" { // a 2xx with no resource id leaves the caller with nothing to reference
		return nil, &APIError{Status: st, Body: "create succeeded but the response carried no resource id: " + string(rb)}
	}
	return &o.Data, nil
}

// UpdateMDMServer PATCHes an MDM server's serverName and/or enableMdmDisownFlag.
// Only fields whose pointer is non-nil are sent; with neither provided it is a
// no-op (no API call).
func (c *Client) UpdateMDMServer(id string, name *string, disown *bool) error {
	attrs := map[string]any{}
	if name != nil {
		attrs["serverName"] = *name
	}
	if disown != nil {
		attrs["enableMdmDisownFlag"] = *disown
	}
	if len(attrs) == 0 {
		return nil
	}
	body := map[string]any{"data": map[string]any{
		"type":       "mdmServers",
		"id":         id,
		"attributes": attrs,
	}}
	st, rb, err := c.rawWrite("PATCH", "mdmServers/"+url.PathEscape(id), body)
	if err != nil {
		return err
	}
	if st < 200 || st >= 300 {
		return &APIError{Status: st, Body: string(rb)}
	}
	return nil
}

// DeleteMDMServer deletes an MDM server by id. Apple refuses (409) while devices
// are still assigned to it — that error is surfaced verbatim so the caller can
// tell the user to unassign first.
func (c *Client) DeleteMDMServer(id string) error {
	st, rb, err := c.rawWrite("DELETE", "mdmServers/"+url.PathEscape(id), nil)
	if err != nil {
		return err
	}
	if st != 204 && st != 200 {
		return &APIError{Status: st, Body: string(rb)}
	}
	return nil
}
