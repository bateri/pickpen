-- What an agent reads of pickpen's page in a few states, set against goldens (test/reading/goldens/<state>.txt),
-- and the reading audit of each (a control with no name, an item said twice, a modal's page read behind it).
-- The page is opened under the host with no screen (pencere-test), with a stand-in for the program that
-- answers the page's calls as the page tests' own does. `make test-reading` runs it; PENCERE_BLESS=1 writes
-- the goldens (read the diff: it is how an agent reads the page).

local pencere = require("pencere")
local test = require("pencere.test")

-- Where the goldens are (an absolute path, given by the Makefile), and whether this run writes them.
local GOLDENS = pencere.env.get("READING_GOLDENS")
assert(GOLDENS and GOLDENS ~= "", "READING_GOLDENS names the directory of the goldens: make test-reading")
local BLESS = (pencere.env.get("PENCERE_BLESS") or "") ~= ""

local PODS = {
	{ "api-1", "Running", "53m" },
	{ "api-2", "Completed", "20m" },
	{ "web-1", "CrashLoopBackOff", "23m" },
	{ "web-2", "Running", "40m" },
	{ "worker-1", "Error", "12m" },
}

local expect = test.expect

-- The reading of the main screen, kept to see that a state is not the main screen again (a key that did not
-- route would keep a copy of it): `marker` is a word the state must say.
local MAIN

local function save(name, page, marker)
	if marker then
		expect(page):to_say(marker)
	end
	local text = page.raw:reading()
	if name == "main" then
		MAIN = text
	else
		assert(text ~= MAIN, name .. ": the reading is the main screen's")
	end
	text = text .. (string.sub(text, -1) == "\n" and "" or "\n")
	local file = GOLDENS .. "/" .. name .. ".txt"
	if BLESS then
		pencere.fs.write(file, text)
	else
		local ok, golden = pcall(pencere.fs.read, file)
		assert(ok, name .. ": no golden at " .. file .. ": PENCERE_BLESS=1")
		assert(
			golden == text,
			name .. ": the page is read otherwise than the golden says: PENCERE_BLESS=1 writes it\n" .. text
		)
	end
	local flaws = page.raw:audit()
	assert(#flaws == 0, name .. ": the reading audit finds:\n" .. table.concat(flaws, "\n"))
end

-- The stand-in program: rows, a filter by the words typed, the marks.
local function program(rows, options)
	options = options or {}
	local self = {
		rows = rows,
		columns = { "NAME", "STATUS", "AGE" },
		kinds = { "text", "text", "duration" },
		marked = {},
		query = "",
		layout = 1,
		marks = 0,
		shown = {},
	}
	function self.refilter()
		self.shown = {}
		local word = string.lower(self.query)
		for id, cells in ipairs(self.rows) do
			if word == "" or string.find(string.lower(table.concat(cells, "\t")), word, 1, true) then
				self.shown[#self.shown + 1] = id - 1
			end
		end
		self.layout += 1
	end
	function self.summary()
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
			terms = self.query == "" and {} or {
				{ kind = "text", text = self.query, negate = false, at = "anywhere", from = 0, to = #self.query },
			},
			unknown = {},
			fuzzy = false,
		}
	end
	local function with_query()
		local sum = self.summary()
		sum.query = self.query
		return sum
	end
	self.refilter()
	self.calls = {
		boot = function()
			local boot = { version = "0.0.0", query = "", confirm = false, given = {}, summary = self.summary() }
			for key, value in pairs(options.boot or {}) do
				boot[key] = value
			end
			return boot
		end,
		window = function(params)
			local rows_out = {}
			for index = params.from + 1, math.min(params.from + params.count, #self.shown) do
				local id = self.shown[index]
				rows_out[#rows_out + 1] = { id = id, cells = self.rows[id + 1], marked = self.marked[id] == true }
			end
			return { layout = self.layout, marks = self.marks, from = params.from, rows = rows_out }
		end,
		query = function(params)
			self.query = params.query
			self.refilter()
			return with_query()
		end,
		mark = function(params)
			for _, id in ipairs(params.ids) do
				self.marked[id] = params.on or nil
			end
			self.marks += 1
			return self.summary()
		end,
		mark_shown = function(params)
			for _, id in ipairs(self.shown) do
				self.marked[id] = params.on or nil
			end
			self.marks += 1
			return self.summary()
		end,
		unmark_all = function()
			self.marked = {}
			self.marks += 1
			return self.summary()
		end,
		output = function()
			return {
				count = 1,
				text = table.concat(self.rows[1], " ") .. "\n",
				again = { kind = "none", line = "pickpen --where ''", where = "" },
			}
		end,
		column = function(params)
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
		end,
		preview = function()
			return { text = "Name: api-1\nStatus: Running\nAge: 53m\n", status = 0 }
		end,
		choose = function()
			return { sent = 1 }
		end,
		execute = function(params)
			return { status = 0, said = "deleted " .. self.rows[params.id + 1][1] }
		end,
		reload = function()
			self.refilter()
			return with_query()
		end,
		fuzzy = function()
			return with_query()
		end,
		order = function()
			self.refilter()
			return with_query()
		end,
	}
	return self
end

-- The page, opened and rested: what the panel shows is asked for once the person has paused.
local function open(options)
	options = options or {}
	local stand_in = program(PODS, options)
	local page = test.open({
		size = { options.width or 1300, options.height or 760 },
		fonts = "fixed",
		calls = stand_in.calls,
	})
	page:advance(1)
	page:settle()
	return page
end

local function rest(page)
	page:advance(1)
	page:settle()
end

test("main", function()
	save("main", open(), "5 rows")
end)

test("filter", function()
	local page = open()
	page.raw:fill_id("query", "web")
	rest(page)
	save("filter", page, "2 of 5 rows")
end)

test("marked", function()
	local page = open()
	page:press("tab")
	page:press("tab")
	rest(page)
	save("marked", page, "2 marked")
end)

test("all-marked", function()
	local page = open()
	page:click_id("hb")
	rest(page)
	save("all-marked", page, "5 marked")
end)

test("sorted", function()
	local page = open()
	page:press("ctrl+1")
	page:press("ctrl+1")
	rest(page)
	local order = page:last_call("order")
	assert(order and order.params.descending == true, "sorted: the page did not ask for the descending order")
	save("sorted", page)
end)

test("palette", function()
	local page = open()
	page:press("cmd+k")
	rest(page)
	save("palette", page, "Unmark every row")
end)

test("help", function()
	local page = open()
	page:press("f1")
	rest(page)
	save("help", page, "Typing always goes to the query.")
end)

test("column-panel", function()
	local page = open()
	page:press("ctrl+3")
	page:press("f3")
	rest(page)
	save("column-panel", page, "2 values in 5 rows")
end)

test("row-preview", function()
	local page = open({ boot = { preview = "describe {NAME}" } })
	rest(page)
	assert(page:last_call("preview"), "row-preview: the page did not ask for the preview")
	save("row-preview", page)
end)

test("confirm", function()
	local page = open({ boot = { confirm = true, where = "STATUS!=Running" } })
	rest(page)
	save("confirm", page, "Mark the rows to send")
end)

test("toast", function()
	local page = open({ boot = { execute = "kubectl delete pod {NAME}", reload = "kubectl get pods" } })
	page:press("down")
	page:press("ctrl+x")
	page:settle()
	page:advance(0.1)
	save("toast", page, "Ran: deleted api-2")
end)

test("narrow", function()
	local page = open({ width = 700, height = 700 })
	page:press("f4")
	rest(page)
	save("narrow", page, "Again, with nobody to ask")
end)
