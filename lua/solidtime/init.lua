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
	vim.api.nvim_create_user_command("SolidTime", function(opts)
		local subcmd = opts.fargs[1]

		if not subcmd or subcmd == "open" then
			buffer.open_tab("timer")
		elseif subcmd == "auth" then
			auth.prompt_api_key()
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
		elseif subcmd == "reload" then
			M.reload()
		else
			print("Usage: :SolidTime [auth|open|start|stop|edit|unproject|projects|clients|entries|tasks|status|reload]")
		end
	end, {
		nargs = "?",
		complete = function()
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
