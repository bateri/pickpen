-- What goes out on stdout for the rows chosen, in each shape, the command a preview runs, the
-- run of it, and the command line the view shows for doing it again. The records are built by
-- hand, as the input would have made them: `{ cells =, raw =, value = }`.

local pencere = require("pencere")
local t = require("t")
local json = require("input.json")
local output = require("output")
local preview = output.preview

local render, part_of, problem_of = output.render, output.part_of, output.problem_of

local function fixture(source, records)
	return { source = source, records = records }
end

local CSV = fixture({ format = "csv", names = { "name", "note" }, heading = "name,note" }, {
	{ cells = { "ann", "a, b" }, raw = 'ann,"a, b"' },
	{ cells = { "bob", "plain" }, raw = "bob,plain" },
})

local PODS = fixture({
	format = "columns",
	names = { "NAME", "STATUS" },
	heading = "NAME     STATUS",
}, {
	{ cells = { "web-1", "Running" }, raw = "web-1    Running" },
	{ cells = { "web-2", "Error" }, raw = "web-2    Error" },
})

local JSONL = fixture({ format = "jsonl", names = { "a", "b" } }, {
	{ cells = { "1", "x" }, raw = '{"a":1,"b":"x"}', value = json.parse('{"a":1,"b":"x"}') },
	{ cells = { "2", "" }, raw = '{"a":2}', value = json.parse('{"a":2}') },
})

local LINES = fixture({ format = "lines", names = { "line" } }, {
	{ cells = { "a1b2c3d Fix the thing" }, raw = "a1b2c3d Fix the thing" },
	{ cells = { "9f8e7d6 Add more" }, raw = "9f8e7d6 Add more" },
})

local JSON_DOCUMENT = fixture({ format = "json", names = { "a" } }, {
	{ cells = { "1" }, raw = '{"a":1}', value = json.parse('{"a":1}') },
	{ cells = { "2" }, raw = '{"a":2}', value = json.parse('{"a":2}') },
	{ cells = { "3" }, raw = '{"a":3}', value = json.parse('{"a":3}') },
})

local INPUT = { kind = "input" }

local function fields(...)
	return { kind = "fields", names = { ... } }
end

local function convert(format)
	return { kind = "as", format = format }
end

local function template(text)
	return { kind = "template", template = text }
end

-- ---- the rows, in each shape --------------------------------------------------------------

t.test("in the input's shape, a row goes out as the text it was read from", function()
	t.eq(render(CSV.records, INPUT, CSV.source), 'name,note\nann,"a, b"\nbob,plain\n')
	-- A table's heading stays behind, so that what reads the rows is given only rows.
	t.eq(render({ PODS.records[2] }, INPUT, PODS.source), "web-2    Error\n")
	t.eq(render(JSONL.records, INPUT, JSONL.source), '{"a":1,"b":"x"}\n{"a":2}\n')
	t.eq(render(LINES.records, INPUT, LINES.source), "a1b2c3d Fix the thing\n9f8e7d6 Add more\n")
	local records = JSON_DOCUMENT.records
	t.eq(
		render({ records[3], records[1] }, INPUT, JSON_DOCUMENT.source),
		'[\n  {"a":3},\n  {"a":1}\n]\n'
	)
	t.eq(
		json.parse(render(records, INPUT, JSON_DOCUMENT.source)),
		json.parse('[{"a":1},{"a":2},{"a":3}]')
	)
end)

t.test("a csv or tsv input has its heading as it was read, else its names", function()
	local source = { format = "csv", names = { "a", "b" } }
	t.eq(render({ { cells = { "1", "2" }, raw = "1,2" } }, INPUT, source), "a,b\n1,2\n")
	source.format = "tsv"
	t.eq(render({ { cells = { "1", "2" }, raw = "1\t2" } }, INPUT, source), "a\tb\n1\t2\n")
	source.heading = "A\tB"
	t.eq(render({ { cells = { "1", "2" }, raw = "1\t2" } }, INPUT, source), "A\tB\n1\t2\n")
end)

