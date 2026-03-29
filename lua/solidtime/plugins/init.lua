--- solidtime.plugins — Plugin registry for SolidTime addons.
---
--- Plugins register themselves by calling M.register() with a definition table.
--- The core plugin (buffer.lua, init.lua) queries this module to discover
--- plugin-provided tabs, commands, and auth providers.
---
--- Plugin definition:
---   {
---     id    = "my_addon",          -- unique string key
---     name  = "My Addon",          -- human-readable label
---
---     tabs  = {                    -- (optional) tabs added to the SolidTime shell
---       { id = "my_tab", label = "My Tab", render = function() end },
---     },
---
---     commands = {                 -- (optional) :SolidTime sub-commands
---       { name = "myaddon", handler = function(fargs) end },
---     },
---
---     --- (optional) Return a credential-bearing provider object for :SolidTime auth <id>
---     find_auth_provider = function(id) end,
---
---     --- (optional) Return list of auth provider ids (for completion)
---     auth_provider_ids = function() end,
---   }

local M = {}

---@type table<string, table>
local _plugins = {}

--- Register a plugin.
---@param plugin table
function M.register(plugin)
	assert(type(plugin.id) == "string" and plugin.id ~= "", "plugin must have an id")
	_plugins[plugin.id] = plugin

	-- Register any tabs with the buffer/shell system.
	if plugin.tabs then
		local buffer = require("solidtime.buffer")
		for _, tab in ipairs(plugin.tabs) do
			buffer.register_tab(tab)
		end
	end
end

--- Return a plugin by id, or nil.
---@param id string
---@return table|nil
function M.get(id)
	return _plugins[id]
end

--- Return all registered plugins as an ordered list.
---@return table[]
function M.list()
	local out = {}
	for _, p in pairs(_plugins) do
		table.insert(out, p)
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

--- Collect all tabs declared by every registered plugin.
---@return table[]
function M.get_all_tabs()
	local tabs = {}
	for _, p in pairs(_plugins) do
		for _, tab in ipairs(p.tabs or {}) do
			table.insert(tabs, tab)
		end
	end
	return tabs
end

--- Collect all commands declared by every registered plugin.
---@return table[]
function M.get_all_commands()
	local cmds = {}
	for _, p in pairs(_plugins) do
		for _, cmd in ipairs(p.commands or {}) do
			table.insert(cmds, cmd)
		end
	end
	return cmds
end

--- Search all plugins for an auth provider matching the given id.
---@param id string
---@return table|nil  provider object suitable for auth.prompt_provider_credentials()
function M.find_auth_provider(id)
	for _, p in pairs(_plugins) do
		if p.find_auth_provider then
			local provider = p.find_auth_provider(id)
			if provider then
				return provider
			end
		end
	end
	return nil
end

--- Collect auth provider ids from all plugins (for command completion).
---@return string[]
function M.all_auth_provider_ids()
	local ids = {}
	for _, p in pairs(_plugins) do
		if p.auth_provider_ids then
			for _, id in ipairs(p.auth_provider_ids()) do
				table.insert(ids, id)
			end
		end
	end
	return ids
end

return M
