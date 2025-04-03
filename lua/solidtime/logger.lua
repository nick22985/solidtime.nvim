local config = require("solidtime.config")
local M = {}

M.levels = {
	INFO = "INFO",
	WARN = "WARN",
	ERROR = "ERROR",
	DEBUG = "DEBUG",
}

function M.init()
	if not config.get().enable_logging then
		return
	end

	local log_file = config.get().storage_dir .. "/.solidtime.log"
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

function M.log(level, message)
	if not config.get().enable_logging then
		return
	end
	local log_file = config.get().storage_dir .. "/.solidtime.log"

	local log_entry = string.format("[%s] %s: %s", os.date("%Y-%m-%d %H:%M:%S"), level, message)

	local f = io.open(log_file, "a")
	if f then
		f:write(log_entry .. "\n")
		f:close()
	else
		print("Failed to write to log file: " .. log_file)
	end

	if config.get().debug_mode or level == M.levels.ERROR then
		vim.notify(log_entry, notifcationLevels[level], {
			title = "SolidTime Logger",
			timeout = 5000,
		})
	end
end

function M.info(msg)
	M.log(M.levels.INFO, msg)
end
function M.warn(msg)
	M.log(M.levels.WARN, msg)
end
function M.error(msg)
	M.log(M.levels.ERROR, msg)
end
function M.debug(msg)
	M.log(M.levels.DEBUG, msg)
end

return M
