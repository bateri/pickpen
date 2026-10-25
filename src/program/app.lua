-- pickpen: rows come in on stdin (or from a file), a person chooses in the terminal pane, and the
-- rows chosen go out on stdout, for what comes next in the pipeline.
--
--   ps aux | pickpen --field PID | xargs kill
--
-- stdin and stdout are the pipeline's, so the view is shown on the controlling terminal
-- (`serve{ filter = true }`) and always: pickpen never guesses whether it is in a pipeline. With
-- `--where` and no `--confirm` nobody is asked: the rows the query matches go out, the same in a
-- terminal and in cron.
--
-- This file is the entry: the command line, the two ways the program goes (nobody is asked, or a
-- person chooses in the pane) and the way out, which is writing the rows. What the page asks of
-- the program is `api/`'s.

local pencere = require("pencere")
local io_ = pencere.io

local api_answer = require("api.answer")
local api_feed = require("api.feed")
local api_list = require("api.list")
local api_panels = require("api.panels")
local input = require("input")
local output = require("output")
local query = require("query")
local session_state = require("state.session")
local version = require("version")

local USAGE = [[
usage: pickpen [options] [FILE]

Choose rows in the middle of a pipeline: they come in on stdin (or from FILE),
you choose in the terminal pane, and the rows you chose go out on stdout.

  ps aux | pickpen --field PID | xargs kill
  kubectl get pods | pickpen --where 'STATUS!=Running' --confirm --field NAME

  -q, --query QUERY      start with QUERY typed
  -w, --where QUERY      no view: write the rows QUERY matches, as grep would
  -c, --confirm          a person confirms: the rows --where matches are marked,
                         and only marked rows go out
  -s, --sort [-]COLUMN   in COLUMN's order (with -, the other way)
  -f, --field COLUMN,…   write these columns of each row, tab-separated
      --format TEMPLATE  write each row as TEMPLATE: {COLUMN}, {2}, {} the row
  -o, --output FORMAT    write csv, tsv, json or jsonl
  -i, --input FORMAT     read lines, csv, tsv, columns, jsonl or json
                         (without it, the shape is read from the first lines)
  -p, --preview COMMAND  show what COMMAND prints for the row the cursor is on;
                         {} {COLUMN} {2} stand for the row and its cells
  -t, --title TEXT       a line above the rows, saying what they are for
  -h, --help             this text
  -v, --version          the version

The query: words the row must hold, !word for one it must not, and
COLUMN=v, !=, ~ (holds), !~, >, >=, <, <=, and a..b, with quantities read
as such: cpu>50, size>1G, age<2h. The same query does the same in the view
and with --where.

Exit status: 0 rows went out, 1 none did, 2 a person was needed and there
was no terminal that shows pencere views, 64 the command line was wrong,
65 the input could not be read, 130 ⌃C.
]]

-- How long a slow input may take before its shape is read from the lines it has sent.
local DECIDE_AFTER = 0.15

-- ---- the way out -------------------------------------------------------------------------------

local function say(message)
	io_.ewrite("pickpen: " .. message .. "\n")
end

local function quit(code, message)
	if message then
		say(message)
	end
	pencere.exit(code)
end

-- Writes to stdout. What reads it having gone is how a pipeline ends (`head`): the program ends
-- quietly, as a SIGPIPE would end it, with the status a shell gives that.
local function write(text)
	if text == "" then
		return
	end
	local ok, why = pcall(io_.write, text)
	if not ok then
		if string.find(tostring(why), "Broken pipe", 1, true) then
			pencere.exit(141)
		end
		quit(74, "cannot write: " .. tostring(why))
	end
end

-- ---- the command line --------------------------------------------------------------------------

local OPTIONS = {
	query = { short = "q", value = true },
	where = { short = "w", value = true },
	confirm = { short = "c" },
	sort = { short = "s", value = true },
	field = { short = "f", value = true, many = true },
	format = { value = true },
	output = { short = "o", value = true },
	input = { short = "i", value = true },
	preview = { short = "p", value = true },
	title = { short = "t", value = true },
	help = { short = "h" },
	version = { short = "v" },
}

local SHORT = {}
for name, option in pairs(OPTIONS) do
	if option.short then
		SHORT[option.short] = name
	end
