-- What goes out for the rows chosen, in each form: the rows themselves (`render`, and `head`,
-- `one` and `streams` for writing them as they come), the command a preview runs for a row and
-- the run of it (`preview`), and the command line that chooses the same rows again in a
-- script. Nothing here knows the page.

local command_line = require("output.command_line")
local part = require("output.part")
local preview = require("output.preview")
local problem = require("output.problem")
local render = require("output.render")
local shell = require("output.shell")
local template = require("output.template")

return {
	part_of = part.part_of,
	knows = part.knows,
	problem_of = problem.problem_of,
	render = render.render,
	streams = render.streams,
	head = render.head,
	one = render.one,
	fill_template = template.fill_template,
	shell_quote = shell.shell_quote,
	command_line = command_line.command_line,
	command_for = preview.command_for,
	preview = preview,
}
