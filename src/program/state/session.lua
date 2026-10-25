-- Everything the program holds while a person chooses: what the command line asked for, the rows
-- read, the list a person looks at, and the answer when there is one. The page's calls are
-- answered from it (`api/`), and it knows nothing of them: those who want to hear that something
-- changed ask to be told (`session:listen`).

local pencere = require("pencere")
local input = require("input")
local json = require("input.json")
local query = require("query")
local table_ = require("state.table")
local view = require("state.view")

-- How often a list in an order takes the rows that came into their places, at most.
local RESORT_EVERY = 0.25

-- A table this small is filtered again in the turn that changed it; a bigger one is, a moment
-- later, in slices.
local SMALL = 20000

local M = {}

local Session = {}
Session.__index = Session

-- `options` are the command line's, as `app.lua` read them.
function M.new(options)
	local rows = table_.new()
	local self = setmetatable({
		options = options,
		table = rows,
		listeners = {},
		-- { kind = "chosen", ids =, shape = } or { kind = "cancelled" }, once the person has
		-- answered.
		answer = nil,
		-- Said to the person, in the page: a sort that names no column.
		notice = nil,
		-- The preview that is running, to be ended when the cursor has moved on.
		previewing = nil,
	}, Session)
	self.view = view.new(rows, {
		confirm = options.confirm,
		rule = options.where,
	})
	rows.listener = {
		columns = function()
			self:columns_changed()
		end,
	}
	-- What the input is read into: the rows, and which shape it turned out to have.
	local base = rows:sink()
	self.reader = input.Reader.new({
		columns = function(names, heading)
			rows.format = self.reader.format
			base.columns(names, heading)
		end,
		record = base.record,
		problem = base.problem,
	}, options.input)
	self.view:set_query(options.query, {})
	return self
end

-- Called with no arguments whenever something the page shows changed.
function Session:listen(listener)
	self.listeners[#self.listeners + 1] = listener
end

function Session:changed()
	for _, listener in ipairs(self.listeners) do
		listener()
	end
end

-- The columns are known, or one more is.
function Session:columns_changed()
	self.view:columns_changed()
	self:apply_sort()
	-- The list is made again against them, once the rows that came with them are in.
	self.needs_refilter = true
end

-- The order the command line asked for waits for the columns it names. A name that is no column's
-- once the input has ended is said to the person.
function Session:apply_sort()
	local sort = self.options.sort
	if sort == nil or self.sorted then
		return
	end
	local column = query.column_named(self.table.names, sort.column)
	if column ~= nil then
		self.view.order = { column = column, descending = sort.descending }
		self.sorted = true
	elseif self.table.done then
		self.notice = "There is no column named " .. json.encode(sort.column) .. " to sort by"
		self.sorted = true
	end
end

-- The shape of what goes out: the columns the person picked in the page, or the command line's.
function Session:shape_of(fields)
	if fields ~= nil and #fields > 0 then
		return { kind = "fields", names = fields }
	end
	return self.options.shape
end

-- Rows came in, or the list has to be made again: the list takes them, and the page is told.
function Session:settle()
	local rows, view_ = self.table, self.view
	rows.format = self.reader.format
	view_:take()
	if self.needs_refilter then
		self.needs_refilter = false
		if #rows.rows <= SMALL then
			view_:refilter()
		else
			pencere.time.after(0, function()
				view_:refilter()
				self:changed()
			end)
		end
	end
	if view_.unsorted and self.resorting == nil then
		self.resorting = pencere.time.after(RESORT_EVERY, function()
			self.resorting = nil
			view_:refilter()
			self:changed()
		end)
	end
	self:changed()
end

-- A piece of the input.
function Session:feed(bytes)
	self.reader:feed(bytes)
	self:settle()
end

-- The input is slow to come: its shape is settled on the lines it has sent.
function Session:decide()
	self.reader:decide()
	self:settle()
end

function Session:end_input()
	self.reader:finish()
	self.table:finish()
	self:apply_sort()
	self:settle()
end

-- Whether the program has been given an answer to go on with.
function Session:answered()
	return self.answer ~= nil
end

function Session:choose(ids, shape)
	self.answer = { kind = "chosen", ids = ids, shape = shape }
end

function Session:cancel()
	self.answer = { kind = "cancelled" }
end

return M
