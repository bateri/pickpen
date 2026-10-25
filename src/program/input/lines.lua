-- Whole lines, plain, without their endings; blank lines are skipped. The first shape (a line is
-- a record) and the ground the others stand on: a table, JSON lines and the rest read what a
-- line holds, and this gives them the lines however the text was cut into pieces.
--
-- A reader of a shape is made with `new(sink)` and has `:feed(text)` for a piece of the text as it
-- comes, and `:finish()` at its end.

local plain = require("input.plain").plain
local text = require("input.text")

local M = {}

local byte, find, sub, concat = string.byte, string.find, string.sub, table.concat
local is_blank = text.is_blank

-- A reader that calls `on_line(line)` for each line, and tells the sink the columns `names` (if
-- given) before the first. A line that is cut between two pieces is held until the rest of it
-- comes, as a list of pieces so that one very long line does not copy itself at each piece.
function M.splitter(sink, on_line, names)
	local started = false
	local held, count = {}, 0

	local function start()
		if not started then
			started = true
			if names then
				sink.columns(names)
			end
		end
	end

	local function one(line)
		if byte(line, -1) == 13 then
			line = sub(line, 1, -2)
		end
		-- The common line has neither a code nor anything but ASCII to ask about.
		if find(line, "\27", 1, true) then
			line = plain(line)
		end
		local at = find(line, "%S")
		if at and (byte(line, at) < 0x80 or not is_blank(line)) then
			on_line(line)
		end
	end

	local reader = {}

	function reader:feed(piece)
		start()
		local pos = 1
		while true do
			local stop = find(piece, "\n", pos, true)
			if not stop then
				break
			end
			local line = sub(piece, pos, stop - 1)
			if count > 0 then
				count += 1
				held[count] = line
				line = concat(held, "", 1, count)
				held, count = {}, 0
			end
			one(line)
			pos = stop + 1
		end
		if pos <= #piece then
			count += 1
			held[count] = pos == 1 and piece or sub(piece, pos)
		end
	end

	function reader:finish()
		start()
		if count > 0 then
			local line = concat(held, "", 1, count)
			held, count = {}, 0
			one(line)
		end
	end

	return reader
end

-- Lines as records: one cell, the line, in the one column `line`.
function M.new(sink)
	return M.splitter(sink, function(line)
		sink.record({ cells = { line }, raw = line })
	end, { "line" })
end

return M
