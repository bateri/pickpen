-- Whether a row holds to a query. A row is `{ cells = {...}, lower = text or nil }`: its cells,
-- and the text a word is looked for in (the cells joined by tabs, in lower case), which is made
-- the first time it is asked for and kept in the row.
--
-- `compile` turns a query into a function of a row, with everything a term needs of its values
-- (their quantities, their lower case) worked out once; that is the form for a loop over many
-- rows. `matches` and `holds` are the same for one.

local fold = require("query.fold")
local order = require("query.order")
local values = require("query.values")

local M = {}

local find = string.find
local scan = values.scan
local comparable_kinds = values.comparable_kinds
local compare_text = order.compare_text
local lower, trim = fold.lower, fold.trim

-- The text a row's words are looked for in, made if the row has none yet.
function M.row_lower(row)
	local text = row.lower
	if text == nil then
		text = lower(table.concat(row.cells, "\t"))
		row.lower = text
	end
	return text
end
local row_lower = M.row_lower

-- A word to look for: the row's text holds it, or (negated) does not.
local function word(term)
	local needle = term.text
	if term.negate then
		return function(row)
			return find(row.lower or row_lower(row), needle, 1, true) == nil
		end
	end
	return function(row)
		return find(row.lower or row_lower(row), needle, 1, true) ~= nil
	end
end

-- A value to compare a cell with, read once: its quantity if it is one, and its lower case.
local function bound(value)
	local kind, number = scan(value)
	return { kind = kind, number = number, text = value, lower = lower(value) }
end

-- `col=a|b` (or, negated, `col!=a|b`): the cell is one of the values. A cell and a value that
-- are quantities of one scale are equal when their numbers are; any other pair is equal when
-- the cell without its spaces is the value, in any case.
local function equals(term, negate)
	local column = term.column
	local alternatives = {}
	local reads_quantity = false
	for i, value in ipairs(term.values) do
		alternatives[i] = bound(value)
		reads_quantity = reads_quantity or alternatives[i].kind ~= nil
	end
	local count = #alternatives
	return function(row)
		local cell = row.cells[column] or ""
		local kind, number
		if reads_quantity then
			kind, number = scan(cell)
		end
		local text
		for i = 1, count do
			local alternative = alternatives[i]
			if kind and alternative.kind and comparable_kinds(kind, alternative.kind) then
				if number == alternative.number then
					return not negate
				end
			else
				if text == nil then
					text = lower(trim(cell))
				end
				if text == alternative.lower then
					return not negate
				end
			end
		end
		return negate
	end
end

-- How far a cell is above a value, as a number of the value's own measure: the difference of
-- their quantities, or how their texts go in order. Nil when there is no saying: a quantity
-- against a cell that is not one of its scale, or a text against an empty cell.
local function distance(cell, kind, number, to)
	if to.kind then
		if kind == nil or not comparable_kinds(kind, to.kind) then
			return nil
		end
		return number - to.number
	end
	local text = trim(cell)
	if text == "" then
		return nil
	end
	return compare_text(text, to.text)
end

-- `col=a..b`: the cell is neither below a nor above b.
local function between(term)
	local column = term.column
	local low, high = bound(term.range[1]), bound(term.range[2])
	local reads_quantity = low.kind ~= nil or high.kind ~= nil
	return function(row)
		local cell = row.cells[column] or ""
		local kind, number
		if reads_quantity then
			kind, number = scan(cell)
		end
		local below = distance(cell, kind, number, low)
		local above = distance(cell, kind, number, high)
		return below ~= nil and above ~= nil and below >= 0 and above <= 0
	end
end

-- `col>v`, `col>=v`, `col<v`, `col<=v`.
local function compares(term)
	local column, op = term.column, term.op
	local to = bound(term.values[1])
	local reads_quantity = to.kind ~= nil
	return function(row)
		local cell = row.cells[column] or ""
		local kind, number
		if reads_quantity then
			kind, number = scan(cell)
		end
		local d = distance(cell, kind, number, to)
		if d == nil then
			return false
		end
		if op == ">" then
			return d > 0
		elseif op == ">=" then
			return d >= 0
		elseif op == "<" then
			return d < 0
		end
		return d <= 0
	end
end

-- `col~v` and `col!~v`: the cell holds v, in any case, or (negated) does not.
local function holds_text(term, negate)
	local column = term.column
	local needle = lower(term.values[1])
	return function(row)
		local found = find(lower(row.cells[column] or ""), needle, 1, true) ~= nil
		return found ~= negate
	end
end

-- A term as a function of a row.
function M.compile_term(term)
	if term.kind == "text" then
		return word(term)
	end
	local op = term.op
	if op == "=" then
		if term.range then
			return between(term)
		end
		return equals(term, false)
	elseif op == "!=" then
		return equals(term, true)
	elseif op == "~" then
		return holds_text(term, false)
	elseif op == "!~" then
		return holds_text(term, true)
	end
	return compares(term)
end

-- A query as a function of a row: every term must hold.
function M.compile(query)
	local terms = {}
	for i, term in ipairs(query.terms) do
		terms[i] = M.compile_term(term)
	end
	local count = #terms
	if count == 0 then
		return function()
			return true
		end
	elseif count == 1 then
		return terms[1]
	elseif count == 2 then
		local first, second = terms[1], terms[2]
		return function(row)
			return first(row) and second(row)
		end
	end
	return function(row)
		for i = 1, count do
			if not terms[i](row) then
				return false
			end
		end
		return true
	end
end

-- Whether one term holds for a row.
function M.holds(term, row)
	return M.compile_term(term)(row)
end

-- Whether a row holds to the query. Anything that asks it of many rows compiles the query once.
function M.matches(query, row)
	return M.compile(query)(row)
end

return M
