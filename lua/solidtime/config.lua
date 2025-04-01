local auth = require("solidtime.auth")

local M = {}

-- Default configuration
M.defaults = {
	api_key = nil, -- API key (set by user via auth)
	api_url = "https://app.solidtime.io/api/v1",
	enable_logging = true, -- Enable logging (default: true)
	debug_mode = false, -- Debug mode (default: false)
	storage_dir = vim.fn.expand("~/.local/share/nvim/solidtime"),
}

-- Current configuration
M.options = {}

--- Merges user config with defaults
--- @param user_config table|nil User-provided configuration
function M.setup(user_config)
	user_config = user_config or {}

	-- Merge defaults with user settings
	M.options = vim.tbl_extend("force", M.defaults, user_config)

	local stored_api_key = auth.get_api_key_for_url(user_config.api_url) or nil
	M.options.api_key = stored_api_key
end

--- Retrieves the configuration
--- @return table The merged configuration
function M.get()
	return M.options
end

return M
