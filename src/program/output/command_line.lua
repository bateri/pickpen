-- The command line that does again, with no person, what the person did in the view: the query
-- as `--where`, the order as `--sort`, and the output as it was shaped. Run in a script or by
-- cron, it writes the rows the query matches, which are the rows the person sent when they sent
-- every row the query showed.

local shell = require("output.shell")
local space = require("output.space")

local M = {}

local quote = shell.shell_quote

-- A recipe is `{ input =, where =, sort = { column =, descending = }, field = { names },
-- format =, output = }`; only `where` is required. `input` is as the person gave it (the shape
-- read from the input needs no flag). Of the three ways to shape the output the first the
-- recipe has is written: `field`, then `format`, then `output`.
function M.command_line(recipe)
	local words = { "pickpen" }
	local function add(flag, value)
		words[#words + 1] = flag
		words[#words + 1] = value
	end
	if recipe.input and recipe.input ~= "" then
		add("--input", quote(recipe.input))
	end
	add("--where", quote(space.trim(recipe.where or "")))
	if recipe.sort then
		add("--sort", quote((recipe.sort.descending and "-" or "") .. recipe.sort.column))
	end
	if recipe.field and #recipe.field > 0 then
		add("--field", quote(table.concat(recipe.field, ",")))
	elseif recipe.format and recipe.format ~= "" then
		add("--format", quote(recipe.format))
	elseif recipe.output and recipe.output ~= "" then
		add("--output", quote(recipe.output))
	end
	return table.concat(words, " ")
end

return M
