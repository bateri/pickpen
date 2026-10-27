-- The page, run against the kit's page API: what it asks of its program, what it shows of what it is
-- told, what its keys and clicks do. Nothing is laid out here (that is the terminal's), so what is
-- looked at is the tree the page hands out and the messages it says; how it looks is not tested.
--
-- The program is a stand-in that holds rows of words and answers the page's calls as pickpen's does,
-- simply: it filters by the words typed, and keeps the marks.

local pencere = require("pencere")
local t = require("t")
local kit = require("kit")

local PRELUDE = pencere.env.get("PENCERE_PRELUDE")
local PAGE = pencere.env.get("PICKPEN_PAGE")

local W, H = 1300, 760

-- ---- the stand-in program ------------------------------------------------------------------------------

local Program = {}
Program.__index = Program

local function new_program(rows, options)
	options = options or {}
	local self = setmetatable({
		rows = rows,
		columns = options.columns or { "NAME", "STATUS", "AGE" },
		kinds = options.kinds or { "text", "text", "duration" },
		marked = {},
		query = "",
		layout = 1,
		marks = 0,
		answered = {},
		boot = options.boot or {},
	}, Program)
	self:refilter()
	return self
end

function Program:refilter()
	self.shown = {}
	local word = string.lower(self.query)
	for id, cells in ipairs(self.rows) do
		if word == "" or string.find(string.lower(table.concat(cells, "\t")), word, 1, true) then
			self.shown[#self.shown + 1] = id - 1
		end
	end
	self.layout += 1
end

function Program:summary()
	local marked, marked_shown = 0, 0
	local shown_set = {}
	for _, id in ipairs(self.shown) do
		shown_set[id] = true
	end
	for id in pairs(self.marked) do
		marked += 1
		if shown_set[id] then
			marked_shown += 1
		end
	end
	local terms = setmetatable({}, pencere.json and pencere.json.array or nil)
	return {
		layout = self.layout,
		marks = self.marks,
		total = #self.rows,
		shown = #self.shown,
		marked = marked,
		marked_shown = marked_shown,
		hidden_marks = marked - marked_shown,
		done = true,
		capped = false,
		format = "columns",
		columns = self.columns,
		kinds = self.kinds,
		widths = { 20, 10, 6 },
		placeholder = "Type to filter: words, !word, STATUS=Running, AGE<1h — F1 for more",
		terms = self.query == "" and {}
			or { { kind = "text", text = self.query, negate = false, from = 0, to = #self.query } },
		unknown = {},
	}
end

-- Answers every call of the page that has no answer yet, as pickpen's program would.
function Program:serve(k)
	local json = k.kit.json
	local more = true
	while more do
		more = false
		for _, message in ipairs(k:all_told()) do
			local call = message.call
			if call and not self.answered[call.id] then
				self.answered[call.id] = true
				more = true
				local result = self:answer(call.method, call.params or {})
				if result ~= nil then
					k.kit.message(json.encode({ response = { id = call.id, result = result } }))
				end
			end
		end
	end
end

function Program:answer(method, params)
	if method == "boot" then
		local boot = {
			version = "0.0.0",
			query = "",
			confirm = self.boot.confirm == true,
			given = {},
			summary = self:summary(),
		}
		for key, value in pairs(self.boot) do
			boot[key] = value
		end
		return boot
	elseif method == "window" then
		local rows = {}
		for index = params.from + 1, math.min(params.from + params.count, #self.shown) do
			local id = self.shown[index]
			rows[#rows + 1] = { id = id, cells = self.rows[id + 1], marked = self.marked[id] == true }
		end
		return { layout = self.layout, marks = self.marks, from = params.from, rows = rows }
	elseif method == "query" then
		self.query = params.query
		self:refilter()
		local sum = self:summary()
		sum.query = self.query
		return sum
	elseif method == "mark" then
		for _, id in ipairs(params.ids) do
			self.marked[id] = params.on or nil
		end
		self.marks += 1
		return self:summary()
	elseif method == "mark_shown" then
		for _, id in ipairs(self.shown) do
			self.marked[id] = params.on or nil
		end
		self.marks += 1
		return self:summary()
	elseif method == "unmark_all" then
		self.marked = {}
		self.marks += 1
		return self:summary()
	elseif method == "output" then
		return {
			count = 1,
			text = table.concat(self.rows[1], " ") .. "\n",
			again = { kind = "none", line = "pickpen --where ''", where = "" },
		}
	elseif method == "column" then
		return {
			column = params.column,
			kind = self.kinds[params.column + 1],
			values = {
				{ value = "Running", count = 3, chosen = false },
				{ value = "Error", count = 1, chosen = false },
			},
			distinct = 2,
			rows = #self.rows,
			chart = self.kinds[params.column + 1] ~= "text"
					and { bins = { 1, 0, 2, 5 }, min = "1m", max = "3h", median = "20m", log = true }
				or nil,
		}
	elseif method == "choose" then
		self.chosen = params
		return { sent = 1 }
	elseif method == "order" then
		self:refilter()
		local sum = self:summary()
		sum.query = self.query
		return sum
	end
	return {}
end

local PODS = {
	{ "api-1", "Running", "53m" },
	{ "api-2", "Completed", "20m" },
	{ "web-1", "CrashLoopBackOff", "23m" },
	{ "web-2", "Running", "40m" },
	{ "worker-1", "Error", "12m" },
}

-- The page, started, and booted by the stand-in with `rows`.
local function opened(rows, options)
	options = options or {}
	local k = kit.start(PRELUDE, PAGE)
	local program = new_program(rows or PODS, options)
	k.program = program
	k:render(options.width or W, options.height or H, 100)
	program:serve(k)
	k:render(options.width or W, options.height or H, 100.1)
	program:serve(k)
	k:render(options.width or W, options.height or H, 100.2)
	-- What the panel shows is asked for once the person has rested a moment.
	k:render(options.width or W, options.height or H, 100.5)
	program:serve(k)
	k:render(options.width or W, options.height or H, 100.6)
	return k, program
end

-- An event, then the program answers and the page draws again.
local function act(k, event)
	event.mods = event.mods or {}
	local reply = k:event(event)
	k.program:serve(k)
	k:render(W, H, (k.now or 100) + 0.01)
	k.program:serve(k)
	k:render(W, H, (k.now or 100) + 0.3)
	k.program:serve(k)
	k:render(W, H, (k.now or 100) + 0.01)
	return reply
end

local function key(k, name, mods)
	return act(k, { type = "key", key = name, mods = mods or {} })
end

local function texts(k)
	return kit.texts(k.root)
end

-- ---- the tests ----------------------------------------------------------------------------------------------

t.test("the page asks its program what it is, listens to the rows, and shows them", function()
	local k = kit.start(PRELUDE, PAGE)
	k:render(W, H, 100)
	t.eq(#k:calls_of("boot"), 1)
	t.has(texts(k), "Waiting for the program")
	local program = new_program(PODS)
	k.program = program
	program:serve(k)
	k:render(W, H, 100.1)
	t.ok(k:subscribed("table"), "listens to the rows")
	program:serve(k)
	k:render(W, H, 100.2)
	local words = texts(k)
	for _, word in ipairs({ "NAME", "STATUS", "AGE", "api-1", "CrashLoopBackOff", "5 rows", "Send this row" }) do
		t.has(words, word)
	end
end)

t.test("the query is the host's field, that says how to filter while it is empty", function()
	local k = opened()
	local field = kit.find(k.root, "query")
	t.ok(field ~= nil, "a field named query")
	t.eq(field.meta.field, "line")
	t.has(kit.texts(field), "Type to filter: words, !word, STATUS=Running")
end)

t.test("what is typed is the program's query, and each term is said as it was read", function()
	local k = opened()
	act(k, { type = "text", field = "query", text = "web" })
	t.eq(k:last_call("query").params.query, "web")
	local words = texts(k)
	t.has(words, "2 of 5 rows")
	t.has(words, "has")
	-- The word is drawn apart in the cells it is in, where it was found.
	t.has(words, "CrashLoopBackOff")
end)

t.test("Esc clears the query, then asks before dropping marks, then sends nothing", function()
	local k = opened()
	act(k, { type = "text", field = "query", text = "web" })
	local reply = key(k, "escape")
	t.eq(k:last_call("query").params.query, "")
	t.eq(reply.fill and reply.fill.query, "")
	key(k, "tab")
	t.eq(k:last_call("mark").params.ids, { 0 })
	reply = key(k, "escape")
	t.ok(not reply.close, "a first Esc with rows marked asks")
	t.has(texts(k), "Esc again to send nothing")
	key(k, "escape")
	t.ok(k:last_call("cancel") ~= nil, "a second Esc sends nothing")
end)

t.test("the arrows move the cursor, and Enter sends the row it is on", function()
	local k = opened()
	key(k, "down")
	key(k, "down")
	key(k, "up")
	key(k, "enter")
	local choose = k:last_call("choose")
	t.ok(choose ~= nil, "Enter sends")
	t.eq(choose.params.ids, { 1 })
end)

t.test("Tab marks the row and steps on; Send then sends the marked rows", function()
	local k = opened()
	key(k, "tab")
	key(k, "tab")
	t.has(texts(k), "2 marked")
	t.has(texts(k), "Send 2 rows")
	key(k, "enter")
	t.eq(k:last_call("choose").params.marked, true)
end)

t.test("with --confirm the cursor's row is not sent: the rows must be marked", function()
	local k = opened(PODS, { boot = { confirm = true, where = "STATUS!=Running" } })
	t.has(texts(k), "Mark the rows to send")
	key(k, "enter")
	t.eq(k:last_call("choose"), nil)
end)

t.test("⌘A marks every row shown, ⇧⌘A unmarks them all", function()
	local k = opened()
	key(k, "a", { command = true })
	t.ok(k:last_call("mark_shown").params.on, "marks the rows shown")
	t.has(texts(k), "5 marked")
	key(k, "a", { command = true, shift = true })
	t.ok(k:last_call("unmark_all") ~= nil, "unmarks")
	t.lacks(texts(k), "marked")
end)

t.test("⌃1 orders by the first column, again for the other way", function()
	local k = opened()
	key(k, "1", { control = true })
	t.eq(k:last_call("order").params, { column = 0, descending = false })
	key(k, "1", { control = true })
	t.eq(k:last_call("order").params, { column = 0, descending = true })
	key(k, "0", { control = true })
	t.eq(k:last_call("order").params, {})
end)

t.test("⌘K is the palette: its field filters the commands, Enter runs one", function()
	local k = opened()
	local reply = key(k, "k", { command = true })
	t.eq(reply.keyboard, { field = "palette" })
	t.ok(kit.find(k.root, "palette") ~= nil, "the palette's field")
	act(k, { type = "text", field = "palette", text = "unmark every" })
	t.has(texts(k), "Unmark every row")
	t.lacks(texts(k), "Last row")
	reply = key(k, "enter")
	t.ok(k:last_call("unmark_all") ~= nil, "the command ran")
	t.eq(reply.keyboard, { field = "query" })
end)

t.test("F1 shows the keys, the mouse and the query, and Esc closes it", function()
	local k = opened()
	key(k, "f1")
	local words = texts(k)
	t.has(words, "Typing always goes to the query.")
	t.has(words, "Drag across the chart")
	t.has(words, "cpu>50  size>=1G  age<2h")
	key(k, "escape")
	t.lacks(texts(k), "Typing always goes to the query.")
end)

t.test("the side panel says what goes out and the command that does it again", function()
	local k = opened()
	-- A wide pane opens it on what goes out.
	t.has(texts(k), "Again, with nobody to ask")
	t.has(texts(k), "pickpen --where ''")
	t.has(texts(k), "api-1 Running 53m")
	key(k, "f4")
	t.lacks(texts(k), "Again, with nobody to ask")
end)

t.test("the column panel counts a column's values and charts its quantities", function()
	local k = opened()
	key(k, "f3")
	t.ok(k:last_call("column") ~= nil, "asks for the column")
	local words = texts(k)
	t.has(words, "Running")
	t.has(words, "2 values in 5 rows")
end)

t.test("a right-click on a row offers what can be done with it", function()
	local k = opened()
	k.bounds_of.rows = { x = 0, y = 60, w = 900, h = 600 }
	k.hit_id = "r:1"
	local reply = act(k, { type = "press", x = 100, y = 60 + 5, button = "right" })
	t.ok(reply.menu ~= nil, "a menu")
	local titles = {}
	for _, entry in ipairs(reply.menu.entries) do
		if type(entry) == "table" then
			titles[#titles + 1] = entry.title
		end
	end
	t.has(titles, "Mark the row")
	t.has(titles, "Send this row")
	t.has(titles, "Copy the row")
	act(k, { type = "menu", index = 1 })
	t.eq(k:last_call("mark").params.ids, { 0 })
end)

t.test("only the rows in sight are made, however many there are", function()
	local rows = {}
	for i = 1, 50000 do
		rows[i] = { "pod-" .. i, i % 3 == 0 and "Error" or "Running", "1m" }
	end
	local k = opened(rows)
	t.has(texts(k), "50,000 rows")
	t.ok(kit.count(k.root) < 3000, "a page of " .. kit.count(k.root) .. " elements")
	-- The page asked for a window of rows, not for all of them.
	local window = k:last_call("window")
	t.ok(window.params.count <= 400, "a window of " .. window.params.count)
end)

t.test("a click on the box in front of a row marks it, a double-click on a row sends it", function()
	local k = opened()
	k.hit_id = "k:3"
	act(k, { type = "press", x = 10, y = 10, button = "left" })
	act(k, { type = "release", x = 10, y = 10, button = "left" })
	t.eq(k:last_call("mark").params, { ids = { 2 }, on = true })
	k.hit_id = "r:2"
	act(k, { type = "press", x = 100, y = 10, button = "left", count = 2 })
	-- Rows are marked: a double-click marks, and does not send.
	t.eq(k:last_call("choose"), nil)
end)

t.test("what goes out follows the cursor once it rests, without waiting for another key", function()
	local k = opened()
	local before = #k:calls_of("output")
	k:event({ type = "key", key = "down", mods = {} })
	k.program:serve(k)
	-- The frame of the key: the page asks to be drawn again a moment later, on its own.
	local _, _, wake = k:render(W, H, 200)
	t.ok(wake ~= nil and wake <= 200.2, "the page wakes itself, at " .. tostring(wake))
	k:render(W, H, wake)
	k.program:serve(k)
	local calls = k:calls_of("output")
	t.ok(#calls > before, "asked what goes out again")
	t.eq(calls[#calls].params.cursor, 1)
end)

t.test("of a wide table only the columns in sight are made, and scrolling across brings the others", function()
	local names = { "ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO", "FOXTROT", "GOLF", "HOTEL", "INDIA", "JULIET" }
	local kinds, row = {}, {}
	for i in ipairs(names) do
		kinds[i] = "text"
		row[i] = string.rep("x", 40)
	end
	local k = opened({ row, row }, { columns = names, kinds = kinds })
	k.extents.rows = { content = 100, view = 300, content_w = 1000, view_w = 300 }
	k:render(W, H, 101)
	k:render(W, H, 101.1)
	local words = texts(k)
	t.has(words, "ALPHA")
	t.lacks(words, "JULIET", "a column far to the right is not made")
	-- The host scrolls the list across, and tells the page where it went.
	t.eq(k:wheel("rows", 700, 0), true, "the rows in sight are built again")
	k:render(W, H, 101.2)
	words = texts(k)
	t.has(words, "JULIET", "scrolled across, it is")
	t.lacks(words, "ALPHA", "and the first, now far to the left, is not")
end)

t.test("the cursor going out of sight asks the host to scroll the list to it", function()
	local rows = {}
	for i = 1, 50 do
		rows[i] = { "pod-" .. i, "Running", i .. "m" }
	end
	local k = opened(rows)
	-- The list shows three rows of twenty-two points of fifty.
	k.extents.rows = { content = 22 * 50, view = 66 }
	k:render(W, H, 101)
	k:settle()
	for _ = 1, 3 do
		key(k, "down")
	end
	t.eq(k.asks[#k.asks], { id = "rows", y = 22, animate = false }, "the fourth row at the bottom")
	t.eq(k.offsets.rows.y, 22)
	key(k, "down", { command = true })
	t.eq(k.offsets.rows.y, 22 * 50 - 66, "the last row: the end of the list")
end)

t.test("a turn of the wheel within the rows made builds nothing; one near their end builds more", function()
	local rows = {}
	for i = 1, 400 do
		rows[i] = { "pod-" .. i, "Running", i .. "m" }
	end
	local k = opened(rows)
	-- Ten rows of twenty-two points in sight, of four hundred.
	k.extents.rows = { content = 22 * 400, view = 220 }
	k:render(W, H, 101)
	k:settle()
	k:render(W, H, 101.1)
	local made = function()
		local count = 0
		for i = 1, 400 do
			if kit.find(k.root, "r:" .. i) then
				count += 1
			end
		end
		return count
	end
	t.ok(made() > 10, "more than is in sight is made: " .. made())
	t.eq(k:wheel("rows", 0, 44), false, "two rows down: the host moved what was made")
	t.eq(kit.find(k.root, "r:250"), nil, "rows far below are not made")
	t.eq(k:wheel("rows", 0, 22 * 240), true, "far down: past the end of what was made")
	k:render(W, H, 101.2)
	t.ok(kit.find(k.root, "r:250") ~= nil, "and the rows there are made")
end)

t.test("going up, the rows above are made as the rows below are going down", function()
	local rows = {}
	for i = 1, 400 do
		rows[i] = { "pod-" .. i, "Running", i .. "m" }
	end
	local k = opened(rows)
	k.extents.rows = { content = 22 * 400, view = 220 }
	k:render(W, H, 101)
	k:settle()
	-- Far down, and made there.
	t.eq(k:wheel("rows", 0, 22 * 200), true)
	k:render(W, H, 101.1)
	t.ok(kit.find(k.root, "r:205") ~= nil)
	t.eq(kit.find(k.root, "r:185"), nil, "little is made behind the way the list went")
	-- Three rows up: near the top of what was made, the way the list goes now.
	t.eq(k:wheel("rows", 0, -22 * 3), true, "near the top of what was made")
	k:render(W, H, 101.2)
	t.ok(kit.find(k.root, "r:185") ~= nil, "and the build makes the rows above")
end)
