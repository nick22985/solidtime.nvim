local M = {}

local api_config_store = vim.fn.expand("~/.solidtime_api_config")

function M.set_api_key_and_url()
	local url = require("solidtime.config").get().api_url
	local key = vim.g.solidtime_api_key

	if not key or key == "" then
		print("API key is not set.")
		return
	end

	local lines = {}
	local url_exists = false
	local f = io.open(api_config_store, "r")
	if f then
		for line in f:lines() do
			if line:find("^url=") then
				local existing_url = line:sub(5)
				if existing_url == url then
					url_exists = true
					table.insert(lines, "url=" .. url)
					table.insert(lines, "key=" .. key)
				else
					table.insert(lines, line)
				end
			else
				table.insert(lines, line)
			end
		end
		f:close()
	end

	if not url_exists then
		table.insert(lines, "url=" .. url)

		table.insert(lines, "key=" .. key)
	end

	local f_write = io.open(api_config_store, "w")
	if f_write then
		for _, line in ipairs(lines) do
			f_write:write(line .. "\n")
		end
		f_write:close()
		print("SolidTime API key and URL have been updated successfully!")
	else
		print("Failed to save API key and URL!")
	end
end

function M.get_api_key_for_url(url)
	local f = io.open(api_config_store, "r")
	if f then
		for line in f:lines() do
			if line:find("^url=") then
				local existing_url = line:sub(5)
				if existing_url == url then
					local key_line = f:read()
					if key_line and key_line:find("^key=") then
						local key = key_line:sub(5)
						f:close()
						return key
					end
				end
			end
		end
		f:close()
	end
	return nil
end

-- Function to prompt for the API key (URL is taken from config)
function M.prompt_api_key()
	vim.ui.input({ prompt = "Enter SolidTime API Key: " }, function(input)
		if input and input ~= "" then
			vim.g.solidtime_api_key = input
			M.set_api_key_and_url() -- Save the key and URL together
		else
			print("API key not set.")
		end
	end)
end

return M
