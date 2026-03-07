local api = require("solidtime.api")
local config = require("solidtime.config")
local logger = require("solidtime.logger")

local M = {}

-- Local storage for time entries
-- Structure:
-- {
--   active_entry = { ... } or nil,
--   pending_sync = { ... list of entries to sync ... },
-- }

---@class TimeEntry
---@field id string|nil ID of the time entry
---@field member_id string|nil Member ID associated with the entry
---@field organization_id string|nil Organization ID associated with the entry
---@field project_id string|nil Project ID associated with the entry
---@field task_id string|nil Task ID associated with the entry
---@field description string|nil Description of the time entry
---@field billable boolean|nil Whether the entry is billable
---@field tags string[]|nil Array of tag IDs
---@field start string|osdate ISO8601 formatted start time
---@field start_timestamp number Unix timestamp for start time
---@field end string|osdate|nil ISO8601 formatted end time
---@field end_timestamp number|nil Unix timestamp for end time
---@field tracking_type "local"|"online" Whether entry is tracked locally or online

---@class StorageData
---@field active_entry TimeEntry|nil Currently active time entry
---@field pending_sync TimeEntry[] Entries waiting to be synced
---@field current_information CurrentInfo|nil

---@class CurrentInfo
---@field member_id string ID of the member
---@field organization_id string ID of the organization
---@field project_id string|nil ID of the project
---@field task_id string|nil ID of the task
---@field billable boolean Whether the entry is billable
---@field description string|nil Description of the time entry
---@field tags string[]|nil Array of tag IDs

---@type StorageData
M.storage = {
	current_information = nil,
	active_entry = nil,
	pending_sync = {},
}

local timer = nil

---@type string
local storage_dir = nil

local function ensure_storage_dir()
	local uv = vim.uv or vim.loop
	if not uv.fs_stat(storage_dir) then
		vim.fn.mkdir(storage_dir, "p")
		logger.info("Created local storage directory: " .. storage_dir)
	end
end

---@type string  per-pid file: active_entry + pending_sync
local storage_file = nil

---@type string  shared file: current_information (org/member/project selection)
local current_file = nil

function M.get_storage()
	return M.storage
end

local function save_storage()
	local f = io.open(storage_file, "w")
	if f then
		f:write(vim.fn.json_encode({
			active_entry = M.storage.active_entry,
			pending_sync = M.storage.pending_sync,
		}))
		f:close()
		logger.debug("Local storage saved to " .. storage_file)
	else
		logger.error("Failed to save local storage to " .. storage_file)
	end
end

local function save_current()
	if not current_file then
		return
	end
	local f = io.open(current_file, "w")
	if f then
		f:write(vim.fn.json_encode({ current_information = M.storage.current_information }))
		f:close()
		logger.debug("Current information saved to " .. current_file)
	else
		logger.error("Failed to save current information to " .. current_file)
	end
end

local function load_storage()
	local f = io.open(storage_file, "r")
	if f then
		local content = f:read("*all")
		f:close()
		if content and content ~= "" then
			local ok, decoded = pcall(vim.fn.json_decode, content)
			if ok and decoded then
				M.storage.active_entry = decoded.active_entry
				M.storage.pending_sync = decoded.pending_sync or {}
				logger.debug("Local storage loaded from " .. storage_file)
			end
		end
	else
		logger.debug("No local storage file found at " .. storage_file)
	end

	if current_file then
		local cf = io.open(current_file, "r")
		if cf then
			local content = cf:read("*all")
			cf:close()
			if content and content ~= "" then
				local ok, decoded = pcall(vim.fn.json_decode, content)
				if ok and decoded and decoded.current_information then
					M.storage.current_information = decoded.current_information
					logger.debug("Current information loaded from " .. current_file)
				end
			end
		end
	end
end

local function is_online()
	local online = false
	pcall(function()
		local result = api.fetch_user_data(nil, { ttl = 0 })
		if result and not result.error then
			online = result and not result.error
		end
	end)
	return online
end

-- Format timestamp to ISO8601
---@param timestamp number Unix timestamp
---@return string|osdate formatted timestamp
local function format_iso8601(timestamp)
	local date = os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp)
	return date
end

