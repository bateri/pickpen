-- A template with `{NAME}` for that column, `{2}` for the second and `{}` for the row as it was
-- read (`part_of`), which is what `--format` and `--preview` are written in.

local part = require("output.part")

local M = {}

local find, sub = string.find, string.sub

-- The template as a list of its parts, in order: a text is written as it is, and a table
-- `{ name = ... }` is a place for a part of the row. It is read once for all the rows that
-- the template fills. A name has no brace in it: in `{a{b}` the name is `b`, and `{a` stays text.
function M.parse(template)
	local parts, from = {}, 1
	while true do
		local first, last, name = find(template, "{([^{}]*)}", from)
		if not first then
			break
		end
		if first > from then
			parts[#parts + 1] = sub(template, from, first - 1)
		end
		parts[#parts + 1] = { name = name }
		from = last + 1
	end
	if from <= #template then
		parts[#parts + 1] = sub(template, from)
	end
	return parts
end

-- The template as a function from a record to the text it fills in, with the names of its
-- places settled once for all the records (`part.reader`); a name that is no part of the row
-- writes nothing.
function M.compile(template, source)
	local parts = M.parse(template)
	local readers, out = {}, {}
	for at, piece in ipairs(parts) do
		if type(piece) == "table" then
			readers[at] = part.reader(piece.name, source)
		end
	end
	return function(record)
		for at, piece in ipairs(parts) do
			if readers[at] then
				out[at] = readers[at](record) or ""
			else
				out[at] = piece
			end
		end
		return table.concat(out)
	end
end

-- `{NAME}` is that column, `{2}` the second, `{}` the row as it was read (`part_of`).
function M.fill_template(template, record, source)
	return M.compile(template, source)(record)
end

return M
