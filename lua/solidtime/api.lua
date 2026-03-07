-- TODO: fix error stuff make it more easy to figure out when in a iter
local config = require("solidtime.config")
local curl = require("plenary.curl")
local cache = require("solidtime.cache")
local logger = require("solidtime.logger")
local M = {}

---@param endpoint string API endpoint to call
---@param method string HTTP method to use (GET, POST, PATCH, DELETE)
---@param params table|nil Query parameters to include in the request
---@param data table|nil Data to include in the request body (for POST and PATCH requests)
---@param callback function|nil Callback function to handle the response
---@param ttl number|nil Time-to-live for caching the response (in seconds)
function M.get_data(endpoint, method, params, data, callback, ttl)
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
			else
				if callback then
					callback(nil, decoded)
				else
					return decoded
				end
				return
			end
		end
		logger.debug(string.format("Cache miss for key: %s. Making API request to endpoint: %s", cache_key, endpoint))
	end

	local api_key = config.get().api_key
	local base_url = config.get().api_url

	if not api_key then
		logger.error("API key is not set.")
		if callback then
			callback("API key is not set.", nil)
		else
			return nil, "API key is not set."
		end
		return
	end

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

	---@type string
	local url = base_url .. endpoint

	local headers = {
		["Authorization"] = "Bearer " .. api_key,
		["Content-Type"] = "application/json",
	}

	local options = {
		headers = headers,
	}

	if data then
		options.body = vim.fn.json_encode(data)
		logger.debug(string.format("Request data: %s", vim.fn.json_encode(data)))
	end

	logger.debug(string.format("Making %s request to URL: %s", method, url))

	local response
	if method == "POST" then
		response = curl.post(url, options)
	elseif method == "PATCH" then
		response = curl.patch(url, options)
	elseif method == "PUT" then
		response = curl.put(url, options)
	elseif method == "DELETE" then
		response = curl.delete(url, options)
	else
		response = curl.get(url, options)
	end

	logger.debug(string.format("Received response status: %d for URL: %s", response.status, url))

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
			if callback then
				callback(err, nil)
			else
				return nil, err
			end
			return
		end
		if ttl ~= nil then
			cache.set_cached_data(cache_key, response.body, ttl)
			logger.debug(string.format("Caching response for key: %s", cache_key))
		end
		if callback then
			callback(nil, decoded)
		else
			return decoded
		end
	elseif response.status == 204 then
		if callback then
			callback(nil, {})
		else
			return {}
		end
	elseif response.status == 401 then
		local error_message = "Unauthorized — check your API key (`:SolidTime auth`)"
		logger.error(error_message)
		if callback then
			callback("API Error: 401 " .. error_message, nil)
		else
			return nil, "API Error: 401 " .. error_message
		end
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
			string.format("Error response: %d for URL: %s Response: %s", response.status, url, vim.inspect(response)),
			false
		)
		if callback then
			callback("API Error: " .. response.status .. " " .. error_message, nil)
		else
			return nil, "API Error: " .. response.status .. " " .. error_message
		end
	end
end

function M.fetch_user_data(callback, options)
	local endpoint = "users/me"
	local ttl = options and options.ttl or 0
	if callback then
		M.get_data(endpoint, "GET", nil, nil, callback, ttl)
	else
		local data, err = M.get_data(endpoint, "GET", nil, nil, nil, ttl)
		if err then
			return { error = err }
		else
			return data
		end
	end
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
--- This function fetches the current user's organization memberships from the API.
--- @param callback function|nil Optional callback function that receives the response data.
---                              If provided, the request will be executed asynchronously.
--- @return UserMembershipsResponse|apiError|nil apiResponse An table containing either membership data or error information
function M.getUserMemberships(callback)
	local endpoint = "users/me/memberships"
	if callback then
		M.get_data(endpoint, "GET", nil, nil, callback, 3600)
		return nil
	else
		local data, err = M.get_data(endpoint, "GET", nil, nil, nil, 3600)
		if err then
			return { error = err }
		else
			---@type UserMembershipsResponse
			return data
		end
	end
end