function M.init()
	storage_dir = config.get().storage_dir

	if not storage_dir then
		logger.error("Storage directory not set. Please configure it in your solidtime setup.")
		return
	end

	-- Each nvim instance gets its own storage file keyed by PID so multiple
	-- instances don't clobber each other's active_entry.
	local pid = vim.fn.getpid()
	storage_file = storage_dir .. "/solidtime_storage_" .. pid .. ".json"
	current_file = storage_dir .. "/solidtime_current.json"

	local uv = vim.uv or vim.loop
	local handle = uv.fs_opendir(storage_dir, nil, 100)
	if handle then
		local entries = uv.fs_readdir(handle)
		uv.fs_closedir(handle)
		if entries then
			for _, entry in ipairs(entries) do
				local m = entry.name:match("^solidtime_storage_(%d+)%.json$")
				if m then
					local epid = tonumber(m)
					if epid ~= pid then
						local _, err = uv.kill(epid, 0)
						if err then
							pcall(os.remove, storage_dir .. "/" .. entry.name)
						end
					end
				end
			end
		end
	end

	ensure_storage_dir()
	load_storage()

	if M.storage.active_entry then
		local now = os.time()
		local start_time = M.storage.active_entry.start_timestamp

		if not start_time then
			logger.warn("Discarding active entry with missing start_timestamp.")
			M.storage.active_entry = nil
			save_storage()
		elseif now - start_time > 24 * 60 * 60 then
			logger.warn("Found a time entry running for more than 24 hours. Stopping it now.")
			M.stop_tracking()
		else
			logger.info("Restored active time entry: " .. (M.storage.active_entry.description or "No description"))
		end
	end

	timer = vim.fn.timer_start(60000, function()
		if M.storage.active_entry then
			save_storage()
		end
	end, { ["repeat"] = -1 })

	if #M.storage.pending_sync > 0 then
		vim.schedule(function()
			M.sync_pending()
		end)
	end

	vim.api.nvim_create_autocmd("VimLeavePre", {
		once = true,
		callback = function()
			if storage_file then
				pcall(os.remove, storage_file)
			end
		end,
	})
end

function M.stop_tracking()
	if timer then
		vim.fn.timer_stop(timer)
		timer = nil
	end
	if M.storage.active_entry then
		M.storage.active_entry = nil
		save_storage()
	end
end

--- Clear the active entry from local state only — no API call.
--- Used by IPC so peer instances don't make duplicate API requests.
function M.clear_active_entry()
	if M.storage.active_entry then
		M.storage.active_entry = nil
		save_storage()
	end
end

