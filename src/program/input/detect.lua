-- The shape of an input, from its first lines: JSON (a line that is a value, or a document), a
-- table with tabs or commas, a table lined up with spaces, or lines of text.

local columns = require("input.columns")
local document = require("input.document")
local json = require("input.json")
local plain = require("input.plain").plain
local text = require("input.text")

local M = {}

local byte, find, sub = string.byte, string.find, string.sub

-- The complete lines of a sample, plain, without the blank ones: the last piece of the text is
-- one only when the input has ended.
local function sample_lines(sample, ended)
	local found, n, pos = {}, 0, 1
	while true do
		local stop = find(sample, "\n", pos, true)
		if not stop and not ended then
			break
		end
		local line = sub(sample, pos, stop and (stop - 1) or #sample)
		if byte(line, -1) == 13 then
			line = sub(line, 1, -2)
		end
		line = plain(line)
		if not text.is_blank(line) then
			n += 1
			found[n] = line
		end
		if not stop then
			break
		end
		pos = stop + 1
	end
	return found
end

-- How many times `what` (one byte, as a plain text) comes in the line.
local function count_of(line, what)
	local n, pos = 0, 1
	while true do
		local at = find(line, what, pos, true)
		if not at then
			return n
		end
		n += 1
		pos = at + 1
	end
end

-- Lines joined where a quoted field holds a line break: the records of CSV, for telling the shape.
local function csv_records(found)
	local records, open, odd = {}, nil, false
	for _, line in ipairs(found) do
		open = open and (open .. "\n" .. line) or line
		if count_of(line, '"') % 2 == 1 then
			odd = not odd
		end
		if not odd then
			records[#records + 1] = open
			open = nil
		end
	end
	if open then
		records[#records + 1] = open
	end
	return records
end

-- How many fields a record of CSV has: for telling the shape.
local function csv_fields(record)
	if not find(record, '"', 1, true) then
		return count_of(record, ",") + 1
	end
	local fields, empty, quoted = 1, true, false
	local at, len = 1, #record
	while at <= len do
		local c = byte(record, at)
		if quoted then
			if c == 34 and byte(record, at + 1) == 34 then
				empty = false
				at += 1
			elseif c == 34 then
				quoted = false
			else
				empty = false
			end
		elseif c == 34 and empty then
			quoted = true
		elseif c == 44 then
			fields += 1
			empty = true
		else
			empty = false
		end
		at += 1
	end
	return fields
end

-- The shape of an input, from its first lines. `ended` says the text is all there is (a last
-- line without its ending is a line then).
function M.detect(sample, ended)
	if ended == nil then
		ended = true
	end
	local found = sample_lines(sample, ended)
	if found[1] == nil then
		return "lines"
	end
	local first = text.trim(found[1])
	local b = byte(first, 1)
	if b == 123 or b == 91 then
		local value = json.parse(first)
		local is_object = json.is_object(value)
		-- One object alone, holding the rows (`{"items": [...]}`, as an API answers): a document.
		if is_object and ended and #found == 1 and document.rows_inside(value) ~= nil then
			return "json"
		end
		if is_object then
			return "jsonl"
		end
		if json.is_array(value) then
			return "json"
		end
		if
			first == "{"
			or first == "["
			or find(first, '^%[%s*[{%["]')
			or find(first, '^{%s*"')
		then
			return "json"
		end
	end
	if #found < 2 then
		return "lines"
	end
	local tabs = count_of(found[1], "\t")
	local same = tabs >= 1
	for i = 2, same and #found or 0 do
		if count_of(found[i], "\t") ~= tabs then
			same = false
			break
		end
	end
	if same then
		return "tsv"
	end
	local records = csv_records(found)
	local commas = csv_fields(records[1])
	same = commas >= 2 and not find(found[1], "  ", 1, true)
	for i = 2, same and #records or 0 do
		if csv_fields(records[i]) ~= commas then
			same = false
			break
		end
	end
	if same then
		return "csv"
	end
	if columns.looks_like_heading(found[1]) then
		local rest = {}
		for i = 2, #found do
			rest[i - 1] = found[i]
		end
		if #columns.layout_of(found[1], rest).names >= 2 then
			return "columns"
		end
	end
	return "lines"
end

return M
