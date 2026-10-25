-- JSON as values that keep what a Lua table cannot: the order of an object's keys (they are the
-- columns of a table), the difference between an empty array and an empty object, and `null`.
--
--   null            json.null, one value that is neither false nor nil
--   array           { n = <count>, [1] = ..., [n] = ... }          with the metatable json.Array
--   object          { keys = { k1, k2, ... }, map = { [k] = v } }  with the metatable json.Object
--
-- An object keeps its keys in the order they were first written; a key written twice keeps its
-- first place and the last value, as an object of JavaScript does. Text goes in and out the way
-- `JSON.parse` and `JSON.stringify` do it (what a person sees in a log and what a script of
-- another language writes agree), numbers included: `1.0` is `1`, `1e21` is `1e+21`.

local M = {}

local byte, find, sub, format = string.byte, string.find, string.sub, string.format
local concat, rep, gsub = table.concat, string.rep, string.gsub
local floor, huge = math.floor, math.huge

M.null = setmetatable({}, {
	__tostring = function()
		return "null"
	end,
})
local null = M.null

M.Array = {}
M.Object = {}
local Array, Object = M.Array, M.Object

function M.is_array(value)
	return getmetatable(value) == Array
end

function M.is_object(value)
	return getmetatable(value) == Object
end

-- An array of a list's items (`list.n` says how many when some are nil, but `null` is what an
-- absent JSON value is, so a list seldom needs it).
function M.array(list)
	local n = list.n or #list
	local array = { n = n }
	for i = 1, n do
		array[i] = list[i]
	end
	return setmetatable(array, Array)
end

-- An object of a list of `{ key, value }` pairs.
function M.object(pairs_list)
	local keys, map = {}, {}
	for _, pair in ipairs(pairs_list) do
		local key = pair[1]
		if map[key] == nil then
			keys[#keys + 1] = key
		end
		map[key] = pair[2]
	end
	return setmetatable({ keys = keys, map = map }, Object)
end

-- Numbers -----------------------------------------------------------------------------------

local EXPONENT_FORMATS = { "%.14e", "%.15e", "%.16e" }
local SMALL_FORMATS = {}
for digits = 0, 16 do
	SMALL_FORMATS[digits + 1] = "%." .. digits .. "e"
end

-- A number the way `String(n)` of JavaScript writes it: whole numbers without a point, the
-- fewest digits that read back as the same number, and an exponent only out of the range of
-- 1e-6 to 1e21.
local function number_text(n)
	if n ~= n then
		return "NaN"
	elseif n == huge then
		return "Infinity"
	elseif n == -huge then
		return "-Infinity"
	elseif n == 0 then
		return "0"
	elseif n == floor(n) and n > -9007199254740992 and n < 9007199254740992 then
		return format("%d", n)
	elseif n < 0 then
		return "-" .. number_text(-n)
	end
	local text
	-- Fifteen digits tell a number of the usual size apart from every other, so the first of
	-- the formats that reads back is the shortest; the numbers too small to have fifteen digits
	-- have fewer, and are tried from one.
	local formats = n < 2.2250738585072014e-308 and SMALL_FORMATS or EXPONENT_FORMATS
	for _, pattern in ipairs(formats) do
		text = format(pattern, n)
		if tonumber(text) == n then
			break
		end
	end
	local lead, rest, exponent = string.match(text, "^(%d)%.?(%d*)e([+-]%d+)$")
	local digits = lead .. string.match(rest, "^(.-)0*$")
	local k = #digits
	-- The position of the point, counted from the first digit, as the language's rule has it.
	local point = tonumber(exponent) + 1
	if k <= point and point <= 21 then
		return digits .. rep("0", point - k)
	elseif 0 < point and point <= 21 then
		return sub(digits, 1, point) .. "." .. sub(digits, point + 1)
	elseif -6 < point and point <= 0 then
		return "0." .. rep("0", -point) .. digits
	end
	local power = point - 1
	local sign = power < 0 and "-" or "+"
	local mantissa = k == 1 and digits or (sub(digits, 1, 1) .. "." .. sub(digits, 2))
	return mantissa .. "e" .. sign .. (power < 0 and -power or power)
end

-- Strings -----------------------------------------------------------------------------------

local ESCAPED = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}
for code = 0, 31 do
	local char = string.char(code)
	if not ESCAPED[char] then
		ESCAPED[char] = format("\\u%04x", code)
	end