t.test("nothing chosen writes nothing at all", function()
	local shapes = { INPUT, convert("json"), convert("csv"), fields("note"), template("{}") }
	for _, shape in ipairs(shapes) do
		t.eq(render({}, shape, CSV.source), "")
	end
end)

t.test("--field writes columns tab-separated; a number is a place, or a line's word", function()
	t.eq(render(CSV.records, fields("note", "name"), CSV.source), "a, b\tann\nplain\tbob\n")
	t.eq(render(CSV.records, fields("2"), CSV.source), "a, b\nplain\n")
	t.eq(render(LINES.records, fields("1"), LINES.source), "a1b2c3d\n9f8e7d6\n")
	t.eq(part_of(LINES.records[1], "4", LINES.source), "thing")
	t.eq(part_of(LINES.records[1], "", LINES.source), "a1b2c3d Fix the thing")
end)

t.test("a part is looked for by heading in any case, then by place", function()
	local record = { cells = { "web-1", "Running" }, raw = "web-1    Running" }
	t.eq(part_of(record, "name", PODS.source), "web-1")
	t.eq(part_of(record, "Status", PODS.source), "Running")
	t.eq(part_of(record, "2", PODS.source), "Running")
	t.eq(part_of(record, "3", PODS.source), "")
	t.eq(part_of(record, "0", PODS.source), nil)
	t.eq(part_of(record, "nope", PODS.source), nil)
	t.eq(part_of(record, "", PODS.source), "web-1    Running")
end)

t.test("a heading is found in any case and by its letters and digits, accents too", function()
	local source = { format = "csv", names = { "Çay", "Naïve Ünit-2" } }
	local record = { cells = { "tea", "unit" }, raw = "tea,unit" }
	t.eq(part_of(record, "çay", source), "tea")
	t.eq(part_of(record, "NAÏVE ÜNIT-2", source), "unit")
	t.eq(part_of(record, "naïveünit2", source), "unit")
	t.eq(problem_of(fields("çay", "naïve_ünit_2"), source.names), nil)
end)

t.test("a column whose heading is a number is that column, not the place", function()
	local source = { format = "csv", names = { "2", "1" } }
	local record = { cells = { "first", "second" }, raw = "first,second" }
	t.eq(part_of(record, "1", source), "second")
	t.eq(part_of(record, "2", source), "first")
	t.eq(part_of(record, "3", source), "")
	t.eq(render({ record }, fields("1"), source), "second\n")
end)

t.test("in lines a word is cut at any white space, the Unicode kind too", function()
	local source = { format = "lines", names = { "line" } }
	local record = { cells = { "x" }, raw = "  one\u{3000}two\u{A0}three\tfour\u{FEFF}" }
	t.eq(part_of(record, "1", source), "one")
	t.eq(part_of(record, "2", source), "two")
	t.eq(part_of(record, "3", source), "three")
	t.eq(part_of(record, "4", source), "four")
	t.eq(part_of(record, "5", source), "")
end)

t.test("--format fills a template; --output converts", function()
	t.eq(
		render(PODS.records, template("kubectl delete pod {NAME} # {2}"), PODS.source),
		"kubectl delete pod web-1 # Running\nkubectl delete pod web-2 # Error\n"
	)
	t.eq(render(CSV.records, convert("tsv"), CSV.source), "name\tnote\nann\ta, b\nbob\tplain\n")
	t.eq(
		render(PODS.records, convert("csv"), PODS.source),
		"NAME,STATUS\nweb-1,Running\nweb-2,Error\n"
	)
	t.eq(
		render(PODS.records, convert("json"), PODS.source),
		'[\n  {"NAME":"web-1","STATUS":"Running"},\n  {"NAME":"web-2","STATUS":"Error"}\n]\n'
	)
	t.eq(
		render(PODS.records, convert("jsonl"), PODS.source),
		'{"NAME":"web-1","STATUS":"Running"}\n{"NAME":"web-2","STATUS":"Error"}\n'
	)
	-- JSON keeps the values it was given, not their text.
	t.eq(render(JSONL.records, convert("jsonl"), JSONL.source), '{"a":1,"b":"x"}\n{"a":2}\n')
	t.eq(
		render(JSONL.records, convert("json"), JSONL.source),
		'[\n  {"a":1,"b":"x"},\n  {"a":2}\n]\n'
	)
end)

