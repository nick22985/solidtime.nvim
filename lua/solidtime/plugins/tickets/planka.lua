--- solidtime.plugins.tickets.planka — Planka ticket provider.
---
--- Auth: username + password credentials are used to obtain a JWT access token
--- via POST /api/access-tokens.  The token is cached in-memory for the session
--- and re-acquired automatically if it expires or is rejected.
---
--- Credentials are stored in the solidtime auth file (never in Lua config).
--- Run :SolidTime auth planka to set them interactively.

local tickets = require("solidtime.plugins.tickets.providers")
local logger = require("solidtime.logger")

local M = {
	id = "planka",
	name = "Planka",

	--- Credential fields presented by :SolidTime auth planka
	credential_fields = {
		{ key = "base_url", label = "Planka base URL (e.g. https://planka.example.com)", secret = false },
		{ key = "username", label = "Username or email", secret = false },
		{ key = "password", label = "Password", secret = true },
	},
}

local _cfg = {} ---@type { base_url?: string, username?: string, password?: string }
local _token = nil ---@type string|nil  cached JWT

--- Cache populated by get_projects(): maps project_id → list of board_ids.
--- Used by search() so it can resolve a project id to board ids without an
--- extra round-trip.
local _proj_boards = {} ---@type table<string, string[]>
--- Cache populated by get_projects(): maps board_id → board name.
local _board_names = {} ---@type table<string, string>
--- Cache populated by get_projects(): maps board_id → project name.
--- Used in global search to show which project a card belongs to.
local _board_project = {} ---@type table<string, string>

local function base_url()
	local u = _cfg.base_url or ""
	return u:gsub("/$", "")
end

local function auth_headers()
	return {
		["Content-Type"] = "application/json",
		["Accept"] = "application/json",
		["Authorization"] = "Bearer " .. (_token or ""),
	}
end

local function acquire_token(callback)
	if not _cfg.username or _cfg.username == "" or not _cfg.password or _cfg.password == "" then
		callback("Planka: username/password not set")
		return
	end

	tickets.request({
		url = base_url() .. "/api/access-tokens",
		method = "POST",
		headers = {
			["Content-Type"] = "application/json",
			["Accept"] = "application/json",
		},
		body = vim.fn.json_encode({
			emailOrUsername = _cfg.username,
			password = _cfg.password,
		}),
	}, function(err, status, body)
		if err then
			if status == 401 then
				callback("Planka: invalid credentials")
			else
				callback("Planka: login failed — " .. err)
			end
			return
		end
		local ok, decoded = pcall(vim.fn.json_decode, body or "")
		if not ok or type(decoded) ~= "table" or not decoded.item then
			callback("Planka: unexpected login response")
			return
		end
		_token = decoded.item
		logger.debug("solidtime planka: token acquired")
		callback(nil)
	end)
end

--- Call fn(callback) with a valid token, retrying once after re-login on 401.
---@param fn fun(cb: fun(err,status,body))
---@param final_callback fun(err, status, body)
local function with_token(fn, final_callback)
	if not _token then
		acquire_token(function(err)
			if err then
				final_callback(err, 0, nil)
				return
			end
			fn(final_callback)
		end)
		return
	end
	fn(function(err, status, body)
		if status == 401 then
			_token = nil
			acquire_token(function(aerr)
				if aerr then
					final_callback(aerr, 0, nil)
					return
				end
				fn(final_callback)
			end)
		else
			final_callback(err, status, body)
		end
	end)
end

---@param opts { base_url?: string, username?: string, password?: string }
function M.setup(opts)
	_cfg = opts or {}
	_token = nil
	_proj_boards = {}
	_board_names = {}
	_board_project = {}
	logger.debug(
		"solidtime planka: setup — base_url="
			.. ((_cfg.base_url and _cfg.base_url ~= "") and _cfg.base_url or "MISSING")
			.. " username="
			.. ((_cfg.username and _cfg.username ~= "") and "set" or "MISSING")
	)
end

---@return boolean, string|nil
function M.is_configured()
	if not _cfg.base_url or _cfg.base_url == "" then
		return false, "Planka base_url not set — run :SolidTime auth planka"
	end
	if not _cfg.username or _cfg.username == "" then
		return false, "Planka username not set — run :SolidTime auth planka"
	end
	if not _cfg.password or _cfg.password == "" then
		return false, "Planka password not set — run :SolidTime auth planka"
	end
	return true
end

