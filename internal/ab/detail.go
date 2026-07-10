package ab

import (
	"errors"
	"fmt"
	"net/url"
	"strings"
)

// --- detail reads (Apple Business API v2 surface, Phase A) ---

// getOne fetches a single JSON:API resource ({data:{...}}).
func (c *Client) getOne(path string) (*Resource, error) {
	var o oneResp
	if err := c.getJSON(path, &o); err != nil {
		return nil, err
	}
	return &o.Data, nil
}

// getOneAllow404 is getOne for an optional linked resource: Apple answers 404
// when the link is absent, so a 404 returns (nil, nil) rather than an error.
func (c *Client) getOneAllow404(path string) (*Resource, error) {
	r, err := c.getOne(path)
	var ae *APIError
	if errors.As(err, &ae) && ae.Status == 404 {
		return nil, nil
	}
	return r, err
}

// linkageIDs follows a paginated relationship linkage list ([{type, id}, ...])
// and returns the member ids in API order.
func (c *Client) linkageIDs(path string) ([]string, error) {
	links, err := c.list(path)
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(links))
	for _, l := range links {
		ids = append(ids, l.ID)
	}
	return ids, nil
}

// GetDevice fetches a single organization device (orgDevice) by id.
func (c *Client) GetDevice(id string) (*Resource, error) {
	return c.getOne("orgDevices/" + url.PathEscape(id))
}

// DeviceAssignedServer returns the MDM server an organization device is
// assigned to, or (nil, nil) when the device is unassigned (Apple answers 404).
func (c *Client) DeviceAssignedServer(id string) (*Resource, error) {
	return c.getOneAllow404("orgDevices/" + url.PathEscape(id) + "/assignedServer")
}

// DeviceAppleCare returns an organization device's AppleCare coverage records.
func (c *Client) DeviceAppleCare(id string) ([]Resource, error) {
	return c.list("orgDevices/" + url.PathEscape(id) + "/appleCareCoverage")
}

// ListMDMDevices returns the devices enrolled in built-in MDM (mdmDevices).
func (c *Client) ListMDMDevices() ([]Resource, error) { return c.list("mdmDevices?limit=1000") }

// GetMDMDevice fetches a single built-in-MDM device by id.
func (c *Client) GetMDMDevice(id string) (*Resource, error) {
	return c.getOne("mdmDevices/" + url.PathEscape(id))
}

// GetMDMDeviceDetails fetches a built-in-MDM device's last-reported posture
// (OS version, FileVault/firewall state, storage, lock/erase/lost-mode status).
func (c *Client) GetMDMDeviceDetails(id string) (*Resource, error) {
	return c.getOne("mdmDevices/" + url.PathEscape(id) + "/details")
}

// GetUser fetches a single user by id (users are API-read-only).
func (c *Client) GetUser(id string) (*Resource, error) {
	return c.getOne("users/" + url.PathEscape(id))
}

// GetUserGroup fetches a single user group by id (read-only).
func (c *Client) GetUserGroup(id string) (*Resource, error) {
	return c.getOne("userGroups/" + url.PathEscape(id))
}

// UserGroupUserIDs returns the ids of a user group's members (paginated linkage list).
func (c *Client) UserGroupUserIDs(id string) ([]string, error) {
	return c.linkageIDs("userGroups/" + url.PathEscape(id) + "/relationships/users?limit=1000")
}

// GetApp fetches a single owned app (Apps & Books) by id.
func (c *Client) GetApp(id string) (*Resource, error) {
	return c.getOne("apps/" + url.PathEscape(id))
}

// GetPackage fetches a single package (custom app/pkg) by id.
func (c *Client) GetPackage(id string) (*Resource, error) {
	return c.getOne("packages/" + url.PathEscape(id))
}

// GetMDMServer fetches a single MDM server by id.
func (c *Client) GetMDMServer(id string) (*Resource, error) {
	return c.getOne("mdmServers/" + url.PathEscape(id))
}

// MDMServerDeviceIDs returns the orgDevice ids assigned to an MDM server
// (paginated linkage list).
func (c *Client) MDMServerDeviceIDs(id string) ([]string, error) {
	return c.linkageIDs("mdmServers/" + url.PathEscape(id) + "/relationships/devices?limit=1000")
}

// GetOrgDeviceActivity fetches a device-management activity (assign/unassign job) by id.
func (c *Client) GetOrgDeviceActivity(id string) (*Resource, error) {
	return c.getOne("orgDeviceActivities/" + url.PathEscape(id))
}

// --- resolvers (name/serial/email → resource, mirroring ResolveConfig/ResolveApp) ---

