-- The few things about text that every reader of the input needs: where a piece of text begins
-- and ends (what a person calls blank), and what a column is when the text is not ASCII.
--
-- Lua strings are bytes, and a table lined up with spaces is lined up in characters: a heading
-- over "Größe" is five columns wide, not seven. So a column position here is a code point, and a
-- byte that is no part of a well-formed sequence is one character of its own (a stray byte never
-- raises, and never takes its neighbours with it).

local M = {}

local byte, find, sub, gsub = string.byte, string.find, string.sub, string.gsub
local utf8_len, utf8_offset = utf8.len, utf8.offset

-- The length of the white space beyond ASCII that begins at `i`, if some does (what JavaScript's
-- `trim` takes too): a no-break space, the spaces of U+2000 to U+200A, the line and paragraph
-- separators, the ideographic space, the byte order mark and a few more.
local function unicode_space_at(s, i)
	local b = byte(s, i)
	if b == 0xC2 then
		return byte(s, i + 1) == 0xA0 and 2 or nil
	elseif b == 0xE1 then
		return (byte(s, i + 1) == 0x9A and byte(s, i + 2) == 0x80) and 3 or nil
	elseif b == 0xE2 then
		local b2, b3 = byte(s, i + 1), byte(s, i + 2)
		if b2 == 0x80 and b3 then
			if (b3 >= 0x80 and b3 <= 0x8A) or b3 == 0xA8 or b3 == 0xA9 or b3 == 0xAF then
				return 3
			end
		elseif b2 == 0x81 and b3 == 0x9F then
			return 3
		end
	elseif b == 0xE3 then
		return (byte(s, i + 1) == 0x80 and byte(s, i + 2) == 0x80) and 3 or nil
	elseif b == 0xEF then
		return (byte(s, i + 1) == 0xBB and byte(s, i + 2) == 0xBF) and 3 or nil
	end
	return nil
end

-- The length of the white space sequence that ends at `j`, if one does.
local function unicode_space_ending(s, j)
	for len = 2, 3 do
		if j - len + 1 >= 1 and unicode_space_at(s, j - len + 1) == len then
			return len
		end
	end
	return nil
end

local function is_ascii_space(b)
	return b == 32 or (b ~= nil and b >= 9 and b <= 13)
end

-- The text without the white space at either end. ASCII white space is the whole story but for
-- a few sequences (a no-break space, a byte order mark) that an edge of the text may begin or
-- end with.
function M.trim(s)
	local i = find(s, "%S")
	if not i then
		return ""
	end
	local j = #s
	while is_ascii_space(byte(s, j)) do
		j -= 1
	end
	-- Only text that begins or ends with a byte of a sequence can have a wide space there.
	if byte(s, i) >= 0xC2 or byte(s, j) >= 0x80 then
		while i <= j do
			local len = unicode_space_at(s, i)
			if is_ascii_space(byte(s, i)) then
				i += 1
			elseif len and i + len - 1 <= j then
				i += len
			else
				break
			end
		end
		while j >= i do
			local len = unicode_space_ending(s, j)
			if is_ascii_space(byte(s, j)) then
				j -= 1
			elseif len and j - len + 1 >= i then
				j -= len
			else
				break
			end
		end
	end
	if i == 1 and j == #s then
		return s
	end
	return sub(s, i, j)
end

function M.is_blank(s)
	local i = find(s, "%S")
	if not i then
		return true
	end
	if byte(s, i) < 0x80 then
		return false
	end
	return M.trim(s) == ""
end

-- How many bytes the character at `i` takes: a well-formed sequence is one character, and so is
-- a stray byte, or the start of a sequence that was cut short (the way a decoder that replaces
-- what it cannot read would count them).
local function step(s, i)
	local b = byte(s, i)
	if b < 0xC2 or b > 0xF4 then
		return 1
	end
	local lo, hi = 0x80, 0xBF
	if b == 0xE0 then
		lo = 0xA0
	elseif b == 0xED then
		hi = 0x9F
	elseif b == 0xF0 then
		lo = 0x90
	elseif b == 0xF4 then
		hi = 0x8F
	end
	local need = b < 0xE0 and 1 or (b < 0xF0 and 2 or 3)
	local c = byte(s, i + 1)
	if not c or c < lo or c > hi then
		return 1
	end
	for k = 2, need do
		c = byte(s, i + k)
		if not c or c < 0x80 or c > 0xBF then
			return k
		end
	end
	return need + 1
end

-- Where every character begins: a list, and one more place after the last (the end of the text),
-- so that the character k is `offsets[k]` up to (but not including) `offsets[k + 1]`.
local function offsets_of(s)
	local offs, n, i, len = {}, 0, 1, #s
	while i <= len do
		local j = find(s, "[\128-\255]", i)
		if not j then
			j = len + 1
		end
		for k = i, j - 1 do
			n += 1
			offs[n] = k
		end
		if j > len then
			break
		end
		n += 1
		offs[n] = j
		i = j + step(s, j)
	end
	offs[n + 1] = len + 1
	return offs
end

-- The text as one ASCII byte per character: ASCII stays as it is and every other character
-- becomes an `x`. What lines up is decided on this, in characters, whatever the bytes are.
-- Gives the shape, and whether the text was ASCII (when the shape is the text itself).
function M.shape(s)
	if not find(s, "[\128-\255]") then
		return s, true
	end
	if utf8_len(s) then
		return (gsub(s, "[\194-\244][\128-\191]*", "x")), false
	end
	local offs = offsets_of(s)
	local out = {}
	for k = 1, #offs - 1 do
		local at = offs[k]
		out[k] = byte(s, at) < 0x80 and sub(s, at, at) or "x"
	end
	return table.concat(out), false
end

-- The byte where the character `k` begins, for any k up to one past the last character: a
-- function of that, made once for a text that is not ASCII.
function M.offsetter(s)
	if utf8_len(s) then
		return function(k)
			return utf8_offset(s, k)
		end
	end
	local offs = offsets_of(s)
	return function(k)
		return offs[k]
	end
end

-- How many characters the text has.
function M.count(s)
	if not find(s, "[\128-\255]") then
		return #s
	end
	return utf8_len(s) or (#offsets_of(s) - 1)
end

-- The first character of the text ("" for none).
function M.first_char(s)
	if s == "" then
		return ""
	end
	return sub(s, 1, step(s, 1))
end

return M
