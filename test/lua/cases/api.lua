-- The calls the page makes, answered from a real table: what the page is told of the command line
-- and the rows, that what it shows will go out is what goes out, that the page's refusals come with
-- a code it can act on, and the limits of one answer.

local t = require("t")
local output = require("output")
local session_state = require("state.session")
local api_answer = require("api.answer")
local api_feed = require("api.feed")
local api_list = require("api.list")
local api_panels = require("api.panels")

local PODS = table.concat({
	"NAME      READY   STATUS             AGE",
	"api-1     1/1     Running            3d",
	"web-1     1/1     CrashLoopBackOff   20m",
	"web-2     0/1     Pending            5m",
	"",
}, "\n")

local function start(text, extra, finished)
	local options = {
		query = "",
		confirm = false,
		shape = { kind = "input" },
		given = {},
	}
	for key, value in pairs(extra or {}) do
		options[key] = value
	end
	local session = session_state.new(options)
	session:feed(text)
	if finished ~= false then
		session:end_input()
	end
	local calls = {}
	for _, area in ipairs({ api_list, api_panels, api_answer }) do
		for name, handler in pairs(area.calls(session)) do
			calls[name] = handler
		end
	end
	return session, calls
end

-- What the call raised, as the page is told it.
local function refused(handler, params)
	local ok, err = pcall(handler, params, { cancelled = false })
	t.ok(not ok, "the call was refused")
	return err
end

