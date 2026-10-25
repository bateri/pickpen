-- What a person is looking at of the table: the query that keeps some of the rows, the order
-- they are in, which are marked, and the rule that marked them. Rows are named by their place in
-- the table (an id) and, in the list the person sees, by their position in `shown`.
--
-- The page holds only the rows in sight and names rows by position, so every position is tied to
-- a generation: `gen` moves whenever the same position would name another row (a new query, a
-- new order), and a call made in an older one is refused (`stale`) instead of marking the wrong
-- row. Rows that come at the end of the list do not move it.
--
-- Filtering a table of hundreds of thousands of rows is done in slices, between which the
-- program answers its other calls: a newer query takes over from an older one that is still
-- being worked out.

local pencere = require("pencere")
local query = require("query")

local M = {}

-- How many rows are tested between two looks at what else is waiting.
local SLICE = 20000

local View = {}
View.__index = View

-- `options`: `typed` (the query at the start), `chips`, `sort` ({ column = name, descending }),
-- `confirm`, `rule` (the `--where` that marks the rows when a person is to confirm them).
function M.new(table, options)
	local self = setmetatable({
		table = table,
		options = options,
		typed = "",
		chips = {},
		-- The terms the query has, each with where it came from (a chip or what was typed).
		terms = {},
		compiled = function()
			return true
		end,
		order = nil,
		-- The ids of the rows the query keeps, in the order shown, and where each one is.
		shown = {},
		where = {},
		gen = 1,
		-- Rows up to this id have been tested by the query.
		caught = 0,
		marked = {},
		marked_count = 0,
		token = 0,
		-- Rows came in an order that is sorted: they are taken in at most a few times a second.
		unsorted = false,
		rule = nil,
		rule_source = nil,
		rule_columns = -1,
		columns_seen = -1,
	}, View)
	if options.confirm and options.rule ~= nil then
		self.rule_source = options.rule
	end
	return self
end

-- ---- the query -----------------------------------------------------------------------------

