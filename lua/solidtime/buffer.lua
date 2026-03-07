local api = require("solidtime.api")
local tracker = require("solidtime.tracker")
local autotrack = require("solidtime.autotrack")
local cache = require("solidtime.cache")
local config = require("solidtime.config")

local function km()
	return (config.get().keymaps or {})
end

local function bmap(buf, lhs, fn, desc)
	if lhs and lhs ~= false and lhs ~= "" then
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
	end
end

local M = {}

local LIST_HEADER_LINES = 2

local PROJECT_COLORS = {
	{ label = "Blue", value = "#3b82f6" },
	{ label = "Green", value = "#22c55e" },
	{ label = "Red", value = "#ef4444" },
	{ label = "Yellow", value = "#eab308" },
	{ label = "Purple", value = "#a855f7" },
	{ label = "Pink", value = "#ec4899" },
	{ label = "Orange", value = "#f97316" },
	{ label = "Teal", value = "#14b8a6" },
}

local function pad(s, n)
	s = tostring(s or "")
	if #s > n then
		return s:sub(1, n - 1) .. "…"
	end
	return s .. string.rep(" ", n - #s)
end

local function list_set_lines(buf, lines)
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

local function list_close(win)
	if vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
end

local function list_set_cursor(win, idx)
	if vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_cursor(win, { LIST_HEADER_LINES + idx, 2 })
	end
end

local function list_current_idx(win, rows)
	if not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local cur = vim.api.nvim_win_get_cursor(win)[1]
	local idx = cur - LIST_HEADER_LINES
	if idx < 1 or idx > #rows then
		return nil
	end
	return idx
end

local function fields_to_vals(f)
	local vals = {}
	for _, field in ipairs(f) do
		if field.key and field.key ~= "__sep__" and field.key ~= "__action__" then
			vals[field.key] = field.value
		end
	end
	return vals
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Form engine
-- ─────────────────────────────────────────────────────────────────────────────
--
-- A "field" is a table:
--   { key = string, label = string, value = any, display = function(v)->string,
--     edit = function(current_value, on_done) }
--
-- `edit` receives the current value and a callback on_done(new_value).
-- Sentinel fields (separators, action rows) have key = nil.
--
-- open_form opens a compact floating window, renders the fields, lets the user
-- navigate with j/k and confirm each field with <CR>.  The action row (last
-- non-separator field) calls on_confirm with the final state when activated.

local FORM_WIDTH = 56 -- total inner width of the form window
local LABEL_WIDTH = 14 -- characters reserved for the label column

local function form_render_lines(fields, title)
	local inner = FORM_WIDTH
	local lines = {}

	local pad = math.floor((inner - #title) / 2)
	table.insert(lines, string.rep(" ", pad) .. title)
	table.insert(lines, string.rep("─", inner))

	for _, field in ipairs(fields) do
		if field.key == "__sep__" then
			table.insert(lines, string.rep("─", inner))
		elseif field.key == "__action__" then
			local lbl = "  " .. field.label .. "  "
			local apad = math.floor((inner - #lbl) / 2)
			table.insert(lines, string.rep(" ", apad) .. lbl)
		else
			local label_col = string.format("  %-" .. LABEL_WIDTH .. "s", field.label)
			local sep = "│ "
			local _raw = field.display and field.display(field.value) or field.value
			local value_str = (type(_raw) == "string") and _raw or ""
			local max_val = inner - #label_col - #sep - 1
			if #value_str > max_val then
				value_str = value_str:sub(1, max_val - 1) .. "…"
			end
			table.insert(lines, label_col .. sep .. value_str)
		end
	end

	return lines
end

local function form_editable_indices(fields, title_lines)
	local indices = {}
	local line = title_lines -- 0-based
	for _, field in ipairs(fields) do
		if field.key == "__sep__" then
			line = line + 1
		elseif field.key == "__action__" then
			table.insert(indices, { line = line, field = field })
			line = line + 1
		else
			table.insert(indices, { line = line, field = field })
			line = line + 1
		end
	end
	return indices
end

---@class FormField
---@field key string|nil  nil = separator  "__action__" = confirm button
---@field label string
---@field value any
---@field display function|nil  (value) -> string
---@field edit function|nil     (value, on_done) -> nil

--- Open a form floating window.
---@param fields FormField[]
---@param title string
---@param on_confirm function  called with the final fields table when action row is <CR>'d
local function open_form(fields, title, on_confirm)
	local HEADER_LINES = 2 -- title + separator
	local height = HEADER_LINES + #fields + 2 -- +2 for padding
	local width = FORM_WIDTH + 2 -- account for border

	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
	})

	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("cursorline", true, { win = win })

	local function redraw()
		local lines = form_render_lines(fields, title)
		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	end

	redraw()

	local nav = form_editable_indices(fields, HEADER_LINES)

	local cursor_idx = 1
	local function set_cursor()
		if nav[cursor_idx] then
			vim.api.nvim_win_set_cursor(win, { nav[cursor_idx].line + 1, 2 })
		end
	end
	set_cursor()

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	bmap(buf, km().nav_down, function()
		if cursor_idx < #nav then
			cursor_idx = cursor_idx + 1
			set_cursor()
		end
	end, "Next field")

	bmap(buf, km().nav_up, function()
		if cursor_idx > 1 then
			cursor_idx = cursor_idx - 1
			set_cursor()
		end
	end, "Previous field")

	bmap(buf, km().close, close, "Close form")
	bmap(buf, km().close_alt, close, "Close form")

	bmap(buf, km().confirm, function()
		local item = nav[cursor_idx]
		if not item then
			return
		end
		local field = item.field

		if field.key == "__action__" then
			close()
			on_confirm(fields)
			return
		end

		if not field.edit then
			return
		end

		field.edit(field.value, function(new_value)
			field.value = new_value
			redraw()
			vim.schedule(function()
				if vim.api.nvim_win_is_valid(win) then
					vim.api.nvim_set_current_win(win)
					set_cursor()
				end
			end)
		end)
	end, "Confirm / edit field")
end

local function edit_description(current, on_done)
	vim.ui.input({ prompt = "Description: ", default = current or "" }, function(val)
		if val == nil then
			return
		end
		val = val:match("^%s*(.-)%s*$")
		on_done(val == "" and nil or val)
	end)
end

local function edit_billable(current, on_done)
	local choices = { "No", "Yes" }
	vim.ui.select(choices, {
		prompt = "Billable?",
	}, function(choice)
		if choice == nil then
			return
		end
		on_done(choice == "Yes")
	end)
end

local function edit_tags(org_id, current_ids, on_done)
	api.getOrganizationTags(org_id, function(err, data)
		if err or not data or not data.data then
			vim.notify(
				"Failed to fetch tags: " .. (err or "unknown error"),
				vim.log.levels.ERROR
			)
			on_done(current_ids)
			return
		end

		local all_tags = data.data
		local selected = {}
		if current_ids then
			for _, id in ipairs(current_ids) do
				selected[id] = true
			end
		end

		local function loop()
			local items = {}
			for _, tag in ipairs(all_tags) do
				table.insert(items, tag)
			end
			table.insert(items, { id = "__new__", name = "+ Create new tag…" })
			table.insert(items, { id = "__done__", name = "Done" })

			vim.ui.select(items, {
				prompt = "Tags (toggle, then Done):",
				format_item = function(item)
					if item.id == "__new__" or item.id == "__done__" then
						return item.name
					end
					return (selected[item.id] and "[x] " or "[ ] ") .. item.name
				end,
			}, function(chosen)
				if chosen == nil or chosen.id == "__done__" then
					local ids = {}
					for id in pairs(selected) do
						table.insert(ids, id)
					end
					on_done(#ids > 0 and ids or nil)
				elseif chosen.id == "__new__" then
					vim.ui.input({ prompt = "New tag name: " }, function(name)
						if not name or name:match("^%s*$") then
							loop()
							return
						end
						name = name:match("^%s*(.-)%s*$")
						api.createTag(org_id, { name = name }, function(cerr, cdata)
							if cdata and cdata.data then
								cache.invalidate_cache("organizations/" .. org_id .. "/tags")
								table.insert(all_tags, cdata.data)
								selected[cdata.data.id] = true
								vim.notify("Tag created: " .. name, vim.log.levels.INFO)
							elseif cerr then
								vim.notify("Failed to create tag: " .. cerr, vim.log.levels.ERROR)
							end
							loop()
						end)
					end)
				else
					selected[chosen.id] = selected[chosen.id] and nil or true
					loop()
				end
			end)
		end

		loop()
	end)
end

-- Returns a display string for a list of tag ids from a pre-fetched id→name map.
local function display_tags(tag_map, ids)
	if not ids or type(ids) ~= "table" or #ids == 0 then
		return "(none)"
	end
	local names = {}
	for _, id in ipairs(ids) do
		table.insert(names, tag_map[id] or id)
	end
	return table.concat(names, ", ")
end

-- Returns a display string for a project id from a pre-fetched id→name map.
local function display_project(project_map, project_id)
	if not project_id then
		return "(none)"
	end
	return project_map[project_id] or project_id
end

-- Returns a display string for a task id from a pre-fetched id→name map.
local function display_task(task_map, task_id)
	if not task_id then
		return "(none)"
	end
	return task_map[task_id] or task_id
end

-- Task picker: single-select from tasks belonging to project_id.
-- Returns the chosen task_id (or nil) via on_done.
-- Also updates task_map in-place when a new task is created.
---@param org_id string
---@param project_id string|nil
---@param current_task_id string|nil
---@param task_map table  id→name, updated when new task created
---@param on_done function
local function edit_task(org_id, project_id, current_task_id, task_map, on_done)
	if not project_id then
		vim.notify("Select a project first.", vim.log.levels.WARN)
		on_done(current_task_id)
		return
	end
	api.getOrganizationTasks(org_id, { project_id = project_id }, function(err, data)
		if err or not data or not data.data then
			vim.notify(
				"Failed to fetch tasks: " .. (err or "unknown error"),
				vim.log.levels.ERROR
			)
			on_done(current_task_id)
			return
		end
		-- Refresh task_map with latest data
		for k in pairs(task_map) do task_map[k] = nil end
		for _, t in ipairs(data.data) do
			task_map[t.id] = t.name
		end

		local items = { { id = nil, name = "(no task)" } }
		for _, t in ipairs(data.data) do
			table.insert(items, t)
		end
		table.insert(items, { id = "__new__", name = "+ Create new task…" })
		vim.ui.select(items, {
			prompt = "Task:",
			format_item = function(t)
				if not t.id or t.id == "__new__" then
					return t.name
				end
				return (t.is_done and "[done] " or "") .. t.name
			end,
		}, function(choice)
			if choice == nil then
				on_done(current_task_id)
				return
			end
			if choice.id == "__new__" then
				vim.ui.input({ prompt = "New task name: " }, function(name)
					if not name or name:match("^%s*$") then
						on_done(current_task_id)
						return
					end
					name = name:match("^%s*(.-)%s*$")
					api.createTask(org_id, {
						name = name,
						is_done = false,
						project_id = project_id,
					}, function(cerr, cdata)
						if cerr then
							vim.notify("Failed to create task: " .. cerr, vim.log.levels.ERROR)
							on_done(current_task_id)
							return
						end
						local new_id = cdata and cdata.data and cdata.data.id
						if new_id then
							task_map[new_id] = name
							vim.notify("Task created: " .. name, vim.log.levels.INFO)
							on_done(new_id)
						else
							on_done(current_task_id)
						end
					end)
				end)
				return
			end
			on_done(choice.id)
		end)
	end)
end

--- Show a client picker for org_id.
--- Includes "(no client)" and "+ Create new client…" options.
--- Calls done(client_id_or_nil) when the user picks or cancels.
---@param org_id string
---@param current_id string|nil
---@param clients table  already-fetched list (may be empty)
---@param done function
local function pick_client(org_id, current_id, clients, done)
	local items = { { id = nil, name = "(no client)" } }
	for _, c in ipairs(clients) do
		table.insert(items, c)
	end
	table.insert(items, { id = "__new__", name = "+ Create new client…" })
	vim.ui.select(items, {
		prompt = "Client:",
		format_item = function(c)
			return c.name
		end,
	}, function(choice)
		if not choice then
			done(current_id)
			return
		end
		if choice.id == "__new__" then
			vim.ui.input({ prompt = "New client name: " }, function(name)
				if not name or name:match("^%s*$") then
					done(current_id)
					return
				end
				name = name:match("^%s*(.-)%s*$")
				api.createClient(org_id, { name = name }, function(cerr, cdata)
					if cdata and cdata.data then
						table.insert(clients, cdata.data)
						vim.notify("Client created: " .. name, vim.log.levels.INFO)
						done(cdata.data.id)
					else
						vim.notify("Failed to create client: " .. (cerr or "?"), vim.log.levels.ERROR)
						done(current_id)
					end
				end)
			end)
		else
			done(choice.id)
		end
	end)
end

local function edit_project(org_id, current_id, project_map, on_done)
	api.getOrganizationProjects(org_id, function(err, data)
		-- Refresh project_map in-place
		for k in pairs(project_map) do project_map[k] = nil end
		if data and data.data then
			for _, p in ipairs(data.data) do
				project_map[p.id] = p.name
			end
		end

		local items = {}
		table.insert(items, { id = "__keep__", name = "Keep current" })
		table.insert(items, { id = "__new__", name = "+ Create new project…" })
		if data and data.data then
			for _, p in ipairs(data.data) do
				table.insert(items, p)
			end
		end
		table.insert(items, { id = "__clear__", name = "(none)" })

		vim.ui.select(items, {
			prompt = "Project:",
			format_item = function(p)
				return p.name
			end,
		}, function(choice)
			if choice == nil then
				return
			end
			if choice.id == "__keep__" then
				on_done(current_id)
			elseif choice.id == "__clear__" then
				on_done(nil)
			elseif choice.id == "__new__" then
				vim.ui.input({ prompt = "Project name: " }, function(name)
					if not name or name:match("^%s*$") then
						on_done(current_id)
						return
					end
					name = name:match("^%s*(.-)%s*$")
					vim.ui.select(PROJECT_COLORS, {
						prompt = "Color:",
						format_item = function(c)
							return c.label
						end,
					}, function(color)
						if not color then
							on_done(current_id)
							return
						end
						vim.ui.select({ "No", "Yes" }, { prompt = "Billable by default?" }, function(bill)
							if not bill then
								on_done(current_id)
								return
							end
							local billable = bill == "Yes"
							api.getOrganizationClients(org_id, function(cerr, cdata)
								local clients = (cdata and cdata.data) or {}
								pick_client(org_id, nil, clients, function(client_id)
									api.createProject(org_id, {
										name = name,
										color = color.value,
										billable_by_default = billable,
										is_billable = billable,
										client_id = client_id or vim.NIL,
									}, function(perr, pdata)
										if perr then
											vim.notify("Failed to create project: " .. perr, vim.log.levels.ERROR)
											on_done(current_id)
										elseif pdata and pdata.data then
											cache.invalidate_cache("organizations/" .. org_id .. "/projects")
											project_map[pdata.data.id] = name
											vim.notify("Project created: " .. name, vim.log.levels.INFO)
											on_done(pdata.data.id)
										end
									end)
								end)
							end)
						end)
					end)
				end)
			else
				on_done(choice.id)
			end
		end)
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Org / project / tag selectors (used from M.open() and standalone)
-- ─────────────────────────────────────────────────────────────────────────────

function M.selectActiveOrganization(callback)
	api.getUserMemberships(function(err, data)
		if err or not data or not data.data or #data.data == 0 then
			vim.notify("No organizations found.", vim.log.levels.WARN)
			return
		end
		vim.ui.select(data.data, {
			prompt = "Select an organization",
			format_item = function(line)
				return string.format("%s (%s)", line.organization.name, line.role)
			end,
		}, function(selected)
			if selected then
				tracker.selectActiveOrganization(selected.organization.id, selected.id)
				if callback then
					callback()
				end
			end
		end)
	end)
end

function M.selectActiveProject()
	if not tracker.storage.current_information then
		vim.notify("No organization selected. Please select an organization first.", vim.log.levels.WARN)
		return
	end
	local org_id = tracker.storage.current_information.organization_id
	if not org_id then
		vim.notify("No organization selected.", vim.log.levels.WARN)
		return
	end
	api.getOrganizationProjects(org_id, function(err, data)
		if err or not data or not data.data then
			vim.notify("No projects found.", vim.log.levels.WARN)
			return
		end

		local items = {}
		table.insert(items, { id = "__new__", name = "+ Create new project…" })
		for _, p in ipairs(data.data) do
			table.insert(items, p)
		end
		table.insert(items, { id = "__clear__", name = "(none)" })

		vim.ui.select(items, {
			prompt = "Select a project",
			format_item = function(line)
				return line.name
			end,
		}, function(selected)
			if not selected then
				return
			end
			if selected.id == "__new__" then
				M.createProject(function(new_project)
					if new_project then
						tracker.selectActiveProject(new_project.id)
					end
				end)
			elseif selected.id == "__clear__" then
				tracker.selectActiveProject(nil)
			else
				tracker.selectActiveProject(selected.id)
			end
		end)
	end)
end

--- Standalone tag selector (used from :SolidTime tags and as a form field editor).
---@param callback function|nil  called when done
function M.selectActiveTags(callback)
	if not tracker.storage.current_information then
		tracker.storage.current_information = {}
	end
	local org_id = tracker.storage.current_information.organization_id
	if not org_id then
		vim.notify("No organization selected.", vim.log.levels.WARN)
		if callback then
			callback()
		end
		return
	end

	edit_tags(org_id, tracker.storage.current_information.tags, function(ids)
		tracker.selectActiveTags(ids)
		if callback then
			callback()
		end
	end)
end

--- Create project UI (also callable standalone).
---@param callback function|nil  called with project data on success
function M.createProject(callback)
	if not tracker.storage.current_information then
		vim.notify("No organization selected.", vim.log.levels.WARN)
		return
	end
	local org_id = tracker.storage.current_information.organization_id
	if not org_id then
		vim.notify("No organization selected.", vim.log.levels.WARN)
		return
	end

	vim.ui.input({ prompt = "Project name: " }, function(name)
		if not name or name:match("^%s*$") then
			return
		end
		name = name:match("^%s*(.-)%s*$")

		vim.ui.select(PROJECT_COLORS, {
			prompt = "Project color:",
			format_item = function(c)
				return c.label
			end,
		}, function(color_choice)
			if not color_choice then
				return
			end
			vim.ui.select({ "No", "Yes" }, { prompt = "Billable by default?" }, function(billable_choice)
				if not billable_choice then
					return
				end
				local billable = billable_choice == "Yes"
				api.getOrganizationClients(org_id, function(cerr, cdata)
					local clients = (cdata and cdata.data) or {}
					pick_client(org_id, nil, clients, function(client_id)
						api.createProject(org_id, {
							name = name,
							color = color_choice.value,
							billable_by_default = billable,
							is_billable = billable,
							client_id = client_id or vim.NIL,
						}, function(perr, pdata)
							if perr then
								vim.notify("Failed to create project: " .. perr, vim.log.levels.ERROR)
								return
							end
							cache.invalidate_cache("organizations/" .. org_id .. "/projects")
							vim.notify("Project created: " .. name, vim.log.levels.INFO)
							if callback then
								callback(pdata and pdata.data)
							end
						end)
					end)
				end)
			end)
		end)
	end)
end

---@param org_id      string
---@param initial     table   {description, billable, project_id, task_id, tags}
---@param fields_ref  table   pre-declared empty table; will be populated in-place
---@param project_map table   id→name map (pre-fetched, mutated in-place by edit_project)
---@param task_map    table   id→name map (pre-fetched, mutated in-place by edit_task)
---@param tag_map     table   id→name map (pre-fetched)
---@return table  the same table that was passed as fields_ref
local function make_time_entry_fields(org_id, initial, fields_ref, project_map, task_map, tag_map)
	fields_ref[1] = {
		key = "description",
		label = "Description",
		value = initial.description,
		display = function(v)
			return v or "(none)"
		end,
		edit = function(v, done)
			edit_description(v, done)
		end,
	}
	fields_ref[2] = {
		key = "billable",
		label = "Billable",
		value = initial.billable or false,
		display = function(v)
			return v and "Yes" or "No"
		end,
		edit = function(v, done)
			edit_billable(v, done)
		end,
	}
	fields_ref[3] = {
		key = "project",
		label = "Project",
		value = initial.project_id,
		display = function(v)
			return display_project(project_map, v)
		end,
		edit = function(v, done)
			edit_project(org_id, v, project_map, function(new_pid)
				-- clear task when project changes
				if new_pid ~= v then
					for _, f in ipairs(fields_ref) do
						if f.key == "task" then
							f.value = nil
						end
					end
					-- also clear task_map since it was for the old project
					for k in pairs(task_map) do task_map[k] = nil end
				end
				done(new_pid)
			end)
		end,
	}
	fields_ref[4] = {
		key = "task",
		label = "Task",
		value = initial.task_id,
		display = function(v)
			return display_task(task_map, v)
		end,
		edit = function(v, done)
			local proj_id
			for _, f in ipairs(fields_ref) do
				if f.key == "project" then
					proj_id = f.value
					break
				end
			end
			edit_task(org_id, proj_id, v, task_map, done)
		end,
	}
	fields_ref[5] = {
		key = "tags",
		label = "Tags",
		value = initial.tags,
		display = function(v)
			return display_tags(tag_map, v)
		end,
		edit = function(v, done)
			edit_tags(org_id, v, done)
		end,
	}
	return fields_ref
end

--- Start screen — form with description / billable / project / tags, then Start.
function M.startScreen()
	local ci = tracker.storage.current_information or {}
	local org_id = ci.organization_id

	if not org_id then
		vim.notify("No organization selected. Run :SolidTime open first.", vim.log.levels.WARN)
		return
	end

	local project_map = {}
	local task_map = {}
	local tag_map = {}
	local fetched_projects = 0
	local fetched_tags = 0
	local fetched_tasks = 0
	local need_tasks = ci.project_id and ci.task_id and 1 or 0

	local function open_start_form()
		local fields = {}
		make_time_entry_fields(org_id, {
			description = ci.description,
			billable = ci.billable,
			project_id = ci.project_id,
			task_id = ci.task_id,
			tags = ci.tags,
		}, fields, project_map, task_map, tag_map)
		fields[6] = { key = "__sep__", label = "" }
		fields[7] = { key = "__action__", label = "▶  Start" }

		open_form(fields, "Start Time Entry", function(f)
			local vals = fields_to_vals(f)

			if not tracker.storage.current_information then
				tracker.storage.current_information = {}
			end
			tracker.storage.current_information.description = vals.description
			tracker.storage.current_information.billable = vals.billable
			tracker.storage.current_information.project_id = vals.project
			tracker.storage.current_information.task_id = vals.task
			tracker.selectActiveTags(vals.tags)

			tracker.start()

			autotrack.save_project_state(autotrack.detect_project(), {
				task_id = vals.task,
				description = vals.description,
				billable = vals.billable,
				tags = vals.tags,
			})
		end)
	end

	local function maybe_open()
		if fetched_projects == 1 and fetched_tags == 1 and fetched_tasks == need_tasks then
			open_start_form()
		end
	end

	api.getOrganizationProjects(org_id, function(err, data)
		if not err and data and data.data then
			for _, p in ipairs(data.data) do
				project_map[p.id] = p.name
			end
		end
		fetched_projects = 1
		maybe_open()
	end)

	if need_tasks == 1 then
		api.getOrganizationTasks(org_id, { project_id = ci.project_id }, function(err, data)
			if not err and data and data.data then
				for _, t in ipairs(data.data) do
					task_map[t.id] = t.name
				end
			end
			fetched_tasks = 1
			maybe_open()
		end)
	end

	api.getOrganizationTags(org_id, function(err, data)
		if not err and data and data.data then
			for _, t in ipairs(data.data) do
				tag_map[t.id] = t.name
			end
		end
		fetched_tags = 1
		maybe_open()
	end)
end

--- Internal: commit edits to an active entry (API + local storage).
---@param entry table
---@param org_id string
---@param description string|nil
---@param billable boolean
---@param tags string[]|nil
---@param project_id string|nil
---@param task_id string|nil
local function finalize_edit(entry, org_id, description, billable, tags, project_id, task_id)
	entry.description = description
	entry.billable = billable
	entry.tags = tags
	entry.project_id = project_id
	entry.task_id = task_id
	tracker.storage.active_entry = entry

	if tracker.storage.current_information then
		tracker.storage.current_information.description = description
		tracker.storage.current_information.billable = billable
		tracker.storage.current_information.tags = tags
		tracker.storage.current_information.project_id = project_id
		tracker.storage.current_information.task_id = task_id
	end

	autotrack.save_project_state(autotrack.detect_project(), {
		task_id = task_id,
		description = description,
		billable = billable,
		tags = tags,
	})

	if entry.id then
		api.updateTimeEntry(org_id, entry.id, {
			member_id = entry.member_id,
			project_id = project_id,
			task_id = task_id,
			start = entry.start,
			billable = billable,
			description = description,
			tags = tags,
		}, function(err, _)
			if err then
				vim.notify("Failed to update entry: " .. err, vim.log.levels.ERROR)
				return
			end
			vim.notify("Time entry updated.", vim.log.levels.INFO)
		end)
	else
		vim.notify("Time entry updated.", vim.log.levels.INFO)
	end

	tracker.selectActiveTags(tags)
end

--- Edit active entry — form pre-filled from active entry; confirm pushes update.
function M.editActiveEntry()
	local entry = tracker.storage.active_entry
	if not entry then
		vim.notify("No active time entry to edit.", vim.log.levels.WARN)
		return
	end

	local org_id = entry.organization_id
		or (tracker.storage.current_information and tracker.storage.current_information.organization_id)

	if not org_id then
		vim.notify("Cannot determine organization for active entry.", vim.log.levels.ERROR)
		return
	end

	local project_map = {}
	local task_map = {}
	local tag_map = {}
	local fetched_projects = 0
	local fetched_tags = 0
	local fetched_tasks = 0
	local need_tasks = entry.project_id and entry.task_id and 1 or 0

	local function open_edit_form()
		local fields = {}
		make_time_entry_fields(org_id, {
			description = entry.description,
			billable = entry.billable,
			project_id = entry.project_id,
			task_id = entry.task_id,
			tags = entry.tags,
		}, fields, project_map, task_map, tag_map)
		fields[6] = { key = "__sep__", label = "" }
		fields[7] = { key = "__action__", label = "✎  Save" }

		open_form(fields, "Edit Time Entry", function(f)
			local vals = fields_to_vals(f)

			finalize_edit(entry, org_id, vals.description, vals.billable, vals.tags, vals.project, vals.task)
		end)
	end

	local function maybe_open()
		if fetched_projects == 1 and fetched_tags == 1 and fetched_tasks == need_tasks then
			open_edit_form()
		end
	end

	api.getOrganizationProjects(org_id, function(err, data)
		if not err and data and data.data then
			for _, p in ipairs(data.data) do
				project_map[p.id] = p.name
			end
		end
		fetched_projects = 1
		maybe_open()
	end)

	if need_tasks == 1 then
		api.getOrganizationTasks(org_id, { project_id = entry.project_id }, function(err, data)
			if not err and data and data.data then
				for _, t in ipairs(data.data) do
					task_map[t.id] = t.name
				end
			end
			fetched_tasks = 1
			maybe_open()
		end)
	end

	api.getOrganizationTags(org_id, function(err, data)
		if not err and data and data.data then
			for _, t in ipairs(data.data) do
				tag_map[t.id] = t.name
			end
		end
		fetched_tags = 1
		maybe_open()
	end)
end

--- Build and open the project list floating window.
--- j/k to navigate, <CR> to edit, a to add, d to delete, q/<Esc> to close.
function M.projectsScreen()
	local autotrack = require("solidtime.autotrack")

	-- ── helpers ──────────────────────────────────────────────────────────────

	local LIST_WIDTH = 72
	local LIST_HEIGHT = 20

	local COL_LOCAL = 18
	local COL_PROJ = 22
	local COL_AUTO = 8

	local function make_header()
		return "  "
			.. pad("Local name", COL_LOCAL)
			.. "│ "
			.. pad("Solidtime project", COL_PROJ)
			.. "│ "
			.. pad("Auto", COL_AUTO)
			.. "│ Description"
	end

	local function make_separator()
		return string.rep("─", LIST_WIDTH)
	end

	local row = math.floor((vim.o.lines - LIST_HEIGHT) / 2)
	local col = math.floor((vim.o.columns - LIST_WIDTH - 2) / 2)

	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = LIST_WIDTH,
		height = LIST_HEIGHT,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Projects ",
		title_pos = "center",
	})

	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("cursorline", true, { win = win })

	local org_id = tracker.storage.current_information and tracker.storage.current_information.organization_id

	local all_org_projects = nil

	local rows = {}

	local function redraw()
		local proj_id_to_name = {}
		if all_org_projects then
			for _, p in ipairs(all_org_projects) do
				proj_id_to_name[p.id] = p.name
			end
		end

		local projects = autotrack.read_config()
		rows = {}
		local names = vim.tbl_keys(projects)
		table.sort(names)
		for _, name in ipairs(names) do
			local cfg = projects[name]
			local proj_name = proj_id_to_name[cfg.solidtime_project_id] or cfg.solidtime_project_id or "(none)"
			local auto_str = cfg.auto_start and "yes" or "no"
			local desc_str = cfg.default_description or ""
			local line = "  "
				.. pad(name, COL_LOCAL)
				.. "│ "
				.. pad(proj_name, COL_PROJ)
				.. "│ "
				.. pad(auto_str, COL_AUTO)
				.. "│ "
				.. desc_str
			table.insert(rows, { line = line, key = name })
		end

		local lines = { make_header(), make_separator() }
		if all_org_projects == nil then
			table.insert(lines, "  Loading…")
		elseif #rows == 0 then
			table.insert(lines, "  (no projects registered — press 'a' to add one)")
		else
			for _, r in ipairs(rows) do
				table.insert(lines, r.line)
			end
		end
		table.insert(lines, make_separator())
		table.insert(lines, "  a add  d delete  <CR> edit  t tasks  q close")

		if vim.api.nvim_buf_is_valid(buf) then
			list_set_lines(buf, lines)
		end
	end

	redraw()

	local function set_cursor_row(idx)
		list_set_cursor(win, idx)
	end
	local function current_row_idx()
		return list_current_idx(win, rows)
	end
	local function close()
		list_close(win)
	end

	if org_id then
		api.getOrganizationProjects(org_id, function(err, data)
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(buf) then
					return
				end
				if err or not data or not data.data then
					all_org_projects = {}
					vim.notify("Could not load projects: " .. tostring(err or "unknown"), vim.log.levels.WARN)
				else
					all_org_projects = data.data
				end
				redraw()
				if #rows > 0 then
					set_cursor_row(1)
				end
			end)
		end)
	else
		all_org_projects = {}
		redraw()
	end

	---@param local_name string|nil  nil = new entry
	local function open_project_form(local_name)
		local projects = autotrack.read_config()
		local existing = (local_name and projects[local_name]) or {}
		local is_new = local_name == nil

		if not org_id then
			vim.notify("No organization selected. Run :SolidTime open first.", vim.log.levels.WARN)
			return
		end

		local all_projects = all_org_projects or {}

		-- Fetch clients async, then build and open the form
		api.getOrganizationClients(org_id, function(cerr, cdata)
			local all_clients = (not cerr and cdata and cdata.data) or {}

			local function get_project_client_id(pid)
				if not pid then
					return nil
				end
				for _, p in ipairs(all_projects) do
					if p.id == pid then
						local cid = p.client_id
						if cid == vim.NIL then
							return nil
						end
						return cid
					end
				end
				return nil
			end

			local local_name_field
			if is_new then
				local detected = autotrack.detect_project() or ""
				local_name_field = {
					key = "local_name",
					label = "Local name",
					value = detected,
					display = function(v)
						return v ~= "" and v or "(type to set)"
					end,
					edit = function(v, done)
						vim.ui.input({ prompt = "Local project name: ", default = v or "" }, function(val)
							if val == nil then
								return
							end
							done(val:match("^%s*(.-)%s*$"))
						end)
					end,
				}
			else
				local_name_field = {
					key = "local_name",
					label = "Local name",
					value = local_name,
					display = function(v)
						return v
					end,
				}
			end

			local function solidtime_project_display(pid)
				if not pid then
					return "(none)"
				end
				for _, p in ipairs(all_projects) do
					if p.id == pid then
						return p.name
					end
				end
				return pid
			end

			local function solidtime_project_edit(pid, done)
				local items = {}
				for _, p in ipairs(all_projects) do
					table.insert(items, p)
				end
				table.insert(items, { id = "__new__", name = "+ Create new project…" })
				vim.ui.select(items, {
					prompt = "Solidtime project:",
					format_item = function(p)
						return p.name
					end,
				}, function(choice)
					if not choice then
						done(pid)
						return
					end
					if choice.id == "__new__" then
						vim.ui.input({ prompt = "Project name: " }, function(name)
							if not name or name:match("^%s*$") then
								done(pid)
								return
							end
							name = name:match("^%s*(.-)%s*$")
							vim.ui.select(PROJECT_COLORS, {
								prompt = "Color:",
								format_item = function(c)
									return c.label
								end,
							}, function(color)
								if not color then
									done(pid)
									return
								end
								pick_client(org_id, nil, all_clients, function(new_client_id)
									api.createProject(org_id, {
										name = name,
										color = color.value,
										billable_by_default = false,
										is_billable = false,
										client_id = new_client_id or vim.NIL,
									}, function(perr, pdata)
										if perr or not pdata or not pdata.data then
											vim.notify(
												"Failed to create project: " .. (perr or "?"),
												vim.log.levels.ERROR
											)
											done(pid)
										else
											cache.invalidate_cache("organizations/" .. org_id .. "/projects")
											table.insert(all_projects, pdata.data)
											vim.notify("Project created: " .. name, vim.log.levels.INFO)
											done(pdata.data.id)
										end
									end)
								end)
							end)
						end)
					else
						done(choice.id)
					end
				end)
			end

			local function client_display(cid)
				if not cid or cid == vim.NIL then
					return "(none)"
				end
				for _, c in ipairs(all_clients) do
					if c.id == cid then
						return c.name
					end
				end
				return "(unknown client)"
			end

			local function client_edit(cid, done)
				pick_client(org_id, cid, all_clients, done)
			end

			local fields = {
				local_name_field,
				{
					key = "solidtime_project_id",
					label = "ST project",
					value = existing.solidtime_project_id,
					display = solidtime_project_display,
					edit = solidtime_project_edit,
				},
				{
					key = "client_id",
					label = "Client",
					value = get_project_client_id(existing.solidtime_project_id),
					display = client_display,
					edit = client_edit,
				},
				{
					key = "auto_start",
					label = "Auto-start",
					value = existing.auto_start or false,
					display = function(v)
						return v and "Yes" or "No"
					end,
					edit = function(_, done)
						vim.ui.select({ "No", "Yes" }, { prompt = "Auto-start?" }, function(c)
							if c == nil then
								return
							end
							done(c == "Yes")
						end)
					end,
				},
				{
					key = "default_description",
					label = "Description",
					value = existing.default_description or "",
					display = function(v)
						return (v and v ~= "") and v or "(none)"
					end,
					edit = function(v, done)
						vim.ui.input({ prompt = "Default description: ", default = v or "" }, function(val)
							if val == nil then
								return
							end
							done(val:match("^%s*(.-)%s*$"))
						end)
					end,
				},
				{
					key = "default_billable",
					label = "Billable",
					value = existing.default_billable or false,
					display = function(v)
						return v and "Yes" or "No"
					end,
					edit = function(_, done)
						vim.ui.select({ "No", "Yes" }, { prompt = "Default billable?" }, function(c)
							if c == nil then
								return
							end
							done(c == "Yes")
						end)
					end,
				},
				{ key = "__sep__", label = "" },
				{ key = "__action__", label = "Save" },
			}

			local form_title = is_new and "Add Project" or ("Edit: " .. local_name)

			open_form(fields, form_title, function(f)
				local vals = fields_to_vals(f)

				local key = vals.local_name
				if not key or key == "" then
					vim.notify("Local project name cannot be empty.", vim.log.levels.ERROR)
					return
				end

				local function finish_save()
					local updated = autotrack.read_config()
					updated[key] = {
						solidtime_project_id = vals.solidtime_project_id,
						auto_start = vals.auto_start or false,
						default_description = (vals.default_description ~= "") and vals.default_description or nil,
						default_billable = vals.default_billable or false,
						default_tags = existing.default_tags or {},
						organization_id = existing.organization_id
							or (tracker.storage.current_information and tracker.storage.current_information.organization_id),
						member_id = existing.member_id
							or (tracker.storage.current_information and tracker.storage.current_information.member_id),
					}
					autotrack.write_config(updated)
					vim.notify("Saved project '" .. key .. "'.", vim.log.levels.INFO)

					vim.schedule(function()
						if vim.api.nvim_win_is_valid(win) then
							vim.api.nvim_set_current_win(win)
							redraw()
						end
					end)
				end

				if vals.solidtime_project_id then
					local proj_obj = nil
					for _, p in ipairs(all_projects) do
						if p.id == vals.solidtime_project_id then
							proj_obj = p
							break
						end
					end
					if proj_obj then
						api.updateProject(org_id, vals.solidtime_project_id, {
							name = proj_obj.name,
							color = proj_obj.color,
							billable_by_default = proj_obj.billable_by_default or false,
							is_billable = proj_obj.is_billable or false,
							client_id = vals.client_id or vim.NIL,
						}, function(uerr, _)
							if uerr then
								vim.notify("Failed to update project client: " .. uerr, vim.log.levels.ERROR)
							else
								proj_obj.client_id = vals.client_id
								cache.invalidate_cache("organizations/" .. org_id .. "/projects")
							end
							finish_save()
						end)
					else
						finish_save()
					end
				else
					finish_save()
				end
			end)
		end)
	end

	bmap(buf, km().close, close, "Close")
	bmap(buf, km().close_alt, close, "Close")

	bmap(buf, km().nav_down, function()
		if not vim.api.nvim_win_is_valid(win) then
			return
		end
		local idx = current_row_idx()
		if idx and idx < #rows then
			set_cursor_row(idx + 1)
		end
	end, "Next project")

	bmap(buf, km().nav_up, function()
		if not vim.api.nvim_win_is_valid(win) then
			return
		end
		local idx = current_row_idx()
		if idx and idx > 1 then
			set_cursor_row(idx - 1)
		end
	end, "Previous project")

	bmap(buf, km().confirm, function()
		local idx = current_row_idx()
		if not idx then
			return
		end
		local row_data = rows[idx]
		if row_data then
			open_project_form(row_data.key)
		end
	end, "Edit project mapping")

	bmap(buf, km().add, function()
		open_project_form(nil)
	end, "Add project mapping")

	bmap(buf, km().tasks, function()
		local idx = current_row_idx()
		if not idx then
			return
		end
		local row_data = rows[idx]
		if not row_data then
			return
		end
		local projects = autotrack.read_config()
		local cfg = projects[row_data.key]
		local st_id = cfg and cfg.solidtime_project_id
		if not st_id then
			vim.notify("No Solidtime project linked to '" .. row_data.key .. "'.", vim.log.levels.WARN)
			return
		end
		local proj_name = row_data.key
		if all_org_projects then
			for _, p in ipairs(all_org_projects) do
				if p.id == st_id then
					proj_name = p.name
					break
				end
			end
		end
		M.tasksScreen(st_id, proj_name)
	end, "Open tasks for project")

	bmap(buf, km().delete, function()
		local idx = current_row_idx()
		if not idx then
			return
		end
		local row_data = rows[idx]
		if not row_data then
			return
		end

		vim.ui.select({ "No", "Yes" }, {
			prompt = "Delete '" .. row_data.key .. "'?",
		}, function(choice)
			if choice ~= "Yes" then
				return
			end
			local projects = autotrack.read_config()
			projects[row_data.key] = nil
			autotrack.write_config(projects)
			vim.notify("Removed '" .. row_data.key .. "'.", vim.log.levels.INFO)
			vim.schedule(function()
				if vim.api.nvim_win_is_valid(win) then
					redraw()
					local new_idx = math.min(idx, #rows)
					if new_idx > 0 then
						set_cursor_row(new_idx)
					end
				end
			end)
		end)
	end, "Delete project mapping")
end

function M.statusScreen()
	local auth = require("solidtime.auth")
	local config = require("solidtime.config")

	local function auth_display(_)
		local cfg = config.get()
		local url = cfg.api_url or "(no URL)"
		local key = cfg.api_key
		local masked = key and (string.rep("*", math.min(math.max(0, #key - 4), 12)) .. key:sub(-4)) or "(no key)"
		return url .. "  " .. masked
	end

	-- Pre-fetch memberships and projects to avoid sync API calls in display closures
	local memberships_data = nil   -- populated async before form opens
	local projects_data = nil      -- populated async before form opens
	local fetched_memberships = 0
	local fetched_projects = 0

	local function org_display(_)
		local ci = tracker.storage.current_information
		if not ci or not ci.organization_id then
			return "(none)"
		end
		if memberships_data then
			for _, m in ipairs(memberships_data) do
				if m.organization and m.organization.id == ci.organization_id then
					return m.organization.name
				end
			end
		end
		return ci.organization_id
	end

	local function project_display(_)
		local ci = tracker.storage.current_information
		if not ci or not ci.project_id then
			return "(none)"
		end
		if projects_data then
			for _, p in ipairs(projects_data) do
				if p.id == ci.project_id then
					return p.name
				end
			end
		end
		return ci.project_id
	end

	local function open_status_form()
		local fields = {
			{
				key = "auth",
				label = "Auth",
				value = true,
				display = auth_display,
				edit = function(_, on_done)
					auth.prompt_api_key()
					vim.schedule(function()
						on_done(true)
					end)
				end,
			},
			{
				key = "org",
				label = "Organization",
				value = (tracker.storage.current_information or {}).organization_id,
				display = org_display,
				edit = function(_, on_done)
					M.selectActiveOrganization(function()
						-- Re-fetch memberships after org change so display updates
						api.getUserMemberships(function(err, data)
							if not err and data and data.data then
								memberships_data = data.data
							end
							local ci = tracker.storage.current_information
							on_done(ci and ci.organization_id)
						end)
					end)
				end,
			},
			{
				key = "project",
				label = "Project",
				value = (tracker.storage.current_information or {}).project_id,
				display = project_display,
				edit = function(_, on_done)
					M.selectActiveProject()
					-- Re-fetch projects after project change so display updates
					local ci = tracker.storage.current_information
					local oid = ci and ci.organization_id
					if oid then
						api.getOrganizationProjects(oid, function(err, data)
							if not err and data and data.data then
								projects_data = data.data
							end
							local ci2 = tracker.storage.current_information
							on_done(ci2 and ci2.project_id)
						end)
					else
						vim.schedule(function()
							local ci2 = tracker.storage.current_information
							on_done(ci2 and ci2.project_id)
						end)
					end
				end,
			},
			{ key = "__sep__", label = "" },
			{ key = "__action__", label = "Close" },
		}

		open_form(fields, "SolidTime Status", function(_)
			-- action = Close; nothing extra to do
		end)
	end

	local function maybe_open()
		if fetched_memberships == 1 and fetched_projects == 1 then
			open_status_form()
		end
	end

	local ci = tracker.storage.current_information

	api.getUserMemberships(function(err, data)
		if not err and data and data.data then
			memberships_data = data.data
		end
		fetched_memberships = 1
		maybe_open()
	end)

	local org_id = ci and ci.organization_id
	if org_id then
		api.getOrganizationProjects(org_id, function(err, data)
			if not err and data and data.data then
				projects_data = data.data
			end
			fetched_projects = 1
			maybe_open()
		end)
	else
		fetched_projects = 1
		maybe_open()
	end
end

function M.clientsScreen()
	local org_id = tracker.storage.current_information and tracker.storage.current_information.organization_id
	if not org_id then
		vim.notify("No organization selected. Run :SolidTime open first.", vim.log.levels.WARN)
		return
	end

	local LIST_WIDTH = 60
	local LIST_HEIGHT = 20

	local row = math.floor((vim.o.lines - LIST_HEIGHT) / 2)
	local col = math.floor((vim.o.columns - LIST_WIDTH - 2) / 2)

	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = LIST_WIDTH,
		height = LIST_HEIGHT,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Clients ",
		title_pos = "center",
	})

	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("cursorline", true, { win = win })

	local clients = nil -- nil = loading

	local rows = {}

	local function redraw()
		rows = {}
		local lines = { "  Name", string.rep("─", LIST_WIDTH) }
		if clients == nil then
			table.insert(lines, "  Loading…")
		elseif #clients == 0 then
			table.insert(lines, "  (no clients — press 'a' to create one)")
		else
			for _, c in ipairs(clients) do
				table.insert(rows, c)
				table.insert(lines, "  " .. (c.name or c.id))
			end
		end
		table.insert(lines, string.rep("─", LIST_WIDTH))
		table.insert(lines, "  a add  d delete  <CR> rename  q close")
		if vim.api.nvim_buf_is_valid(buf) then
			list_set_lines(buf, lines)
		end
	end

	local function close()
		list_close(win)
	end
	local function set_cursor_row(idx)
		list_set_cursor(win, idx)
	end
	local function current_idx()
		return list_current_idx(win, rows)
	end

	redraw()
	api.getOrganizationClients(org_id, function(err, data)
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			if err or not data or not data.data then
				clients = {}
				vim.notify("Could not load clients: " .. tostring(err or "unknown"), vim.log.levels.WARN)
			else
				clients = data.data
			end
			redraw()
			if #rows > 0 then
				set_cursor_row(1)
			end
		end)
	end)

	bmap(buf, km().close, close, "Close")
	bmap(buf, km().close_alt, close, "Close")

	bmap(buf, km().nav_down, function()
		local idx = current_idx()
		if idx and idx < #rows then
			set_cursor_row(idx + 1)
		end
	end, "Next client")

	bmap(buf, km().nav_up, function()
		local idx = current_idx()
		if idx and idx > 1 then
			set_cursor_row(idx - 1)
		end
	end, "Previous client")

	bmap(buf, km().add, function()
		vim.ui.input({ prompt = "Client name: " }, function(name)
			if not name or name:match("^%s*$") then
				return
			end
			name = name:match("^%s*(.-)%s*$")
			api.createClient(org_id, { name = name }, function(err, data)
				if err then
					vim.notify("Failed to create client: " .. err, vim.log.levels.ERROR)
					return
				end
				cache.invalidate_cache("organizations/" .. org_id .. "/clients")
				if data and data.data then
					table.insert(clients, data.data)
				end
				vim.notify("Client created: " .. name, vim.log.levels.INFO)
				vim.schedule(function()
					if vim.api.nvim_win_is_valid(win) then
						redraw()
						set_cursor_row(#rows)
					end
				end)
			end)
		end)
	end, "Create client")

	bmap(buf, km().confirm, function()
		local idx = current_idx()
		if not idx then
			return
		end
		local client = rows[idx]
		vim.ui.input({ prompt = "Rename client: ", default = client.name or "" }, function(name)
			if not name or name:match("^%s*$") then
				return
			end
			name = name:match("^%s*(.-)%s*$")
			api.updateClient(org_id, client.id, { name = name }, function(err, _)
				if err then
					vim.notify("Failed to rename: " .. err, vim.log.levels.ERROR)
					return
				end
				cache.invalidate_cache("organizations/" .. org_id .. "/clients")
				client.name = name
				vim.schedule(function()
					if vim.api.nvim_win_is_valid(win) then
						redraw()
						set_cursor_row(idx)
					end
				end)
			end)
		end)
	end, "Rename client")

	bmap(buf, km().delete, function()
		local idx = current_idx()
		if not idx then
			return
		end
		local client = rows[idx]
		vim.ui.select({ "No", "Yes" }, {
			prompt = "Delete client '" .. (client.name or client.id) .. "'?",
		}, function(choice)
			if choice ~= "Yes" then
				return
			end
			api.deleteClient(org_id, client.id, function(err, _)
				if err then
					vim.notify("Failed to delete: " .. err, vim.log.levels.ERROR)
					return
				end
				cache.invalidate_cache("organizations/" .. org_id .. "/clients")
				for i, c in ipairs(clients) do
					if c.id == client.id then
						table.remove(clients, i)
						break
					end
				end
				vim.notify("Client deleted.", vim.log.levels.INFO)
				vim.schedule(function()
					if vim.api.nvim_win_is_valid(win) then
						redraw()
						local new_idx = math.min(idx, #rows)
						if new_idx > 0 then
							set_cursor_row(new_idx)
						end
					end
				end)
			end)
		end)
	end, "Delete client")
end

--- Open the tasks list for a specific project.
---@param project_id string   Solidtime project UUID
---@param project_name string|nil  Display name for the title bar
function M.tasksScreen(project_id, project_name)
	local ci = tracker.storage.current_information
	local org_id = ci and ci.organization_id

	if not org_id then
		vim.notify("No organization selected. Run :SolidTime open first.", vim.log.levels.WARN)
		return
	end

	local LIST_WIDTH = 64
	local LIST_HEIGHT = 22

	local row_win = math.floor((vim.o.lines - LIST_HEIGHT) / 2)
	local col_win = math.floor((vim.o.columns - LIST_WIDTH - 2) / 2)

	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = LIST_WIDTH,
		height = LIST_HEIGHT,
		row = row_win,
		col = col_win,
		style = "minimal",
		border = "rounded",
		title = " Tasks: " .. (project_name or project_id) .. " ",
		title_pos = "center",
	})

	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("cursorline", true, { win = win })

	local tasks = nil -- nil = loading
	local rows = {}

	local function redraw()
		rows = {}
		local lines = { "  Done  Name", string.rep("─", LIST_WIDTH) }
		if tasks == nil then
			table.insert(lines, "  Loading…")
		elseif #tasks == 0 then
			table.insert(lines, "  (no tasks — press 'a' to create one)")
		else
			for _, t in ipairs(tasks) do
				table.insert(rows, t)
				local check = t.is_done and "[x]" or "[ ]"
				table.insert(lines, string.format("  %s  %s", check, t.name or t.id))
			end
		end
		table.insert(lines, string.rep("─", LIST_WIDTH))
		table.insert(lines, "  a add  d delete  <CR> rename/toggle  q close")
		if vim.api.nvim_buf_is_valid(buf) then
			list_set_lines(buf, lines)
		end
	end

	local function close()
		list_close(win)
	end
	local function set_cursor_row(idx)
		list_set_cursor(win, idx)
	end
	local function current_idx()
		return list_current_idx(win, rows)
	end

	-- Initial async load
	redraw()
	api.getOrganizationTasks(org_id, { project_id = project_id }, function(err, data)
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			if err or not data or not data.data then
				tasks = {}
				vim.notify("Could not load tasks: " .. tostring(err or "unknown"), vim.log.levels.WARN)
			else
				tasks = data.data
			end
			redraw()
			if #rows > 0 then
				set_cursor_row(1)
			end
		end)
	end)

	bmap(buf, km().close, close, "Close")
	bmap(buf, km().close_alt, close, "Close")

	bmap(buf, km().nav_down, function()
		local idx = current_idx()
		if idx and idx < #rows then
			set_cursor_row(idx + 1)
		end
	end, "Next task")

	bmap(buf, km().nav_up, function()
		local idx = current_idx()
		if idx and idx > 1 then
			set_cursor_row(idx - 1)
		end
	end, "Previous task")

	bmap(buf, km().add, function()
		vim.ui.input({ prompt = "Task name: " }, function(name)
			if not name or name:match("^%s*$") then
				return
			end
			name = name:match("^%s*(.-)%s*$")
			api.createTask(org_id, {
				name = name,
				is_done = false,
				project_id = project_id,
			}, function(err, result)
				if err or (result and result.error) then
					vim.notify(
						"Failed to create task: " .. tostring(err or result.error),
						vim.log.levels.ERROR
					)
					return
				end
				if result and result.data then
					table.insert(tasks, result.data)
				end
				vim.notify("Task created: " .. name, vim.log.levels.INFO)
				if vim.api.nvim_win_is_valid(win) then
					redraw()
					set_cursor_row(#rows)
				end
			end)
		end)
	end, "Create task")

	bmap(buf, km().confirm, function()
		local idx = current_idx()
		if not idx then
			return
		end
		local task = rows[idx]

		local choices = {
			{ label = "Toggle done (" .. (task.is_done and "mark undone" or "mark done") .. ")" },
			{ label = "Rename" },
		}
		vim.ui.select(choices, {
			prompt = "Task: " .. (task.name or task.id),
			format_item = function(c)
				return c.label
			end,
		}, function(choice)
			if not choice then
				return
			end

			if choice.label:match("^Toggle") then
				api.updateTask(org_id, task.id, {
					name = task.name,
					is_done = not task.is_done,
				}, function(err, result)
					if err or (result and result.error) then
						vim.notify(
							"Failed to update task: " .. tostring(err or result.error),
							vim.log.levels.ERROR
						)
						return
					end
					task.is_done = not task.is_done
					if vim.api.nvim_win_is_valid(win) then
						redraw()
						set_cursor_row(idx)
					end
				end)
			else
				-- rename
				vim.ui.input({ prompt = "Rename task: ", default = task.name or "" }, function(name)
					if not name or name:match("^%s*$") then
						return
					end
					name = name:match("^%s*(.-)%s*$")
					api.updateTask(org_id, task.id, {
						name = name,
						is_done = task.is_done,
					}, function(err, result)
						if err or (result and result.error) then
							vim.notify(
								"Failed to rename task: " .. tostring(err or result.error),
								vim.log.levels.ERROR
							)
							return
						end
						task.name = name
						if vim.api.nvim_win_is_valid(win) then
							redraw()
							set_cursor_row(idx)
						end
					end)
				end)
			end
		end)
	end, "Edit task")

	bmap(buf, km().delete, function()
		local idx = current_idx()
		if not idx then
			return
		end
		local task = rows[idx]
		vim.ui.select({ "No", "Yes" }, {
			prompt = "Delete task '" .. (task.name or task.id) .. "'?",
		}, function(choice)
			if choice ~= "Yes" then
				return
			end
			api.deleteTask(org_id, task.id, function(err, result)
				if err or (result and result.error) then
					vim.notify(
						"Failed to delete task: " .. tostring(err or result.error),
						vim.log.levels.ERROR
					)
					return
				end
				for i, t in ipairs(tasks) do
					if t.id == task.id then
						table.remove(tasks, i)
						break
					end
				end
				vim.notify("Task deleted.", vim.log.levels.INFO)
				if vim.api.nvim_win_is_valid(win) then
					redraw()
					local new_idx = math.min(idx, #rows)
					if new_idx > 0 then
						set_cursor_row(new_idx)
					end
				end
			end)
		end)
	end, "Delete task")
end

function M.timeEntriesScreen()
	local ci = tracker.storage.current_information
	local org_id = ci and ci.organization_id
	local member_id = ci and ci.member_id

	if not org_id then
		vim.notify("No organization selected. Run :SolidTime open first.", vim.log.levels.WARN)
		return
	end

	local LIST_WIDTH = 90
	local LIST_HEIGHT = 24

	local COL_DATE = 12
	local COL_DUR = 8
	local COL_PROJ = 20
	local COL_BILL = 6

	local function make_header()
		return "  "
			.. pad("Date", COL_DATE)
			.. "│ "
			.. pad("Duration", COL_DUR)
			.. "│ "
			.. pad("Project", COL_PROJ)
			.. "│ "
			.. pad("Bill", COL_BILL)
			.. "│ Description"
	end

	local row_win = math.floor((vim.o.lines - LIST_HEIGHT) / 2)
	local col_win = math.floor((vim.o.columns - LIST_WIDTH - 2) / 2)

	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = LIST_WIDTH,
		height = LIST_HEIGHT,
		row = row_win,
		col = col_win,
		style = "minimal",
		border = "rounded",
		title = " Time Entries ",
		title_pos = "center",
	})

	vim.api.nvim_set_option_value("buftype", "acwrite", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("cursorline", true, { win = win })
	vim.api.nvim_buf_set_name(buf, "solidtime://time-entries")

	local current_page = 1
	local total_pages = 1
	local entries = nil
	local rows = {}
	local proj_map = {}
	local pending_deletes = {}

	if org_id then
		api.getOrganizationProjects(org_id, function(err, data)
			if not err and data and data.data then
				for _, p in ipairs(data.data) do
					proj_map[p.id] = p.name
				end
			end
		end)
	end

	local function fmt_duration(start_str, end_str)
		if not start_str or not end_str then
			return "—"
		end
		if type(start_str) ~= "string" or type(end_str) ~= "string" then
			return "—"
		end
		local function parse_iso(s)
			if type(s) ~= "string" then
				return nil
			end
			local y, mo, d, h, mi, sec = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
			if not y then
				return nil
			end
			return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec })
		end
		local t1 = parse_iso(start_str)
		local t2 = parse_iso(end_str)
		if not t1 or not t2 then
			return "?"
		end
		local secs = math.max(0, t2 - t1)
		local h = math.floor(secs / 3600)
		local m = math.floor((secs % 3600) / 60)
		if h > 0 then
			return string.format("%dh %02dm", h, m)
		end
		return string.format("%dm", m)
	end

	local function fmt_date(s)
		if not s then
			return ""
		end
		return s:sub(1, 10)
	end

	local function redraw()
		rows = {}
		local lines = { make_header(), string.rep("─", LIST_WIDTH) }

		if entries == nil then
			table.insert(lines, "  Loading…")
		elseif #entries == 0 then
			table.insert(lines, "  (no time entries found)")
		else
			for _, e in ipairs(entries) do
				table.insert(rows, e)
				local proj = proj_map[e.project_id] or "(none)"
				local dur = fmt_duration(e.start, e["end"])
				local date = fmt_date(e.start)
				local bill = e.billable and "yes" or "no"
				local desc = e.description or ""
				local staged = pending_deletes[e.id]
				local prefix = staged and "~ " or "  "
				local line = prefix
					.. pad(date, COL_DATE)
					.. "│ "
					.. pad(dur, COL_DUR)
					.. "│ "
					.. pad(proj, COL_PROJ)
					.. "│ "
					.. pad(bill, COL_BILL)
					.. "│ "
					.. desc
				table.insert(lines, line)
			end
		end

		table.insert(lines, string.rep("─", LIST_WIDTH))
		local page_info = string.format("page %d/%d", current_page, total_pages)
		local staged_count = (function()
			local n = 0
			for _ in pairs(pending_deletes) do
				n = n + 1
			end
			return n
		end)()
		local hint = staged_count > 0
				and string.format(
					"  [ prev  ] next  <CR> edit  d delete  %s  :w commit (%d staged)  q close",
					page_info,
					staged_count
				)
			or string.format("  [ prev  ] next  <CR> edit  d delete  %s  q close", page_info)
		table.insert(lines, hint)

		if vim.api.nvim_buf_is_valid(buf) then
			list_set_lines(buf, lines)
		end
	end

	local function close()
		list_close(win)
	end
	local function set_cursor_row(idx)
		list_set_cursor(win, idx)
	end
	local function current_idx()
		return list_current_idx(win, rows)
	end

	local function load_page(page)
		entries = nil
		redraw()
		local params = { page = page }
		if member_id then
			params.member_ids = { member_id }
		end
		api.getOrganizationTimeEntries(org_id, params, function(err, data)
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(buf) then
					return
				end
				if err or not data or not data.data then
					entries = {}
					vim.notify("Could not load entries: " .. tostring(err or "unknown"), vim.log.levels.WARN)
				else
					entries = data.data
					if data.meta and data.meta.last_page then
						total_pages = data.meta.last_page
					end
				end
				redraw()
				if #rows > 0 then
					set_cursor_row(1)
				end
			end)
		end)
	end

	load_page(1)

	bmap(buf, km().close, close, "Close")
	bmap(buf, km().close_alt, close, "Close")

	bmap(buf, km().nav_down, function()
		local idx = current_idx()
		if idx and idx < #rows then
			set_cursor_row(idx + 1)
		end
	end, "Next entry")

	bmap(buf, km().nav_up, function()
		local idx = current_idx()
		if idx and idx > 1 then
			set_cursor_row(idx - 1)
		end
	end, "Previous entry")

	bmap(buf, km().next_page, function()
		if current_page < total_pages then
			current_page = current_page + 1
			load_page(current_page)
		end
	end, "Next page")

	bmap(buf, km().prev_page, function()
		if current_page > 1 then
			current_page = current_page - 1
			load_page(current_page)
		end
	end, "Previous page")

	bmap(buf, km().confirm, function()
		local idx = current_idx()
		if not idx then
			return
		end
		local entry = rows[idx]

		local entry_project_map = {}
		local entry_task_map = {}
		local entry_tag_map = {}
		local fetched_projects = 0
		local fetched_tags = 0
		local fetched_tasks = 0
		local need_tasks = entry.project_id and entry.task_id and 1 or 0

		-- Copy already-known project names from the list's proj_map
		for k, v in pairs(proj_map) do
			entry_project_map[k] = v
		end

		local function open_entry_edit_form()
			local fields = {}
			make_time_entry_fields(org_id, {
				description = entry.description,
				billable = entry.billable,
				project_id = entry.project_id,
				task_id = entry.task_id,
				tags = entry.tags,
			}, fields, entry_project_map, entry_task_map, entry_tag_map)
			fields[6] = { key = "__sep__", label = "" }
			fields[7] = { key = "__action__", label = "Save" }

			open_form(fields, "Edit Entry", function(f)
				local vals = fields_to_vals(f)
				api.updateTimeEntry(org_id, entry.id, {
					member_id = entry.member_id,
					project_id = vals.project,
					task_id = vals.task,
					start = entry.start,
					["end"] = entry["end"],
					billable = vals.billable,
					description = vals.description,
					tags = vals.tags,
				}, function(err, _)
					if err then
						vim.notify("Failed to update: " .. err, vim.log.levels.ERROR)
						return
					end
					entry.description = vals.description
					entry.billable = vals.billable
					entry.project_id = vals.project
					entry.task_id = vals.task
					entry.tags = vals.tags
					vim.notify("Entry updated.", vim.log.levels.INFO)
					vim.schedule(function()
						if vim.api.nvim_win_is_valid(win) then
							redraw()
							set_cursor_row(idx)
						end
					end)
				end)
			end)
		end

		local function maybe_open_entry()
			if fetched_projects == 1 and fetched_tags == 1 and fetched_tasks == need_tasks then
				open_entry_edit_form()
			end
		end

		-- If proj_map is already populated, skip the project fetch
		if next(entry_project_map) ~= nil then
			fetched_projects = 1
		else
			api.getOrganizationProjects(org_id, function(err, data)
				if not err and data and data.data then
					for _, p in ipairs(data.data) do
						entry_project_map[p.id] = p.name
						proj_map[p.id] = p.name
					end
				end
				fetched_projects = 1
				maybe_open_entry()
			end)
		end

		if need_tasks == 1 then
			api.getOrganizationTasks(org_id, { project_id = entry.project_id }, function(err, data)
				if not err and data and data.data then
					for _, t in ipairs(data.data) do
						entry_task_map[t.id] = t.name
					end
				end
				fetched_tasks = 1
				maybe_open_entry()
			end)
		end

		api.getOrganizationTags(org_id, function(err, data)
			if not err and data and data.data then
				for _, t in ipairs(data.data) do
					entry_tag_map[t.id] = t.name
				end
			end
			fetched_tags = 1
			maybe_open_entry()
		end)

		if fetched_projects == 1 then
			maybe_open_entry()
		end
	end, "Edit entry")

	bmap(buf, km().delete, function()
		local idx = current_idx()
		if not idx then
			return
		end
		local entry = rows[idx]
		local label = (entry.description and entry.description ~= "") and entry.description or fmt_date(entry.start)

		vim.ui.select({ "No", "Yes" }, {
			prompt = "Delete entry '" .. label .. "'?",
		}, function(choice)
			if choice ~= "Yes" then
				return
			end
			api.deleteTimeEntry(org_id, entry.id, function(err, _)
				if err then
					vim.notify("Failed to delete: " .. err, vim.log.levels.ERROR)
					return
				end
				pending_deletes[entry.id] = nil
				for i, e in ipairs(entries) do
					if e.id == entry.id then
						table.remove(entries, i)
						break
					end
				end
				vim.notify("Entry deleted.", vim.log.levels.INFO)
				vim.schedule(function()
					if vim.api.nvim_win_is_valid(win) then
						redraw()
						local new_idx = math.min(idx, #rows)
						if new_idx > 0 then
							set_cursor_row(new_idx)
						end
					end
				end)
			end)
		end)
	end, "Delete entry")

	if km().delete and km().delete ~= false and km().delete ~= "" then
		vim.keymap.set("v", km().delete, function()
			local vstart = vim.fn.line("v")
			local vend = vim.fn.line(".")
			if vstart > vend then
				vstart, vend = vend, vstart
			end
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
			for lnum = vstart, vend do
				local idx = lnum - LIST_HEADER_LINES
				if idx >= 1 and idx <= #rows then
					local entry = rows[idx]
					pending_deletes[entry.id] = true
				end
			end
			redraw()
		end, { buffer = buf, nowait = true, desc = "Stage entries for deletion" })
	end

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			local ids = {}
			for id in pairs(pending_deletes) do
				table.insert(ids, id)
			end
			if #ids == 0 then
				vim.notify("Nothing staged for deletion.", vim.log.levels.INFO)
				return
			end
			local total = #ids
			local done_count = 0
			local failed_count = 0
			for _, id in ipairs(ids) do
				api.deleteTimeEntry(org_id, id, function(err, _)
					done_count = done_count + 1
					if err then
						failed_count = failed_count + 1
						vim.notify("Failed to delete entry: " .. err, vim.log.levels.ERROR)
					else
						pending_deletes[id] = nil
						for i, e in ipairs(entries) do
							if e.id == id then
								table.remove(entries, i)
								break
							end
						end
					end
					if done_count == total then
						local deleted = total - failed_count
						if deleted > 0 then
							vim.notify(
								string.format("Deleted %d entr%s.", deleted, deleted == 1 and "y" or "ies"),
								vim.log.levels.INFO
							)
						end
						vim.bo[buf].modified = false
						vim.schedule(function()
							if vim.api.nvim_win_is_valid(win) then
								redraw()
								if #rows > 0 then
									set_cursor_row(math.min(current_idx() or 1, #rows))
								end
							end
						end)
					end
				end)
			end
		end,
	})
end

return M
