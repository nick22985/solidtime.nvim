--- solidtime.plugins.tickets.providers — provider registry and shared HTTP helper.
---
--- Each provider (Freedcamp, Planka, Trello, …) is a Lua module that calls
--- M.register() when it is loaded.  The rest of the plugin only talks to
--- this module; it never requires provider files directly.
---
--- Provider contract:
---   provider.id      string   — unique snake_case key, e.g. "freedcamp"
---   provider.name    string   — human-readable label
---
---   provider.credential_fields  table[]  (optional but recommended)
---     Ordered list of { key, label, secret? } describing the credentials
---     that auth.prompt_provider_credentials() will collect and persist.
---     Loaded automatically from the auth store at startup.
---
---   provider.setup(opts)
---     Called once at startup with a plain table of credential key→value
---     pairs (loaded from the auth store).  Also called after the user runs
---     :SolidTime auth <provider_id> to apply the new credentials live.
---
---   provider.is_configured()  →  ok: boolean, err: string|nil   (optional)
---     Returns false when mandatory credentials are missing.
---
---   provider.get_projects(callback)   (optional)
---     Async; callback(err, projects[]).  Each project must have at minimum
---     an `id` and either `title` or `name`.  Implement this when your
---     provider supports per-project ticket scoping.
---
---   provider.search(query, project_id, callback)
---     Async; callback(err, tickets[]) where each ticket = {
---       id, title, description, url, status, priority, raw
---     }

local M = {}

---@type table<string, table>
local _providers = {}

--- Register a provider.  Providers call this from their own module body.
---@param provider table
function M.register(provider)
	assert(type(provider.id) == "string" and provider.id ~= "", "ticket provider must have an id")
	assert(type(provider.name) == "string", "ticket provider must have a name")
	assert(type(provider.search) == "function", "ticket provider must implement search()")
	_providers[provider.id] = provider
end

--- Return all registered providers as an ordered list.
---@return table[]
function M.list()
	local out = {}
	for _, p in pairs(_providers) do
		table.insert(out, p)
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

--- Return a single provider by id, or nil.
---@param id string
---@return table|nil
function M.get(id)
	return _providers[id]
end

-- ---------------------------------------------------------------------------
-- Shared async HTTP helper (mirrors the pattern in api.lua, but generic so
-- providers can call arbitrary external APIs without depending on api.lua).
-- ---------------------------------------------------------------------------

local curl = require("plenary.curl")
local logger = require("solidtime.logger")

---@param opts { url: string, method?: string, headers?: table, params?: table, body?: string }
---@param callback fun(err: string|nil, status: integer, body: string|nil)
function M.request(opts, callback)
	local method = (opts.method or "GET"):lower()
	local url = opts.url

	-- Append query string if params supplied
	if opts.params then
		-- Percent-encode a single value component (RFC 3986 unreserved chars are safe)
		local function urlencode(s)
			s = tostring(s)
			return s:gsub("[^A-Za-z0-9%-_.~]", function(c)
				return string.format("%%%02X", c:byte())
			end)
		end
		local qs = ""
		for k, v in pairs(opts.params) do
			if type(v) == "table" then
				for _, item in ipairs(v) do
					qs = qs .. urlencode(k) .. "[]=" .. urlencode(item) .. "&"
				end
			else
				qs = qs .. urlencode(k) .. "=" .. urlencode(v) .. "&"
			end
		end
		if qs ~= "" then
			url = url .. "?" .. qs:sub(1, -2)
		end
	end

	logger.debug("solidtime.tickets: " .. method:upper() .. " " .. url)

	local curl_opts = {
		url = url,
		headers = opts.headers or {},
		callback = vim.schedule_wrap(function(response)
			if not response then
				callback("No response from server", 0, nil)
				return
			end
			logger.debug("solidtime.tickets: response status=" .. tostring(response.status))
			if response.status and (response.status == 200 or response.status == 201) then
				callback(nil, response.status, response.body)
			else
				local msg = "HTTP " .. tostring(response.status or "?")
				if response.body and response.body ~= "" then
					local ok, dec = pcall(vim.fn.json_decode, response.body)
					if ok and dec and dec.msg and dec.msg ~= "" then
						msg = msg .. ": " .. dec.msg
					elseif not ok then
						msg = msg .. ": " .. response.body:sub(1, 120)
					end
				end
				callback(msg, response.status or 0, response.body)
			end
		end),
	}

	if opts.body then
		curl_opts.body = opts.body
	end

	curl[method](curl_opts)
end

return M