-- The terms of what was typed and of the chips, tested together. Gives the names the query
-- compares that are no column's.
function View:set_query(typed, chips)
	self.typed, self.chips = typed, chips or {}
	local names = self.table.names
	local terms, all, unknown, seen = {}, {}, {}, {}
	local function take(source, chip)
		local parsed = query.parse(source, names)
		for _, term in ipairs(parsed.terms) do
			terms[#terms + 1] = { term = term, chip = chip, source = source }
			all[#all + 1] = term
		end
		for _, name in ipairs(query.unknown_names(source, names)) do
			if not seen[name] then
				seen[name] = true
				unknown[#unknown + 1] = name
			end
		end
	end
	for _, chip in ipairs(self.chips) do
		take(chip, true)
	end
	take(typed, false)
	self.terms = terms
	self.compiled = query.compile({ terms = all, empty = #all == 0 })
	self.unknown = unknown
	self.columns_seen = self.table.columns_version
	return unknown
end

-- The query as a person would write it again: the chips, then what was typed.
function View:source()
	local parts = {}
	for _, chip in ipairs(self.chips) do
		parts[#parts + 1] = chip
	end
	local typed = self.typed:gsub("^%s+", ""):gsub("%s+$", "")
	if typed ~= "" then
		parts[#parts + 1] = typed
	end
	return table.concat(parts, " ")
end

-- ---- the list --------------------------------------------------------------------------------

local function breathe()
	if coroutine.isyieldable() then
		pencere.time.sleep(0)
	end
end

local function place(self, ids)
	local where = {}
	for at = 1, #ids do
		where[ids[at]] = at
	end
	self.shown, self.where = ids, where
	self.gen += 1
end

-- Keeps the rows the query keeps, in the order asked for. False when a newer call took over
-- before this one was done (it has nothing to say, the newer one will).
function View:refilter()
	self.token += 1
	local mine = self.token
	local rows = self.table.rows
	local test = self.compiled
	local ids, count = {}, 0
	local at = 1
	while at <= #rows do
		local stop = math.min(at + SLICE - 1, #rows)
		for id = at, stop do
			if test(rows[id]) then
				count += 1
				ids[count] = id
			end
		end
		at = stop + 1
		if at <= #rows then
			breathe()
			if self.token ~= mine then
				return false
			end
		end
	end
	self.caught = #rows
	if self.order then
		ids = query.order(rows, ids, self.order.column, self.order.descending)
	end
	self.unsorted = false
	place(self, ids)
	return true
end

-- A new order (nil: the input's), and the rows in it.
function View:set_order(order)
	self.order = order
	return self:refilter()
end

-- ---- rows that come ----------------------------------------------------------------------------

-- The columns were set again (a JSON key not seen before): the query and the rule are read again
-- against them, and the list is made again.
function View:columns_changed()
	self:set_query(self.typed, self.chips)
	if self.rule_source ~= nil then
		self.rule = query.compile(query.parse(self.rule_source, self.table.names))
		self.rule_columns = self.table.columns_version
	end
end

-- Rows up to the last one arrived. A rule marks the ones it matches; the ones the query keeps
-- join the list, at its end, or, in an order, wait for the list to be made again. Gives the
-- number of rows that joined the list at its end.
function View:take()
	local rows = self.table.rows
	if self.caught >= #rows then
		return 0
	end
	local from = self.caught + 1
	if self.rule_source ~= nil then
		if self.rule == nil or self.rule_columns ~= self.table.columns_version then
			self.rule = query.compile(query.parse(self.rule_source, self.table.names))
			self.rule_columns = self.table.columns_version
		end
		for id = from, #rows do
			if self.rule(rows[id]) and not self.marked[id] then
				self.marked[id] = true
				self.marked_count += 1
			end
		end
	end
	if self.order ~= nil then
		-- A list in an order takes the new rows into their places a few times a second, not
		-- for each one.
		self.unsorted = true
		self.caught = #rows
		return 0
	end
	local test, shown, where = self.compiled, self.shown, self.where
	local added = 0
	for id = from, #rows do
		if test(rows[id]) then
			shown[#shown + 1] = id
			where[id] = #shown
			added += 1
		end
	end
	self.caught = #rows
	return added
end

-- ---- marks -------------------------------------------------------------------------------------

local function set_mark(self, id, on)
	local was = self.marked[id] == true
	if on and not was then
		self.marked[id] = true
		self.marked_count += 1
	elseif was and not on then
		self.marked[id] = nil
		self.marked_count -= 1
	end
end

-- Marks (or unmarks) the rows at positions `from` to `to` of the list.
function View:mark_range(from, to, on)
	local shown = self.shown
	from, to = math.max(from, 1), math.min(to, #shown)
	for at = from, to do
		set_mark(self, shown[at], on)
	end
end

function View:mark_shown(on)
	self:mark_range(1, #self.shown, on)
end

function View:unmark_all()
	self.marked = {}
	self.marked_count = 0
end

function View:invert_shown()
	for _, id in ipairs(self.shown) do
		set_mark(self, id, not self.marked[id])
	end
end

-- How many of the marked rows the query hides.
function View:hidden_marks()
	if self.marked_count == 0 then
		return 0
	end
	local hidden, where = 0, self.where
	for id in pairs(self.marked) do
		if where[id] == nil then
			hidden += 1
		end
	end
	return hidden
end

-- ---- what goes out ----------------------------------------------------------------------------

-- The ids the rows to send are, in the order they go out: the marked ones in the order shown (or
-- the input's, when no order is asked for), or the row under the cursor.
function View:to_send(cursor)
	if self.marked_count > 0 then
		local ids = {}
		for id in pairs(self.marked) do
			ids[#ids + 1] = id
		end
		table.sort(ids)
		if self.order then
			ids = query.order(self.table.rows, ids, self.order.column, self.order.descending)
		end
		return ids
	end
	if self.options.confirm or cursor == nil then
		return {}
	end
	local id = self.shown[cursor]
	return id and { id } or {}
end

-- The rows that are the rule's, in the input's order: what `--where` alone would send.
function View:matching(source)
	local rule = query.compile(query.parse(source, self.table.names))
	return query.filter(self.table.rows, rule)
end

function View:is_marked(id)
	return self.marked[id] == true
end

return M
