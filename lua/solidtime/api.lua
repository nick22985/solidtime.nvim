-- TODO: fix error stuff make it more easy to figure out when in a iter
local config = require("solidtime.config")
local curl = require("plenary.curl")
local cache = require("solidtime.cache")
local logger = require("solidtime.logger")
local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Replace nil values for explicitly-nullable fields with vim.NIL so that
--- vim.fn.json_encode sends JSON null instead of omitting the key.
--- Only operates on keys present in the `nullable` list.
local function with_nulls(data, nullable)
	if not data then
		return data
	end
	local out = {}
	for k, v in pairs(data) do
		out[k] = v
	end
	for _, key in ipairs(nullable) do
		if out[key] == nil then
			out[key] = vim.NIL
		end
	end
	return out
end

local function build_url(base_url, endpoint, params)
	if not base_url:match("/$") then
		base_url = base_url .. "/"
	end

	if params then
		local query = ""
		local function encode_val(v)
			return tostring(v)
				:gsub("([^%w%-%.%_%~ ])", function(c)
					return string.format("%%%02X", string.byte(c))
				end)
				:gsub(" ", "+")
		end
		for key, value in pairs(params) do
			if type(value) == "table" then
				for _, item in ipairs(value) do
					query = query .. key .. "[]=" .. encode_val(item) .. "&"
				end
			else
				query = query .. key .. "=" .. encode_val(value) .. "&"
			end
		end
		query = query:sub(1, -2)
		endpoint = endpoint .. "?" .. query
		logger.debug(string.format("URL with query params: %s", endpoint))
	end

	return base_url .. endpoint
end

--- Parse a plenary curl response into (err, decoded) used by all callbacks.
local function parse_response(response, endpoint, cache_key, ttl)
	if not response then
		return "No response from server", nil
	end

	logger.debug(string.format("Received response status: %d for URL: %s", response.status, endpoint))

	if response.status == 200 or response.status == 201 then
		local ok, decoded = pcall(vim.json.decode, response.body or "")
		if not ok or decoded == nil then
			local body = response.body or ""
			local err
			if body:match("^<!DOCTYPE") or body:match("^<html") then
				err = "API key invalid or expired — run :SolidTime auth to re-authenticate"
			else
				err = "Invalid JSON response from " .. endpoint .. " (status=200)"
			end
			logger.error(err)
			return err, nil
		end
		if ttl ~= nil and cache_key then
			cache.set_cached_data(cache_key, response.body, ttl)
			logger.debug(string.format("Caching response for key: %s", cache_key))
		end
		return nil, decoded
	elseif response.status == 204 then
		return nil, {}
	elseif response.status == 401 then
		local error_message = "Unauthorized — check your API key (`:SolidTime auth`)"
		logger.error(error_message)
		return "API Error: 401 " .. error_message, nil
	else
		local error_message = "Unknown error"
		if response.body and response.body ~= "" then
			local ok, decoded = pcall(vim.json.decode, response.body)
			if ok and decoded and decoded.message then
				error_message = decoded.message
			else
				error_message = response.body
			end
		end
		logger.error(
			string.format(
				"Error response: %d for URL: %s Response: %s",
				response.status,
				endpoint,
				vim.inspect(response)
			),
			false
		)
		return "API Error: " .. response.status .. " " .. error_message, nil
	end
end

-- ---------------------------------------------------------------------------
-- Core async request  (always non-blocking)
-- ---------------------------------------------------------------------------

