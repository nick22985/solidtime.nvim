-- TODO: fix error stuff make it more easy to figure out when in a iter
local config = require("solidtime.config")
local curl = require("plenary.curl")
local cache = require("solidtime.cache")
local logger = require("solidtime.logger")
local M = {}

function M.get_data(endpoint, method, params, data, callback, ttl)
	local cache_key = endpoint .. (params and vim.fn.json_encode(params) or "")

	logger.debug(string.format("Checking cache for key: %s", cache_key))

	-- ttl is nil means no caching
	if ttl ~= nil then
		local cached_data = cache.get_cached_data(cache_key, ttl)
		if cached_data then
			logger.debug(string.format("Cache hit for key: %s. Returning cached data.", cache_key))
			print("Returning cached data for " .. endpoint)
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
		print("API key is not set.")
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
		local error_message = vim.json.decode(response.body).message
		-- local error_message = "test"
		logger.error(string.format("Error response: %d for URL: %s", response.status, url))
		if callback then
			callback("API Error: " .. response.status .. " " .. error_message, nil)
		else
			return nil, "API Error: " .. response.status .. " " .. error_message
		end
	end
end

function M.fetch_user_data(callback)
	local endpoint = "users/me"
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

function M.getUserMemberships(callback)
	local endpoint = "users/me/memberships"
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
		logger.error(error_msg)
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

return M
