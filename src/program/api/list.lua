-- The calls that show the list: the start (`open`), a new query or order, the rows in sight
-- (`window`), one row whole (`row`) and the marks.
--
-- Positions are 1-based places in the list the person sees, and the generation (`gen`) says which
-- list: the page asks only for what it has seen, and a position asked in an older list is refused
-- (`stale`) and not answered with the wrong row.
--
-- This is api/'s: the files of api/ know the page, and input/, query/, output/ and state/ do not.

local pencere = require("pencere")
local call = require("api.call")
local p = require("api.params")
local summary = require("api.summary")
local version = require("version")

local M = {}

-- The most rows one `window` gives, and the longest cell it gives of a row: the page draws a cell
-- in a column's width and shows a row whole by asking for it (`row`).
local MOST_ROWS = 200
local LONGEST_CELL = 256
-- How long `open` waits for an input to end, if the page does not say.
local OPEN_WAIT = 0.3
-- How much of the program's stream one answer takes, as the stream counts it.
local MOST_BYTES = 512 * 1024

-- A cell cut to its first `LONGEST_CELL` characters, at a character boundary.
local function short(cell)
	if #cell <= LONGEST_CELL then
		return cell
	end
	local ok, cut = pcall(utf8.offset, cell, LONGEST_CELL + 1)
	if ok and cut == nil then
		-- Fewer characters than that: all of it.
		return cell
	end
	return string.sub(cell, 1, (ok and cut or LONGEST_CELL + 1) - 1)
end

local function given_of(options)
	return {
		input = options.given.input,
		field = options.given.field,
		format = options.given.format,
		output = options.given.output,
	}
end

function M.calls(session)
	local view, rows = session.view, session.table
	local calls = {}

	-- What the view starts from, as the command line set it, and the list as it is. A moment is
	-- given to the input first (`wait` seconds at most, a third of one if the page says no more),
	-- so that the page opens on the rows of an input that is quick, and not on nothing.
	local open_schema = p.object({ wait = p.optional(p.number(0, 60)) })
	calls.open = call.new(open_schema, function(args)
		local options = session.options
		local until_ = pencere.time.monotonic() + (args.wait or OPEN_WAIT)
		while not rows.done and pencere.time.monotonic() < until_ do
			pencere.time.sleep(0.01)
		end
		return {
			version = version,
			title = options.title,
			query = options.query,
			where = options.where,
			confirm = options.confirm,
			sort = options.sort
				and { column = options.sort.column, descending = options.sort.descending },
			preview = options.preview ~= nil,
			given = given_of(options),
			notice = session.notice,
			summary = summary.of(session),
		}
	end)

	-- A new query: what was typed and the terms the mouse wrote. Answered with the list that
	-- keeps the rows, unless a newer query came before it was done.
	local query_schema = p.object({
		typed = p.string(),
		chips = p.optional(p.array(p.string(), 64)),
	})
	calls.query = call.new(query_schema, function(args)
		view:set_query(args.typed, args.chips or {})
		if not view:refilter() then
			return { superseded = true }
		end
		return { summary = summary.of(session) }
	end)

	-- A column's order (none: the input's), or its reverse.
	local order_schema = p.object({
		column = p.optional(p.integer(1)),
		descending = p.optional(p.boolean()),
	})
	calls.order = call.new(order_schema, function(args)
		local order = nil
		if args.column ~= nil then
			if args.column > #rows.names then
				error({ code = "bad-params", message = "column: there is no such column" }, 0)
			end
			order = { column = args.column, descending = args.descending == true }
		end
		if not view:set_order(order) then
			return { superseded = true }
		end
		return { summary = summary.of(session) }
	end)

	-- The rows at these places of the list, each with whether it is marked.
	local window_schema = p.object({
		gen = p.optional(p.integer(0)),
		from = p.integer(1),
		count = p.integer(1, MOST_ROWS),
	})
	calls.window = call.new(window_schema, function(args)
		if args.gen ~= nil and args.gen ~= view.gen then
			return { gen = view.gen, stale = true }
		end
		local out, bytes = {}, 0
		local shown = view.shown
		for at = args.from, math.min(args.from + args.count - 1, #shown) do
			local id = shown[at]
			local cells, cost = {}, 8
			for column, cell in ipairs(rows.rows[id].cells) do
				cell = short(cell)
				cells[column] = cell
				cost += pencere.text.wire_size(cell) + 3
			end
			if #out > 0 and bytes + cost > MOST_BYTES then
				break
			end
			bytes += cost
			out[#out + 1] = { cells = cells, marked = view:is_marked(id) or nil }
		end
		return { gen = view.gen, from = args.from, rows = out, shown = #shown }
	end)

	-- One row whole, as the side panel and the copy want it.
	local row_schema = p.object({ gen = p.optional(p.integer(0)), pos = p.integer(1) })
	calls.row = call.new(row_schema, function(args)
		call.in_list(view, args.gen)
		local id = view.shown[args.pos]
		if id == nil then
			error({ code = "not-found", message = "there is no such row" }, 0)
		end
		local record = rows.rows[id]
		return { cells = record.cells, raw = record.raw, marked = view:is_marked(id) }
	end)

	-- Marks. `range` marks (or unmarks) positions `from` to `to`; the others are the whole list.
	local mark_schema = p.object({
		gen = p.optional(p.integer(0)),
		op = p.enum("range", "all", "none", "invert"),
		from = p.optional(p.integer(1)),
		to = p.optional(p.integer(1)),
		on = p.optional(p.boolean()),
	})
	calls.mark = call.new(mark_schema, function(args)
		call.in_list(view, args.gen)
		local on = args.on ~= false
		if args.op == "range" then
			if args.from == nil or args.to == nil then
				error({ code = "bad-params", message = "range: from and to" }, 0)
			end
			view:mark_range(math.min(args.from, args.to), math.max(args.from, args.to), on)
		elseif args.op == "all" then
			view:mark_shown(on)
		elseif args.op == "none" then
			view:unmark_all()
		else
			view:invert_shown()
		end
		session:changed()
		return { marked = view.marked_count, hidden = view:hidden_marks() }
	end)

	return calls
end

return M
