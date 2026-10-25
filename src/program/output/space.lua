-- What counts as white space where the output decides about a cell or splits a line into
-- words. Lua's `%s` knows only the ASCII kind, and the output has to agree with the rule it
-- was written to (the set a JavaScript `trim()` and `\s` take: ASCII, the no-break space, the
-- Unicode spaces and the byte order mark), so a cell that begins with a no-break space is
-- quoted in CSV and a word is cut at an ideographic space.

local M = {}

local byte, sub, find = string.byte, string.sub, string.find
local gsub, gmatch = string.gsub, string.gmatch

-- The white space that takes three bytes in UTF-8, as the bytes themselves.
local WIDE3 = {
	["\225\154\128"] = true, -- U+1680
	["\226\128\168"] = true, -- U+2028
	["\226\128\169"] = true, -- U+2029
	["\226\128\175"] = true, -- U+202F
	["\226\129\159"] = true, -- U+205F
	["\227\128\128"] = true, -- U+3000
	["\239\187\191"] = true, -- U+FEFF
}
for last = 128, 138 do
	WIDE3["\226\128" .. string.char(last)] = true -- U+2000 to U+200A
end

-- The patterns of every white space that is not ASCII, to turn them into a plain space before a
-- line is split into words.
local WIDE_PATTERNS = {
	"\194\160",
	"\225\154\128",
	"\226\128[\128-\138]",
	"\226\128[\168\169\175]",
	"\226\129\159",
	"\227\128\128",
	"\239\187\191",
}

local function ascii_space(b)
	return b == 32 or (b >= 9 and b <= 13)
end

-- The length in bytes of the white space that begins at `at`, or 0.
local function width_at(s, at)
	local b = byte(s, at)
	if b == nil then
		return 0
	end
	if b < 128 then
		return ascii_space(b) and 1 or 0
	end
	if b == 194 then
		return byte(s, at + 1) == 160 and 2 or 0
	end
	return WIDE3[sub(s, at, at + 2)] and 3 or 0
end

-- The length in bytes of the white space that ends at `at`, or 0. (A lead byte is never a
-- continuation byte, so a suffix of a longer character cannot be taken for one of these.)
local function width_before(s, at)
	local b = byte(s, at)
	if b == nil then
		return 0
	end
	if b < 128 then
		return ascii_space(b) and 1 or 0
	end
	if b == 160 and byte(s, at - 1) == 194 then
		return 2
	end
	if at >= 3 and WIDE3[sub(s, at - 2, at)] then
		return 3
	end
	return 0
end

-- Whether the text has white space at either end: `trim` would change it.
function M.has_edge(s)
	local first, last = byte(s, 1), byte(s, -1)
	if first == nil then
		return false
	end
	-- The common cell, a printable ASCII byte at both ends, is settled by two reads.
	if first > 32 and first < 128 and last > 32 and last < 128 then
		return false
	end
	return width_at(s, 1) > 0 or width_before(s, #s) > 0
end

-- The text without the white space at either end.
function M.trim(s)
	local from, to = 1, #s
	while from <= to do
		local width = width_at(s, from)
		if width == 0 then
			break
		end
		from += width
	end
	while to >= from do
		local width = width_before(s, to)
		if width == 0 then
			break
		end
		to -= width
	end
	return sub(s, from, to)
end

-- The words of a line, split at any run of white space (none empty).
function M.words(s)
	if find(s, "[\128-\255]") then
		for _, pattern in ipairs(WIDE_PATTERNS) do
			s = gsub(s, pattern, " ")
		end
	end
	local words = {}
	for word in gmatch(s, "%S+") do
		words[#words + 1] = word
	end
	return words
end

return M