// ResolveDevice finds an organization device by id or serial number (serials
// compare case-insensitively). Device ids are serial-shaped, not UUIDs, so
// looksLikeID never matches — always list and match here.
func (c *Client) ResolveDevice(serialOrID string) (*Resource, error) {
	devs, err := c.ListDevices()
	if err != nil {
		return nil, err
	}
	var bySerial []*Resource
	for i := range devs {
		if devs[i].ID == serialOrID {
			return &devs[i], nil
		}
		if strings.EqualFold(devs[i].AttrStr("serialNumber"), serialOrID) {
			bySerial = append(bySerial, &devs[i])
		}
	}
	switch len(bySerial) {
	case 1:
		return bySerial[0], nil
	case 0:
		return nil, fmt.Errorf("device %q not found (by serial number or id)", serialOrID)
	default:
		return nil, fmt.Errorf("device serial %q is ambiguous (%d devices share it) — use the device id", serialOrID, len(bySerial))
	}
}

// ResolveUser finds a user by id, email, or managed Apple Account (addresses
// compare case-insensitively). id is unique so it wins immediately; an address
// that matches >1 user is an error (caller should use the id).
func (c *Client) ResolveUser(emailOrID string) (*Resource, error) {
	if looksLikeID(emailOrID) {
		if r, err := c.GetUser(emailOrID); err == nil {
			return r, nil
		}
	}
	users, err := c.ListUsers()
	if err != nil {
		return nil, err
	}
	var byEmail []*Resource
	for i := range users {
		if users[i].ID == emailOrID {
			return &users[i], nil
		}
		if strings.EqualFold(users[i].AttrStr("email"), emailOrID) ||
			strings.EqualFold(users[i].AttrStr("managedAppleAccount"), emailOrID) {
			byEmail = append(byEmail, &users[i])
		}
	}
	switch len(byEmail) {
	case 1:
		return byEmail[0], nil
	case 0:
		return nil, fmt.Errorf("user %q not found (by email, managed Apple Account, or id)", emailOrID)
	default:
		return nil, fmt.Errorf("user email %q is ambiguous (%d users share it) — use the user id", emailOrID, len(byEmail))
	}
}

// ResolveUserGroup finds a user group by id or by its `name` attribute; a name
// shared by >1 group is an error (caller should use the group id).
func (c *Client) ResolveUserGroup(nameOrID string) (*Resource, error) {
	if looksLikeID(nameOrID) {
		if r, err := c.GetUserGroup(nameOrID); err == nil {
			return r, nil
		}
	}
	groups, err := c.ListUserGroups()
	if err != nil {
		return nil, err
	}
	var byName []*Resource
	for i := range groups {
		if groups[i].ID == nameOrID {
			return &groups[i], nil
		}
		if groups[i].AttrStr("name") == nameOrID {
			byName = append(byName, &groups[i])
		}
	}
	switch len(byName) {
	case 1:
		return byName[0], nil
	case 0:
		return nil, fmt.Errorf("user group %q not found (by name or id)", nameOrID)
	default:
		return nil, fmt.Errorf("user group name %q is ambiguous (%d groups share it) — use the group id", nameOrID, len(byName))
	}
}

// ResolvePackage finds a package by id or by its `name` attribute; a name
// shared by >1 package is an error (caller should use the package id).
func (c *Client) ResolvePackage(nameOrID string) (*Resource, error) {
	if looksLikeID(nameOrID) {
		if r, err := c.GetPackage(nameOrID); err == nil {
			return r, nil
		}
	}
	pkgs, err := c.ListPackages()
	if err != nil {
		return nil, err
	}
	var byName []*Resource
	for i := range pkgs {
		if pkgs[i].ID == nameOrID {
			return &pkgs[i], nil
		}
		if pkgs[i].AttrStr("name") == nameOrID {
			byName = append(byName, &pkgs[i])
		}
	}
	switch len(byName) {
	case 1:
		return byName[0], nil
	case 0:
		return nil, fmt.Errorf("package %q not found (by name or id)", nameOrID)
	default:
		return nil, fmt.Errorf("package name %q is ambiguous (%d packages share it) — use the package id", nameOrID, len(byName))
	}
}

// ResolveMDMServer finds an MDM server by id or by its `serverName` attribute;
// a name shared by >1 server is an error (caller should use the server id).
func (c *Client) ResolveMDMServer(nameOrID string) (*Resource, error) {
	if looksLikeID(nameOrID) {
		if r, err := c.GetMDMServer(nameOrID); err == nil {
			return r, nil
		}
	}
	servers, err := c.ListMDMServers()
	if err != nil {
		return nil, err
	}
	var byName []*Resource
	for i := range servers {
		if servers[i].ID == nameOrID {
			return &servers[i], nil
		}
		if servers[i].AttrStr("serverName") == nameOrID {
			byName = append(byName, &servers[i])
		}
	}
	switch len(byName) {
	case 1:
		return byName[0], nil
	case 0:
		return nil, fmt.Errorf("MDM server %q not found (by name or id)", nameOrID)
	default:
		return nil, fmt.Errorf("MDM server name %q is ambiguous (%d servers share it) — use the server id", nameOrID, len(byName))
	}
}
