-- The query and the quantities it compares: what a person types chooses the rows they mean, with
-- `--where` and in the view alike, since both run this code. The first tests are the old
-- program's, one for one; the rest go branch by branch, and the last time 200 000 rows.

local pencere = require("pencere")
local t = require("t")
local query = require("query")
local stats = require("query.stats")

local COLUMNS = { "NAME", "STATUS", "%CPU", "SIZE", "AGE", "CONTAINER ID", "STARTED" }

local function row(...)
	return { cells = { ... } }
end

local ROWS = {
	row("web-1", "Running", "12.5", "1.2G", "3d4h", "a1b2", "2026-10-20"),
	row("web-2", "CrashLoopBackOff", "0.0", "512Mi", "47m", "c3d4", "2026-10-22T08:00:00Z"),
	row("db-1", "Running", "88", "40GiB", "45s", "e5f6", "2026-09-01"),
	row("cache", "Pending", "", "10MB", "2m", "Up 2 hours", ""),
}

-- The first cells of the rows the query keeps.
local function keep(source, rows, columns)
	local compiled = query.compile(query.parse(source, columns or COLUMNS))
	local kept = {}
	for _, r in ipairs(rows) do
		if compiled(r) then
			kept[#kept + 1] = r.cells[1]
		end
	end
	return kept
end

local function rows_of(cells)
	local rows = {}
	for i, cell in ipairs(cells) do
		rows[i] = row(cell)
	end
	return rows
end

local function range(count)
	local list = {}
	for i = 1, count do
		list[i] = i
	end
	return list
end

-- The cells of one column in the order `order` puts them in.
local function ordered(cells, descending)
	local rows = rows_of(cells)
	local result = {}
	for i, at in ipairs(query.order(rows, range(#rows), 1, descending)) do
		result[i] = rows[at].cells[1]
	end
	return result
end

-- A repeatable run of numbers: Park and Miller's generator, small enough to be exact in doubles.
local function random(seed)
	return function(n)
		seed = (seed * 48271) % 2147483647
		return seed % n + 1
	end
end

-- ---- the old program's tests ---------------------------------------------------------------

t.test("a quantity is read from what a cell says", function()
	t.eq(query.quantity("12"), { kind = "number", value = 12 })
	t.eq(query.quantity("12.5%"), { kind = "number", value = 12.5 })
	t.eq(query.quantity("1.5G"), { kind = "size", value = 1.5 * 1024 ^ 3 })
	t.eq(query.quantity("512Ki"), { kind = "size", value = 512 * 1024 })
	t.eq(query.quantity("3.4 MB"), { kind = "size", value = 3.4e6 })
	t.eq(query.quantity("10k"), { kind = "size", value = 10240 })
	t.eq(query.quantity("3m"), { kind = "duration", value = 180 })
	t.eq(query.quantity("5d2h"), { kind = "duration", value = 5 * 86400 + 7200 })
	t.eq(query.quantity("500ms"), { kind = "duration", value = 0.5 })
	t.eq(query.quantity("1:02:03"), { kind = "duration", value = 3723 })
	t.eq(query.quantity("2026-10-22").kind, "date")
	t.eq(query.quantity("2026-10-22T10:00:00Z").value, 1792663200000)
	for _, words in ipairs({ "Running", "1.2.3", "v2", "", "a1b2", "-", "12 apples" }) do
		t.eq(query.quantity(words), nil, words)
	end
end)

t.test("a column's kind is what most of its cells are", function()
	t.eq(query.column_kind({ "1", "2", "3", "4", "x" }), "number")
	t.eq(query.column_kind({ "1", "2", "x", "y" }), "text")
	t.eq(query.column_kind({ "1G", "0", "300M", "2G", "5G" }), "size")
	t.eq(query.column_kind({ "Running", "Pending", "3" }), "text")
	t.eq(query.column_kind({}), "text")
end)

t.test("a quantity is written back as a query reads it", function()
	t.eq(query.write_quantity("size", 1.5 * 1024 ^ 3), "1.5Gi")
	t.eq(query.write_quantity("duration", 5400), "1.5h")
	t.eq(query.write_quantity("number", 1234.567), "1230")
	for _, case in ipairs({ { "size", 3 * 1024 ^ 2 }, { "duration", 90 }, { "number", 0.25 } }) do
		t.eq(query.quantity(query.write_quantity(case[1], case[2])).value, case[2])
	end
end)

t.test("words are looked for in every column, in any case; !word leaves rows out", function()
	t.eq(keep("web", ROWS), { "web-1", "web-2" })
	t.eq(keep("RUNNING", ROWS), { "web-1", "db-1" })
	t.eq(keep("!running", ROWS), { "web-2", "cache" })
	t.eq(keep("web running", ROWS), { "web-1" })
	t.eq(keep('"up 2"', ROWS), { "cache" })
	t.eq(keep("", ROWS), { "web-1", "web-2", "db-1", "cache" })
end)

t.test("a column is compared by its heading, or by its letters alone", function()
	t.eq(keep("status=running", ROWS), { "web-1", "db-1" })
	t.eq(keep("STATUS=Running|Pending", ROWS), { "web-1", "db-1", "cache" })
	t.eq(keep("STATUS!=Running", ROWS), { "web-2", "cache" })
	t.eq(keep("name~WEB", ROWS), { "web-1", "web-2" })
	t.eq(keep("name!~web", ROWS), { "db-1", "cache" })
	t.eq(keep("cpu>50", ROWS), { "db-1" })
	t.eq(keep('"container id"~up', ROWS), { "cache" })
	t.eq(keep("containerid=e5f6", ROWS), { "db-1" })
end)

t.test("quantities compare as quantities, and an empty cell is never above or below", function()
	t.eq(keep("%cpu<=12.5", ROWS), { "web-1", "web-2" })
	t.eq(keep("size>1G", ROWS), { "web-1", "db-1" })
	t.eq(keep("size=1.2G", ROWS), { "web-1" })
	t.eq(keep("age<1h", ROWS), { "web-2", "db-1", "cache" })
	t.eq(keep("age=1m..1h", ROWS), { "web-2", "cache" })
	t.eq(keep("started>2026-10-01", ROWS), { "web-1", "web-2" })
	-- A bare number is read in the column's unit: a thousand bytes.
	t.eq(keep("size<20000000", ROWS), { "cache" })
	-- A value that is no quantity compares as text.
	t.eq(keep("name>e", ROWS), { "web-1", "web-2" })
end)

t.test("a name that is no column's makes the term a word, and is told", function()
	local lines = { "line" }
	local r = row("GET /a user=bob 200")
	t.ok(query.matches(query.parse("user=bob", lines), r))
	t.ok(not query.matches(query.parse("user=alice", lines), r))
	t.eq(query.unknown_names("user=bob line~GET size>1", lines), { "user", "size" })
	t.eq(query.unknown_names("STATUS=x !foo", COLUMNS), {})
end)

t.test("cells sort as quantities before words, empty cells last either way", function()
	local cells = { "10", "9", "", "b", "1.5G", "A", "2" }
	t.eq(ordered(cells, false), { "2", "9", "10", "1.5G", "A", "b", "" })
	t.eq(ordered(cells, true), { "b", "A", "1.5G", "10", "9", "2", "" })
	local function before(a, b)
		return query.compare_ordered(query.sort_key(a), query.sort_key(b), false) < 0
	end
	t.ok(before("file9", "file10"))
	t.ok(before("512Mi", "1G"))
end)

t.test("a click writes its term into the query, in place of the column's own", function()
	t.eq(query.with_term("web STATUS=Running", COLUMNS, 2, "STATUS=Pending"), "web STATUS=Pending")
	t.eq(query.with_term("web", COLUMNS, 2, "STATUS=Pending"), "web STATUS=Pending")
	t.eq(query.with_term("STATUS=a web status!=b", COLUMNS, 2, nil), "web")
	t.eq(query.with_term("", COLUMNS, 3, "%CPU=1..5"), "%CPU=1..5")
end)

-- ---- quantities, form by form --------------------------------------------------------------

t.test("numbers are read in their plain forms, with signs, dots and exponents", function()
	local numbers = {
		{ "0", 0 }, { "007", 7 }, { "+5", 5 }, { "-3.5", -3.5 }, { ".5", 0.5 }, { "-.5", -0.5 },
		{ "5.", 5 }, { "1e6", 1e6 }, { "1E-3", 0.001 }, { "2.5e+2", 250 }, { "  12  ", 12 },
		{ "\t12\n", 12 }, { "12 %", 12 }, { "12%", 12 }, { "-4.5%", -4.5 }, { ".5%", 0.5 },
		{ "\u{a0}7\u{a0}", 7 }, { "7\u{3000}", 7 },
	}
	for _, case in ipairs(numbers) do
		t.eq(query.quantity(case[1]), { kind = "number", value = case[2] }, case[1])
	end
	for _, word in ipairs({
		"e5", "--5", "5e", "5e+", "0x10", "1,000", "+", ".", "1.2.3", "5%%", "% 5", "5 %%", "NaN",
		"inf", "1_000", "５", "5 5",
	}) do
		t.eq(query.quantity(word), nil, word)
	end
end)

t.test("a number of forty characters is read and one of forty-one is words", function()
	t.eq(query.quantity(string.rep("1", 40)).kind, "number")
	t.eq(query.quantity(string.rep("1", 41)), nil)
	t.eq(query.quantity("  " .. string.rep("1", 40) .. "  ").kind, "number")
end)

t.test("a size counts in 1024s with one letter and `i`, in 1000s with a `B`", function()
	local sizes = {
		{ "5B", 5 }, { "5b", 5 }, { "1k", 1024 }, { "1K", 1024 }, { "1KB", 1000 }, { "1kb", 1000 },
		{ "1kB", 1000 }, { "1Ki", 1024 }, { "1KiB", 1024 }, { "1Kib", 1024 },
		{ "2M", 2 * 1024 ^ 2 },
		{ "2Mi", 2 * 1024 ^ 2 }, { "2MB", 2e6 }, { "2mb", 2e6 }, { "1G", 1024 ^ 3 },
		{ "1GB", 1e9 }, { "1T", 1024 ^ 4 }, { "1TB", 1e12 }, { "1P", 1024 ^ 5 },
		{ "1PiB", 1024 ^ 5 },
		{ "1.5 Gi", 1.5 * 1024 ^ 3 }, { "1.5\u{a0}GB", 1.5e9 }, { "-1K", -1024 }, { "+2k", 2048 },
		{ ".5G", 0.5 * 1024 ^ 3 }, { "5.k", 5 * 1024 }, { "0B", 0 },
	}
	for _, case in ipairs(sizes) do
		t.eq(query.quantity(case[1]), { kind = "size", value = case[2] }, case[1])
	end
	for _, word in ipairs({ "1GIB", "1Gb2", "1Gx", "1 m", "5 m", "1Kii", "1 KB B", "G", "K5" }) do
		t.eq(query.quantity(word), nil, word)
	end
end)

t.test("a length of time is parts of a number and a unit, or a clock", function()
	local lengths = {
		{ "1ms", 0.001 }, { "1s", 1 }, { "2m", 120 }, { "3h", 10800 }, { "1d", 86400 },
		{ "1w", 604800 }, { "1y", 31536000 }, { "5d2h", 5 * 86400 + 7200 }, { "1.5h", 5400 },
		{ "2h30m", 9000 }, { "1m30s", 90 }, { "1s500ms", 1.5 }, { "250ms", 0.25 },
		{ "1:02:03", 3723 }, { "12:34", 754 }, { "0:01.23", 1.23 }, { "0:00:00.5", 0.5 },
		{ "100:00:00", 360000 }, { "1:02:03.25", 3723.25 }, { " 45s ", 45 },
	}
	for _, case in ipairs(lengths) do
		t.eq(query.quantity(case[1]), { kind = "duration", value = case[2] }, case[1])
	end
	for _, word in ipairs({
		"1h30", "h", "1.h", "1..5s", "1x", "1:2", "1:023", "1:02:3", "1:02:03:04", "1:02.", ":30",
		"-5s", "+5s", "5 s", "1.5.3m", "1ms5",
	}) do
		t.eq(query.quantity(word), nil, word)
	end
end)

t.test("a moment is a date, with a time and a zone or without", function()
	local moments = {
		{ "2026-10-22", 1792627200000 },
		{ "2026-10-22T10:00:00Z", 1792663200000 },
		{ "2026-10-22T10:00Z", 1792663200000 },
		{ "2026-10-22T10:00", 1792663200000 },
		{ "2026-10-22 10:00", 1792663200000 },
		{ "2026-10-22 10:30:15", 1792665015000 },
		{ "2026-10-22T10:00:00+02:00", 1792656000000 },
		{ "2026-10-22T10:00:00+0200", 1792656000000 },
		{ "2026-10-22T10:00-08:00", 1792692000000 },
		{ "2026-10-22T10:00:00.123456Z", 1792663200123 },
		{ "2026-10-22T10:00:00.5Z", 1792663200500 },
		{ "2026-10-22T24:00", 1792713600000 },
		{ "2024-02-29", 1709164800000 },
		{ "1969-12-31T23:59:59Z", -1000 },
		{ "1970-01-01", 0 },
		{ "0000-01-01", -62167219200000 },
		{ "9999-12-31", 253402214400000 },
		{ " 2026-10-22 ", 1792627200000 },
	}
	for _, case in ipairs(moments) do
		t.eq(query.quantity(case[1]), { kind = "date", value = case[2] }, case[1])
	end
	for _, word in ipairs({
		"2026-13-01", "2026-00-10", "2026-10-00", "2026-02-29", "2026-04-31", "2026-10-22T25:00",
		"2026-10-22T10:60", "2026-10-22T24:01", "2026-10-22T10:00:60", "2026-10-22T10",
		"2026-10-22Z", "2026-10-22T10:00:00+25:00", "2026-10-22T10:00:00+02:60",
		"2026-10-22T10:00:00.Z", "2026-10-22T10:00:0", "2026-10-2", "26-10-22", "2026/10/22",
		"2026-10-22x", "2026-10-22T10:00:00 +0200",
	}) do
		t.eq(query.quantity(word), nil, word)
	end
end)

t.test("a moment with no zone is read as UTC, the same as the same moment with Z", function()
	t.eq(query.quantity("2026-10-22T10:00:00").value, query.quantity("2026-10-22T10:00:00Z").value)
	t.eq(query.quantity("2026-10-22 10:00").value, query.quantity("2026-10-22T10:00Z").value)
end)

t.test("kinds compare with their own, and a number with a size or a length of time", function()
	local function q(cell)
		return query.quantity(cell)
	end
	t.ok(query.comparable(q("1"), q("2")))
	t.ok(query.comparable(q("1G"), q("2M")))
	t.ok(query.comparable(q("1G"), q("5")))
	t.ok(query.comparable(q("5"), q("1h")))
	t.ok(query.comparable(q("2026-10-22"), q("2026-01-01")))
	t.ok(not query.comparable(q("1G"), q("1h")))
	t.ok(not query.comparable(q("2026-10-22"), q("5")))
	t.ok(not query.comparable(q("1h"), q("2026-10-22")))
end)

t.test("a column's kind is the kind of most of its first filled cells", function()
	t.eq(query.column_kind({ "1h", "2h", "3h", "4h", "x" }), "duration")
	t.eq(query.column_kind({ "1h", "2h", "3h", "x" }), "text")
	t.eq(query.column_kind({ "2026-10-22", "2026-10-23", "", "2026-10-24", "2026-10-25", "-" }),
		"date")
	t.eq(query.column_kind({ "", "  ", "" }), "text")
	-- Numbers count for a column of sizes, but a column of numbers is not made a size by one.
	t.eq(query.column_kind({ "1", "2", "3", "4", "5G" }), "number")
	t.eq(query.column_kind({ "1G", "2G", "3G", "4", "5" }), "size")
	-- Four tenths of each: the first kind to have the most is the kind.
	t.eq(query.column_kind({ "1G", "2G", "1h", "2h", "x" }), "text")
	t.eq(query.column_kind({ "1G", "1h", "2h", "3h", "4h", "5h", "5" }), "duration")
	t.eq(query.column_kind({ "1G", "2G", "1h", "2h", "3h", "4h", "5" }), "text")
	-- Only the first filled cells are read.
	t.eq(query.column_kind({ "1", "2", "x", "y", "z" }, 2), "number")
	t.eq(query.column_kind({ "", "1", "", "2", "x", "y" }, 2), "number")
end)

t.test("a quantity is written as three digits and a unit, and read back", function()
	t.eq(query.write_quantity("number", 0), "0")
	t.eq(query.write_quantity("number", -1234.567), "-1230")
	t.eq(query.write_quantity("number", 1.125), "1.13")
	t.eq(query.write_quantity("number", 0.0001234), "0.000123")
	t.eq(query.write_quantity("number", 1.23e-7), "1.23e-7")
	t.eq(query.write_quantity("number", 1.234e25), "1.23e+25")
	t.eq(query.write_quantity("number", 999.7), "1000")
	t.eq(query.write_quantity("number", 12), "12")
	t.eq(query.write_quantity("size", 512), "512B")
	t.eq(query.write_quantity("size", 1024), "1Ki")
	t.eq(query.write_quantity("size", 1536), "1.5Ki")
	t.eq(query.write_quantity("size", 40 * 1024 ^ 3), "40Gi")
	t.eq(query.write_quantity("size", 3 * 1024 ^ 6), "3070Pi")
	t.eq(query.write_quantity("duration", 0.25), "250ms")
	t.eq(query.write_quantity("duration", 0), "0ms")
	t.eq(query.write_quantity("duration", 45), "45s")
	t.eq(query.write_quantity("duration", 90), "1.5m")
	t.eq(query.write_quantity("duration", 7200), "2h")
	t.eq(query.write_quantity("duration", 3 * 86400), "3d")
	t.eq(query.write_quantity("date", 1792627200000), "2026-10-22")
	t.eq(query.write_quantity("date", 1792663200000), "2026-10-22T10:00:00Z")
	t.eq(query.write_quantity("date", 1792663200999.7), "2026-10-22T10:00:00Z")
	t.eq(query.write_quantity("date", -1000), "1969-12-31T23:59:59Z")
	t.eq(query.write_quantity("date", -62167219200000), "0000-01-01")
	for _, case in ipairs({
		{ "date", 1792663200000 }, { "date", 1792627200000 }, { "size", 5 * 1024 ^ 2 },
		{ "duration", 7200 }, { "duration", 0.5 }, { "number", 17 },
	}) do
		t.eq(query.quantity(query.write_quantity(case[1], case[2])).value, case[2], case[1])
	end
end)

-- ---- text ----------------------------------------------------------------------------------

t.test("text is lowered in the common scripts, and any other byte is left as it is", function()
	local fold = query.fold
	t.eq(fold.lower("Hello WORLD 123"), "hello world 123")
	t.eq(fold.lower("ÀÉÎÕÜ Ä Ö Ü Ñ Ç"), "àéîõü ä ö ü ñ ç")
	t.eq(fold.lower("Ā Ă Ą Ĺ Ł Ń Ŋ Ž Ÿ"), "ā ă ą ĺ ł ń ŋ ž ÿ")
	t.eq(fold.lower("İSTANBUL"), "istanbul")
	t.eq(fold.lower("ΑΒΓ Δ ΩΣ Ά Έ Ί Ό Ύ Ώ"), "αβγ δ ωσ ά έ ί ό ύ ώ")
	t.eq(fold.lower("ΟΔΟΣ"), fold.lower("οδος"))
	t.eq(fold.lower("ПРИВЕТ Мир Ёж Ђ"), "привет мир ёж ђ")
	t.eq(fold.lower("Ổ Ế ẞ"), "ổ ế ß")
	t.eq(fold.lower("中文 日本語 한국어 😀"), "中文 日本語 한국어 😀")
	t.eq(fold.lower("a\255B\192C\128"), "a\255b\192c\128")
	t.eq(fold.lower("\195"), "\195")
	t.eq(fold.lower("x\195\169\169Y"), "xé\169y")
	t.eq(fold.lower(""), "")
end)

t.test("a word is found in any case of any of the common scripts", function()
	local rows = {
		row("Müller", "ok"), row("МОСКВА", "ok"),
		row("Ελλάδα", "ok"), row("plain", "ok"),
	}
	t.eq(keep("müller", rows, { "A", "B" }), { "Müller" })
	t.eq(keep("MÜLLER", rows, { "A", "B" }), { "Müller" })
	t.eq(keep("москва", rows, { "A", "B" }), { "МОСКВА" })
	t.eq(keep("ΕΛΛΆΔΑ", rows, { "A", "B" }), { "Ελλάδα" })
	t.eq(keep("a~MÜ", rows, { "A", "B" }), { "Müller" })
	t.eq(keep("a=müller", rows, { "A", "B" }), { "Müller" })
end)

t.test("white space is that of every script, a heading's name its letters and digits", function()
	local fold = query.fold
	t.eq(fold.trim("  a b \t\n"), "a b")
	t.eq(fold.trim("\u{a0}\u{2003}a\u{3000}\u{feff}"), "a")
	t.eq(fold.trim("\u{e2}\u{80}x"), "\u{e2}\u{80}x")
	t.eq(fold.trim(" "), "")
	t.eq(fold.trim(""), "")
	t.ok(fold.is_blank("\u{a0} \t"))
	t.ok(not fold.is_blank("\u{a0}x"))
	t.ok(fold.has_space("a\u{2009}b"))
	t.ok(not fold.has_space("ab\u{2e}"))
	t.eq(query.simple_name("%CPU"), "cpu")
	t.eq(query.simple_name("CONTAINER ID"), "containerid")
	t.eq(query.simple_name("Größe (MB)"), "größemb")
	t.eq(query.simple_name("Имя-1"), "имя1")
	t.eq(query.simple_name("名前 / 数"), "名前数")
	t.eq(query.simple_name("a\u{a0}b\u{2014}c\u{20ac}d😀e"), "abcde")
	t.eq(query.simple_name("--%--"), "")
	t.eq(query.simple_name("a\255b\128c"), "abc")
	t.eq(query.column_named(COLUMNS, "container id"), 6)
	t.eq(query.column_named(COLUMNS, "CONTAINERID"), 6)
	t.eq(query.column_named(COLUMNS, "cpu"), 3)
	t.eq(query.column_named(COLUMNS, "%"), nil)
	t.eq(query.column_named(COLUMNS, ""), nil)
	t.eq(query.column_named(COLUMNS, "nope"), nil)
	t.eq(query.column_named({ "a b", "ab" }, "ab"), 2)
	t.eq(query.column_named({ "a-b", "ab" }, "ab"), 2)
	t.eq(query.column_named({ "a-b" }, "ab"), 1)
end)

t.test("a text that is no valid UTF-8 raises nowhere", function()
	local broken = "a\255\254\192\128\237\160\128 \226\130 \240\159 \195"
	local rows = { row(broken, "x"), row("ok", "y") }
	local columns = { "A", broken }
	local queries =
		{ broken, "!" .. broken, "a~" .. broken, "a=" .. broken, '"' .. broken, broken .. "=1" }
	for _, source in ipairs(queries) do
		local parsed = query.parse(source, columns)
		local compiled = query.compile(parsed)
		compiled(rows[1])
		compiled(rows[2])
		query.unknown_names(source, columns)
		query.with_term(source, columns, 1, "A=1")
	end
	query.order(rows, { 1, 2 }, 1, false)
	query.order(rows, { 1, 2 }, 1, true)
	query.quantity(broken)
	query.simple_name(broken)
	query.fold.lower(broken)
	query.fold.trim(broken)
	t.eq(query.matches(query.parse("a~\255", columns), rows[1]), true)
end)

-- ---- the query -----------------------------------------------------------------------------

t.test("a term is where it was written, and its words are lowered", function()
	local parsed = query.parse('web  "Up 2" !Db', COLUMNS)
	t.eq(parsed.empty, false)
	t.eq(parsed.terms, {
		{ kind = "text", text = "web", negate = false, from = 1, to = 3 },
		{ kind = "text", text = "up 2", negate = false, from = 6, to = 11 },
		{ kind = "text", text = "db", negate = true, from = 13, to = 15 },
	})
	local source = "  size>=1G   status=Running|Pending  "
	local terms = query.parse(source, COLUMNS).terms
	t.eq(source:sub(terms[1].from, terms[1].to), "size>=1G")
	t.eq(source:sub(terms[2].from, terms[2].to), "status=Running|Pending")
	t.eq(terms[1], {
		kind = "field", column = 4, op = ">=", values = { "1G" }, from = 3, to = 10,
	})
	t.eq(terms[2], {
		kind = "field", column = 2, op = "=", values = { "Running", "Pending" }, from = 14, to = 35,
	})
	t.eq(query.parse("", COLUMNS), { terms = {}, empty = true })
	t.eq(query.parse(" \t ", COLUMNS), { terms = {}, empty = true })
	t.eq(query.parse("é ü", COLUMNS).terms[2].from, 4)
end)

t.test("quotes keep spaces, either kind of quote, and the other kind inside", function()
	t.eq(query.parse("'up 2'", COLUMNS).terms[1].text, "up 2")
	t.eq(query.parse([["it's" ok]], COLUMNS).terms[1].text, "it's")
	t.eq(query.parse([['say "hi"']], COLUMNS).terms[1].text, 'say "hi"')
	t.eq(query.parse([[a"b c"d]], COLUMNS).terms[1].text, "ab cd")
	t.eq(#query.parse([["a b" "c d"]], COLUMNS).terms, 2)
	-- A quote never closed holds the rest of the source.
	local open = query.parse('web "up 2 and more', COLUMNS).terms
	t.eq(#open, 2)
	t.eq(open[2].text, "up 2 and more")
	t.eq(open[2].to, 18)
	-- An empty pair of quotes is no word.
	t.eq(query.parse('""', COLUMNS).empty, true)
	t.eq(query.parse("''", COLUMNS).empty, true)
	-- An operator inside quotes is a letter.
	local quoted = query.parse('"status=Running"', COLUMNS).terms
	t.eq(quoted[1].kind, "text")
	t.eq(quoted[1].text, "status=running")
	t.eq(keep('"status=Running"', ROWS), {})
	t.eq(keep('name="web-1"', ROWS), { "web-1" })
	t.eq(keep("status='Running'", ROWS), { "web-1", "db-1" })
	t.eq(keep('status="Crash Loop"', ROWS), {})
	t.eq(keep('"container id"="Up 2 hours"', ROWS), { "cache" })
	t.eq(keep("\"container id\"='up 2 hours'", ROWS), { "cache" })
end)

t.test("the operators are read longest first, and the first one in a token counts", function()
	local function op(source)
		local term = query.parse(source, COLUMNS).terms[1]
		return term.kind == "field" and (term.op .. "|" .. table.concat(term.values, ",")) or "text"
	end
	t.eq(op("size>=1"), ">=|1")
	t.eq(op("size<=1"), "<=|1")
	t.eq(op("size!=1"), "!=|1")
	t.eq(op("size!~1"), "!~|1")
	t.eq(op("size=1"), "=|1")
	t.eq(op("size~1"), "~|1")
	t.eq(op("size>1"), ">|1")
	t.eq(op("size<1"), "<|1")
	t.eq(op("size=>1"), "=|>1")
	t.eq(op("size==1"), "=|=1")
	t.eq(op("size=a=b"), "=|a=b")
	t.eq(op("size>a~b"), ">|a~b")
	t.eq(op("=size"), "text")
	t.eq(op(">5"), "text")
	t.eq(op("!=5"), "text")
	t.eq(op("size=a|b|c"), "=|a,b,c")
	t.eq(op("size=a||b"), "=|a,,b")
	t.eq(op("size="), "=|")
	t.eq(op("size=|"), "=|,")
	t.eq(op("size>a|b"), ">|a|b")
	t.eq(op("size~a|b"), "~|a|b")
	t.eq(op("size!=a|b"), "!=|a,b")
end)

t.test("a word that begins with ! is left out, and a lone ! is a word", function()
	local terms = query.parse("! !a !!a !\"b c\" !", COLUMNS).terms
	t.eq(terms[1], { kind = "text", text = "!", negate = false, from = 1, to = 1 })
	t.eq(terms[2].negate, true)
	t.eq(terms[2].text, "a")
	t.eq(terms[3].negate, true)
	t.eq(terms[3].text, "!a")
	t.eq(terms[4].negate, true)
	t.eq(terms[4].text, "b c")
	t.eq(terms[5].negate, false)
	t.eq(query.parse('!""', COLUMNS).empty, true)
	t.eq(keep("!web !db", ROWS), { "cache" })
	t.eq(keep("!!", ROWS), { "web-1", "web-2", "db-1", "cache" })
	t.eq(keep("running !web", ROWS), { "db-1" })
end)

t.test("a range is two ends that begin and end with something other than a dot", function()
	local function range_of(source)
		local term = query.parse(source, COLUMNS).terms[1]
		return term.range, term.values
	end
	t.eq((range_of("size=1..5")), { "1", "5" })
	t.eq((range_of("size=a..b..c")), { "a..b", "c" })
	t.eq((range_of("size=1.5..2.5")), { "1.5", "2.5" })
	t.eq((range_of("size=2026-10-01..2026-10-31")), { "2026-10-01", "2026-10-31" })
	t.eq((range_of("size=1...5")), nil)
	t.eq((range_of("size=..5")), nil)
	t.eq((range_of("size=1..")), nil)
	t.eq((range_of("size=1")), nil)
	t.eq((range_of("size>1..5")), nil)
	t.eq((range_of("size!=1..5")), nil)
	t.eq((range_of("size~1..5")), nil)
	t.eq((range_of('size="a b..c d"')), { "a b", "c d" })
	t.eq(select(2, range_of("size=1..5|7")), { "1..5", "7" })
end)

t.test("a range keeps what is between its ends, both included", function()
	t.eq(keep("size=500Mi..2G", ROWS), { "web-1", "web-2" })
	t.eq(keep("size=1.2G..1.2G", ROWS), { "web-1" })
	t.eq(keep("size=2G..500Mi", ROWS), {})
	t.eq(keep("cpu=0..12.5", ROWS), { "web-1", "web-2" })
	t.eq(keep("cpu=0.1..12.4", ROWS), {})
	t.eq(keep("age=1m..1h", ROWS), { "web-2", "cache" })
	t.eq(keep("started=2026-10-01..2026-10-21", ROWS), { "web-1" })
	t.eq(keep("started=2026-10-20..2026-10-22T08:00:00Z", ROWS), { "web-1", "web-2" })
	-- An end that is a quantity of another kind leaves no row in; an empty cell never is between.
	t.eq(keep("size=1..2h", ROWS), {})
	t.eq(keep("started=1..5", ROWS), {})
	t.eq(keep("cpu=0..100", ROWS), { "web-1", "web-2", "db-1" })
	-- Ends that are words are between as text.
	t.eq(keep("name=c..e", ROWS), { "db-1", "cache" })
	t.eq(keep("name=a..z", ROWS), { "web-1", "web-2", "db-1", "cache" })
	t.eq(keep("name=cache..web-1", ROWS), { "web-1", "db-1", "cache" })
end)

t.test("a column that is not one makes the term a word, with its operator in it", function()
	local lines = { "line" }
	local r1 = row("GET /a user=bob 200")
	local r2 = row("GET /a user!=bob 200")
	local r3 = row("GET /a user>=5 200")
	t.ok(query.matches(query.parse("user!=bob", lines), r2))
	t.ok(not query.matches(query.parse("user!=bob", lines), r1))
	t.ok(query.matches(query.parse("user>=5", lines), r3))
	t.ok(query.matches(query.parse("USER=BOB", lines), r1))
	t.eq(query.parse("user=bob", lines).terms[1], {
		kind = "text", text = "user=bob", negate = false, from = 1, to = 8,
	})
	t.eq(query.unknown_names('"a b"=1 a b=2 "a b"~3 =x name=1', COLUMNS), { "a b", "b" })
	t.eq(query.unknown_names("name=1 status!=2", COLUMNS), {})
	t.eq(query.unknown_names("", COLUMNS), {})
	t.eq(query.unknown_names("zz>1 zz<2 yy~3", COLUMNS), { "zz", "yy" })
end)

t.test("a value that matches by quantity is equal by its number, in any unit", function()
	local rows = {
		row("a", "", "1024", "1Ki"),
		row("b", "", "1000", "1KB"),
		row("c", "", "1k", "1024B"),
		row("d", "", "2h", "120m"),
		row("e", "", "7200", "x"),
	}
	local columns = { "N", "P", "Q", "R" }
	t.eq(keep("q=1024", rows, columns), { "a", "c" })
	t.eq(keep("q=1Ki", rows, columns), { "a", "c" })
	t.eq(keep("r=1024", rows, columns), { "a", "c" })
	t.eq(keep("r=1KiB", rows, columns), { "a", "c" })
	t.eq(keep("r=1000", rows, columns), { "b" })
	t.eq(keep("q!=1024", rows, columns), { "b", "d", "e" })
	t.eq(keep("r=120m", rows, columns), { "d" })
	t.eq(keep("r=2h", rows, columns), { "d" })
	t.eq(keep("r=7200", rows, columns), { "d" })
	-- A cell that is words is equal to words, trimmed and without regard to case.
	t.eq(keep("r=X", rows, columns), { "e" })
	t.eq(keep("r=x|1Ki", rows, columns), { "a", "c", "e" })
	-- A number is not a size when the cell is a date, nor a date a number.
	t.eq(keep("q=2026-10-22", rows, columns), {})
	t.eq(keep("q!=2026-10-22", rows, columns), { "a", "b", "c", "d", "e" })
end)

t.test("equal and not equal read an empty value as the empty cells", function()
	t.eq(keep("started=", ROWS), { "cache" })
	t.eq(keep("started!=", ROWS), { "web-1", "web-2", "db-1" })
	t.eq(keep("cpu=", ROWS), { "cache" })
	t.eq(keep("status=|pending", ROWS), { "cache" })
	t.eq(keep("name= web-1", ROWS), {})
	t.eq(keep('name=" web-1"', ROWS), {})
	t.eq(keep("name=WEB-1", { row(" web-1 ") }), { " web-1 " })
end)

t.test("holds-text is in any case, and the empty text is in every cell", function()
	t.eq(keep("status~LOOP", ROWS), { "web-2" })
	t.eq(keep("status!~LOOP", ROWS), { "web-1", "db-1", "cache" })
	t.eq(keep("started~2026-10", ROWS), { "web-1", "web-2" })
	t.eq(keep("started!~2026-10", ROWS), { "db-1", "cache" })
	t.eq(keep("name~", ROWS), { "web-1", "web-2", "db-1", "cache" })
	t.eq(keep("name!~", ROWS), {})
	t.eq(keep("cpu~1", ROWS), { "web-1" })
	t.eq(keep("size~i", ROWS), { "web-2", "db-1" })
	t.eq(keep('status~"ing"', ROWS), { "web-1", "db-1", "cache" })
end)

t.test("comparisons of numbers, sizes, lengths of time and moments, each with each", function()
	local rows = {
		row("a", "5", "1G", "30s", "2026-01-01"),
		row("b", "50", "1M", "2m", "2026-06-01"),
		row("c", "500", "1k", "2h", "2026-12-01"),
		row("d", "", "", "", ""),
		row("e", "x", "y", "z", "w"),
	}
	local columns = { "N", "A", "B", "C", "D" }
	t.eq(keep("a>5", rows, columns), { "b", "c" })
	t.eq(keep("a>=5", rows, columns), { "a", "b", "c" })
	t.eq(keep("a<50", rows, columns), { "a" })
	t.eq(keep("a<=50", rows, columns), { "a", "b" })
	t.eq(keep("a>5%", rows, columns), { "b", "c" })
	t.eq(keep("b>1k", rows, columns), { "a", "b" })
	t.eq(keep("b>=1000", rows, columns), { "a", "b", "c" })
	t.eq(keep("b<1M", rows, columns), { "c" })
	t.eq(keep("b<1.5Mi", rows, columns), { "b", "c" })
	t.eq(keep("c>1m", rows, columns), { "b", "c" })
	t.eq(keep("c<=2m", rows, columns), { "a", "b" })
	t.eq(keep("c>100", rows, columns), { "b", "c" })
	t.eq(keep("c<1:00", rows, columns), { "a" })
	t.eq(keep("d>2026-03-01", rows, columns), { "b", "c" })
	t.eq(keep("d<=2026-06-01", rows, columns), { "a", "b" })
	t.eq(keep("d>=2026-06-01T00:00:00Z", rows, columns), { "b", "c" })
	t.eq(keep("d<2026-06-01T00:00:01+00:00", rows, columns), { "a", "b" })
	t.eq(keep("d<2026-06-01T00:00:01+01:00", rows, columns), { "a" })
	-- Kinds that cannot be compared are not above or below each other.
	t.eq(keep("b>1h", rows, columns), {})
	t.eq(keep("b<1h", rows, columns), {})
	t.eq(keep("d>5", rows, columns), {})
	t.eq(keep("d<5", rows, columns), {})
	t.eq(keep("a>2026-01-01", rows, columns), {})
	t.eq(keep("c>1k", rows, columns), {})
	-- Empty cells are never above or below; words go by the value as text when it is one.
	t.eq(keep("a<1000", rows, columns), { "a", "b", "c" })
	t.eq(keep("a>w", rows, columns), { "e" })
	t.eq(keep("a<w", rows, columns), { "a", "b", "c" })
	t.eq(keep("d>=", rows, columns), { "a", "b", "c", "e" })
end)

t.test("words compare as text, their numbers as numbers, capitals beside small letters", function()
	local rows = rows_of({ "file1", "file9", "file10", "File11", "File100", "other", "" })
	t.eq(keep("a>file9", rows, { "A" }), { "file10", "File11", "File100", "other" })
	t.eq(keep("a<=file10", rows, { "A" }), { "file1", "file9", "file10" })
	t.eq(keep("a>=FILE10", rows, { "A" }), { "file10", "File11", "File100", "other" })
	t.eq(keep("a<file09", rows, { "A" }), { "file1" })
	t.eq(keep("a>Z", rows, { "A" }), {})
	t.eq(keep("a<g", rows, { "A" }), { "file1", "file9", "file10", "File11", "File100" })
end)

t.test("a compiled query is the same as asking row by row, the row keeps its lower case", function()
	local parsed = query.parse("web !running cpu<50 size>1k", COLUMNS)
	local compiled = query.compile(parsed)
	for _, r in ipairs(ROWS) do
		t.eq(compiled(r), query.matches(parsed, r))
		t.eq(compiled(r), query.holds(parsed.terms[1], r) and query.holds(parsed.terms[2], r)
			and query.holds(parsed.terms[3], r) and query.holds(parsed.terms[4], r))
	end
	local fresh = row("Alpha", "BETA")
	t.eq(fresh.lower, nil)
	t.eq(query.row_lower(fresh), "alpha\tbeta")
	t.eq(fresh.lower, "alpha\tbeta")
	local given = { cells = { "X" }, lower = "given" }
	t.eq(query.row_lower(given), "given")
	t.eq(query.compile(query.parse("", COLUMNS))(row("anything")), true)
	t.eq(query.compile(query.parse("a b c", { "A" }))(row("a b c")), true)
	t.eq(query.compile(query.parse("a b d", { "A" }))(row("a b c")), false)
	-- A row with fewer cells than the columns has empty cells there.
	t.eq(keep("status=", { row("only") }), { "only" })
	t.eq(keep("status>a", { row("only") }), {})
	t.eq(keep("only", { row("only") }), { "only" })
end)

t.test("a value is quoted when it has a space, a quote or an operator", function()
	t.eq(query.quote_value("plain"), "plain")
	t.eq(query.quote_value("Up 2"), '"Up 2"')
	t.eq(query.quote_value(""), '""')
	t.eq(query.quote_value("a=b"), '"a=b"')
	t.eq(query.quote_value("a|b"), '"a|b"')
	t.eq(query.quote_value("a!b"), '"a!b"')
	t.eq(query.quote_value("a~b"), '"a~b"')
	t.eq(query.quote_value("<5"), '"<5"')
	t.eq(query.quote_value('say "hi"'), "'say \"hi\"'")
	t.eq(query.quote_value("it's"), "\"it's\"")
	t.eq(query.quote_value("a\u{a0}b"), '"a\u{a0}b"')
	t.eq(query.quote_name("CONTAINER ID"), '"CONTAINER ID"')
	t.eq(query.quote_name("%CPU"), "%CPU")
	local values = { "plain", "Up 2", "", "a=b", "x|y", 'say "hi"', "it's", "<5", "a\tb" }
	for _, value in ipairs(values) do
		local term = query.parse("name=" .. query.quote_value(value), COLUMNS).terms[1]
		t.eq(table.concat(term.values, "|"), value, value)
	end
end)

t.test("a term is put in place of the column's, and the spaces round it are mended", function()
	local w = query.with_term
	t.eq(w("status=a web status!=b", COLUMNS, 2, "STATUS=c"), "STATUS=c web")
	t.eq(w("web status=a   cpu>5 status!=b", COLUMNS, 2, "STATUS=c"), "web STATUS=c cpu>5")
	t.eq(w("web  cpu>5", COLUMNS, 2, "STATUS=c"), "web cpu>5 STATUS=c")
	t.eq(w("  web  ", COLUMNS, 2, "STATUS=c"), "web STATUS=c")
	t.eq(w("status=a", COLUMNS, 2, nil), "")
	t.eq(w("web", COLUMNS, 2, nil), "web")
	t.eq(w('"status"=a web', COLUMNS, 2, nil), "web")
	t.eq(w("a   b\tc", COLUMNS, 2, nil), "a b\tc")
	t.eq(w("a\u{a0}\u{a0}b status=1", COLUMNS, 2, nil), "a b")
	t.eq(w("cpu=1..5 web", COLUMNS, 3, "%CPU=2..3"), "%CPU=2..3 web")
	t.eq(w("user=bob", COLUMNS, 2, "STATUS=c"), "user=bob STATUS=c")
	t.eq(w("é status=a ü", COLUMNS, 2, "STATUS=é"), "é STATUS=é ü")
end)

-- ---- order ---------------------------------------------------------------------------------

t.test("digits in text count as numbers, in any case, and the zeros before them not", function()
	local function cmp(a, b)
		local d = query.compare_text(a, b)
		return d < 0 and -1 or d > 0 and 1 or 0
	end
	t.eq(cmp("file9", "file10"), -1)
	t.eq(cmp("file10", "file9"), 1)
	t.eq(cmp("file9", "file9"), 0)
	t.eq(cmp("a", "B"), -1)
	t.eq(cmp("B", "a"), 1)
	t.eq(cmp("abc", "abcd"), -1)
	t.eq(cmp("abcd", "abc"), 1)
	t.eq(cmp("", "a"), -1)
	t.eq(cmp("a1b", "a01b"), 1)
	t.eq(cmp("a01b", "a1b"), -1)
	t.eq(cmp("a007b", "a7c"), -1)
	t.eq(cmp("a7", "a07"), 1)
	t.eq(cmp("a000", "a0"), 1)
	t.eq(cmp("a000b", "a0c"), -1)
	t.eq(cmp("x12345678901234567890", "x2"), 1)
	t.eq(cmp("x12345678901234567890", "x12345678901234567891"), -1)
	t.eq(cmp("1a", "a"), -1)
	t.eq(cmp("a1", "ab"), -1)
	t.eq(cmp("a1", "a-"), 1)
	t.eq(cmp("Zebra", "apple"), 1)
	t.eq(cmp("Élan", "zèbre"), 1)
	t.eq(cmp("école", "Ecole"), 1)
	t.eq(cmp("Ecole", "École"), -1)
	t.eq(cmp("A", "a"), -1)
	t.eq(cmp("a", "A"), 1)
end)

t.test("the key of a word, compared as bytes, puts words where compare_text does", function()
	local words = {
		"", "a", "A", "b", "B", "file1", "file9", "File10", "file010", "file10a", "file10-", "file",
		"file0", "file00", "x1y2", "x1y10", "x01y2", "x2", "x10", "x9", "x12345678901234567890",
		"x2345678901234567890", "x123456789", "x23456789", "Zebra", "apple", "école", "Ecole",
		"École", "ecole", "a b", "a-b", "a_b", "a1", "a-", "ab", "1", "01", "10", "9", "09", "1a",
	}
	local text_key = require("query.order").text_key
	for _, a in ipairs(words) do
		for _, b in ipairs(words) do
			local d = query.compare_text(a, b)
			local ka, kb = text_key(a), text_key(b)
			local by_key = ka < kb and -1 or ka > kb and 1 or 0
			t.eq(by_key, d < 0 and -1 or d > 0 and 1 or 0, a .. " / " .. b)
		end
	end
end)

t.test("a sort key is a cell read once, and two keys are in order", function()
	t.eq(query.sort_key("12"), { text = "12", empty = false, q = { kind = "number", value = 12 } })
	t.eq(query.sort_key("web"), { text = "web", empty = false })
	t.eq(query.sort_key("  "), { text = "  ", empty = true })
	local function k(cell)
		return query.sort_key(cell)
	end
	t.ok(query.compare_keys(k("2"), k("10")) < 0)
	t.ok(query.compare_keys(k("10"), k("2")) > 0)
	t.ok(query.compare_keys(k("1000"), k("1Ki")) < 0)
	t.ok(query.compare_keys(k("5"), k("web")) < 0)
	t.ok(query.compare_keys(k("web"), k("5")) > 0)
	t.ok(query.compare_keys(k(""), k("5")) > 0)
	t.ok(query.compare_keys(k("5"), k("")) < 0)
	t.eq(query.compare_keys(k(""), k(" ")), 0)
	t.ok(query.compare_keys(k("1h"), k("1G")) < 0)
	t.ok(query.compare_keys(k("1G"), k("1h")) > 0)
	t.ok(query.compare_keys(k("2026-10-22"), k("5")) < 0)
	-- Equal quantities go by their text, so that the order is the same however they come.
	t.ok(query.compare_keys(k("1.0"), k("1")) ~= 0)
	t.eq(query.compare_keys(k("1"), k("1")), 0)
	t.ok(query.compare_ordered(k("2"), k("10"), true) > 0)
	t.ok(query.compare_ordered(k(""), k("10"), true) > 0)
	t.ok(query.compare_ordered(k("10"), k(""), true) < 0)
	t.eq(query.compare_ordered(k(""), k(""), true), 0)
end)

t.test("rows with equal cells keep the order they came in, in either direction", function()
	local rows = {
		row("a", "1"), row("b", "2"), row("c", "1"), row("d", "web"), row("e", "2"),
		row("f", "web"), row("g", ""), row("h", "1"), row("i", " "), row("j", "WEB"),
	}
	local function names(indices)
		local list = {}
		for i, at in ipairs(indices) do
			list[i] = rows[at].cells[1]
		end
		return table.concat(list)
	end
	t.eq(names(query.order(rows, range(#rows), 2, false)), "achbejdfgi")
	t.eq(names(query.order(rows, range(#rows), 2, true)), "dfjbeachgi")
	-- The rows named, in the order named: ties go by the order of the list, not by row number.
	t.eq(names(query.order(rows, { 8, 3, 1, 5, 2 }, 2, false)), "hcaeb")
	t.eq(names(query.order(rows, { 8, 3, 1, 5, 2 }, 2, true)), "ebhca")
	t.eq(query.order(rows, {}, 2, false), {})
	t.eq(query.order(rows, { 4 }, 2, true), { 4 })
	-- A column the rows lack is all empty cells.
	t.eq(names(query.order(rows, { 3, 1, 2 }, 9, false)), "cab")
end)

t.test("numbers sort as numbers whatever their unit, and a number among sizes is bytes", function()
	t.eq(ordered({ "1G", "5", "512M", "1k", "1000", "3.5K", "0" }, false),
		{ "0", "5", "1000", "1k", "3.5K", "512M", "1G" })
	t.eq(ordered({ "2h", "90s", "1:00", "61", "3d", "500ms" }, false),
		{ "500ms", "1:00", "61", "90s", "2h", "3d" })
	t.eq(ordered({ "2026-10-22", "2026-01-01T00:00:00Z", "2026-10-21 23:59", "2025-12-31" }, false),
		{ "2025-12-31", "2026-01-01T00:00:00Z", "2026-10-21 23:59", "2026-10-22" })
	t.eq(ordered({ "-5", "5", "-10", "10", "-0.5" }, false), { "-10", "-5", "-0.5", "5", "10" })
	t.eq(ordered({ "50%", "9", "100%", "9.5%" }, true), { "100%", "50%", "9.5%", "9" })
end)

t.test("words sort in any case, their numbers as numbers, after the quantities", function()
	t.eq(ordered({ "file10", "File9", "file1", "b", "A", "7", "" }, false),
		{ "7", "A", "b", "file1", "File9", "file10", "" })
	t.eq(ordered({ "file10", "File9", "file1", "b", "A", "7", "" }, true),
		{ "file10", "File9", "file1", "b", "A", "7", "" })
	-- Cells that differ in case only go by their bytes, and in the same order the other way.
	t.eq(ordered({ "web", "Web", "WEB", "wEb" }, false), { "WEB", "Web", "wEb", "web" })
	t.eq(ordered({ "web", "Web", "WEB", "wEb" }, true), { "web", "wEb", "Web", "WEB" })
	t.eq(ordered({ "école", "Zebra", "Éclair", "apple", "ecole" }, false),
		{ "apple", "ecole", "Zebra", "Éclair", "école" })
	t.eq(ordered({ " ", "x", "", "  ", "1" }, false), { "1", "x", " ", "", "  " })
	t.eq(ordered({ " ", "x", "", "  ", "1" }, true), { "x", "1", " ", "", "  " })
end)

t.test("equal quantities go by their text, kinds that cannot meet by their names", function()
	t.eq(ordered({ "1", "1.0", "01", "+1", "1" }, false), { "+1", "01", "1", "1", "1.0" })
	t.eq(ordered({ "1", "1.0", "01", "+1", "1" }, true), { "1.0", "1", "1", "01", "+1" })
	t.eq(ordered({ "1G", "2h", "1M", "30s", "x", "" }, false), { "30s", "2h", "1M", "1G", "x", "" })
	t.eq(ordered({ "1G", "2h", "1M", "30s", "x", "" }, true), { "x", "1G", "1M", "2h", "30s", "" })
	t.eq(ordered({ "5", "2026-10-22", "1", "2025-01-01" }, false),
		{ "2025-01-01", "2026-10-22", "1", "5" })
end)

t.test("a sort by a column is the pairwise order, whatever the cells are", function()
	local pool = {
		numbers = { "0", "1", "2", "10", "2.5", "-3", "100%", "1e2", "007", "1.0", "+1", ".5" },
		sizes = { "1k", "1K", "2KB", "3M", "512Mi", "1G", "0B", "1.5Gi" },
		lengths = { "1s", "2m", "3h", "500ms", "1:30", "1d", "0:00:01", "2h30m" },
		dates = {
			"2026-10-22", "2026-10-21", "2026-10-22T08:00Z", "2025-01-01", "2026-10-22 08:00",
		},
		words = {
			"web", "Web", "WEB", "file1", "file2", "file10", "File9", "Ärger", "ärger", "ÉCOLE",
			"école", "я", "Я", "-", "x1y2", "x1y10", "a b", "a  b",
		},
		blanks = { "", " ", "\t", "\u{a0}" },
	}
	-- Each mix holds kinds that can be compared with each other, or two that cannot and no
	-- number to stand between them: the pairwise order is then an order a sort can be checked by.
	local mixes = {
		{ "numbers", "words", "blanks" },
		{ "numbers", "sizes", "words", "blanks" },
		{ "numbers", "lengths", "words" },
		{ "sizes", "words", "blanks" },
		{ "dates", "words", "blanks" },
		{ "dates", "blanks" },
		{ "sizes", "lengths", "words", "blanks" },
		{ "dates", "sizes", "blanks" },
		{ "words" },
		{ "numbers" },
	}
	local next_number = random(42)
	for _, mix in ipairs(mixes) do
		local cells = {}
		for i = 1, 240 do
			local list = pool[mix[next_number(#mix)]]
			cells[i] = list[next_number(#list)]
		end
		local rows = rows_of(cells)
		for _, descending in ipairs({ false, true }) do
			-- Insertion sort is stable, and says what the pairwise order makes of the cells.
			local expected = {}
			for i = 1, #cells do
				local at = i
				while at > 1 do
					local d = query.compare_ordered(
						query.sort_key(cells[expected[at - 1]]),
						query.sort_key(cells[i]),
						descending
					)
					if d <= 0 then
						break
					end
					expected[at] = expected[at - 1]
					at -= 1
				end
				expected[at] = i
			end
			t.eq(query.order(rows, range(#rows), 1, descending), expected,
				table.concat(mix, "+") .. (descending and " descending" or " ascending"))
		end
	end
end)

t.test("a column of kinds that cannot all be compared is sorted all the same", function()
	local cells = { "5", "1G", "2h", "2026-10-22", "x", "", "1k", "3", "1h", "2025-01-01" }
	local rows = rows_of(cells)
	for _, descending in ipairs({ false, true }) do
		local result = query.order(rows, range(#rows), 1, descending)
		local seen = {}
		for _, at in ipairs(result) do
			seen[at] = true
		end
		t.eq(#result, #cells)
		for i = 1, #cells do
			t.ok(seen[i], "row " .. i)
		end
		t.eq(result[#result], 6)
	end
end)

t.test("filter names the rows a query keeps, in the order they come", function()
	local compiled = query.compile(query.parse("running", COLUMNS))
	t.eq(query.filter(ROWS, compiled), { 1, 3 })
	t.eq(query.filter(ROWS, compiled, { 4, 3, 2, 1 }), { 3, 1 })
	t.eq(query.filter(ROWS, query.compile(query.parse("", COLUMNS))), { 1, 2, 3, 4 })
	t.eq(query.filter({}, compiled), {})
	t.eq(query.order(ROWS, query.filter(ROWS, compiled), 3, true), { 3, 1 })
end)

-- ---- what the column panel shows -----------------------------------------------------------

t.test("a column's panel counts its values, most common first, and charts quantities", function()
	local result = stats.column(ROWS, range(#ROWS), 2, { top = 2 })
	t.eq(result.kind, "text")
	t.eq(result.filled, 4)
	t.eq(result.empty, 0)
	t.eq(result.distinct, 3)
	t.eq(result.top, {
		{ value = "Running", count = 2 }, { value = "CrashLoopBackOff", count = 1 },
	})
	t.eq(result.more, true)
	t.eq(result.buckets, nil)

	local cpu = stats.column(ROWS, range(#ROWS), 3, {})
	t.eq(cpu.kind, "number")
	t.eq(cpu.filled, 3)
	t.eq(cpu.empty, 1)
	t.eq(cpu.distinct, 4)
	t.eq(cpu.more, false)
	t.eq(cpu.top[1], { value = "", count = 1 })
	t.eq(cpu.top[4], { value = "88", count = 1 })
	t.eq(cpu.quantities, 3)
	t.eq(cpu.min, 0)
	t.eq(cpu.median, 12.5)
	t.eq(cpu.max, 88)
	t.eq(cpu.log, false)
	t.eq(#cpu.buckets, 36)
	t.eq(cpu.buckets[1].from, 0)
	t.eq(cpu.buckets[1].count, 1)
	t.ok(math.abs(cpu.buckets[1].to - 88 / 36) < 1e-12)
	t.eq(cpu.buckets[36].count, 1)
	t.eq(cpu.buckets[36].to, 88)
	local total = 0
	for _, bucket in ipairs(cpu.buckets) do
		total += bucket.count
	end
	t.eq(total, 3)
end)

t.test("a panel is over the rows named, with the kind of the whole column unless given", function()
	local some = { 1, 2 }
	local result = stats.column(ROWS, some, 4, {})
	t.eq(result.kind, "size")
	t.eq(result.filled, 2)
	t.eq(result.min, 512 * 1024 ^ 2)
	t.eq(result.max, 1.2 * 1024 ^ 3)
	t.eq(stats.column(ROWS, some, 4, { kind = "text" }).quantities, nil)
	t.eq(stats.column(ROWS, some, 4, { kind = "text" }).kind, "text")
	t.eq(stats.column(ROWS, {}, 4, {}).distinct, 0)
	t.eq(stats.column(ROWS, {}, 4, {}).buckets, nil)
	-- Quantities of another kind than the column's are not on its chart, numbers are.
	local mixed = { row("1G"), row("5"), row("2h"), row("3M"), row("x") }
	local chart = stats.column(mixed, range(#mixed), 1, { kind = "size", buckets = 4 })
	t.eq(chart.quantities, 3)
	t.eq(chart.min, 5)
	t.eq(#chart.buckets, 4)
	t.eq(stats.kind_of(ROWS, 3), "number")
	t.eq(stats.kind_of(ROWS, 5), "duration")
	t.eq(stats.kind_of(ROWS, 7), "date")
	t.eq(stats.kinds(ROWS, 7), { "text", "text", "number", "size", "duration", "text", "date" })
end)

t.test("a chart is in logarithms when its greatest is a hundred times its least", function()
	local rows = {}
	for _, ms in ipairs({ "1ms", "2ms", "3ms", "5ms", "8ms", "40ms", "900ms", "2s", "30s" }) do
		rows[#rows + 1] = row(ms)
	end
	local result = stats.column(rows, range(#rows), 1, { buckets = 6 })
	t.eq(result.kind, "duration")
	t.eq(result.log, true)
	t.eq(result.min, 0.001)
	t.eq(result.max, 30)
	t.eq(result.median, 0.008)
	t.eq(#result.buckets, 6)
	t.ok(math.abs(result.buckets[1].from - 0.001) < 1e-12)
	t.ok(math.abs(result.buckets[6].to - 30) < 1e-9)
	t.ok(math.abs(result.buckets[1].to - result.buckets[2].from) < 1e-12)
	t.ok(math.abs(stats.place(result, 30) - 1) < 1e-12)
	t.ok(math.abs(stats.place(result, 0.001)) < 1e-12)
	t.ok(math.abs(stats.value_at(result, 0) - 0.001) < 1e-12)
	-- The many small ones are in several buckets, not one.
	t.ok(result.buckets[1].count >= 4)
	t.ok(result.buckets[6].count == 1)
	local linear = stats.column(rows, { 1, 2, 3, 4 }, 1, { buckets = 4 })
	t.eq(linear.log, false)
	t.ok(math.abs(stats.value_at(linear, 0.5) - 0.003) < 1e-12)
	t.eq(stats.column({ row("5"), row("5") }, { 1, 2 }, 1, {}).span, 1)
end)

t.test("the values of a column are the most common first, then the first in byte order", function()
	local rows = {}
	for _, v in ipairs({ "b", "a", "c", "b", "d", "a", "b", "e", "", "e" }) do
		rows[#rows + 1] = row(v)
	end
	local result = stats.column(rows, range(#rows), 1, { top = 4 })
	t.eq(result.top, {
		{ value = "b", count = 3 }, { value = "a", count = 2 }, { value = "e", count = 2 },
		{ value = "", count = 1 },
	})
	t.eq(result.distinct, 6)
	t.eq(result.filled, 9)
	t.eq(result.empty, 1)
	t.eq(result.more, true)
	t.eq(stats.column(rows, range(#rows), 1, { top = 0 }).top, {})
	t.eq(#stats.column(rows, range(#rows), 1, { top = 100 }).top, 6)
end)

-- ---- 200 000 rows --------------------------------------------------------------------------

local function ps_rows(count)
	local next_number = random(20261022)
	local users = { "root", "kalaomer", "_windowserver", "daemon", "_nsurlsessiond", "www" }
	local states = { "Ss", "S", "R+", "S+", "Ss+", "U", "Z" }
	local words = { "web", "api", "canary", "worker", "daemon", "agent", "node", "helper", "mdns" }
	local rows = {}
	for i = 1, count do
		local command = string.format(
			"/usr/libexec/%s%d --%s --port=%d",
			words[next_number(#words)],
			next_number(99),
			words[next_number(#words)],
			1000 + next_number(9000)
		)
		rows[i] = {
			cells = {
				users[next_number(#users)],
				tostring(next_number(99999)),
				string.format("%.1f", (next_number(1000) - 1) / 10),
				string.format("%.1f", (next_number(100) - 1) / 10),
				tostring(next_number(9000000) + 400000),
				tostring(next_number(500000)),
				next_number(3) == 1 and "??" or ("ttys00" .. next_number(9)),
				states[next_number(#states)],
				string.format("%d:%02d%s", next_number(12), next_number(60) - 1,
					next_number(2) == 1 and "AM" or "PM"),
				string.format("%d:%02d.%02d", next_number(500) - 1, next_number(60) - 1,
					next_number(100) - 1),
				command,
			},
		}
	end
	return rows
end

local PS_COLUMNS =
	{ "USER", "PID", "%CPU", "%MEM", "VSZ", "RSS", "TTY", "STAT", "START", "TIME", "COMMAND" }

local function timed(label, fn)
	local started = pencere.time.monotonic()
	local result = fn()
	local took = (pencere.time.monotonic() - started) * 1000
	print(string.format("       %-48s %8.1f ms", label, took))
	return result, took
end

t.test("200 000 rows of ps aux are filtered and sorted in seconds", function()
	local rows = timed("build 200000 rows of 11 cells", function()
		return ps_rows(200000)
	end)
	local function run(source)
		return timed("compile + filter  " .. source, function()
			return query.filter(rows, query.compile(query.parse(source, PS_COLUMNS)))
		end)
	end
	local first, first_ms = run("web !canary")
	t.ok(#first > 0 and #first < #rows)
	t.ok(first_ms < 6000)
	local again, again_ms = run("web !canary")
	t.eq(again, first)
	t.ok(again_ms < 6000)
	local busy, busy_ms = run("cpu>50 user=root")
	t.ok(#busy > 0)
	t.ok(busy_ms < 6000)
	local api, api_ms = run("%mem>=2 command~api")
	t.ok(#api > 0)
	t.ok(api_ms < 6000)
	local ranged, ranged_ms = run("pid=1000..2000 rss>100M tty!=?? time<10:00")
	t.ok(ranged_ms < 6000)
	t.ok(#ranged >= 0)

	local all = range(#rows)
	local function check(sorted, column, descending)
		t.eq(#sorted, #rows)
		for i = 1, #sorted - 1, 997 do
			local a = query.sort_key(rows[sorted[i]].cells[column])
			local b = query.sort_key(rows[sorted[i + 1]].cells[column])
			t.ok(query.compare_ordered(a, b, descending) <= 0, "order at " .. i)
		end
	end
	local by_pid, pid_ms = timed("order by PID", function()
		return query.order(rows, all, 2, false)
	end)
	check(by_pid, 2, false)
	t.ok(pid_ms < 6000)
	local by_cpu, cpu_ms = timed("order by %CPU descending", function()
		return query.order(rows, all, 3, true)
	end)
	check(by_cpu, 3, true)
	t.ok(cpu_ms < 6000)
	local by_command, command_ms = timed("order by COMMAND (text)", function()
		return query.order(rows, all, 11, false)
	end)
	check(by_command, 11, false)
	t.ok(command_ms < 6000)
	local _, again_sorted_ms = timed("order by COMMAND, an already ordered list", function()
		return query.order(rows, by_command, 11, false)
	end)
	t.ok(again_sorted_ms < 6000)
	local _, user_ms = timed("order by USER (many equal)", function()
		return query.order(rows, all, 1, false)
	end)
	t.ok(user_ms < 6000)
	local _, time_ms = timed("order by TIME (clock)", function()
		return query.order(rows, by_pid, 10, true)
	end)
	t.ok(time_ms < 6000)
	local panel, panel_ms = timed("panel of %CPU over all rows", function()
		return stats.column(rows, all, 3, {})
	end)
	t.eq(panel.kind, "number")
	t.eq(panel.filled, 200000)
	t.ok(panel_ms < 6000)
	local _, panel_text_ms = timed("panel of COMMAND over all rows", function()
		return stats.column(rows, all, 11, {})
	end)
	t.ok(panel_text_ms < 6000)
end)
