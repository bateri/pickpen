-- The command line that does again, with nobody to ask, what Send would do: and whether it does.
-- It does when the rows marked are exactly the rows a query matches: the query typed or, with
-- `--confirm`, the rule the rows were marked by. Rows marked one by one have no query that names
-- them, and the page says that too.
--
-- This is api/'s: the files of api/ know the page, and input/, query/, output/ and state/ do not.

local output = require("output")

local M = {}

local function trim(text)
	return (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", ""))
end

-- `fields`: the columns the person picked in the page, or nil for the command line's.
-- Gives { kind = "none" | "same" | "different", line =, where =, rows =, chosen = }.
function M.of(session, fields)
	local view, rows = session.view, session.table
	local options = session.options
	local given = options.given
	local names = rows.names

	local field = fields or given.field
	local function line_for(where)
		local sort = nil
		if view.order then
			sort = { column = names[view.order.column] or "", descending = view.order.descending }
		end
		return output.command_line({
			input = given.input,
			where = where,
			sort = sort,
			field = (field and #field > 0) and field or nil,
			format = given.format,
			output = given.output,
		})
	end

	local typed = view:source()
	local candidates = { { where = typed, ids = view.shown } }
	local rule = view.rule_source
	if rule ~= nil and trim(rule) ~= trim(typed) then
		candidates[2] = { where = rule }
	end
	-- The query typed says what is meant once there is one; until then, the rule does.
	local main = candidates[1]
	if trim(typed) == "" and candidates[2] then
		main = candidates[2]
	end
	local function ids_of(candidate)
		if candidate.ids == nil then
			candidate.ids = view:matching(candidate.where)
		end
		return candidate.ids
	end

	if view.marked_count == 0 then
		return { kind = "none", line = line_for(main.where), where = main.where }
	end
	for _, candidate in ipairs(candidates) do
		local ids = ids_of(candidate)
		if view.marked_count == #ids then
			local all = true
			for _, id in ipairs(ids) do
				if not view.marked[id] then
					all = false
					break
				end
			end
			if all then
				return {
					kind = "same",
					line = line_for(candidate.where),
					rows = #ids,
					where = candidate.where,
				}
			end
		end
	end
	return {
		kind = "different",
		line = line_for(main.where),
		rows = #ids_of(main),
		chosen = view.marked_count,
		where = main.where,
	}
end

return M