--- Attempts to sync all pending offline entries to the API.
--- Entries that succeed are removed from the queue; failures stay for the next attempt.
function M.sync_pending()
	if #M.storage.pending_sync == 0 then
		return
	end

	if not is_online() then
		logger.info("Offline — skipping pending sync.")
		return
	end

	logger.info(string.format("Syncing %d pending offline entries...", #M.storage.pending_sync))

	local remaining = {}
	for _, entry in ipairs(M.storage.pending_sync) do
		if not entry.organization_id or not entry.member_id then
			logger.warn("Skipping pending entry with missing organization_id or member_id")
		else
			if not entry.id then
				local result = api.createTimeEntry(entry.organization_id, {
					start = entry.start,
					["end"] = entry["end"],
					project_id = entry.project_id,
					description = entry.description,
					billable = entry.billable,
					member_id = entry.member_id,
					tags = entry.tags,
				})
				if result and result.error then
					logger.error("Failed to sync pending entry (create): " .. result.error)
					table.insert(remaining, entry)
				elseif result == nil or result.data == nil then
					logger.error("Failed to sync pending entry: no data returned")
					table.insert(remaining, entry)
				else
					logger.info("Synced offline entry: " .. (entry.description or "No description"))
				end
			else
				local result = api.updateTimeEntry(entry.organization_id, entry.id, {
					member_id = entry.member_id,
					project_id = entry.project_id,
					start = entry.start,
					["end"] = entry["end"],
					billable = entry.billable,
					description = entry.description,
					tags = entry.tags,
				})
				if result and result.error then
					logger.error("Failed to sync pending entry (update): " .. result.error)
					table.insert(remaining, entry)
				else
					logger.info("Synced offline entry (update): " .. (entry.description or "No description"))
				end
			end
		end
	end

	M.storage.pending_sync = remaining
	save_storage()

	local synced = #M.storage.pending_sync == 0
	if synced then
		vim.notify("All offline entries synced.", vim.log.levels.INFO)
	else
		vim.notify(
			string.format("%d offline entries could not be synced and will be retried.", #remaining),
			vim.log.levels.WARN
		)
	end
end

function M.start()
	local now = os.time()

	local current_information = M.storage.current_information

	if not current_information then
		logger.error("No current information found. Please set it before starting a time entry.")
		vim.notify("No current information found. Please set it before starting a time entry.", vim.log.levels.ERROR)
		local result = api.getUserTimeEntry()
		if result and result.error then
			logger.error("Failed to get user time entry: " .. result.error)
			return
		end

		return
	end
	local description = current_information.description or nil
	local billable = current_information.billable or false
	local organization_id = current_information.organization_id
	local project_id = current_information.project_id
	local task_id = current_information.task_id or nil
	local member_id = current_information.member_id
	local tags = current_information.tags or nil
	local isOnline = is_online()
	if isOnline then
		local result = api.getUserTimeEntry()
		if result and result.data then
			if result.data.project_id == project_id and result.data.description == (description or vim.NIL) then
				M.storage.active_entry = result.data
				M.storage.active_entry.tracking_type = "online"
				save_storage()
				return
			end
			local org_id = result.data.organization_id or organization_id
			api.updateTimeEntry(org_id, result.data.id, {
				member_id = result.data.member_id or member_id,
				project_id = result.data.project_id,
				start = result.data.start,
				["end"] = format_iso8601(os.time()),
				billable = result.data.billable,
				description = result.data.description,
				tags = result.data.tags,
			})
		end
	else
		if M.storage.active_entry then
			vim.notify("Already tracking — stop the current entry first.", vim.log.levels.WARN)
			return
		end
	end

	M.storage.active_entry = {
		start = format_iso8601(now),
		start_timestamp = now,
		tracking_type = isOnline and "online" or "local",
		organization_id = organization_id,
		project_id = project_id,
		task_id = task_id,
		member_id = member_id,
		description = description,
		billable = billable,
		tags = tags,
	}

	if isOnline then
		local result = api.createTimeEntry(organization_id, {
			start = M.storage.active_entry.start,
			project_id = project_id,
			task_id = task_id,
			description = description,
			billable = billable,
			member_id = current_information.member_id,
			tags = tags,
		})
		if result and result.error then
			logger.error("Failed to start time entry: " .. result.error)
			M.storage.active_entry = nil
			return
		end
		if result == nil or result.data == nil then
			logger.error("Failed to start time entry: no data returned")
			M.storage.active_entry = nil
			return
		end

		M.storage.active_entry.id = result.data.id
		vim.notify(
			"Started time entry: " .. (M.storage.active_entry.description or "No description"),
			vim.log.levels.INFO
		)
		save_storage()
		require("solidtime.autotrack").resume()
	else
		vim.notify(
			"Started time entry (offline): " .. (M.storage.active_entry.description or "No description"),
			vim.log.levels.INFO
		)
		save_storage()
		require("solidtime.autotrack").resume()
	end
end

function M.stop(opts)
	opts = opts or {}
	-- By default a manual stop pauses auto-tracking until the user starts again.
	-- Internal callers (idle-stop) pass { pause_autotrack = false } to skip this.
	local pause_autotrack = opts.pause_autotrack ~= false
	local now = os.time()
	if M.storage.active_entry == nil then
		local result = api.getUserTimeEntry()

		if result and result.data then
			M.storage.active_entry = result.data
			M.storage.active_entry.tracking_type = "online"
		else
			vim.notify("No active time entry to stop.", vim.log.levels.ERROR)
			return
		end
	end

	M.storage.active_entry["end"] = format_iso8601(now)
	M.storage.active_entry.end_timestamp = now

	local isOnline = is_online()
	if isOnline then
		if #M.storage.pending_sync > 0 then
			M.sync_pending()
		end
		if not M.storage.active_entry.organization_id or not M.storage.active_entry.id then
			logger.error("No active time entry to stop.")
			return
		end
		local result = api.updateTimeEntry(M.storage.active_entry.organization_id, M.storage.active_entry.id, {
			member_id = M.storage.active_entry.member_id,
			project_id = M.storage.active_entry.project_id,
			task_id = M.storage.active_entry.task_id,
			start = M.storage.active_entry.start,
			["end"] = M.storage.active_entry["end"],
			billable = M.storage.active_entry.billable,
			description = M.storage.active_entry.description,
			tags = M.storage.active_entry.tags,
		})
		if result and result.error then
			logger.error("Failed to stop time entry: " .. result.error)
			table.insert(M.storage.pending_sync, M.storage.active_entry)
			M.storage.active_entry = nil
			save_storage()
			return
		end
		if result == nil then
			logger.error("Failed to stop time entry no data")
			return
		end
	else
		table.insert(M.storage.pending_sync, M.storage.active_entry)
		logger.info("Stopped time entry: " .. (M.storage.active_entry.description or "No description"))
	end

	local message = string.format(
		"%s Stopped time entry: %s",
		isOnline and "Online" or "Offline",
		(M.storage.active_entry.description and M.storage.active_entry.description ~= "")
				and M.storage.active_entry.description
			or "No description"
	)

	vim.notify(message, vim.log.levels.INFO)

	M.storage.active_entry = nil
	save_storage()

	if pause_autotrack then
		local autotrack = require("solidtime.autotrack")
		autotrack.pause()
	end
end

---@param organizationId string|nil Organization ID
---@param memberId string|nil Member ID
---@return nil
M.selectActiveOrganization = function(organizationId, memberId)
	if organizationId == nil then
		logger.error("No organization id provided")
		return
	end
	if memberId == nil then
		logger.error("No member id provided")
		return
	end

	if not M.storage.current_information then
		M.storage.current_information = {}
	end

	M.storage.current_information.organization_id = organizationId
	M.storage.current_information.member_id = memberId
	M.storage.current_information.project_id = nil

	save_current()
end

---@param tagIds string[]|nil Array of tag IDs to set as active tags
M.selectActiveTags = function(tagIds)
	if not M.storage.current_information then
		M.storage.current_information = {}
	end
	M.storage.current_information.tags = tagIds
	save_current()
end

M.selectActiveProject = function(projectId)
	if projectId == nil then
		logger.error("No project id provided")
		return
	end

	if not M.storage.current_information then
		M.storage.current_information = {}
	end

	if projectId == "clear" then
		M.storage.current_information.project_id = nil
		save_current()
		return
	end

	M.storage.current_information.project_id = projectId

	save_current()
end

return M
