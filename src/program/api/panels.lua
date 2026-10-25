-- The calls behind the side panel: what a column holds (`column`), the term a click on a value
-- writes (`term`), what will go out and the command line that does it again (`output`), and the
-- preview of the row the cursor is on (`preview`).
--
-- This is api/'s: the files of api/ know the page, and input/, query/, output/ and state/ do not.

local pencere = require("pencere")
local again = require("api.again")
local call = require("api.call")
local output = require("output")
local p = require("api.params")
local query = require("query")

local M = {}

-- How many rows the picture of what goes out shows at most: the rest are counted.
local MOST_OUTPUT_ROWS = 1000
-- How many bars the chart of a column has, and how many values the panel lists.
local BUCKETS = 36

local fields_schema = p.optional(p.array(p.string(), 200))

function M.calls(session)
	local view, rows = session.view, session.table
	local calls = {}

	local function column_of(number)
		if number > #rows.names then
			error({ code = "bad-params", message = "column: there is no such column" }, 0)
		end
		return number
	end

	-- A column of the rows the query keeps: its values by how often they come, and a chart of
	-- its quantities. Every value comes with the term that keeps the rows that have it, and every
	-- edge of a bar with the quantity as a query writes it, so that a click or a drag is a term
	-- the program wrote, with its own quoting.
	calls.column = call.new(
		p.object({ gen = p.optional(p.integer(0)), column = p.integer(1) }),
		function(args)
			call.in_list(view, args.gen)
			local column = column_of(args.column)
			local name = rows.names[column]
			local stats = query.stats.column(rows.rows, view.shown, column, { buckets = BUCKETS })
			for _, entry in ipairs(stats.top) do
				entry.term = query.quote_name(name) .. "=" .. query.quote_value(entry.value)
				entry.not_term = query.quote_name(name) .. "!=" .. query.quote_value(entry.value)
			end
			if stats.buckets then
				local edges = {}
				for at, bucket in ipairs(stats.buckets) do
					edges[at] = query.write_quantity(stats.kind, bucket.from)
					if at == #stats.buckets then
						edges[at + 1] = query.write_quantity(stats.kind, stats.max)
					end
				end
				stats.edges = edges
				stats.name = query.quote_name(name)
			end
			stats.column = column
			return stats
		end
	)

	-- The term for a column and a value, as a click on it writes it.
	calls.term = call.new(
		p.object({
			column = p.integer(1),
			value = p.string(),
			negate = p.optional(p.boolean()),
		}),
		function(args)
			local name = rows.names[column_of(args.column)]
			local op = args.negate and "!=" or "="
			return { term = query.quote_name(name) .. op .. query.quote_value(args.value) }
		end
	)

	-- What would go out for the rows that are marked (or the one under the cursor), by the same
	-- function that writes it, with the command line that does it again and whether it does.
	calls.output = call.new(
		p.object({
			gen = p.optional(p.integer(0)),
			cursor = p.optional(p.integer(1)),
			fields = fields_schema,
		}),
		function(args)
			call.in_list(view, args.gen)
			local shape = session:shape_of(args.fields)
			local problem = output.problem_of(shape, rows.names)
			local line = again.of(session, args.fields)
			if problem then
				return { problem = problem, again = line }
			end
			local ids = view:to_send(args.cursor)
			local records = {}
			for at = 1, math.min(#ids, MOST_OUTPUT_ROWS) do
				records[at] = rows.rows[ids[at]]
			end
			return {
				text = pencere.text.lossy(output.render(records, shape, rows:source())),
				count = #ids,
				truncated = #ids > MOST_OUTPUT_ROWS,
				again = line,
			}
		end
	)

	if session.options.preview ~= nil then
		-- What the preview command prints for a row. One at a time: the cursor has moved on from
		-- the last one, or the page gave it up.
		calls.preview = call.new(
			p.object({
				gen = p.optional(p.integer(0)),
				pos = p.integer(1),
				width = p.optional(p.integer(10, 1000)),
			}),
			function(args, running)
				call.in_list(view, args.gen)
				local id = view.shown[args.pos]
				local record = id and rows.rows[id]
				if record == nil then
					error({ code = "not-found", message = "There is no such row" }, 0)
				end
				if session.previewing then
					session.previewing:cancel()
					session.previewing = nil
				end
				local command = output.command_for(session.options.preview, record, rows:source())
				local result
				local handle = output.preview.run(command, args.width or 100, function(done)
					result = done
				end)
				session.previewing = handle
				-- The call waits for the command while the program goes on with the page's other
				-- calls.
				while result == nil do
					if running ~= nil and running.cancelled then
						handle:cancel()
					end
					pencere.time.sleep(0.01)
				end
				if session.previewing == handle then
					session.previewing = nil
				end
				return {
					text = result.text,
					status = result.status,
					cut = result.cut,
					timed_out = result.timed_out,
					cancelled = result.cancelled,
				}
			end
		)
	end

	return calls
end

return M
