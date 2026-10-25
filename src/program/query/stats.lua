-- What the column panel shows of one column, worked out here because the view cannot hold the
-- rows: the kind of the column, how many of its cells are filled, its values by how often they
-- come, and the quantities of its cells as a chart of buckets with their least, middle and
-- greatest.

local fold = require("query.fold")
local values = require("query.values")

local M = {}

local scan = values.scan
local is_blank = fold.is_blank

-- The kind of a column of `rows` (`column_kind`), read from the first `sample` filled cells of
-- the rows, not of the rows a query keeps: the kind of a column does not move as a person types.
function M.kind_of(rows, column, sample)
	sample = sample or 500
	local cells, filled = {}, 0
	for i = 1, #rows do
		local cell = rows[i].cells[column] or ""
		if not is_blank(cell) then
			cells[#cells + 1] = cell
			filled += 1
			if filled >= sample then
				break
			end
		end
	end
	return values.column_kind(cells, sample)
end

-- The kind of each of the first `count` columns of `rows`.
function M.kinds(rows, count, sample)
	local kinds = {}
	for column = 1, count do
		kinds[column] = M.kind_of(rows, column, sample)
	end
	return kinds
end

-- Whether `a` is before `b` among the values shown: the more common first, and among the
-- equally common the one that is first in byte order.
local function before(count_a, value_a, count_b, value_b)
	return count_a > count_b or (count_a == count_b and value_a < value_b)
end

-- The `limit` values that come most, as `{ value, count }`, from the counts of every value.
local function most_common(counts, distinct, limit)
	local top = {}
	for i = 1, #distinct do
		local value = distinct[i]
		local count = counts[value]
		local last = top[#top]
		if #top < limit or (last and before(count, value, last.count, last.value)) then
			local at = #top + 1
			while at > 1 and before(count, value, top[at - 1].count, top[at - 1].value) do
				top[at] = top[at - 1]
				at -= 1
			end
			top[at] = { value = value, count = count }
			if #top > limit then
				top[#top] = nil
			end
		end
	end
	return top
end

-- The chart of a column's quantities: the least, the middle (the one at half of the sorted
-- list), the greatest, and `buckets` buckets of equal width, each `{ from, to, count }`. Times,
-- sizes and counts are often spread over orders of magnitude (most requests take milliseconds,
-- a few seconds): when the greatest is a hundred times the least, which is above 0, the
-- buckets are equal in logarithms, so that the many small values are not one bar and the few
-- large ones are still seen (`log`). `low` and `span` are the chart's left end and width in the
-- chart's own scale, which `place` and `value_at` turn to and from a value.
local function chart(numbers, count)
	table.sort(numbers)
	local least, greatest = numbers[1], numbers[#numbers]
	local log = least > 0 and greatest / least >= 100
	local function scale(v)
		return log and math.log(v) or v
	end
	local low = scale(least)
	local span = scale(greatest) - low
	if span == 0 or span ~= span then
		span = 1
	end
	local buckets = {}
	for i = 1, count do
		buckets[i] = { count = 0 }
	end
	for i = 1, #numbers do
		local at = math.floor((scale(numbers[i]) - low) / span * count) + 1
		local bucket = buckets[math.min(count, at)]
		bucket.count += 1
	end
	local result = {
		min = least,
		max = greatest,
		median = numbers[#numbers // 2 + 1],
		log = log,
		low = low,
		span = span,
		buckets = buckets,
	}
	for i = 1, count do
		buckets[i].from = M.value_at(result, (i - 1) / count)
		buckets[i].to = M.value_at(result, i / count)
	end
	return result
end

-- Where a value is across the chart, from 0 to 1.
function M.place(stats, value)
	local scaled = stats.log and math.log(value) or value
	return (scaled - stats.low) / stats.span
end

-- The value at a place across the chart, from 0 to 1.
function M.value_at(stats, place)
	local scaled = stats.low + place * stats.span
	return stats.log and math.exp(scaled) or scaled
end

-- What the panel shows of the `column` of the rows named in `indices` (row numbers in `rows`):
--
--   kind       "number", "size", "duration", "date" or "text": options.kind, else the column's
--              own (see `kind_of`)
--   filled     how many of the rows have something in the cell; empty, how many have not
--   distinct   how many different cells there are (an empty cell is one, written "")
--   top        the cells that come most, `{ value, count }`, the most common first
--   more       whether there are cells beyond the ones in `top`
--   quantities, buckets, min, median, max, log, low, span
--              for a column of a kind other than "text", the cells that are quantities of its
--              kind (or numbers) and the chart of them (see `chart`); nil when there are none
--
-- options: `top` (how many values; 40 for words and 12 otherwise), `buckets` (36), `kind`,
-- `sample` (500, the cells `kind_of` reads).
function M.column(rows, indices, column, options)
	options = options or {}
	local kind = options.kind or M.kind_of(rows, column, options.sample)
	local limit = options.top or (kind == "text" and 40 or 12)
	local counts, distinct = {}, {}
	local numbers = {}
	local filled, empty = 0, 0
	local charted = kind ~= "text"
	for i = 1, #indices do
		local cell = rows[indices[i]].cells[column] or ""
		local seen = counts[cell]
		if seen then
			counts[cell] = seen + 1
		else
			counts[cell] = 1
			distinct[#distinct + 1] = cell
		end
		if is_blank(cell) then
			empty += 1
		else
			filled += 1
			if charted then
				local found, number = scan(cell)
				-- A value that is no finite number cannot be placed on a chart.
				if
					found
					and (found == kind or found == "number")
					and number == number
					and number ~= math.huge
					and number ~= -math.huge
				then
					numbers[#numbers + 1] = number
				end
			end
		end
	end
	local top = most_common(counts, distinct, limit)
	local result = {
		kind = kind,
		filled = filled,
		empty = empty,
		distinct = #distinct,
		top = top,
		more = #distinct > #top,
	}
	if charted and #numbers > 0 then
		result.quantities = #numbers
		for key, value in pairs(chart(numbers, options.buckets or 36)) do
			result[key] = value
		end
	end
	return result
end

return M
