-- pickpen's page, run on the kit's own page API with the program's own calls behind it (see
-- `page_host.lua`): what it shows, what the keys and the pointer do to it, and what it asks of the
-- program, which answers from the real table, list and marks.

local pencere = require("pencere")
local t = require("t")
local page_host = require("page_host")
local session_state = require("state.session")
local api_answer = require("api.answer")
local api_feed = require("api.feed")
local api_list = require("api.list")
local api_panels = require("api.panels")

local SOURCE = "view/page.lua"

local PODS = table.concat({
	"NAME      READY   STATUS             AGE",
	"api-1     1/1     Running            3d",
	"web-1     1/1     CrashLoopBackOff   20m",
	"web-2     0/1     Pending            5m",
	"db-1      1/1     Running            12d",
	"",
}, "\n")

local function options_with(extra)
	local options = {
		query = "",
		confirm = false,
		shape = { kind = "input" },
		given = {},
	}
	for key, value in pairs(extra or {}) do
		options[key] = value
	end
	return options
end

-- A page open on `text` as the input of a program with `extra` options.
local function open(text, extra)
	local session = session_state.new(options_with(extra))
	session:feed(text)
	session:end_input()
	local calls = {}
	for _, area in ipairs({ api_list, api_panels, api_answer }) do
		for name, handler in pairs(area.calls(session)) do
			calls[name] = handler
		end
	end
	local host = page_host.new(SOURCE, calls, api_feed.topics(session))
	host.session = session
	host:settle()
	return host, session
end

t.test("the page shows the columns and the rows the program has", function()
	local host = open(PODS)
	local tree = host.tree
	t.ok(page_host.says(tree, "NAME"), "the heading")
	t.ok(page_host.says(tree, "STATUS"), "the heading")
	t.ok(page_host.says(tree, "CrashLoopBackOff"), "a row")
	t.ok(page_host.says(tree, "4 rows"), "the count")
end)

-- The pointer is over `id`, pressed and let go there: a click.
local function click(host, id, mods, button)
	host.over = id
	host:event({ type = "move", x = 10, y = 10 })
	local which = button or "left"
	local reply = host:event({ type = "press", x = 10, y = 10, button = which, mods = mods or {} })
	local released = host:event({ type = "release", x = 10, y = 10, button = which })
	host:settle()
	return reply, released
end

local function cells_shown(host)
	return page_host.texts(host.tree)
end

