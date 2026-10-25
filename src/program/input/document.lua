-- One JSON document, read whole: an array is its elements, `{"items": [...]}` its items.

local json = require("input.json")
local keys_of = require("input.keys")

local M = {}

local is_array, is_object = json.is_array, json.is_object

-- The one array of objects an object holds, as an API's answer holds its rows; else nil.
function M.rows_inside(object)
	local found
	for _, key in ipairs(object.keys) do
		local item = object.map[key]
		if is_array(item) and item.n > 0 then
			local rows = true
			for i = 1, item.n do
				if not is_object(item[i]) then
					rows = false
					break
				end
			end
			if rows then
				if found then
					return nil
				end
				found = item
			end
		end
	end
	return found
end

-- The rows of a document: an array's elements, the one array of objects an object holds, or
-- itself. A list with its count in `n`.
function M.elements_of(value)
	if is_array(value) then
		return value
	end
	if is_object(value) then
		return M.rows_inside(value) or { n = 1, value }
	end
	return { n = 1, value }
end

function M.new(sink)
	local pieces, count = {}, 0
	local reader = {}

	function reader:feed(piece)
		count += 1
		pieces[count] = piece
	end

	function reader:finish()
		local value = json.parse(table.concat(pieces, "", 1, count))
		pieces, count = {}, 0
		if value == nil then
			sink.problem("The input is not one JSON document")
			return
		end
		local keys = keys_of.new(sink)
		local items = M.elements_of(value)
		for i = 1, items.n do
			local item = items[i]
			sink.record({ cells = keys.cells(item), raw = json.encode(item), value = item })
		end
		if #keys.names == 0 then
			sink.columns({ "value" })
		end
	end

	return reader
end

return M