end

local function label(name)
	local option = OPTIONS[name]
	local short = option.short and ("-" .. option.short .. ", ") or ""
	return short .. "--" .. name .. (option.value and " <value>" or "")
end

-- A word of the command line that is an option: it starts with a dash and is more than one.
local function looks_like_option(word)
	return #word > 1 and string.sub(word, 1, 1) == "-"
end

-- `--sort -cpu` is `--sort=-cpu`: the minus is the order's, not an option's.
local function join_sort(arguments)
	local joined, at = {}, 1
	while at <= #arguments do
		local argument, following = arguments[at], arguments[at + 1]
		if (argument == "--sort" or argument == "-s") and following ~= nil
			and string.sub(following, 1, 1) == "-" then
			joined[#joined + 1] = "--sort=" .. following
			at += 2
		else
			joined[#joined + 1] = argument
			at += 1
		end
	end
	return joined
end

-- The words of the command line as { values = { name = text or list or true }, positionals }, or
-- nil and what is wrong.
local function read_words(arguments)
	arguments = join_sort(arguments)
	local values, positionals = {}, {}
	local function put(name, value)
		if OPTIONS[name].many then
			values[name] = values[name] or {}
			table.insert(values[name], value)
		else
			values[name] = value
		end
	end
	local at = 1
	while at <= #arguments do
		local word = arguments[at]
		at += 1
		if word == "--" then
			while at <= #arguments do
				positionals[#positionals + 1] = arguments[at]
				at += 1
			end
		elseif string.sub(word, 1, 2) == "--" then
			local name, attached = string.match(word, "^%-%-([^=]+)=(.*)$")
			name = name or string.sub(word, 3)
			local option = OPTIONS[name]
			if option == nil then
				return nil, "Unknown option '--" .. name .. "'"
			end
			if option.value then
				if attached == nil then
					if arguments[at] == nil or looks_like_option(arguments[at]) then
						return nil, "Option '" .. label(name) .. "' argument missing"
					end
					attached = arguments[at]
					at += 1
				end
				put(name, attached)
			else
				if attached ~= nil then
					return nil, "Option '" .. label(name) .. "' does not take an argument"
				end
				put(name, true)
			end
		elseif looks_like_option(word) then
			-- Short options, in a bunch: switches, and a last one that may take the rest of the
			-- word or the next one.
			local position = 2
			while position <= #word do
				local letter = string.sub(word, position, position)
				local name = SHORT[letter]
				if name == nil then
					return nil, "Unknown option '-" .. letter .. "'"
				end
				if OPTIONS[name].value then
					local rest = string.sub(word, position + 1)
					if rest == "" then
						if arguments[at] == nil or looks_like_option(arguments[at]) then
							return nil, "Option '" .. label(name) .. "' argument missing"
						end
						rest = arguments[at]
						at += 1
					end
					put(name, rest)
					break
				end
				put(name, true)
				position += 1
			end
		else
			positionals[#positionals + 1] = word
		end
	end
	return { values = values, positionals = positionals }
end

local function split_commas(list)
	local names = {}
	for _, text in ipairs(list) do
		for piece in string.gmatch(text .. ",", "([^,]*),") do
			names[#names + 1] = (string.gsub(string.gsub(piece, "^%s+", ""), "%s+$", ""))
		end
	end
	return names
end

local function in_list(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

-- What the command line asks for: { help =, version = } or the options, or nil and what is wrong.
local function parse(arguments)
	local words, why = read_words(arguments)
	if words == nil then
		return nil, why
	end
	local values = words.values
	if values.help then
		return { help = true }
	end
	if values.version then
		return { version = true }
	end
	if #words.positionals > 1 then
		return nil, "give one FILE at most"
	end

	local fields = split_commas(values.field or {})
	for _, name in ipairs(fields) do
		if name == "" then
			return nil, "--field names a column with no name"
		end
	end
	local shapes = (#fields > 0 and 1 or 0) + (values.format ~= nil and 1 or 0)
		+ (values.output ~= nil and 1 or 0)
	if shapes > 1 then
		return nil, "give one of --field, --format and --output"
	end
	local shape = { kind = "input" }
	if #fields > 0 then
		shape = { kind = "fields", names = fields }
	elseif values.format ~= nil then
		shape = { kind = "template", template = values.format }
	elseif values.output ~= nil then
		local format = values.output
		if not in_list({ "csv", "tsv", "json", "jsonl" }, format) then
			return nil, "--output is csv, tsv, json or jsonl, not " .. input.json.encode(format)
		end
		shape = { kind = "as", format = format }
	end

	if values.input ~= nil and not in_list(input.FORMATS, values.input) then
		return nil, "--input is one of " .. table.concat(input.FORMATS, ", ")
	end

	local sort = nil
	if values.sort ~= nil then
		local descending = string.sub(values.sort, 1, 1) == "-"
		local column = descending and string.sub(values.sort, 2) or values.sort
		if column == "" then
			return nil, "--sort names no column"
		end
		sort = { column = column, descending = descending }
	end

	local file = words.positionals[1]
	return {
		file = (file ~= nil and file ~= "-") and file or nil,
		query = values.query or "",
		where = values.where,
		confirm = values.confirm == true,
		sort = sort,
		shape = shape,
		input = values.input,
		preview = values.preview,
		title = values.title,
		-- The output flags as given, for the command line the view shows.
		given = {
			input = values.input,
			field = #fields > 0 and fields or nil,
			format = values.format,
			output = values.output,
		},
	}
end

-- ---- the input ---------------------------------------------------------------------------------

-- Starts reading the input, a piece at a time: `on_data(bytes)` for each, `on_end()` at the end.
-- Gives a handle with `stop`. A file that cannot be read is said before anything else is done.
local function open_input(options, on_data, on_end)
	if options.file == nil then
		-- A person who typed `pickpen` alone would wait on a read nobody feeds.
		if io_.is_terminal("stdin") then
			quit(64, "give rows on stdin or name a FILE (pickpen --help says how it is used)")
		end
		return pencere.io.read_stdin(on_data, on_end)
	end
	local ok, stat = pcall(pencere.fs.stat, options.file)
	if not ok or stat == nil then
		local why = ok and "no such file" or tostring(stat)
		quit(66, "cannot read " .. options.file .. ": " .. why)
	end
	if stat.kind == "dir" then
		quit(66, "cannot read " .. options.file .. ": it is a directory")
	end
	local failed, over = false, false
	local child = pencere.process.spawn({
		argv = { "cat", "--", options.file },
		raw = true,
		on_stdout = on_data,
		on_stderr = function()
			failed = true
		end,
		on_exit = function(code)
			-- Stopped (the list is full, or the program is going): nothing more is wanted of it.
			if over then
				return
			end
			if failed or code ~= 0 then
				quit(66, "cannot read " .. options.file)
			end
			over = true
			on_end()
		end,
	})
	return {
		stop = function()
			over = true
			child:kill("TERM")
		end,
		active = function()
			return not over
		end,
		wait = function()
			while not over do
				pencere.time.sleep(0.02)
			end
		end,
	}
end

-- ---- nobody is asked ---------------------------------------------------------------------------

-- `--where` with nobody to ask: the rows the query matches go out, one by one when they can.
local function headless(options)
	local where = options.where
	local compiled = nil
	local names, heading = {}, nil
	local held = {}
	local count = 0
	local headed = false
	local reader
	local source = { names = names }
	local function one_by_one()
		return options.sort == nil and output.streams(options.shape, reader.format)
	end
	local sink = {
		columns = function(next_names, text)
			if #names == 0 then
				for _, name in ipairs(query.unknown_names(where, next_names)) do
					say("there is no column named " .. input.json.encode(name)
						.. ": that term is looked for as a word")
				end
			end
			names = next_names
			if text ~= nil then
				heading = text
			end
			source = { names = names, heading = heading }
			compiled = query.compile(query.parse(where, names))
			local problem = output.problem_of(options.shape, names)
			if problem then
				quit(64, problem)
			end
			if options.sort and query.column_named(names, options.sort.column) == nil then
				quit(64, "there is no column named " .. input.json.encode(options.sort.column)
					.. " to sort by")
			end
		end,
		record = function(record)
			compiled = compiled or query.compile(query.parse(where, names))
			if not compiled(record) then
				return
			end
			count += 1
			if not one_by_one() then
				held[#held + 1] = record
				return
			end
			source.format = reader.format
			if not headed then
				headed = true
				write(output.head(options.shape, source))
			end
			write(output.one(record, options.shape, source))
		end,
		problem = function(text)
			say(string.lower(string.sub(text, 1, 1)) .. string.sub(text, 2))
		end,
	}
	reader = input.Reader.new(sink, options.input)

	local reading
	local timer = nil
	local function ended()
		reader:finish()
		source.format = reader.format
		if reader.format == "json" and #names == 0 then
			quit(65, "the input could not be read")
		end
		if not one_by_one() then
			local rows = held
			if options.sort then
				local column = query.column_named(names, options.sort.column)
				local indices = {}
				for at = 1, #held do
					indices[at] = at
				end
				indices = query.order(held, indices, column, options.sort.descending)
				rows = {}
				for at, place in ipairs(indices) do
					rows[at] = held[place]
				end
			end
			write(output.render(rows, options.shape, source))
		end
		pencere.exit(count > 0 and 0 or 1)
	end
	reading = open_input(options, function(bytes)
		reader:feed(bytes)
		source.format = reader.format
		if timer == nil and reader.format == nil and reader:has_line() then
			timer = pencere.time.after(DECIDE_AFTER, function()
				reader:decide()
				source.format = reader.format
			end)
		end
	end, ended)
	-- Nothing else is waited for here: reading is what the loop does until the input ends.
	reading:wait()
end

-- ---- a person chooses --------------------------------------------------------------------------

-- The icon a terminal draws beside the program's name above the view.
local ICONS = {
	{ file = "assets/icon-32-dark.png", theme = "dark" },
	{ file = "assets/icon-64-dark.png", theme = "dark" },
	{ file = "assets/icon-32-light.png", theme = "light" },
	{ file = "assets/icon-64-light.png", theme = "light" },
}

local function choose(options)
	local session = session_state.new(options)
	local rows = session.table
	local reader = session.reader

	local reading = nil
	local timer = nil
	reading = open_input(options, function(bytes)
		session:feed(bytes)
		if timer == nil and reader.format == nil and reader:has_line() then
			timer = pencere.time.after(DECIDE_AFTER, function()
				session:decide()
			end)
		end
		if rows.capped and reading then
			reading:stop()
			session:end_input()
		end
	end, function()
		session:end_input()
	end)

	local calls = {}
	for _, area in ipairs({ api_list, api_panels, api_answer }) do
		for name, handler in pairs(area.calls(session)) do
			calls[name] = handler
		end
	end

	local no_view = false
	local outcome = pencere.serve({
		program = "pickpen",
		-- What a terminal writes above the view, in place of the program's name for it: the same
		-- for every run, as a program's name is; `--title` is the view's to say, at its top.
		title = "Pick",
		icons = ICONS,
		filter = true,
		calls = calls,
		topics = api_feed.topics(session),
		fallback = function()
			no_view = true
		end,
	})
	if reading and reading:active() then
		reading:stop()
	end

	local answer = session.answer
	if answer ~= nil and answer.kind == "chosen" then
		local records = {}
		for at, id in ipairs(answer.ids) do
			records[at] = rows.rows[id]
		end
		write(output.render(records, answer.shape, rows:source()))
		pencere.exit(0)
	end
	if not outcome.shown and outcome.reason == "interrupted" then
		pencere.exit(130)
	end
	if no_view or not outcome.shown then
		quit(2, "choosing rows needs a terminal that shows pencere views; "
			.. "--where QUERY alone runs without one")
	end
	if answer ~= nil then
		quit(1, "nothing was chosen")
	end
	if outcome.ended == "signal" then
		local signal = outcome.signal
		pencere.exit((signal == nil or signal == 2) and 130 or 128 + signal)
	end
	quit(1, "nothing was chosen")
end

-- ---- the start ---------------------------------------------------------------------------------

local options, why = parse(pencere.args)
if options == nil then
	quit(64, why .. " (pickpen --help says how it is used)")
end
if options.help then
	write(USAGE)
	pencere.exit(0)
end
if options.version then
	write("pickpen " .. version .. "\n")
	pencere.exit(0)
end

if options.where ~= nil and not options.confirm then
	headless(options)
else
	choose(options)
end
