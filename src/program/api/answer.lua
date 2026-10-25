-- The person's answer: the rows to send, or nothing. Either ends the view, and the program goes
-- on to write what was chosen once the terminal is the pane's again.
--
-- This is api/'s: the files of api/ know the page, and input/, query/, output/ and state/ do not.

local pencere = require("pencere")
local call = require("api.call")
local output = require("output")
local p = require("api.params")

local M = {}

-- How long after the answer the view is closed: the answer has to reach the page first, or the page
-- loses it with the view.
local AFTER = 0.02

local function close()
	pencere.time.after(AFTER, function()
		pencere.close_view()
	end)
end

function M.calls(session)
	local view, rows = session.view, session.table
	local calls = {}

	-- Sends these rows (the marked ones, or the row under the cursor) in the shape asked for, and
	-- ends.
	calls.choose = call.new(
		p.object({
			gen = p.optional(p.integer(0)),
			cursor = p.optional(p.integer(1)),
			fields = p.optional(p.array(p.string(), 200)),
		}),
		function(args)
			if session:answered() then
				return { chosen = 0 }
			end
			call.in_list(view, args.gen)
			local shape = session:shape_of(args.fields)
			local problem = output.problem_of(shape, rows.names)
			if problem then
				error({ code = "failed", message = problem }, 0)
			end
			local ids = view:to_send(args.cursor)
			if #ids == 0 then
				error({ code = "failed", message = "No row was chosen" }, 0)
			end
			session:choose(ids, shape)
			close()
			return { chosen = #ids }
		end
	)

	-- Sends nothing, and ends.
	calls.cancel = call.new(p.object({}), function()
		if not session:answered() then
			session:cancel()
			close()
		end
		return { ok = true }
	end)

	return calls
end

return M
