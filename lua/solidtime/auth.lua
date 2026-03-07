local M = {}

local api_config_store = vim.fn.expand("~/.solidtime_api_config")

--- Read every line of the config file into a list.
local function read_lines()
	local lines = {}
	local f = io.open(api_config_store, "r")
	if f then
		for line in f:lines() do
			table.insert(lines, line)
		end
		f:close()
	end
	return lines
end

--- Write a list of lines back to the config file.
local function write_lines(lines)
	local f = io.open(api_config_store, "w")
	if not f then
		return false
	end
	for _, line in ipairs(lines) do
		f:write(line .. "\n")
	end
	f:close()
	return true
end

--- Return the URL that was last explicitly set as active, or nil.
function M.get_active_url()
	local lines = read_lines()
	for _, line in ipairs(lines) do
		if line:find("^active_url=") then
			return line:sub(12)
		end
	end
	return nil
end

--- Persist `url` as the active URL (overwrites any previous active_url= line).
function M.set_active_url(url)
	local lines = read_lines()
	local found = false
	for i, line in ipairs(lines) do
		if line:find("^active_url=") then
			lines[i] = "active_url=" .. url
			found = true
			break
		end
	end
	if not found then
		table.insert(lines, 1, "active_url=" .. url)
	end
	write_lines(lines)
end

--- Save a url/key pair and mark that URL as active.
--- Also updates the live config immediately.
function M.set_api_key_and_url(key, url)
	if not url then
		url = require("solidtime.config").get().api_url
	end
	if not key then
		key = vim.g.solidtime_api_key
	end

	if not key or key == "" then
		print("API key is not set.")
		return
	end

	local lines = read_lines()
	local url_exists = false
	local result = {}
	local skip_next = false

	for _, line in ipairs(lines) do
		if skip_next then
			skip_next = false
		elseif line:find("^active_url=") then
			-- will be re-inserted at the top after we rebuild
		elseif line:find("^url=") then
			local existing_url = line:sub(5)
			if existing_url == url then
				url_exists = true
				skip_next = true
				table.insert(result, "url=" .. url)
				table.insert(result, "key=" .. key)
			else
				table.insert(result, line)
			end
		else
			table.insert(result, line)
		end
	end

	if not url_exists then
		table.insert(result, "url=" .. url)
		table.insert(result, "key=" .. key)
	end

	table.insert(result, 1, "active_url=" .. url)

	if write_lines(result) then
		local cfg = require("solidtime.config").get()
		cfg.api_key = key
		cfg.api_url = url
		print("SolidTime auth saved for " .. url)
	else
		print("Failed to save SolidTime auth!")
	end
end

function M.get_api_key_for_url(url)
	if not url then
		return nil
	end
	local lines = read_lines()
	for i, line in ipairs(lines) do
		if line:find("^url=") then
			local existing_url = line:sub(5)
			if existing_url == url then
				local key_line = lines[i + 1]
				if key_line and key_line:find("^key=") then
					return key_line:sub(5)
				end
			end
		end
	end
	return nil
end

--- Normalise a raw URL string entered by the user:
--- strips whitespace, trailing slash, and appends /api/v1 if absent.
local function normalise_url(raw)
	raw = raw:match("^%s*(.-)%s*$")
	raw = raw:gsub("/$", "")
	if not raw:match("/api/v1$") then
		raw = raw .. "/api/v1"
	end
	return raw
end

--- Prompt for URL then API key.
--- - Shows the current URL as default; user can keep it or change it.
--- - If the entered URL already has a saved key, switches to it immediately
---   (no need to re-enter the key) but still asks if the user wants to update it.
--- - If the URL is new, prompts for the key.
--- Called by :SolidTime auth and the status-screen token/URL fields.
function M.prompt_api_key()
	local cfg = require("solidtime.config")
	local current_url = cfg.get().api_url

	vim.ui.input({
		prompt = "SolidTime API URL: ",
		default = current_url,
	}, function(raw_url)
		if not raw_url or raw_url:match("^%s*$") then
			print("Auth not changed.")
			return
		end

		local new_url = normalise_url(raw_url)
		local existing_key = M.get_api_key_for_url(new_url)

		if existing_key and new_url == current_url then
			vim.ui.input({
				prompt = "API Key (" .. new_url .. "): ",
				default = "",
			}, function(key)
				if not key or key:match("^%s*$") then
					print("API key not changed.")
					return
				end
				M.set_api_key_and_url(key:match("^%s*(.-)%s*$"), new_url)
			end)
		elseif existing_key then
			M.set_api_key_and_url(existing_key, new_url)
		else
			vim.ui.input({
				prompt = "API Key (" .. new_url .. "): ",
			}, function(key)
				if not key or key:match("^%s*$") then
					print("API key not set — auth not saved.")
					return
				end
				M.set_api_key_and_url(key:match("^%s*(.-)%s*$"), new_url)
			end)
		end
	end)
end

return M
