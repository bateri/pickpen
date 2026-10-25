-- A table lined up with spaces: `ps aux`, `docker ps`, `kubectl get`, `df -h`. Where its columns
-- are, how a line is cut into them, and the names the heading gives. Positions are characters
-- (the first is 1), as a person counts them under a heading, not bytes.

local lines = require("input.lines")
local text = require("input.text")

local M = {}

local byte, find, sub = string.byte, string.find, string.sub
local lower, gmatch = string.lower, string.gmatch
local trim, shape = text.trim, text.shape
local huge = math.huge

-- Where the columns of a table lined up with spaces begin: at each place where every line,
-- the heading among them, has a space just before and the heading a word, so that a value
-- with spaces of its own (`Up 2 hours`) stays one cell. The last column takes the rest of
-- each line (`COMMAND` in `ps`).
function M.starts(heading, rows)
	local ground = shape(heading)
	local first, last
	for at in gmatch(ground, "()%S+") do
		first = first or at
		last = at
	end
	if not first then
		return {}
	end
	local shapes = {}
	for i, row in ipairs(rows) do
		shapes[i] = (shape(row))
	end
	local count = #shapes

	-- Whether the place `at` is a gap: a space, or past the end, in the heading and every line.
	local function gap(at)
		if at <= #ground and byte(ground, at) ~= 32 then
			return false
		end
		for i = 1, count do
			local row = shapes[i]
			if at <= #row and byte(row, at) ~= 32 then
				return false
			end
		end
		return true
	end

	local starts = { first }
	local before = gap(first)
	for at = first + 1, last do
		local here = gap(at)
		if before and not here then
			starts[#starts + 1] = at
		end
		before = here
	end
	-- A column whose values are wider than its heading (a right-aligned PID) begins before
	-- the heading's word: the first column still begins at the start of the line.
	starts[1] = 1
	return starts
end

-- Where the column that begins at `at` begins in a line whose characters are `ground`, `len` of
-- them: a word that crosses the boundary moves it to the nearest space, to its left (but not
-- before `floor`) or to its right. The boundary stays where it is when no space is near.
local function nudge(ground, len, at, floor)
	local left = at - 1
	while left >= floor and byte(ground, left) ~= 32 do
		left -= 1
	end
	local right = at
	while right <= len and byte(ground, right) ~= 32 do
		right += 1
	end
	local to_left = left >= floor and (at - left - 1) or huge
	local to_right = right <= len and (right - at) or huge
	if to_left == huge and to_right == huge then
		return at
	end
	return to_left <= to_right and (left + 1) or (right + 1)
end

-- A line of ASCII cut at the starts: the same as `cut`, for the lines (nearly all of them) that
-- are ASCII, which are cut where they are, without the shape made.
local function cut_ascii(line, starts, n)
	local len = #line
	local cells = {}
	local prev = 1
	for i = 2, n do
		local at = starts[i]
		if at <= len and byte(line, at - 1) ~= 32 and byte(line, at) ~= 32 then
			at = nudge(line, len, at, prev + 1)
		end
		-- The cell without the white space at either end.
		local first = find(line, "%S", prev)
		if first and first < at then
			local last = at <= len and (at - 1) or len
			local b = byte(line, last)
			while b == 32 or (b >= 9 and b <= 13) do
				last -= 1
				b = byte(line, last)
			end
			cells[i - 1] = sub(line, first, last)
		else
			cells[i - 1] = ""
		end
		prev = at
	end
	local first = find(line, "%S", prev)
	if first then
		local last = len
		local b = byte(line, last)
		while b == 32 or (b >= 9 and b <= 13) do
			last -= 1
			b = byte(line, last)
		end
		cells[n] = sub(line, first, last)
	else
		cells[n] = ""
	end
	return cells
end

-- A line cut at the starts, each boundary moved to the nearest space when a word crosses it.
function M.cut(line, starts)
	local n = #starts
	if n == 0 then
		return {}
	end
	local ground, ascii = shape(line)
	if ascii then
		return cut_ascii(line, starts, n)
	end
	-- Not ASCII: the boundaries are found in characters and then cut where those characters are.
	local len = #ground
	local cells = {}
	local prev = starts[1]
	local offset = text.offsetter(line)
	local size = #line
	local function place(k)
		return k > len and (size + 1) or offset(k)
	end
	for i = 2, n do
		local at = starts[i]
		if at <= len and byte(ground, at - 1) ~= 32 and byte(ground, at) ~= 32 then
			at = nudge(ground, len, at, prev + 1)
		end
		cells[i - 1] = trim(sub(line, place(prev), place(at) - 1))
		prev = at
	end
	cells[n] = trim(sub(line, place(prev), size))
	return cells
end

-- A line split at its spaces into `count` cells, the last taking the rest of the line.
function M.split_words(line, count)
	local rest = trim(line)
	local cells, n, pos = {}, 0, 1
	while n < count - 1 and pos <= #rest do
		local _, stop, word = find(rest, "^(%S+)%s*", pos)
		if not stop then
			break
		end
		n += 1
		cells[n] = word
		pos = stop + 1
	end
	if pos <= #rest then
		cells[n + 1] = sub(rest, pos)
	end
	return cells
end

-- Column names from a heading, unique and never empty.
function M.names_of(fields)
	local seen, names = {}, {}
	for at = 1, #fields do
		local base = trim(fields[at])
		if base == "" then
			base = "column " .. at
		end
		local key = lower(base)
		local n = (seen[key] or 0) + 1
		seen[key] = n
		names[at] = n == 1 and base or (base .. " " .. n)
	end
	return names
end

-- Whether the line has at least `need` words.
local function has_words(row, need)
	local count, pos = 0, 1
	while true do
		local _, stop = find(row, "%S+", pos)
		if not stop then
			return false
		end
		count += 1
		if count >= need then
			return true
		end
		pos = stop + 1
	end
end

-- How a table lined up with spaces is cut into columns.
--
-- Most commands keep their columns lined up under the headings (`docker ps`, `kubectl get`,
-- `df`), and their values may hold spaces (`Up 2 hours`): those are cut where the columns are.
-- Some let a wide value push the rest of its line to the right (`ps` on macOS does, with a
-- twelve-digit VSZ), so that no column lines up after it; when the places find fewer columns
-- than the heading has groups of words, and every line has a word for each heading, the line
-- is split at its spaces instead, the last column taking the rest of it (`COMMAND`).
--
--   { kind = "places", starts = { ... }, names = { ... } }
--   { kind = "words", count = <n>, names = { ... } }
function M.layout_of(heading, rows)
	local starts = M.starts(heading, rows)
	local places = { kind = "places", starts = starts, names = M.names_of(M.cut(heading, starts)) }
	local trimmed = trim(heading)
	local groups, pos = 1, 1
	while true do
		local first, stop = find(trimmed, "%s%s+", pos)
		if not first then
			break
		end
		groups += 1
		pos = stop + 1
	end
	local words = {}
	for word in gmatch(trimmed, "%S+") do
		words[#words + 1] = word
	end
	if #starts >= groups or #words < 2 then
		return places
	end
	for _, row in ipairs(rows) do
		if not has_words(row, #words) then
			return places
		end
	end
	return { kind = "words", count = #words, names = M.names_of(words) }
end

local upper_pattern

-- Whether a word begins with a capital letter (of any script: `Größe`, `ÜBERSICHT`). Lua's own
-- patterns know the capitals of ASCII only; the runner's `regex` has the Unicode classes, and is
-- asked about the one character, and only when it is not ASCII.
local function begins_capital(word)
	local b = byte(word, 1)
	if b < 0x80 then
		return b >= 65 and b <= 90
	end
	local char = text.first_char(word)
	if not utf8.len(char) then
		return false
	end
	if upper_pattern == nil then
		local ok, pencere = pcall(require, "pencere")
		upper_pattern = ok and pencere.regex.new("^\\p{Lu}") or false
	end
	return upper_pattern and upper_pattern:find(char) ~= nil
end

-- `NAME   READY   STATUS`, `USER PID %CPU`, `Filesystem Size Used`: words a table is headed with.
function M.looks_like_heading(line)
	local words = {}
	for word in gmatch(trim(line), "%S+") do
		words[#words + 1] = word
		if #words > 40 then
			return false
		end
	end
	if #words < 2 or not begins_capital(words[1]) then
		return false
	end
	-- `SIZE/OFF` (lsof) and `I/O` head columns; `/usr/bin`, `a=1` and `10:00` are values.
	for _, word in ipairs(words) do
		if
			find(word, "^[+%-]?%d")
			or find(word, "^[/.~]")
			or find(word, "[=:]")
			or text.count(word) > 32
		then
			return false
		end
	end
	return true
end

-- A reader of a table: the first line is the heading, the columns are told once there is a line
-- to see them under, and each line after is a record of cells.
function M.new(sink)
	local heading
	local waiting = {}
	local kind, starts, count, columns_count

	local function emit(line)
		local cells
		if kind == "places" then
			if columns_count == 0 or find(line, "[\128-\255]") then
				cells = M.cut(line, starts)
			else
				cells = cut_ascii(line, starts, columns_count)
			end
		else
			cells = M.split_words(line, count)
		end
		sink.record({ cells = cells, raw = line })
	end

	local function settle(ended)
		if kind ~= nil or heading == nil then
			return
		end
		-- A heading alone tells no column from a space inside a heading (`IMAGE ID`): wait for
		-- a line.
		if #waiting == 0 and not ended then
			return
		end
		local sample = {}
		for i = 1, math.min(#waiting, 200) do
			sample[i] = waiting[i]
		end
		local layout = M.layout_of(heading, sample)
		kind, starts, count = layout.kind, layout.starts, layout.count
		columns_count = starts and #starts
		sink.columns(layout.names)
		for _, line in ipairs(waiting) do
			emit(line)
		end
		waiting = {}
	end

	local splitter = lines.splitter(sink, function(line)
		if heading == nil then
			heading = line
		elseif kind == nil then
			waiting[#waiting + 1] = line
		else
			emit(line)
		end
	end)

	local reader = {}

	function reader:feed(piece)
		splitter:feed(piece)
		-- The columns are read from what this first piece brought: the sample the shape was
		-- told from, or the first lines of a file whose shape was given.
		settle(false)
	end

	function reader:finish()
		splitter:finish()
		settle(true)
	end

	return reader
end

return M