---@param endpoint string API endpoint to call
---@param method string HTTP method to use (GET, POST, PATCH, PUT, DELETE)
---@param params table|nil Query parameters
---@param data table|nil Request body (POST/PUT/PATCH)
---@param callback function  function(err, decoded) — always required
---@param ttl number|nil Cache TTL in seconds (nil = no cache)
function M.get_data(endpoint, method, params, data, callback, ttl)
	assert(type(callback) == "function", "solidtime api.get_data: callback is required")

	local cache_key = endpoint .. (params and vim.fn.json_encode(params) or "")

	logger.debug(string.format("Checking cache for key: %s", cache_key))

	if ttl and ttl ~= 0 then
		local cached_data = cache.get_cached_data(cache_key, ttl)
		if cached_data then
			logger.debug(string.format("Cache hit for key: %s. Returning cached data.", cache_key))
			local ok, decoded = pcall(vim.json.decode, cached_data)
			if not ok or decoded == nil then
				logger.warn(string.format("Cache decode failed for key: %s — evicting.", cache_key))
				cache.invalidate_cache(cache_key)
				-- fall through to network request
			else
				vim.schedule(function()
					callback(nil, decoded)
				end)
				return
			end
		end
		logger.debug(string.format("Cache miss for key: %s. Making API request to endpoint: %s", cache_key, endpoint))
	end

	local api_key = config.get().api_key
	local base_url = config.get().api_url

	if not api_key then
		logger.error("API key is not set.")
		vim.schedule(function()
			callback("API key is not set.", nil)
		end)
		return
	end

	local url = build_url(base_url, endpoint, params)
	logger.debug(string.format("Making async %s request to URL: %s", method, url))

	local headers = {
		["Authorization"] = "Bearer " .. api_key,
		["Content-Type"] = "application/json",
	}

	local options = {
		headers = headers,
		raw = { "--location-trusted" },
		callback = vim.schedule_wrap(function(response)
			local err, decoded = parse_response(response, endpoint, cache_key, ttl)
			callback(err, decoded)
		end),
	}

	if data then
		options.body = vim.fn.json_encode(data)
		logger.debug(string.format("Request data: %s", options.body))
	end

	if method == "POST" then
		curl.post(url, options)
	elseif method == "PATCH" then
		curl.patch(url, options)
	elseif method == "PUT" then
		curl.put(url, options)
	elseif method == "DELETE" then
		curl.delete(url, options)
	else
		curl.get(url, options)
	end
end

-- ---------------------------------------------------------------------------
-- Sync wrapper  (blocks with vim.wait — use sparingly, only where unavoidable)
-- ---------------------------------------------------------------------------

---Synchronous variant. Blocks the event loop using vim.wait until the async
---request completes. Only use this in contexts where a callback chain is not
---feasible (e.g. VimLeavePre, is_online check).
---@return any decoded, string|nil err
function M.get_data_sync(endpoint, method, params, data, ttl)
	local done = false
	local result_decoded, result_err

	M.get_data(endpoint, method, params, data, function(err, decoded)
		result_err = err
		result_decoded = decoded
		done = true
	end, ttl)

	vim.wait(10000, function()
		return done
	end, 10)

	return result_decoded, result_err
end

-- ---------------------------------------------------------------------------
-- Public API functions
-- All accept an optional callback.  When callback is provided the call is
-- non-blocking; omitting callback falls back to get_data_sync (blocking).
-- ---------------------------------------------------------------------------

local function wrap(endpoint, method, params, data, callback, ttl)
	if callback then
		M.get_data(endpoint, method, params, data, callback, ttl)
		return nil
	else
		local decoded, err = M.get_data_sync(endpoint, method, params, data, ttl)
		if err then
			return { error = err }
		end
		return decoded
	end
end

function M.fetch_user_data(callback, options)
	local endpoint = "users/me"
	local ttl = options and options.ttl or 0
	return wrap(endpoint, "GET", nil, nil, callback, ttl)
end

---@class apiError
---@field error string Error message

--- Represents a user's membership in an organization.
--- @class UserMembership
--- @field id string Membership ID
--- @field organization table Organization information
--- @field organization.id string Organization ID
--- @field organization.name string Organization name
--- @field organization.currency string Organization currency code
--- @field role string User's role in organization (e.g., "owner")

--- Represents the response containing user membership data.
--- @class UserMembershipsResponse
--- @field data UserMembership[] Array of user membership objects
--- @field error string|nil Error message if request failed

--- Retrieves the user's organization memberships.
---@param callback function|nil
---@return UserMembershipsResponse|apiError|nil
function M.getUserMemberships(callback)
	return wrap("users/me/memberships", "GET", nil, nil, callback, 3600)
end

function M.getUserTimeEntry(callback)
	return wrap("users/me/time-entries/active", "GET", nil, nil, callback, nil)
end

