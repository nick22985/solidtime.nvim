local config = require("solidtime.config")
local tracker = require("solidtime.tracker")
local logger = require("solidtime.logger")
local ipc = require("solidtime.ipc")

local M = {}

local last_project_name = nil

local is_startup = false

local idle_warn_timer = nil
local idle_stop_timer = nil
local idle_warned = false

local function cancel_idle_timers()
	if idle_warn_timer then
		pcall(vim.fn.timer_stop, idle_warn_timer)
		idle_warn_timer = nil
	end
	if idle_stop_timer then
		pcall(vim.fn.timer_stop, idle_stop_timer)
		idle_stop_timer = nil
	end
	idle_warned = false
end

local function reset_idle_timers()
	cancel_idle_timers()

	local cfg = config.get()
	local warn_ms = (cfg.idle_warn_timeout or 0) * 60 * 1000
	local stop_ms = (cfg.idle_stop_timeout or 0) * 60 * 1000

	if not tracker.storage.active_entry then
		return
	end

	if warn_ms > 0 then
		idle_warn_timer = vim.fn.timer_start(warn_ms, function()
			idle_warn_timer = nil
			if not tracker.storage.active_entry then
				return
			end
			idle_warned = true
			vim.schedule(function()
				vim.notify(
					"No activity for "
						.. cfg.idle_warn_timeout
						.. " min — still tracking?\n"
						.. "Stop with <leader>te or it will auto-stop in "
						.. ((cfg.idle_stop_timeout or 0) - (cfg.idle_warn_timeout or 0))
						.. " min.",
					vim.log.levels.WARN,
					{ title = "SolidTime" }
				)
			end)
		end)
	end

	if stop_ms > 0 then
		idle_stop_timer = vim.fn.timer_start(stop_ms, function()
			idle_stop_timer = nil
			if not tracker.storage.active_entry then
				return
			end
			vim.schedule(function()
				vim.notify(
					"Auto-stopped: no activity for " .. cfg.idle_stop_timeout .. " min.",
					vim.log.levels.INFO,
					{ title = "SolidTime" }
				)
				tracker.stop()
			end)
		end)
	end
end

function M.on_activity()
	if not tracker.storage.active_entry then
		return
	end
	if idle_warned then
		idle_warned = false
		vim.notify("Activity detected — timer still running.", vim.log.levels.INFO, { title = "SolidTime" })
	end
	reset_idle_timers()
end

---@return table<string, table>
local function read_projects_config()
	local path = config.get().projects_config_file
	if not path then
		return {}
	end

	local f = io.open(path, "r")
	if not f then
		return {}
	end

	local content = f:read("*all")
	f:close()

	if not content or content == "" then
		return {}
	end

	local ok, decoded = pcall(vim.fn.json_decode, content)
	if not ok or type(decoded) ~= "table" then
		logger.warn("solidtime: projects config is not valid JSON: " .. path)
		return {}
	end

	return decoded
end
M.read_config = read_projects_config

---@param projects table<string, table>
local function write_projects_config(projects)
	local path = config.get().projects_config_file
	if not path then
		return
	end

	local dir = vim.fn.fnamemodify(path, ":h")
	vim.fn.mkdir(dir, "p")

	local f = io.open(path, "w")
	if not f then
		logger.error("solidtime: could not write projects config to " .. path)
		return
	end
	f:write(vim.fn.json_encode(projects))
	f:close()
end
M.write_config = write_projects_config

---@param file_path string|nil  absolute path of the file to check
---@return string|nil
local function detect_project_for_path(file_path)
	local dir = file_path and vim.fn.fnamemodify(file_path, ":h") or vim.fn.getcwd()

	local git_root =
		vim.fn.systemlist("git -C " .. vim.fn.shellescape(dir) .. " rev-parse --show-toplevel 2>/dev/null")[1]
	if git_root and git_root ~= "" and not git_root:match("^fatal") then
		return vim.fn.fnamemodify(git_root, ":t")
	end

	return vim.fn.fnamemodify(dir, ":t")
end

---@return string|nil
function M.detect_project()
	return detect_project_for_path(nil)
end

