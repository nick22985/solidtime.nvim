local api = require("solidtime.api")

local M = {}
M.floating_window = nil -- Store the floating window object

-- put in utils
local function format_iso8601(timestamp)
	return os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp)
end

local function create_floating_window_config()
	local width = math.floor(vim.o.columns * 0.8)
	local height = math.floor(vim.o.lines * 0.8)

	return {
		relative = "editor",
		width = width,
		height = height,
		col = math.floor((vim.o.columns - width) / 2),
		row = math.floor((vim.o.lines - height) / 2),
		style = "minimal",
		border = "rounded",
	}
end

local function create_floating_window(config, enter)
	local default_config = {
		relative = "editor",
		style = "minimal",
		width = 30,
		height = 15,
		row = 2,
		col = 2,
	}

	if not enter then
		enter = false
	end

	config = vim.tbl_extend("keep", config, default_config)

	local buf = vim.api.nvim_create_buf(false, true) -- No file, scratch buffer
	local win = vim.api.nvim_open_win(buf, enter or false, config)

	return { buf = buf, win = win }
end

local function set_buffer_options(buf)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("readonly", true, { buf = buf })
end

local function set_buffer_content(buf, lines)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

local function update_buffer_for_data(buf, data)
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_set_option_value("readonly", false, { buf = buf })
	set_buffer_content(buf, data)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("readonly", true, { buf = buf })
end

-- @param bufnr number Buffer number
local function setup_autocmds_and_keymaps(bufnr)
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(M.floating_window.win),
		callback = function()
			if M.floating_window and M.floating_window.buf == bufnr then
				M.floating_window = nil
			end
		end,
	})

	vim.keymap.set("n", "q", function()
		if M.floating_window and M.floating_window.buf == bufnr then
			vim.api.nvim_win_close(M.floating_window.win, true)
		end
	end, { buffer = bufnr, desc = "Close floating window" })

	vim.keymap.set("n", "<Esc>", function()
		if M.floating_window and M.floating_window.buf == bufnr then
			vim.api.nvim_win_close(M.floating_window.win, true)
		end
	end, { buffer = bufnr, desc = "Close floating window" })

	vim.keymap.set("n", "<CR>", function(t)
		-- the enter key need to get data etc
	end, { buffer = bufnr, desc = "Select Data" })
end

local function fetch_and_display_data(display_function)
	if not M.floating_window then
		local windowConfig = create_floating_window_config()
		M.floating_window = create_floating_window(windowConfig, true)
		setup_autocmds_and_keymaps(M.floating_window.buf)
		set_buffer_content(M.floating_window.buf, { "Loading..." })
		set_buffer_options(M.floating_window.buf)
	end

	-- Fetch data and update the buffer with it
	vim.defer_fn(function()
		display_function(function(err, data)
			if err then
				update_buffer_for_data(M.floating_window.buf, {
					"Error fetching data: " .. err,
				})
				return
			end

			update_buffer_for_data(M.floating_window.buf, data)
		end)
	end, 10)
end

function M.openUserMemberShips()
	local function getDataAndTransform(callback)
		local data, err = api.getUserMemberships()
		if not data then
			callback(err, nil)

			return
		end

		local transformed_data = {}
		for _, membership in ipairs(data.data) do
			local membership_info = {
				string.format("Organization: %s", membership.organization.name),
				string.format("Role: %s", membership.role),
			}

			for _, line in ipairs(membership_info) do
				table.insert(transformed_data, line)
			end
		end

		callback(nil, transformed_data)
	end
	fetch_and_display_data(getDataAndTransform)
end

function M.openUserCurrentTimeEntry()
	local function getDataAndTransform(callback)
		local results = vim
			.iter({
				api.getUserMemberships(),
				-- api.getUserTimeEntry(),
			})
			-- :map(function(proc)
			-- 	return proc
			-- end)
			:totable()

		local getUserMemberships = results[1]
		if not getUserMemberships.data then
			callback(getUserMemberships.error, nil)
			return
		end

		api.createTimeEntry(getUserMemberships.data[1].organization.id, {
			member_id = getUserMemberships.data[1].id,
			description = "test",
			billable = true,
			start = format_iso8601(os.time()),
		}, function(err, data)
			P(err)
			if err then
				callback(err, nil)
				return
			end
		end)

		-- local currentTimeEntry = results[2]
		-- if not currentTimeEntry.data then
		-- 	callback(currentTimeEntry.error, nil)
		-- 	return
		-- end
		-- currentTimeEntry = currentTimeEntry.data

		-- local transformed_data = {}
		-- local entry = currentTimeEntry
		-- local entry_info = {
		-- 	string.format("ID: %s", entry.id),
		-- 	string.format("Organization: %s", entry.organization_id),
		-- 	string.format("Project: %s", entry.project_id),
		-- 	string.format("Billable: %s", entry.billable),
		-- 	string.format("Description: %s", entry.description),
		-- 	string.format("Start: %s", entry.start),
		-- 	string.format("End: %s", entry["end"]),
		-- }
		--
		-- for _, line in ipairs(entry_info) do
		-- 	table.insert(transformed_data, line)
		-- end

		callback(nil, { "test" })
	end
	fetch_and_display_data(getDataAndTransform)
end

function M.getOrganization(organization_id) end

return M
