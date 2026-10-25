-- JSON lines: each line is a value, and the keys of the objects are the columns.

local json = require("input.json")
local keys_of = require("input.keys")
local lines = require("input.lines")

local M = {}

function M.new(sink)
	local keys = keys_of.new(sink)
	local bad = 0
	return lines.splitter(sink, function(line)
		local value = json.parse(line)
		if value == nil then
			bad += 1
			-- Told once, then counted: a log with a line of text in it should not drown the view.
			if bad == 1 or bad % 1000 == 0 then
				sink.problem(bad == 1 and "A line is not JSON" or (bad .. " lines are not JSON"))
			end
			return
		end
		sink.record({ cells = keys.cells(value), raw = line, value = value })
	end)
end

return M
