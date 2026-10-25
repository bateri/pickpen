-- The query: what a person types above the rows, and what `--where` runs with no person. One
-- language and one reading of it, so that the command line the view shows chooses the rows the
-- view showed.
--
--   word            the row holds the word, in any column, in any case
--   !word           it does not
--   "two words"     quotes keep spaces in a word or a value
--   col=v           the column is v (a quantity compares as one: `size=1G`), `col=a|b` either
--   col!=v          it is not
--   col~v  col!~v   it holds v, or does not, in any case
--   col>v  col>=v  col<v  col<=v
--                   compared as quantities when both are one (`cpu>50`, `age<2h`, `size>1G`),
--                   otherwise as text
--   col=a..b        between a and b, both included
--
-- Every term must hold. A column is named as its heading is, in any case, or with only its
-- letters and digits (`cpu` for `%CPU`, `containerid` for `CONTAINER ID`). A name that is no
-- column's makes the whole term a word: `user=bob` searches lines for `user=bob`.
--
-- Columns are numbered from 1 and "no column" is nil. A term's `from` and `to` are the places of
-- its first and last byte in the source, so `source:sub(term.from, term.to)` is the term as it
-- was written.

local fold = require("query.fold")

local M = {}

local byte, find, sub = string.byte, string.find, string.sub
local space_at = fold.space_at

-- The operators, the longest first: where two begin at one place, `>=` is not `>` and `=`.
local OPERATORS = { ">=", "<=", "!=", "!~", "=", "~", ">", "<" }

