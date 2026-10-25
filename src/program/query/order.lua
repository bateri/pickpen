-- The order of rows: cells compared as quantities before words, words as text with their digit
-- runs as numbers, empty cells last either way. The order is the one `--sort` and the view's
-- headings share. `compare_ordered` and its parts say what the order is, a pair at a time;
-- `order` is the same order for a whole column, made fast: a column is read once, its
-- quantities are sorted on their numbers and its words on a key that is made to be compared
-- as plain bytes.

local fold = require("query.fold")
local values = require("query.values")

local M = {}

local byte, find, gsub, match, sub = string.byte, string.find, string.gsub, string.match, string.sub
local scan = values.scan
local is_blank = fold.is_blank

-- Text in order, with runs of digits by their number, without regard to case: `file9` before
-- `file10`. A plain loop, not a collator, so that the view and the program, on two machines,
-- put rows in one order. Gives a negative number, 0 or a positive one. Letters are compared by
-- their code points; a text that is no more than another's beginning comes first; texts that
-- differ only in case, or in the zeros before a number, are told apart by their bytes.
function M.compare_text(a, b)
	local x, y = fold.lower(a), fold.lower(b)
	local i, j, nx, ny = 1, 1, #x, #y
	while i <= nx and j <= ny do
		local cx, cy = byte(x, i), byte(y, j)
		if cx >= 48 and cx <= 57 and cy >= 48 and cy <= 57 then
			local _, ei = find(x, "^%d+", i)
			local _, ej = find(y, "^%d+", j)
			-- A run's zeros before its number do not count, but its last digit does.
			local _, zx = find(x, "^0+", i)
			local _, zy = find(y, "^0+", j)
			local si = zx and math.min(zx + 1, ei) or i
			local sj = zy and math.min(zy + 1, ej) or j
			local lx, ly = ei - si + 1, ej - sj + 1
			if lx ~= ly then
				return lx - ly
			end
			local dx, dy = sub(x, si, ei), sub(y, sj, ej)
			if dx ~= dy then
				return dx < dy and -1 or 1
			end
			i, j = ei + 1, ej + 1
		else
			if cx ~= cy then
				return cx - cy
			end
			i += 1
			j += 1
		end
	end
	local rest = (nx - i + 1) - (ny - j + 1)
	if rest ~= 0 then
		return rest
	end
	return a < b and -1 or a > b and 1 or 0
end
local compare_text = M.compare_text

-- A cell as the sort reads it, read once so that a long sort parses each cell once:
-- `{ text, empty, q }`, with `q` the cell's quantity or nil.
function M.sort_key(cell)
	local empty = is_blank(cell)
	return { text = cell, empty = empty, q = (not empty) and values.quantity(cell) or nil }
end

-- Two cells in order: quantities that compare as quantities, before words, which compare as
-- text; empty cells last.
function M.compare_keys(a, b)
	if a.empty or b.empty then
		return a.empty == b.empty and 0 or a.empty and 1 or -1
	end
	local qa, qb = a.q, b.q
	if qa and qb and values.comparable(qa, qb) then
		local d = qa.value - qb.value
		if d ~= 0 and d == d then
			return d
		end
		return compare_text(a.text, b.text)
	end
	if qa and not qb then
		return -1
	end
	if qb and not qa then
		return 1
	end
	if qa and qb then
		-- Kinds that cannot be compared (a size and a length of time) go by their names.
		return qa.kind < qb.kind and -1 or qa.kind > qb.kind and 1 or qa.value - qb.value
	end
	return compare_text(a.text, b.text)
end

-- The order `--sort` and the view's headings put rows in: empty cells last either way.
function M.compare_ordered(a, b, descending)
	if a.empty or b.empty then
		return a.empty == b.empty and 0 or a.empty and 1 or -1
	end
	local d = M.compare_keys(a, b)
	return descending and -d or d
end

-- A run of digits for the sort key: no zeros before the number, and before it a character
-- that says how long it is, so that a shorter number is the smaller whatever its digits. The
-- character is a digit above `0`, which keeps the run where a digit goes among the letters; a
-- run of nine digits or more begins with a 9 for each eight beyond the first eight.
local function digit_run(run)
	local digits = match(run, "^0*(%d.*)$")
	local count = #digits
	local lead = ""
	while count >= 9 do
		lead = lead .. "9"
		count -= 8
	end
	return lead .. string.char(48 + count) .. digits
end

-- A word as a key that plain byte order puts where `compare_text` puts it: the lower case with
-- its digit runs encoded, then (to tell what only differs in case) the word itself.
function M.text_key(cell)
	local lowered = fold.lower(cell)
	if find(lowered, "%d") then
		lowered = gsub(lowered, "%d+", digit_run)
	end
	return lowered .. "\1" .. cell
end
local text_key = M.text_key

