-- What a cell says as a quantity: a number, a size, a length of time or a moment. The query's
-- comparisons and the sort read cells through this one module, so that `cpu>50` and
-- `--sort -cpu` mean the same rows wherever they run. A cell is read on its own, never by the
-- type of its column: a column whose every other cell is a size does not make a stray word one.
--
--   12  -3.5  1e6  12%              numbers (a percentage is its number)
--   1.2G  512Ki  3.4 MB  200M  10k  sizes: one letter and `iB` count in 1024s, as `ls -h`,
--                                   `du -h` and Kubernetes do, `kB`, `MB` and the rest in 1000s,
--                                   as Docker does; the value is in bytes
--   45s  3m  5d2h  500ms  1:02:03   lengths of time, in seconds: a small `m` is minutes and a
--                                   capital `M` a size
--   2026-10-22  2026-10-22T10:00:00Z  2026-10-22 10:00
--                                   moments, in milliseconds since 1970. A moment without a
--                                   zone is read as UTC: the runner has no time zone to ask.

local fold = require("query.fold")

local M = {}

local byte, find, match, sub = string.byte, string.find, string.match, string.sub
local floor = math.floor
local trim, space_at = fold.trim, fold.space_at

-- A size's letter (as the byte of its small form) to its power of 1024 or 1000, in bytes.
local POWER = { [107] = 1, [109] = 2, [103] = 3, [116] = 4, [112] = 5 }
local BINARY, DECIMAL = {}, {}
do
	local binary, decimal = 1, 1
	for power = 1, 5 do
		binary *= 1024
		decimal *= 1000
		BINARY[power], DECIMAL[power] = binary, decimal
	end
end

-- The seconds of a length of time's unit, by the byte of its letter (`ms` is read apart).
local SECONDS = {
	[115] = 1, [109] = 60, [104] = 3600, [100] = 86400, [119] = 604800, [121] = 31536000,
}

-- Whether two kinds of quantity can be compared: one kind, or one a bare number, which is
-- read in the other's base unit (`size>1000` is a thousand bytes). A moment is compared only
-- with a moment.
local function comparable_kinds(a, b)
	if a == b then
		return true
	end
	if a == "date" or b == "date" then
		return false
	end
	return a == "number" or b == "number"
end
M.comparable_kinds = comparable_kinds

-- The size unit `[kKmMgGtTpP]i?[bB]?` or `[bB]`, all of the text: the factor of bytes it
-- stands for. A lone small `m` is no size but minutes: it gives `nil, true`.
local function size_unit(tail)
	local n = #tail
	if n == 0 or n > 3 then
		return nil
	end
	local first = byte(tail, 1)
	if first >= 65 and first <= 90 then
		first += 32
	end
	if first == 98 then
		return n == 1 and 1 or nil
	end
	local power = POWER[first]
	if power == nil then
		return nil
	end
	if n == 1 then
		if tail == "m" then
			return nil, true
		end
		return BINARY[power]
	end
	local second = byte(tail, 2)
	if second == 105 then
		if n == 2 then
			return BINARY[power]
		end
		local third = byte(tail, 3)
		return (third == 98 or third == 66) and BINARY[power] or nil
	end
	if n == 2 and (second == 98 or second == 66) then
		return DECIMAL[power]
	end
	return nil
end

-- `5d2h`, `500ms`, `1.5h`: parts of a number and a unit, all of the text; the seconds.
local function duration(text)
	local at, n, total = 1, #text, 0
	while at <= n do
		local _, last = find(text, "^%d+", at)
		if last == nil then
			return nil
		end
		local _, fraction = find(text, "^%.%d+", last + 1)
		last = fraction or last
		local unit = byte(text, last + 1)
		local scale, width
		if unit == 109 and byte(text, last + 2) == 115 then
			scale, width = 0.001, 2
		else
			scale, width = SECONDS[unit], 1
		end
		if scale == nil then
			return nil
		end
		total += tonumber(sub(text, at, last)) * scale
		at = last + width + 1
	end
	return total
