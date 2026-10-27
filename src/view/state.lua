-- What the page holds, and what it does: the rows are the program's (it reads them, filters and sorts
-- them, and keeps the marks), and the page holds what a person sees and where they are: the query
-- they typed, the cursor, the rows in sight, what is open. Every key, click and command ends up in
-- the actions here, so that the keyboard and the mouse do the same.
--
-- A row is named two ways: its place in the input (`id`, from 0, the program's), and its place among
-- the rows shown (`index`, from 1). The program says which rows are at which places, a window at a
-- time; the page keeps the windows it was given until the rows shown are put in another order.

local L = require("./lib")
local json = pencere.json

local S = {
	boot = nil, -- how the command line set the view up, once the program has said
	error = nil, -- the program could not be reached, or said something the page cannot go on from
	width = 1000,
	height = 640,
	now = 0,
	-- What the program last said of the rows (its `table` topic, and the answers to what changes them).
	sum = nil,
	-- Moves when the rows shown are put in another order or are other rows: the windows are thrown away.
	layout = -1,
	marks_rev = 0,
	query = "",
	terms = {},
	unknown = {},
	order = nil, -- { column =, descending = }, columns from 1
	cursor = nil, -- the index of the row the cursor is on
	cursor_id = nil, -- and its id, once a window has said it
	anchor = nil, -- the id a ⇧-click or ⇧↑ ⇧↓ marks from
	anchor_on = true, -- whether the anchor's row was marked when it became the anchor
	follow = false, -- the cursor keeps to the last row as rows come, as `tail -f` does
	unseen = 0, -- rows that came below while the list was not following
	reveal = false, -- the cursor's row is to be scrolled into sight
	relocate = false, -- the rows were put in another order: where is the cursor's row now?
	-- The windows of rows the program gave: index -> { id =, cells =, marked =, rev = }.
	rows = {},
	widths = {}, -- the columns the person resized: column -> points
	hidden = {}, -- column -> true
	fields = nil, -- the columns that go out, as the person picked them; nil keeps the command line's
	panel = { open = false, tab = "output" },
	panel_width = 360,
	column = 1, -- the column the column panel shows
	overlay = nil, -- "palette" or "help"
	palette = { text = "", chosen = 1 },
	menu = nil, -- what the entries of the menu that is up do
	sending = false,
	escape_asked = -100,
	toast = nil, -- { text =, tone =, until_ = }
	-- What the panel shows, as the program last said it: the column, what goes out, the preview.
	facet = nil,
	facet_key = nil,
	output = nil,
	output_key = nil,
	preview = nil,
	preview_key = nil,
	-- Timers: a thing asked for once the person has rested a moment, by name -> { at =, run = }.
	timers = {},
	-- What the reply to the event the page is answering says besides drawing again.
	out = {},
}

-- ---- talking to the program ----------------------------------------------------------------------

local A = {}

-- A list that is a list in JSON even when it is empty.
local function list(items)
	return setmetatable(items or {}, json.array)
end
A.list = list

-- The reply to the event or the message being answered: drawn again, with what the actions said.
function A.reply()
	local out = S.out
	S.out = {}
	out.redraw = true
	return out
end

-- The keyboard goes back to what the person types in (the palette's field while it is up).
function A.keep_keyboard()
	if S.overlay == "palette" then
		S.out.keyboard = { field = "palette" }
	elseif S.overlay == nil then
		S.out.keyboard = { field = "query" }
	end
end

-- Asks the program; `done(result)` is called with what it answered, and an error is said in a toast
-- (or by `failed(err)`).
local function ask(method, params, done, failed)
	return pencere.call(method, params or {}, function(result, err)
		if err then
			if failed then
				failed(err)
			else
				A.toast(err.message or err.code or "The program could not do that", "bad")
			end
		elseif done then
			done(result)
		end
		return A.reply()
	end)
end
A.ask = ask

-- Something to do once nothing has changed it for `delay` seconds (a preview while the cursor runs
-- through the rows is asked for once it rests).
function A.later(name, delay, run)
	S.timers[name] = { at = S.now + delay, run = run }
end

-- When the next thing asked for later is due, or nil: what is set going while the page is built
-- (a preview, what goes out) wakes the page then, so that it is not left until the next key.
function A.next_due()
	local next_at = nil
	for _, timer in pairs(S.timers) do
		next_at = next_at and math.min(next_at, timer.at) or timer.at
	end
	return next_at
end

-- Runs what is due; the time of the next one, for the page to be drawn again then.
function A.tick()
	local next_at = nil
	for name, timer in pairs(S.timers) do
		if timer.at <= S.now then
			S.timers[name] = nil
			timer.run()
		else
			next_at = next_at and math.min(next_at, timer.at) or timer.at
		end
	end
	return next_at
end

-- ---- toasts ----------------------------------------------------------------------------------------

function A.toast(text, tone)
	tone = tone or "info"
	S.toast = { text = text, tone = tone, until_ = S.now + (tone == "bad" and 5 or 2.2) }
end

-- ---- what the program says of the rows ---------------------------------------------------------------

-- How many rows are shown, and the most the cursor can be on.
function A.shown()
	return S.sum and S.sum.shown or 0
end

-- The program's word on the rows: how many there are, are shown and are marked, the columns, and
-- whether the rows shown are the ones the page holds windows of.
function A.take(sum, from_top)
	local old = S.sum
	S.sum = sum
	if sum.layout ~= S.layout then
		S.layout = sum.layout
		S.rows = {}
		if from_top then
			S.cursor = sum.shown > 0 and 1 or nil
			S.cursor_id = nil
			S.follow, S.unseen, S.relocate = false, 0, false
			L.scroll_to("rows", 0)
		elseif S.cursor_id ~= nil then
			-- Rows taken into their places as they come: the cursor stays on its row, wherever it went.
			S.relocate = true
		end
	elseif old and sum.shown > old.shown then
		local added = sum.shown - old.shown
		if S.follow then
			S.cursor = sum.shown
			S.cursor_id = nil
			S.reveal = true
		else
			S.unseen += added
		end
	end
	if from_top and sum.layout == S.layout and S.cursor ~= 1 then
		S.cursor = sum.shown > 0 and 1 or nil
		S.cursor_id = nil
		S.follow, S.unseen = false, 0
		L.scroll_to("rows", 0)
	end
	if S.cursor == nil and sum.shown > 0 then
		S.cursor = 1
	elseif S.cursor ~= nil and S.cursor > sum.shown then
		S.cursor = sum.shown > 0 and sum.shown or nil
		S.cursor_id = nil
	end
	if sum.marks ~= S.marks_rev then
		S.marks_rev = sum.marks
	end
	if sum.terms then
		S.terms, S.unknown = sum.terms, sum.unknown or {}
	end
	if sum.query ~= nil and sum.query ~= S.query then
		-- The program wrote into the query (a click on a value, a drag across the chart).
		S.query = sum.query
		S.out.fill = { query = sum.query }
	end
	-- The panel asks again for what it shows of rows that changed.
	if S.facet and (sum.layout ~= (old and old.layout) or sum.total ~= (old and old.total)) then
		S.facet_key = nil
	end
end

-- ---- the windows of rows ---------------------------------------------------------------------------------

local OVERSCAN = 80
local asking = nil -- the window asked for and not yet given: { from =, to =, layout = }

-- The rows `first` to `last` (indexes) are wanted: asks for those it does not hold, with some
-- around them, one window at a time.
function A.need(first, last)
	local shown = A.shown()
	if shown == 0 or asking then
		return
	end
	first, last = math.max(first, 1), math.min(last, shown)
	local missing = S.relocate
	for index = first, last do
		local row = S.rows[index]
		if row == nil or row.rev ~= S.marks_rev then
			missing = true
			break
		end
	end
	if not missing then
		return
	end
	local from = math.max(first - OVERSCAN, 1)
	local to = math.min(last + OVERSCAN, shown)
	asking = { from = from, to = to }
	local params = { from = from - 1, count = to - from + 1 }
	if S.relocate and S.cursor_id ~= nil then
		params.cursor = S.cursor_id
	end
	ask("window", params, function(result)
		asking = nil
		if result.layout < S.layout then
			return
		end
		if result.layout > S.layout then
			S.layout = result.layout
			S.rows = {}
		end
		for at, row in ipairs(result.rows) do
			S.rows[result.from + at] = { id = row.id, cells = row.cells, marked = row.marked, rev = result.marks }
		end
		if params.cursor ~= nil then
			S.relocate = false
			if result.cursor_index ~= nil and result.cursor_index >= 0 then
				S.cursor = result.cursor_index + 1
			else
				S.cursor = A.shown() > 0 and 1 or nil
				S.cursor_id = nil
			end
			S.reveal = true
		end
	end, function()
		asking = nil
	end)
end

-- The row at an index, when a window has it.
function A.row(index)
	return index and S.rows[index]
end

-- The id of the row the cursor is on, when it is known.
function A.cursor_id()
	local row = A.row(S.cursor)
	if row then
		S.cursor_id = row.id
	end
	return S.cursor_id
end

-- ---- the query and the order ---------------------------------------------------------------------------------

-- What the person typed: the program filters, one query at a time; what was typed while one was out
-- is sent when it is back.
local querying, query_waiting = false, false

local function send_query()
	querying = true
	query_waiting = false
	local sent = S.query
	ask("query", { query = sent }, function(sum)
		querying = false
		-- The query is the person's: what they typed since is not written over by what was sent.
		sum.query = nil
		A.take(sum, true)
		if query_waiting then
			send_query()
		end
	end, function(err)
		querying = false
		A.toast(err.message or "The query could not be run", "bad")
	end)
end

function A.set_query(text, fill)
	if text == S.query and not fill then
		return
	end
	S.query = text
	if fill then
		S.out.fill = { query = text }
	end
	if querying then
		query_waiting = true
	else
		send_query()
	end
end

-- The program writes a term into the query (a value clicked, a range dragged): `term` is what to ask.
function A.term(params)
	ask("term", params, function(sum)
		A.take(sum, true)
	end)
	A.keep_keyboard()
end

-- Plain words looked for letter by letter, best matches first (`--fuzzy`), or as they are typed.
function A.set_fuzzy(on)
	ask("fuzzy", { on = on }, function(sum)
		sum.query = nil
		A.take(sum, true)
		A.toast(on and "Fuzzy words: their letters in order, best first" or "Words as they are typed")
	end)
end

function A.set_order(order)
	S.order = order
	if order then
		S.column = order.column
	end
	ask("order", order and { column = order.column - 1, descending = order.descending } or {}, function(sum)
		sum.query = nil
		A.take(sum, true)
	end)
end

-- A heading's click: up, then down, then the input's order again.
function A.cycle_order(column)
	local order = S.order
	if order == nil or order.column ~= column then
		A.set_order({ column = column, descending = false })
	elseif not order.descending then
		A.set_order({ column = column, descending = true })
	else
		A.set_order(nil)
	end
end

-- ---- the cursor -----------------------------------------------------------------------------------------------

local page_rows = 10

function A.set_page_rows(rows)
	page_rows = math.max(rows, 1)
end

function A.move_to(index)
	local shown = A.shown()
	if shown == 0 then
		return
	end
	S.cursor = math.clamp(index, 1, shown)
	S.cursor_id = nil
	S.follow = false
	S.reveal = true
end

function A.move(delta)
	A.move_to((S.cursor or 0) + delta)
end

function A.page(direction)
	A.move(direction * math.max(1, page_rows - 1))
end

function A.first()
	A.move_to(1)
end

function A.last()
	A.move_to(A.shown())
	S.follow, S.unseen = true, 0
end

function A.set_cursor(index)
	S.cursor = index
	S.cursor_id = nil
	S.follow = false
end

-- ---- marks --------------------------------------------------------------------------------------------------------

-- The program's answer to a change of the marks: its counts, and the windows to be asked for again.
local function marked(sum)
	A.take(sum, false)
end

-- Marks or unmarks the rows of these ids; the rows in sight change at once.
function A.set_marked(ids, on)
	local set = {}
	for _, id in ipairs(ids) do
		set[id] = true
	end
	for _, row in pairs(S.rows) do
		if set[row.id] then
			row.marked = on
		end
	end
	if S.sum then
		-- The counts move at once too; the program's answer puts them right.
		for _, id in ipairs(ids) do
			S.sum.marked += on and 1 or -1
		end
		S.sum.marked = math.max(S.sum.marked, 0)
	end
	ask("mark", { ids = list(ids), on = on }, marked)
end

function A.is_marked(index)
	local row = A.row(index)
	return row ~= nil and row.marked
end

function A.toggle(index)
	local row = A.row(index)
	if row == nil then
		return
	end
	local on = not row.marked
	A.set_marked({ row.id }, on)
	S.anchor, S.anchor_on = row.id, on
end

-- Tab: marks (or unmarks) the row and steps on, as fzf does.
function A.mark_and_move(delta)
	if S.cursor == nil then
		return
	end
	A.toggle(S.cursor)
	A.move(delta)
end

-- ⇧↑ ⇧↓ and ⇧-click: every row from the anchor to here takes the anchor's mark.
function A.extend_to(index)
	local row = A.row(index)
	if row == nil then
		return
	end
	local on = true
	if S.anchor ~= nil then
		on = S.anchor_on or S.anchor == row.id
	end
	local from = S.anchor or row.id
	-- The rows in sight between the two change at once; the program marks the run.
	local anchor_index = nil
	for at, held in pairs(S.rows) do
		if held.id == from then
			anchor_index = at
		end
	end
	if anchor_index then
		local low, high = math.min(anchor_index, index), math.max(anchor_index, index)
		for at = low, high do
			if S.rows[at] then
				S.rows[at].marked = on
			end
		end
	end
	ask("mark_range", { from = from, to = row.id, on = on }, marked)
	if S.anchor == nil then
		S.anchor, S.anchor_on = row.id, on
	end
	S.cursor = index
	S.cursor_id = row.id
	S.follow = false
	S.reveal = true
end

function A.extend(delta)
	if S.cursor == nil then
		return
	end
	local row = A.row(S.cursor)
	if row == nil then
		return
	end
	if S.anchor == nil or not S.anchor_on then
		S.anchor, S.anchor_on = row.id, true
		if not row.marked then
			A.set_marked({ row.id }, true)
		end
	end
	local next_index = math.clamp(S.cursor + delta, 1, A.shown())
	A.extend_to(next_index)
end

local function bulk(method, params)
	for _, row in pairs(S.rows) do
		row.rev = -1
	end
	ask(method, params or {}, marked)
end

function A.mark_shown(on)
	if on == nil then
		on = true
	end
	for _, row in pairs(S.rows) do
		row.marked = on
	end
	bulk("mark_shown", { on = on })
end

function A.unmark_all()
	for _, row in pairs(S.rows) do
		row.marked = false
	end
	S.anchor = nil
	bulk("unmark_all")
end

function A.invert()
	for _, row in pairs(S.rows) do
		row.marked = not row.marked
	end
	bulk("invert")
end

-- Marks every row whose column is this value (of the rows the facet counts, with `facet`).
function A.mark_value(column, id, facet)
	ask("mark_value", { column = column - 1, id = id, facet = facet == true }, function(result)
		marked(result.summary)
		for _, row in pairs(S.rows) do
			row.rev = -1
		end
		A.toast("Marked " .. L.plural(result.count, "row"))
	end)
end

-- ---- what goes out ------------------------------------------------------------------------------------------

-- How many rows Send would send: the marked ones, or the cursor's row.
function A.to_send()
	local sum = S.sum
	if sum and sum.marked > 0 then
		return sum.marked
	end
	if (S.boot and S.boot.confirm) or S.cursor == nil then
		return 0
	end
	return 1
end

local function fields_param(params)
	if S.fields ~= nil then
		params.fields = list(S.fields)
	end
	return params
end

-- Sends the rows chosen: the program writes them once the view has closed. `key` is the `--expect`
-- key that sent them, which the program writes ahead of them (none for Enter).
function A.send(id, key)
	if S.sending or A.still_executing() then
		return
	end
	local params = { key = key }
	if id ~= nil then
		params.ids = list({ id })
	elseif S.sum and S.sum.marked > 0 then
		params.marked = true
	else
		if (S.boot and S.boot.confirm) or A.cursor_id() == nil then
			return
		end
		params.ids = list({ A.cursor_id() })
	end
	S.sending = true
	S.overlay = nil
	ask("choose", fields_param(params), function()
		S.out.close = true
	end, function(err)
		S.sending = false
		A.toast(err.message or "The rows could not be sent", "bad")
	end)
end

-- The rows read again from `--reload`'s command: the program lets the ones there were go.
function A.reload()
	ask("reload", {}, function(sum)
		sum.query = nil
		A.take(sum, true)
	end)
end

-- `--execute` for the cursor's row (`{+}` in it the marked rows): the view stays and says how it
-- ended, and with `--reload` the rows are read again after it.
function A.execute()
	local id = A.cursor_id()
	if id == nil or S.executing then
		return
	end
	S.executing = true
	A.toast("Running " .. L.cut(S.boot.execute, 60))
	ask("execute", { id = id }, function(result)
		S.executing = false
		local status = result.status ~= json.null and result.status or nil
		local words = status == 0 and "Ran"
			or status == nil and "Ended by a signal"
			or ("Ended with status " .. tostring(status))
		if type(result.said) == "string" then
			words = words .. ": " .. result.said
		end
		A.toast(words, status == 0 and "info" or "bad")
		if S.boot.reload then
			A.reload()
		end
	end, function(err)
		S.executing = false
		A.toast(err.message or "The command did not run", "bad")
	end)
end

-- Whether `--execute` is still running, which the view waits for before it ends (⌃C does not):
-- what the person set going is let finish, and they see how it ended.
function A.still_executing()
	if S.executing then
		A.toast("Waiting for the command to end: " .. L.cut(S.boot.execute, 60))
	end
	return S.executing == true
end

-- Sends nothing, and ends.
function A.cancel()
	if S.sending or A.still_executing() then
		return
	end
	S.sending = true
	S.overlay = nil
	ask("cancel", {}, function()
		S.out.close = true
	end, function()
		-- A program that cannot be told is left by closing the view: that sends nothing too.
		S.out.close = true
	end)
end

-- Esc, one step at a time toward sending nothing: what is open, then the query, then nothing.
function A.back()
	if S.overlay ~= nil then
		S.overlay = nil
		A.keep_keyboard()
		return
	end
	if S.query ~= "" then
		A.set_query("", true)
		return
	end
	local marks = S.sum and S.sum.marked or 0
	if marks > 0 and S.now - S.escape_asked > 2.5 then
		S.escape_asked = S.now
		A.toast("Esc again to send nothing — " .. L.count(marks) .. " marked rows would be dropped")
		return
	end
	A.cancel()
end

-- The columns that go out: the person's pick, or the command line's `--field`.
function A.sent_fields()
	if S.fields ~= nil then
		return S.fields
	end
	return (S.boot and S.boot.given.field) or {}
end

function A.toggle_field(name)
	local current = A.sent_fields()
	local next_fields, had = {}, false
	for _, field in ipairs(current) do
		if string.lower(field) == string.lower(name) then
			had = true
		else
			next_fields[#next_fields + 1] = field
		end
	end
	if not had then
		next_fields[#next_fields + 1] = name
	end
	S.fields = next_fields
	S.output_key = nil
end

function A.reset_fields()
	S.fields = nil
	S.output_key = nil
end

-- What goes out and the command line that does it again, asked for again when what they depend on
-- has changed and the person has rested a moment.
function A.want_output()
	local key = table.concat({
		tostring(S.marks_rev),
		tostring(S.layout),
		tostring(A.cursor_id()),
		S.query,
		tostring(S.sum and S.sum.total),
		S.fields and table.concat(S.fields, ",") or "-",
	}, "\0")
	if key == S.output_key then
		return
	end
	S.output_key = key
	A.later("output", 0.12, function()
		local params = { cursor = A.cursor_id() }
		ask("output", fields_param(params), function(result)
			S.output = result
		end, function(err)
			S.output = { text = "", error = err.message or "The output could not be drawn" }
		end)
	end)
end

function A.copy(text, what)
	S.out.copy = text
	A.toast("Copied " .. what)
end

function A.copy_row(id)
	id = id or A.cursor_id()
	if id == nil then
		return
	end
	ask("copy_row", { id = id }, function(result)
		A.copy(result.text, "the row")
	end)
end

function A.copy_command()
	ask("output", fields_param({ cursor = A.cursor_id() }), function(result)
		A.copy(result.again.line, "the command")
	end)
end

-- ---- the panel ----------------------------------------------------------------------------------------------------

function A.open_tab(tab)
	local open = not (S.panel.open and S.panel.tab == tab)
	S.panel = { open = open, tab = tab }
end

function A.toggle_panel()
	S.panel = { open = not S.panel.open, tab = S.panel.tab }
end

function A.show_column(column)
	S.column = column
	S.panel = { open = true, tab = "column" }
	S.facet_key = nil
end

-- The column panel's counts and chart, asked for again when the query, the rows or the column moved.
function A.want_facet()
	local column = math.clamp(S.column, 1, math.max(#(S.sum and S.sum.columns or {}), 1))
	local key = table.concat({ tostring(column), S.query, tostring(S.layout), tostring(S.sum and S.sum.total) }, "\0")
	if key == S.facet_key then
		return
	end
	S.facet_key = key
	A.later("facet", 0.05, function()
		ask("column", { column = column - 1 }, function(result)
			S.facet = result
		end)
	end)
end

-- The preview of the cursor's row, asked for once the cursor rests; the last one asked is given up.
local previewing = nil

function A.want_preview(width_chars)
	local id = A.cursor_id()
	if id == nil then
		return
	end
	local key = tostring(id) .. ":" .. tostring(width_chars)
	-- A command with the query or the marked rows in it is run again when they change.
	local template = S.boot and S.boot.preview or ""
	if string.find(template, "{q}", 1, true) then
		key = key .. "\0" .. S.query
	end
	if string.find(template, "{+", 1, true) then
		key = key .. "\0" .. tostring(S.marks_rev)
	end
	if key == S.preview_key then
		return
	end
	S.preview_key = key
	S.preview_waiting = true
	A.later("preview", 0.12, function()
		if previewing then
			pencere.cancel(previewing)
		end
		previewing = ask("preview", { id = id, width = width_chars }, function(result)
			previewing = nil
			S.preview = result
			S.preview_waiting = false
		end, function(err)
			previewing = nil
			S.preview = { text = err.message or "The preview did not run", status = json.null }
			S.preview_waiting = false
		end)
	end)
end

return { S = S, A = A }
