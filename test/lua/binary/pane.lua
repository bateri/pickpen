-- pickpen in a pipeline in a terminal pane, with pencere's stand-in terminal (`pencere-fake-host`)
-- playing the terminal and a scripted page: the page's calls travel to the program through the tty
-- while stdin and stdout carry the pipeline's data. The page here is a script of the same calls the
-- real page makes (query, mark, order, choose); what the real page does with its keys and its
-- pointer is the page tests'.

local t = require("t")
local s = require("binary.support")

local function has(text, piece)
	return string.find(text, piece, 1, true) ~= nil
end

local function count(text, piece)
	local n, at = 0, 1
	while true do
		local first = string.find(text, piece, at, true)
		if not first then
			return n
		end
		n += 1
		at = first + #piece
	end
end

-- The page opens before it asks for anything, and `open` gives the input a moment (here, up to
-- `seconds`) to end, so that a test does not race the reading of its own input.
local function open(seconds)
	return string.format('open={"wait":%s}', seconds or 5)
end

local function marking(place)
	return string.format('mark={"op":"range","from":%d,"to":%d,"on":true}', place, place)
end

t.test("the rows marked in the pane go out on stdout, in the order shown", function()
	local ran = s.pane(
		"printf 'alpha\\nbeta\\ngamma\\n' | \"$PICKPEN\"",
		{ open(), marking(1), marking(3), "choose={}" }
	)
	t.eq(ran.out, "alpha\ngamma\n")
	t.eq(ran.status, 0)
	t.ok(has(ran.log, "program: dismiss"), ran.log)
	t.ok(has(ran.log, "alternate screen off"))
	-- The pipe has the data and nothing else: the terminal had the protocol.
	t.eq(ran.err, "")
end)

t.test("the order the person asked for is the order the rows go out in", function()
	local ran = s.pane(
		"printf 'alpha\\nbeta\\ngamma\\n' | \"$PICKPEN\"",
		{ open(), 'order={"column":1,"descending":true}', marking(1), marking(3), "choose={}" }
	)
	t.eq(ran.out, "gamma\nalpha\n")
	t.eq(ran.status, 0)
end)

t.test("with nothing marked the row under the cursor goes out", function()
	local ran = s.pane(
		"printf 'alpha\\nbeta\\ngamma\\n' | \"$PICKPEN\"",
		{ open(), 'choose={"cursor":2}' }
	)
	t.eq(ran.out, "beta\n")
	t.eq(ran.status, 0)
end)

local FILES = {
	{ "pods.txt", "STATUS!=Running AGE<1h", { "--field", "NAME" } },
	{ "requests.jsonl", "status>=400 ms>100 !health", { "--sort", "-ms" } },
	{ "servers.csv", "role=db|cache cpu>50", { "--sort", "memory" } },
	{ "ps.txt", "%cpu>2 !postgres", { "--format", "kill {PID} # {COMMAND}" } },
}

