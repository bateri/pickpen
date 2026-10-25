-- How a call of the page is answered. The params it arrives with are checked against the schema it
-- names (what does not fit is answered `bad-params`, and the work never runs), and what the work
-- raises is told to the page with a code it can act on: `stale` for a position asked in a list
-- that has since changed, `failed` for what the program would not do (the words are for the
-- person).
--
-- This is api/'s: the files of api/ know the page, and input/, query/, output/ and state/ do not.

local params = require("api.params")

local M = {}

-- What a failure tells the page: an error that is a table with a code is the call's own answer.
local function failure(err)
	if type(err) == "table" and err.code then
		return err
	end
	local words = string.gsub(tostring(err), "\nstack traceback:.*$", "")
	return { code = "failed", message = words }
end

-- A call that takes the params `schema` describes. `work(params, call)` gives the answer; `call`
-- is the runner's, with `call.cancelled`.
function M.new(schema, work)
	return function(args, call)
		local parsed, why = params.parse(schema, args)
		if why then
			error({ code = "bad-params", message = why }, 0)
		end
		local results = table.pack(pcall(work, parsed, call))
		if not results[1] then
			error(failure(results[2]), 0)
		end
		return table.unpack(results, 2, results.n)
	end
end

-- An answer to a call made in a list that has since changed.
function M.stale()
	error({ code = "stale", message = "the list has changed since" }, 0)
end

-- Refuses a call made in another list than the one there is. A call that names none is made in
-- the list as it is (a page always names the one it saw).
function M.in_list(view, gen)
	if gen ~= nil and gen ~= view.gen then
		M.stale()
	end
end

return M