t.test("the page is told the command line and the rows so far", function()
	local session, calls = start(PODS, { title = "Pods", query = "web", preview = "echo {}" })
	local opened = calls.open({})
	t.eq(opened.title, "Pods")
	t.eq(opened.query, "web")
	t.eq(opened.preview, true)
	t.eq(opened.summary.total, 3)
	t.eq(opened.summary.columns, { "NAME", "READY", "STATUS", "AGE" })
	t.eq(opened.summary.format, "columns")
	t.eq(opened.summary.done, true)
	t.eq(#session.view.shown, 2, "the starting query already keeps the rows")
end)

t.test("open waits a moment for an input still coming, and not for one that is over", function()
	local _, calls = start(PODS, nil, false)
	local began = require("pencere").time.monotonic()
	local opened = calls.open({ wait = 0.05 })
	local waited = require("pencere").time.monotonic() - began
	t.eq(opened.summary.done, false)
	t.ok(waited >= 0.04, "it waited: " .. waited)
	-- A coroutine is what lets it wait; the second call is one with the input over.
	local _, finished = start(PODS)
	began = require("pencere").time.monotonic()
	finished.open({ wait = 5 })
	t.ok(require("pencere").time.monotonic() - began < 1, "it did not")
end)

t.test("what the page shows will go out is what goes out", function()
	local session, calls = start(PODS)
	local gen = session.view.gen
	calls.mark({ gen = gen, op = "range", from = 2, to = 3, on = true })
	local shown = calls.output({ gen = gen })
	t.eq(shown.count, 2)
	local records = { session.table.rows[2], session.table.rows[3] }
	t.eq(shown.text, output.render(records, { kind = "input" }, session.table:source()))
	calls.choose({ gen = gen })
	t.eq(session.answer.kind, "chosen")
	local sent = {}
	for at, id in ipairs(session.answer.ids) do
		sent[at] = session.table.rows[id]
	end
	t.eq(output.render(sent, session.answer.shape, session.table:source()), shown.text)
end)

t.test("columns picked in the page shape what goes out, over the command line's", function()
	local session, calls = start(PODS, { shape = { kind = "fields", names = { "NAME" } } })
	local gen = session.view.gen
	calls.mark({ gen = gen, op = "all", on = true })
	t.eq(calls.output({ gen = gen }).text, "api-1\nweb-1\nweb-2\n")
	t.eq(calls.output({ gen = gen, fields = { "STATUS", "NAME" } }).text,
		"Running\tapi-1\nCrashLoopBackOff\tweb-1\nPending\tweb-2\n")
	calls.choose({ gen = gen, fields = { "AGE" } })
	t.eq(session.answer.shape, { kind = "fields", names = { "AGE" } })
end)

t.test("a choice is the marked rows or the cursor's row; nothing chosen is refused", function()
	local session, calls = start(PODS, { confirm = true })
	local err = refused(calls.choose, { cursor = 1 })
	t.eq(err.code, "failed")
	t.ok(string.find(err.message, "No row was chosen", 1, true))
	t.eq(session.answer, nil)
	local plain_session, plain = start(PODS)
	local nothing = refused(plain.choose, { cursor = 99 })
	t.ok(string.find(nothing.message, "No row was chosen", 1, true))
	plain.choose({ cursor = 2 })
	t.eq(plain_session.answer.ids, { 2 })
end)

t.test("a shape that names no column is refused when the page sends", function()
	local session, calls = start(PODS)
	calls.mark({ op = "all", on = true })
	local err = refused(calls.choose, { fields = { "NOPE" } })
	t.ok(string.find(err.message, 'There is no column named "NOPE"', 1, true), err.message)
	t.eq(session.answer, nil)
	t.eq(calls.output({ fields = { "NOPE" } }).problem, 'There is no column named "NOPE"')
end)

t.test("Send nothing is an answer too", function()
	local session, calls = start(PODS)
	calls.cancel({})
	t.eq(session.answer.kind, "cancelled")
	-- And a second answer does not undo the first.
	calls.mark({ op = "all", on = true })
	calls.choose({})
	t.eq(session.answer.kind, "cancelled")
end)

t.test("a position in a list that has changed is stale; one that names none is not", function()
	local session, calls = start(PODS)
	local gen = session.view.gen
	calls.query({ typed = "web", chips = {} })
	local err = refused(calls.mark, { gen = gen, op = "all", on = true })
	t.eq(err.code, "stale")
	t.eq(refused(calls.row, { gen = gen, pos = 1 }).code, "stale")
	t.eq(calls.window({ gen = gen, from = 1, count = 10 }).stale, true)
	t.eq(calls.mark({ op = "all", on = true }).marked, 2)
end)

t.test("what the page sends is checked, and what does not fit is bad-params", function()
	local _, calls = start(PODS)
	t.eq(refused(calls.window, { from = 0, count = 10 }).code, "bad-params")
	t.eq(refused(calls.window, { from = 1, count = 10000 }).code, "bad-params")
	t.eq(refused(calls.mark, { op = "explode" }).code, "bad-params")
	t.eq(refused(calls.mark, { op = "range", on = true }).code, "bad-params")
	t.eq(refused(calls.query, { typed = 5 }).code, "bad-params")
	t.eq(refused(calls.order, { column = 99 }).code, "bad-params")
	t.eq(refused(calls.column, { column = 99 }).code, "bad-params")
end)

t.test("one answer for the rows in sight is limited: its cells are cut, and its size", function()
	local long = string.rep("é", 1000)
	local lines = { "ID,A,B,C,D,E,F,G,H,I,J,K,L,M,N,O,P,Q,R,S,T" }
	for index = 1, 400 do
		local cells = { tostring(index) }
		for _ = 1, 20 do
			cells[#cells + 1] = long
		end
		lines[#lines + 1] = table.concat(cells, ",")
	end
	local _, calls = start(table.concat(lines, "\n") .. "\n", { input = "csv" })
	local window = calls.window({ from = 1, count = 200 })
	t.ok(#window.rows >= 1 and #window.rows < 200, "the answer was cut short: " .. #window.rows)
	t.eq(utf8.len(window.rows[1].cells[2]), 256, "a cell is cut at a character")
	t.eq(calls.row({ pos = 1 }).cells[2], long, "a row whole is not")
end)

t.test("the picture of what goes out is of the first 1000 rows, and counts the rest", function()
	local lines = {}
	for index = 1, 2500 do
		lines[index] = "row " .. index
	end
	local _, calls = start(table.concat(lines, "\n") .. "\n")
	calls.mark({ op = "all", on = true })
	local shown = calls.output({})
	t.eq(shown.count, 2500)
	t.eq(shown.truncated, true)
	local count = 0
	for _ in string.gmatch(shown.text, "[^\n]+") do
		count += 1
	end
	t.eq(count, 1000)
end)

t.test("a column's values come with the terms a click writes, the chart with its edges", function()
	local _, calls = start(PODS)
	local panel = calls.column({ column = 3 })
	t.eq(panel.top[1].count, 1)
	t.eq(panel.top[1].term, "STATUS=" .. panel.top[1].value)
	local ages = calls.column({ column = 4 })
	t.eq(ages.kind, "duration")
	t.ok(ages.buckets ~= nil and #ages.edges == #ages.buckets + 1, "an edge for each end of a bar")
	t.eq(calls.term({ column = 3, value = "Pending" }).term, "STATUS=Pending")
	t.eq(calls.term({ column = 3, value = "Pending", negate = true }).term, "STATUS!=Pending")
	t.eq(calls.term({ column = 1, value = "two words" }).term, 'NAME="two words"')
end)

t.test("the facet of a column leaves out the column's own terms", function()
	local _, calls = start(PODS)
	calls.query({ typed = "STATUS=Pending", chips = {} })
	local panel = calls.column({ column = 3 })
	t.eq(panel.filled, 3, "the other statuses are still there to choose")
end)

t.test("the topic says the summary at once", function()
	local session = start(PODS)
	local topics = api_feed.topics(session)
	local pushed = {}
	local subscription = {
		push = function(_, value)
			pushed[#pushed + 1] = value
		end,
		on_end = function() end,
	}
	topics.rows(nil, subscription)
	t.eq(#pushed, 1, "the summary at once")
	t.eq(pushed[1].total, 3)
end)

t.test("a cell is cut at a character, and a row of a few characters is shown whole", function()
	local cells = string.rep("é", 200)
	local _, calls = start("ID,TEXT\n1," .. cells .. "\n", { input = "csv" })
	t.eq(calls.window({ from = 1, count = 1 }).rows[1].cells[2], cells)
end)

t.test("a cell with a byte that is not text is told with U+FFFD, and goes out as it is", function()
	local session, calls = start("ID,TEXT\n1,bad\255byte\n", { input = "csv" })
	local window = calls.window({ from = 1, count = 1 })
	local text = window.rows[1].cells[2]
	t.eq(text, "bad\u{fffd}byte")
	-- The answer can be sent as JSON, which the cell itself could not.
	t.ok(#require("pencere").json.encode(window) > 0)
	t.eq(calls.row({ pos = 1 }).cells[2], "bad\u{fffd}byte")
	t.eq(session.table.rows[1].cells[2], "bad\255byte", "what is held is not changed")
	calls.mark({ op = "all", on = true })
	t.eq(calls.choose({}).chosen, 1)
	t.eq(session.answer.ids, { 1 })
end)

t.test("a cell over the limit is cut at a character, in linear time", function()
	local cell = string.rep("a", 16380) .. "éééééé"
	local text = "ID,TEXT\n1," .. cell .. "\n2," .. string.rep("b", 20000) .. "\255\n"
	local session = start(text, { input = "csv" })
	t.eq(#session.table.rows[1].cells[2], 16380 + 2 * 2, "not inside a character")
	t.ok(utf8.len(session.table.rows[1].cells[2]) ~= nil)
	t.eq(#session.table.rows[2].cells[2], 16384, "a stray byte does not take the rest with it")
	t.eq(session.table.cut, true)
end)
