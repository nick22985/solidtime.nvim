local config = require("solidtime.config")
local M = {}

M.levels = {
	INFO = "INFO",
	WARN = "WARN",
	ERROR = "ERROR",
	DEBUG = "DEBUG",
}

local log_file_path = "/.latest.solidtime.log"

function M.init()
	if not config.get().enable_logging then
		return
	end

	local log_file = config.get().storage_dir .. log_file_path
	local f = io.open(log_file, "w")
	if f then
		f:write("SolidTime Logger Initialized\n")
		f:close()
	else
		print("Failed to create log file: " .. log_file)
	end
end

local notifcationLevels = {
	[M.levels.INFO] = vim.log.levels.INFO,
	[M.levels.WARN] = vim.log.levels.WARN,
	[M.levels.ERROR] = vim.log.levels.ERROR,
	[M.levels.DEBUG] = vim.log.levels.DEBUG,
}

---@param level string Log level (INFO, WARN, ERROR, DEBUG)
---@param message string Message to log
---@param notify boolean Whether to notify the user (default: true)
function M.log(level, message, notify)
	if not config.get().enable_logging then
		return
	end
	if not M.levels[level] then
		print("Invalid log level: " .. level)
		return
	end
	-- default to true
	if notify == nil then
		notify = true
	end
	local log_file = config.get().storage_dir .. log_file_path

	local log_entry = string.format("[%s] %s: %s", os.date("%Y-%m-%d %H:%M:%S"), level, message)

	local f = io.open(log_file, "a")
	if f then
		f:write(log_entry .. "\n")
		f:close()
	else
		print("Failed to write to log file: " .. log_file)
	end

	if (config.get().debug_mode or level == M.levels.ERROR) and notify then
		vim.notify(log_entry, notifcationLevels[level], {
			title = "SolidTime Logger",
			timeout = 5000,
		})
	end
end

function M.info(msg, notify)
	M.log(M.levels.INFO, msg, notify)
end
function M.warn(msg, notify)
	M.log(M.levels.WARN, msg, notify)
end
function M.error(msg, notify)
	M.log(M.levels.ERROR, msg, notify)
end
function M.debug(msg, notify)
	M.log(M.levels.DEBUG, msg, notify)
end

return M
