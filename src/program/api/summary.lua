-- What the page is told of the table and the list in one piece: how many rows there are, how many
-- the query keeps, how many are marked, the columns with the width and kind each is shown by, and
-- how every term of the query was read. The page holds only the few rows in sight; this is what it
-- knows of the rest.

local query = require("query")

local M = {}

local WORDS = {
	["="] = "is",
	["!="] = "is not",
	["~"] = "holds",
	["!~"] = "does not hold",
	[">"] = "above",
	[">="] = "at least",
	["<"] = "below",
	["<="] = "at most",
}

-- How many characters a column is shown as wide as at most, and at least.
local WIDEST, NARROWEST = 60, 4

-- How a term was read, in words: `STATUS is not Running`, `has web`.
function M.label(term, names)
	if term.kind == "text" then
		return (term.negate and "has no " or "has ") .. term.text
	end
	local column = names[term.column] or "?"
	if term.range then
		return column .. " between " .. term.range[1] .. " and " .. term.range[2]
	end
	local values = table.concat(term.values, " or ")
	return column .. " " .. WORDS[term.op] .. " " .. values
end

-- The kind most of a column's first cells have: what the page aligns and charts by. Read again
-- only while the first rows are still coming.
local function kinds_of(session)
	local table_ = session.table
	local key = table_.columns_version * 1000 + math.min(#table_.rows, 500)
	if session.kinds_key == key then
		return session.kinds
	end
	local kinds = {}
	for column = 1, #table_.names do
		local cells = {}
		for at = 1, math.min(#table_.rows, 500) do
			cells[at] = table_.rows[at].cells[column] or ""
		end
		kinds[column] = query.column_kind(cells, 500)
	end
	session.kinds_key, session.kinds = key, kinds
	return kinds
end

-- The widths, in characters, the columns are first shown with: the longest of the heading and
-- the first rows, within bounds.
local function widths_of(table_)
	local widths = {}
	for column = 1, #table_.names do
		local longest = (table_.longest[column] or 0) + 2
		widths[column] = math.min(math.max(longest, NARROWEST), WIDEST)
	end
	return widths
end

function M.of(session)
	local table_, view = session.table, session.view
	local names = table_.names
	local terms = {}
	for _, entry in ipairs(view.terms) do
		terms[#terms + 1] = {
			label = M.label(entry.term, names),
			chip = entry.chip,
			source = entry.chip and entry.source or nil,
			-- A term that names a column that is not there is a word, which is seldom meant.
			word = entry.term.kind == "text" and entry.source:find("[=~<>]") ~= nil,
		}
	end
	local order = nil
	if view.order then
		order = { column = view.order.column, descending = view.order.descending }
	end
	return {
		gen = view.gen,
		total = #table_.rows,
		shown = #view.shown,
		marked = view.marked_count,
		hidden = view:hidden_marks(),
		columns = names,
		widths = widths_of(table_),
		kinds = kinds_of(session),
		format = table_.format,
		done = table_.done,
		capped = table_.capped,
		cut = table_.cut,
		problems = table_.problems,
		terms = terms,
		unknown = view.unknown or {},
		order = order,
		rule = view.rule_source,
	}
end

return M