-- A stable merge sort of a list of places, by `compare(a, b)` (a number; 0 keeps the input's
-- order). It is for a comparison that is no order a library sort may rely on, as the one that
-- reads a size against a length of time is not.
local function merge_sort(list, compare)
	local n = #list
	local src, dst = list, {}
	local width = 1
	while width < n do
		local start = 1
		while start <= n do
			local middle = math.min(start + width, n + 1)
			local stop = math.min(start + 2 * width, n + 1)
			local left, right, k = start, middle, start
			while left < middle and right < stop do
				if compare(src[right], src[left]) < 0 then
					dst[k] = src[right]
					right += 1
				else
					dst[k] = src[left]
					left += 1
				end
				k += 1
			end
			while left < middle do
				dst[k] = src[left]
				left, k = left + 1, k + 1
			end
			while right < stop do
				dst[k] = src[right]
				right, k = right + 1, k + 1
			end
			start += 2 * width
		end
		src, dst = dst, src
		width *= 2
	end
	return src
end

-- Whether the quantities of a column are all comparable with each other, from the kinds that
-- are among them. A number is comparable with a size and with a length of time, which are not
-- with each other; a moment is comparable with moments only.
local function one_scale(has)
	if has.date then
		return not (has.number or has.size or has.duration)
	end
	return not (has.size and has.duration)
end

-- The rows in the order of one column: a new list of the row numbers in `indices` (each a place
-- in `rows`, and `rows[i].cells[column]` the cell), quantities before words, empty cells last
-- either way, the rows that are equal in the order they came. `descending` reverses all but the
-- empty cells and the ties.
function M.order(rows, indices, column, descending)
	local n = #indices
	local cells, nums = {}, {}
	local quantities, words, blanks = {}, {}, {}
	local has = {}
	for p = 1, n do
		local cell = rows[indices[p]].cells[column] or ""
		cells[p] = cell
		if is_blank(cell) then
			nums[p] = 0
			blanks[#blanks + 1] = indices[p]
		else
			local kind, number = scan(cell)
			if kind then
				nums[p] = number
				has[kind] = true
				quantities[#quantities + 1] = p
			else
				nums[p] = 0
				words[#words + 1] = p
			end
		end
	end

	local out, k = {}, 0
	local function put(list)
		for i = 1, #list do
			k += 1
			out[k] = indices[list[i]]
		end
	end

	if one_scale(has) then
		if descending then
			table.sort(quantities, function(a, b)
				local va, vb = nums[a], nums[b]
				if va ~= vb then
					return va > vb
				end
				local ta, tb = cells[a], cells[b]
				if ta ~= tb then
					local c = compare_text(ta, tb)
					if c ~= 0 then
						return c > 0
					end
				end
				return a < b
			end)
		else
			table.sort(quantities, function(a, b)
				local va, vb = nums[a], nums[b]
				if va ~= vb then
					return va < vb
				end
				local ta, tb = cells[a], cells[b]
				if ta ~= tb then
					local c = compare_text(ta, tb)
					if c ~= 0 then
						return c < 0
					end
				end
				return a < b
			end)
		end
		local keys = {}
		for i = 1, #words do
			local p = words[i]
			keys[p] = text_key(cells[p])
		end
		if descending then
			table.sort(words, function(a, b)
				local ka, kb = keys[a], keys[b]
				if ka ~= kb then
					return ka > kb
				end
				return a < b
			end)
			put(words)
			put(quantities)
		else
			table.sort(words, function(a, b)
				local ka, kb = keys[a], keys[b]
				if ka ~= kb then
					return ka < kb
				end
				return a < b
			end)
			put(quantities)
			put(words)
		end
	else
		-- Cells that are quantities of kinds which cannot be compared: the pairwise order, on a
		-- sort that does not mind it is not transitive.
		local all = {}
		local sort_keys = {}
		for i = 1, #quantities do
			all[#all + 1] = quantities[i]
		end
		for i = 1, #words do
			all[#all + 1] = words[i]
		end
		table.sort(all)
		for i = 1, #all do
			sort_keys[all[i]] = M.sort_key(cells[all[i]])
		end
		local sign = descending and -1 or 1
		put(merge_sort(all, function(a, b)
			return sign * M.compare_keys(sort_keys[a], sort_keys[b])
		end))
	end
	for i = 1, #blanks do
		out[k + i] = blanks[i]
	end
	return out
end

-- The row numbers of the rows a compiled query keeps, in the order they are in: from the
-- rows named in `indices`, or from every row.
function M.filter(rows, compiled, indices)
	local out, k = {}, 0
	if indices then
		for i = 1, #indices do
			local row = indices[i]
			if compiled(rows[row]) then
				k += 1
				out[k] = row
			end
		end
	else
		for row = 1, #rows do
			if compiled(rows[row]) then
				k += 1
				out[k] = row
			end
		end
	end
	return out
end

return M