end

-- `1:02:03`, `0:01.23`, `12:34`: hours, minutes and seconds, or minutes and seconds; the seconds.
local function clock(text)
	local _, last, hours, minutes = find(text, "^(%d+):(%d%d)")
	if last == nil then
		return nil
	end
	local seconds
	if byte(text, last + 1) == 58 then
		local _, after, digits = find(text, "^:(%d%d)", last + 1)
		if after == nil then
			return nil
		end
		seconds, last = tonumber(digits), after
	end
	local fraction = 0
	if last < #text then
		if not find(text, "^%.%d+$", last + 1) then
			return nil
		end
		fraction = tonumber(sub(text, last + 1))
	end
	local total
	if seconds == nil then
		total = tonumber(hours) * 60 + tonumber(minutes)
	else
		total = tonumber(hours) * 3600 + tonumber(minutes) * 60 + seconds
	end
	return total + fraction
end

local DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function days_in(year, month)
	if month == 2 and year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then
		return 29
	end
	return DAYS[month]
end

-- The days from 1970-01-01 to a day of the calendar, which runs on past either end.
local function days_from_civil(year, month, day)
	if month <= 2 then
		year -= 1
	end
	local era = year // 400
	local of_era = year - era * 400
	local shifted = month > 2 and month - 3 or month + 9
	local of_year = (153 * shifted + 2) // 5 + day - 1
	return era * 146097 + of_era * 365 + of_era // 4 - of_era // 100 + of_year - 719468
end

