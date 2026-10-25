-- Tests of reading the input: its shape from the first lines, a table lined up with spaces cut
-- into its columns as the commands that print them line them up, each record keeping the text it
-- was read from, and the pieces of JSON that the readers stand on.

local pencere = require("pencere")
local t = require("t")
local input = require("input")

local json = input.json
local columns = input.columns

local function join(lines)
	return table.concat(lines, "\n") .. "\n"
end

-- A value with every byte past ASCII written as its number, so that a failure that holds text
-- that is not UTF-8 can still be shown.
local function bytes(value)
	if type(value) == "string" then
		return (string.gsub(value, "[\128-\255]", function(char)
			return "\\" .. string.byte(char)
		end))
	elseif type(value) == "table" then
		local copy = {}
		for key, item in pairs(value) do
			copy[key] = bytes(item)
		end
		return copy
	end
	return value
end

-- Reads text the way pickpen reads standard input, in pieces of `piece` bytes (7 unless it says
-- another; 0 or more than the text is the text whole).
local function read(text, format, piece)
	piece = piece or 7
	if piece <= 0 then
		piece = math.max(1, #text)
	end
	local out = { names = {}, calls = {}, records = {}, problems = {} }
	local reader = input.Reader.new({
		columns = function(names, heading)
			out.names = names
			out.calls[#out.calls + 1] = names
			if heading ~= nil then
				out.heading = heading
			end
		end,
		record = function(record)
			out.records[#out.records + 1] = record
		end,
		problem = function(said)
			out.problems[#out.problems + 1] = said
		end,
	}, format)
	local at = 1
	while at <= #text do
		reader:feed(string.sub(text, at, at + piece - 1))
		at += piece
	end
	reader:finish()
	out.format = reader.format
	out.cells = {}
	out.raws = {}
	for i, record in ipairs(out.records) do
		out.cells[i] = record.cells
		out.raws[i] = record.raw
	end
	return out
end

local DOCKER = join({
	"CONTAINER ID   IMAGE          COMMAND                  CREATED        STAT" ..
		"US                    PORTS                    NAMES",
	"4f1c2a9e7b3d   nginx:1.27     \"/docker-entrypoint.…\"   2 hours ago    Up 2" ..
		" hours                0.0.0.0:8080->80/tcp     web",
	"9a8b7c6d5e4f   postgres:16    \"docker-entrypoint.s…\"   3 days ago     Up 3" ..
		" days (healthy)       5432/tcp                 db",
	"1a2b3c4d5e6f   redis:7        \"redis-server\"           3 days ago     Exit" ..
		"ed (0) 2 hours ago                             cache",
})

local KUBECTL = join({
	"NAME                      READY   STATUS             RESTARTS       AGE",
	"api-7d9f8b6c5d-2xkqp      1/1     Running            0              3d4h",
	"api-7d9f8b6c5d-9hjzt      1/1     Running            2 (5h ago)     3d4h",
	"worker-5c6b7d8f9-k2m4n    0/1     CrashLoopBackOff   14 (2m ago)    47m",
})

local DF = join({
	"Filesystem        Size    Used   Avail Capacity iused ifree %iused  Mounte" ..
		"d on",
	"/dev/disk3s1s1   926Gi    10Gi   612Gi     2%    426k  4.3G    0%   /",
	"devfs            204Ki   204Ki     0Bi   100%     706     0  100%   /dev",
	"/dev/disk3s6     926Gi    20Ki   612Gi     1%       0  6.4G    0%   /Syste" ..
		"m/Volumes/VM",
})

local PS = join({
	"USER               PID  %CPU %MEM      VSZ    RSS   TT  STAT STARTED      " ..
		" TIME COMMAND",
	"deployer         71234  12.3  1.1 412345678 182736   ??  S    10:01AM   1:" ..
		"02.33 /Applications/Safari.app/Contents/MacOS/Safari",
	"root               123   0.0  0.0 408123456   1234   ??  Ss   Mon09AM   0:" ..
		"00.12 /usr/sbin/syslogd",
	"_windowserver     1534   4.1  0.7 413456789 123456   ??  Ss   Mon09AM  52:" ..
		"10.45 /System/Library/WindowServer -daemon",
})

local PS_MAC = join({
	"USER               PID  %CPU %MEM      VSZ    RSS   TT  STAT STARTED      " ..
		"TIME COMMAND",
	"_windowserver      394  45.9  1.0 104487033824 350624   ??  Rs   13Oct26 3" ..
		"046:43.05 /System/Library/WindowServer -daemon",
	"someone          45283  39.3  0.5 1980409632 177600   ??  S    Wed12PM 738" ..
		":52.90 /Applications/Browser.app/Contents/MacOS/Browser --type=renderer",
	"root               123   0.0  0.0 408123456   1234   ??  Ss   Mon09AM   0:" ..
		"00.12 /usr/sbin/syslogd",
})

local LSOF = join({
	"COMMAND   PID  USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME",
	"node    12345 me   21u  IPv4 0x1a2b      0t0  TCP *:3000 (LISTEN)",
})

t.test("the shape is read from the first lines", function()
	t.eq(input.detect(DOCKER), "columns")
	t.eq(input.detect(KUBECTL), "columns")
	t.eq(input.detect(DF), "columns")
	t.eq(input.detect(PS), "columns")
	t.eq(input.detect(LSOF), "columns")
	t.eq(input.detect("/usr/bin/a /usr/lib\n/usr/bin/b /usr/lib\n"), "lines")
	t.eq(input.detect("name,age\nann,3\nbob,4\n"), "csv")
	t.eq(input.detect("name\tage\nann\t3\n"), "tsv")
	t.eq(input.detect('{"a":1}\n{"a":2}\n'), "jsonl")
	t.eq(input.detect('[{"a":1},\n{"a":2}]\n'), "json")
	t.eq(input.detect('{\n  "items": []\n}\n'), "json")
	t.eq(input.detect("a1b2c3d Fix the thing\n9f8e7d6 Add the other, and more\n"), "lines")
	t.eq(input.detect("total 48\ndrwxr-xr-x  5 me staff 160 Oct 22 10:00 src\n"), "lines")
	t.eq(input.detect("[2026-10-22 10:00:01] started\n[2026-10-22 10:00:02] ready\n"), "lines")
	t.eq(input.detect("just one line\n"), "lines")
	t.eq(input.detect(""), "lines")
end)

t.test("docker's columns hold values with spaces of their own", function()
	local got = read(DOCKER)
	t.eq(got.names, { "CONTAINER ID", "IMAGE", "COMMAND", "CREATED", "STATUS", "PORTS", "NAMES" })
	t.eq(got.cells[1], {
		"4f1c2a9e7b3d",
		"nginx:1.27",
		'"/docker-entrypoint.…"',
		"2 hours ago",
		"Up 2 hours",
		"0.0.0.0:8080->80/tcp",
		"web",
	})
	t.eq(got.cells[2][5], "Up 3 days (healthy)")
	t.eq({ table.unpack(got.cells[3], 5) }, { "Exited (0) 2 hours ago", "", "cache" })
end)

t.test("kubectl's restarts keep when they were", function()
	local got = read(KUBECTL)
	t.eq(got.names, { "NAME", "READY", "STATUS", "RESTARTS", "AGE" })
	t.eq(got.cells[2], { "api-7d9f8b6c5d-9hjzt", "1/1", "Running", "2 (5h ago)", "3d4h" })
	t.eq(
		got.cells[3],
		{ "worker-5c6b7d8f9-k2m4n", "0/1", "CrashLoopBackOff", "14 (2m ago)", "47m" }
	)
end)

t.test("df's right-aligned numbers and its heading of two words", function()
	local got = read(DF)
	t.eq(got.names, {
		"Filesystem",
		"Size",
		"Used",
		"Avail",
		"Capacity",
		"iused",
		"ifree",
		"%iused",
		"Mounted on",
	})
	t.eq(got.cells[2], { "devfs", "204Ki", "204Ki", "0Bi", "100%", "706", "0", "100%", "/dev" })
	t.eq(got.cells[3][9], "/System/Volumes/VM")
end)

t.test("ps's last column takes the rest of the line, spaces and all", function()
	local got = read(PS)
	t.eq(got.names[#got.names], "COMMAND")
	t.eq(got.names[2], "PID")
	t.eq({ got.cells[1][2], got.cells[2][2], got.cells[3][2] }, { "71234", "123", "1534" })
	t.eq(got.cells[3][#got.cells[3]], "/System/Library/WindowServer -daemon")
	t.eq(got.cells[1][1], "deployer")
end)

t.test("a table whose wide values push the line out of line is split at its spaces", function()
	t.eq(input.detect(PS_MAC), "columns")
	local got = read(PS_MAC)
	t.eq(got.names, {
		"USER",
		"PID",
		"%CPU",
		"%MEM",
		"VSZ",
		"RSS",
		"TT",
		"STAT",
		"STARTED",
		"TIME",
		"COMMAND",
	})
	t.eq(got.cells[1], {
		"_windowserver",
		"394",
		"45.9",
		"1.0",
		"104487033824",
		"350624",
		"??",
		"Rs",
		"13Oct26",
		"3046:43.05",
		"/System/Library/WindowServer -daemon",
	})
	t.eq(got.cells[2][11], "/Applications/Browser.app/Contents/MacOS/Browser --type=renderer")
	t.eq({ got.cells[1][2], got.cells[2][2], got.cells[3][2] }, { "394", "45283", "123" })
end)

t.test("a later line wider than the first ones is cut at the nearest space", function()
	local starts = columns.starts("NAME    PID", { "ab      12" })
	t.eq(starts, { 1, 9 })
	t.eq(columns.cut("abcdefghij 1234", starts), { "abcdefghij", "1234" })
	t.eq(columns.cut("ab    123456", starts), { "ab", "123456" })
end)

t.test("CSV keeps quoted commas and line breaks, and each record's own text", function()
	local text = 'name,note\r\nann,"a, b"\r\nbob,"two\nlines"\ncat,"say ""hi"""\n'
	local got = read(text, nil, 3)
	t.eq(got.format, "csv")
	t.eq(got.names, { "name", "note" })
	t.eq(got.heading, "name,note")
	t.eq(got.cells, { { "ann", "a, b" }, { "bob", "two\nlines" }, { "cat", 'say "hi"' } })
	t.eq(got.raws, { 'ann,"a, b"', 'bob,"two\nlines"', 'cat,"say ""hi"""' })
end)

t.test("headings are made unique and never empty", function()
	t.eq(read("a,,a,A\n1,2,3,4\n").names, { "a", "column 2", "a 2", "A 3" })
end)

t.test("JSON lines: keys are columns as they come, a line that is not JSON is told", function()
	local got = read('{"a":1,"b":{"c":2}}\nnot json\n{"b":null,"d":true}\n')
	t.eq(got.format, "jsonl")
	t.eq(got.names, { "a", "b", "d" })
	t.eq(got.cells, { { "1", '{"c":2}' }, { "", "", "true" } })
	t.eq(got.problems, { "A line is not JSON" })
	local value = got.records[2].value
	t.ok(json.is_object(value))
	t.eq(value.keys, { "b", "d" })
	t.ok(value.map.b == json.null)
	t.eq(value.map.d, true)
end)

t.test("a JSON document is its array, or the one array of objects it holds", function()
	t.eq(read('[{"x":1},{"x":2}]').cells, { { "1" }, { "2" } })
	local kube = read('{"apiVersion":"v1","items":[{"name":"a"},{"name":"b"}],"kind":"List"}')
	t.eq(kube.names, { "name" })
	t.eq(kube.cells, { { "a" }, { "b" } })
	t.eq(read("[1,2]").cells, { { "1" }, { "2" } })
	t.eq(read("[1, 2", "json").problems, { "The input is not one JSON document" })
end)

t.test("lines: blank ones skipped, colour codes and CR dropped", function()
	local got = read("\27[32mone\27[0m\r\n\n  \ntwo\n")
	t.eq(got.format, "lines")
	t.eq(got.names, { "line" })
	t.eq(got.raws, { "one", "two" })
end)

t.test("--input decides at once, so a slow first line is not waited on", function()
	local rows = {}
	local reader = input.Reader.new({
		columns = function() end,
		record = function(record)
			rows[#rows + 1] = record.raw
		end,
		problem = function() end,
	}, "lines")
	reader:feed("first\n")
	t.eq(reader.format, "lines")
	t.eq(rows, { "first" })
end)

-- plain ---------------------------------------------------------------------------------------

t.test("plain drops colours, moves, titles and links, and keeps text and lone escapes", function()
	local plain = input.plain
	t.eq(plain("no codes"), "no codes")
	t.eq(plain("\27[1;31mred\27[0m"), "red")
	t.eq(plain("\27[38;5;196mx\27[2K\27[?25l"), "x")
	t.eq(plain("a\27]0;a title\7b"), "ab")
	t.eq(plain("\27]8;;https://example.com\27\\link\27]8;;\27\\"), "link")
	t.eq(plain("up\27Mdown"), "updown")
	-- Not a code: kept.
	t.eq(plain("a\27cb"), "a\27cb")
	t.eq(plain("end\27"), "end\27")
	t.eq(plain("cut\27[12"), "cut\27[12")
	-- An ESC ] with no end is the two-byte code and nothing more.
	t.eq(plain("a\27]0;title"), "a0;title")
	t.eq(plain("\27[31mrésumé ünï\27[0m"), "résumé ünï")
end)

-- text ----------------------------------------------------------------------------------------

t.test("trim and blank know the white space that is not ASCII", function()
	local text = require("input.text")
	t.eq(text.trim("  a b \t"), "a b")
	t.eq(text.trim(""), "")
	t.eq(text.trim(" \t\r\n"), "")
	t.eq(text.trim("\194\160 name \194\160"), "name")
	t.eq(text.trim("\239\187\191name"), "name")
	t.eq(text.trim("\227\128\128 x \226\128\131"), "x")
	t.eq(text.trim("a\194\160b"), "a\194\160b")
	t.eq(text.trim("é "), "é")
	t.eq(text.trim("\226\130"), "\226\130")
	t.eq(text.trim("x\226\128"), "x\226\128")
	t.ok(text.is_blank(""))
	t.ok(text.is_blank(" \t "))
	t.ok(text.is_blank("\194\160\226\128\168"))
	t.ok(not text.is_blank("\194\160x"))
	t.ok(not text.is_blank("é"))
end)

t.test("a column is a character, and a stray byte is one of its own", function()
	local text = require("input.text")
	t.eq(text.count("abc"), 3)
	t.eq(text.count("Größe"), 5)
	t.eq(text.count("a\255b"), 3)
	-- A sequence cut short is one character, as a decoder that replaces what it cannot read has it.
	t.eq(text.count("a\226\130b"), 3)
	t.eq(text.count("\237\160\128"), 3)
	t.eq(text.count("\192\128"), 2)
	t.eq(text.shape("ab c"), "ab c")
	t.eq((text.shape("Größe x")), "Grxxe x")
	t.eq((text.shape("\255 \226\130 é")), "x x x")
	local offset = text.offsetter("aé\255b")
	t.eq({ offset(1), offset(2), offset(3), offset(4), offset(5) }, { 1, 2, 4, 5, 6 })
	local valid = text.offsetter("aéb")
	t.eq({ valid(1), valid(2), valid(3), valid(4) }, { 1, 2, 4, 5 })
	t.eq(text.first_char("Ünal"), "Ü")
	t.eq(text.first_char("\255x"), "\255")
	t.eq(text.first_char(""), "")
end)

-- columns -------------------------------------------------------------------------------------

t.test("a table with non-ASCII values is cut in characters, not bytes", function()
	local text = join({
		"NAME      SIZE   CITY",
		"Çağrı     120    İzmir",
		"Ünal      7      Köln",
		"Zoë       55     Zürich",
	})
	t.eq(input.detect(text), "columns")
	local got = read(text)
	t.eq(got.names, { "NAME", "SIZE", "CITY" })
	t.eq(got.cells, {
		{ "Çağrı", "120", "İzmir" },
		{ "Ünal", "7", "Köln" },
		{ "Zoë", "55", "Zürich" },
	})
	t.eq(got.raws[1], "Çağrı     120    İzmir")
end)

t.test("a heading may begin with a capital that is not ASCII", function()
	t.eq(input.detect("ÜBER  SIZE\nfoo   12\n"), "columns")
	t.eq(input.detect("Ünal  SIZE\nfoo   12\n"), "columns")
	t.eq(input.detect("über  SIZE\nfoo   12\n"), "lines")
	t.eq(input.detect("Größe  Name  Zeit\n12     foo   3\n"), "columns")
	t.eq(columns.names_of({ "Name", "name", "NAME", "", " x ", "" }), {
		"Name",
		"name 2",
		"NAME 3",
		"column 4",
		"x",
		"column 6",
	})
end)

t.test("what looks like a heading, and what is a value", function()
	local heading = columns.looks_like_heading
	t.ok(heading("NAME READY STATUS"))
	t.ok(heading("COMMAND   PID  SIZE/OFF NODE"))
	t.ok(heading("Filesystem Size Used"))
	t.ok(not heading("NAME"))
	t.ok(not heading(""))
	t.ok(not heading("name ready status"))
	t.ok(not heading("/usr/bin /usr/lib"))
	t.ok(not heading("NAME 12 STATUS"))
	t.ok(not heading("NAME -1 STATUS"))
	t.ok(not heading("NAME a=1 STATUS"))
	t.ok(not heading("TIME 10:00 STATUS"))
	t.ok(not heading("NAME .hidden STATUS"))
	t.ok(not heading("NAME ~/home STATUS"))
	t.ok(heading("NAME " .. string.rep("x", 32)))
	t.ok(not heading("NAME " .. string.rep("x", 33)))
	t.ok(heading("A" .. string.rep(" B", 39)))
	t.ok(not heading("A" .. string.rep(" B", 40)))
end)

t.test("split_words gives the last cell the rest of the line", function()
	t.eq(columns.split_words("  a   b c d  ", 3), { "a", "b", "c d" })
	t.eq(columns.split_words("a b", 4), { "a", "b" })
	t.eq(columns.split_words("a", 1), { "a" })
	t.eq(columns.split_words("   ", 3), {})
	t.eq(columns.split_words("a  b  c", 2), { "a", "b  c" })
end)

t.test("column starts: a space under every line, a word over it", function()
	t.eq(columns.starts("", {}), {})
	t.eq(columns.starts("A", {}), { 1 })
	t.eq(columns.starts("A  B   C", {}), { 1, 4, 8 })
	-- A value that crosses every gap joins the columns.
	t.eq(columns.starts("A  B   C", { "xxxxxxxx" }), { 1 })
	-- A column of values wider than its heading begins before the heading's word.
	t.eq(columns.starts("A  B   C", { "xxxxx 1" }), { 1, 7 })
	-- The first column begins at the line's start even when a right-aligned value is wider.
	t.eq(columns.starts("  PID NAME", { "12345 foo" }), { 1, 7 })
	t.eq(columns.cut("", { 1, 4 }), { "", "" })
	t.eq(columns.cut("abc", {}), {})
	-- A word that crosses a boundary: nearest space, left on a tie; no space near, and it stays.
	t.eq(columns.cut("ab cdefgh ij", { 1, 6 }), { "ab", "cdefgh ij" })
	t.eq(columns.cut("abcdefghij", { 1, 6 }), { "abcde", "fghij" })
	t.eq(columns.cut("ab", { 1, 5, 9 }), { "ab", "", "" })
end)

t.test("a stray byte is a character in a table, and nothing raises", function()
	local text = join({
		"NAME      SIZE",
		"é\255x       12",
		"\226\130x        7",
		"\255\254\253\252      9",
	})
	local got = read(text, "columns")
	t.eq(got.names, { "NAME", "SIZE" })
	t.eq(
		bytes(got.cells),
		bytes({ { "é\255x", "12" }, { "\226\130x", "7" }, { "\255\254\253\252", "9" } })
	)
	t.eq(
		bytes(read("NAME   X\n\255\254\255\254   y\n").cells),
		bytes({ { "\255\254\255\254", "y" } })
	)
	t.eq(#read("\255\254 Z\n\255 y\n\255\n").records, 3)
end)

t.test("a heading alone is the columns, once it is known to be alone", function()
	local got = read("NAME   STATUS\n", "columns")
	t.eq(got.names, { "NAME", "STATUS" })
	t.eq(#got.records, 0)
	t.eq(got.calls, { { "NAME", "STATUS" } })
	-- Not told until a line comes under it (a space may be inside a heading: `IMAGE ID`).
	local told = {}
	local reader = input.Reader.new({
		columns = function(names)
			told[#told + 1] = names
		end,
		record = function() end,
		problem = function() end,
	}, "columns")
	reader:feed("IMAGE ID   SIZE\n")
	t.eq(told, {})
	reader:feed("abc123456   12\n")
	t.eq(told, { { "IMAGE ID", "SIZE" } })
end)

t.test("a table of one column or one word is lines", function()
	t.eq(input.detect("NAME\nfoo\nbar\n"), "lines")
	t.eq(read("NAME\nfoo\n").format, "lines")
end)

t.test("a table with a very wide cell is cut and kept whole", function()
	local wide = string.rep("x", 200000)
	local got = read(join({ "NAME      SIZE", "foo       12", wide .. "  7" }), "columns", 0)
	t.eq(got.cells[1], { "foo", "12" })
	t.eq(got.cells[2], { wide, "7" })
end)

-- json ----------------------------------------------------------------------------------------

t.test("json values keep the order of keys, null, and the empty array from the object", function()
	local value = assert(json.parse('{"b":1,"a":[],"2":{},"1":null}'))
	t.ok(json.is_object(value))
	t.ok(not json.is_array(value))
	t.eq(value.keys, { "b", "a", "2", "1" })
	t.ok(json.is_array(value.map.a))
	t.eq(value.map.a.n, 0)
	t.ok(json.is_object(value.map["2"]))
	t.ok(value.map["1"] == json.null)
	t.ok(json.null ~= nil and json.null ~= false)
	t.eq(tostring(json.null), "null")
	t.ok(not json.is_object(json.null) and not json.is_array(json.null))
	t.ok(not json.is_array("x") and not json.is_object(1) and not json.is_object(nil))
end)

t.test("json builders make what the parser makes", function()
	local built = json.object({ { "a", json.array({ 1, "x", json.null }) }, { "b", true } })
	t.eq(json.encode(built), '{"a":[1,"x",null],"b":true}')
	t.eq(json.encode(json.object({})), "{}")
	t.eq(json.encode(json.array({})), "[]")
	local twice = json.object({ { "a", 1 }, { "b", 2 }, { "a", 3 } })
	t.eq(twice.keys, { "a", "b" })
	t.eq(json.encode(twice), '{"a":3,"b":2}')
end)

t.test("a key written twice keeps its first place and its last value", function()
	local value = assert(json.parse('{"a":1,"b":2,"a":3}'))
	t.eq(value.keys, { "a", "b" })
	t.eq(value.map.a, 3)
end)

t.test("json reads a pair the slow way when it has an escape or white space about it", function()
	local text = '{"k\\"1" :\t"v" , "\\u00e9":\n1,\r\n"s" : "a\\nb","n":-2.5e1 }'
	local value = assert(json.parse(text))
	t.eq(value.keys, { 'k"1', "é", "s", "n" })
	t.eq(value.map['k"1'], "v")
	t.eq(value.map["é"], 1)
	t.eq(value.map.s, "a\nb")
	t.eq(value.map.n, -25)
	local plain =
		assert(json.parse('{"a":"x","b":7,"c":-0,"d":1.5,"e":[1],"f":{"g":null},"h":true}'))
	t.eq(plain.keys, { "a", "b", "c", "d", "e", "f", "h" })
	t.eq(plain.map.d, 1.5)
	t.ok(plain.map.f.map.g == json.null)
	t.eq(plain.map.h, true)
	t.ok(json.parse('{"a":01}') == nil)
	t.ok(json.parse('{"a":1.}') == nil)
	t.ok(json.parse('{"a":-}') == nil)
	t.ok(json.parse('{"a":"x" "b":1}') == nil and json.parse('{"a" "x"}') == nil)
	t.ok(json.parse('{"a":"unterminated}') == nil and json.parse('{"a\\"') == nil)
end)

t.test("json parses scalars, white space and nesting", function()
	t.eq(json.parse(" \t\r\n 42 \n"), 42)
	t.eq(json.parse("-0.5e1"), -5)
	t.eq(json.parse("1E3"), 1000)
	t.eq(json.parse("true"), true)
	t.eq(json.parse("false"), false)
	t.ok(json.parse("null") == json.null)
	t.eq(json.parse('"a b"'), "a b")
	t.eq(json.parse("[ ]").n, 0)
	local spaced = json.parse('{ "a" : [ 1 , { "b" : [ ] } ] , "c" : { } }')
	t.eq(json.encode(spaced), '{"a":[1,{"b":[]}],"c":{}}')
	local deep = string.rep("[", 512) .. string.rep("]", 512)
	t.ok(json.parse(deep) ~= nil)
	local too_deep, why = json.parse(string.rep("[", 513) .. string.rep("]", 513))
	t.eq(too_deep, nil)
	t.ok(string.find(why, "too deep", 1, true))
	local object_deep = string.rep('{"a":', 600) .. "1" .. string.rep("}", 600)
	t.eq((json.parse(object_deep)), nil)
	-- Unclosed and deep at once does not run out of stack either.
	t.eq((json.parse(string.rep("[", 100000))), nil)
end)

t.test("json parses strings, escapes, surrogate pairs and text that is not UTF-8", function()
	t.eq(json.parse('"a\\"b\\\\c\\/d\\b\\f\\n\\r\\t"'), 'a"b\\c/d\b\f\n\r\t')
	t.eq(json.parse('"\\u00e9\\u0041\\u20ac"'), "éA€")
	t.eq(json.parse('"\\ud83d\\ude00"'), "\240\159\152\128")
	t.eq(json.parse('"\\u0000"'), "\0")
	-- Half a pair is the replacement character (UTF-8 has no room for it).
	t.eq(json.parse('"\\ud83dx"'), "\239\191\189x")
	t.eq(json.parse('"\\ude00"'), "\239\191\189")
	t.eq(json.parse('"\\ud83d\\u0041"'), "\239\191\189A")
	t.eq(json.parse('"tab\\tand é and 日本"'), "tab\tand é and 日本")
	t.eq(bytes(json.parse('"a\255b"')), bytes("a\255b"))
end)

t.test("json refuses what is not one value, and says so", function()
	local bad = {
		"",
		"  ",
		"[1,]",
		"[1 2]",
		"{,}",
		'{"a":1,}',
		'{"a" 1}',
		"{a:1}",
		"{'a':1}",
		"[1",
		'{"a":1',
		'"abc',
		'"a\nb"',
		'"a\\x"',
		'"\\u12"',
		"01",
		"-",
		"1.",
		".5",
		"+1",
		"1e",
		"1e+",
		"nul",
		"truee",
		"[1] 2",
		"{} {}",
		"\239\187\191{}",
		"NaN",
		"[tru]",
	}
	for _, text in ipairs(bad) do
		local value, why = json.parse(text)
		t.ok(value == nil, "parsed: " .. bytes(text))
		t.eq(type(why), "string")
	end
	t.eq((json.parse(nil)), nil)
	t.eq((json.parse(5)), nil)
end)

t.test("json writes numbers the way a script of another language does", function()
	local cases = {
		{ 1, "1" },
		{ -1, "-1" },
		{ 0, "0" },
		{ -0.0, "0" },
		{ 1.5, "1.5" },
		{ -0.5, "-0.5" },
		{ 100, "100" },
		{ 0.1, "0.1" },
		{ 0.1 + 0.2, "0.30000000000000004" },
		{ 1 / 3, "0.3333333333333333" },
		{ 2 / 3, "0.6666666666666666" },
		{ 123.456, "123.456" },
		{ 4.35, "4.35" },
		{ 1e20, "100000000000000000000" },
		{ 1e21, "1e+21" },
		{ 1.5e21, "1.5e+21" },
		{ 123456789012345680000, "123456789012345680000" },
		{ 2 ^ 53, "9007199254740992" },
		{ 2 ^ 53 + 2, "9007199254740994" },
		{ 2 ^ 63, "9223372036854776000" },
		{ 0.000001, "0.000001" },
		{ 0.0000001, "1e-7" },
		{ 1.5e-7, "1.5e-7" },
		{ 1.2345e-10, "1.2345e-10" },
		{ 5e-324, "5e-324" },
		{ 1.7976931348623157e308, "1.7976931348623157e+308" },
		{ 1e300, "1e+300" },
		{ 123456789.125, "123456789.125" },
		{ -1e-7, "-1e-7" },
	}
	for _, case in ipairs(cases) do
		t.eq(json.encode(case[1]), case[2], "encode " .. case[2])
		t.eq(json.text_of(case[1]), case[2], "text_of " .. case[2])
		t.eq(json.parse(case[2]), case[1], "parse " .. case[2])
	end
	t.eq(json.encode(0 / 0), "null")
	t.eq(json.encode(math.huge), "null")
	t.eq(json.encode(-math.huge), "null")
	t.eq(json.text_of(0 / 0), "NaN")
	t.eq(json.text_of(math.huge), "Infinity")
	t.eq(json.text_of(-math.huge), "-Infinity")
	t.eq(json.parse("1e999"), math.huge)
	t.eq(json.parse("12345678901234567890"), 12345678901234567890)
	t.eq(json.encode(json.parse("1.0")), "1")
	t.eq(json.encode(json.parse("1e2")), "100")
end)

t.test("json writes strings as a script of another language does", function()
	t.eq(json.encode('a"b\\c/d'), '"a\\"b\\\\c/d"')
	t.eq(json.encode("\b\f\n\r\t"), '"\\b\\f\\n\\r\\t"')
	t.eq(json.encode("\0\1\31\127"), '"\\u0000\\u0001\\u001f\127"')
	local wide = "é日本\240\159\152\128 \226\128\168"
	t.eq(json.encode(wide), '"' .. wide .. '"')
	t.eq(json.encode(json.object({ { 'k"ey', "v" } })), '{"k\\"ey":"v"}')
	t.eq(json.encode("plain"), '"plain"')
	t.eq(json.encode(""), '""')
end)

t.test("json writes with an indent as a script of another language does", function()
	local value = assert(json.parse('{"a":[1,2,{"x":null}],"b":{},"c":[],"d":"s","e":[[]]}'))
	t.eq(
		json.encode(value, 2),
		join({
			"{",
			'  "a": [',
			"    1,",
			"    2,",
			"    {",
			'      "x": null',
			"    }",
			"  ],",
			'  "b": {},',
			'  "c": [],',
			'  "d": "s",',
			'  "e": [',
			"    []",
			"  ]",
			"}",
		}):sub(1, -2)
	)
	t.eq(json.encode(json.array({ 1, 2 }), 1), "[\n 1,\n 2\n]")
	t.eq(json.encode(json.array({ 1 }), "\t"), "[\n\t1\n]")
	t.eq(json.encode(json.array({ 1 }), 0), "[1]")
	t.eq(json.encode(json.array({ 1 }), nil), "[1]")
	t.eq(json.encode(json.array({ 1 }), 20), "[\n          1\n]")
	t.eq(json.encode(7, 2), "7")
end)

t.test("json encode refuses what it cannot write, and does not follow a cycle", function()
	t.raises(function()
		json.encode({ 1, 2 })
	end, "neither")
	t.raises(function()
		json.encode(function() end)
	end, "function")
	local loop = json.array({ 1 })
	loop[2] = loop
	loop.n = 2
	t.raises(function()
		json.encode(loop)
	end, "too deep")
end)

t.test("text_of is what a cell shows of a value", function()
	t.eq(json.text_of(json.null), "")
	t.eq(json.text_of("s"), "s")
	t.eq(json.text_of(true), "true")
	t.eq(json.text_of(false), "false")
	t.eq(json.text_of(12), "12")
	t.eq(json.text_of(assert(json.parse('{"c":2,"a":[1,"x"]}'))), '{"c":2,"a":[1,"x"]}')
	t.eq(json.text_of(json.array({})), "[]")
	t.eq(json.text_of(nil), "")
end)

t.test("json round trips what the parser reads", function()
	local texts = {
		'{"time":"2026-10-22T09:00:00.529Z","ms":42,"ok":true,"tags":["a","b"],"n":null}',
		'[1,2.5,"x",[],{},[{"a":[[]]}]]',
		'{"é":"日本語","esc":"a\\nb\\t\\u0001"}',
	}
	for _, text in ipairs(texts) do
		t.eq(json.encode(assert(json.parse(text))), text)
	end
end)

-- CSV and TSV ---------------------------------------------------------------------------------

t.test("CSV: empty fields, fewer cells than the heading, and a quote that is no opening", function()
	local got = read('a,b,c\n1,,3\n,,\nx\nsay "hi",q"r,"",z\n', "csv")
	t.eq(got.names, { "a", "b", "c" })
	t.eq(got.cells, { { "1", "", "3" }, { "", "", "" }, { "x" }, { 'say "hi"', 'q"r', "", "z" } })
end)

t.test("CSV: blank lines are skipped, and so is a line of colour codes alone", function()
	local got = read("a,b\n\n1,2\r\n \n\27[0m\n3,4\n", "csv")
	t.eq(got.cells, { { "1", "2" }, { "3", "4" } })
	t.eq(got.raws, { "1,2", "3,4" })
end)

t.test("CSV: colour codes are dropped from the cells and from the text", function()
	local got = read("a,b\n\27[31mred\27[0m,x\n", "csv")
	t.eq(got.cells, { { "red", "x" } })
	t.eq(got.raws, { "red,x" })
end)

t.test("CSV: a carriage return inside a field is not in the cell but is in the text", function()
	local got = read("a,b\nx\ry,z\r\n", "csv")
	t.eq(got.cells, { { "xy", "z" } })
	t.eq(got.raws, { "x\ry,z" })
	-- Inside quotes it is the field's own.
	t.eq(read('a\n"x\r\ny"\n', "csv").cells, { { "x\r\ny" } })
end)

t.test("CSV: a piece may end inside a quoted field, or between the quotes of a pair", function()
	local text = 'k,v\n"a,b","c\nd"\n"say ""hi""",x\n"""",y\n'
	for _, piece in ipairs({ 1, 2, 3, 5, 0 }) do
		local got = read(text, "csv", piece)
		t.eq(got.cells, { { "a,b", "c\nd" }, { 'say "hi"', "x" }, { '"', "y" } }, "piece " .. piece)
		t.eq(got.raws, { '"a,b","c\nd"', '"say ""hi""",x', '"""",y' }, "piece " .. piece)
	end
end)

t.test("CSV: a quote that never closes ends with the input, and its text is a record", function()
	local got = read('a,b\n1,"two\nthree', "csv")
	t.eq(got.cells, { { "1", "two\nthree" } })
	t.eq(got.raws, { '1,"two\nthree' })
end)

t.test("CSV: a last record without a line end is a record", function()
	t.eq(read("a,b\n1,2", "csv").cells, { { "1", "2" } })
	t.eq(read("a,b\n1,2\n\n\n", "csv").cells, { { "1", "2" } })
end)

t.test("CSV: a heading alone, and nothing at all", function()
	local got = read("a,b,c\n", "csv")
	t.eq(got.names, { "a", "b", "c" })
	t.eq(got.heading, "a,b,c")
	t.eq(#got.records, 0)
	local none = read("", "csv")
	t.eq(none.calls, {})
	t.eq(#none.records, 0)
	t.eq(read("\n\n  \n", "csv").calls, {})
end)

t.test("CSV: the heading's own text goes with the columns, colour codes dropped", function()
	local got = read('"a b","c"\r\n1,2\r\n', "csv")
	t.eq(got.names, { "a b", "c" })
	t.eq(got.heading, '"a b","c"')
	t.eq(read("\27[1mx\27[0m,y\n1,2\n", "csv").heading, "x,y")
end)

t.test("TSV: tabs divide, commas do not, and a quoted tab stays", function()
	local got = read('name\tnote\nann\ta, b\nbob\t"x\ty"\n', "tsv")
	t.eq(got.names, { "name", "note" })
	t.eq(got.cells, { { "ann", "a, b" }, { "bob", "x\ty" } })
	t.eq(got.raws, { "ann\ta, b", 'bob\t"x\ty"' })
	t.eq(read("a\tb\n1\t\n", "tsv").cells, { { "1", "" } })
end)

t.test("CSV: a huge cell is kept whole, whatever the pieces", function()
	local huge = string.rep("x,y\"z", 200000)
	local text = 'k,v\n"' .. string.gsub(huge, '"', '""') .. '",end\n'
	local got = read(text, "csv", 4096)
	t.eq(#got.cells, 1)
	t.eq(got.cells[1][1], huge)
	t.eq(got.cells[1][2], "end")
	local plain_cell = string.rep("abc", 400000)
	t.eq(read("k\n" .. plain_cell .. "\n", "csv", 65536).cells[1][1], plain_cell)
end)

-- Lines ---------------------------------------------------------------------------------------

t.test("lines: a line cut between pieces is one line, and one with no end is a line", function()
	for _, piece in ipairs({ 1, 2, 3, 0 }) do
		local got = read("one\r\ntwo\n\nthree", "lines", piece)
		t.eq(got.raws, { "one", "two", "three" }, "piece " .. piece)
		t.eq(got.cells, { { "one" }, { "two" }, { "three" } })
	end
	t.eq(read("a\n", "lines").names, { "line" })
	-- A carriage return is cut off whichever piece it falls at the end of.
	t.eq(read("x\r\ny\r\n", "lines", 2).raws, { "x", "y" })
end)

t.test("lines: nothing at all is the one column and no record", function()
	local got = read("", "lines")
	t.eq(got.names, { "line" })
	t.eq(#got.records, 0)
	t.eq(read("\n \n\27[0m\n").raws, {})
end)

t.test("lines: a huge line is kept whole, and text that is not UTF-8 goes through", function()
	local huge = string.rep("x", 3000000)
	t.eq(read(huge .. "\n", "lines", 65536).raws, { huge })
	t.eq(bytes(read("a\255b\n\254\n", "lines").raws), bytes({ "a\255b", "\254" }))
end)

-- JSON lines and documents -----------------------------------------------------------------

t.test("JSON lines: a column that comes later is told, and earlier cells are shorter", function()
	local got = read('{"a":1}\n{"b":2}\n{"a":3,"b":4,"c":5}\n{"c":6}\n', "jsonl")
	t.eq(got.calls, { { "a" }, { "a", "b" }, { "a", "b", "c" } })
	t.eq(got.cells, { { "1" }, { "", "2" }, { "3", "4", "5" }, { "", "", "6" } })
	t.eq(got.raws[2], '{"b":2}')
end)

t.test("JSON lines: what is no object is a cell of the column value", function()
	local got = read('5\n"text"\n[1,2]\nnull\ntrue\n{"value":"v"}\n', "jsonl")
	t.eq(got.names, { "value" })
	t.eq(got.cells, { { "5" }, { "text" }, { "[1,2]" }, { "" }, { "true" }, { "v" } })
	t.eq(got.records[1].value, 5)
	t.ok(got.records[4].value == json.null)
	t.eq(got.problems, {})
	-- And beside the keys of the objects.
	local mixed = read('{"a":1}\n7\n', "jsonl")
	t.eq(mixed.names, { "a", "value" })
	t.eq(mixed.cells, { { "1" }, { "", "7" } })
end)

t.test("JSON lines: a line that is not JSON is told once, then by the thousand", function()
	local lines = {}
	for i = 1, 2500 do
		lines[i] = i == 7 and '{"a":1}' or "not json " .. i
	end
	local got = read(join(lines), "jsonl", 4096)
	t.eq(
		got.problems,
		{ "A line is not JSON", "1000 lines are not JSON", "2000 lines are not JSON" }
	)
	t.eq(#got.records, 1)
end)

t.test("JSON lines: colour codes and a carriage return are not in the line", function()
	local got = read('\27[32m{"a":"x"}\27[0m\r\n', "jsonl")
	t.eq(got.cells, { { "x" } })
	t.eq(got.raws, { '{"a":"x"}' })
end)

t.test("a JSON document: an object that holds no rows is the row, a scalar is a value", function()
	local one = read('{"name":"a","tags":[1,2],"more":[{"x":1}],"also":[{"y":1}]}', "json")
	t.eq(one.names, { "name", "tags", "more", "also" })
	t.eq(one.cells, { { "a", "[1,2]", '[{"x":1}]', '[{"y":1}]' } })
	t.eq(read("7", "json").cells, { { "7" } })
	t.eq(read('"s"', "json").names, { "value" })
	local empty = read("[]", "json")
	t.eq(empty.names, { "value" })
	t.eq(#empty.records, 0)
	t.eq(read("{}", "json").cells, { {} })
	t.eq(read("[{},{}]", "json").names, { "value" })
end)

t.test("a JSON document: each row keeps its text and its value, whatever the pieces", function()
	local text = '[\n  {"a": 1, "b": [1, 2]},\n  {"a": 2.50, "c": "é"}\n]\n'
	for _, piece in ipairs({ 1, 3, 0 }) do
		local got = read(text, nil, piece)
		t.eq(got.format, "json")
		t.eq(got.names, { "a", "b", "c" })
		t.eq(got.cells, { { "1", "[1,2]" }, { "2.5", "", "é" } })
		t.eq(got.raws, { '{"a":1,"b":[1,2]}', '{"a":2.5,"c":"é"}' })
		t.eq(got.records[2].value.keys, { "a", "c" })
	end
	t.eq(read("[1, 2", "json").calls, {})
	t.eq(read("", "json").problems, { "The input is not one JSON document" })
end)

-- Detect ---------------------------------------------------------------------------------------

t.test("detect: JSON by its first line", function()
	t.eq(input.detect('{"items":[{"a":1}]}'), "json")
	t.eq(input.detect('{"items":[{"a":1}]}\n'), "json")
	-- Not alone yet: it may be the first of many lines.
	t.eq(input.detect('{"items":[{"a":1}]}\n', false), "jsonl")
	t.eq(input.detect('{"items":[{"a":1}]}\n{"items":[]}\n'), "jsonl")
	t.eq(input.detect('{"a":1,"b":[1]}'), "jsonl")
	t.eq(input.detect('{"a":[{"x":1}],"b":[{"y":1}]}'), "jsonl")
	t.eq(input.detect("[1,2,3]\n"), "json")
	t.eq(input.detect("[\n"), "json")
	t.eq(input.detect("{\n"), "json")
	t.eq(input.detect('{"a":\n'), "json")
	t.eq(input.detect('[{"a":\n'), "json")
	t.eq(input.detect('["a",\n'), "json")
	t.eq(input.detect("[[1,\n"), "json")
	-- Looks like JSON but is not enough of it.
	t.eq(input.detect("[1,\n"), "lines")
	t.eq(input.detect("{a}\n"), "lines")
	t.eq(input.detect("[INFO] started\n[INFO] ready\n"), "lines")
	t.eq(input.detect('  {"a":1}  \n{"a":2}\n'), "jsonl")
end)

t.test("detect: tabs, commas and spaces", function()
	t.eq(input.detect("a\tb\tc\n1\t2\t3\n4\t5\t6\n"), "tsv")
	-- Different counts of tabs: not a table of tabs.
	t.eq(input.detect("a\tb\n1\t2\t3\n"), "lines")
	t.eq(input.detect("a,b,c\n1,2,3\n4,5\n"), "lines")
	t.eq(input.detect("a,b\n1,2\n"), "csv")
	t.eq(input.detect("a\n1\n"), "lines")
	t.eq(input.detect("a,b,c\n1,2,3\n"), "csv")
	-- Two spaces in the first line: a table of spaces, whatever commas it has.
	t.eq(input.detect("NAME  NOTE, x, y\nfoo   a, b, c\n"), "columns")
	t.eq(input.detect('a,b,c\n1,"x,y",3\n'), "csv")
	-- A quoted line break does not make a record of its own.
	t.eq(input.detect('a,b\n1,"x\ny"\n3,4\n'), "csv")
	t.eq(input.detect('a,b,c\n1,"x\ny",3\n4,5,6\n'), "csv")
	t.eq(input.detect('"a,b",c\nd,e\n'), "csv")
	t.eq(input.detect('a,b\n1,"x\ny"\n3,4,5\n'), "lines")
	t.eq(input.detect('a,b,c\n1,2,3'), "csv")
	t.eq(input.detect('a,b,c\n1,2,3', false), "lines")
end)

t.test("detect: the sample is plain, without blank lines and carriage returns", function()
	t.eq(input.detect("\n\n  \r\nname,age\r\nann,3\r\n"), "csv")
	t.eq(input.detect("\27[1mname\27[0m,age\nann,3\n"), "csv")
	t.eq(input.detect("\27[1mNAME\27[0m  SIZE\nfoo  12\n"), "columns")
	t.eq(input.detect("\27[0m\n\n"), "lines")
	t.eq(input.detect("\n"), "lines")
	t.eq(input.detect("name,age\nann,3", false), "lines")
end)

t.test("detect: a table of spaces needs a heading and two columns", function()
	t.eq(input.detect("NAME    AGE\nann     3\n"), "columns")
	t.eq(input.detect("name    age\nann     3\n"), "lines")
	t.eq(input.detect("NAME\nann\n"), "lines")
	t.eq(input.detect("NAME AGE\n"), "lines")
	t.eq(input.detect("NAME AGE\n", false), "lines")
	-- A heading is told by its words alone: a capital, and nothing that is a value.
	t.eq(input.detect("a1 NAME\nb2 foo\n"), "lines")
end)

-- Reader --------------------------------------------------------------------------------------

t.test("the shape is nil until it is decided: by the sample, the clock or the end", function()
	local sink = {
		columns = function() end,
		record = function() end,
		problem = function() end,
	}
	local reader = input.Reader.new(sink)
	t.eq(reader.format, nil)
	t.ok(not reader:has_line())
	reader:feed("name,age")
	t.ok(not reader:has_line())
	reader:feed("\nann,3\n")
	t.ok(reader:has_line())
	t.eq(reader.format, nil)
	-- Slow to come: decided on what it has sent.
	reader:decide()
	t.eq(reader.format, "csv")
	t.ok(reader:has_line())
	reader:decide()
	reader:feed("bob,4\n")
	reader:finish()
	t.eq(reader.format, "csv")

	local ended = input.Reader.new(sink)
	ended:feed("just one line")
	ended:finish()
	t.eq(ended.format, "lines")
end)

t.test("fifty lines settle the shape, and so do 64 KiB without one", function()
	local sink = { columns = function() end, record = function() end, problem = function() end }
	local lines = {}
	for i = 1, 49 do
		lines[i] = "a,b"
	end
	local reader = input.Reader.new(sink)
	reader:feed(join(lines))
	t.eq(reader.format, nil)
	reader:feed("a,b\n")
	t.eq(reader.format, "csv")

	local wide = input.Reader.new(sink)
	wide:feed(string.rep("x", 65535))
	t.eq(wide.format, nil)
	wide:feed("x")
	t.eq(wide.format, "lines")
end)

t.test("the shape given overrides the first lines", function()
	t.eq(read("a,b\n1,2\n", "lines").raws, { "a,b", "1,2" })
	t.eq(read("a,b\n1,2\n", "lines").format, "lines")
	t.eq(read("NAME  X\nfoo   1\n", "csv").names, { "NAME  X" })
	t.eq(read("one line\n", "columns").names, { "one", "line" })
	t.eq(read('{"a":1}\n', "lines").raws, { '{"a":1}' })
	t.eq(read("a\tb\n1\t2\n", "csv").names, { "a\tb" })
	t.raises(function()
		input.Reader.new({}, "xml"):feed("x")
	end, "xml")
end)

t.test("every shape reads nothing, and the heading of nothing", function()
	for _, format in ipairs(input.FORMATS) do
		local got = read("", format)
		t.eq(#got.records, 0, format)
		local problems = format == "json" and { "The input is not one JSON document" } or {}
		t.eq(got.problems, problems, format)
	end
	t.eq(input.FORMATS, { "lines", "csv", "tsv", "columns", "jsonl", "json" })
	local got = read("")
	t.eq(got.format, "lines")
	t.eq(got.names, { "line" })
end)

-- The same records, however the text comes -----------------------------------------------------

local function sample_of(format)
	local rows = {}
	if format == "lines" then
		for i = 1, 120 do
			rows[i] = "line " .. i .. " of text, and (some) more: é"
		end
		rows[40] = "a: b"
	elseif format == "csv" then
		rows[1] = "id,name,note"
		for i = 2, 120 do
			rows[i] = i .. ",name " .. i .. ',"note, ' .. i .. '"'
		end
		rows[60] = '60,quoted,"two\nlines ""here"""'
	elseif format == "tsv" then
		rows[1] = "id\tname\tnote"
		for i = 2, 120 do
			rows[i] = i .. "\tname " .. i .. "\tnote " .. i
		end
	elseif format == "columns" then
		rows[1] = "NAME            COUNT   STATUS         AGE"
		for i = 2, 120 do
			rows[i] = string.format("%-16s%-8d%-15s%s", "item-" .. i, i * 7, "Running ok", i .. "d")
		end
	elseif format == "jsonl" then
		for i = 1, 120 do
			rows[i] = string.format('{"id":%d,"name":"n%d","tags":["a","b"],"é":null}', i, i)
		end
		rows[30] = "not json"
		rows[50] = '{"late":true}'
	else
		for i = 1, 120 do
			local ok = tostring(i % 2 == 0)
			rows[i] = string.format('  {"id": %d, "name": "n%d", "ok": %s}', i, i, ok)
		end
		return "[\n" .. table.concat(rows, ",\n") .. "\n]\n"
	end
	return join(rows)
end

t.test("the records are the same whatever the pieces the text comes in", function()
	for _, format in ipairs(input.FORMATS) do
		local text = sample_of(format)
		local whole = read(text, nil, 0)
		t.eq(whole.format, format)
		t.ok(#whole.records >= 100, format .. " has records")
		for _, piece in ipairs({ 1, 2, 3, 7, 50, 64, 1000, 65536 }) do
			local got = read(text, nil, piece)
			t.eq(got.format, format, format .. " piece " .. piece)
			t.eq(got.names, whole.names, format .. " piece " .. piece)
			t.eq(got.heading, whole.heading, format .. " piece " .. piece)
			t.eq(got.cells, whole.cells, format .. " piece " .. piece)
			t.eq(got.raws, whole.raws, format .. " piece " .. piece)
			t.eq(got.problems, whole.problems, format .. " piece " .. piece)
		end
		-- And with the shape given, which decides at the first piece.
		for _, piece in ipairs({ 1, 7, 64 }) do
			local got = read(text, format, piece)
			t.eq(got.cells, whole.cells, format .. " given, piece " .. piece)
			t.eq(got.raws, whole.raws, format .. " given, piece " .. piece)
		end
	end
end)

t.test("pieces that cut a character in two give the same records", function()
	local text = join({ "NAME      CITY", "Çağrı     İzmir", "Zoë       Zürich" })
	for _, piece in ipairs({ 1, 2, 3, 0 }) do
		t.eq(read(text, nil, piece).cells, { { "Çağrı", "İzmir" }, { "Zoë", "Zürich" } })
		t.eq(read(text, "columns", piece).cells[2], { "Zoë", "Zürich" })
	end
	local csv = "naïve,日本\nçà,語\n"
	for _, piece in ipairs({ 1, 2, 3, 0 }) do
		t.eq(read(csv, nil, piece).cells, { { "çà", "語" } })
	end
end)

-- Speed ----------------------------------------------------------------------------------------

-- Feeds the text in pieces of 64 KiB to a reader of the shape and counts the records; says how
-- long it took. The bound is loose: it is here to catch a reading that has gone quadratic, the
-- number printed is the measure.
local function timed(label, text, format, expect_format, rows)
	local count, last = 0, nil
	local reader = input.Reader.new({
		columns = function() end,
		record = function(record)
			count += 1
			last = record
		end,
		problem = function() end,
	}, format)
	local started = pencere.time.monotonic()
	local at, size = 1, #text
	while at <= size do
		reader:feed(string.sub(text, at, at + 65535))
		at += 65536
	end
	reader:finish()
	local took = pencere.time.monotonic() - started
	local line = string.format("speed: %s: %d records, %d KiB", label, count, size // 1024)
	print(string.format("%s, %.0f ms", line, took * 1000))
	t.eq(reader.format, expect_format)
	t.eq(count, rows)
	t.ok(took < 8, label .. " took " .. took .. " s")
	return last
end

local PS_FORMAT = "%-12s %7s %5s %4s %10s %6s  %-4s %-4s %-8s %9s %s"
local PS_COMMANDS = {
	"/usr/sbin/syslogd",
	"/System/Library/WindowServer -daemon",
	"/Applications/Safari.app/Contents/MacOS/Safari --type=renderer --lang=en-US",
}

-- `ps aux` as macOS prints it: eleven columns, a command with spaces in it, and (when `wide` is
-- set) a VSZ now and then wider than its column, which pushes the rest of the line right.
local function ps_text(rows, wide)
	local out = {
		string.format(
			PS_FORMAT,
			"USER", "PID", "%CPU", "%MEM", "VSZ", "RSS", "TT", "STAT", "STARTED", "TIME", "COMMAND"
		),
	}
	for i = 1, rows do
		local vsz = tostring(400000000 + (i * 7919) % 90000000)
		if wide and i % 4 == 3 then
			vsz = "104487033824"
		elseif wide and i % 7 == 2 then
			vsz = "10448703382400"
		end
		out[i + 1] = string.format(
			PS_FORMAT,
			"user" .. i % 40,
			tostring(i % 100000),
			string.format("%.1f", i % 1000 / 10),
			string.format("%.1f", i % 100 / 10),
			vsz,
			tostring(i % 700000),
			"??",
			"Ss",
			"Mon09AM",
			"0:00.12",
			PS_COMMANDS[i % 3 + 1]
		)
	end
	return table.concat(out, "\n") .. "\n"
end

t.test("speed: 200 000 lines of ps, cut at their spaces", function()
	local text = ps_text(200000, true)
	local last = timed("ps, wide VSZ (split at spaces)", text, nil, "columns", 200000)
	t.eq(#last.cells, 11)
	t.eq(last.cells[1], "user0")
	t.eq(last.cells[11], PS_COMMANDS[200000 % 3 + 1])
end)

t.test("speed: 200 000 lines of ps, cut at their places", function()
	local text = ps_text(200000, false)
	local last = timed("ps, aligned (cut at places)", text, nil, "columns", 200000)
	t.eq(#last.cells, 11)
	t.eq(last.cells[2], tostring(200000 % 100000))
	t.eq(last.cells[11], PS_COMMANDS[200000 % 3 + 1])
end)

t.test("speed: 100 000 lines of JSON", function()
	local lines = {}
	for i = 1, 100000 do
		lines[i] = string.format(
			'{"time":"2026-10-22T09:00:%02d.529Z","level":"info","method":"GET",'
				.. '"path":"/api/orders/%d","status":200,"ms":%d,"size":"6.1KiB",'
				.. '"user":"u%d","ok":true,"ratio":%.3f}',
			i % 60,
			i,
			i % 400,
			i % 200,
			i / 7
		)
	end
	local last = timed("json lines", table.concat(lines, "\n") .. "\n", nil, "jsonl", 100000)
	t.eq(#last.cells, 10)
	t.eq(last.cells[8], "u0")
end)

t.test("speed: 100 000 lines of CSV", function()
	local lines = { "id,name,region,cpu,memory,disk,uptime,note" }
	for i = 1, 100000 do
		lines[i + 1] = string.format(
			'%d,db-%d,eu-central-1,%d%%,%.1fGiB,%dGiB,%dd,%s',
			i,
			i % 500,
			i % 100,
			i % 64 + 0.5,
			i % 900,
			i % 365,
			i % 10 == 0 and '"checked, ""ok"""' or "fine"
		)
	end
	local last = timed("csv", table.concat(lines, "\n") .. "\n", nil, "csv", 100000)
	t.eq(#last.cells, 8)
	t.eq(last.cells[1], "100000")
end)

t.test("speed: 200 000 plain lines", function()
	local lines = {}
	for i = 1, 200000 do
		lines[i] = "a1b2c3d Fix the order total when a coupon is applied twice " .. i
	end
	timed("lines", table.concat(lines, "\n") .. "\n", nil, "lines", 200000)
end)
