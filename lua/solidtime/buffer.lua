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

local TABS = {
	{ id = "timer", label = "Timer" },
	{ id = "status", label = "Status" },
	{ id = "projects", label = "Projects" },
	{ id = "clients", label = "Clients" },
	{ id = "tasks", label = "Tasks" },
	{ id = "entries", label = "Entries" },
}

local shell_back_or_close_fn = nil

local shell = {
	win = nil,
	buf = nil,
	active_tab = 1,
	stack = {},
	direct_open = false,
}

local TAB_BAR_LINES = 2
local LIST_HEADER_LINES = TAB_BAR_LINES + 2

local function shell_is_open()
	return shell.win ~= nil
		and vim.api.nvim_win_is_valid(shell.win)
		and shell.buf ~= nil
		and vim.api.nvim_buf_is_valid(shell.buf)
end

local function shell_close()
	if shell.win and vim.api.nvim_win_is_valid(shell.win) then
		vim.api.nvim_win_close(shell.win, true)
	end
	shell.win = nil
	shell.buf = nil
	shell.stack = {}
	shell.direct_open = false
	shell_back_or_close_fn = nil
end

local DEFAULT_W = 90
local DEFAULT_H = 26

local function shell_dims()
	local tab_id = TABS[shell.active_tab] and TABS[shell.active_tab].id or "timer"
	local sizes = {
		-- timer = { w = 60, h = 18 },
		-- status = { w = 60, h = 14 },
		-- projects = { w = 74, h = 22 },
		-- clients = { w = 62, h = 22 },
		-- tasks = { w = 66, h = 24 },
		-- entries = { w = 92, h = 26 },
	}
	local s = sizes[tab_id] or { w = DEFAULT_W, h = DEFAULT_H }
	local w = math.min(s.w, vim.o.columns - 4)
	local h = math.min(s.h, vim.o.lines - 4)
	return w, h
end

