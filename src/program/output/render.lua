-- What goes out on stdout for the rows chosen. One function writes it, and the view's picture of
-- what will go out is drawn by the same function, so that the two never differ.
--
-- In the input's shape, a row goes out as the text it was read from: lines and columns as their
-- lines (a table's heading stays behind, so that `| xargs` is given only rows), CSV and TSV
-- after their heading, JSON lines as their lines, and a JSON document as an array of the
-- elements chosen. `--field`, `--format` and `--output` shape it otherwise.
--
-- A shape is `{ kind = "input" }`, `{ kind = "fields", names = }`, `{ kind = "template",
-- template = }` or `{ kind = "as", format = "csv" | "tsv" | "json" | "jsonl" }`; a source is
-- `{ format =, names =, heading = }` (what was read, and the names of the columns). A record
-- is `{ cells =, raw =, value = }`. Every line it writes ends with a line end.

local pencere = require("pencere")
local formats = require("output.formats")
local json = require("input.json")
local part = require("output.part")
local template = require("output.template")

local M = {}

local concat = table.concat

local SEPARATORS = { csv = ",", tsv = "\t" }
local WRITERS = { csv = formats.csv_cell, tsv = formats.tsv_cell }

-- The lines, each ended; nothing for no lines.
local function lines_of(items)
	if #items == 0 then
		return ""
	end
	return concat(items, "\n") .. "\n"
end

-- A JSON document of the texts of its elements, one to a line.
local function document_of(items)
	return "[\n  " .. concat(items, ",\n  ") .. "\n]\n"
end

-- The line that names the columns in CSV and TSV, without its line end.
local function names_line(format, names)
	return formats.row(names, #names, WRITERS[format], SEPARATORS[format], {})
end

-- The heading a CSV or TSV input is written after: as it was read, else its names.
local function heading_of(source)
	return source.heading or concat(source.names, SEPARATORS[source.format])
end

local function converted(format, records, source)
	local names = source.names
	if format == "csv" or format == "tsv" then
		local write, separator, count = WRITERS[format], SEPARATORS[format], #names
		local into = {}
		local items = { names_line(format, names) }
		for at, record in ipairs(records) do
			items[at + 1] = formats.row(record.cells, count, write, separator, into)
		end
		return lines_of(items)
	end
	local keys = formats.keys(names)
	local items = {}
	for at, record in ipairs(records) do
		items[at] = json.encode(formats.value(record, keys))
	end
	-- JSON is text, and a byte that is not text cannot be written in it: it becomes U+FFFD, as
	-- a reader that decodes the input would have had it. (Every other shape copies the bytes.)
	if format == "jsonl" then
		return pencere.text.lossy(lines_of(items))
	end
	return pencere.text.lossy(document_of(items))
end

local function in_input_shape(records, source)
	local format = source.format
	if format == "csv" or format == "tsv" then
		local items = { heading_of(source) }
		for at, record in ipairs(records) do
			items[at + 1] = record.raw
		end
		return lines_of(items)
	end
	local items = {}
	for at, record in ipairs(records) do
		items[at] = record.raw
	end
	if format == "json" then
		return document_of(items)
	end
	return lines_of(items)
end

-- The rows as they go out; nothing at all for no rows.
function M.render(records, shape, source)
	if #records == 0 then
		return ""
	end
	local kind = shape.kind
	if kind == "fields" then
		local readers, into = {}, {}
		for place, name in ipairs(shape.names) do
			readers[place] = part.reader(name, source)
		end
		local items = {}
		for at, record in ipairs(records) do
			for place, read in ipairs(readers) do
				into[place] = read(record) or ""
			end
			items[at] = concat(into, "\t")
		end
		return lines_of(items)
	elseif kind == "template" then
		local fill, items = template.compile(shape.template, source), {}
		for at, record in ipairs(records) do
			items[at] = fill(record)
		end
		return lines_of(items)
	elseif kind == "as" then
		return converted(shape.format, records, source)
	end
	return in_input_shape(records, source)
end

-- Whether rows can be written one by one as they come, rather than all at the end.
function M.streams(shape, format)
	if shape.kind == "as" then
		return shape.format ~= "json"
	end
	if shape.kind == "input" then
		return format ~= "json"
	end
	return true
end

-- What goes ahead of the first row when rows are written one by one.
function M.head(shape, source)
	if shape.kind == "as" and (shape.format == "csv" or shape.format == "tsv") then
		return names_line(shape.format, source.names) .. "\n"
	end
	if shape.kind == "input" and (source.format == "csv" or source.format == "tsv") then
		return heading_of(source) .. "\n"
	end
	return ""
end

-- One row, as it goes out after `head` when rows are written one by one.
function M.one(record, shape, source)
	if shape.kind == "as" and (shape.format == "csv" or shape.format == "tsv") then
		local row = formats.row(
			record.cells,
			#source.names,
			WRITERS[shape.format],
			SEPARATORS[shape.format],
			{}
		)
		return row .. "\n"
	end
	if shape.kind == "input" and (source.format == "csv" or source.format == "tsv") then
		return record.raw .. "\n"
	end
	return M.render({ record }, shape, source)
end

return M
