-- The columns of JSON values: the keys of their objects, in the order they were first seen. A
-- value that is no object is a cell of the column `value`.

local json = require("input.json")

local M = {}

local Object = json.Object
local text_of = json.text_of

local VALUE = { "value" }

-- Keys that tell `sink` the columns whenever a value brings one not seen before.
function M.new(sink)
	local names, at, count = {}, {}, 0

	local function add(list)
		local added = false
		for i = 1, #list do
			local key = list[i]
			if not at[key] then
				count += 1
				at[key] = count
				names[count] = key
				added = true
			end
		end
		if added then
			sink.columns(table.move(names, 1, count, 1, {}))
		end
	end

	local keys = { names = names }

	-- The cells of a value (the columns it brings told to the sink first). A column the value
	-- has nothing for is an empty cell, as is one it has `null` for.
	function keys.cells(value)
		local cells = {}
		if getmetatable(value) ~= Object then
			add(VALUE)
			local place = at.value
			for i = 1, place - 1 do
				cells[i] = ""
			end
			cells[place] = text_of(value)
			return cells
		end
		local list, map = value.keys, value.map
		add(list)
		local last = 0
		for i = 1, #list do
			local key = list[i]
			local item = map[key]
			local place = at[key]
			cells[place] = type(item) == "string" and item or text_of(item)
			if place > last then
				last = place
			end
		end
		for i = 1, last do
			if cells[i] == nil then
				cells[i] = ""
			end
		end
		return cells
	end

	return keys
end

return M
