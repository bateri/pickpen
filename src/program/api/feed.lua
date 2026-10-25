-- The topic the page listens to: the table and the list as they change (rows came in, the input
-- ended, marks moved). What it says is the summary the calls give, so the page keeps one kind of
-- picture of the table. A change is said a few times a second at most, however fast the rows
-- come.
--
-- This is api/'s: the files of api/ know the page, and input/, query/, output/ and state/ do not.

local pencere = require("pencere")
local summary = require("api.summary")

local M = {}

-- The least time between two tellings, seconds.
local INTERVAL = 0.04

function M.topics(session)
	local listening = {}
	local timer = nil
	local function say()
		timer = nil
		local now = summary.of(session)
		for subscription in pairs(listening) do
			subscription:push(now)
		end
	end
	session:listen(function()
		if next(listening) ~= nil and timer == nil then
			timer = pencere.time.after(INTERVAL, say)
		end
	end)
	return {
		rows = function(_, subscription)
			listening[subscription] = true
			subscription:on_end(function()
				listening[subscription] = nil
			end)
			subscription:push(summary.of(session))
		end,
	}
end

return M
