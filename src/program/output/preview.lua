-- `--preview`: the command run for the row the cursor is on, on the program's machine, with
-- what it prints shown beside the rows.
--
-- Every process of a pipeline shares the pane's terminal, and the host's answers to the program
-- arrive on it, the token that opens views among them. So the command is given no standard
-- input (it is closed, so a command that reads gets the end at once) and runs in a group of its
-- own, which is what ends it whole: a shell's children, a pager it started.
--
-- It also runs in a session of its own, so it has no controlling terminal to open.

local pencere = require("pencere")
local part = require("output.part")
local shell = require("output.shell")
local templates = require("output.template")

local M = {}

-- What the view is shown of a preview at most: more ends the command, and the view says so.
M.MAX_OUTPUT = 256 * 1024
-- How long a preview may run, in seconds.
M.TIMEOUT = 10

-- The command with the row's values in place of `{}`, `{COLUMN}` and `{2}`, each quoted for sh.
-- A name that is no part of the row is left as it was written.
function M.command_for(template, record, source)
	local out = {}
	for at, piece in ipairs(templates.parse(template)) do
		if type(piece) == "string" then
			out[at] = piece
		else
			local text = part.part_of(record, piece.name, source)
			if text == nil then
				out[at] = "{" .. piece.name .. "}"
			else
				out[at] = shell.shell_quote(text)
			end
		end
	end
	return table.concat(out)
end

-- Runs `command` with `/bin/sh -c`, `width` columns wide (the `COLUMNS` it sees), and calls
-- `on_done(result)` once, when it is over, whatever ended it. The result is
-- `{ text =, status =, signal =, cut =, timed_out =, cancelled = }`:
--   text       what it printed, both streams in the order it came, ANSI colours as they were,
--              invalid UTF-8 made into U+FFFD
--   status     the exit code, nil when a signal ended it
--   cut        it printed more than `max_output` bytes: it was ended, and `text` stops there
--   timed_out  it ran longer than `timeout` seconds and was ended
--   cancelled  `cancel` was called on the handle that this gives; `text` is what came before
-- `options` may hold `max_output` and `timeout` instead of the limits above.
-- The handle's `cancel` ends the command and everything it started; `on_done` is still
-- called, with `cancelled` set, so that whoever waits is never left waiting.
function M.run(command, width, on_done, options)
	options = options or {}
	local timeout = options.timeout or M.TIMEOUT
	local chunks = {}
	local state = { timed_out = false, cancelled = false }
	local child, timer
	local handle = {}

	local function take(chunk)
		chunks[#chunks + 1] = chunk
	end

	local function finish(status, signal, overflowed)
		if timer then
			timer:cancel()
		end
		on_done({
			text = pencere.text.lossy(table.concat(chunks)),
			status = status,
			signal = signal,
			cut = overflowed == true,
			timed_out = state.timed_out,
			cancelled = state.cancelled,
		})
	end

	function handle:cancel()
		state.cancelled = true
		if child then
			child:kill("KILL")
		end
	end

	local started, spawned = pcall(pencere.process.spawn, {
		argv = { "/bin/sh", "-c", command },
		env = {
			COLUMNS = string.format("%d", math.floor(tonumber(width) or 80)),
			LINES = "200",
			PICKPEN_PREVIEW = "1",
		},
		raw = true,
		-- No controlling terminal: the host's answers arrive there, and a command (ssh asking for
		-- a password, say) must not read them.
		session = true,
		max_output = options.max_output or M.MAX_OUTPUT,
		on_stdout = take,
		on_stderr = take,
		on_exit = finish,
	})
	if not started then
		-- What went wrong is the preview, as a command that printed it would have.
		take(tostring(spawned))
		pencere.time.after(0, function()
			finish(nil, nil, false)
		end)
		return handle
	end
	child = spawned
	timer = pencere.time.after(timeout, function()
		state.timed_out = true
		child:kill("KILL")
	end)
	return handle
end

return M