function M.createTimeEntry(organization_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/time-entries"

	if not data.member_id or not data.start then
		local error_msg = "Missing required fields: member_id and start"
		logger.error(error_msg, false)
		if callback then
			vim.schedule(function()
				callback(error_msg, nil)
			end)
			return nil
		else
			return { error = error_msg }
		end
	end

	return wrap(endpoint, "POST", nil, with_nulls(data, { "task_id", "end", "description", "tags" }), callback, nil)
end

---@class updateTimeEntryData
---@field member_id string
---@field project_id string|nil
---@field task_id string|nil
---@field start string|osdate
---@field end string|osdate|nil
---@field billable boolean
---@field description string|nil max 500 characters
---@field tags table|nil

---@param organization_id string
---@param time_entry_id string
---@param data updateTimeEntryData|nil
---@param callback function|nil
function M.updateTimeEntry(organization_id, time_entry_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/time-entries/" .. time_entry_id
	local body = with_nulls(data, { "project_id", "task_id", "end", "description", "tags" })
	return wrap(endpoint, "PUT", nil, body, callback, nil)
end

function M.getOrganization(organization_id, callback)
	local endpoint = "organizations/" .. organization_id
	return wrap(endpoint, "GET", nil, nil, callback, 3600)
end

function M.getOrganizationProjects(organization_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/projects"
	return wrap(endpoint, "GET", nil, nil, callback, 3600)
end

---@class createProjectData
---@field name string
---@field color string Hex color string (e.g. "#ff0000")
---@field billable_by_default boolean
---@field is_billable boolean
---@field client_id string|nil

---@param organization_id string
---@param data createProjectData
---@param callback function|nil
function M.createProject(organization_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/projects"
	return wrap(endpoint, "POST", nil, data, callback, nil)
end

---@param organization_id string
---@param project_id string
---@param data table  { name, color, billable_by_default, is_billable, client_id }
---@param callback function|nil
function M.updateProject(organization_id, project_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/projects/" .. project_id
	return wrap(endpoint, "PUT", nil, data, callback, nil)
end

--- Retrieves all tags for an organization.
---@param organization_id string
---@param callback function|nil
function M.getOrganizationTags(organization_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/tags"
	return wrap(endpoint, "GET", nil, nil, callback, 300)
end

---@class createTagData
---@field name string

---@param organization_id string
---@param data createTagData
---@param callback function|nil
function M.createTag(organization_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/tags"
	return wrap(endpoint, "POST", nil, data, callback, nil)
end

--- Retrieves all members of an organization.
---@param organization_id string
---@param callback function|nil
function M.getOrganizationMembers(organization_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/members"
	return wrap(endpoint, "GET", nil, nil, callback, 3600)
end

--- Retrieves all clients for an organization.
---@param organization_id string
---@param callback function|nil
function M.getOrganizationClients(organization_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/clients"
	return wrap(endpoint, "GET", nil, nil, callback, 300)
end

---@class createClientData
---@field name string

---@param organization_id string
---@param data createClientData
---@param callback function|nil
function M.createClient(organization_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/clients"
	return wrap(endpoint, "POST", nil, data, callback, nil)
end

---@param organization_id string
---@param client_id string
---@param callback function|nil
function M.deleteClient(organization_id, client_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/clients/" .. client_id
	return wrap(endpoint, "DELETE", nil, nil, callback, nil)
end

---@param organization_id string
---@param client_id string
---@param data table  { name = string }
---@param callback function|nil
function M.updateClient(organization_id, client_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/clients/" .. client_id
	return wrap(endpoint, "PUT", nil, data, callback, nil)
end

--- Retrieves a page of time entries for a member.
---@param organization_id string
---@param params table|nil  { member_ids=string, page=number, ... }
---@param callback function|nil
function M.getOrganizationTimeEntries(organization_id, params, callback)
	local endpoint = "organizations/" .. organization_id .. "/time-entries"
	return wrap(endpoint, "GET", params, nil, callback, nil)
end

---@param organization_id string
---@param time_entry_id string
---@param callback function|nil
function M.deleteTimeEntry(organization_id, time_entry_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/time-entries/" .. time_entry_id
	return wrap(endpoint, "DELETE", nil, nil, callback, nil)
end

--- Retrieves all tasks for an organization, optionally filtered by project.
---@param organization_id string
---@param params table|nil  { project_id = string }
---@param callback function|nil
function M.getOrganizationTasks(organization_id, params, callback)
	local endpoint = "organizations/" .. organization_id .. "/tasks"
	return wrap(endpoint, "GET", params, nil, callback, nil)
end

---@class createTaskData
---@field name string
---@field is_done boolean
---@field project_id string

---@param organization_id string
---@param data createTaskData
---@param callback function|nil
function M.createTask(organization_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/tasks"
	return wrap(endpoint, "POST", nil, data, callback, nil)
end

---@param organization_id string
---@param task_id string
---@param data table  { name = string, is_done = boolean }
---@param callback function|nil
function M.updateTask(organization_id, task_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/tasks/" .. task_id
	return wrap(endpoint, "PUT", nil, data, callback, nil)
end

---@param organization_id string
---@param task_id string
---@param callback function|nil
function M.deleteTask(organization_id, task_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/tasks/" .. task_id
	return wrap(endpoint, "DELETE", nil, nil, callback, nil)
end

return M