-- Splits on spaces outside quotes; quotes are dropped from `text` and kept in `raw`. A quote
-- that is never closed holds the rest of the source.
local function tokenize(source)
	local tokens = {}
	local n, at = #source, 1
	while at <= n do
		while at <= n do
			local width = space_at(source, at)
			if width == 0 then
				break
			end
			at += width
		end
		if at > n then
			break
		end
		local from = at
		local pieces, run, quote = {}, at, nil
		while at <= n do
			local c = byte(source, at)
			if quote then
				if c == quote then
					pieces[#pieces + 1] = sub(source, run, at - 1)
					quote, run = nil, at + 1
				end
			elseif c == 34 or c == 39 then
				pieces[#pieces + 1] = sub(source, run, at - 1)
				quote, run = c, at + 1
			elseif (c <= 32 or c >= 128) and space_at(source, at) > 0 then
				break
			end
			at += 1
		end
		pieces[#pieces + 1] = sub(source, run, at - 1)
		tokens[#tokens + 1] = {
			text = table.concat(pieces),
			raw = sub(source, from, at - 1),
			from = from,
			to = at - 1,
		}
	end
	return tokens
end
M.tokenize = tokenize

-- Letters and digits only, in lower case: how a heading may be named.
function M.simple_name(name)
	return fold.alnum(fold.lower(name))
end

-- The column a name names, or nil: a heading in any case, else a heading with only its letters
-- and digits.
function M.column_named(columns, name)
	local lowered = fold.lower(name)
	for i = 1, #columns do
		if fold.lower(columns[i]) == lowered then
			return i
		end
	end
	local simple = fold.alnum(lowered)
	if simple == "" then
		return nil
	end
	for i = 1, #columns do
		if M.simple_name(columns[i]) == simple then
			return i
		end
	end
	return nil
end

-- Where the operator is in a raw token, outside quotes: the first, longest first. Gives its
-- place and the operator, or nil.
local function find_operator(raw)
	local quote
	for at = 1, #raw do
		local c = byte(raw, at)
		if quote then
			if c == quote then
				quote = nil
			end
		elseif c == 34 or c == 39 then
			quote = c
		elseif c == 62 or c == 60 or c == 33 or c == 61 or c == 126 then
			for i = 1, #OPERATORS do
				local op = OPERATORS[i]
				if sub(raw, at, at + #op - 1) == op then
					return at, op
				end
			end
		end
	end
	return nil
end

-- A piece of a token without its quotes.
local function unquote(raw)
	local texts = {}
	for i, token in ipairs(tokenize(raw)) do
		texts[i] = token.text
	end
	return table.concat(texts, " ")
end

-- `a..b` as two ends, or nil: an end is anything that does not begin or end with a dot, so
-- `1..5` and `a..b..c` (`a..b` and `c`) are ranges and `1...5` is the text it is. The ends hold
-- no line breaks, as a pattern's `.` does not.
local function range_of(value)
	local last = #value - 2
	for at = last, 2, -1 do
		if
			sub(value, at, at + 1) == ".."
			and byte(value, at - 1) ~= 46
			and byte(value, at + 2) ~= 46
			and not find(sub(value, 1, at - 2), "[\r\n]")
			and not find(sub(value, at + 3), "[\r\n]")
		then
			return { sub(value, 1, at - 1), sub(value, at + 2) }
		end
	end
	return nil
end

-- `a|b|c` as three, `a||b` as three with an empty one between, `` as one empty one.
local function alternatives(value)
	local values, from = {}, 1
	while true do
		local bar = find(value, "|", from, true)
		if bar == nil then
			values[#values + 1] = sub(value, from)
			return values
		end
		values[#values + 1] = sub(value, from, bar - 1)
		from = bar + 1
	end
end

-- The terms of a query, `{ terms = {...}, empty = bool }`. A term is
-- `{ kind = "text", text, negate, from, to }` (`text` in lower case) or
-- `{ kind = "field", column, op, values, range, from, to }`: `values` are each alternative of
-- `a|b` for `=` and `!=` and the one value otherwise, `range` is `{ low, high }` for `=` written
-- as `a..b`.
function M.parse(source, columns)
	local terms = {}
	for _, token in ipairs(tokenize(source)) do
		local raw = token.raw
		local at, op = find_operator(raw)
		local column
		if at and at > 1 then
			column = M.column_named(columns, unquote(sub(raw, 1, at - 1)))
		end
		if column then
			local value = unquote(sub(raw, at + #op))
			terms[#terms + 1] = {
				kind = "field",
				column = column,
				op = op,
				values = (op == "=" or op == "!=") and alternatives(value) or { value },
				range = op == "=" and range_of(value) or nil,
				from = token.from,
				to = token.to,
			}
		else
			local negate = byte(raw, 1) == 33 and #raw > 1
			local text = negate and unquote(sub(raw, 2)) or token.text
			if text ~= "" then
				terms[#terms + 1] = {
					kind = "text",
					text = fold.lower(text),
					negate = negate,
					from = token.from,
					to = token.to,
				}
			end
		end
	end
	return { terms = terms, empty = #terms == 0 }
end

-- The names a query compares that are no column's, each once and in the order they come: such
-- a term is looked for as a word, which is seldom what was meant, so the view marks it and
-- `--where` says so.
function M.unknown_names(source, columns)
	local names, seen = {}, {}
	for _, token in ipairs(tokenize(source)) do
		local at = find_operator(token.raw)
		if at and at > 1 then
			local name = unquote(sub(token.raw, 1, at - 1))
			if M.column_named(columns, name) == nil and not seen[name] then
				seen[name] = true
				names[#names + 1] = name
			end
		end
	end
	return names
end

-- A value as the query needs it written: quoted when it has a space, a quote or an operator.
function M.quote_value(value)
	if value ~= "" and not fold.has_space(value) and not find(value, "[\"'=!~<>|]") then
		return value
	end
	if find(value, '"', 1, true) then
		return "'" .. value .. "'"
	end
	return '"' .. value .. '"'
end

-- A column's name as the query needs it written.
function M.quote_name(name)
	return M.quote_value(name)
end

-- Every run of two or more spaces as one space.
local function squeeze(text)
	local pieces, kept = {}, 1
	local at, n = 1, #text
	while at <= n do
		local width = space_at(text, at)
		if width == 0 then
			at += 1
		else
			local stop, count = at + width, 1
			while stop <= n do
				local more = space_at(text, stop)
				if more == 0 then
					break
				end
				stop, count = stop + more, count + 1
			end
			if count >= 2 then
				pieces[#pieces + 1] = sub(text, kept, at - 1)
				pieces[#pieces + 1] = " "
				kept = stop
			end
			at = stop
		end
	end
	pieces[#pieces + 1] = sub(text, kept)
	return table.concat(pieces)
end

-- The query with the terms on one column replaced by `term` (or removed, for nil), which is how
-- the view's clicks write into what the person types. The first of the column's terms is the
-- place the new one takes; a column with none gets it at the end.
function M.with_term(source, columns, column, term)
	local parsed = M.parse(source, columns)
	local pieces = {}
	local at, placed = 1, false
	for _, t in ipairs(parsed.terms) do
		if t.kind == "field" and t.column == column then
			pieces[#pieces + 1] = sub(source, at, t.from - 1)
			if not placed and term ~= nil then
				pieces[#pieces + 1] = term
				placed = true
			end
			at = t.to + 1
		end
	end
	pieces[#pieces + 1] = sub(source, at)
	local out = fold.trim(squeeze(table.concat(pieces)))
	if not placed and term ~= nil then
		out = out == "" and term or (out .. " " .. term)
	end
	return out
end

return M
