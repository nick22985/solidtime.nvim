---@diagnostic disable: undefined-field
local eq = assert.are.same

describe("solidtime.config", function()
	local config

	before_each(function()
		package.loaded["solidtime"] = nil
		package.loaded["solidtime.config"] = nil
		package.loaded["solidtime.auth"] = nil
		package.loaded["solidtime.logger"] = nil
		package.loaded["solidtime.tracker"] = nil
		package.loaded["solidtime.buffer"] = nil
		package.loaded["solidtime.cache"] = nil
		package.loaded["solidtime.auth"] = {
			get_active_url = function()
				return nil
			end,
			get_api_key_for_url = function()
				return nil
			end,
		}
		config = require("solidtime.config")
	end)

	it("uses default api_url when no opts provided", function()
		config.setup({})
		eq("https://app.solidtime.io/api/v1", config.get().api_url)
	end)

	it("merges user-provided api_url", function()
		config.setup({ api_url = "https://my.instance.io/api/v1" })
		eq("https://my.instance.io/api/v1", config.get().api_url)
	end)

	it("uses default enable_logging when not provided", function()
		config.setup({})
		eq(true, config.get().enable_logging)
	end)

	it("overrides enable_logging", function()
		config.setup({ enable_logging = false })
		eq(false, config.get().enable_logging)
	end)

	it("uses default debug_mode = false", function()
		config.setup({})
		eq(false, config.get().debug_mode)
	end)

	it("overrides debug_mode", function()
		config.setup({ debug_mode = true })
		eq(true, config.get().debug_mode)
	end)

	it("does not mutate defaults table", function()
		local defaults_before = vim.deepcopy(config.defaults)
		config.setup({ api_url = "https://changed.io" })
		eq(defaults_before.api_url, config.defaults.api_url)
	end)
end)

describe("solidtime.cache", function()
	local cache

	before_each(function()
		package.loaded["solidtime.cache"] = nil
		package.loaded["solidtime.config"] = nil
		package.loaded["solidtime.logger"] = nil
		package.loaded["solidtime.logger"] = {
			debug = function() end,
			info = function() end,
			warn = function() end,
			error = function() end,
			log = function() end,
			init = function() end,
			levels = { INFO = "INFO", WARN = "WARN", ERROR = "ERROR", DEBUG = "DEBUG" },
		}
		cache = require("solidtime.cache")
		cache.clear_all_cache()
	end)

	it("returns nil for a missing key", function()
		eq(nil, cache.get_cached_data("missing", 60))
	end)

	it("stores and retrieves a value within TTL", function()
		cache.set_cached_data("key1", "hello", 60)
		eq("hello", cache.get_cached_data("key1", 60))
	end)

	it("returns nil after invalidation", function()
		cache.set_cached_data("key2", "world", 60)
		cache.invalidate_cache("key2")
		eq(nil, cache.get_cached_data("key2", 60))
	end)

	it("returns nil after clear_all_cache", function()
		cache.set_cached_data("k1", "v1", 60)
		cache.set_cached_data("k2", "v2", 60)
		cache.clear_all_cache()
		eq(nil, cache.get_cached_data("k1", 60))
		eq(nil, cache.get_cached_data("k2", 60))
	end)
end)

describe("solidtime.auth", function()
	local auth
	local tmp_file

	before_each(function()
		package.loaded["solidtime.auth"] = nil
		package.loaded["solidtime.config"] = nil
		tmp_file = os.tmpname()
		auth = require("solidtime.auth")
	end)

	after_each(function()
		os.remove(tmp_file)
	end)

	it("get_api_key_for_url returns nil when no file exists", function()
		eq(nil, auth.get_api_key_for_url("https://nonexistent.io/api/v1"))
	end)

	it("get_api_key_for_url returns nil for unknown URL", function()
		local f = io.open(tmp_file, "w")
		f:write("url=https://other.io/api/v1\nkey=abc123\n")
		f:close()
		eq(nil, auth.get_api_key_for_url("https://nothere.io/api/v1"))
	end)
end)

