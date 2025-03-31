local logger = require("solidtime.logger")
local M = {}

local cache = {}

local function is_cache_expired(timestamp, ttl)
	logger.debug(string.format("Checking if cache is expired: timestamp = %d, ttl = %d", timestamp, ttl))
	return vim.fn.localtime() > (timestamp + ttl)
end

function M.get_cached_data(key, ttl)
	logger.debug(string.format("Attempting to get cached data for key: %s", key))

	local cache_data = cache[key]
	if cache_data then
		if is_cache_expired(cache_data.timestamp, ttl) then
			logger.debug(string.format("Cache expired for key: %s", key))
			cache[key] = nil
			return nil
		end
		logger.debug(string.format("Cache hit for key: %s", key))
		return cache_data.value
	end

	logger.debug(string.format("Cache miss for key: %s", key))
	return nil
end

function M.set_cached_data(key, value, ttl)
	logger.debug(string.format("Setting cache data for key: %s, ttl: %d", key, ttl))
	cache[key] = {
		value = value,
		timestamp = vim.fn.localtime(),
		ttl = ttl,
	}
	logger.debug(string.format("Cache data set successfully for key: %s", key))
end

function M.invalidate_cache(key)
	logger.debug(string.format("Invalidating cache for key: %s", key))
	cache[key] = nil
	logger.debug(string.format("Cache invalidated for key: %s", key))
end

function M.clear_all_cache()
	logger.debug("Clearing all cache")
	cache = {}
	logger.debug("All cache cleared")
end

return M
