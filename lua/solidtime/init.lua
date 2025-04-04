local auth = require("solidtime.auth")
local config = require("solidtime.config")
local logger = require("solidtime.logger")
local buffer = require("solidtime.buffer")
local tracker = require("solidtime.tracker")

local M = {}

--- Setup function for solidtime.nvim
--- @param opts table|nil Options for solidtime
function M.setup(opts)
	opts = opts or {}

	config.setup(opts)
	logger.init()

	logger.debug("Setting up solidtime.nvim...")

	tracker.init()

	-- Registers default commands
	M.RegisterCommands()
	M.setup_keymaps()
	logger.debug("solidtime.nvim setup complete.")
end

function M.setup_keymaps()
	-- Keymaps for solidtime.nvim
	vim.keymap.set("n", "<leader>so", function()
		-- buffer.openUserCurrentTimeEntry()
		M.open()
	end, { desc = "Open SolidTime" })

	vim.keymap.set("n", "<leader>ts", function()
		tracker.start()
	end, { desc = "Start SolidTime Timer" })
	vim.keymap.set("n", "<leader>te", function()
		tracker.stop()
	end, { desc = "Stop SolidTime Timer" })
	vim.keymap.set("n", "<leader>tr", function()
		M.reload()
	end, { desc = "Reload SolidTime Timer" })
end

-- Register commands for solidtime.nvim
function M.RegisterCommands()
	-- setup api key
	vim.api.nvim_create_user_command("SolidTime", function(opts)
		local subcmd = opts.fargs[1]

		if subcmd == "auth" then
			auth.prompt_api_key()
		elseif subcmd == "start" then
			tracker.start()
		elseif subcmd == "stop" then
			tracker.stop()
		elseif subcmd == "reload" then
			M.reload()
		else
			print("Unknown command. Usage: :SolidTime auth")
		end
	end, {
		nargs = "?",
		complete = function()
			return { "auth", "reload", "start", "stop" }
		end,
	})
end

function M.reload()
	-- local oldConfig = config.get()
	-- get all loaded modules from package.loaded starting with solidtime.*

	-- stop timers and save data
	tracker.stop_tracking()

	local solidtime_modules = {}
	for name, _ in pairs(package.loaded) do
		if name:match("^solidtime*") then
			table.insert(solidtime_modules, name)
			package.loaded[name] = nil
		end
	end
	-- print("Unloaded modules: " .. vim.inspect(solidtime_modules))

	vim.cmd("Lazy reload solidtime.nvim")
	-- print("Reloaded solidtime.nvim")
end
function M.open()
	buffer.selectActiveProject()
end

return M
