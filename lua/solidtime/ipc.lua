local M = {}

local registry_file = nil

local function own_socket()
	local s = vim.v.servername
	return (s and s ~= "") and s or nil
end

--- Each entry in the registry is { socket = "...", project_dir = "..." }.
--- Older entries that are plain strings are tolerated for backward compatibility.
---@return table[]
local function read_registry()
	if not registry_file then
		return {}
	end
	local f = io.open(registry_file, "r")
	if not f then
		return {}
	end
	local content = f:read("*all")
	f:close()
	if not content or content == "" then
		return {}
	end
	local ok, decoded = pcall(vim.fn.json_decode, content)
	if not ok or type(decoded) ~= "table" then
		return {}
	end
	-- Migrate plain-string entries from older format to table entries.
	-- Drop any entry whose socket field is not a non-empty string.
	local migrated = {}
	for _, entry in ipairs(decoded) do
		if type(entry) == "string" and entry ~= "" then
			table.insert(migrated, { socket = entry, project_dir = nil })
		elseif type(entry) == "table" and type(entry.socket) == "string" and entry.socket ~= "" then
			table.insert(migrated, entry)
		end
		-- silently drop anything else (nil socket, table-as-socket, etc.)
	end
	return migrated
end

---@param entries table[]
local function write_registry(entries)
	if not registry_file then
		return
	end
	local dir = vim.fn.fnamemodify(registry_file, ":h")
	vim.fn.mkdir(dir, "p")
	local f = io.open(registry_file, "w")
	if not f then
		return
	end
	f:write(vim.fn.json_encode(entries))
	f:close()
end

---@param socket_path string
---@return boolean
local function is_socket_alive(socket_path)
	if type(socket_path) ~= "string" or socket_path == "" then
		return false
	end
	if socket_path == own_socket() then
		return false
	end
	local uv = vim.uv or vim.loop
	if uv.fs_stat(socket_path) == nil then
		return false
	end
	local ok, chan = pcall(vim.fn.sockconnect, "pipe", socket_path, { rpc = true })
	if not ok or not chan or chan == 0 then
		return false
	end
	pcall(vim.fn.chanclose, chan)
	return true
end

--- Returns all live registry entries (including own), pruning dead ones.
---@return table[]
local function live_entries()
	local all = read_registry()
	local live = {}
	local changed = false

	for _, entry in ipairs(all) do
		local sock = entry.socket
		if sock == own_socket() then
			table.insert(live, entry)
		elseif is_socket_alive(sock) then
			table.insert(live, entry)
		else
			changed = true
		end
	end

	if changed then
		write_registry(live)
	end

	return live
end

---@return string[]  live peer socket paths (excluding self)
local function live_peers()
	local entries = live_entries()
	local peers = {}
	local me = own_socket()
	for _, entry in ipairs(entries) do
		if entry.socket ~= me then
			table.insert(peers, entry.socket)
		end
	end
	return peers
end

--- Returns true when at least one other live Neovim instance is registered
--- for the same solidtime project name as this instance.
--- Matches on project_name (the resolved git/cwd name used in projects.json)
--- so that different worktrees of the same repo are treated as peers.
---@param project_name string
---@return boolean
function M.has_peer_for_project(project_name)
	if not project_name or project_name == "" then
		return false
	end
	local entries = live_entries()
	local me = own_socket()
	for _, entry in ipairs(entries) do
		if entry.socket ~= me and entry.project_name == project_name then
			return true
		end
	end
	return false
end

---@param project_name string|nil  resolved project name (from autotrack.detect_project())
function M.register(project_name)
	local me = own_socket()
	if not me then
		return
	end

	local project_dir = vim.fn.getcwd()

	local all = read_registry()
	-- Update existing entry for this socket if present, otherwise append.
	for _, entry in ipairs(all) do
		if entry.socket == me then
			entry.project_dir = project_dir
			entry.project_name = project_name or entry.project_name
			write_registry(all)
			return
		end
	end
	table.insert(all, { socket = me, project_dir = project_dir, project_name = project_name })
	write_registry(all)
end

function M.unregister()
	local me = own_socket()
	if not me then
		return
	end

	local all = read_registry()
	local filtered = {}
	for _, entry in ipairs(all) do
		if entry.socket ~= me then
			table.insert(filtered, entry)
		end
	end
	write_registry(filtered)
end

function M.broadcast_stop()
	local peers = live_peers()
	if #peers == 0 then
		return
	end

	local uv = vim.uv or vim.loop

	local lua_code = "require('solidtime.ipc')._remote_stop()"
	local payload = vim.mpack.encode({ 2, "nvim_exec_lua", { lua_code, {} } })

	for _, socket_path in ipairs(peers) do
		local pipe = uv.new_pipe(true)
		if pipe then
			pipe:connect(socket_path, function(err)
				if err then
					pipe:close()
					return
				end
				pipe:write(payload, function()
					pipe:close()
				end)
			end)
		end
	end
end

function M._remote_stop()
	local ok, tracker = pcall(require, "solidtime.tracker")
	if not ok then
		return
	end
	if tracker.storage and tracker.storage.active_entry then
		tracker.clear_active_entry()
	end
end

---@param storage_dir string  same dir solidtime uses for its storage JSON
function M.init(storage_dir)
	registry_file = storage_dir .. "/nvim_instances.json"

	local augroup = vim.api.nvim_create_augroup("SolidTimeIPC", { clear = true })

	vim.api.nvim_create_autocmd("UIEnter", {
		group = augroup,
		once = true,
		callback = function()
			M.register()
		end,
	})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = augroup,
		once = true,
		callback = function()
			M.unregister()
		end,
	})
end

return M