for _, case in ipairs(FILES) do
	local file, where, extra = case[1], case[2], case[3]
	local name = "--where '" .. where .. "' on " .. file .. " goes out as a page sending them does"
	t.test(name, function()
		local path = s.DEMO .. file
		local args = { "--where", where }
		for _, word in ipairs(extra) do
			args[#args + 1] = word
		end
		args[#args + 1] = path
		local headless = s.run(args)
		t.eq(headless.status, 0, headless.err)
		-- The page types the query, marks every row it shows, and sends them.
		local typed = string.gsub(string.gsub(where, "\\", "\\\\"), '"', '\\"')
		local shown = s.pane(
			"\"$PICKPEN\" " .. table.concat((function()
				local quoted = {}
				for _, word in ipairs(extra) do
					quoted[#quoted + 1] = s.quoted(word)
				end
				return quoted
			end)(), " ") .. " " .. s.quoted(path),
			{
				open(10),
				'query={"typed":"' .. typed .. '"}',
				'mark={"op":"all","on":true}',
				"choose={}",
			}
		)
		t.eq(shown.status, 0, shown.err)
		t.eq(shown.out, headless.out)
	end)
end

t.test("--confirm in a pane: the rule marks the rows, and what is marked goes out", function()
	local pods = s.DEMO .. "pods.txt"
	local headless = s.run({ "--where", "STATUS!=Running", "--field", "NAME", pods })
	local ran = s.pane(
		"\"$PICKPEN\" --where 'STATUS!=Running' --confirm --field NAME " .. s.quoted(pods),
		{ open(10), "choose={}" }
	)
	t.eq(ran.status, 0, ran.err)
	t.eq(ran.out, headless.out)
	t.ok(#ran.out > 0)
end)

t.test("--confirm: nothing marked is nothing to send", function()
	local ran = s.pane(
		"\"$PICKPEN\" --where 'STATUS=Nothing' --confirm " .. s.quoted(s.DEMO .. "pods.txt"),
		{ open(10), "choose={}" },
		{ "--then", "close" }
	)
	t.eq(ran.out, "")
	t.eq(ran.status, 1)
	t.ok(has(ran.log, "response") and has(ran.log, "No row was chosen"), ran.log)
end)

t.test("Send nothing writes nothing and ends with 1", function()
	local ran = s.pane("printf 'a\\nb\\n' | \"$PICKPEN\"", { open(), "cancel={}" })
	t.eq(ran.out, "")
	t.eq(ran.status, 1)
	t.ok(has(ran.err, "nothing was chosen"), ran.err)
end)

t.test("⌃C ends it as a signal does, with the terminal given back", function()
	local ran = s.pane(
		"printf 'a\\nb\\n' | \"$PICKPEN\"",
		{ "window={\"from\":1,\"count\":10}" },
		{ "--then", "interrupt" }
	)
	t.eq(ran.out, "")
	t.eq(ran.status, 130)
	t.ok(string.find(ran.log, "program: bye id=%d+ reason=signal"), ran.log)
	t.ok(has(ran.log, "alternate screen off"))
end)

t.test("the person closing the view sends nothing", function()
	local ran = s.pane("printf 'a\\n' | \"$PICKPEN\"", {}, { "--then", "close" })
	t.eq(ran.out, "")
	t.eq(ran.status, 1)
end)

t.test("a view the terminal starts again finds the rows where they were", function()
	local ran = s.pane(
		"printf 'a\\nb\\nc\\n' | \"$PICKPEN\"",
		{ 'window={"from":1,"count":10}' },
		{ "--then", "restart" }
	)
	t.eq(count(ran.log, "program: open id="), 2, ran.log)
	-- Both views were shown the three rows.
	t.eq(count(ran.log, '"rows":[{"cells":["a"]},{"cells":["b"]},{"cells":["c"]}]'), 2, ran.log)
	-- The stand-in types ^C once the second view has made its calls.
	t.eq(ran.out, "")
	t.eq(ran.status, 130)
end)

t.test("an input that does not end does not hold the answer up", function()
	local ran = s.pane(
		"(printf 'one\\ntwo\\n'; sleep 4) | { \"$PICKPEN\"; echo $? > \"$DIR/own\"; "
			.. "date +%s > \"$DIR/ended\"; }",
		{ open(1), marking(2), "choose={}" }
	)
	-- The pipeline ends when its slowest member does; pickpen ended long before.
	t.eq(ran.out, "two\n")
	t.eq(ran.status, 0)
	t.ok(ran.seconds >= 3.5, "the sleep ran its course: " .. ran.seconds)
end)

t.test("rows that come while the view is open join the list", function()
	local ran = s.pane(
		"(printf 'one\\n'; sleep 1; printf 'two\\nthree\\n') | \"$PICKPEN\"",
		{ "window={\"from\":1,\"count\":10}" },
		{ "--then", "close" }
	)
	t.eq(ran.out, "")
	t.ok(has(ran.log, "view:"), ran.log)
end)

t.test("a list of 200,000 rows is held by the program and shown a window at a time", function()
	local lines = { string.format("%-8s %7s %5s %s", "USER", "PID", "%CPU", "COMMAND") }
	for number = 1, 200000 do
		lines[#lines + 1] = string.format("%-8s %7d %5.1f /usr/bin/program-%d --flag",
			"user" .. number % 7, number, number % 100 + (number % 10) / 10, number)
	end
	local dir = s.scratch()
	local path = dir .. "/big.txt"
	require("pencere").fs.write(path, table.concat(lines, "\n") .. "\n")
	local ran = s.pane(
		"\"$PICKPEN\" " .. s.quoted(path),
		{
			open(30),
			'window={"from":199990,"count":10}',
			'query={"typed":"cpu>98 program-1999"}',
			'window={"from":1,"count":3}',
			marking(1),
			"choose={}",
		}
	)
	s.clean(dir)
	t.eq(ran.status, 0, ran.err)
	t.ok(has(ran.log, '"total":200000'), "the summary says how many rows there are")
	t.ok(has(ran.log, "program-199999"), "the last rows were asked for and given")
	print(string.format("       200,000 rows: opened, windowed, queried, marked, sent in %.1f s",
		ran.seconds))
	t.ok(#ran.out > 0)
	t.ok(ran.seconds < 40, tostring(ran.seconds))
end)
