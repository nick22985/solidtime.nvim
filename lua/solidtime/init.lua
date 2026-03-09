local auth = require("solidtime.auth")
local config = require("solidtime.config")
local logger = require("solidtime.logger")
local buffer = require("solidtime.buffer")
local tracker = require("solidtime.tracker")
local autotrack = require("solidtime.autotrack")
local ipc = require("solidtime.ipc")

local M = {}

--- Setup function for solidtime.nvim
--- @param opts table|nil Options for solidtime
function M.setup(opts)
	opts = opts or {}

	config.setup(opts)

	local storage_dir = config.get().storage_dir
	if storage_dir then
		vim.fn.mkdir(storage_dir, "p")
	end

	logger.init()

	logger.debug("Setting up solidtime.nvim...")

	tracker.init()
	autotrack.init()
	ipc.init(config.get().storage_dir)

	local tickets_cfg = config.get().tickets or {}
	local loaded_providers = {}

	for provider_id, provider_opts in pairs(tickets_cfg.providers or {}) do
		local ok, provider = pcall(require, "solidtime.tickets." .. provider_id)
		if ok and provider and type(provider.setup) == "function" then
			local stored_creds = auth.get_provider_creds(provider_id)
			local effective_opts = vim.tbl_extend("force", provider_opts or {}, stored_creds)
			provider.setup(effective_opts)
			loaded_providers[provider_id] = true
			logger.debug("solidtime: loaded ticket provider '" .. provider_id .. "'")
		elseif not ok then
			logger.warn("solidtime: failed to load ticket provider '" .. provider_id .. "': " .. tostring(provider))
		end
	end

	local seen_ids = {}
	local auth_lines = auth.list_provider_ids and auth.list_provider_ids() or {}
	for _, provider_id in ipairs(auth_lines) do
		if not loaded_providers[provider_id] and not seen_ids[provider_id] then
			seen_ids[provider_id] = true
			local ok, provider = pcall(require, "solidtime.tickets." .. provider_id)
			if ok and provider and type(provider.setup) == "function" then
				local stored_creds = auth.get_provider_creds(provider_id)
				provider.setup(stored_creds)
				logger.debug("solidtime: auto-loaded ticket provider '" .. provider_id .. "' from auth store")
			end
		end
	end

	M.RegisterCommands()
	M.setup_keymaps()
	logger.debug("solidtime.nvim setup complete.")
end

function M.setup_keymaps()
	local km = config.get().keymaps

	local function map(lhs, fn, desc)
		if lhs and lhs ~= false then
			vim.keymap.set("n", lhs, fn, { desc = desc })
		end
	end

	map(km.open, function()
		buffer.open_tab("timer")
	end, "Open SolidTime Timer")
	map(km.start, function()
		buffer.startScreen()
	end, "Start SolidTime Timer")
	map(km.stop, function()
		tracker.stop()
	end, "Stop SolidTime Timer")
	map(km.edit_active, function()
		buffer.editActiveEntry()
	end, "Edit active SolidTime entry")
	map(km.reload, function()
		M.reload()
	end, "Reload SolidTime")
end

function M.RegisterCommands()
	local tickets_mod = require("solidtime.tickets")

	vim.api.nvim_create_user_command("SolidTime", function(opts)
		local subcmd = opts.fargs[1]
		local arg2 = opts.fargs[2]

		if not subcmd or subcmd == "open" then
			buffer.open_tab("timer")
		elseif subcmd == "auth" then
			if arg2 and arg2 ~= "" then
				local provider = tickets_mod.get(arg2)
				if not provider then
					local ok, loaded = pcall(require, "solidtime.tickets." .. arg2)
					if ok then
						provider = loaded
					end
				end
				if provider then
					auth.prompt_provider_credentials(provider)
				else
					print("Unknown ticket provider: " .. arg2)
				end
			else
				auth.prompt_api_key()
			end
		elseif subcmd == "start" then
			buffer.startScreen()
		elseif subcmd == "stop" then
			tracker.stop()
		elseif subcmd == "edit" then
			buffer.open_tab("timer")
		elseif subcmd == "unproject" then
			autotrack.unregister_current_project()
		elseif subcmd == "projects" then
			buffer.open_tab("projects")
		elseif subcmd == "clients" then
			buffer.open_tab("clients")
		elseif subcmd == "entries" then
			buffer.open_tab("entries")
		elseif subcmd == "tasks" then
			buffer.open_tab("tasks")
		elseif subcmd == "status" then
			buffer.open_tab("status")
		elseif subcmd == "tickets" then
			buffer.open_tab("tickets")
		elseif subcmd == "reload" then
			M.reload()
		else
			print(
				"Usage: :SolidTime [auth [<provider>]|open|start|stop|edit|unproject|projects|clients|entries|tasks|tickets|status|reload]"
			)
		end
	end, {
		nargs = "*",
		complete = function(arg_lead, cmd_line, _)
			local parts = vim.split(cmd_line, "%s+", { trimempty = true })
			local completing_provider = (parts[2] == "auth") and (#parts > 2 or arg_lead == "")
			if completing_provider then
				local ids = {}
				for _, p in ipairs(tickets_mod.list()) do
					table.insert(ids, p.id)
				end
				if arg_lead and arg_lead ~= "" then
					local filtered = {}
					for _, id in ipairs(ids) do
						if id:sub(1, #arg_lead) == arg_lead then
							table.insert(filtered, id)
						end
					end
					return filtered
				end
				return ids
			end
			return {
				"auth",
				"clients",
				"edit",
				"entries",
				"open",
				"projects",
				"reload",
				"start",
				"status",
				"stop",
				"tasks",
				"tickets",
				"unproject",
			}
		end,
	})
end

function M.reload()
	tracker.stop_tracking()

	local solidtime_modules = {}
	for name, _ in pairs(package.loaded) do
		if name:match("^solidtime%.") or name == "solidtime" then
			table.insert(solidtime_modules, name)
			package.loaded[name] = nil
		end
	end

	local ok = pcall(vim.cmd, "Lazy reload solidtime.nvim")
	if not ok then
		require("solidtime").setup()
	end
end
return M
