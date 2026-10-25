-- The rows read so far, which a person looks at while the input is still coming in: the columns,
-- the records, whether the input has ended, and what could not be read. It is the sink a reader
-- (`input`) writes into, and it knows nothing of the page.
--
-- Rows are held by the program and not by the page, because a pipeline can carry hundreds of
-- thousands of them and a page is a small sandbox: it asks for the few rows in sight.

local utf8_len = utf8.len

local M = {}

-- The most rows a person is given. Reading stops there, and the page says so: nobody looks
-- through more, and the memory of the program is a thing too.
M.MAX_ROWS = 200000

-- The longest cell kept; a longer one is cut, and the page says some were.
M.MAX_CELL = 16384

-- How many of the first rows the shape of the columns (their widths, their kinds) is read from.
M.SAMPLE = 300

local Table = {}
Table.__index = Table

function M.new()
	return setmetatable({
		names = {},
		heading = nil,
		format = nil,
		rows = {},
		done = false,
		capped = false,
		cut = false,
		problems = {},
		-- Moves whenever the columns change; a page that holds them asks again when it does.
		columns_version = 0,
		-- For each column, the longest cell of the first rows, in characters: what the page
		-- sizes the column by.
		longest = {},
		-- `columns()` is called when the columns were set; the reader of the rows tells the rest.
		listener = nil,
	}, Table)
end

local function characters(text)
	return utf8_len(text) or #text
end

-- The widths follow the first rows as they come.
local function widen(self, record, at)
	if at > M.SAMPLE then
		return
	end
	local longest = self.longest
	for column, cell in ipairs(record.cells) do
		local length = characters(cell)
		if length > (longest[column] or 0) then
			longest[column] = length
		end
	end
end

-- The columns, the first time and whenever a JSON key not seen before arrives.
function Table:set_columns(names, heading)
	self.names = names
	if heading ~= nil then
		self.heading = heading
	end
	self.columns_version += 1
	for column, name in ipairs(names) do
		local length = characters(name)
		if length > (self.longest[column] or 0) then
			self.longest[column] = length
		end
	end
	-- A column that came late is looked at in the rows that came before it.
	for at = 1, math.min(#self.rows, M.SAMPLE) do
		widen(self, self.rows[at], at)
	end
	if self.listener then
		self.listener.columns()
	end
end

function Table:add(record)
	if self.capped then
		return
	end
	local rows = self.rows
	if #rows >= M.MAX_ROWS then
		self.capped = true
		return
	end
	local cells = record.cells
	for column, cell in ipairs(cells) do
		if #cell > M.MAX_CELL then
			-- Cut at a character boundary, so that the rest is still text.
			local cut = string.sub(cell, 1, M.MAX_CELL)
			while #cut > 0 and utf8_len(cut) == nil do
				cut = string.sub(cut, 1, #cut - 1)
			end
			cells[column] = cut
			self.cut = true
		end
	end
	rows[#rows + 1] = record
	widen(self, record, #rows)
end

function Table:add_problem(text)
	self.problems[#self.problems + 1] = text
end

function Table:finish()
	self.done = true
end

-- What a reader writes into: three functions, as `input` wants them.
function Table:sink()
	return {
		columns = function(names, heading)
			self:set_columns(names, heading)
		end,
		record = function(record)
			self:add(record)
		end,
		problem = function(text)
			self:add_problem(text)
		end,
	}
end

-- The table as `output` reads it.
function Table:source()
	return { format = self.format, names = self.names, heading = self.heading }
end

return M
