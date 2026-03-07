local M = {}

local registry_file = nil

local function own_socket()
	local s = vim.v.servername
	return (s and s ~= "") and s or nil
end

---@return string[]
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
	return decoded
end

---@param sockets string[]
local function write_registry(sockets)
	if not registry_file then
		return
	end
	local dir = vim.fn.fnamemodify(registry_file, ":h")
	vim.fn.mkdir(dir, "p")
	local f = io.open(registry_file, "w")
	if not f then
		return
	end
	f:write(vim.fn.json_encode(sockets))
	f:close()
end

---@param socket_path string
---@return boolean
local function is_socket_alive(socket_path)
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

---@return string[]  live peer socket paths
local function live_peers()
	local all = read_registry()
	local live = {}
	local changed = false

	for _, s in ipairs(all) do
		if s == own_socket() then
			table.insert(live, s)
		elseif is_socket_alive(s) then
			table.insert(live, s)
		else
			changed = true
		end
	end

	if changed then
		write_registry(live)
	end

	local peers = {}
	local me = own_socket()
	for _, s in ipairs(live) do
		if s ~= me then
			table.insert(peers, s)
		end
	end
	return peers
end

function M.register()
	local me = own_socket()
	if not me then
		return
	end

	local all = read_registry()
	-- Avoid duplicates
	for _, s in ipairs(all) do
		if s == me then
			return
		end
	end
	table.insert(all, me)
	write_registry(all)
end

function M.unregister()
	local me = own_socket()
	if not me then
		return
	end

	local all = read_registry()
	local filtered = {}
	for _, s in ipairs(all) do
		if s ~= me then
			table.insert(filtered, s)
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