--- Fetch all accessible Planka projects and boards.
--- Returns a flat list where each project appears once (prefixed "[Project]")
--- followed by its boards ("Project / Board").  Stored ids use type prefixes:
---   "p:<id>" for a whole project, "b:<id>" for a single board.
---@param callback fun(err: string|nil, items: table[]|nil)
function M.get_projects(callback)
	local ok, err = M.is_configured()
	if not ok then
		callback(err, nil)
		return
	end

	with_token(function(cb)
		tickets.request({
			url = base_url() .. "/api/projects",
			method = "GET",
			headers = auth_headers(),
		}, cb)
	end, function(req_err, _, body)
		if req_err then
			callback(req_err, nil)
			return
		end

		local dok, decoded = pcall(vim.fn.json_decode, body or "")
		if not dok or type(decoded) ~= "table" then
			callback("Planka: invalid JSON from /api/projects", nil)
			return
		end

		local projects = decoded.items or {}
		local boards = (decoded.included and decoded.included.boards) or {}

		local proj_name = {}
		local proj_order = {}
		for _, p in ipairs(projects) do
			local pid = tostring(p.id)
			proj_name[pid] = p.name or pid
			table.insert(proj_order, pid)
		end

		local seen_board_ids = {}
		local boards_by_proj = {}
		_proj_boards = {}
		_board_names = {}
		_board_project = {}
		for _, b in ipairs(boards) do
			local bid = tostring(b.id)
			if not seen_board_ids[bid] then
				seen_board_ids[bid] = true
				local pid = tostring(b.projectId)
				_board_names[bid] = type(b.name) == "string" and b.name or ""
				_board_project[bid] = proj_name[pid] or ""
				if not boards_by_proj[pid] then
					boards_by_proj[pid] = {}
				end
				table.insert(boards_by_proj[pid], b)
				if not _proj_boards[pid] then
					_proj_boards[pid] = {}
				end
				table.insert(_proj_boards[pid], bid)
			end
		end

		local result = {}
		for _, pid in ipairs(proj_order) do
			local pname = proj_name[pid] or pid
			local proj_boards = boards_by_proj[pid] or {}

			table.insert(result, {
				id = "p:" .. pid,
				name = "[Project] " .. pname,
			})

			table.sort(proj_boards, function(a, b)
				return (a.position or 0) < (b.position or 0)
			end)

			for _, b in ipairs(proj_boards) do
				table.insert(result, {
					id = "b:" .. tostring(b.id),
					name = pname .. " / " .. (b.name or tostring(b.id)),
				})
			end
		end

		callback(nil, result)
	end)
end

--- Resolve a stored scope id to a list of Planka board ids.
--- "p:<project_id>" → all board ids cached for that project (or re-fetched)
--- "b:<board_id>"   → { board_id }
--- plain id (legacy) → treated as a board id
---@param scope_id string
---@param callback fun(err: string|nil, board_ids: string[]|nil)
local function resolve_board_ids(scope_id, callback)
	local function ensure_board_names(board_ids, cb)
		if next(_board_names) ~= nil then
			cb(nil, board_ids)
			return
		end
		M.get_projects(function(err, _)
			if err then
				cb(err, nil)
				return
			end
			cb(nil, board_ids)
		end)
	end

	if scope_id:sub(1, 2) == "b:" then
		local bid = scope_id:sub(3)
		ensure_board_names({ bid }, callback)
		return
	end

	local pid
	if scope_id:sub(1, 2) == "p:" then
		pid = scope_id:sub(3)
	else
		ensure_board_names({ scope_id }, callback)
		return
	end

	if _proj_boards[pid] and #_proj_boards[pid] > 0 then
		callback(nil, _proj_boards[pid])
		return
	end

	M.get_projects(function(err, _)
		if err then
			callback(err, nil)
			return
		end
		callback(nil, _proj_boards[pid] or {})
	end)
end

--- Search Planka cards, scoped to the linked project or board.
---@param query string      search string (empty = broad match)
---@param scope_id string   "p:<project_id>", "b:<board_id>", or "" for all
---@param callback fun(err: string|nil, tickets: table[]|nil)
function M.search(query, scope_id, callback)
	local ok, err = M.is_configured()
	if not ok then
		callback(err, nil)
		return
	end

	if scope_id and scope_id ~= "" then
		resolve_board_ids(scope_id, function(rerr, board_ids)
			if rerr then
				callback(rerr, nil)
				return
			end
			M._do_search(query, board_ids, callback)
		end)
	else
		if next(_board_names) == nil then
			M.get_projects(function(perr, _)
				if perr then
					callback(perr, nil)
					return
				end
				M._do_search(query, nil, callback)
			end)
		else
			M._do_search(query, nil, callback)
		end
	end
end

--- Internal: run the search API call and filter results to board_ids.
---@param query string
---@param board_ids string[]|nil   nil = no filter
---@param callback fun(err, tickets)
function M._do_search(query, board_ids, callback)
	local q = (query and query ~= "") and query or " "

	local board_set = nil
	if board_ids and #board_ids > 0 then
		board_set = {}
		for _, bid in ipairs(board_ids) do
			board_set[bid] = true
		end
	end

	with_token(function(cb)
		tickets.request({
			url = base_url() .. "/api/cards/search",
			method = "GET",
			headers = auth_headers(),
			params = {
				query = q,
				limit = 100,
				includeArchived = "false",
			},
		}, cb)
	end, function(req_err, _, body)
		if req_err then
			callback(req_err, nil)
			return
		end

		local dok, decoded = pcall(vim.fn.json_decode, body or "")
		if not dok or type(decoded) ~= "table" then
			callback("Planka: invalid JSON from /api/cards/search", nil)
			return
		end

		local result = {}
		for _, c in ipairs(decoded.items or {}) do
			local bid = tostring(c.boardId or "")
			if not board_set or board_set[bid] then
				if c.archived == true then
					goto continue
				end

				local label_str = ""
				if type(c.labels) == "table" and #c.labels > 0 then
					local names = {}
					for _, l in ipairs(c.labels) do
						if l.name and l.name ~= "" then
							table.insert(names, l.name)
						end
					end
					if #names > 0 then
						label_str = "[" .. table.concat(names, ", ") .. "]"
					end
				end

				local list_name = type(c.listName) == "string" and c.listName or ""
				local board_name = _board_names[bid] or ""
				local project_name = _board_project[bid] or ""

				table.insert(result, {
					id = tostring(c.id or ""),
					title = (c.name or ""),
					description = (c.slateDescription or ""),
					url = base_url() .. "/cards/" .. tostring(c.id or ""),
					status = list_name,
					board = board_name,
					project = project_name,
					priority = label_str,
					raw = c,
				})
				::continue::
			end
		end

		callback(nil, result)
	end)
end

tickets.register(M)

return M
