---@diagnostic disable: undefined-field
local eq = assert.are.same
local solidtime = require("solidtime")
local config = require("solidtime.config")

describe("solidtime.setup", function()
	it("should setup plugin", function()
		solidtime.setup()
		eq(config.defaults, config.get())
	end)
	it("should merge config", function()
		solidtime.setup({
			api_url = "https://test.co",
		})

		local expectedConfig = config.get()
		expectedConfig.api_url = "https://test.co"
		eq(config.get(), expectedConfig)
	end)
end)