end

local function quote(text)
	if not find(text, '[%z\1-\31"\\]') then
		return '"' .. text .. '"'
	end
	return '"' .. gsub(text, '[%z\1-\31"\\]', ESCAPED) .. '"'
end

-- Encoding ----------------------------------------------------------------------------------

local MAX_DEPTH = 512

local encode_value

local function encode_array(array, gap, indent, out, depth)
	local n = array.n
	if n == 0 then
		out[#out + 1] = "[]"
		return
	end
	local inner = indent .. gap
	out[#out + 1] = gap == "" and "[" or ("[\n" .. inner)
	for i = 1, n do
		if i > 1 then
			out[#out + 1] = gap == "" and "," or (",\n" .. inner)
		end
		encode_value(array[i], gap, inner, out, depth + 1)
	end
	out[#out + 1] = gap == "" and "]" or ("\n" .. indent .. "]")
end

local function encode_object(object, gap, indent, out, depth)
	local keys, map = object.keys, object.map
	if #keys == 0 then
		out[#out + 1] = "{}"
		return
	end
	local inner = indent .. gap
	local colon = gap == "" and ":" or ": "
	out[#out + 1] = gap == "" and "{" or ("{\n" .. inner)
	for i, key in ipairs(keys) do
		if i > 1 then
			out[#out + 1] = gap == "" and "," or (",\n" .. inner)
		end
		out[#out + 1] = quote(key) .. colon
		encode_value(map[key], gap, inner, out, depth + 1)
	end
	out[#out + 1] = gap == "" and "}" or ("\n" .. indent .. "}")
end

function encode_value(value, gap, indent, out, depth)
	local kind = type(value)
	if kind == "string" then
		out[#out + 1] = quote(value)
	elseif kind == "number" then
		out[#out + 1] = (value ~= value or value == huge or value == -huge) and "null"
			or number_text(value)
	elseif kind == "boolean" then
		out[#out + 1] = value and "true" or "false"
	elseif value == null or value == nil then
		out[#out + 1] = "null"
	elseif kind == "table" then
		if depth > MAX_DEPTH then
			error("json.encode: the value is nested too deep", 0)
		end
		local meta = getmetatable(value)
		if meta == Array then
			encode_array(value, gap, indent, out, depth)
		elseif meta == Object then
			encode_object(value, gap, indent, out, depth)
		else
			error("json.encode: a table that is neither json.array nor json.object", 0)
		end
	else
		error("json.encode: cannot write a " .. kind, 0)
	end
end

-- The text of a value, as `JSON.stringify(value, null, indent)` writes it: on one line without
-- an `indent`, else with a line for each item, indented by that many spaces (at most 10) or by
-- the text it is given.
function M.encode(value, indent)
	local gap = ""
	if type(indent) == "number" then
		gap = rep(" ", math.max(0, math.min(10, floor(indent))))
	elseif type(indent) == "string" then
		gap = sub(indent, 1, 10)
	end
	local out = {}
	encode_value(value, gap, "", out, 0)
	return concat(out)
end

-- What a cell shows of a value: nothing for `null`, a string as it is, a number or a boolean as
-- the language writes it, and an array or an object on one line as JSON.
function M.text_of(value)
	local kind = type(value)
	if kind == "string" then
		return value
	elseif value == null or value == nil then
		return ""
	elseif kind == "number" then
		return number_text(value)
	elseif kind == "boolean" then
		return value and "true" or "false"
	end
	return M.encode(value)
end

-- Parsing -----------------------------------------------------------------------------------

-- The text being read and the place in it: the readers below share them, so that no reading
-- makes a closure of its own (the parser never waits, so it is never in two places at once).
local src, at, size

local function fail(why)
	error({ json = why .. " at " .. at }, 0)
end

local function skip_space()
	local b = byte(src, at)
	if b == 32 or b == 10 or b == 13 or b == 9 then
		at = find(src, "[^ \t\n\r]", at) or (size + 1)
	end
end

local SIMPLE = {
	[34] = '"',
	[92] = "\\",
	[47] = "/",
	[98] = "\b",
	[102] = "\f",
	[110] = "\n",
	[114] = "\r",
	[116] = "\t",
}

-- U+FFFD, what stands for a half of a surrogate pair that has no other half (UTF-8 cannot
-- hold one).
local REPLACEMENT = "\239\191\189"

-- The escape that begins at `where` (after the backslash) and the place after it.
local function read_escape(where)
	local b = byte(src, where)
	local simple = SIMPLE[b]
	if simple then
		return simple, where + 1
	end
	if b ~= 117 then
		at = where
		fail("bad escape")
	end
	local hex = string.match(src, "^%x%x%x%x", where + 1)
	if not hex then
		at = where
		fail("bad escape")
	end
	local code = tonumber(hex, 16)
	local after = where + 5
	if code >= 0xD800 and code <= 0xDBFF then
		local low = byte(src, after) == 92 and byte(src, after + 1) == 117
			and string.match(src, "^%x%x%x%x", after + 2)
		low = low and tonumber(low, 16)
		if low and low >= 0xDC00 and low <= 0xDFFF then
			return utf8.char(0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)), after + 6
		end
		return REPLACEMENT, after
	elseif code >= 0xDC00 and code <= 0xDFFF then
		return REPLACEMENT, after
	end
	return utf8.char(code), after
end

local function read_string()
	local start = at + 1
	local stop = find(src, '[%z\1-\31"\\]', start)
	local b = stop and byte(src, stop)
	if b == 34 then
		at = stop + 1
		return sub(src, start, stop - 1)
	end
	local parts, n = {}, 0
	while true do
		if not b then
			at = size + 1
			fail("unterminated string")
		elseif b == 34 then
			parts[n + 1] = sub(src, start, stop - 1)
			at = stop + 1
			return concat(parts)
		elseif b ~= 92 then
			at = stop
			fail("control character in string")
		end
		parts[n + 1] = sub(src, start, stop - 1)
		local text, after = read_escape(stop + 1)
		parts[n + 2] = text
		n += 2
		start = after
		stop = find(src, '[%z\1-\31"\\]', start)
		b = stop and byte(src, stop)
	end
end

local function read_number()
	-- The digits, and the byte after them: only a point or an exponent makes it more than a
	-- whole number.
	local _, last, digits, more = find(src, "^(-?[0-9]+)([.eE]?)", at)
	if not last then
		fail("unexpected character")
	end
	local lead = byte(digits, 1)
	if (lead == 48 and #digits > 1) or (lead == 45 and byte(digits, 2) == 48 and #digits > 2) then
		fail("a number with a leading zero")
	end
	if more == "" then
		at = last + 1
		return tonumber(digits)
	end
	if more == "." then
		local _, stop = find(src, "^%.[0-9]+", last)
		if not stop then
			at = last
			fail("bad number")
		end
		last = stop
	else
		last -= 1
	end
	local b = byte(src, last + 1)
	if b == 101 or b == 69 then
		local _, stop = find(src, "^[eE][+-]?[0-9]+", last + 1)
		if not stop then
			at = last + 1
			fail("bad number")
		end
		last = stop
	end
	local number = tonumber(sub(src, at, last))
	at = last + 1
	return number
end

local read_value

local function read_array(depth)
	local array, n = { n = 0 }, 0
	at += 1
	skip_space()
	if byte(src, at) == 93 then
		at += 1
		return setmetatable(array, Array)
	end
	while true do
		n += 1
		array[n] = read_value(depth)
		skip_space()
		local b = byte(src, at)
		if b == 44 then
			at += 1
		elseif b == 93 then
			at += 1
			array.n = n
			return setmetatable(array, Array)
		else
			fail("expected , or ]")
		end
	end
end

-- A key and its value, read the slow way: any white space, any escape, any kind of value.
local function read_pair(depth)
	if byte(src, at) ~= 34 then
		fail("expected a key")
	end
	local key = read_string()
	skip_space()
	if byte(src, at) ~= 58 then
		fail("expected :")
	end
	at += 1
	return key, read_value(depth)
end

-- The common pair, read in one call: a key and a string, each with nothing to unescape and at
-- most a space after the colon; or the key alone, for a value that is not a string.
local PAIR_OF_STRINGS = '^"([^%z\1-\31"\\]*)"[ ]?:[ ]?"([^%z\1-\31"\\]*)"'
local KEY_AND_COLON = '^"([^%z\1-\31"\\]*)"[ ]?:[ ]?'

local function read_object(depth)
	local keys, map, n = {}, {}, 0
	at += 1
	skip_space()
	if byte(src, at) == 125 then
		at += 1
		return setmetatable({ keys = keys, map = map }, Object)
	end
	while true do
		local key, value
		local _, stop, first, second = find(src, PAIR_OF_STRINGS, at)
		if stop then
			key, value, at = first, second, stop + 1
		else
			_, stop, first = find(src, KEY_AND_COLON, at)
			if stop then
				at = stop + 1
				local b = byte(src, at)
				if b and b >= 48 and b <= 57 then
					key, value = first, read_number()
				else
					key, value = first, read_value(depth)
				end
			else
				key, value = read_pair(depth)
			end
		end
		if map[key] == nil then
			n += 1
			keys[n] = key
		end
		map[key] = value
		local b = byte(src, at)
		if b == 32 or b == 10 or b == 13 or b == 9 then
			skip_space()
			b = byte(src, at)
		end
		if b == 44 then
			at += 1
			b = byte(src, at)
			if b == 32 or b == 10 or b == 13 or b == 9 then
				skip_space()
			end
		elseif b == 125 then
			at += 1
			return setmetatable({ keys = keys, map = map }, Object)
		else
			fail("expected , or }")
		end
	end
end

local MAX_NESTING = 512

function read_value(depth)
	skip_space()
	local b = byte(src, at)
	if b == 34 then
		return read_string()
	elseif b == 123 or b == 91 then
		if depth >= MAX_NESTING then
			fail("nested too deep")
		end
		if b == 123 then
			return read_object(depth + 1)
		end
		return read_array(depth + 1)
	elseif b == 116 then
		if sub(src, at, at + 3) == "true" then
			at += 4
			return true
		end
	elseif b == 102 then
		if sub(src, at, at + 4) == "false" then
			at += 5
			return false
		end
	elseif b == 110 then
		if sub(src, at, at + 3) == "null" then
			at += 4
			return null
		end
	elseif b == nil then
		fail("unexpected end")
	elseif b == 45 or (b >= 48 and b <= 57) then
		return read_number()
	end
	fail("unexpected character")
end

local function read_all()
	local value = read_value(0)
	skip_space()
	if at <= size then
		fail("unexpected text after the value")
	end
	return value
end

-- The value that is the whole text (white space about it apart), or nil and what is wrong.
-- Nesting past 512 levels is refused, not followed.
function M.parse(text)
	if type(text) ~= "string" then
		return nil, "not a string"
	end
	src, at, size = text, 1, #text
	local ok, result = pcall(read_all)
	src = nil
	if ok then
		return result
	end
	if type(result) == "table" and result.json then
		return nil, result.json
	end
	return nil, tostring(result)
end

return M
