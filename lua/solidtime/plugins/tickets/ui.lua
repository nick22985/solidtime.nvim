--- solidtime.plugins.tickets.ui — Tickets tab rendering for the SolidTime shell.
---
--- Extracted from buffer.lua into the tickets plugin.  Uses buffer._shell_*
--- utilities to interact with the floating window.

local M = {}

local _debounce_timer = nil

function M.tab_tickets()
	local buffer = require("solidtime.buffer")
	local shell_push = buffer._shell_push
	local shell_select = buffer._shell_select
	local providers_mod = require("solidtime.plugins.tickets.providers")
	local providers = providers_mod.list()

	if #providers == 0 then
		local function render(inner_w)
			return {
				"  Tickets",
				string.rep("─", inner_w),
				"",
				"  No ticket providers configured.",
				"",
				"  Enable a provider in your solidtime setup(), e.g.:",
				'    plugins = { tickets = { providers = { freedcamp = {} } } }',
				"  Then run:  :SolidTime auth freedcamp",
				"",
				string.rep("─", inner_w),
				"  q close",
			}
		end
		local function install_keymaps() end
		shell_push({ render = render, install_keymaps = install_keymaps })
		return
	end

	if #providers > 1 then
		local autotrack = require("solidtime.autotrack")
		local project_name = autotrack.detect_project()
		if project_name then
			local cfg = autotrack.read_config()
			local proj_entry = cfg[project_name] or {}
			local stored_provider_id = proj_entry.tickets and proj_entry.tickets.provider
			if stored_provider_id then
				for _, p in ipairs(providers) do
					if p.id == stored_provider_id then
						M.tab_tickets_for(p)
						return
					end
				end
			end
		end

		shell_select(providers, {
			prompt = "Select ticket provider:",
			format_item = function(p)
				return p.name
			end,
		}, function(chosen)
			if chosen then
				M.tab_tickets_for(chosen)
			end
		end)
		return
	end

	M.tab_tickets_for(providers[1])
end