---@param bufnr integer
---@return string|nil
function M.detect_project_for_buf(bufnr)
	local file = vim.api.nvim_buf_get_name(bufnr)
	if not file or file == "" then
		return nil
	end

	local oil_path = file:match("^oil://(.*)")
	if oil_path then
		return detect_project_for_path(oil_path)
	end

	if file:match("^%w+://") then
		return nil
	end

	return detect_project_for_path(file)
end

---@param project_name string  git/cwd name
---@param project_cfg table    entry from projects.json
local function notify_auto_started(project_name, project_cfg)
	local lines = { "Auto-started: " .. project_name }
	if project_cfg.default_description and project_cfg.default_description ~= "" then
		table.insert(lines, "Desc:     " .. project_cfg.default_description)
	end
	if project_cfg.default_billable then
		table.insert(lines, "Billable: Yes")
	end
	if project_cfg.default_tags and #project_cfg.default_tags > 0 then
		table.insert(lines, "Tags:     " .. table.concat(project_cfg.default_tags, ", "))
	end
	table.insert(lines, "Edit with <leader>tx")
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "SolidTime" })
end

---@param project_name string
local function handle_project(project_name)
	if project_name == last_project_name then
		M.on_activity()
		return
	end

	local startup = is_startup
	is_startup = false

	last_project_name = project_name
	cancel_idle_timers()

	local projects = read_projects_config()
	local project_cfg = projects[project_name]

	if startup and project_cfg and project_cfg.auto_start and project_cfg.solidtime_project_id then
		local api = require("solidtime.api")
		local existing = api.getUserTimeEntry()
		if existing and existing.data and existing.data.project_id == project_cfg.solidtime_project_id then
			logger.info("solidtime autotrack: adopting existing server entry for " .. project_name)
			tracker.storage.active_entry = existing.data
			tracker.storage.active_entry.tracking_type = "online"
			local ci = tracker.storage.current_information
			if not ci or not ci.organization_id then
				if project_cfg.organization_id and project_cfg.member_id then
					tracker.selectActiveOrganization(project_cfg.organization_id, project_cfg.member_id)
					ci = tracker.storage.current_information
				end
			end
			if ci then
				ci.project_id = project_cfg.solidtime_project_id
				ci.description = project_cfg.default_description or nil
				ci.billable = project_cfg.default_billable or false
				ci.tags = (project_cfg.default_tags and #project_cfg.default_tags > 0) and project_cfg.default_tags
					or nil
			end
			reset_idle_timers()
			return
		end
	end

	ipc.broadcast_stop()
	if tracker.storage.active_entry then
		tracker.stop()
	end

	if project_cfg and project_cfg.auto_start and project_cfg.solidtime_project_id then
		local ci = tracker.storage.current_information

		if not ci or not ci.organization_id then
			if project_cfg.organization_id and project_cfg.member_id then
				tracker.selectActiveOrganization(project_cfg.organization_id, project_cfg.member_id)
				ci = tracker.storage.current_information
			else
				logger.warn(
					"solidtime autotrack: no current_information and no org in project config — cannot auto-start (run :SolidTime open first)"
				)
				return
			end
		end

		ci.project_id = project_cfg.solidtime_project_id
		ci.description = project_cfg.default_description or nil
		ci.billable = project_cfg.default_billable or false
		ci.tags = (project_cfg.default_tags and #project_cfg.default_tags > 0) and project_cfg.default_tags or nil

		tracker.start()
		local notify_delay = startup and ((config.get().autotrack or {}).startup_notify_delay or 100) or 0
		if notify_delay > 0 then
			vim.defer_fn(function()
				notify_auto_started(project_name, project_cfg)
			end, notify_delay)
		else
			notify_auto_started(project_name, project_cfg)
		end
		reset_idle_timers()
	end
end

function M.on_project_change()
	vim.schedule(function()
		local project_name = M.detect_project()
		if not project_name then
			return
		end
		handle_project(project_name)
	end)
end

function M.on_focus_gained()
	vim.schedule(function()
		local bufnr = vim.api.nvim_get_current_buf()
		local project_name = M.detect_project_for_buf(bufnr) or M.detect_project()
		if not project_name then
			return
		end

		if project_name == last_project_name and tracker.storage.active_entry then
			M.on_activity()
			return
		end

		last_project_name = nil
		handle_project(project_name)
	end)
end

---@param bufnr integer
function M.on_buf_enter(bufnr)
	vim.schedule(function()
		local project_name = M.detect_project_for_buf(bufnr)
		if not project_name then
			return
		end
		handle_project(project_name)
	end)
end

function M.register_current_project()
	local project_name = M.detect_project()
	if not project_name then
		vim.notify("Could not detect project name.", vim.log.levels.ERROR)
		return
	end

	local ci = tracker.storage.current_information
	if not ci or not ci.organization_id then
		vim.notify("No organization selected. Run :SolidTime open first.", vim.log.levels.WARN)
		return
	end

	local projects = read_projects_config()
	local existing = projects[project_name] or {}

	local api = require("solidtime.api")
	local proj_result = api.getOrganizationProjects(ci.organization_id)
	if not proj_result or not proj_result.data or #proj_result.data == 0 then
		vim.notify("No projects found in your organization.", vim.log.levels.ERROR)
		return
	end

	vim.ui.select(proj_result.data, {
		prompt = "Map '" .. project_name .. "' to Solidtime project:",
		format_item = function(p)
			return p.name
		end,
	}, function(chosen_proj)
		if not chosen_proj then
			return
		end

		vim.ui.select({ "No", "Yes" }, {
			prompt = "Auto-start timer when entering this project?",
		}, function(auto_choice)
			if not auto_choice then
				return
			end
			local auto_start = auto_choice == "Yes"

			vim.ui.input({
				prompt = "Default description (leave blank for none): ",
				default = existing.default_description or "",
			}, function(desc)
				if desc == nil then
					return
				end
				desc = desc:match("^%s*(.-)%s*$")

				vim.ui.select({ "No", "Yes" }, {
					prompt = "Default billable?",
				}, function(bill_choice)
					if not bill_choice then
						return
					end

					projects[project_name] = {
						solidtime_project_id = chosen_proj.id,
						organization_id = ci.organization_id,
						member_id = ci.member_id,
						auto_start = auto_start,
						default_description = desc ~= "" and desc or nil,
						default_billable = bill_choice == "Yes",
						default_tags = existing.default_tags or {},
					}
					write_projects_config(projects)

					vim.notify(
						"Project '" .. project_name .. "' → '" .. chosen_proj.name .. "' saved.",
						vim.log.levels.INFO,
						{ title = "SolidTime" }
					)
				end)
			end)
		end)
	end)
end

function M.unregister_current_project()
	local project_name = M.detect_project()
	if not project_name then
		vim.notify("Could not detect project name.", vim.log.levels.ERROR)
		return
	end

	local projects = read_projects_config()
	if not projects[project_name] then
		vim.notify("'" .. project_name .. "' is not registered.", vim.log.levels.WARN)
		return
	end

	projects[project_name] = nil
	write_projects_config(projects)
	vim.notify("Removed '" .. project_name .. "' from auto-tracking.", vim.log.levels.INFO)
end

function M.init()
	local augroup = vim.api.nvim_create_augroup("SolidTimeAutoTrack", { clear = true })

	vim.api.nvim_create_autocmd("VimEnter", {
		group = augroup,
		once = true,
		callback = function()
			is_startup = true
			M.on_project_change()
		end,
	})

	vim.api.nvim_create_autocmd("DirChanged", {
		group = augroup,
		callback = function()
			M.on_project_change()
		end,
	})

	vim.api.nvim_create_autocmd("BufEnter", {
		group = augroup,
		callback = function(ev)
			M.on_buf_enter(ev.buf)
		end,
	})

	vim.api.nvim_create_autocmd("FocusGained", {
		group = augroup,
		callback = function()
			M.on_focus_gained()
		end,
	})

	local activity_events = { "CursorMoved", "CursorMovedI", "InsertEnter", "BufWritePost" }
	vim.api.nvim_create_autocmd(activity_events, {
		group = augroup,
		callback = function()
			M.on_activity()
		end,
	})
end

return M
