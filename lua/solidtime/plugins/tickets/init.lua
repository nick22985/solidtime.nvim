--- solidtime.plugins.tickets — Tickets addon for SolidTime.
---
--- Provides ticket search and integration with external issue trackers
--- (Freedcamp, Planka, etc.).  Each tracker is a "provider" module that
--- registers with the provider registry.
---
--- Usage in solidtime.setup():
---   plugins = {
---     tickets = {
---       providers = {
---         freedcamp = {},
---         planka = {},
---       },
---     },
---   },
---
--- Then run :SolidTime auth freedcamp (or planka) to set credentials.

local auth = require("solidtime.auth")
local logger = require("solidtime.logger")

local M = {}

--- Register this plugin with the SolidTime plugin system.
function M.register()
	local plugins = require("solidtime.plugins")
	plugins.register({
		id = "tickets",
		name = "Tickets",

		tabs = {
			{
				id = "tickets",
				label = "Tickets",
				render = function()
					require("solidtime.plugins.tickets.ui").tab_tickets()
				end,
			},
		},

		commands = {
			{
				name = "tickets",
				handler = function()
					require("solidtime.buffer").open_tab("tickets")
				end,
			},
		},

		find_auth_provider = function(id)
			local providers = require("solidtime.plugins.tickets.providers")
			return providers.get(id)
		end,

		auth_provider_ids = function()
			local providers = require("solidtime.plugins.tickets.providers")
			local list = providers.list()
			local ids = {}
			for _, p in ipairs(list) do
				table.insert(ids, p.id)
			end
			return ids
		end,
	})
end

--- Setup the tickets plugin: load and configure providers.
---@param opts table  { providers = { freedcamp = {}, planka = {} } }
function M.setup(opts)
	opts = opts or {}
	local loaded_providers = {}

	for provider_id, provider_opts in pairs(opts.providers or {}) do
		local ok, provider = pcall(require, "solidtime.plugins.tickets." .. provider_id)
		if ok and provider and type(provider.setup) == "function" then
			local stored_creds = auth.get_provider_creds(provider_id)
			local effective_opts = vim.tbl_extend("force", provider_opts or {}, stored_creds)
			provider.setup(effective_opts)
			loaded_providers[provider_id] = true
			logger.debug("solidtime tickets: loaded provider '" .. provider_id .. "'")
		elseif not ok then
			logger.warn("solidtime tickets: failed to load provider '" .. provider_id .. "': " .. tostring(provider))
		end
	end

	-- Auto-load providers that have stored credentials but aren't in the config.
	local seen_ids = {}
	local auth_lines = auth.list_provider_ids and auth.list_provider_ids() or {}
	for _, provider_id in ipairs(auth_lines) do
		if not loaded_providers[provider_id] and not seen_ids[provider_id] then
			seen_ids[provider_id] = true
			local ok, provider = pcall(require, "solidtime.plugins.tickets." .. provider_id)
			if ok and provider and type(provider.setup) == "function" then
				local stored_creds = auth.get_provider_creds(provider_id)
				provider.setup(stored_creds)
				logger.debug("solidtime tickets: auto-loaded provider '" .. provider_id .. "' from auth store")
			end
		end
	end
end

return M
