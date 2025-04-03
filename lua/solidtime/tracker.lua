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
---@field start string|osdate ISO8601 formatted start time
---@field start_timestamp number Unix timestamp for start time
---@field end string|osdate|nil ISO8601 formatted end time
---@field end_timestamp number|nil Unix timestamp for end time
---@field tracking_type "local"|"online" Whether entry is tracked locally or online

---@class StorageData
---@field active_entry TimeEntry|nil Currently active time entry
---@field pending_sync TimeEntry[] Entries waiting to be synced
---@field current_infomation CurrentInfo |nil

---@class CurrentInfo
---@field member_id string ID of the member
---@field organization_id string ID of the organization
---@field project_id string|nil ID of the project
---@field task_id string|nil ID of the task
---@field billable boolean Whether the entry is billable
---@field description string|nil Description of the time entry

---@type StorageData
local storage = {
	current_infomation = nil,
	active_entry = nil,
	pending_sync = {},
}

local timer = nil

---@type string
local storage_dir = nil

local function ensure_storage_dir()
	if not vim.loop.fs_stat(storage_dir) then
		vim.fn.mkdir(storage_dir, "p")
		logger.info("Created local storage directory: " .. storage_dir)
	end
end

---@type string
local storage_file = nil

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

local function save_storage()
	---@type file*|nil
	local f = io.open(storage_file, "w")
	if f then
		f:write(vim.fn.json_encode(storage))
		f:close()
		logger.debug("Local storage saved to " .. storage_file)
	else
		logger.error("Failed to save local storage to " .. storage_file)
	end
end

-- Load storage from file
local function load_storage()
	---@type file*|nil
	local f = io.open(storage_file, "r")
	if f then
		---@type string|nil
		local content = f:read("*all")
		f:close()
		if content and content ~= "" then
			---@type StorageData|nil
			local decoded = vim.fn.json_decode(content)
			if decoded then
				storage = decoded
				logger.debug("Local storage loaded from " .. storage_file)
			end
		end
	else
		logger.debug("No local storage file found at " .. storage_file)
	end
end

function M.init()
	storage_dir = config.get().storage_dir
	storage_file = storage_dir .. "/solidtime_storage.json"

	if not storage_dir then
		logger.error("Storage directory not set. Please configure it in your solidtime setup.")
		return
	end

	ensure_storage_dir()
	load_storage()

	if storage.active_entry then
		---@type number
		local now = os.time()
		---@type number
		local start_time = storage.active_entry.start_timestamp
		---@type number
		local duration = now - start_time

		-- FIXME: add config for this maybe? also send somthing via vim.notify instead of stoppng
		if duration > 24 * 60 * 60 then
			logger.warn("Found a time entry running for more than 24 hours. Stopping it now.")
			M.stop_tracking()
		else
			logger.info("Restored active time entry: " .. (storage.active_entry.description or "No description"))
		end
	end

	-- auto save every 60 seconds
	timer = vim.fn.timer_start(60000, function()
		if storage.active_entry then
			save_storage()
		end
	end, { ["repeat"] = -1 })
end

function M.stop_tracking()
	if timer then
		vim.fn.timer_stop(timer)
		timer = nil
	end
	if storage.active_entry then
		storage.active_entry = nil
		save_storage()
	end
end

local testCurrentConfig = {
	organization_id = "522bc964-e5be-48ed-a7ec-ffd1ae0a5ec6",
	member_id = "87c29bbc-3578-412a-a424-e4dceaea0078",
}

function M.start()
	local now = os.time()

	-- FIXME: use online config here somehow
	storage.current_infomation = testCurrentConfig
	local current_infomation = storage.current_infomation
	if not current_infomation then
		logger.error("No current information found. Please set it before starting a time entry.")
		vim.notify("No current information found. Please set it before starting a time entry.", vim.log.levels.ERROR)
		-- search online to see if there is a active entry
		local result = api.getUserTimeEntry()
		if result and result.error then
			logger.error("Failed to get user time entry: " .. result.error)
			return
		end

		return
	end
	local description = current_infomation.description or nil
	local billable = current_infomation.billable or false
	local organization_id = current_infomation.organization_id
	local project_id = current_infomation.project_id
	local member_id = current_infomation.member_id
	local isOnline = is_online()
	if isOnline then
		local result = api.getUserTimeEntry()
		if result and result.data then
			if storage.active_entry and storage.active_entry.id == result.data.id then
				logger.error("You already have an active time entry")
				return
			else
				storage.active_entry = result.data
				storage.active_entry.tracking_type = "online"

				logger.info("You already have an active time entry running online. Setting as active time entry")
				return
			end
		end
	else
		if storage.active_entry then
			logger.error("You already have an active time entry. Please stop it before starting a new one.")
			return
		end
	end

	storage.active_entry = {
		start = format_iso8601(now),
		start_timestamp = now,
		tracking_type = isOnline and "online" or "local",
		organization_id = organization_id,
		project_id = project_id,
		member_id = member_id,
		description = description,
		billable = billable,
	}

	if isOnline then
		local result = api.createTimeEntry(organization_id, {
			start = storage.active_entry.start,
			project_id = project_id,
			description = description,
			billable = billable,
			member_id = current_infomation.member_id,
		})
		if result and result.error then
			logger.error("Failed to start time entry: " .. result.error)
			storage.active_entry = nil
			return
		end
		if result == nil then
			logger.error("Failed to start time entry no data")
			storage.active_entry = nil
			return
		end

		storage.active_entry.id = result.data.id
		vim.notify(
			"Started time entry: " .. (storage.active_entry.description or "No description"),
			vim.log.levels.INFO
		)
		save_storage()
	end
end

function M.stop()
	local now = os.time()
	if storage.active_entry == nil then
		local result = api.getUserTimeEntry()

		if result and result.data then
			storage.active_entry = result.data
			storage.active_entry.tracking_type = "online"
		else
			vim.notify("No active time entry to stop.", vim.log.levels.ERROR)
			return
		end
	end

	storage.active_entry["end"] = format_iso8601(now)
	storage.active_entry.end_timestamp = now

	local isOnline = is_online()
	if isOnline then
		-- check if any values are nil
		if not storage.active_entry.organization_id or not storage.active_entry.id then
			logger.error("No active time entry to stop.")
			return
		end
		local result = api.updateTimeEntry(storage.active_entry.organization_id, storage.active_entry.id, {
			member_id = storage.active_entry.member_id,
			project_id = storage.active_entry.project_id,
			start = storage.active_entry.start,
			["end"] = storage.active_entry["end"],
			billable = storage.active_entry.billable,
			description = storage.active_entry.description,
		})
		if result and result.error then
			logger.error("Failed to stop time entry: " .. result.error)
			storage.active_entry = nil
			return
		end
		if result == nil then
			logger.error("Failed to stop time entry no data")
			return
		end
	else
		table.insert(storage.pending_sync, storage.active_entry)
		logger.info("Stopped time entry: " .. (storage.active_entry.description or "No description"))
	end

	local message = string.format(
		"%s Stopped time entry: %s",
		isOnline and "Online" or "Offline",
		(storage.active_entry.description and storage.active_entry.description ~= "")
				and storage.active_entry.description
			or "No description"
	)

	vim.notify(message, vim.log.levels.INFO)

	storage.active_entry = nil
	save_storage()
end

return M
