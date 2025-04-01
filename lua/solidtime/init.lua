local auth = require("solidtime.auth")
local config = require("solidtime.config")
local logger = require("solidtime.logger")
local buffer = require("solidtime.buffer")
local tracker = require("solidtime.tracker")

local M = {}

--- Setup function for solidtime.nvim
--- @param opts table Options for solidtime
function M.setup(opts)
	opts = opts or {}

	config.setup(opts)

	logger.debug("Setting up solidtime.nvim...")

	tracker.init()

	-- Registers default commands
	M.RegisterCommands()
	logger.debug("solidtime.nvim setup complete.")
end

-- Register commands for solidtime.nvim
function M.RegisterCommands()
	-- setup api key
	vim.api.nvim_create_user_command("SolidTime", function(opts)
		local subcmd = opts.fargs[1]

		if subcmd == "auth" then
			auth.prompt_api_key()
		else
			print("Unknown command. Usage: :SolidTime auth")
		end
	end, {
		nargs = "?",
		complete = function()
			return { "auth" }
		end,
	})
end

function M.open()
	buffer.openUserCurrentTimeEntry()
end

vim.api.nvim_set_keymap("n", "<leader>so", ":lua require('solidtime').open()<CR>", { noremap = true, silent = true })

return M