local function tab_bar_lines(inner_width)
	local parts = {}
	for i, tab in ipairs(TABS) do
		if i == shell.active_tab then
			table.insert(parts, " [" .. tab.label .. "] ")
		else
			table.insert(parts, "  " .. tab.label .. "  ")
		end
	end
	local bar = table.concat(parts, "")
	if #bar < inner_width then
		bar = bar .. string.rep(" ", inner_width - #bar)
	elseif #bar > inner_width then
		bar = bar:sub(1, inner_width)
	end
	return { bar, string.rep("─", inner_width) }
end

local function buf_set_lines(buf, lines)
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

local function shell_redraw()
	if not shell_is_open() then
		return
	end
	local saved_cursor = vim.api.nvim_win_get_cursor(shell.win)
	local w = vim.api.nvim_win_get_width(shell.win) - 2
	local lines = tab_bar_lines(w)
	local top = shell.stack[#shell.stack]
	if top and top.render then
		local content = top.render(w)
		for _, l in ipairs(content) do
			table.insert(lines, l)
		end
	end
	buf_set_lines(shell.buf, lines)
	local line_count = vim.api.nvim_buf_line_count(shell.buf)
	local restore_line = math.min(saved_cursor[1], line_count)
	if restore_line >= 1 then
		vim.api.nvim_win_set_cursor(shell.win, { restore_line, saved_cursor[2] })
	end
	if top and top.install_keymaps then
		top.install_keymaps()
	end
	if shell_back_or_close_fn and not (top and top.owns_cancel) then
		bmap(shell.buf, km().close, shell_back_or_close_fn, "Back / Close")
		bmap(shell.buf, km().close_alt, shell_back_or_close_fn, "Back / Close")
	end
end

local function shell_open(tab_idx)
	tab_idx = tab_idx or shell.active_tab

	if shell_is_open() then
		shell.active_tab = tab_idx
		shell.stack = {}
		return
	end

	shell.active_tab = tab_idx
	shell.stack = {}

	local w, h = shell_dims()
	local row = math.floor((vim.o.lines - h) / 2)
	local col = math.floor((vim.o.columns - w) / 2)

	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = w,
		height = h,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " SolidTime ",
		title_pos = "center",
	})

	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("cursorline", true, { win = win })

	shell.win = win
	shell.buf = buf

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			shell.win = nil
			shell.buf = nil
			shell.stack = {}
			shell.direct_open = false
		end,
	})
	vim.keymap.set("n", "gg", function() end, { buffer = buf, nowait = true })
	vim.keymap.set("n", "G", function() end, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<C-d>", function() end, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<C-u>", function() end, { buffer = buf, nowait = true })

	vim.keymap.set("n", "<Tab>", function()
		local next_tab = (shell.active_tab % #TABS) + 1
		M.switch_tab(next_tab)
	end, { buffer = buf, nowait = true, desc = "Next tab" })
	vim.keymap.set("n", "<S-Tab>", function()
		local prev_tab = ((shell.active_tab - 2) % #TABS) + 1
		M.switch_tab(prev_tab)
	end, { buffer = buf, nowait = true, desc = "Previous tab" })

	for i = 1, #TABS do
		local idx = i
		vim.keymap.set("n", "<leader>" .. i, function()
			M.switch_tab(idx)
		end, { buffer = buf, nowait = true, desc = "Switch to tab " .. TABS[idx].label })
	end

	local function back_or_close()
		if not shell.direct_open and #shell.stack > 1 then
			local top = shell.stack[#shell.stack]
			if top and top.on_pop then
				top.on_pop()
			end
			table.remove(shell.stack)
			shell_resize_for_tab()
			shell_redraw()
			vim.api.nvim_win_set_cursor(shell.win, { LIST_HEADER_LINES + 1, 2 })
		else
			shell_close()
		end
	end
	shell_back_or_close_fn = back_or_close
	bmap(buf, km().close, back_or_close, "Back / Close")
	bmap(buf, km().close_alt, back_or_close, "Back / Close")
end

function shell_resize_for_tab()
	if not shell_is_open() then
		return
	end
	local w, h = shell_dims()
	w = math.min(w, vim.o.columns - 4)
	h = math.min(h, vim.o.lines - 4)
	local row = math.floor((vim.o.lines - h) / 2)
	local col = math.floor((vim.o.columns - w) / 2)
	vim.api.nvim_win_set_config(shell.win, {
		relative = "editor",
		width = w,
		height = h,
		row = row,
		col = col,
	})
end

local function shell_push(view)
	table.insert(shell.stack, view)
	shell_redraw()
end

function M.switch_tab(tab_idx)
	if not shell_is_open() then
		M.open_tab(tab_idx)
		return
	end
	shell.active_tab = tab_idx
	shell.stack = {}
	shell.direct_open = false
	shell_resize_for_tab()
	local tab = TABS[tab_idx]
	if tab then
		local launcher = M["_tab_" .. tab.id]
		if launcher then
			launcher()
		end
	end
end

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

local function list_set_cursor(row_idx)
	if not shell_is_open() then
		return
	end
	local target = LIST_HEADER_LINES + row_idx
	local line_count = vim.api.nvim_buf_line_count(shell.buf)
	if target < 1 or target > line_count then
		return
	end
	vim.api.nvim_win_set_cursor(shell.win, { target, 2 })
end

local function list_current_idx(rows)
	if not shell_is_open() then
		return nil
	end
	local cur = vim.api.nvim_win_get_cursor(shell.win)[1]
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

local LABEL_WIDTH = 14

local function form_render_lines(fields, inner_w)
	local lines = {}
	local sep_line = string.rep("─", inner_w)

	for _, field in ipairs(fields) do
		if field.key == "__sep__" then
			table.insert(lines, sep_line)
		elseif field.key == "__action__" then
			local lbl = "  " .. field.label .. "  "
			local apad = math.floor((inner_w - #lbl) / 2)
			table.insert(lines, string.rep(" ", math.max(0, apad)) .. lbl)
		else
			local label_col = string.format("  %-" .. LABEL_WIDTH .. "s", field.label)
			local sep = "│ "
			local raw = field.display and field.display(field.value) or field.value
			local value_str = (type(raw) == "string") and raw or ""
			local max_val = inner_w - #label_col - #sep - 1
			if max_val > 0 and #value_str > max_val then
				value_str = value_str:sub(1, max_val - 1) .. "…"
			end
			table.insert(lines, label_col .. sep .. value_str)
		end
	end
	return lines
end

local function form_nav(fields)
	local nav = {}
	local line = 0
	for _, field in ipairs(fields) do
		if field.key == "__sep__" then
			line = line + 1
		else
			table.insert(nav, { line = line, field = field })
			line = line + 1
		end
	end
	return nav
end

---@class FormField
---@field key string|nil
---@field label string
---@field value any
---@field display function|nil
---@field edit function|nil

--- Open a form inline in the shell.
---@param fields FormField[]
---@param title string
---@param on_confirm function
local function open_form(fields, title, on_confirm)
	local cursor_idx = 1
	local form_active = true

	local content_start = TAB_BAR_LINES -- 0-based

	local function set_cursor(nav)
		if not shell_is_open() or not form_active then
			return
		end
		local entry = nav[cursor_idx]
		if entry then
			local target = content_start + 2 + entry.line + 1
			local line_count = vim.api.nvim_buf_line_count(shell.buf)
			if target >= 1 and target <= line_count then
				vim.api.nvim_win_set_cursor(shell.win, { target, 2 })
			end
		end
	end

	local function render(inner_w)
		local lines = {}
		local title_pad = math.floor((inner_w - #title) / 2)
		table.insert(lines, string.rep(" ", math.max(0, title_pad)) .. title)
		table.insert(lines, string.rep("─", inner_w))
		local field_lines = form_render_lines(fields, inner_w)
		for _, l in ipairs(field_lines) do
			table.insert(lines, l)
		end
		table.insert(lines, "")
		table.insert(lines, string.rep(" ", math.floor(inner_w / 2) - 3) .. "q/Esc: back")
		return lines
	end

	local nav = form_nav(fields)

	local function confirm_field()
		local item = nav[cursor_idx]
		if not item then
			return
		end
		local field = item.field

		if field.key == "__action__" then
			form_active = false
			table.remove(shell.stack)
			shell_resize_for_tab()
			on_confirm(fields)
			shell_redraw()
			return
		end

		if field.inline_edit then
			if not shell_is_open() then
				return
			end
			local buf = shell.buf
			local lnum = content_start + 2 + item.line + 1
			local label_col = string.format("  %-" .. LABEL_WIDTH .. "s", field.label)
			local prefix = label_col .. "│ "
			local current_val = (field.value ~= nil and tostring(field.value)) or ""
			vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
			vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { prefix .. current_val })
			vim.api.nvim_win_set_cursor(shell.win, { lnum, #prefix + #current_val })
			vim.cmd("startinsert!")
			vim.keymap.set("i", "<CR>", "<Esc>", { buffer = buf, nowait = true })
			vim.api.nvim_create_autocmd("InsertLeave", {
				buffer = buf,
				once = true,
				callback = function()
					pcall(vim.keymap.del, "i", "<CR>", { buffer = buf })
					if not shell_is_open() then
						return
					end
					local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
					vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
					local sep_pos = line:find("│ ")
					local new_val
					if sep_pos then
						new_val = line:sub(sep_pos + 3)
					else
						new_val = line:match("^%s*(.-)%s*$") or ""
					end
					new_val = new_val:match("^%s*(.-)%s*$") or ""
					field.value = new_val ~= "" and new_val or nil
					shell_redraw()
					vim.schedule(function()
						if shell_is_open() then
							set_cursor(nav)
						end
					end)
				end,
			})
			return
		end

		if not field.edit then
			return
		end
		field.edit(field.value, function(new_value)
			field.value = new_value
			shell_redraw()
			vim.schedule(function()
				if shell_is_open() then
					set_cursor(nav)
				end
			end)
		end)
	end

	local function nav_down()
		if cursor_idx < #nav then
			cursor_idx = cursor_idx + 1
			set_cursor(nav)
		end
	end

	local function nav_up()
		if cursor_idx > 1 then
			cursor_idx = cursor_idx - 1
			set_cursor(nav)
		end
	end

	local function install_keymaps()
		if not shell_is_open() then
			return
		end
		local buf = shell.buf
		bmap(buf, km().nav_down, nav_down, "Next field")
		bmap(buf, km().nav_up, nav_up, "Previous field")
		bmap(buf, km().confirm, confirm_field, "Confirm field")
		vim.keymap.set("n", "gg", function()
			cursor_idx = 1
			set_cursor(nav)
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "G", function()
			cursor_idx = #nav
			set_cursor(nav)
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-d>", function()
			cursor_idx = math.min(#nav, cursor_idx + math.max(1, math.floor(#nav / 2)))
			set_cursor(nav)
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-u>", function()
			cursor_idx = math.max(1, cursor_idx - math.max(1, math.floor(#nav / 2)))
			set_cursor(nav)
		end, { buffer = buf, nowait = true })
	end

	local view = {
		render = render,
		install_keymaps = install_keymaps,
		on_pop = function()
			form_active = false
		end,
	}
	shell_push(view)
	vim.schedule(function()
		set_cursor(nav)
	end)
end

local function shell_select(items, opts, on_choice)
	local prompt = (opts and opts.prompt) or "Select:"
	local format_item = (opts and opts.format_item)
		or function(x)
			return type(x) == "string" and x or tostring(x)
		end
	local rows = {}
	local sel_idx = (opts and opts.initial_idx) or 1

	local function render(inner_w)
		rows = {}
		local lines = { "  " .. prompt, string.rep("─", inner_w) }
		for _, item in ipairs(items) do
			table.insert(rows, item)
			table.insert(lines, "  " .. format_item(item))
		end
		table.insert(lines, string.rep("─", inner_w))
		table.insert(lines, "  <CR> select   q/Esc cancel")
		return lines
	end

	local function install_keymaps()
		if not shell_is_open() then
			return
		end
		local buf = shell.buf

		bmap(buf, km().nav_down, function()
			local idx = list_current_idx(rows)
			if idx and idx < #rows then
				list_set_cursor(idx + 1)
			end
		end, "Next item")

		bmap(buf, km().nav_up, function()
			local idx = list_current_idx(rows)
			if idx and idx > 1 then
				list_set_cursor(idx - 1)
			end
		end, "Previous item")

		vim.keymap.set("n", "gg", function()
			if #rows > 0 then
				list_set_cursor(1)
			end
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "G", function()
			if #rows > 0 then
				list_set_cursor(#rows)
			end
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-d>", function()
			local idx = list_current_idx(rows) or 1
			list_set_cursor(math.min(#rows, idx + math.max(1, math.floor(#rows / 2))))
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-u>", function()
			local idx = list_current_idx(rows) or 1
			list_set_cursor(math.max(1, idx - math.max(1, math.floor(#rows / 2))))
		end, { buffer = buf, nowait = true })

		bmap(buf, km().confirm, function()
			local idx = list_current_idx(rows)
			if not idx then
				return
			end
			local chosen = rows[idx]
			table.remove(shell.stack)
			shell_redraw()
			vim.schedule(function()
				on_choice(chosen, idx)
			end)
		end, "Select item")

		-- q / Esc cancel
		local function cancel()
			table.remove(shell.stack)
			shell_redraw()
			vim.schedule(function()
				on_choice(nil, nil)
			end)
		end
		vim.keymap.set("n", "q", cancel, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, nowait = true })
	end

	shell_push({ render = render, install_keymaps = install_keymaps, owns_cancel = true })
	vim.schedule(function()
		if shell_is_open() then
			list_set_cursor(sel_idx)
		end
	end)
end

local function shell_input(prompt, default, on_done)
	local value = default or ""

	local function render(inner_w)
		return {
			"  " .. prompt,
			string.rep("─", inner_w),
			"  " .. value,
			string.rep("─", inner_w),
			"  <CR>/<Esc> confirm   Ctrl-C cancel",
		}
	end

	local function install_keymaps()
		if not shell_is_open() then
			return
		end
		local buf = shell.buf
		local lnum = TAB_BAR_LINES + 3

		for _, k in ipairs({ km().close, km().close_alt }) do
			vim.keymap.set("n", k, function() end, { buffer = buf, nowait = true })
		end

		local function activate()
			if not shell_is_open() then
				return
			end
			vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
			vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { "  " .. value })
			vim.api.nvim_win_set_cursor(shell.win, { lnum, 2 + #value })
			vim.keymap.set("i", "<CR>", "<Esc>", { buffer = buf, nowait = true })
			vim.cmd("startinsert!")

			vim.api.nvim_create_autocmd("InsertLeave", {
				buffer = buf,
				once = true,
				callback = function()
					pcall(vim.keymap.del, "i", "<CR>", { buffer = buf })
					if not shell_is_open() then
						return
					end
					local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
					vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
					local raw = line:match("^%s*(.-)%s*$") or ""
					table.remove(shell.stack)
					shell_redraw()
					vim.schedule(function()
						on_done(raw ~= "" and raw or nil)
					end)
				end,
			})
		end

		vim.schedule(activate)
	end

	shell_push({ render = render, install_keymaps = install_keymaps })
end

local function edit_billable(current, on_done)
	shell_select({ "No", "Yes" }, { prompt = "Billable?" }, function(choice)
		if choice == nil then
			return
		end
		on_done(choice == "Yes")
	end)
end

local function edit_tags(org_id, current_ids, on_done)
	api.getOrganizationTags(org_id, function(err, data)
		if err or not data or not data.data then
			vim.notify("Failed to fetch tags: " .. (err or "unknown error"), vim.log.levels.ERROR)
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

		local function loop(restore_idx)
			local items = {}
			for _, tag in ipairs(all_tags) do
				table.insert(items, tag)
			end
			table.insert(items, { id = "__new__", name = "+ Create new tag…" })
			table.insert(items, { id = "__done__", name = "Done" })

			shell_select(items, {
				prompt = "Tags (toggle, then Done):",
				initial_idx = restore_idx or 1,
				format_item = function(item)
					if item.id == "__new__" or item.id == "__done__" then
						return item.name
					end
					return (selected[item.id] and "[x] " or "[ ] ") .. item.name
				end,
			}, function(chosen, chosen_idx)
				if chosen == nil or chosen.id == "__done__" then
					local ids = {}
					for id in pairs(selected) do
						table.insert(ids, id)
					end
					local refreshed = {}
					for _, tag in ipairs(all_tags) do
						refreshed[tag.id] = tag.name
					end
					on_done(#ids > 0 and ids or nil, refreshed)
				elseif chosen.id == "__new__" then
					shell_input("New tag name:", "", function(name)
						if not name then
							vim.schedule(function()
								loop(chosen_idx)
							end)
							return
						end
						api.createTag(org_id, { name = name }, function(cerr, cdata)
							if cdata and cdata.data then
								cache.invalidate_cache("organizations/" .. org_id .. "/tags")
								table.insert(all_tags, cdata.data)
								selected[cdata.data.id] = true
								vim.notify("Tag created: " .. name, vim.log.levels.INFO)
							elseif cerr then
								vim.notify("Failed to create tag: " .. cerr, vim.log.levels.ERROR)
							end
							vim.schedule(function()
								loop(chosen_idx)
							end)
						end)
					end)
				else
					selected[chosen.id] = not selected[chosen.id] and true or nil
					vim.schedule(function()
						loop(chosen_idx)
					end)
				end
			end)
		end
		loop(1)
	end)
end

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

local function display_project(project_map, project_id)
	if not project_id then
		return "(none)"
	end
	return project_map[project_id] or project_id
end

local function display_task(task_map, task_id)
	if not task_id then
		return "(none)"
	end
	return task_map[task_id] or task_id
end

local function edit_task(org_id, project_id, current_task_id, task_map, on_done)
	if not project_id then
		vim.notify("Select a project first.", vim.log.levels.WARN)
		on_done(current_task_id)
		return
	end
	api.getOrganizationTasks(org_id, { project_id = project_id, done = "false" }, function(err, data)
		if err or not data or not data.data then
			vim.notify("Failed to fetch tasks: " .. (err or "unknown error"), vim.log.levels.ERROR)
			on_done(current_task_id)
			return
		end
		for k in pairs(task_map) do
			task_map[k] = nil
		end
		for _, t in ipairs(data.data) do
			task_map[t.id] = t.name
		end

		local items = { { id = nil, name = "(no task)" } }
		for _, t in ipairs(data.data) do
			table.insert(items, t)
		end
		table.insert(items, { id = "__new__", name = "+ Create new task…" })
		vim.schedule(function()
			shell_select(items, {
				prompt = "Task:",
				format_item = function(t)
					return t.name
				end,
			}, function(choice)
				if choice == nil then
					on_done(current_task_id)
					return
				end
				if choice.id == "__new__" then
					shell_input("New task name: ", "", function(name)
						if not name or name:match("^%s*$") then
							on_done(current_task_id)
							return
						end
						name = name:match("^%s*(.-)%s*$")
						api.createTask(
							org_id,
							{ name = name, is_done = false, project_id = project_id },
							function(cerr, cdata)
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
							end
						)
					end)
					return
				end
				on_done(choice.id)
			end)
		end)
	end)
end

local function pick_client(org_id, current_id, clients, done)
	local items = { { id = nil, name = "(no client)" } }
	for _, c in ipairs(clients) do
		table.insert(items, c)
	end
	table.insert(items, { id = "__new__", name = "+ Create new client…" })
	shell_select(items, {
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
			shell_input("New client name: ", "", function(name)
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
		for k in pairs(project_map) do
			project_map[k] = nil
		end
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

		vim.schedule(function()
			shell_select(items, {
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
					shell_input("Project name: ", "", function(name)
						if not name or name:match("^%s*$") then
							on_done(current_id)
							return
						end
						name = name:match("^%s*(.-)%s*$")
						shell_select(PROJECT_COLORS, {
							prompt = "Color:",
							format_item = function(c)
								return c.label
							end,
						}, function(color)
							if not color then
								on_done(current_id)
								return
							end
							shell_select({ { id = false, name = "No" }, { id = true, name = "Yes" } }, {
								prompt = "Billable by default?",
								format_item = function(c)
									return c.name
								end,
							}, function(bill)
								if not bill then
									on_done(current_id)
									return
								end
								local billable = bill.id == true
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
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Org / project / tag selectors (used from open and standalone)
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

		vim.schedule(function()
			shell_select(items, {
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
	end)
end

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

	shell_input("Project name:", "", function(name)
		if not name then
			return
		end
		shell_select(PROJECT_COLORS, {
			prompt = "Project color:",
			format_item = function(c)
				return c.label
			end,
		}, function(color_choice)
			if not color_choice then
				return
			end
			shell_select({ { id = false, name = "No" }, { id = true, name = "Yes" } }, {
				prompt = "Billable by default?",
				format_item = function(x)
					return x.name
				end,
			}, function(billable_choice)
				if not billable_choice then
					return
				end
				local billable = billable_choice.id
				api.getOrganizationClients(org_id, function(cerr, cdata)
					local clients = (cdata and cdata.data) or {}
					vim.schedule(function()
						pick_client(org_id, nil, clients, function(client_id)
							api.createProject(org_id, {
								name = name,
								color = color_choice.value,
								billable_by_default = billable,
								is_billable = billable,
								client_id = client_id or vim.NIL,
							}, function(perr, pdata)
								vim.schedule(function()
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
		end)
	end)
end

local function make_time_entry_fields(org_id, initial, fields_ref, project_map, task_map, tag_map)
	fields_ref[1] = {
		key = "description",
		label = "Description",
		value = initial.description,
		inline_edit = true,
		display = function(v)
			return v or "(none)"
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
				if new_pid ~= v then
					for _, f in ipairs(fields_ref) do
						if f.key == "task" then
							f.value = nil
						end
					end
					for k in pairs(task_map) do
						task_map[k] = nil
					end
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
			edit_tags(org_id, v, function(ids, refreshed)
				if refreshed then
					for k, name in pairs(refreshed) do
						tag_map[k] = name
					end
				end
				done(ids)
			end)
		end,
	}
	return fields_ref
end

local function timer_tab_open_start_form()
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
	local need_tasks = (ci.project_id and ci.task_id) and 1 or 0

	local function open_form_now()
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
			shell.stack = {}
			M._tab_timer()
		end)
	end

	local function maybe_open()
		if fetched_projects == 1 and fetched_tags == 1 and fetched_tasks == need_tasks then
			open_form_now()
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
		api.getOrganizationTasks(org_id, { project_id = ci.project_id, done = "false" }, function(err, data)
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

local function timer_tab_open_edit_form()
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
	local need_tasks = (entry.project_id and entry.task_id) and 1 or 0

	local function finalize_edit(description, billable, tags, project_id, task_id)
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

	local function open_form_now()
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
			finalize_edit(vals.description, vals.billable, vals.tags, vals.project, vals.task)
		end)
	end

	local function maybe_open()
		if fetched_projects == 1 and fetched_tags == 1 and fetched_tasks == need_tasks then
			open_form_now()
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
		api.getOrganizationTasks(org_id, { project_id = entry.project_id, done = "false" }, function(err, data)
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

function M._tab_timer()
	local entry = tracker.storage.active_entry

	if not entry then
		local function render(inner_w)
			local lines = {}
			local lbl = string.format("  %-14s│ ", "Status")
			table.insert(lines, string.rep("─", inner_w))
			table.insert(lines, lbl .. "○ Stopped")
			table.insert(lines, string.rep("─", inner_w))
			table.insert(lines, "")
			table.insert(lines, "  s start   <Tab>/<S-Tab> cycle   <leader>1-6 jump   q close")
			return lines
		end
		local function install_keymaps()
			if not shell_is_open() then
				return
			end
			local buf = shell.buf
			bmap(buf, km().nav_down, function() end, "—")
			bmap(buf, km().nav_up, function() end, "—")
			bmap(buf, km().confirm, function() end, "—")
			vim.keymap.set("n", "s", function()
				timer_tab_open_start_form()
			end, { buffer = buf, nowait = true, desc = "Start timer" })
		end
		shell_push({ render = render, install_keymaps = install_keymaps })
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
	local need_tasks = (entry.project_id and entry.task_id) and 1 or 0

	local function parse_iso(s)
		if type(s) ~= "string" then
			return nil
		end
		local y, mo, d, h, mi, sec = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
		if not y then
			return nil
		end
		y, mo, d, h, mi, sec = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(sec)
		local now = os.time()
		local tz_offset = os.difftime(now, os.time(os.date("!*t", now)))
		return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec }) + tz_offset
	end

	local function elapsed_str()
		local t1 = entry.start and parse_iso(entry.start)
		if not t1 then
			return "running"
		end
		local secs = math.max(0, os.time() - t1)
		local h = math.floor(secs / 3600)
		local m = math.floor((secs % 3600) / 60)
		if h > 0 then
			return string.format("● Running  %dh %02dm", h, m)
		end
		return string.format("● Running  %dm", m)
	end

	local function finalize_edit(description, billable, tags, project_id, task_id)
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

	local function open_form_now()
		if #shell.stack > 0 then
			table.remove(shell.stack)
		end

		local entry_fields = {}
		make_time_entry_fields(org_id, {
			description = entry.description,
			billable = entry.billable,
			project_id = entry.project_id,
			task_id = entry.task_id,
			tags = entry.tags,
		}, entry_fields, project_map, task_map, tag_map)

		local fields = {
			{
				key = "status",
				label = "Status",
				value = true,
				display = function(_)
					return elapsed_str()
				end,
			},
		}
		for _, f in ipairs(entry_fields) do
			table.insert(fields, f)
		end
		table.insert(fields, { key = "__sep__", label = "" })
		table.insert(fields, { key = "__action__", label = "✎  Save" })

		open_form(fields, "Timer", function(f)
			local vals = fields_to_vals(f)
			finalize_edit(vals.description, vals.billable, vals.tags, vals.project, vals.task)
			shell.stack = {}
			M._tab_timer()
		end)

		vim.schedule(function()
			if not shell_is_open() then
				return
			end
			vim.keymap.set("n", "s", function()
				tracker.stop()
				shell.stack = {}
				M._tab_timer()
			end, { buffer = shell.buf, nowait = true, desc = "Stop timer" })
		end)
	end

	local function maybe_open()
		if fetched_projects == 1 and fetched_tags == 1 and fetched_tasks == need_tasks then
			open_form_now()
		end
	end

	shell_push({
		render = function(inner_w)
			return { string.rep("─", inner_w), "  Loading…" }
		end,
	})

	api.getOrganizationProjects(org_id, function(err, data)
		if not err and data and data.data then
			for _, p in ipairs(data.data) do
				project_map[p.id] = p.name
			end
		end
		fetched_projects = 1
		vim.schedule(maybe_open)
	end)

	if need_tasks == 1 then
		api.getOrganizationTasks(org_id, { project_id = entry.project_id, done = "false" }, function(err, data)
			if not err and data and data.data then
				for _, t in ipairs(data.data) do
					task_map[t.id] = t.name
				end
			end
			fetched_tasks = 1
			vim.schedule(maybe_open)
		end)
	end

	api.getOrganizationTags(org_id, function(err, data)
		if not err and data and data.data then
			for _, t in ipairs(data.data) do
				tag_map[t.id] = t.name
			end
		end
		fetched_tags = 1
		vim.schedule(maybe_open)
	end)
end

function M._tab_status()
	local auth_mod = require("solidtime.auth")
	local memberships_data = nil
	local projects_data = nil

	local function open_status_form()
		if #shell.stack > 0 then
			table.remove(shell.stack)
		end

		local function auth_display(_)
			local cfg = config.get()
			local url = cfg.api_url or "(no URL)"
			local key = cfg.api_key
			local masked = key and (string.rep("*", math.min(math.max(0, #key - 4), 12)) .. key:sub(-4)) or "(no key)"
			return url .. "  " .. masked
		end

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

		local fields = {
			{
				key = "auth",
				label = "Auth",
				value = true,
				display = auth_display,
				edit = function(_, on_done)
					auth_mod.prompt_api_key()
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
			shell_close()
		end)
	end

	local fetched_memberships = 0
	local fetched_projects = 0

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

	shell_push({
		render = function(inner_w)
			return { string.rep("─", inner_w), "  Loading…" }
		end,
	})
end

function M._tab_projects()
	local autotrack_mod = require("solidtime.autotrack")
	local org_id = tracker.storage.current_information and tracker.storage.current_information.organization_id

	local COL_LOCAL = 18
	local COL_PROJ = 22
	local COL_AUTO = 8

	local all_org_projects = nil
	local rows = {}
	local search_query = ""
	local searching = false

	local function make_rows()
		local proj_id_to_name = {}
		if all_org_projects then
			for _, p in ipairs(all_org_projects) do
				proj_id_to_name[p.id] = p.name
			end
		end

		local projects = autotrack_mod.read_config()
		rows = {}
		local names = vim.tbl_keys(projects)
		table.sort(names)
		local q = search_query ~= "" and search_query:lower() or nil
		for _, name in ipairs(names) do
			if not q or name:lower():find(q, 1, true) then
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
		end
	end

	local function render(inner_w)
		make_rows()
		local title_line
		if searching then
			title_line = "  Projects  /  " .. search_query .. "█"
		elseif search_query ~= "" then
			title_line = "  Projects  [/" .. search_query .. "]"
		else
			title_line = "  Local name"
				.. string.rep(" ", math.max(1, COL_LOCAL - 10))
				.. "│ "
				.. pad("Solidtime project", COL_PROJ)
				.. "│ "
				.. pad("Auto", COL_AUTO)
				.. "│ Description"
		end
		local header = searching and title_line
			or (
				"  "
				.. pad("Local name", COL_LOCAL)
				.. "│ "
				.. pad("Solidtime project", COL_PROJ)
				.. "│ "
				.. pad("Auto", COL_AUTO)
				.. "│ Description"
			)
		if searching or search_query ~= "" then
			header = title_line
		end
		local lines = { header, string.rep("─", inner_w) }
		if all_org_projects == nil then
			table.insert(lines, "  Loading…")
		elseif #rows == 0 and search_query ~= "" then
			table.insert(lines, "  (no matches)")
		elseif #rows == 0 then
			table.insert(lines, "  (no projects registered — press 'a' to add one)")
		else
			for _, r in ipairs(rows) do
				table.insert(lines, r.line)
			end
		end
		table.insert(lines, string.rep("─", inner_w))
		if searching then
			table.insert(lines, "  typing… <CR> confirm   <Esc> cancel")
		elseif search_query ~= "" then
			table.insert(lines, "  / search   <Esc> clear   a add  d delete  <CR> edit  t tasks  q close")
		else
			table.insert(lines, "  / search   a add  d delete  <CR> edit  t tasks  q close")
		end
		return lines
	end

	local function open_project_form(local_name)
		local projects = autotrack_mod.read_config()
		local existing = (local_name and projects[local_name]) or {}
		local is_new = local_name == nil

		if not org_id then
			vim.notify("No organization selected. Run :SolidTime open first.", vim.log.levels.WARN)
			return
		end

		local all_projects = all_org_projects or {}

		api.getOrganizationClients(org_id, function(cerr, cdata)
			local all_clients = (not cerr and cdata and cdata.data) or {}

			local function get_project_client_id(pid)
				if not pid then
					return nil
				end
				for _, p in ipairs(all_projects) do
					if p.id == pid then
						local cid = p.client_id
						return (cid == vim.NIL) and nil or cid
					end
				end
				return nil
			end

			local local_name_field
			if is_new then
				local detected = autotrack_mod.detect_project() or ""
				local_name_field = {
					key = "local_name",
					label = "Local name",
					value = detected,
					display = function(v)
						return (v ~= "" and v) or "(type to set)"
					end,
					inline_edit = true,
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

			local function st_proj_display(pid)
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

			local function st_proj_edit(pid, done)
				local items = {}
				for _, p in ipairs(all_projects) do
					table.insert(items, p)
				end
				table.insert(items, { id = "__new__", name = "+ Create new project…" })
				shell_select(items, {
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
						shell_input("Project name: ", "", function(name)
							if not name or name:match("^%s*$") then
								done(pid)
								return
							end
							name = name:match("^%s*(.-)%s*$")
							vim.schedule(function()
								shell_select(PROJECT_COLORS, {
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
											vim.schedule(function()
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

			local form_fields = {
				local_name_field,
				{
					key = "solidtime_project_id",
					label = "ST project",
					value = existing.solidtime_project_id,
					display = st_proj_display,
					edit = st_proj_edit,
				},
				{
					key = "client_id",
					label = "Client",
					value = get_project_client_id(existing.solidtime_project_id),
					display = client_display,
					edit = function(cid, done)
						pick_client(org_id, cid, all_clients, done)
					end,
				},
				{
					key = "auto_start",
					label = "Auto-start",
					value = existing.auto_start or false,
					display = function(v)
						return v and "Yes" or "No"
					end,
					edit = function(_, done)
						shell_select({ { id = false, name = "No" }, { id = true, name = "Yes" } }, {
							prompt = "Auto-start?",
							format_item = function(x)
								return x.name
							end,
						}, function(c)
							if c == nil then
								return
							end
							done(c.id)
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
					inline_edit = true,
				},
				{
					key = "default_billable",
					label = "Billable",
					value = existing.default_billable or false,
					display = function(v)
						return v and "Yes" or "No"
					end,
					edit = function(_, done)
						shell_select({ { id = false, name = "No" }, { id = true, name = "Yes" } }, {
							prompt = "Default billable?",
							format_item = function(x)
								return x.name
							end,
						}, function(c)
							if c == nil then
								return
							end
							done(c.id)
						end)
					end,
				},
				{ key = "__sep__", label = "" },
				{ key = "__action__", label = "Save" },
			}

			local form_title = is_new and "Add Project" or ("Edit: " .. local_name)

			open_form(form_fields, form_title, function(f)
				local vals = fields_to_vals(f)
				local key = vals.local_name
				if not key or key == "" then
					vim.notify("Local project name cannot be empty.", vim.log.levels.ERROR)
					return
				end

				local function finish_save()
					local updated = autotrack_mod.read_config()
					updated[key] = {
						solidtime_project_id = vals.solidtime_project_id,
						auto_start = vals.auto_start or false,
						default_description = (vals.default_description ~= "") and vals.default_description or nil,
						default_billable = vals.default_billable or false,
						default_tags = existing.default_tags or {},
						organization_id = existing.organization_id
							or (
								tracker.storage.current_information
								and tracker.storage.current_information.organization_id
							),
						member_id = existing.member_id
							or (tracker.storage.current_information and tracker.storage.current_information.member_id),
					}
					autotrack_mod.write_config(updated)
					vim.notify("Saved project '" .. key .. "'.", vim.log.levels.INFO)
					vim.schedule(function()
						shell_redraw()
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

	local function install_keymaps()
		if not shell_is_open() then
			return
		end
		local buf = shell.buf

		bmap(buf, km().nav_down, function()
			make_rows()
			local idx = list_current_idx(rows)
			if idx and idx < #rows then
				list_set_cursor(idx + 1)
			end
		end, "Next project")

		bmap(buf, km().nav_up, function()
			make_rows()
			local idx = list_current_idx(rows)
			if idx and idx > 1 then
				list_set_cursor(idx - 1)
			end
		end, "Previous project")

		vim.keymap.set("n", "gg", function()
			if #rows > 0 then
				list_set_cursor(1)
			end
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "G", function()
			if #rows > 0 then
				list_set_cursor(#rows)
			end
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-d>", function()
			local idx = list_current_idx(rows) or 1
			list_set_cursor(math.min(#rows, idx + math.max(1, math.floor(#rows / 2))))
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-u>", function()
			local idx = list_current_idx(rows) or 1
			list_set_cursor(math.max(1, idx - math.max(1, math.floor(#rows / 2))))
		end, { buffer = buf, nowait = true })

		bmap(buf, km().confirm, function()
			local idx = list_current_idx(rows)
			if not idx then
				return
			end
			open_project_form(rows[idx].key)
		end, "Edit project mapping")

		bmap(buf, km().add, function()
			open_project_form(nil)
		end, "Add project mapping")

		bmap(buf, km().tasks, function()
			local idx = list_current_idx(rows)
			if not idx then
				return
			end
			local row_data = rows[idx]
			if not row_data then
				return
			end
			local projects = autotrack_mod.read_config()
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
			shell.active_tab = 5
			shell_resize_for_tab()
			shell.stack = {}
			M._tab_tasks(st_id, proj_name)
		end, "Open tasks for project")

		bmap(buf, km().delete, function()
			local idx = list_current_idx(rows)
			if not idx then
				return
			end
			local row_data = rows[idx]
			if not row_data then
				return
			end
			shell_select({ { id = false, name = "No" }, { id = true, name = "Yes" } }, {
				prompt = "Delete '" .. row_data.key .. "'?",
				format_item = function(x)
					return x.name
				end,
			}, function(choice)
				if not choice or not choice.id then
					return
				end
				local projects = autotrack_mod.read_config()
				projects[row_data.key] = nil
				autotrack_mod.write_config(projects)
				vim.notify("Removed '" .. row_data.key .. "'.", vim.log.levels.INFO)
				vim.schedule(function()
					shell_redraw()
				end)
			end)
		end, "Delete project mapping")

		vim.keymap.set("n", "/", function()
			if not shell_is_open() then
				return
			end
			searching = true
			shell_redraw()
			vim.ui.input({ prompt = "/" }, function(input)
				searching = false
				if input ~= nil then
					search_query = input
				end
				vim.schedule(function()
					if shell_is_open() then
						shell_redraw()
						if #rows > 0 then
							list_set_cursor(1)
						end
					end
				end)
			end)
		end, { buffer = buf, nowait = true, desc = "Search projects" })

		vim.keymap.set("n", "<Esc>", function()
			if not shell_is_open() then
				return
			end
			if search_query ~= "" then
				search_query = ""
				shell_redraw()
				if #rows > 0 then
					list_set_cursor(1)
				end
			end
		end, { buffer = buf, nowait = true, desc = "Clear search" })
	end

	shell_push({ render = render, install_keymaps = install_keymaps })

	if org_id then
		cache.invalidate_cache("organizations/" .. org_id .. "/projects")
		api.getOrganizationProjects(org_id, function(err, data)
			vim.schedule(function()
				if not shell_is_open() then
					return
				end
				if err or not data or not data.data then
					all_org_projects = {}
					vim.notify("Could not load projects: " .. tostring(err or "unknown"), vim.log.levels.WARN)
				else
					all_org_projects = data.data
				end
				shell_redraw()
				if #rows > 0 then
					list_set_cursor(1)
				end
			end)
		end)
	else
		all_org_projects = {}
	end
end

function M._tab_clients()
	local org_id = tracker.storage.current_information and tracker.storage.current_information.organization_id
	if not org_id then
		vim.notify("No organization selected. Run :SolidTime open first.", vim.log.levels.WARN)
		return
	end

	local clients = nil
	local rows = {}
	local search_query = ""
	local searching = false

	local function filtered_clients()
		if not clients then
			return {}
		end
		if search_query == "" then
			return clients
		end
		local q = search_query:lower()
		local out = {}
		for _, c in ipairs(clients) do
			if (c.name or ""):lower():find(q, 1, true) then
				table.insert(out, c)
			end
		end
		return out
	end

	local function render(inner_w)
		rows = {}
		local title_line
		if searching then
			title_line = "  Name  /  " .. search_query .. "█"
		elseif search_query ~= "" then
			title_line = "  Name  [/" .. search_query .. "]"
		else
			title_line = "  Name"
		end
		local lines = { title_line, string.rep("─", inner_w) }
		local visible = filtered_clients()
		if clients == nil then
			table.insert(lines, "  Loading…")
		elseif #visible == 0 and search_query ~= "" then
			table.insert(lines, "  (no matches)")
		elseif #clients == 0 then
			table.insert(lines, "  (no clients — press 'a' to create one)")
		else
			for _, c in ipairs(visible) do
				table.insert(rows, c)
				table.insert(lines, "  " .. (c.name or c.id))
			end
		end
		table.insert(lines, string.rep("─", inner_w))
		if searching then
			table.insert(lines, "  typing… <CR> confirm   <Esc> cancel")
		elseif search_query ~= "" then
			table.insert(lines, "  / search   <Esc> clear   a add  d delete  <CR> rename  q close")
		else
			table.insert(lines, "  / search   a add  d delete  <CR> rename  q close")
		end
		return lines
	end

	local function install_keymaps()
		if not shell_is_open() then
			return
		end
		local buf = shell.buf

		bmap(buf, km().nav_down, function()
			local idx = list_current_idx(rows)
			if idx and idx < #rows then
				list_set_cursor(idx + 1)
			end
		end, "Next client")

		bmap(buf, km().nav_up, function()
			local idx = list_current_idx(rows)
			if idx and idx > 1 then
				list_set_cursor(idx - 1)
			end
		end, "Previous client")

		vim.keymap.set("n", "gg", function()
			if #rows > 0 then
				list_set_cursor(1)
			end
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "G", function()
			if #rows > 0 then
				list_set_cursor(#rows)
			end
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-d>", function()
			local idx = list_current_idx(rows) or 1
			list_set_cursor(math.min(#rows, idx + math.max(1, math.floor(#rows / 2))))
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-u>", function()
			local idx = list_current_idx(rows) or 1
			list_set_cursor(math.max(1, idx - math.max(1, math.floor(#rows / 2))))
		end, { buffer = buf, nowait = true })

		bmap(buf, km().add, function()
			shell_input("Client name: ", "", function(name)
				if not name or name:match("^%s*$") then
					return
				end
				name = name:match("^%s*(.-)%s*$")
				api.createClient(org_id, { name = name }, function(err, data)
					if err then
						vim.notify("Failed to create client: " .. err, vim.log.levels.ERROR)
						api.getOrganizationClients(org_id, function(ferr, fdata)
							if not ferr and fdata and fdata.data then
								clients = fdata.data
							end
							vim.schedule(function()
								if shell_is_open() then
									shell_redraw()
								end
							end)
						end)
						return
					end
					cache.invalidate_cache("organizations/" .. org_id .. "/clients")
					if data and data.data then
						table.insert(clients, data.data)
					end
					vim.notify("Client created: " .. name, vim.log.levels.INFO)
					vim.schedule(function()
						if shell_is_open() then
							shell_redraw()
							list_set_cursor(#rows)
						end
					end)
				end)
			end)
		end, "Create client")

		bmap(buf, km().confirm, function()
			local idx = list_current_idx(rows)
			if not idx then
				return
			end
			local client = rows[idx]
			shell_input("Rename client: ", client.name or "", function(name)
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
						if shell_is_open() then
							shell_redraw()
							list_set_cursor(idx)
						end
					end)
				end)
			end)
		end, "Rename client")

		bmap(buf, km().delete, function()
			local idx = list_current_idx(rows)
			if not idx then
				return
			end
			local client = rows[idx]
			shell_select({ { id = false, name = "No" }, { id = true, name = "Yes" } }, {
				prompt = "Delete client '" .. (client.name or client.id) .. "'?",
				format_item = function(x)
					return x.name
				end,
			}, function(choice)
				if not choice or not choice.id then
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
						if shell_is_open() then
							shell_redraw()
							local new_idx = math.min(idx, #rows)
							if new_idx > 0 then
								list_set_cursor(new_idx)
							end
						end
					end)
				end)
			end)
		end, "Delete client")

		vim.keymap.set("n", "/", function()
			if not shell_is_open() then
				return
			end
			searching = true
			shell_redraw()
			vim.ui.input({ prompt = "/" }, function(input)
				searching = false
				if input ~= nil then
					search_query = input
				end
				vim.schedule(function()
					if shell_is_open() then
						shell_redraw()
						if #rows > 0 then
							list_set_cursor(1)
						end
					end
				end)
			end)
		end, { buffer = buf, nowait = true, desc = "Search clients" })

		vim.keymap.set("n", "<Esc>", function()
			if not shell_is_open() then
				return
			end
			if search_query ~= "" then
				search_query = ""
				shell_redraw()
				if #rows > 0 then
					list_set_cursor(1)
				end
			end
		end, { buffer = buf, nowait = true, desc = "Clear search" })
	end

	shell_push({ render = render, install_keymaps = install_keymaps })

	cache.invalidate_cache("organizations/" .. org_id .. "/clients")
	api.getOrganizationClients(org_id, function(err, data)
		vim.schedule(function()
			if not shell_is_open() then
				return
			end
			if err or not data or not data.data then
				clients = {}
				vim.notify("Could not load clients: " .. tostring(err or "unknown"), vim.log.levels.WARN)
			else
				clients = data.data
			end
			shell_redraw()
			if #rows > 0 then
				list_set_cursor(1)
			end
		end)
	end)
end

--- Internal tasks view — renders task list for a specific project.
---@param project_id string
---@param project_name string|nil
function M._tab_tasks(project_id, project_name)
	local ci = tracker.storage.current_information
	local org_id = ci and ci.organization_id

	if not project_id then
		if not org_id then
			vim.notify("No organization selected. Run :SolidTime open first.", vim.log.levels.WARN)
			return
		end

		local picker_projects = nil
		local picker_rows = {}
		local picker_search_query = ""
		local picker_searching = false

		local function picker_filtered()
			if not picker_projects then
				return {}
			end
			if picker_search_query == "" then
				return picker_projects
			end
			local q = picker_search_query:lower()
			local out = {}
			for _, p in ipairs(picker_projects) do
				if (p.name or ""):lower():find(q, 1, true) then
					table.insert(out, p)
				end
			end
			return out
		end

		local function picker_render(inner_w)
			picker_rows = {}
			local title_line
			if picker_searching then
				title_line = "  Select a project  /  " .. picker_search_query .. "█"
			elseif picker_search_query ~= "" then
				title_line = "  Select a project  [/" .. picker_search_query .. "]"
			else
				title_line = "  Select a project"
			end
			local lines = { title_line, string.rep("─", inner_w) }
			local visible = picker_filtered()
			if picker_projects == nil then
				table.insert(lines, "  Loading…")
			elseif #visible == 0 and picker_search_query ~= "" then
				table.insert(lines, "  (no matches)")
			elseif #picker_projects == 0 then
				table.insert(lines, "  (no projects found)")
			else
				for _, p in ipairs(visible) do
					table.insert(picker_rows, p)
					table.insert(lines, "  " .. (p.name or p.id))
				end
			end
			table.insert(lines, string.rep("─", inner_w))
			if picker_searching then
				table.insert(lines, "  typing… <CR> confirm   <Esc> cancel")
			elseif picker_search_query ~= "" then
				table.insert(lines, "  / search   <Esc> clear   <CR> select   q close")
			else
				table.insert(lines, "  / search   <CR> select   q close")
			end
			return lines
		end

		local function picker_install_keymaps()
			if not shell_is_open() then
				return
			end
			local buf = shell.buf
			bmap(buf, km().nav_down, function()
				local idx = list_current_idx(picker_rows)
				if idx and idx < #picker_rows then
					list_set_cursor(idx + 1)
				end
			end, "Next project")
			bmap(buf, km().nav_up, function()
				local idx = list_current_idx(picker_rows)
				if idx and idx > 1 then
					list_set_cursor(idx - 1)
				end
			end, "Previous project")
			vim.keymap.set("n", "gg", function()
				if #rows > 0 then
					list_set_cursor(1)
				end
			end, { buffer = buf, nowait = true })
			vim.keymap.set("n", "G", function()
				if #rows > 0 then
					list_set_cursor(#rows)
				end
			end, { buffer = buf, nowait = true })
			vim.keymap.set("n", "<C-d>", function()
				local idx = list_current_idx(rows) or 1
				list_set_cursor(math.min(#rows, idx + math.max(1, math.floor(#rows / 2))))
			end, { buffer = buf, nowait = true })
			vim.keymap.set("n", "<C-u>", function()
				local idx = list_current_idx(rows) or 1
				list_set_cursor(math.max(1, idx - math.max(1, math.floor(#rows / 2))))
			end, { buffer = buf, nowait = true })

			bmap(buf, km().confirm, function()
				local idx = list_current_idx(picker_rows)
				if not idx then
					return
				end
				local selected = picker_rows[idx]
				table.remove(shell.stack)
				M._tab_tasks(selected.id, selected.name)
			end, "Select project")

			vim.keymap.set("n", "/", function()
				if not shell_is_open() then
					return
				end
				picker_searching = true
				shell_redraw()
				vim.ui.input({ prompt = "/" }, function(input)
					picker_searching = false
					if input ~= nil then
						picker_search_query = input
					end
					vim.schedule(function()
						if shell_is_open() then
							shell_redraw()
							if #picker_rows > 0 then
								list_set_cursor(1)
							end
						end
					end)
				end)
			end, { buffer = buf, nowait = true, desc = "Search projects" })

			vim.keymap.set("n", "<Esc>", function()
				if not shell_is_open() then
					return
				end
				if picker_search_query ~= "" then
					picker_search_query = ""
					shell_redraw()
					if #picker_rows > 0 then
						list_set_cursor(1)
					end
				end
			end, { buffer = buf, nowait = true, desc = "Clear search" })
		end

		shell_push({ render = picker_render, install_keymaps = picker_install_keymaps })

		cache.invalidate_cache("organizations/" .. org_id .. "/projects")
		api.getOrganizationProjects(org_id, function(err, data)
			vim.schedule(function()
				if not shell_is_open() then
					return
				end
				if err or not data or not data.data then
					picker_projects = {}
					vim.notify("No projects found.", vim.log.levels.WARN)
				else
					picker_projects = data.data
				end
				shell_redraw()
				if #picker_rows > 0 then
					list_set_cursor(1)
				end
			end)
		end)
		return
	end

	if not org_id then
		vim.notify("No organization selected. Run :SolidTime open first.", vim.log.levels.WARN)
		return
	end

	local tasks = nil
	local rows = {}
	local search_query = ""
	local searching = false

	local function filtered_tasks()
		if not tasks then
			return {}
		end
		if search_query == "" then
			return tasks
		end
		local q = search_query:lower()
		local out = {}
		for _, t in ipairs(tasks) do
			if (t.name or ""):lower():find(q, 1, true) then
				table.insert(out, t)
			end
		end
		return out
	end

	local function render(inner_w)
		rows = {}
		local title_line
		if searching then
			title_line = "  Tasks: " .. (project_name or project_id) .. "  /  " .. search_query .. "█"
		elseif search_query ~= "" then
			title_line = "  Tasks: " .. (project_name or project_id) .. "  [/" .. search_query .. "]"
		else
			title_line = "  Tasks: " .. (project_name or project_id)
		end
		local lines = { title_line, string.rep("─", inner_w) }
		local visible = filtered_tasks()
		if tasks == nil then
			table.insert(lines, "  Loading…")
		elseif #visible == 0 and search_query ~= "" then
			table.insert(lines, "  (no matches)")
		elseif #tasks == 0 then
			table.insert(lines, "  (no tasks — press 'a' to create one)")
		else
			for _, t in ipairs(visible) do
				table.insert(rows, t)
				local check = t.is_done and "[x]" or "[ ]"
				table.insert(lines, string.format("  %s  %s", check, t.name or t.id))
			end
		end
		table.insert(lines, string.rep("─", inner_w))
		if searching then
			table.insert(lines, "  typing… <CR> confirm   <Esc> cancel")
		elseif search_query ~= "" then
			table.insert(lines, "  / search   <Esc> clear   a add  d delete  <CR> toggle  r rename  p project  q close")
		else
			table.insert(lines, "  / search   a add  d delete  <CR> toggle done  r rename  p project  q close")
		end
		return lines
	end

	local function install_keymaps()
		if not shell_is_open() then
			return
		end
		local buf = shell.buf

		bmap(buf, km().nav_down, function()
			local idx = list_current_idx(rows)
			if idx and idx < #rows then
				list_set_cursor(idx + 1)
			end
		end, "Next task")

		bmap(buf, km().nav_up, function()
			local idx = list_current_idx(rows)
			if idx and idx > 1 then
				list_set_cursor(idx - 1)
			end
		end, "Previous task")

		vim.keymap.set("n", "gg", function()
			if #rows > 0 then
				list_set_cursor(1)
			end
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "G", function()
			if #rows > 0 then
				list_set_cursor(#rows)
			end
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-d>", function()
			local idx = list_current_idx(rows) or 1
			list_set_cursor(math.min(#rows, idx + math.max(1, math.floor(#rows / 2))))
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-u>", function()
			local idx = list_current_idx(rows) or 1
			list_set_cursor(math.max(1, idx - math.max(1, math.floor(#rows / 2))))
		end, { buffer = buf, nowait = true })

		bmap(buf, km().add, function()
			shell_input("Task name:", "", function(name)
				if not name then
					return
				end
				api.createTask(org_id, { name = name, is_done = false, project_id = project_id }, function(err, result)
					if err or (result and result.error) then
						vim.notify("Failed to create task: " .. tostring(err or result.error), vim.log.levels.ERROR)
						return
					end
					if result and result.data then
						table.insert(tasks, result.data)
					end
					vim.notify("Task created: " .. name, vim.log.levels.INFO)
					vim.schedule(function()
						if shell_is_open() then
							shell_redraw()
							list_set_cursor(#rows)
						end
					end)
				end)
			end)
		end, "Create task")

		bmap(buf, km().confirm, function()
			local idx = list_current_idx(rows)
			if not idx then
				return
			end
			local task = rows[idx]
			api.updateTask(org_id, task.id, { name = task.name, is_done = not task.is_done }, function(err, result)
				if err or (result and result.error) then
					vim.notify("Failed to update task: " .. tostring(err or result.error), vim.log.levels.ERROR)
					return
				end
				local marking_done = not task.is_done
				task.is_done = marking_done
				if marking_done then
					require("solidtime.autotrack").clear_done_task(project_id, task.id)
				end
				vim.schedule(function()
					if shell_is_open() then
						shell_redraw()
						list_set_cursor(idx)
					end
				end)
			end)
		end, "Toggle task done")

		vim.keymap.set("n", "r", function()
			local idx = list_current_idx(rows)
			if not idx then
				return
			end
			local task = rows[idx]
			shell_input("Rename task:", task.name or "", function(name)
				if not name then
					return
				end
				api.updateTask(org_id, task.id, { name = name, is_done = task.is_done }, function(err, result)
					if err or (result and result.error) then
						vim.notify("Failed to rename task: " .. tostring(err or result.error), vim.log.levels.ERROR)
						return
					end
					task.name = name
					vim.schedule(function()
						if shell_is_open() then
							shell_redraw()
							list_set_cursor(idx)
						end
					end)
				end)
			end)
		end, { buffer = buf, nowait = true, desc = "Rename task" })

		bmap(buf, km().delete, function()
			local idx = list_current_idx(rows)
			if not idx then
				return
			end
			local task = rows[idx]
			shell_select({ { id = false, name = "No" }, { id = true, name = "Yes" } }, {
				prompt = "Delete task '" .. (task.name or task.id) .. "'?",
				format_item = function(x)
					return x.name
				end,
			}, function(choice)
				if not choice or not choice.id then
					return
				end
				api.deleteTask(org_id, task.id, function(err, result)
					if err or (result and result.error) then
						vim.notify("Failed to delete task: " .. tostring(err or result.error), vim.log.levels.ERROR)
						return
					end
					for i, t in ipairs(tasks) do
						if t.id == task.id then
							table.remove(tasks, i)
							break
						end
					end
					vim.notify("Task deleted.", vim.log.levels.INFO)
					vim.schedule(function()
						if shell_is_open() then
							shell_redraw()
							local new_idx = math.min(idx, #rows)
							if new_idx > 0 then
								list_set_cursor(new_idx)
							end
						end
					end)
				end)
			end)
		end, "Delete task")

		vim.keymap.set("n", "p", function()
			if not shell_is_open() then
				return
			end
			table.remove(shell.stack)
			M._tab_tasks(nil, nil)
		end, { buffer = buf, nowait = true, desc = "Switch project" })

		vim.keymap.set("n", "/", function()
			if not shell_is_open() then
				return
			end
			searching = true
			shell_redraw()
			vim.ui.input({ prompt = "/" }, function(input)
				searching = false
				if input ~= nil then
					search_query = input
				end
				vim.schedule(function()
					if shell_is_open() then
						shell_redraw()
						if #rows > 0 then
							list_set_cursor(1)
						end
					end
				end)
			end)
		end, { buffer = buf, nowait = true, desc = "Search tasks" })

		vim.keymap.set("n", "<Esc>", function()
			if not shell_is_open() then
				return
			end
			if search_query ~= "" then
				search_query = ""
				shell_redraw()
				if #rows > 0 then
					list_set_cursor(1)
				end
			end
		end, { buffer = buf, nowait = true, desc = "Clear search" })
	end

	shell_push({ render = render, install_keymaps = install_keymaps })

	cache.invalidate_cache_prefix("organizations/" .. org_id .. "/tasks")
	api.getOrganizationTasks(org_id, { project_id = project_id }, function(err, data)
		vim.schedule(function()
			if not shell_is_open() then
				return
			end
			if err or not data or not data.data then
				tasks = {}
				vim.notify("Could not load tasks: " .. tostring(err or "unknown"), vim.log.levels.WARN)
			else
				tasks = data.data
			end
			shell_redraw()
			if #rows > 0 then
				list_set_cursor(1)
			end
		end)
	end)
end

function M._tab_entries()
	local ci = tracker.storage.current_information
	local org_id = ci and ci.organization_id
	local member_id = ci and ci.member_id

	if not org_id then
		vim.notify("No organization selected. Run :SolidTime open first.", vim.log.levels.WARN)
		return
	end

	local COL_DATE = 12
	local COL_DUR = 8
	local COL_PROJ = 20
	local COL_BILL = 6

	local current_page = 1
	local total_pages = 1
	local entries = nil
	local rows = {}
	local proj_map = {}
	local pending_deletes = {}
	local search_query = ""
	local searching = false

	-- Pre-fetch project names
	api.getOrganizationProjects(org_id, function(err, data)
		if not err and data and data.data then
			for _, p in ipairs(data.data) do
				proj_map[p.id] = p.name
			end
		end
	end)

	local function fmt_duration(start_str, end_str)
		if not start_str or not end_str then
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
		local t1, t2 = parse_iso(start_str), parse_iso(end_str)
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

	local function filtered_entries()
		if not entries then
			return {}
		end
		if search_query == "" then
			return entries
		end
		local q = search_query:lower()
		local out = {}
		for _, e in ipairs(entries) do
			local desc = (e.description or ""):lower()
			local proj = (proj_map[e.project_id] or ""):lower()
			if desc:find(q, 1, true) or proj:find(q, 1, true) then
				table.insert(out, e)
			end
		end
		return out
	end

	local function render(inner_w)
		rows = {}
		local title_line
		if searching then
			title_line = "  Date        │ Dur     │ Project             │ Bill  │ Description  /  "
				.. search_query
				.. "█"
		elseif search_query ~= "" then
			title_line = "  Date        │ Dur     │ Project             │ Bill  │ [/" .. search_query .. "]"
		else
			title_line = "  "
				.. pad("Date", COL_DATE)
				.. "│ "
				.. pad("Duration", COL_DUR)
				.. "│ "
				.. pad("Project", COL_PROJ)
				.. "│ "
				.. pad("Bill", COL_BILL)
				.. "│ Description"
		end
		local lines = { title_line, string.rep("─", inner_w) }

		local visible = filtered_entries()
		if entries == nil then
			table.insert(lines, "  Loading…")
		elseif #visible == 0 and search_query ~= "" then
			table.insert(lines, "  (no matches)")
		elseif #entries == 0 then
			table.insert(lines, "  (no time entries found)")
		else
			for _, e in ipairs(visible) do
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

		table.insert(lines, string.rep("─", inner_w))
		local page_info = string.format("page %d/%d", current_page, total_pages)
		local staged_count = 0
		for _ in pairs(pending_deletes) do
			staged_count = staged_count + 1
		end
		local hint
		if searching then
			hint = "  typing… <CR> confirm   <Esc> cancel"
		elseif search_query ~= "" then
			hint = staged_count > 0
					and string.format(
						"  / search   <Esc> clear   [ prev  ] next  <CR> edit  d del  %s  :w commit (%d staged)  q close",
						page_info,
						staged_count
					)
				or string.format("  / search   <Esc> clear   [ prev  ] next  <CR> edit  d del  %s  q close", page_info)
		else
			hint = staged_count > 0
					and string.format(
						"  / search   [ prev  ] next  <CR> edit  d del  %s  :w commit (%d staged)  q close",
						page_info,
						staged_count
					)
				or string.format("  / search   [ prev  ] next  <CR> edit  d del  %s  q close", page_info)
		end
		table.insert(lines, hint)
		return lines
	end

	local function load_page(page)
		entries = nil
		shell_redraw()
		local params = { page = page }
		if member_id then
			params.member_ids = { member_id }
		end
		api.getOrganizationTimeEntries(org_id, params, function(err, data)
			vim.schedule(function()
				if not shell_is_open() then
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
				shell_redraw()
				if #rows > 0 then
					list_set_cursor(1)
				end
			end)
		end)
	end

	local function open_entry_edit_form(idx, entry)
		local entry_project_map = {}
		local entry_task_map = {}
		local entry_tag_map = {}
		local fetched_projects = 0
		local fetched_tags = 0
		local fetched_tasks = 0
		local need_tasks = (entry.project_id and entry.task_id) and 1 or 0

		for k, v in pairs(proj_map) do
			entry_project_map[k] = v
		end

		local function open_form_now()
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
						if shell_is_open() then
							shell_redraw()
							list_set_cursor(idx)
						end
					end)
				end)
			end)
		end

		local function maybe_open_entry()
			if fetched_projects == 1 and fetched_tags == 1 and fetched_tasks == need_tasks then
				open_form_now()
			end
		end

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
			api.getOrganizationTasks(org_id, { project_id = entry.project_id, done = "false" }, function(err, data)
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
	end

	local function install_keymaps()
		if not shell_is_open() then
			return
		end
		local buf = shell.buf

		bmap(buf, km().nav_down, function()
			local idx = list_current_idx(rows)
			if idx and idx < #rows then
				list_set_cursor(idx + 1)
			end
		end, "Next entry")

		bmap(buf, km().nav_up, function()
			local idx = list_current_idx(rows)
			if idx and idx > 1 then
				list_set_cursor(idx - 1)
			end
		end, "Previous entry")

		vim.keymap.set("n", "gg", function()
			if #rows > 0 then
				list_set_cursor(1)
			end
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "G", function()
			if #rows > 0 then
				list_set_cursor(#rows)
			end
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-d>", function()
			local idx = list_current_idx(rows) or 1
			list_set_cursor(math.min(#rows, idx + math.max(1, math.floor(#rows / 2))))
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-u>", function()
			local idx = list_current_idx(rows) or 1
			list_set_cursor(math.max(1, idx - math.max(1, math.floor(#rows / 2))))
		end, { buffer = buf, nowait = true })

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
			local idx = list_current_idx(rows)
			if not idx then
				return
			end
			open_entry_edit_form(idx, rows[idx])
		end, "Edit entry")

		bmap(buf, km().delete, function()
			local idx = list_current_idx(rows)
			if not idx then
				return
			end
			local entry = rows[idx]
			local label = (entry.description and entry.description ~= "") and entry.description or fmt_date(entry.start)
			shell_select({ { id = false, name = "No" }, { id = true, name = "Yes" } }, {
				prompt = "Delete entry '" .. label .. "'?",
				format_item = function(x)
					return x.name
				end,
			}, function(choice)
				if not choice or not choice.id then
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
						if shell_is_open() then
							shell_redraw()
							local new_idx = math.min(idx, #rows)
							if new_idx > 0 then
								list_set_cursor(new_idx)
							end
						end
					end)
				end)
			end)
		end, "Delete entry")

		-- Visual-mode bulk stage
		if km().delete and km().delete ~= false and km().delete ~= "" then
			vim.keymap.set("v", km().delete, function()
				local vstart = vim.fn.line("v")
				local vend = vim.fn.line(".")
				if vstart > vend then
					vstart, vend = vend, vstart
				end
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
				for lnum = vstart, vend do
					local row_idx = lnum - LIST_HEADER_LINES
					if row_idx >= 1 and row_idx <= #rows then
						pending_deletes[rows[row_idx].id] = true
					end
				end
				shell_redraw()
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
				local fail_count = 0
				for _, id in ipairs(ids) do
					api.deleteTimeEntry(org_id, id, function(err, _)
						done_count = done_count + 1
						if err then
							fail_count = fail_count + 1
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
							local deleted = total - fail_count
							if deleted > 0 then
								vim.notify(
									string.format("Deleted %d entr%s.", deleted, deleted == 1 and "y" or "ies"),
									vim.log.levels.INFO
								)
							end
							vim.bo[buf].modified = false
							vim.schedule(function()
								if shell_is_open() then
									shell_redraw()
									local cur_idx = list_current_idx(rows)
									if #rows > 0 then
										list_set_cursor(math.min(cur_idx or 1, #rows))
									end
								end
							end)
						end
					end)
				end
			end,
		})

		vim.keymap.set("n", "/", function()
			if not shell_is_open() then
				return
			end
			searching = true
			shell_redraw()
			vim.ui.input({ prompt = "/" }, function(input)
				searching = false
				if input ~= nil then
					search_query = input
				end
				vim.schedule(function()
					if shell_is_open() then
						shell_redraw()
						if #rows > 0 then
							list_set_cursor(1)
						end
					end
				end)
			end)
		end, { buffer = buf, nowait = true, desc = "Search entries" })

		vim.keymap.set("n", "<Esc>", function()
			if not shell_is_open() then
				return
			end
			if search_query ~= "" then
				search_query = ""
				shell_redraw()
				if #rows > 0 then
					list_set_cursor(1)
				end
			end
		end, { buffer = buf, nowait = true, desc = "Clear search" })
	end

	shell_push({ render = render, install_keymaps = install_keymaps })
	load_page(1)
end

--- Open the shell on a specific tab (by tab id string or index).
---@param tab string|integer  tab id ("timer","status","projects","clients","tasks","entries") or 1-based index
function M.open_tab(tab)
	local tab_idx = 1
	if type(tab) == "number" then
		tab_idx = tab
	elseif type(tab) == "string" then
		for i, t in ipairs(TABS) do
			if t.id == tab then
				tab_idx = i
				break
			end
		end
	end
	tab_idx = math.max(1, math.min(tab_idx, #TABS))

	local was_open = shell_is_open()
	shell_open(tab_idx)

	if not was_open then
		vim.api.nvim_win_set_config(shell.win, { title = " SolidTime ", title_pos = "center" })
	end

	shell.active_tab = tab_idx
	shell.stack = {}
	shell_resize_for_tab()
	local tab_def = TABS[tab_idx]
	if tab_def then
		local launcher = M["_tab_" .. tab_def.id]
		if launcher then
			launcher()
		end
	end
end

function M.startScreen()
	M.open_tab("timer")
	shell.direct_open = true
	timer_tab_open_start_form()
end

function M.editActiveEntry()
	M.open_tab("timer")
end

function M.statusScreen()
	M.open_tab("status")
end
function M.projectsScreen()
	M.open_tab("projects")
end
function M.clientsScreen()
	M.open_tab("clients")
end
function M.timeEntriesScreen()
	M.open_tab("entries")
end

function M.tasksScreen(project_id, project_name)
	local tab_idx = 5
	local was_open = shell_is_open()
	shell_open(tab_idx)
	if not was_open then
		vim.api.nvim_win_set_config(shell.win, { title = " SolidTime ", title_pos = "center" })
	end
	shell.active_tab = tab_idx
	shell.stack = {}
	shell_resize_for_tab()
	M._tab_tasks(project_id, project_name)
end

return M
