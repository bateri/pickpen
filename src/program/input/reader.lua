-- Reading the pipeline's input as rows: what shape it has (unless a format is given), and each
-- record as it comes, so that a view opened on `tail -f` shows lines while they arrive.
--
-- The shape is read from the first lines, never the mode: whether pickpen is in a pipeline is
-- not a question this file asks. A record keeps the text it was read from (`raw`), which is
-- what goes out when the output has the input's shape.
--
-- The sink is a table of three functions, called as functions and not as methods:
--
--   sink.columns(names, heading)   the columns, the first time and whenever JSON brings a key
--                                  not seen before; for CSV and TSV with the heading's own text
--   sink.record(record)            { cells = { ... }, raw = "...", value = <JSON, if any> }
--   sink.problem(text)             something that could not be read as its shape; reading goes on

local delimited = require("input.delimited")
local detect = require("input.detect").detect
local document = require("input.document")
local jsonl = require("input.jsonl")
local lines = require("input.lines")
local columns = require("input.columns")

local M = {}

local find = string.find

-- How many lines, or bytes, the shape is read from before records flow.
local SAMPLE_LINES = 50
local SAMPLE_BYTES = 64 * 1024

local function parser_for(format, sink)
	if format == "lines" then
		return lines.new(sink)
	elseif format == "columns" then
		return columns.new(sink)
	elseif format == "csv" then
		return delimited.new(sink, ",")
	elseif format == "tsv" then
		return delimited.new(sink, "\t")
	elseif format == "jsonl" then
		return jsonl.new(sink)
	elseif format == "json" then
		return document.new(sink)
	end
	error("input: there is no shape called " .. tostring(format), 0)
end

-- How many line ends the text has, counting no further than `limit`.
local function count_lines(piece, limit)
	local n, pos = 0, 1
	while n < limit do
		local at = find(piece, "\n", pos, true)
		if not at then
			break
		end
		n += 1
		pos = at + 1
	end
	return n
end

local Reader = {}
Reader.__index = Reader

-- A reader that tells `sink` what it reads. `format` is the shape if it is known (then records
-- flow from the first piece), nil to read it from the first lines.
function M.new(sink, format)
	return setmetatable({
		sink = sink,
		wanted = format,
		-- The shape, nil until it is decided.
		format = nil,
		decided = false,
		ended = false,
		parser = nil,
		-- What came before the shape was decided: the pieces, their bytes, and their lines.
		held = {},
		held_count = 0,
		held_bytes = 0,
		held_lines = 0,
	}, Reader)
end

-- Text as it comes.
function Reader:feed(piece)
	if self.parser then
		self.parser:feed(piece)
		return
	end
	self.held_count += 1
	self.held[self.held_count] = piece
	self.held_bytes += #piece
	self.held_lines += count_lines(piece, SAMPLE_LINES - self.held_lines)
	if
		self.wanted ~= nil
		or self.held_bytes >= SAMPLE_BYTES
		or self.held_lines >= SAMPLE_LINES
	then
		self:decide()
	end
end

-- Whether a whole line has come, so that a slow input can be decided on what it has sent.
function Reader:has_line()
	return self.parser ~= nil or self.held_lines > 0
end

-- Settles the shape on what has come so far, and lets the records flow. Called when the sample
-- is full, at the end, and by a timer when the input is slow to come.
function Reader:decide()
	if self.decided then
		return
	end
	self.decided = true
	local sample = table.concat(self.held, "", 1, self.held_count)
	self.held, self.held_count = {}, 0
	self.format = self.wanted or detect(sample, self.ended)
	self.parser = parser_for(self.format, self.sink)
	self.parser:feed(sample)
end

-- The input has ended: what is left is read, and the last record is a record.
function Reader:finish()
	self.ended = true
	self:decide()
	self.parser:finish()
end

return M
