-- TODO: fix error stuff make it more easy to figure out when in a iter
local config = require("solidtime.config")
local curl = require("plenary.curl")
local cache = require("solidtime.cache")
local logger = require("solidtime.logger")
local M = {}

-- API module for solidtime.nvim
-- This module handles API requests to the SolidTime API
-- It provides functions to fetch user data, create time entries, and manage organizations.
-- It also includes caching functionality to reduce the number of API requests made.

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
			-- check if cached data is expired
			logger.debug(string.format("Cache hit for key: %s. Returning cached data.", cache_key))
			cached_data = vim.json.decode(cached_data)
			if callback then
				callback(nil, cached_data)
			else
				return cached_data
			end
			return
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
		for key, value in pairs(params) do
			query = query .. key .. "=" .. value .. "&"
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
	-- response.status = 401

	if response.status == 200 or response.status == 201 then
		if ttl ~= nil then
			cache.set_cached_data(cache_key, response.body, ttl)
			logger.debug(string.format("Caching response for key: %s", cache_key))
		end
		if callback then
			callback(nil, vim.json.decode(response.body))
		else
			return vim.json.decode(response.body)
		end
	else
		local error_message = response.body
		if response.body then
			error_message = vim.json.decode(response.body).message
		else
			if response.body:find("Not Found") then
				error_message = "Not Found"
			else
				error_message = "Error decoding JSON response"
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

-- Organization-related API calls
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

return M