--- Open the tickets view scoped to a specific provider.
---@param provider table  a registered ticket provider
function M.tab_tickets_for(provider)
	local buffer = require("solidtime.buffer")
	local tracker = require("solidtime.tracker")
	local autotrack = require("solidtime.autotrack")
	local api = require("solidtime.api")

	-- Import shell utilities from buffer
	local shell = buffer._shell
	local shell_push = buffer._shell_push
	local shell_redraw = buffer._shell_redraw
	local shell_select = buffer._shell_select
	local shell_is_open = buffer._shell_is_open
	local bmap = buffer._bmap
	local km = buffer._km
	local pad = buffer._pad
	local TAB_BAR_LINES = buffer._TAB_BAR_LINES
	local LIST_HEADER_LINES = buffer._LIST_HEADER_LINES

	local project_name = autotrack.detect_project()
	local proj_entry = project_name and (autotrack.read_config()[project_name] or {}) or {}

	local results = nil
	local rows = {}
	local search_query = ""
	local search_active = false
	local global_search = false
	local status_msg = nil
	local _search_gen = 0

	local proj_id_key = provider.id .. "_project_id"

	local function reload_proj_entry()
		if project_name then
			proj_entry = autotrack.read_config()[project_name] or {}
		end
	end

	local function provider_project_ids()
		local t = proj_entry.tickets or {}
		local raw = t[proj_id_key]
		if not raw or raw == "" then
			return {}
		end
		if raw:sub(1, 1) == "[" then
			local ok, decoded = pcall(vim.fn.json_decode, raw)
			if ok and type(decoded) == "table" then
				local ids = {}
				for _, v in ipairs(decoded) do
					if v and tostring(v) ~= "" then
						table.insert(ids, tostring(v))
					end
				end
				return ids
			end
		end
		return { tostring(raw) }
	end

	local function encode_project_ids(ids)
		if #ids == 0 then
			return nil
		end
		if #ids == 1 then
			return ids[1]
		end
		return vim.fn.json_encode(ids)
	end

	local function solidtime_project_id()
		return proj_entry.solidtime_project_id
	end

	local function save_tickets_cfg(key, value)
		if not project_name then
			return
		end
		local cfg = autotrack.read_config()
		if not cfg[project_name] then
			return
		end
		cfg[project_name].tickets = cfg[project_name].tickets or {}
		cfg[project_name].tickets[key] = value
		autotrack.write_config(cfg)
		proj_entry = cfg[project_name]
	end

	local SEARCH_LINE = TAB_BAR_LINES + 1
	local TICKET_HEADER_LINES = TAB_BAR_LINES + 4

	local function do_search(query, scope_pids)
		_search_gen = _search_gen + 1
		local my_gen = _search_gen
		results = nil
		status_msg = nil
		shell_redraw()

		local pids = scope_pids or {}

		if not global_search and #pids == 0 then
			results = {}
			status_msg = "No project linked."
			shell_redraw()
			return
		end

		local search_pids = (global_search or #pids == 0) and { "" } or pids

		local pending = #search_pids
		local merged = {}
		local first_err = nil

		for _, pid in ipairs(search_pids) do
			provider.search(query, pid, function(err, tickets)
				if my_gen ~= _search_gen then
					return
				end
				if err then
					first_err = err
				elseif tickets then
					local seen_ids = {}
					for _, t in ipairs(merged) do
						seen_ids[t.id] = true
					end
					for _, t in ipairs(tickets) do
						if not seen_ids[t.id] then
							table.insert(merged, t)
							seen_ids[t.id] = true
						end
					end
				end
				pending = pending - 1
				if pending == 0 then
					if first_err and #merged == 0 then
						results = {}
						status_msg = "Error: " .. first_err
					else
						results = merged
					end
					if shell_is_open() then
						vim.schedule(function()
							if my_gen ~= _search_gen then
								return
							end
							shell_redraw()
							if not search_active and #rows > 0 then
								local target = TICKET_HEADER_LINES + 1
								local line_count = vim.api.nvim_buf_line_count(shell.buf)
								if target <= line_count then
									vim.api.nvim_win_set_cursor(shell.win, { target, 2 })
								end
							end
						end)
					end
				end
			end)
		end
	end

	local function cancel_debounce()
		if _debounce_timer then
			pcall(vim.fn.timer_stop, _debounce_timer)
			_debounce_timer = nil
		end
	end

	local function render(inner_w)
		rows = {}
		local pids = provider_project_ids()
		local has_project_picker = type(provider.get_projects) == "function"

		local search_bar = search_query ~= "" and ("  /" .. search_query) or "  /"
		local lines = { search_bar, string.rep("─", inner_w) }

		local scope_badge = global_search and "[global]"
			or (#pids == 1 and "(project: " .. pids[1] .. ")")
			or (#pids > 1 and "(" .. #pids .. " projects linked)")
			or nil
		table.insert(lines, "  " .. provider.name .. (scope_badge and ("  " .. scope_badge) or ""))
		table.insert(lines, string.rep("─", inner_w))

		if #pids == 0 and has_project_picker and not global_search then
			table.insert(lines, "")
			table.insert(lines, "  No project linked to '" .. (project_name or "?") .. "'.")
			table.insert(lines, "  Press 'p' to pick and link a project.")
			table.insert(lines, "")
		elseif results == nil then
			table.insert(lines, "  Press '/' to search, or <CR> to list all open tickets.")
		elseif #results == 0 then
			table.insert(
				lines,
				"  (no tickets" .. (search_query ~= "" and (" matching '" .. search_query .. "'") or "") .. ")"
			)
		else
			for _, t in ipairs(results) do
				table.insert(rows, t)
				local badge = ""
				local project = type(t.project) == "string" and t.project or nil
				local board = type(t.board) == "string" and t.board or nil
				local status = type(t.status) == "string" and t.status or nil
				local priority = type(t.priority) == "string" and t.priority or nil
				if project and project ~= "" then
					badge = badge .. "[" .. project .. "]"
				end
				if board and board ~= "" then
					badge = badge .. "[" .. board .. "]"
				end
				if status and status ~= "" then
					badge = badge .. "[" .. status .. "]"
				end
				if priority and priority ~= "" then
					badge = badge .. "[" .. priority .. "]"
				end
				local label = "  " .. pad(t.title, inner_w - (badge ~= "" and #badge + 3 or 2))
				if badge ~= "" then
					label = label .. " " .. badge
				end
				table.insert(lines, label)
			end
		end

		-- Footer
		table.insert(lines, string.rep("─", inner_w))
		if status_msg then
			table.insert(lines, "  " .. status_msg)
		elseif search_active then
			table.insert(lines, "  typing…  <Esc> stop   updates after 200 ms pause")
		elseif #pids == 0 and has_project_picker and not global_search then
			table.insert(lines, "  / search   p link project   g global   q close")
		else
			local hint = "  / search"
			if has_project_picker then
				hint = hint .. "   p project"
				if #pids > 0 then
					hint = hint .. "   u unlink"
				end
			end
			hint = hint .. "   g " .. (global_search and "scoped" or "global")
			if results ~= nil then
				hint = hint .. "   o open   <CR> actions   <Esc> clear"
			end
			table.insert(lines, hint .. "   q close")
		end
		return lines
	end

	local function ticket_set_cursor(idx)
		if not shell_is_open() then
			return
		end
		local target = TICKET_HEADER_LINES + idx
		local line_count = vim.api.nvim_buf_line_count(shell.buf)
		if target < 1 or target > line_count then
			return
		end
		vim.api.nvim_win_set_cursor(shell.win, { target, 2 })
	end

	local function ticket_current_idx()
		if not shell_is_open() then
			return nil
		end
		local cur = vim.api.nvim_win_get_cursor(shell.win)[1]
		local idx = cur - TICKET_HEADER_LINES
		if idx < 1 or idx > #rows then
			return nil
		end
		return idx
	end

	local function activate_search()
		if not shell_is_open() then
			return
		end
		local buf = shell.buf
		search_active = true
		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, SEARCH_LINE - 1, SEARCH_LINE, false, { "  /" .. search_query })
		vim.api.nvim_win_set_cursor(shell.win, { SEARCH_LINE, 2 + 1 + #search_query })
		vim.keymap.set("i", "<CR>", "<Esc>", { buffer = buf, nowait = true })
		vim.keymap.set("i", "<Esc>", "<Esc>", { buffer = buf, nowait = true })
		vim.cmd("startinsert!")

		local pids = provider_project_ids()

		vim.api.nvim_create_autocmd("InsertLeave", {
			buffer = buf,
			once = true,
			callback = function()
				pcall(vim.keymap.del, "i", "<CR>", { buffer = buf })
				pcall(vim.keymap.del, "i", "<Esc>", { buffer = buf })
				if not shell_is_open() then
					return
				end
				local line = vim.api.nvim_buf_get_lines(buf, SEARCH_LINE - 1, SEARCH_LINE, false)[1] or ""
				vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
				search_query = line:match("^%s*/(.-)%s*$") or ""
				search_active = false
				cancel_debounce()
				do_search(search_query, global_search and nil or pids)
			end,
		})
	end

	local function pick_project()
		if type(provider.get_projects) ~= "function" then
			return
		end

		if not project_name then
			vim.notify("Cannot link project: no git repo detected in current directory.", vim.log.levels.ERROR)
			return
		end
		do
			local cfg = autotrack.read_config()
			if not cfg[project_name] then
				vim.notify(
					"'"
						.. project_name
						.. "' is not registered with Solidtime.\n"
						.. "Run :SolidTime open → Projects tab → register this project first.",
					vim.log.levels.ERROR
				)
				return
			end
		end

		local ok, cfg_err = provider.is_configured and provider.is_configured()
		if ok == false then
			vim.notify(provider.name .. ": " .. (cfg_err or "not configured"), vim.log.levels.ERROR)
			return
		end

		shell_push({
			render = function(inner_w)
				return {
					"  " .. provider.name .. ": link project…",
					string.rep("─", inner_w),
					"  Loading projects…",
					string.rep("─", inner_w),
					"  <Esc> cancel",
				}
			end,
			install_keymaps = function()
				local buf = shell.buf
				local function cancel()
					table.remove(shell.stack)
					shell_redraw()
				end
				vim.keymap.set("n", "q", cancel, { buffer = buf, nowait = true })
				vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, nowait = true })
			end,
		})

		provider.get_projects(function(err, remote_projects)
			if not shell_is_open() then
				return
			end
			if err or not remote_projects or #remote_projects == 0 then
				table.remove(shell.stack)
				vim.notify(
					provider.name .. ": could not fetch projects — " .. (err or "empty list"),
					vim.log.levels.ERROR
				)
				shell_redraw()
				return
			end
			table.remove(shell.stack)
			shell_select(remote_projects, {
				prompt = "Link " .. provider.name .. " project to '" .. (project_name or "?") .. "':",
				searchable = true,
				format_item = function(p)
					local label = p.title or p.name or tostring(p.id)
					return label
				end,
			}, function(chosen)
				if not chosen then
					return
				end
				local new_pid = tostring(chosen.id)
				local existing = provider_project_ids()

				for _, existing_pid in ipairs(existing) do
					if existing_pid == new_pid then
						vim.notify(
							provider.name .. " project " .. new_pid .. " is already linked.",
							vim.log.levels.INFO
						)
						shell_redraw()
						return
					end
				end

				local function after_save(msg)
					reload_proj_entry()
					vim.notify(msg, vim.log.levels.INFO)
					shell_redraw()

					if solidtime_project_id() then
						return
					end
					local ci = tracker.storage.current_information or {}
					local org_id = ci.organization_id
					if not org_id then
						return
					end
					api.getOrganizationProjects(org_id, function(perr, pdata)
						if perr or not pdata or not pdata.data or #pdata.data == 0 then
							return
						end
						shell_select(pdata.data, {
							prompt = "Also link a Solidtime project for task creation? (Esc to skip)",
							format_item = function(p)
								return p.name or p.id
							end,
						}, function(proj)
							if not proj then
								shell_redraw()
								return
							end
							local cfg = autotrack.read_config()
							if cfg[project_name] then
								cfg[project_name].solidtime_project_id = proj.id
								autotrack.write_config(cfg)
								proj_entry = cfg[project_name]
							end
							vim.notify(
								"Solidtime project '" .. (proj.name or proj.id) .. "' linked.",
								vim.log.levels.INFO
							)
							shell_redraw()
						end)
					end)
				end

				if #existing == 0 then
					save_tickets_cfg("provider", provider.id)
					save_tickets_cfg(proj_id_key, encode_project_ids({ new_pid }))
					after_save(
						"Linked " .. provider.name .. " project " .. new_pid .. " to '" .. (project_name or "?") .. "'"
					)
				else
					local select_opts = {
						{ id = "add", label = "Add  (linked: " .. table.concat(existing, ", ") .. ")" },
						{ id = "replace", label = "Replace all with " .. new_pid },
					}
					shell_select(select_opts, {
						prompt = "Project already linked — add or replace?",
						format_item = function(o)
							return o.label
						end,
					}, function(action)
						if not action then
							shell_redraw()
							return
						end
						local ids
						if action.id == "add" then
							ids = vim.list_extend(vim.deepcopy(existing), { new_pid })
						else
							ids = { new_pid }
						end
						save_tickets_cfg("provider", provider.id)
						save_tickets_cfg(proj_id_key, encode_project_ids(ids))
						after_save(
							"Linked "
								.. #ids
								.. " "
								.. provider.name
								.. " project(s) to '"
								.. (project_name or "?")
								.. "'"
						)
					end)
				end
			end)
		end)
	end

	local function unlink_projects()
		if not project_name then
			vim.notify("Cannot unlink: no git repo detected.", vim.log.levels.ERROR)
			return
		end
		local pids = provider_project_ids()
		if #pids == 0 then
			vim.notify("No projects linked to unlink.", vim.log.levels.INFO)
			return
		end

		local label = #pids == 1 and ("project " .. pids[1]) or (#pids .. " projects")
		shell_select({
			{ id = "yes", label = "Yes, unlink " .. label },
			{ id = "no", label = "Cancel" },
		}, {
			prompt = "Unlink all " .. provider.name .. " projects from '" .. project_name .. "'?",
			format_item = function(o)
				return o.label
			end,
		}, function(choice)
			if not choice or choice.id ~= "yes" then
				shell_redraw()
				return
			end
			save_tickets_cfg(proj_id_key, nil)
			save_tickets_cfg("provider", nil)
			reload_proj_entry()
			results = nil
			status_msg = nil
			vim.notify("Unlinked all " .. provider.name .. " projects from '" .. project_name .. "'.", vim.log.levels.INFO)
			shell_redraw()
		end)
	end

	local function open_url(url)
		if not url or url == "" then
			vim.notify("No URL for this ticket.", vim.log.levels.WARN)
			return
		end
		if vim.ui.open then
			vim.ui.open(url)
		else
			local cmd = vim.fn.has("mac") == 1 and "open" or "xdg-open"
			vim.fn.jobstart({ cmd, url }, { detach = true })
		end
	end

	local function open_ticket_actions(ticket)
		local ci = tracker.storage.current_information or {}
		local org_id = ci.organization_id

		local actions = {
			{ id = "open_browser", label = "Open in browser" },
			{ id = "create_task", label = "Create Solidtime task" },
			{ id = "start_timer", label = "Start timer with this title" },
			{ id = "both", label = "Create task and start timer" },
		}

		shell_select(actions, {
			prompt = ticket.title,
			format_item = function(a)
				return a.label
			end,
		}, function(chosen)
			if not chosen then
				return
			end

			local function do_start_timer()
				if not tracker.storage.current_information then
					tracker.storage.current_information = {}
				end
				tracker.storage.current_information.description = ticket.title
				tracker.start()
				buffer.open_tab("timer")
			end

			local function do_create_task(then_cb)
				if not org_id then
					vim.notify("No organization selected. Run :SolidTime open first.", vim.log.levels.WARN)
					return
				end

				local function create_or_find(pid, cb)
					api.createTask(
						org_id,
						{ name = ticket.title, is_done = false, project_id = pid },
						function(cerr, result)
							if not cerr and not (result and result.error) then
								vim.notify("Task created: " .. ticket.title, vim.log.levels.INFO)
								cb(result and result.data)
								return
							end
							local msg = tostring(cerr or result.error)
							if msg:find("422") or msg:lower():find("already exists") then
								api.getOrganizationTasks(org_id, { project_id = pid }, function(terr, tdata)
									if terr or not tdata or not tdata.data then
										vim.notify("Failed to create task: " .. msg, vim.log.levels.ERROR)
										return
									end
									local existing_task
									for _, t in ipairs(tdata.data) do
										if t.name == ticket.title then
											existing_task = t
											break
										end
									end
									if existing_task then
										vim.notify("Using existing task: " .. ticket.title, vim.log.levels.INFO)
										cb(existing_task)
									else
										vim.notify("Failed to create task: " .. msg, vim.log.levels.ERROR)
									end
								end)
							else
								vim.notify("Failed to create task: " .. msg, vim.log.levels.ERROR)
							end
						end
					)
				end

				local st_pid = solidtime_project_id()
				if st_pid then
					create_or_find(st_pid, function(task)
						if then_cb then
							then_cb(task)
						end
					end)
				else
					api.getOrganizationProjects(org_id, function(perr, pdata)
						if perr or not pdata or not pdata.data or #pdata.data == 0 then
							vim.notify(
								"Could not fetch Solidtime projects: " .. (perr or "empty"),
								vim.log.levels.ERROR
							)
							return
						end
						shell_select(pdata.data, {
							prompt = "Solidtime project for task:",
							format_item = function(p)
								return p.name or p.id
							end,
						}, function(proj)
							if not proj then
								return
							end
							if project_name then
								local cfg = autotrack.read_config()
								if cfg[project_name] then
									cfg[project_name].solidtime_project_id = proj.id
									autotrack.write_config(cfg)
									proj_entry = cfg[project_name]
								end
							end
							create_or_find(proj.id, function(task)
								if then_cb then
									then_cb(task)
								end
							end)
						end)
					end)
				end
			end

			if chosen.id == "open_browser" then
				open_url(ticket.url)
			elseif chosen.id == "create_task" then
				do_create_task(nil)
			elseif chosen.id == "start_timer" then
				do_start_timer()
			elseif chosen.id == "both" then
				do_create_task(function(new_task)
					if not tracker.storage.current_information then
						tracker.storage.current_information = {}
					end
					tracker.storage.current_information.description = ticket.title
					if new_task and new_task.id then
						tracker.storage.current_information.task_id = new_task.id
						tracker.storage.current_information.project_id = new_task.project_id
							or solidtime_project_id()
					end
					tracker.start()
					buffer.open_tab("timer")
				end)
			end
		end)
	end

	local function install_keymaps()
		if not shell_is_open() then
			return
		end
		local buf = shell.buf

		bmap(buf, km().nav_down, function()
			local idx = ticket_current_idx()
			if idx and idx < #rows then
				ticket_set_cursor(idx + 1)
			end
		end, "Next ticket")

		bmap(buf, km().nav_up, function()
			local idx = ticket_current_idx()
			if idx and idx > 1 then
				ticket_set_cursor(idx - 1)
			end
		end, "Previous ticket")

		vim.keymap.set("n", "gg", function()
			if #rows > 0 then
				ticket_set_cursor(1)
			end
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "G", function()
			if #rows > 0 then
				ticket_set_cursor(#rows)
			end
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-d>", function()
			local idx = ticket_current_idx() or 1
			ticket_set_cursor(math.min(#rows, idx + math.max(1, math.floor(#rows / 2))))
		end, { buffer = buf, nowait = true })
		vim.keymap.set("n", "<C-u>", function()
			local idx = ticket_current_idx() or 1
			ticket_set_cursor(math.max(1, idx - math.max(1, math.floor(#rows / 2))))
		end, { buffer = buf, nowait = true })

		bmap(buf, km().confirm, function()
			local pids = provider_project_ids()
			if #pids == 0 and not global_search and type(provider.get_projects) == "function" then
				return
			end
			if results == nil then
				do_search("", global_search and nil or pids)
				return
			end
			local idx = ticket_current_idx()
			if not idx then
				return
			end
			open_ticket_actions(rows[idx])
		end, "Select / search")

		if type(provider.get_projects) == "function" then
			vim.keymap.set("n", "p", function()
				pick_project()
			end, { buffer = buf, nowait = true, desc = "Link project" })
			vim.keymap.set("n", "u", function()
				unlink_projects()
			end, { buffer = buf, nowait = true, desc = "Unlink all projects" })
		end

		vim.keymap.set("n", "o", function()
			local idx = ticket_current_idx()
			if not idx then
				return
			end
			open_url(rows[idx].url)
		end, { buffer = buf, nowait = true, desc = "Open ticket in browser" })

		vim.keymap.set("n", "/", function()
			if not shell_is_open() then
				return
			end
			local pids = provider_project_ids()
			if #pids == 0 and not global_search and type(provider.get_projects) == "function" then
				return
			end
			activate_search()
		end, { buffer = buf, nowait = true, desc = "Search tickets" })

		vim.keymap.set("n", "<leader>g", function()
			if not shell_is_open() then
				return
			end
			global_search = not global_search
			if search_query ~= "" then
				do_search(search_query, global_search and nil or provider_project_ids())
			else
				shell_redraw()
			end
		end, { buffer = buf, nowait = true, desc = "Toggle global search" })

		vim.keymap.set("n", "<Esc>", function()
			if not shell_is_open() then
				return
			end
			if search_query ~= "" then
				search_query = ""
				results = nil
				shell_redraw()
			elseif global_search then
				global_search = false
				shell_redraw()
			end
		end, { buffer = buf, nowait = true, desc = "Clear search / exit global" })
	end

	shell_push({ render = render, install_keymaps = install_keymaps })
end

return M
