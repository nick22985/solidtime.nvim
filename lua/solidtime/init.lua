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

	-- Load plugins.
	-- Built-in plugins (under solidtime.plugins.*) are always loaded.
	-- Users can pass options to them and add third-party plugins via config:
	--   plugins = {
	--     tickets = { providers = { freedcamp = {} } },          -- built-in (options)
	--     ["my_solidtime_addon"] = { some_option = true },       -- third-party
	--   }
	local plugins_mod = require("solidtime.plugins")
	local plugins_cfg = config.get().plugins or {}

	-- Built-in plugins: always loaded even without explicit config.
	local BUILTIN_PLUGINS = { "tickets" }
	for _, builtin_id in ipairs(BUILTIN_PLUGINS) do
		local plugin_opts = plugins_cfg[builtin_id] or {}
		local ok, plugin_mod = pcall(require, "solidtime.plugins." .. builtin_id)
		if ok and plugin_mod then
			if type(plugin_mod.register) == "function" then
				plugin_mod.register()
			end
			if type(plugin_mod.setup) == "function" then
				plugin_mod.setup(plugin_opts)
			end
			logger.debug("solidtime: loaded built-in plugin '" .. builtin_id .. "'")
		end
	end

	-- Third-party / additional plugins from config.
	for plugin_id, plugin_opts in pairs(plugins_cfg) do
		-- Skip built-in plugins (already loaded above).
		local is_builtin = false
		for _, bid in ipairs(BUILTIN_PLUGINS) do
			if plugin_id == bid then
				is_builtin = true
				break
			end
		end
		if not is_builtin then
			-- Try built-in path first, then fall back to the raw id as a module path.
			local ok, plugin_mod = pcall(require, "solidtime.plugins." .. plugin_id)
			if not ok then
				ok, plugin_mod = pcall(require, plugin_id)
			end
			if ok and plugin_mod then
				if type(plugin_mod.register) == "function" then
					plugin_mod.register()
				end
				if type(plugin_mod.setup) == "function" then
					plugin_mod.setup(plugin_opts)
				end
				logger.debug("solidtime: loaded plugin '" .. plugin_id .. "'")
			elseif not ok then
				logger.warn("solidtime: failed to load plugin '" .. plugin_id .. "': " .. tostring(plugin_mod))
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
	local plugins_mod = require("solidtime.plugins")

	-- Built-in subcommands
	local builtin_commands = {
		open = function()
			buffer.open_tab("timer")
		end,
		start = function()
			buffer.startScreen()
		end,
		stop = function()
			tracker.stop()
		end,
		edit = function()
			buffer.open_tab("timer")
		end,
		unproject = function()
			autotrack.unregister_current_project()
		end,
		projects = function()
			buffer.open_tab("projects")
		end,
		clients = function()
			buffer.open_tab("clients")
		end,
		entries = function()
			buffer.open_tab("entries")
		end,
		tasks = function()
			buffer.open_tab("tasks")
		end,
		status = function()
			buffer.open_tab("status")
		end,
		reload = function()
			M.reload()
		end,
	}

	vim.api.nvim_create_user_command("SolidTime", function(opts)
		local subcmd = opts.fargs[1]
		local arg2 = opts.fargs[2]

		if not subcmd or subcmd == "open" then
			buffer.open_tab("timer")
		elseif subcmd == "auth" then
			if arg2 and arg2 ~= "" then
				local provider = plugins_mod.find_auth_provider(arg2)
				if provider then
					auth.prompt_provider_credentials(provider)
				else
					print("Unknown auth provider: " .. arg2)
				end
			else
				auth.prompt_api_key()
			end
		elseif builtin_commands[subcmd] then
			builtin_commands[subcmd]()
		else
			-- Check plugin commands
			local plugin_cmds = plugins_mod.get_all_commands()
			local handled = false
			for _, cmd in ipairs(plugin_cmds) do
				if cmd.name == subcmd then
					cmd.handler(arg2)
					handled = true
					break
				end
			end
			if not handled then
				local cmd_list = "auth|open|start|stop|edit|unproject|projects|clients|entries|tasks|status|reload"
				for _, cmd in ipairs(plugin_cmds) do
					cmd_list = cmd_list .. "|" .. cmd.name
				end
				print("Usage: :SolidTime [" .. cmd_list .. "]")
			end
		end
	end, {
		nargs = "*",
		complete = function(arg_lead, cmd_line, _)
			local parts = vim.split(cmd_line, "%s+", { trimempty = true })
			local completing_provider = (parts[2] == "auth") and (#parts > 2 or arg_lead == "")
			if completing_provider then
				local ids = plugins_mod.all_auth_provider_ids()
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
			local completions = {
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
				"unproject",
			}
			for _, cmd in ipairs(plugins_mod.get_all_commands()) do
				table.insert(completions, cmd.name)
			end
			table.sort(completions)
			return completions
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
