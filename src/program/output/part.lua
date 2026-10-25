-- A part of a row, by the name `--field`, `--format` and `--preview` give it: a column by its
-- heading, `2` the second column, and `` (as in `{}`) the row as it was read.

local query = require("query")
local space = require("output.space")

local M = {}

local function is_number(name)
	return string.find(name, "^%d+$") ~= nil
end

local function nothing()
	return nil
end

-- How the name reads a record: a function from a record to its part, or to nil when the name
-- names none. What a name means is settled here, once, for all the rows that share the columns
-- (`source` has `names` and `format`), because looking a heading up by its simple name for
-- every row of a hundred thousand would be most of the cost of writing them. In lines, which
-- have one column, `2` is the line's second word, as fzf and awk count: `git log --oneline |
-- pickpen --field 1` writes the hashes. A column whose heading is a number is that column,
-- which is why a heading is looked for before a place.
function M.reader(name, source)
	if name == "" then
		return function(record)
			return record.raw
		end
	end
	local at = query.column_named(source.names, name)
	if at then
		return function(record)
			return record.cells[at] or ""
		end
	end
	local place = is_number(name) and tonumber(name) or 0
	if place == 0 then
		return nothing
	end
	if source.format == "lines" then
		return function(record)
			return space.words(record.raw)[place] or ""
		end
	end
	return function(record)
		return record.cells[place] or ""
	end
end

-- The part of one record that `name` names, or nil when it names none.
function M.part_of(record, name, source)
	return M.reader(name, source)(record)
end

-- Whether `part_of` knows the name with these columns.
function M.knows(name, names)
	if name == "" or query.column_named(names, name) then
		return true
	end
	return is_number(name) and tonumber(name) > 0
end

return M
