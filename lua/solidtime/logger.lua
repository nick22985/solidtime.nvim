local M = {}

-- FIXME: where should the path be?
local log_file = vim.fn.expand("~/.solidtime.log")
local config = require("solidtime.config")

M.levels = {
	INFO = "INFO",
	WARN = "WARN",
	ERROR = "ERROR",
	DEBUG = "DEBUG",
}

function M.log(level, message)
	if not config.get().enable_logging then
		return
	end

	local log_entry = string.format("[%s] %s: %s", os.date("%Y-%m-%d %H:%M:%S"), level, message)

	local f = io.open(log_file, "a")
	if f then
		f:write(log_entry .. "\n")
		f:close()
	else
		print("Failed to write to log file: " .. log_file)
	end

	if config.get().debug_mode or level == M.levels.ERROR then
		vim.notify(log_entry, vim.log.levels.INFO)
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
