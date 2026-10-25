-- The built program with nobody to ask: `--where` writes what the query matches, as grep would, the
-- exit status says whether anything went out, and a person is never stood in for.

local pencere = require("pencere")
local t = require("t")
local s = require("binary.support")

local PODS = s.read(s.DEMO .. "pods.txt")

local function has(text, piece)
	return string.find(text, piece, 1, true) ~= nil
end

t.test("--where writes the rows the query matches, in the input's shape", function()
	local ran = s.run({ "--where", "STATUS=Error" }, PODS)
	t.eq(ran.status, 0)
	local count = 0
	for line in string.gmatch(ran.out, "[^\n]+") do
		count += 1
		t.ok(string.find(line, "%sError%s"), line)
		-- The heading stays behind; the lines go out as they came.
		t.ok(has(PODS, line .. "\n"), line)
	end
	t.ok(count > 0)
end)

t.test("--where with --sort and --field", function()
	local ran = s.run({
		"--where", "status>=500", "--sort", "-ms", "--field", "ms,status",
		s.DEMO .. "requests.jsonl",
	})
	t.eq(ran.status, 0, ran.err)
	local previous, count = math.huge, 0
	for line in string.gmatch(ran.out, "[^\n]+") do
		local ms = tonumber(string.match(line, "^([^\t]+)\t"))
		t.ok(ms ~= nil and ms <= previous, line)
		previous = ms
		count += 1
	end
	t.ok(count > 10, tostring(count))
end)

t.test("nothing matched writes nothing and ends with 1, as grep does", function()
	local ran = s.run({ "--where", "no-such-word" }, PODS)
	t.eq(ran.out, "")
	t.eq(ran.status, 1)
end)

t.test("a person is needed, and there is no terminal: 2, with what to do instead", function()
	for _, args in ipairs({ {}, { "--confirm", "--where", "x" }, { "--query", "web" } }) do
		local ran = s.run(args, PODS)
		t.eq(ran.status, 2, table.concat(args, " "))
		t.eq(ran.out, "")
		t.ok(has(ran.err, "needs a terminal that shows pencere views; --where QUERY alone runs"),
			ran.err)
	end
end)

t.test("a terminal that shows no views: a person was needed, 2", function()
	local ran = s.pane("printf 'a\\n' | \"$PICKPEN\"", {}, {}, { "--no-host" })
	t.eq(ran.status, 2)
	t.eq(ran.out, "")
	t.ok(has(ran.err, "needs a terminal that shows pencere views"), ran.err)
end)

t.test("a column a term names that is not there is said", function()
	local ran = s.run({ "--where", "PORT=80" }, PODS)
	t.eq(ran.status, 1)
	t.ok(has(ran.err, 'no column named "PORT": that term is looked for as a word'), ran.err)
end)

t.test("the command line is checked before anything is read", function()
	t.eq(s.run({ "--field", "A", "--output", "json" }).status, 64)
	t.eq(s.run({ "--output", "xml" }).status, 64)
	t.eq(s.run({ "--input", "yaml" }).status, 64)
	t.eq(s.run({ "a", "b" }).status, 64)
	t.eq(s.run({ "--bogus" }).status, 64)
	t.eq(s.run({ "--where", "", "--field", "NOPE" }, PODS).status, 64)
	t.eq(s.run({ "--where", "", "--sort", "NOPE" }, PODS).status, 64)
	t.eq(s.run({ "--where", "", "/no/such/file" }).status, 66)
	t.eq(s.run({ "--where", "x", "--input", "json" }, "[1, 2").status, 65)
	t.ok(string.find(s.run({ "--help" }).out, "^usage: pickpen"))
	t.ok(string.find(s.run({ "--version" }).out, "^pickpen %d+%.%d+%.%d+\n$"))
end)

t.test("with no FILE and a terminal for input, it says what to give", function()
	local ran = s.pane("\"$PICKPEN\" --where x", {}, {}, { "--no-host" })
	t.eq(ran.status, 64)
	t.ok(has(ran.err, "give rows on stdin or name a FILE"), ran.err)
end)

t.test("options may be written as --name=value, -n value, -nvalue and in a bunch", function()
	local ran = s.run({ "--where=STATUS=Error", "-f", "NAME" }, PODS)
	t.eq(ran.status, 0, ran.err)
	t.ok(has(ran.out, "-"), ran.out)
	t.eq(s.run({ "-wSTATUS=Error", "-fNAME" }, PODS).out, ran.out)
	t.eq(s.run({ "-s", "-NAME", "-w", "x" }, "x 1\nx 2\n").status, 64)
end)

t.test("the rows go out as they come, while the input is still being written", function()
	local started = pencere.time.monotonic()
	local first_at, finished_at, first = nil, nil, nil
	local ran = pencere.process.run({
		argv = { "sh", "-c", "(printf 'ok one\\nerror two\\n'; sleep 2; printf 'error three\\n') | "
			.. s.quoted(s.BIN) .. " --where error" },
		raw = true,
		session = true,
		timeout = 30,
		on_stdout = function(piece)
			if first_at == nil then
				first_at, first = pencere.time.monotonic() - started, piece
			end
		end,
	})
	finished_at = pencere.time.monotonic() - started
	t.eq(ran.code, 0)
	t.eq(first, "error two\n")
	local seen = string.format("first %.2f s, end %.2f s", first_at, finished_at)
	t.ok(first_at < finished_at - 1, seen)
	t.eq(ran.stdout, "error two\nerror three\n")
end)

t.test("what reads the output going away ends pickpen quietly", function()
	local ran = pencere.process.run({
		argv = {
			"sh",
			"-c",
			"yes row | head -50000 | " .. s.quoted(s.BIN) .. " --where row | head -1",
		},
		raw = true,
		session = true,
		timeout = 40,
	})
	t.eq(ran.stdout, "row\n")
	t.eq(ran.stderr, "")
end)

t.test("a FILE is read as stdin is, and - is stdin", function()
	local from_file = s.run({ "--where", "STATUS=Error", s.DEMO .. "pods.txt" })
	t.eq(from_file.status, 0, from_file.err)
	t.eq(s.run({ "--where", "STATUS=Error", "-" }, PODS).out, from_file.out)
end)
