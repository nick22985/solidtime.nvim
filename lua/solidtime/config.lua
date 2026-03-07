local auth = require("solidtime.auth")

local M = {}

-- Default configuration
M.defaults = {
	api_key = nil, -- API key (set by user via auth)
	api_url = "https://app.solidtime.io/api/v1",
	enable_logging = true, -- Enable logging (default: true)
	debug_mode = false, -- Debug mode (default: false)
	storage_dir = vim.fn.expand("~/.local/share/nvim/solidtime"),
	-- Path to per-project auto-tracking config file.
	-- Format: { "<git-repo-name>": { solidtime_project_id, auto_start, default_description, ... } }
	projects_config_file = (vim.env.XDG_CONFIG_HOME or vim.fn.expand("~/.config")) .. "/solidtime/projects.json",
	-- Idle detection: minutes of no activity before warning/stopping the active timer.
	-- Set to 0 to disable. idle_stop_timeout must be > idle_warn_timeout.
	idle_warn_timeout = 5, -- minutes before a warning notification
	idle_stop_timeout = 10, -- minutes before the timer is auto-stopped (0 = never)

	-- Auto-tracking options.
	autotrack = {
		-- How long (ms) to delay the startup auto-start notification so that the
		-- notification plugin (noice, nvim-notify, etc.) has time to load.
		-- Set to 0 to notify immediately (may show the built-in blocking message).
		startup_notify_delay = 100,

		ignore_buftypes = { "nofile", "terminal", "help", "quickfix", "prompt" },

		ignore_buf_patterns = {
			"^neo%-tree ",
			"^Neogit",
			"^fugitive://",
			"^gitsigns://",
			"^diffview://",
			"^Telescope",
			"^toggleterm://",
		},
	},

	-- Keymaps. Set any value to false to disable that mapping entirely.
	keymaps = {
		-- Global mappings (set once during setup)
		open = "<leader>so", -- Open SolidTime (org/project picker)
		start = "<leader>ts", -- Open Start Time Entry form
		stop = "<leader>te", -- Stop the running timer immediately
		edit_active = "<leader>tx", -- Edit the active time entry
		reload = "<leader>tr", -- Reload the plugin

		-- Buffer-local mappings used inside every list screen and form.
		-- These apply to: projectsScreen, clientsScreen, tasksScreen,
		-- timeEntriesScreen, and all open_form instances.
		nav_down = "j", -- Move cursor down
		nav_up = "k", -- Move cursor up
		confirm = "<CR>", -- Confirm / edit highlighted item
		close = "q", -- Close the current window
		close_alt = "<Esc>", -- Alternative close (same as close)
		add = "a", -- Add / create a new item
		delete = "d", -- Delete the highlighted item
		tasks = "t", -- Open tasks for the highlighted project
		next_page = "]", -- Next page (time entries screen)
		prev_page = "[", -- Previous page (time entries screen)
	},
}

-- Current configuration
M.options = {}

--- Merges user config with defaults
--- @param user_config table|nil User-provided configuration
function M.setup(user_config)
	user_config = user_config or {}

	local merged_keymaps = vim.tbl_extend("force", M.defaults.keymaps, user_config.keymaps or {})
	local user_autotrack = user_config.autotrack or {}
	local merged_autotrack = vim.tbl_extend("force", M.defaults.autotrack, user_autotrack)
	-- List fields: user values *replace* defaults when provided; otherwise keep defaults.
	if user_autotrack.ignore_buftypes ~= nil then
		merged_autotrack.ignore_buftypes = user_autotrack.ignore_buftypes
	end
	if user_autotrack.ignore_buf_patterns ~= nil then
		merged_autotrack.ignore_buf_patterns = user_autotrack.ignore_buf_patterns
	end

	M.options = vim.tbl_extend("force", M.defaults, user_config)
	M.options.keymaps = merged_keymaps
	M.options.autotrack = merged_autotrack

	if not user_config.api_url then
		local active = auth.get_active_url()
		if active and active ~= "" then
			M.options.api_url = active
		end
	end

	local stored_api_key = auth.get_api_key_for_url(M.options.api_url)
	M.options.api_key = stored_api_key
end

--- Retrieves the configuration
--- @return table The merged configuration
function M.get()
	return M.options
end

return M
