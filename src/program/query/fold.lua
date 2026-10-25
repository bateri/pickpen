-- Text as the query reads it: the same letter in any case, the spaces of every script, the
-- letters and digits of a heading. Strings are bytes here; whatever walks them by character
-- decodes UTF-8 by hand, and bytes that are no valid UTF-8 are passed over as they are, so that
-- no text, however broken, raises.

local M = {}

local byte, find, gsub, lower, sub = string.byte, string.find, string.gsub, string.lower, string.sub
local utf8char = utf8.char

-- The length in bytes of the white space character that starts at `i`, or 0: what `\s` and
-- `trim` mean to a person, that is ASCII's spaces and controls, the no-break space, the spaces
-- of U+2000 to U+200A, the line and paragraph separators, U+3000 and the byte order mark.
local function space_at(s, i)
	local b = byte(s, i)
	if b == nil then
		return 0
	end
	if b == 32 or (b >= 9 and b <= 13) then
		return 1
	end
	if b < 0xC2 then
		return 0
	end
	local b2, b3 = byte(s, i + 1, i + 2)
	if b == 0xC2 then
		return b2 == 0xA0 and 2 or 0
	elseif b == 0xE1 then
		return (b2 == 0x9A and b3 == 0x80) and 3 or 0
	elseif b == 0xE2 then
		if b2 == 0x80 and b3 ~= nil then
			if (b3 >= 0x80 and b3 <= 0x8A) or b3 == 0xA8 or b3 == 0xA9 or b3 == 0xAF then
				return 3
			end
		elseif b2 == 0x81 and b3 == 0x9F then
			return 3
		end
		return 0
	elseif b == 0xE3 then
		return (b2 == 0x80 and b3 == 0x80) and 3 or 0
	elseif b == 0xEF then
		return (b2 == 0xBB and b3 == 0xBF) and 3 or 0
	end
	return 0
end
M.space_at = space_at

-- The length in bytes of the white space character that ends at `j`, or 0.
local function space_before(s, j)
	local b = byte(s, j)
	if b == nil then
		return 0
	end
	if b == 32 or (b >= 9 and b <= 13) then
		return 1
	end
	if b < 0x80 then
		return 0
	end
	if j >= 2 and space_at(s, j - 1) == 2 then
		return 2
	end
	if j >= 3 and space_at(s, j - 2) == 3 then
		return 3
	end
	return 0
end

-- The text without the white space at its ends.
function M.trim(s)
	local first, last = byte(s, 1), byte(s, -1)
	if first == nil then
		return s
	end
	-- Most cells begin and end with a plain visible character: nothing to cut, nothing to copy.
	if first > 32 and first < 128 and last > 32 and last < 128 then
		return s
	end
	local from, to = 1, #s
	while from <= to do
		local width = space_at(s, from)
		if width == 0 then
			break
		end
		from += width
	end
	while to >= from do
		local width = space_before(s, to)
		if width == 0 then
			break
		end
		to -= width
	end
	if from == 1 and to == #s then
		return s
	end
	return sub(s, from, to)
end

-- Whether there is nothing in the text but white space.
function M.is_blank(s)
	local first = byte(s, 1)
	if first == nil then
		return true
	end
	if first > 32 and first < 128 then
		return false
	end
	return M.trim(s) == ""
end

-- Whether the text holds a white space character anywhere.
function M.has_space(s)
	if find(s, "[ \t\n\v\f\r]") then
		return true
	end
	if find(s, "[\194-\239]") then
		for i = 1, #s do
			if space_at(s, i) > 1 then
				return true
			end
		end
	end
	return false
end

-- The lower case of one letter, for the scripts a table is likely to hold: Latin-1, Latin
-- Extended-A and B, Latin Extended Additional (Vietnamese), Greek, Cyrillic and Armenian. It
-- is the simple mapping, one letter for one, so that a text keeps its length in letters; the
-- capital dotted I becomes a plain i, and the final sigma is folded into the sigma, so that
-- `ΟΔΟΣ` and `οδος` meet. A letter of any other script is its own lower case.
local function lower_letter(cp)
	if cp < 0x100 then
		if cp >= 0xC0 and cp <= 0xDE and cp ~= 0xD7 then
			return cp + 32
		end
		return cp
	elseif cp < 0x180 then
		if cp == 0x130 then
			return 0x69
		elseif cp == 0x178 then
			return 0xFF
		elseif cp <= 0x137 or (cp >= 0x14A and cp <= 0x177) then
			return cp % 2 == 0 and cp + 1 or cp
		elseif (cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17E) then
			return cp % 2 == 1 and cp + 1 or cp
		end
		return cp
	elseif cp < 0x250 then
		if cp >= 0x1CD and cp <= 0x1DC then
			return cp % 2 == 1 and cp + 1 or cp
		elseif
			(cp >= 0x1DE and cp <= 0x1EF)
			or (cp >= 0x1F8 and cp <= 0x21F)
			or (cp >= 0x222 and cp <= 0x233)
			or (cp >= 0x246 and cp <= 0x24F)
		then
			return cp % 2 == 0 and cp + 1 or cp
		elseif cp == 0x1F4 then
			return 0x1F5
		end
		return cp
	elseif cp >= 0x370 and cp <= 0x3FF then
		if cp >= 0x391 and cp <= 0x3AB and cp ~= 0x3A2 then
			return cp + 32
		elseif cp == 0x386 then
			return 0x3AC
		elseif cp >= 0x388 and cp <= 0x38A then
			return cp + 37
		elseif cp == 0x38C then
			return 0x3CC
		elseif cp == 0x38E or cp == 0x38F then
			return cp + 63
		elseif cp == 0x3C2 then
			return 0x3C3
		end
		return cp
	elseif cp >= 0x400 and cp <= 0x52F then
		if cp <= 0x40F then
			return cp + 80
		elseif cp <= 0x42F then
			return cp + 32
		elseif (cp >= 0x460 and cp <= 0x481) or (cp >= 0x48A and cp <= 0x4BF) then
			return cp % 2 == 0 and cp + 1 or cp
		elseif cp == 0x4C0 then
			return 0x4CF
		elseif cp >= 0x4C1 and cp <= 0x4CE then
			return cp % 2 == 1 and cp + 1 or cp
		elseif cp >= 0x4D0 then
			return cp % 2 == 0 and cp + 1 or cp
		end
		return cp
	elseif cp >= 0x531 and cp <= 0x556 then
		return cp + 48
	elseif cp >= 0x1E00 and cp <= 0x1EFF then
		if cp == 0x1E9E then
			return 0xDF
		elseif cp <= 0x1E95 or cp >= 0x1EA0 then
			return cp % 2 == 0 and cp + 1 or cp
		end
		return cp
	end
	return cp