t.test("a template writes nothing for a name that is no part, and keeps other braces", function()
	local record = PODS.records[1]
	t.eq(output.fill_template("{nope}|{}|{name}", record, PODS.source), "|web-1    Running|web-1")
	t.eq(output.fill_template("{a{NAME}} {x", record, PODS.source), "{aweb-1} {x")
	t.eq(output.fill_template("100% {NAME}%s", record, PODS.source), "100% web-1%s")
	t.eq(output.fill_template("", record, PODS.source), "")
end)

t.test("a CSV cell is quoted when a reader would take it for more, or lose its space", function()
	local source = { format = "columns", names = { "a", "b,c", " d" } }
	local rows = {
		{ cells = { "plain", "has,comma", 'say "hi"' }, raw = "" },
		{ cells = { "two\nlines", "cr\rhere", " lead" }, raw = "" },
		{ cells = { "trail ", "\u{A0}nbsp", "" }, raw = "" },
		{ cells = { "tab\there", "ünï", "x" }, raw = "" },
	}
	t.eq(
		render(rows, convert("csv"), source),
		'a,"b,c"," d"\n'
			.. 'plain,"has,comma","say ""hi"""\n'
			.. '"two\nlines","cr\rhere"," lead"\n'
			.. '"trail ","\u{A0}nbsp",\n'
			.. "tab\there,ünï,x\n"
	)
end)

t.test("a TSV cell has no tab or line end in it, each becomes a space", function()
	local source = { format = "columns", names = { "a", "b\tc" } }
	local rows = { { cells = { "x\ty", "l1\nl2\r\n" }, raw = "" } }
	t.eq(render(rows, convert("tsv"), source), "a\tb c\nx y\tl1 l2  \n")
end)

t.test("a row shorter than its columns is written with empty cells", function()
	local source = { format = "csv", names = { "a", "b", "c" } }
	local rows = { { cells = { "1" }, raw = "1" } }
	t.eq(render(rows, convert("csv"), source), "a,b,c\n1,,\n")
	t.eq(render(rows, convert("tsv"), source), "a\tb\tc\n1\t\t\n")
	t.eq(render(rows, convert("jsonl"), source), '{"a":"1","b":"","c":""}\n')
	t.eq(render(rows, fields("c", "a"), source), "\t1\n")
end)

t.test("a name that comes twice is one JSON key: first place, last value", function()
	local source = { format = "csv", names = { "a", "b", "a" } }
	local rows = { { cells = { "1", "2", "3" }, raw = "1,2,3" } }
	t.eq(render(rows, convert("jsonl"), source), '{"a":"3","b":"2"}\n')
end)

t.test("text in a cell is written as JSON writes a string", function()
	local source = { format = "csv", names = { "q" } }
	local rows = { { cells = { 'say "hi"\\\n\t\1/é' }, raw = "" } }
	t.eq(render(rows, convert("jsonl"), source), '{"q":"say \\"hi\\"\\\\\\n\\t\\u0001/é"}\n')
end)

t.test("bytes that are not text never raise, and the shapes that copy text copy them", function()
	local bad = "a\255\254b"
	local source = { format = "csv", names = { "x", "y" }, heading = "x,y" }
	local rows = { { cells = { bad, "ok" }, raw = bad .. ",ok" } }
	t.eq(render(rows, INPUT, source), "x,y\n" .. bad .. ",ok\n")
	t.eq(render(rows, fields("x"), source), bad .. "\n")
	t.eq(render(rows, template("[{x}]"), source), "[" .. bad .. "]\n")
	t.eq(render(rows, convert("csv"), source), "x,y\n" .. bad .. ",ok\n")
	t.eq(render(rows, convert("tsv"), source), "x\ty\n" .. bad .. "\tok\n")
	-- JSON is text: a byte that is not becomes U+FFFD.
	t.eq(render(rows, convert("jsonl"), source), '{"x":"a\239\191\189\239\191\189b","y":"ok"}\n')
	t.eq(
		render(rows, convert("json"), source),
		'[\n  {"x":"a\239\191\189\239\191\189b","y":"ok"}\n]\n'
	)
	t.eq(
		problem_of(fields(bad), { "x" }),
		'There is no column named "a\239\191\189\239\191\189b"'
	)
end)