describe("solidtime.tracker (unit)", function()
	local tracker
	local tmp_dir

	before_each(function()
		tmp_dir = vim.fn.tempname()
		vim.fn.mkdir(tmp_dir, "p")

		package.loaded["solidtime.tracker"] = nil
		package.loaded["solidtime.api"] = nil
		package.loaded["solidtime.cache"] = nil
		package.loaded["solidtime.logger"] = {
			debug = function() end,
			info = function() end,
			warn = function() end,
			error = function() end,
			log = function() end,
			init = function() end,
			levels = { INFO = "INFO", WARN = "WARN", ERROR = "ERROR", DEBUG = "DEBUG" },
		}
		package.loaded["solidtime.config"] = {
			get = function()
				return {
					storage_dir = tmp_dir,
					api_url = "https://app.solidtime.io/api/v1",
					enable_logging = false,
					debug_mode = false,
				}
			end,
			setup = function() end,
			defaults = {},
			options = {},
		}
		package.loaded["solidtime.api"] = {
			fetch_user_data = function()
				return { data = {} }
			end,
			getUserTimeEntry = function()
				return { data = nil }
			end,
			createTimeEntry = function()
				return { data = { id = "fake-id" } }
			end,
			updateTimeEntry = function()
				return { data = {} }
			end,
			getUserMemberships = function()
				return { data = {} }
			end,
		}

		tracker = require("solidtime.tracker")
		tracker.init()
	end)

	after_each(function()
		if tracker then
			tracker.stop_tracking()
		end
		vim.fn.delete(tmp_dir, "rf")
	end)

	it("storage initialises with empty pending_sync", function()
		eq({}, tracker.storage.pending_sync)
	end)

	it("storage initialises with nil active_entry", function()
		eq(nil, tracker.storage.active_entry)
	end)

	it("storage initialises with nil current_information", function()
		eq(nil, tracker.storage.current_information)
	end)

	it("selectActiveOrganization creates current_information if nil", function()
		tracker.storage.current_information = nil
		tracker.selectActiveOrganization("org-1", "member-1")
		assert.is_not_nil(tracker.storage.current_information)
		eq("org-1", tracker.storage.current_information.organization_id)
		eq("member-1", tracker.storage.current_information.member_id)
		eq(nil, tracker.storage.current_information.project_id)
	end)

	it("selectActiveOrganization resets project_id on org change", function()
		tracker.storage.current_information = {
			organization_id = "old-org",
			member_id = "old-member",
			project_id = "old-proj",
		}
		tracker.selectActiveOrganization("new-org", "new-member")
		eq("new-org", tracker.storage.current_information.organization_id)
		eq("new-member", tracker.storage.current_information.member_id)
		eq(nil, tracker.storage.current_information.project_id)
	end)

	it("selectActiveProject sets project_id", function()
		tracker.storage.current_information = { organization_id = "org-1", member_id = "m-1" }
		tracker.selectActiveProject("proj-1")
		eq("proj-1", tracker.storage.current_information.project_id)
	end)

	it("selectActiveProject clears project_id on 'clear'", function()
		tracker.storage.current_information = { organization_id = "org-1", member_id = "m-1", project_id = "proj-1" }
		tracker.selectActiveProject("clear")
		eq(nil, tracker.storage.current_information.project_id)
	end)

	it("selectActiveProject does nothing when projectId is nil", function()
		tracker.storage.current_information = { organization_id = "org-1", member_id = "m-1", project_id = "proj-1" }
		tracker.selectActiveProject(nil)
		-- project_id should be unchanged
		eq("proj-1", tracker.storage.current_information.project_id)
	end)

	it("stop_tracking clears active_entry", function()
		tracker.storage.active_entry = { id = "entry-1", start = "2024-01-01T00:00:00Z" }
		tracker.stop_tracking()
		eq(nil, tracker.storage.active_entry)
	end)

	it("sync_pending does nothing when pending_sync is empty", function()
		tracker.storage.pending_sync = {}
		-- Should not error
		tracker.sync_pending()
		eq({}, tracker.storage.pending_sync)
	end)

	it("selectActiveTags sets tags in current_information", function()
		tracker.storage.current_information = { organization_id = "org-1", member_id = "m-1" }
		tracker.selectActiveTags({ "tag-1", "tag-2" })
		eq({ "tag-1", "tag-2" }, tracker.storage.current_information.tags)
	end)

	it("selectActiveTags accepts nil to clear tags", function()
		tracker.storage.current_information = { organization_id = "org-1", member_id = "m-1", tags = { "tag-1" } }
		tracker.selectActiveTags(nil)
		eq(nil, tracker.storage.current_information.tags)
	end)

	it("selectActiveTags creates current_information if nil", function()
		tracker.storage.current_information = nil
		tracker.selectActiveTags({ "tag-x" })
		assert.is_not_nil(tracker.storage.current_information)
		eq({ "tag-x" }, tracker.storage.current_information.tags)
	end)

	it("start() propagates tags into active_entry", function()
		tracker.storage.current_information = {
			organization_id = "org-1",
			member_id = "m-1",
			billable = false,
			tags = { "tag-a", "tag-b" },
		}
		-- api stub returns fake id
		tracker.start()
		assert.is_not_nil(tracker.storage.active_entry)
		eq({ "tag-a", "tag-b" }, tracker.storage.active_entry.tags)
	end)

	it("start() has nil tags when current_information has no tags", function()
		tracker.storage.current_information = {
			organization_id = "org-1",
			member_id = "m-1",
			billable = false,
		}
		tracker.start()
		eq(nil, tracker.storage.active_entry.tags)
	end)
end)
