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
---@field organization_id string|nil Organization ID associated with the entry
---@field project_id string|nil Project ID associated with the entry
---@field task_id string|nil Task ID associated with the entry
---@field description string Description of the time entry
---@field billable boolean Whether the entry is billable
---@field start string|osdate ISO8601 formatted start time
---@field start_timestamp number Unix timestamp for start time
---@field end string|osdate|nil ISO8601 formatted end time
---@field end_timestamp number|nil Unix timestamp for end time
---@field duration number|nil Duration in seconds
---@field current_duration number|nil Current duration for active entries
---@field tracking_type "local"|"online" Whether entry is tracked locally or online

---@class StorageData
---@field active_entry TimeEntry|nil Currently active time entry
---@field pending_sync TimeEntry[] Entries waiting to be synced
---@field current_infomation CurrentInfo |nil

---@class CurrentInfo
---@field organization_id string|nil ID of the organization
---@field project_id string|nil ID of the project
---@field task_id string|nil ID of the task
---@field billable boolean Whether the entry is billable

---@type StorageData
local storage = {
	current_infomation = nil,
	active_entry = nil,
	pending_sync = {},
}

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
		local result = api.fetch_user_data()
		if result and not result.error then
			online = result and not result.error
		end
	end)
	return online and config.get().use_solidtime
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
	config.defaults.use_solidtime = true
	config.defaults.always_track_locally = false
	config.defaults.sync_threshold = 1

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
	vim.fn.timer_start(60000, function()
		if storage.active_entry then
			save_storage()
		end
	end, { ["repeat"] = -1 })
end

return M
