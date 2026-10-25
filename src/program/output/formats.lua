-- How one cell, and one row, is written in each format the output converts to.

local json = require("input.json")
local space = require("output.space")

local M = {}

local find, gsub, concat = string.find, string.gsub, table.concat

-- A CSV cell: quoted when a reader would take it for more than one cell or lose the space at
-- its ends, the quotes in it doubled.
function M.csv_cell(cell)
	if find(cell, '[",\n\r]') or space.has_edge(cell) then
		return '"' .. gsub(cell, '"', '""') .. '"'
	end
	return cell
end

-- A TSV cell has no way to hold a tab or a line end, so each becomes a space.
function M.tsv_cell(cell)
	if find(cell, "[\t\n\r]") then
		return (gsub(cell, "[\t\n\r]", " "))
	end
	return cell
end

-- One line of `count` cells (without its line end), each written by `write`. `into` is a table
-- of the caller's that holds `count` places and is used again for the next row, so that a hundred
-- thousand rows do not make a hundred thousand tables.
function M.row(cells, count, write, separator, into)
	for at = 1, count do
		into[at] = write(cells[at] or "")
	end
	return concat(into, separator)
end

-- The keys of the JSON object a row becomes, one for each name: a name that comes twice is
-- one key, at its first place and with the value of its last column, as an object has it.
function M.keys(names)
	local keys, seen = {}, {}
	for at, name in ipairs(names) do
		local key = seen[name]
		if key then
			key.at = at
		else
			key = { name = name, at = at }
			seen[name] = key
			keys[#keys + 1] = key
		end
	end
	return keys
end

-- The row as the JSON value it is written as: the value it was read as (JSON in, JSON out, so
-- that a number stays a number), or an object of its cells under the column names.
function M.value(record, keys)
	if record.value ~= nil then
		return record.value
	end
	local pairs_of = {}
	for at, key in ipairs(keys) do
		pairs_of[at] = { key.name, record.cells[key.at] or "" }
	end
	return json.object(pairs_of)
end

return M