t.test("what is typed in the terminal's field filters the rows", function()
	local host, session = open(PODS)
	host:event({ type = "text", text = "web" })
	host:settle()
	t.eq(session.view.typed, "web")
	t.eq(#session.view.shown, 2)
	t.ok(page_host.says(host.tree, "2 of 4 rows"), "the count")
	t.ok(not page_host.says(host.tree, "api-1"), "a row that does not match is gone")
	t.ok(page_host.says(host.tree, "has web"), "how the term was read")
end)

t.test("a term that names a column is compared, one that names none is a word", function()
	local host, session = open(PODS)
	host:event({ type = "text", text = "STATUS!=Running" })
	host:settle()
	t.eq(#session.view.shown, 2)
	t.ok(page_host.says(host.tree, "STATUS is not Running"))
	host:event({ type = "text", text = "PORT=80" })
	host:settle()
	t.ok(page_host.says(host.tree, "no column"), "the warning")
end)

t.test("the keys move the cursor, mark, and send what is marked", function()
	local host, session = open(PODS)
	host:key("down")
	t.eq(host.kit ~= nil, true)
	-- Tab marks the row and goes on.
	host:key("tab")
	host:key("tab")
	host:settle()
	t.eq(session.view.marked_count, 2)
	t.ok(page_host.says(host.tree, "2 rows marked"))
	host:key("enter")
	host:settle()
	t.eq(session.answer.kind, "chosen")
	-- The cursor started on the first row and went down once: rows 2 and 3 were marked.
	t.eq(session.answer.ids, { 2, 3 })
end)

t.test("with nothing marked Send sends the row under the cursor", function()
	local host, session = open(PODS)
	host:key("down")
	host:key("down")
	host:key("enter")
	host:settle()
	t.eq(session.answer.ids, { 3 })
end)

t.test("with --confirm nothing marked sends nothing and says so", function()
	local host, session = open(PODS, { confirm = true })
	host:key("enter")
	host:settle()
	t.eq(session.answer, nil)
	t.ok(page_host.says(host.tree, "Mark the rows to send first"))
end)

t.test("a box marks, a drag down the boxes marks the rows it passes, a click undoes", function()
	local host, session = open(PODS)
	host.over = "box:1"
	host:event({ type = "press", x = 5, y = 5, button = "left", mods = {} })
	host.over = "box:3"
	host:event({ type = "move", x = 5, y = 60 })
	host:event({ type = "release", x = 5, y = 60, button = "left" })
	host:settle()
	t.eq(session.view.marked_count, 3)
	host.over = "box:2"
	click(host, "box:2")
	t.eq(session.view.marked_count, 2)
end)

t.test("shift-arrow marks a run, command-A marks every row shown, shift-command-A none", function()
	local host, session = open(PODS)
	host:key("down", { shift = true })
	host:key("down", { shift = true })
	host:settle()
	t.eq(session.view.marked_count, 3)
	host:key("a", { command = true })
	host:settle()
	t.eq(session.view.marked_count, 4)
	host:key("a", { command = true, shift = true })
	host:settle()
	t.eq(session.view.marked_count, 0)
end)

t.test("a click on a heading orders by it, up, then down, then as it came", function()
	local host, session = open(PODS)
	click(host, "head:4")
	t.eq(session.view.order, { column = 4, descending = false })
	click(host, "head:4")
	t.eq(session.view.order, { column = 4, descending = true })
	click(host, "head:4")
	t.eq(session.view.order, nil)
end)

t.test("Esc closes what is open, then the chips, then asks twice with rows marked", function()
	local host, session = open(PODS)
	host:key("?")
	t.ok(page_host.says(host:render(), "Keys, the mouse and the query"))
	host:key("escape")
	t.ok(not page_host.says(host:render(), "Keys, the mouse and the query"))
	host:key("tab")
	host:key("escape")
	host:settle()
	t.eq(session.answer, nil, "the first Esc only asks")
	t.ok(page_host.says(host.tree, "Esc again"))
	host:key("escape")
	host:settle()
	t.eq(session.answer.kind, "cancelled")
end)

t.test("a right click on a cell offers its term, written beside what is typed", function()
	local host, session = open(PODS)
	host.boxes["row:2"] = { x = 0, y = 52, w = 800, h = 24 }
	host.over = "row:2"
	host:event({ type = "move", x = 100, y = 60 })
	local reply = host:event({ type = "press", x = 330, y = 60, button = "right", mods = {} })
	t.ok(reply.menu ~= nil, "a menu")
	t.ok(string.find(reply.menu.entries[1].title, "Only rows where", 1, true))
	host:event({ type = "release", x = 330, y = 60, button = "right" })
	host:event({ type = "menu", index = 1 })
	host:settle()
	t.eq(#session.view.chips, 1)
	t.ok(page_host.says(host.tree, "is"))
end)

t.test("the column panel lists the values, and a click keeps the rows with one", function()
	local host, session = open(PODS)
	click(host, "tab-column")
	host:settle()
	host:settle()
	t.ok(page_host.says(host.tree, "filled"))
	-- The panel opens on the first column; go to the status column.
	click(host, "col-next")
	click(host, "col-next")
	host:settle()
	click(host, "value:1")
	host:settle()
	t.eq(#session.view.chips, 1)
	t.ok(#session.view.shown < 4)
end)

t.test("the palette lists the commands and runs the one chosen", function()
	local host, session = open(PODS)
	host:key("k", { command = true })
	host:settle()
	t.ok(page_host.says(host.tree, "Mark every row shown"))
	for _, letter in ipairs({ "e", "v", "e", "r", "y" }) do
		host:key(letter)
	end
	host:key("enter")
	host:settle()
	t.eq(session.view.marked_count, 4)
end)

t.test("the output panel shows what will go out and the command line again", function()
	local host, session = open(PODS, { query = "" })
	host:event({ type = "text", text = "web" })
	host:key("a", { command = true })
	click(host, "tab-output")
	host:settle()
	host:settle()
	t.ok(page_host.says(host.tree, "web-1"))
	t.ok(page_host.says(host.tree, "pickpen --where web"))
	t.ok(page_host.says(host.tree, "This chooses the 2 rows marked"))
end)

t.test("a long list is shown through a window of rows, not one element for each", function()
	local lines = { "ID  NAME" }
	for index = 1, 50000 do
		lines[#lines + 1] = string.format("%-6d row-%d", index, index)
	end
	local host, session = open(table.concat(lines, "\n") .. "\n")
	t.eq(#session.table.rows, 50000)
	t.ok(page_host.count(host.tree) < 3000, "elements in the frame: " .. page_host.count(host.tree))
	t.ok(page_host.says(host.tree, "50,000 rows"))
	host:key("down", { command = true })
	host:settle()
	t.ok(page_host.says(host.tree, "row-50000"), "the last row after the jump")
end)

t.test("a second click on a row at once sends it; one a moment later does not", function()
	local host, session = open(PODS)
	click(host, "row:2")
	click(host, "row:3")
	t.eq(session.answer, nil, "two rows, two clicks")
	click(host, "row:3")
	host:settle()
	t.eq(session.answer.ids, { 3 })

	-- A second click after the first one's moment has passed is a click again.
	local later, other = open(PODS)
	click(later, "row:2")
	later:render()
	later.now += 5
	later:render()
	click(later, "row:2")
	t.eq(other.answer, nil)
	t.eq(later.session.answer, nil)
end)

t.test("a message to the person goes away by itself", function()
	local host = open(PODS, { confirm = true })
	host:key("enter")
	t.ok(page_host.says(host:render(), "Mark the rows to send first"))
	t.ok(host.wake ~= nil, "a frame is asked for when it is over")
	host.now += 3
	t.ok(not page_host.says(host:render(), "Mark the rows to send first"))
	t.ok(host.wake == nil, "nothing more is waited for")
end)

t.test("Esc with rows marked asks, and asks again once its moment has passed", function()
	local host, session = open(PODS)
	host:key("tab")
	host:key("escape")
	host:render()
	host.now += 4
	host:render()
	host:key("escape")
	host:settle()
	t.eq(session.answer, nil, "the moment passed: it asked again, and did not send nothing")
end)

t.test("the rows the program has too many of are not asked for twice", function()
	local lines = { "ID  NAME" }
	for index = 1, 3000 do
		lines[#lines + 1] = string.format("%-6d row-%d", index, index)
	end
	local host = open(table.concat(lines, "\n") .. "\n")
	local asked = 0
	for _, text in ipairs(host.sent) do
		if string.find(text, '"method":"window"', 1, true) then
			asked += 1
		end
	end
	host:render()
	host:render()
	local after = 0
	for _, text in ipairs(host.sent) do
		if string.find(text, '"method":"window"', 1, true) then
			after += 1
		end
	end
	t.eq(after, asked, "a render that finds the rows in hand asks for none")
end)

local function calls_of(host, method)
	local n = 0
	for _, text in ipairs(host.sent) do
		if string.find(text, '"method":"' .. method .. '"', 1, true) then
			n += 1
		end
	end
	return n
end

t.test("a refusal because the list changed gives the page back to the person", function()
	local host, session = open(PODS)
	session.view:refilter()
	host:key("enter")
	host:settle()
	t.eq(session.answer, nil, "the list had changed: nothing was sent")
	t.ok(page_host.says(host.tree, "The list changed"))
	host:key("enter")
	host:settle()
	t.eq(session.answer.kind, "chosen", "and the page is the person's again")
end)

t.test("the query the command line started with stands as a term that can be taken out", function()
	local host, session = open(PODS, { query = "web" })
	t.eq(session.view.typed, "")
	t.eq(session.view.chips, { "web" })
	t.eq(#session.view.shown, 2)
	t.ok(page_host.says(host.tree, "Remove"))
	click(host, "chip:1")
	t.eq(#session.view.shown, 4)
end)

t.test("following the last row scrolls to it as rows come", function()
	local lines = { "ID  NAME" }
	for index = 1, 60 do
		lines[#lines + 1] = string.format("%-6d row-%d", index, index)
	end
	local host, session = open(table.concat(lines, "\n") .. "\n")
	host.boxes.list = { x = 0, y = 100, w = 800, h = 240, content = 60 * 24 }
	host:key("down", { command = true })
	host:settle()
	local listing = page_host.find(host.tree, function(node)
		return node.meta and node.meta.id == "list"
	end)
	t.eq(listing.style.scroll_y, 60 * 24 - 240, "the last row is the last in sight")
	session:feed(string.rep("0     later\n", 30))
	host.boxes.list.content = 90 * 24
	host:push_now(require("api.summary").of(session))
	host:settle()
	listing = page_host.find(host.tree, function(node)
		return node.meta and node.meta.id == "list"
	end)
	t.eq(listing.style.scroll_y, 90 * 24 - 240, "and goes on to the new last row")
end)

t.test("rows that come do not ask for the row again, unless they move the cursor", function()
	local host, session = open(PODS)
	click(host, "tab-row")
	host:settle()
	local before = calls_of(host, "row")
	for _ = 1, 3 do
		session:feed("db-9     1/1     Running            1d\n")
		host:push_now(require("api.summary").of(session))
		host:settle()
	end
	t.eq(calls_of(host, "row"), before, "the cursor's row is the same row")
end)

t.test("the output panel follows the cursor", function()
	local host = open(PODS)
	click(host, "tab-output")
	host:settle()
	t.ok(page_host.says(host.tree, "api-1"))
	host:key("down")
	host:settle()
	t.ok(page_host.says(host.tree, "web-1"), "the row Send would send now")
end)

t.test("the test host finds the scripts a page requires as the terminal does", function()
	local resolve = page_host.resolve
	t.eq(resolve("view/other.lua", "./page"), "view/page.lua")
	t.eq(select(2, resolve("view/page.lua", "./nothing/here")), "nothing at view/nothing/here")
	t.eq(select(2, resolve("view/page.lua", "parts/x")), "a path starts with ./ or ../")
	t.eq(select(2, resolve("view/page.lua", "../../x")), "a path out of the bundle")
end)