function M.getUserTimeEntry(callback)
	local endpoint = "users/me/time-entries/active"
	if callback then
		M.get_data(endpoint, "GET", nil, nil, callback, nil)
	else
		local data, err = M.get_data(endpoint, "GET", nil, nil, nil, nil)
		if err then
			return { error = err }
		else
			return data
		end
	end
end

function M.createTimeEntry(organization_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/time-entries"

	if not data.member_id or not data.start then
		local error_msg = "Missing required fields: member_id and start"
		logger.error(error_msg, false)
		if callback then
			callback(error_msg, nil)
		else
			return { error = error_msg }
		end
		return
	end

	if callback then
		M.get_data(endpoint, "POST", nil, data, callback, nil)
	else
		local response, err = M.get_data(endpoint, "POST", nil, data, nil, nil)
		if err then
			return { error = err }
		else
			return response
		end
	end
end

---@class updateTimeEntryData
---@field member_id string
---@field project_id string|nil
---@field task_id string|nil
---@field start string|osdate
---@field end string|osdate|nil
---@field billable boolean
---@field description string|nil max 500 chracters
---@field tags table|nil

---@param organization_id string
---@param time_entry_id string
---@param data updateTimeEntryData|nil
---@param callback function|nil
function M.updateTimeEntry(organization_id, time_entry_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/time-entries/" .. time_entry_id

	if callback then
		M.get_data(endpoint, "PUT", nil, data, callback, nil)
	else
		local response, err = M.get_data(endpoint, "PUT", nil, data, nil, nil)
		if err then
			return { error = err }
		else
			return response
		end
	end
end

function M.getOrganization(organization_id, callback)
	local endpoint = "organizations/" .. organization_id
	if callback then
		M.get_data(endpoint, "GET", nil, nil, callback, 3600)
	else
		local data, err = M.get_data(endpoint, "GET", nil, nil, nil, 3600)
		if err then
			return { error = err }
		else
			return data
		end
	end
end

function M.getOrganizationProjects(organization_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/projects"
	if callback then
		M.get_data(endpoint, "GET", nil, nil, callback, 3600)
	else
		local data, err = M.get_data(endpoint, "GET", nil, nil, nil, 3600)
		if err then
			return { error = err }
		else
			return data
		end
	end
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
	if callback then
		M.get_data(endpoint, "POST", nil, data, callback, nil)
	else
		local response, err = M.get_data(endpoint, "POST", nil, data, nil, nil)
		if err then
			return { error = err }
		else
			return response
		end
	end
end

---@param organization_id string
---@param project_id string
---@param data table  { name, color, billable_by_default, is_billable, client_id }
---@param callback function|nil
function M.updateProject(organization_id, project_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/projects/" .. project_id
	if callback then
		M.get_data(endpoint, "PUT", nil, data, callback, nil)
	else
		local response, err = M.get_data(endpoint, "PUT", nil, data, nil, nil)
		if err then
			return { error = err }
		else
			return response
		end
	end
end

--- Retrieves all tags for an organization.
---@param organization_id string
---@param callback function|nil
function M.getOrganizationTags(organization_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/tags"
	if callback then
		M.get_data(endpoint, "GET", nil, nil, callback, 300)
	else
		local data, err = M.get_data(endpoint, "GET", nil, nil, nil, 300)
		if err then
			return { error = err }
		else
			return data
		end
	end
end

---@class createTagData
---@field name string

---@param organization_id string
---@param data createTagData
---@param callback function|nil
function M.createTag(organization_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/tags"
	if callback then
		M.get_data(endpoint, "POST", nil, data, callback, nil)
	else
		local response, err = M.get_data(endpoint, "POST", nil, data, nil, nil)
		if err then
			return { error = err }
		else
			return response
		end
	end
end

--- Retrieves all members of an organization.
---@param organization_id string
---@param callback function|nil
function M.getOrganizationMembers(organization_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/members"
	if callback then
		M.get_data(endpoint, "GET", nil, nil, callback, 3600)
	else
		local data, err = M.get_data(endpoint, "GET", nil, nil, nil, 3600)
		if err then
			return { error = err }
		else
			return data
		end
	end
end

--- Retrieves all clients for an organization.
---@param organization_id string
---@param callback function|nil
function M.getOrganizationClients(organization_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/clients"
	if callback then
		M.get_data(endpoint, "GET", nil, nil, callback, 300)
	else
		local data, err = M.get_data(endpoint, "GET", nil, nil, nil, 300)
		if err then
			return { error = err }
		else
			return data
		end
	end
end

---@class createClientData
---@field name string

---@param organization_id string
---@param data createClientData
---@param callback function|nil
function M.createClient(organization_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/clients"
	if callback then
		M.get_data(endpoint, "POST", nil, data, callback, nil)
	else
		local response, err = M.get_data(endpoint, "POST", nil, data, nil, nil)
		if err then
			return { error = err }
		else
			return response
		end
	end
end

---@param organization_id string
---@param client_id string
---@param callback function|nil
function M.deleteClient(organization_id, client_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/clients/" .. client_id
	if callback then
		M.get_data(endpoint, "DELETE", nil, nil, callback, nil)
	else
		local response, err = M.get_data(endpoint, "DELETE", nil, nil, nil, nil)
		if err then
			return { error = err }
		else
			return response
		end
	end
end

---@param organization_id string
---@param client_id string
---@param data table  { name = string }
---@param callback function|nil
function M.updateClient(organization_id, client_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/clients/" .. client_id
	if callback then
		M.get_data(endpoint, "PUT", nil, data, callback, nil)
	else
		local response, err = M.get_data(endpoint, "PUT", nil, data, nil, nil)
		if err then
			return { error = err }
		else
			return response
		end
	end
end

--- Retrieves a page of time entries for a member.
---@param organization_id string
---@param params table|nil  { member_ids=string, page=number, ... }
---@param callback function|nil
function M.getOrganizationTimeEntries(organization_id, params, callback)
	local endpoint = "organizations/" .. organization_id .. "/time-entries"
	if callback then
		M.get_data(endpoint, "GET", params, nil, callback, nil)
	else
		local data, err = M.get_data(endpoint, "GET", params, nil, nil, nil)
		if err then
			return { error = err }
		else
			return data
		end
	end
end

---@param organization_id string
---@param time_entry_id string
---@param callback function|nil
function M.deleteTimeEntry(organization_id, time_entry_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/time-entries/" .. time_entry_id
	if callback then
		M.get_data(endpoint, "DELETE", nil, nil, callback, nil)
	else
		local response, err = M.get_data(endpoint, "DELETE", nil, nil, nil, nil)
		if err then
			return { error = err }
		else
			return response
		end
	end
end

--- Retrieves all tasks for an organization, optionally filtered by project.
---@param organization_id string
---@param params table|nil  { project_id = string }
---@param callback function|nil
function M.getOrganizationTasks(organization_id, params, callback)
	local endpoint = "organizations/" .. organization_id .. "/tasks"
	if callback then
		M.get_data(endpoint, "GET", params, nil, callback, nil)
	else
		local data, err = M.get_data(endpoint, "GET", params, nil, nil, nil)
		if err then
			return { error = err }
		else
			return data
		end
	end
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
	if callback then
		M.get_data(endpoint, "POST", nil, data, callback, nil)
	else
		local response, err = M.get_data(endpoint, "POST", nil, data, nil, nil)
		if err then
			return { error = err }
		else
			return response
		end
	end
end

---@param organization_id string
---@param task_id string
---@param data table  { name = string, is_done = boolean }
---@param callback function|nil
function M.updateTask(organization_id, task_id, data, callback)
	local endpoint = "organizations/" .. organization_id .. "/tasks/" .. task_id
	if callback then
		M.get_data(endpoint, "PUT", nil, data, callback, nil)
	else
		local response, err = M.get_data(endpoint, "PUT", nil, data, nil, nil)
		if err then
			return { error = err }
		else
			return response
		end
	end
end

---@param organization_id string
---@param task_id string
---@param callback function|nil
function M.deleteTask(organization_id, task_id, callback)
	local endpoint = "organizations/" .. organization_id .. "/tasks/" .. task_id
	if callback then
		M.get_data(endpoint, "DELETE", nil, nil, callback, nil)
	else
		local response, err = M.get_data(endpoint, "DELETE", nil, nil, nil, nil)
		if err then
			return { error = err }
		else
			return response
		end
	end
end

return M
