local api = require("solidtime.api")
local tracker = require("solidtime.tracker")

local M = {}
M.floating_window = nil -- Store the floating window object

local function format_iso8601(timestamp)
	return os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp)
end

local function create_window_config()
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

	config = vim.tbl_extend("keep", config, default_config)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, enter or false, config)

	return { buf = buf, win = win }
end

-- Buffer management functions
local function configure_buffer(buf)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("readonly", true, { buf = buf })
end

local function update_buffer_content(buf, lines)
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_set_option_value("readonly", false, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("readonly", true, { buf = buf })
end

local function setup_window_controls(bufnr)
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
		-- the enter key functionality
	end, { buffer = bufnr, desc = "Select Data" })
end

local function display_data(data_provider)
	if not M.floating_window then
		local window_config = create_window_config()
		M.floating_window = create_floating_window(window_config, true)
		setup_window_controls(M.floating_window.buf)
		update_buffer_content(M.floating_window.buf, { "Loading..." })
		configure_buffer(M.floating_window.buf)
	end

	vim.schedule(function()
		local success, result = pcall(data_provider)

		if not success then
			update_buffer_content(M.floating_window.buf, {
				"Error fetching data: " .. tostring(result),
			})
			return
		end

		if result.error then
			update_buffer_content(M.floating_window.buf, {
				"Error fetching data: " .. tostring(result.error),
			})
			return
		end

		update_buffer_content(M.floating_window.buf, result.lines)
	end)
end

local function get_user_memberships_data()
	local memberships_result = api.getUserMemberships()
	if not memberships_result then
		return { error = "Failed to fetch memberships" }
	end

	if not memberships_result.data then
		return { error = memberships_result.error }
	end

	local lines = {}
	for _, membership in ipairs(memberships_result.data) do
		table.insert(lines, string.format("Organization: %s", membership.organization.name))
		table.insert(lines, string.format("Role: %s", membership.role))
		table.insert(lines, "")
	end

	return { lines = lines }
end

local function get_user_time_entry_data()
	local results = vim.iter({
		api.getUserMemberships(),
		api.getUserTimeEntry(),
	}):totable()

	local memberships_result = results[1]
	if not memberships_result.data then
		return { error = memberships_result.error }
	end

	local time_entry_result = results[2]
	if not time_entry_result.data then
		return { error = time_entry_result.error }
	end

	local entry = time_entry_result.data
	local lines = {
		string.format("ID: %s", entry.id),
		string.format("Organization: %s", entry.organization_id),
		string.format("Project: %s", entry.project_id),
		string.format("Billable: %s", entry.billable),
		string.format("Description: %s", entry.description),
		string.format("Start: %s", entry.start),
		string.format("End: %s", entry["end"]),
	}

	return { lines = lines }
end

-- Public API functions
function M.openUserMemberShips()
	display_data(get_user_memberships_data)
end

function M.openUserCurrentTimeEntry()
	display_data(get_user_time_entry_data)
end

function M.selectActiveOrganization()
	local organizations = api.getUserMemberships()
	if not organizations or #organizations.data == 0 then
		print("No organizations found.")
		return
	end
	vim.ui.select(organizations.data, {
		prompt = "Select an organization",
		format_item = function(line)
			return string.format("%s (%s)", line.organization.name, line.role)
		end,
	}, function(selected)
		if selected then
			return tracker.selectActiveOrganization(selected.organization.id, selected.id)
		else
			-- print("No organization selected")
		end
	end)
end

function M.selectActiveProject()
	local organization_id = tracker.storage.current_infomation.organization_id
	if not organization_id then
		print("No organization selected.")
		return
	end
	local projects = api.getOrganizationProjects(organization_id)
	if not projects or #projects.data == 0 then
		print("No projects found.")
		return
	end
	table.insert(projects.data, {
		id = "clear",
		name = "Clear Project",
	})
	vim.ui.select(projects.data, {
		prompt = "Select a project",
		format_item = function(line)
			return string.format("%s", line.name)
		end,
	}, function(selected)
		if selected then
			return tracker.selectActiveProject(selected.id)
		else
			-- print("No project selected")
		end
	end)
end

function M.startScreen()
	-- Implementation pending
end

return M
