-- Why a shape cannot be written with the columns there are: the refusal that comes before
-- anything is written, so that a typed name is not found out to be wrong halfway.

local pencere = require("pencere")
local json = require("input.json")
local part = require("output.part")
local template = require("output.template")

local M = {}

-- The name is quoted as JSON quotes a string, so that a name with a quote or a control
-- character in it is read back as it was typed (and a byte that is not text is U+FFFD, for the
-- words go where text goes).
local function missing(name)
	return pencere.text.lossy("There is no column named " .. json.encode(name))
end

-- Why the shape cannot be written with these column names, or nil when it can. `shape` is
-- `{ kind = "fields", names = }`, `{ kind = "template", template = }`, or one that names no
-- part of a row.
function M.problem_of(shape, names)
	if shape.kind == "fields" then
		for _, name in ipairs(shape.names) do
			if not part.knows(name, names) then
				return missing(name)
			end
		end
	elseif shape.kind == "template" then
		for _, piece in ipairs(template.parse(shape.template)) do
			if type(piece) == "table" and not part.knows(piece.name, names) then
				return missing(piece.name)
			end
		end
	end
	return nil
end

return M
