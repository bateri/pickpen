-- CSV or TSV: the first record is the heading; quoted fields may hold line breaks, and a quote
-- inside a quoted field is written twice.
--
-- The text is read in runs between the few bytes that mean something (the delimiter, a quote, a
-- line end), never byte by byte, and a record may begin in one piece of the text and end in
-- another.

local columns = require("input.columns")
local plain = require("input.plain").plain
local text = require("input.text")

local M = {}

local byte, find, sub, concat = string.byte, string.find, string.sub, table.concat

function M.new(sink, delimiter)
	local special = '[\n\r"' .. delimiter .. "]"
	local quoted = false
	-- A quote just closed inside a quoted field: the next quote makes it a literal one.
	local closing = false
	local heading = true

	-- The field being read, as the pieces it came in, and how long it is so far.
	local field, pieces, length = {}, 0, 0
	local cells, count = {}, 0
	-- What the record has been in the pieces of text before this one.
	local before, held = {}, 0

	local function add(piece)
		if piece ~= "" then
			pieces += 1
			field[pieces] = piece
			length += #piece
		end
	end

	local function take()
		local value
		if pieces == 0 then
			value = ""
		elseif pieces == 1 then
			value = field[1]
			field[1] = nil
		else
			value = concat(field, "", 1, pieces)
			field = {}
		end
		pieces, length = 0, 0
		return value
	end

	-- A record is complete: `raw` is the text it was read from, without its line end.
	local function record(raw)
		if byte(raw, -1) == 13 then
			raw = sub(raw, 1, -2)
		end
		count += 1
		cells[count] = take()
		local mine, n = cells, count
		cells, count = {}, 0
		closing = false
		if find(raw, "\27", 1, true) then
			raw = plain(raw)
			for i = 1, n do
				mine[i] = plain(mine[i])
			end
		end
		if text.is_blank(raw) then
			return
		end
		if heading then
			heading = false
			sink.columns(columns.names_of(mine), raw)
		else
			sink.record({ cells = mine, raw = raw })
		end
	end

	local reader = {}

	function reader:feed(piece)
		local len = #piece
		local pos, from = 1, 1
		while pos <= len do
			if quoted then
				local quote = find(piece, '"', pos, true)
				if not quote then
					add(sub(piece, pos))
					pos = len + 1
					break
				end
				add(sub(piece, pos, quote - 1))
				quoted = false
				closing = true
				pos = quote + 1
			else
				local at = find(piece, special, pos)
				if not at then
					add(sub(piece, pos))
					closing = false
					pos = len + 1
					break
				end
				if at > pos then
					add(sub(piece, pos, at - 1))
					closing = false
				end
				local c = byte(piece, at)
				pos = at + 1
				if c == 10 then
					local raw = sub(piece, from, at - 1)
					if held > 0 then
						held += 1
						before[held] = raw
						raw = concat(before, "", 1, held)
						before, held = {}, 0
					end
					record(raw)
					from = pos
				elseif c == 34 then
					if closing then
						add('"')
						quoted = true
						closing = false
					elseif length == 0 then
						quoted = true
					else
						add('"')
					end
				elseif c == 13 then
					closing = false
				else
					closing = false
					count += 1
					cells[count] = take()
				end
			end
		end
		if from <= len then
			held += 1
			before[held] = from == 1 and piece or sub(piece, from)
		end
	end

	function reader:finish()
		local pending = concat(before, "", 1, held)
		before, held = {}, 0
		if not text.is_blank(pending) or count > 0 then
			record(pending)
		end
	end

	return reader
end

return M