-- ---- a shape that cannot be written -------------------------------------------------------

t.test("a shape that names no column is refused before anything is written", function()
	local names = PODS.source.names
	t.eq(problem_of(fields("NAME", "nope"), names), 'There is no column named "nope"')
	t.eq(problem_of(template("{NAME} {wat}"), names), 'There is no column named "wat"')
	t.eq(problem_of(template("{} {2} {name}"), names), nil)
	t.eq(problem_of(fields("", "2", "status"), names), nil)
	t.eq(problem_of(fields("0"), names), 'There is no column named "0"')
	t.eq(problem_of(INPUT, names), nil)
	t.eq(problem_of(convert("csv"), names), nil)
end)

t.test("the name in the refusal is quoted as JSON quotes it", function()
	local names = { "a" }
	t.eq(problem_of(fields('a"b\\c'), names), 'There is no column named "a\\"b\\\\c"')
	t.eq(problem_of(fields("a\tb"), names), 'There is no column named "a\\tb"')
	t.eq(problem_of(fields("a\1b"), names), 'There is no column named "a\\u0001b"')
	t.eq(problem_of(template("{é}"), names), 'There is no column named "é"')
end)

-- ---- rows one by one ----------------------------------------------------------------------

t.test("rows written one by one come to what rendering them all at once writes", function()
	local cases = {
		{ CSV, INPUT },
		{ CSV, convert("csv") },
		{ CSV, fields("note") },
		{ PODS, convert("tsv") },
		{ PODS, fields("NAME") },
		{ PODS, template("{NAME}={2}") },
		{ PODS, INPUT },
		{ JSONL, INPUT },
		{ JSONL, convert("jsonl") },
		{ LINES, INPUT },
		{ LINES, convert("csv") },
	}
	for _, case in ipairs(cases) do
		local data, shape = case[1], case[2]
		t.ok(output.streams(shape, data.source.format))
		local pieces = { output.head(shape, data.source) }
		for _, record in ipairs(data.records) do
			pieces[#pieces + 1] = output.one(record, shape, data.source)
		end
		t.eq(table.concat(pieces), render(data.records, shape, data.source))
	end
	t.ok(not output.streams(convert("json"), "csv"))
	t.ok(not output.streams(INPUT, "json"))
	t.ok(output.streams(INPUT, "lines"))
end)

t.test("a row with a line end in it is one row when written one by one", function()
	local source = { format = "csv", names = { "a\nb", "c" } }
	local record = { cells = { "x\ny", "z" }, raw = "" }
	t.eq(output.head(convert("csv"), source), '"a\nb",c\n')
	t.eq(output.one(record, convert("csv"), source), '"x\ny",z\n')
end)

-- ---- the command a preview runs, and the command line that chooses again ---------------------

t.test("a preview command is given the row's values quoted for the shell", function()
	local record = { cells = { "it's", "x" }, raw = "it's x; rm -rf /" }
	local source = { names = { "a", "b" }, format = "csv" }
	t.eq(
		output.command_for("echo {} {a} {2} {zzz}", record, source),
		"echo 'it'\\''s x; rm -rf /' 'it'\\''s' x {zzz}"
	)
	t.eq(output.command_for("no placeholders", record, source), "no placeholders")
	t.eq(output.command_for("{b}{b}", record, source), "xx")
	t.eq(output.command_for("cat {}", { cells = { "" }, raw = "" }, source), "cat ''")
end)

t.test("the command line quotes what the shell would split", function()
	t.eq(output.shell_quote("NAME"), "NAME")
	t.eq(output.shell_quote("a/b-c.d_e@f%g+h=i:j,k"), "a/b-c.d_e@f%g+h=i:j,k")
	t.eq(output.shell_quote("STATUS!=Running"), "'STATUS!=Running'")
	t.eq(output.shell_quote("it's"), "'it'\\''s'")
	t.eq(output.shell_quote(""), "''")
	t.eq(output.shell_quote("a b"), "'a b'")
	t.eq(output.shell_quote("a\nb"), "'a\nb'")
	t.eq(output.shell_quote("$HOME"), "'$HOME'")
	t.eq(
		output.command_line({
			where = "STATUS!=Running cpu>50",
			sort = { column = "%CPU", descending = true },
			field = { "NAME", "PID" },
		}),
		"pickpen --where 'STATUS!=Running cpu>50' --sort -%CPU --field NAME,PID"
	)
	t.eq(
		output.command_line({ input = "lines", where = "", output = "json" }),
		"pickpen --input lines --where '' --output json"
	)
end)

t.test("the command line writes the first of field, format and output; trims the query", function()
	t.eq(
		output.command_line({ where = "  a=1\t", sort = { column = "n", descending = false } }),
		"pickpen --where a=1 --sort n"
	)
	t.eq(
		output.command_line({ where = "", field = { "a" }, format = "{a}", output = "csv" }),
		"pickpen --where '' --field a"
	)
	t.eq(
		output.command_line({ where = "", field = {}, format = "{a} {b}", output = "csv" }),
		"pickpen --where '' --format '{a} {b}'"
	)
	t.eq(
		output.command_line({ where = "", format = "", output = "csv" }),
		"pickpen --where '' --output csv"
	)
	t.eq(output.command_line({ where = "\u{A0}x\u{3000}" }), "pickpen --where x")
end)

-- ---- running the preview ------------------------------------------------------------------

-- Runs the command and waits for it to be over; gives the result, or fails if it never is.
local function run(command, width, options)
	local result
	preview.run(command, width, function(done)
		result = done
	end, options)
	local deadline = pencere.time.monotonic() + 20
	while result == nil and pencere.time.monotonic() < deadline do
		pencere.time.sleep(0.01)
	end
	t.ok(result ~= nil, "the preview did not end")
	return result
end

t.test("a preview gives what both streams printed, and the status", function()
	local result = run("printf 'out\\n'; printf 'err\\n' >&2; exit 3", 80)
	t.ok(string.find(result.text, "out\n", 1, true))
	t.ok(string.find(result.text, "err\n", 1, true))
	t.eq(#result.text, 8)
	t.eq(result.status, 3)
	t.eq(result.cut, false)
	t.eq(result.timed_out, false)
	t.eq(result.cancelled, false)
	t.eq(run("true", 80).status, 0)
end)

t.test("a preview is told the width and the height it has", function()
	t.eq(run('printf "%s %s %s" "$COLUMNS" "$LINES" "$PICKPEN_PREVIEW"', 132).text, "132 200 1")
end)

t.test("a preview keeps the colours the command printed", function()
	local colours = "\27[31mred\27[0m \27[1;32mgreen\27[0m\n"
	t.eq(run("printf '\\033[31mred\\033[0m \\033[1;32mgreen\\033[0m\\n'", 80).text, colours)
end)

t.test("a preview makes text of what is not, and does not raise", function()
	t.eq(run("printf '\\377ok'", 80).text, "\239\191\189ok")
end)

t.test("a preview runs with no terminal input, and is cut when it prints too much", function()
	local record = { cells = { "x y", "z" }, raw = "x y,z" }
	local source = { names = { "a", "b" }, format = "csv" }
	local command = output.command_for(
		"printf '%s|' {} {2}; tty || true; cat; yes | head -c 400000",
		record,
		source
	)
	local result = run(command, 80)
	t.ok(string.find(result.text, "^x y,z|z|not a tty\n"), result.text)
	t.eq(result.cut, true)
	t.eq(#result.text, 256 * 1024)
	t.eq(result.status, nil)
end)

t.test("a preview that prints more than it may is ended, one that prints as much is not", function()
	local over = run("yes", 80, { max_output = 100 })
	t.eq(over.cut, true)
	t.eq(#over.text, 100)
	t.eq(over.status, nil)
	t.eq(over.signal, 9)
	local exact = run("printf 'aaaaaaaaaa'", 80, { max_output = 10 })
	t.eq(exact.cut, false)
	t.eq(exact.text, "aaaaaaaaaa")
	t.eq(exact.status, 0)
	local one_more = run("printf 'aaaaaaaaaaa'", 80, { max_output = 10 })
	t.eq(one_more.cut, true)
	t.eq(one_more.text, "aaaaaaaaaa")
end)

t.test("a preview that runs too long is ended, and what it started with it", function()
	local started = pencere.time.monotonic()
	local result = run("printf 'begun\\n'; sleep 30 & sleep 30; echo never", 80, { timeout = 0.3 })
	t.eq(result.timed_out, true)
	t.eq(result.status, nil)
	t.eq(result.text, "begun\n")
	t.ok(pencere.time.monotonic() - started < 10, "it was not ended")
end)

t.test("a preview that is cancelled is ended and still tells it is over", function()
	local result
	local handle = preview.run("printf 'before\\n'; sleep 30; echo after", 80, function(done)
		result = done
	end)
	pencere.time.sleep(0.3)
	t.ok(result == nil, "it was over already")
	local started = pencere.time.monotonic()
	handle:cancel()
	local deadline = started + 10
	while result == nil and pencere.time.monotonic() < deadline do
		pencere.time.sleep(0.01)
	end
	t.ok(result ~= nil, "it did not end")
	t.eq(result.cancelled, true)
	t.eq(result.text, "before\n")
	t.eq(result.status, nil)
	t.eq(result.timed_out, false)
	-- A second cancel, with the command gone, is nothing.
	handle:cancel()
end)

t.test("a preview is told once that it is over, whichever way it ended", function()
	local calls = 0
	local handle = preview.run("true", 80, function()
		calls += 1
	end)
	pencere.time.sleep(0.5)
	handle:cancel()
	pencere.time.sleep(0.2)
	t.eq(calls, 1)
end)

-- ---- a hundred thousand rows --------------------------------------------------------------

local MANY = 100000
local BOUND_MS = 4000

local function many()
	local rows = {}
	for at = 1, MANY do
		local cells = { "id-" .. at, "pod number " .. at, "Running", tostring(at * 3), "x,y" }
		rows[at] = { cells = cells, raw = table.concat(cells, ",") }
	end
	return rows
end

-- Writes the rows in the shape, prints how long it took, and checks it was not long.
local function timed(label, rows, source, shape)
	local from = pencere.time.monotonic()
	local text = render(rows, shape, source)
	local took = (pencere.time.monotonic() - from) * 1000
	print(string.format("       %-14s %7d rows %8.1f ms %9d bytes", label, #rows, took, #text))
	t.ok(took < BOUND_MS, label .. " took " .. math.floor(took) .. " ms")
	t.ok(select(2, string.gsub(text, "\n", "")) >= #rows, label .. " wrote too few lines")
end

t.test("a hundred thousand rows are written in good time, in each shape", function()
	local rows = many()
	local names = { "id", "name", "status", "n", "tags" }
	local csv = { format = "csv", names = names }
	timed("input csv", rows, csv, INPUT)
	timed("input json", rows, { format = "json", names = names }, INPUT)
	timed("fields", rows, csv, fields("name", "id", "3"))
	timed("template", rows, csv, template("kubectl delete {id} # {2} {status}"))
	timed("convert csv", rows, csv, convert("csv"))
	timed("convert tsv", rows, csv, convert("tsv"))
	timed("convert jsonl", rows, csv, convert("jsonl"))
	timed("convert json", rows, csv, convert("json"))
	timed("lines word", rows, { format = "lines", names = { "line" } }, fields("2"))
end)
