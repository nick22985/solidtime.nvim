--- solidtime.plugins.tickets.freedcamp — Freedcamp ticket provider.
---
--- Auth modes (auto-detected from credentials):
---   • Simple key:  api_key only — passed as X-API-KEY header.
---   • Signed key:  api_key + api_secret — adds timestamp + HMAC-SHA1 hash
---                  query params so requests can't be replayed.
---
--- Credentials are stored in the solidtime auth file (never in Lua config).
--- Run :SolidTime auth freedcamp to set them interactively.

local tickets = require("solidtime.plugins.tickets.providers")
local logger = require("solidtime.logger")

local BASE_URL = "https://freedcamp.com/api/v1"

local M = {
	id = "freedcamp",
	name = "Freedcamp",

	--- Credential fields presented by :SolidTime auth freedcamp
	credential_fields = {
		{ key = "api_key", label = "API Key", secret = true },
		{ key = "api_secret", label = "API Secret (leave blank for simple-key mode)", secret = true },
	},
}

local _cfg = {} ---@type { api_key?: string, api_secret?: string }

--- Build the auth query params for a request.
--- In signed mode we add timestamp + HMAC-SHA1 hash.
--- In simple mode we just add api_key.
---@return table  params to merge into the request
local function auth_params()
	local key = _cfg.api_key or ""
	local secret = _cfg.api_secret

	if not secret or secret == "" then
		-- Simple key mode
		return { api_key = key }
	end

	-- Signed key mode: hash = HMAC-SHA1(api_key .. timestamp, api_secret)
	local ts = tostring(os.time())

	local msg = key .. ts
	local hash = nil

	local cmd = string.format(
		"printf '%%s' %s | openssl dgst -sha1 -hmac %s 2>/dev/null | awk '{print $NF}'",
		vim.fn.shellescape(msg),
		vim.fn.shellescape(secret)
	)
	local result = vim.fn.system(cmd)
	result = result and result:gsub("%s+$", "") or ""

	if result ~= "" then
		hash = result
	else
		local py_cmd = string.format(
			'python3 -c "import hmac,hashlib; print(hmac.new(%s.encode(),%s.encode(),hashlib.sha1).hexdigest())" 2>/dev/null',
			vim.fn.string(secret),
			vim.fn.string(msg)
		)
		result = vim.fn.system(py_cmd)
		result = result and result:gsub("%s+$", "") or ""
		if result ~= "" then
			hash = result
		end
	end

	if not hash then
		logger.warn("solidtime freedcamp: could not compute HMAC hash — falling back to simple key auth")
		return { api_key = key }
	end

	return { api_key = key, timestamp = ts, hash = hash }
end

--- Build the standard request headers (no auth in headers for Freedcamp —
--- auth goes in query params).
---@return table
local function headers()
	return {
		["Content-Type"] = "application/json",
		["Accept"] = "application/json",
	}
end

---@param opts { api_key?: string, api_secret?: string }
function M.setup(opts)
	_cfg = opts or {}
	logger.debug(
		"solidtime freedcamp: setup — api_key="
			.. ((_cfg.api_key and _cfg.api_key ~= "") and "set" or "MISSING")
			.. " api_secret="
			.. ((_cfg.api_secret and _cfg.api_secret ~= "") and "set" or "not set (simple-key mode)")
	)
end

--- Check whether the provider is usable (has a key set).
---@return boolean, string|nil  ok, err_message
function M.is_configured()
	if not _cfg.api_key or _cfg.api_key == "" then
		return false, "Freedcamp api_key not set — run :SolidTime auth freedcamp to configure credentials"
	end
	if _cfg.api_secret and _cfg.api_secret ~= "" then
		return true
	end
	return true
end

--- Fetch all Freedcamp projects the current user has access to.
---@param callback fun(err: string|nil, projects: table[]|nil)
function M.get_projects(callback)
	local ok, err = M.is_configured()
	if not ok then
		callback(err, nil)
		return
	end

	tickets.request({
		url = BASE_URL .. "/projects",
		method = "GET",
		headers = headers(),
		params = auth_params(),
	}, function(req_err, _, body)
		if req_err then
			callback(req_err, nil)
			return
		end
		local decode_ok, decoded = pcall(vim.fn.json_decode, body or "")
		if not decode_ok or type(decoded) ~= "table" then
			callback("Freedcamp: invalid JSON response from /projects", nil)
			return
		end
		if decoded.http_code and decoded.http_code ~= 200 then
			callback("Freedcamp: " .. (decoded.msg or tostring(decoded.http_code)), nil)
			return
		end
		local raw = (decoded.data and decoded.data.projects) or {}
		local projects = {}
		for _, p in ipairs(raw) do
			table.insert(projects, {
				id = tostring(p.project_id or ""),
				name = p.project_name or tostring(p.project_id or ""),
			})
		end
		callback(nil, projects)
	end)
end

--- Search issues in a specific Freedcamp project via the Issue Tracker endpoint.
--- The API does not support free-text search, so we fetch open issues and do a
--- client-side substring match on title.
---
---@param query string           substring to filter by (empty = return all open issues)
---@param project_id string      Freedcamp project_id
---@param callback fun(err: string|nil, tickets: table[]|nil)
function M.search(query, project_id, callback)
	local ok, err = M.is_configured()
	if not ok then
		callback(err, nil)
		return
	end

	if not project_id or project_id == "" then
		M.get_projects(function(perr, projects)
			if perr or not projects or #projects == 0 then
				callback(perr or "Freedcamp: no projects found", nil)
				return
			end
			local pending = #projects
			local merged = {}
			local first_err = nil
			for _, p in ipairs(projects) do
				M.search(query, tostring(p.id), function(serr, tix)
					if serr then
						first_err = serr
					elseif tix then
						for _, t in ipairs(tix) do
							table.insert(merged, t)
						end
					end
					pending = pending - 1
					if pending == 0 then
						callback(first_err and #merged == 0 and first_err or nil, merged)
					end
				end)
			end
		end)
		return
	end

	local params = auth_params()
	params.project_id = project_id
	params.status = "0"
	params.limit = 200
	params.offset = 0

	tickets.request({
		url = BASE_URL .. "/issues",
		method = "GET",
		headers = headers(),
		params = params,
	}, function(req_err, _, body)
		if req_err then
			callback(req_err, nil)
			return
		end

		local decode_ok, decoded = pcall(vim.fn.json_decode, body or "")
		if not decode_ok or type(decoded) ~= "table" then
			callback("Freedcamp: invalid JSON from /issues", nil)
			return
		end
		if decoded.http_code and decoded.http_code ~= 200 then
			callback("Freedcamp: " .. (decoded.msg or tostring(decoded.http_code)), nil)
			return
		end

		local raw = (decoded.data and decoded.data.issues) or {}
		local q = query and query:lower() or ""

		local result = {}
		for _, t in ipairs(raw) do
			local title = t.title or ""
			local display = (t.number_prefixed and (t.number_prefixed .. " ") or "") .. title
			if q == "" or display:lower():find(q, 1, true) then
				table.insert(result, {
					id = tostring(t.id or ""),
					title = display,
					description = t.description or "",
					url = t.url or "",
					status = t.status_title or tostring(t.status or ""),
					priority = t.priority_title or tostring(t.priority or ""),
					raw = t,
				})
			end
		end

		callback(nil, result)
	end)
end

tickets.register(M)

return M