-- The day of the calendar a number of days from 1970-01-01 is.
local function civil_from_days(days)
	days += 719468
	local era = days // 146097
	local of_era = days - era * 146097
	local year_of_era = (of_era - of_era // 1460 + of_era // 36524 - of_era // 146096) // 365
	local year = year_of_era + era * 400
	local of_year = of_era - (365 * year_of_era + year_of_era // 4 - year_of_era // 100)
	local shifted = (5 * of_year + 2) // 153
	local day = of_year - (153 * shifted + 2) // 5 + 1
	local month = shifted < 10 and shifted + 3 or shifted - 9
	if month <= 2 then
		year += 1
	end
	return year, month, day
end

-- `2026-10-22`, `2026-10-22T10:00`, `2026-10-22 10:00:00.5+02:00`, `...Z`: the milliseconds
-- since 1970 as `Date.parse` reads them, or nil when a part is out of its range. A date alone,
-- or a time with a zone, is exact. A time with no zone is local time to a browser; here it is
-- UTC, since the runner has no time zone to ask. A day the month does not have (the 30th of
-- February) is no moment, as the standard says; V8's legacy parser rolls it into the next month,
-- and another engine does not, so the old program read it differently in two places.
local function moment(text)
	local _, _, year, month, day = find(text, "^(%d%d%d%d)-(%d%d)-(%d%d)")
	if year == nil then
		return nil
	end
	year, month, day = tonumber(year), tonumber(month), tonumber(day)
	if month < 1 or month > 12 or day < 1 or day > days_in(year, month) then
		return nil
	end
	local hour, minute, second, milli, offset = 0, 0, 0, 0, 0
	if #text > 10 then
		local separator = byte(text, 11)
		if separator ~= 84 and separator ~= 32 then
			return nil
		end
		local _, last, hours, minutes = find(text, "^(%d%d):(%d%d)", 12)
		if last == nil then
			return nil
		end
		hour, minute = tonumber(hours), tonumber(minutes)
		local at = last + 1
		if byte(text, at) == 58 then
			local _, after, digits = find(text, "^:(%d%d)", at)
			if after == nil then
				return nil
			end
			second, at = tonumber(digits), after + 1
			if byte(text, at) == 46 then
				local _, end_of, fraction = find(text, "^%.(%d+)", at)
				if end_of == nil then
					return nil
				end
				milli, at = tonumber(sub(fraction .. "00", 1, 3)), end_of + 1
			end
		end
		local zone = sub(text, at)
		if zone ~= "" and zone ~= "Z" then
			local sign, zone_hours, zone_minutes = match(zone, "^([+-])(%d%d):?(%d%d)$")
			if sign == nil or tonumber(zone_hours) > 23 or tonumber(zone_minutes) > 59 then
				return nil
			end
			offset = (tonumber(zone_hours) * 60 + tonumber(zone_minutes)) * 60000
			if sign == "-" then
				offset = -offset
			end
		end
		if minute > 59 or second > 59 or hour > 24 then
			return nil
		end
		if hour == 24 and (minute > 0 or second > 0 or milli > 0) then
			return nil
		end
	end
	local seconds = days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
	return seconds * 1000 + milli - offset
end

-- What a cell holds as a quantity: its kind and its value, or nothing when it holds words.
-- This is the form for the loops over a column, which would otherwise make a table for every
-- cell; `quantity` is the same in a table.
local function scan(cell)
	local first = byte(cell, 1)
	if first == nil then
		return nil
	end
	local text = cell
	local last = byte(cell, -1)
	if first <= 32 or first >= 128 or last <= 32 or last >= 128 then
		text = trim(cell)
		first = byte(text, 1)
		if first == nil then
			return nil
		end
	end
	-- Words are the most of any column: all the forms below begin with a digit, a sign or a dot.
	if (first < 48 or first > 57) and first ~= 43 and first ~= 45 and first ~= 46 then
		return nil
	end
	local n = #text
	if n > 40 then
		return nil
	end
	local _, stop = find(text, "^[+-]?%d+%.?%d*")
	if stop == nil then
		_, stop = find(text, "^[+-]?%.%d+")
		if stop == nil then
			return nil
		end
	end
	if stop == n then
		return "number", tonumber(text)
	end
	local after = byte(text, stop + 1)
	if after == 101 or after == 69 then
		if find(text, "^[+-]?%d+$", stop + 2) then
			return "number", tonumber(text)
		end
		return nil
	end
	local tail = sub(text, stop + 1 + space_at(text, stop + 1))
	if tail == "%" then
		return "number", tonumber(sub(text, 1, stop))
	end
	local factor = size_unit(tail)
	if factor then
		return "size", tonumber(sub(text, 1, stop)) * factor
	end
	-- A length of time or a moment begins with a digit, never with a sign.
	if first < 48 or first > 57 then
		return nil
	end
	local value
	if after == 58 then
		value = clock(text)
		if value then
			return "duration", value
		end
	elseif after == 45 then
		value = moment(text)
		if value then
			return "date", value
		end
	else
		value = duration(text)
		if value then
			return "duration", value
		end
	end
	return nil
end
M.scan = scan

-- The quantity a cell holds, `{ kind = "number"|"size"|"duration"|"date", value = n }`, in the
-- kind's base unit (bytes, seconds, milliseconds since 1970), or nil when it holds words.
function M.quantity(cell)
	local kind, value = scan(cell)
	if kind == nil then
		return nil
	end
	return { kind = kind, value = value }
end

-- Whether two quantities can be compared (see `comparable_kinds`).
function M.comparable(a, b)
	return comparable_kinds(a.kind, b.kind)
end

-- The kind most of a column's cells have, or "text": what the view aligns and charts by. Only
-- the first `sample` filled cells are read. A number counts for any kind, since a "0" is found
-- in a column of sizes.
function M.column_kind(cells, sample)
	sample = sample or 500
	local counts, seen = {}, {}
	local filled = 0
	for i = 1, #cells do
		local cell = cells[i]
		if not fold.is_blank(cell) then
			filled += 1
			local kind = scan(cell)
			if kind then
				if counts[kind] == nil then
					counts[kind] = 0
					seen[#seen + 1] = kind
				end
				counts[kind] += 1
			end
			if filled >= sample then
				break
			end
		end
	end
	if filled == 0 then
		return "text"
	end
	-- The first kind to have the most wins a tie, as the first one met.
	local best, most = "text", 0
	for _, kind in ipairs(seen) do
		if counts[kind] > most then
			best, most = kind, counts[kind]
		end
	end
	local numbers = best == "number" and 0 or (counts.number or 0)
	if (most + numbers) / filled >= 0.8 then
		return best
	end
	return "text"
end

-- A number as `String(Number(n.toPrecision(3)))` writes it: three significant digits (half
-- rounded up, as a person rounds) and no more than they need.
local function three_digits(n)
	if n ~= n then
		return "NaN"
	elseif n == math.huge then
		return "Infinity"
	elseif n == -math.huge then
		return "-Infinity"
	elseif n == 0 then
		return "0"
	end
	local written = string.format("%.40e", math.abs(n))
	local lead, rest, exponent = match(written, "^(%d)%.(%d+)e([+-]%d+)$")
	local scaled = tonumber(lead .. sub(rest, 1, 2))
	if byte(rest, 3) >= 53 then
		scaled += 1
	end
	local place = tonumber(exponent) + 1
	if scaled == 1000 then
		scaled, place = 100, place + 1
	end
	local digits = string.format("%d", scaled):gsub("0+$", "")
	local count = #digits
	local text
	if count <= place and place <= 21 then
		text = digits .. string.rep("0", place - count)
	elseif place > 0 and place <= 21 then
		text = sub(digits, 1, place) .. "." .. sub(digits, place + 1)
	elseif place > -6 and place <= 0 then
		text = "0." .. string.rep("0", -place) .. digits
	else
		local power = place - 1
		local mantissa = count == 1 and digits or (sub(digits, 1, 1) .. "." .. sub(digits, 2))
		text = mantissa .. "e" .. (power < 0 and "-" or "+") .. string.format("%d", math.abs(power))
	end
	return (n < 0 and "-" or "") .. text
end

local SIZE_UNITS = { "", "Ki", "Mi", "Gi", "Ti", "Pi" }
local DURATION_STEPS = { { "d", 86400 }, { "h", 3600 }, { "m", 60 }, { "s", 1 } }

-- A moment as `toISOString` writes it, cut to the date when it is a whole day and to the
-- second when it has no more.
local function write_moment(value)
	if value ~= value or value == math.huge or value == -math.huge or math.abs(value) > 8.64e15 then
		return three_digits(value)
	end
	local millis = value >= 0 and floor(value) or -floor(-value)
	local days = floor(millis / 86400000)
	local of_day = millis - days * 86400000
	local year, month, day = civil_from_days(days)
	local year_text
	if year >= 0 and year <= 9999 then
		year_text = string.format("%04d", year)
	else
		year_text = (year < 0 and "-" or "+") .. string.format("%06d", math.abs(year))
	end
	local date = string.format("%s-%02d-%02d", year_text, month, day)
	if of_day == 0 then
		return date
	end
	local seconds = of_day // 1000
	return string.format(
		"%sT%02d:%02d:%02dZ",
		date,
		seconds // 3600,
		seconds % 3600 // 60,
		seconds % 60
	)
end

-- A quantity as a person writes it in a query: what the column panel puts there.
function M.write_quantity(kind, value)
	if kind == "number" then
		return three_digits(value)
	elseif kind == "size" then
		local n, at = value, 1
		while math.abs(n) >= 1024 and at < #SIZE_UNITS do
			n /= 1024
			at += 1
		end
		if at == 1 then
			return three_digits(n) .. "B"
		end
		return three_digits(n) .. SIZE_UNITS[at]
	elseif kind == "duration" then
		for _, step in ipairs(DURATION_STEPS) do
			if math.abs(value) >= step[2] then
				return three_digits(value / step[2]) .. step[1]
			end
		end
		return string.format("%d", floor(value * 1000 + 0.5)) .. "ms"
	end
	return write_moment(value)
end

return M