end

-- The code point of a well-formed UTF-8 sequence, or nil.
local function decode(seq)
	local n = #seq
	local lead = byte(seq, 1)
	local cp, want
	if lead < 0xE0 then
		cp, want = lead - 0xC0, 2
	elseif lead < 0xF0 then
		cp, want = lead - 0xE0, 3
	else
		cp, want = lead - 0xF0, 4
	end
	if n ~= want then
		return nil
	end
	for k = 2, n do
		cp = cp * 64 + (byte(seq, k) - 0x80)
	end
	return cp
end

local function lower_sequence(seq)
	local cp = decode(seq)
	if cp == nil then
		return seq
	end
	local low = lower_letter(cp)
	if low == cp then
		return seq
	end
	return utf8char(low)
end

-- The text in lower case, for matching "in any case". Text that is all ASCII takes the plain
-- way; any other is lowered letter by letter (see `lower_letter`).
function M.lower(s)
	if not find(s, "[\128-\255]") then
		return lower(s)
	end
	return (gsub(lower(s), "[\194-\244][\128-\191]*", lower_sequence))
end

-- The ranges of code points that are neither a letter nor a digit, above ASCII: controls,
-- punctuation, symbols, combining marks, spaces, private use. A code point outside them is
-- counted as a letter or a digit, which for the scripts a heading is written in is what it is.
local NOT_WORD = {
	{ 0x80, 0xA9 }, { 0xAB, 0xB1 }, { 0xB4, 0xB4 }, { 0xB6, 0xB8 }, { 0xBB, 0xBB },
	{ 0xBF, 0xBF }, { 0xD7, 0xD7 }, { 0xF7, 0xF7 }, { 0x2C2, 0x2C5 }, { 0x2D2, 0x2DF },
	{ 0x2E5, 0x2EB }, { 0x2ED, 0x2ED }, { 0x2EF, 0x36F }, { 0x375, 0x375 }, { 0x37E, 0x37E },
	{ 0x384, 0x385 }, { 0x387, 0x387 }, { 0x3F6, 0x3F6 }, { 0x482, 0x489 }, { 0x55A, 0x55F },
	{ 0x589, 0x58A }, { 0x591, 0x5C7 }, { 0x600, 0x61F }, { 0x64B, 0x65F }, { 0x66A, 0x66D },
	{ 0x2000, 0x206F }, { 0x20A0, 0x214F }, { 0x2190, 0x245F }, { 0x249C, 0x2775 },
	{ 0x2794, 0x2BFF }, { 0x2E00, 0x2FFF }, { 0x3000, 0x3004 }, { 0x3008, 0x3020 },
	{ 0x3030, 0x3030 }, { 0x3036, 0x3037 }, { 0x303D, 0x303F }, { 0x3099, 0x309C },
	{ 0x30A0, 0x30A0 }, { 0x30FB, 0x30FB }, { 0x3200, 0x33FF }, { 0x4DC0, 0x4DFF },
	{ 0xA490, 0xA4CF }, { 0xD800, 0xF8FF }, { 0xFD3E, 0xFD3F }, { 0xFE00, 0xFE6F },
	{ 0xFF00, 0xFF0F }, { 0xFF1A, 0xFF20 }, { 0xFF3B, 0xFF40 }, { 0xFF5B, 0xFF65 },
	{ 0xFFE0, 0xFFFF }, { 0x1D000, 0x1D3FF }, { 0x1F000, 0x1FAFF }, { 0xE0000, 0x10FFFF },
}

local function is_word(cp)
	if cp > 0x10FFFF then
		return false
	end
	-- The letters of Latin-1 to the end of Latin Extended-B come first, as they come most.
	if cp >= 0xC0 and cp <= 0x2B8 then
		return cp ~= 0xD7 and cp ~= 0xF7
	end
	for i = 1, #NOT_WORD do
		local range = NOT_WORD[i]
		if cp < range[1] then
			return true
		elseif cp <= range[2] then
			return false
		end
	end
	return true
end

local function word_run(run)
	local kept = {}
	local at, n = 1, #run
	while at <= n do
		local lead = byte(run, at)
		local width = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or lead >= 0xC2 and 2 or 1
		local seq = sub(run, at, at + width - 1)
		local cp = width > 1 and decode(seq)
		if cp and is_word(cp) then
			kept[#kept + 1] = seq
		end
		at += width
	end
	return table.concat(kept)
end

-- The letters and digits of the text and nothing else, in the case they have.
function M.alnum(s)
	local plain = gsub(s, "[^%w\128-\255]", "")
	if not find(plain, "[\128-\255]") then
		return plain
	end
	return (gsub(plain, "[\128-\255]+", word_run))
end

return M
