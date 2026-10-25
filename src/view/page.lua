-- pickpen's page: the rows of a pipeline, a query above them, boxes to mark, and what goes out.
--
-- It is a page of the kit, which the terminal draws in its own font and colours: every colour is a
-- role of the theme, and nothing here is a picture. It holds only the rows in sight; the program
-- (src/program/api/) has the table, filters it, orders it and keeps the marks, and the page asks
-- it for the few rows on the screen, by their place in the list it is showing (`gen` says which
-- list). What the page says to the program and hears from it is described there.
--
-- A page is one script, with no `require`, so this file is long and sectioned:
--   1. numbers and small helpers          6. the side panel
--   2. what the page holds                7. the screen
--   3. what is asked of the program       8. commands and keys
--   4. the cursor and the marks           9. the pointer and the keyboard
--   5. text with colour codes            10. the page
--
-- The keyboard has two places. At the start it is in the terminal's text field (the query: what
-- is typed filters). The field gives the keys ⏎ ↓ Tab and Esc back to the page, which then
-- reads the keys itself; `/` takes the keyboard back to the field.

local b = pencere
local div, text = b.div, b.text
local alpha = b.alpha

-- ---- 1. numbers and small helpers -------------------------------------------------------------

local TEXT = 13
local SMALL = 11.5
local ROW = 24
local HEAD = 26
-- A character of the terminal's face, in points, for the width of a column (a guess: the face is
-- the terminal's and the page is not told its width; a cell is cut at its column's edge).
local CHAR = 7.8
local BOX = 32
local MIN_COLUMN = 40
local PANEL_MIN_PAGE = 640
-- The most rows the page keeps, and how many more than the ones in sight it asks for.
local KEPT = 2500
local AROUND = 30
local LIST = "list"
local PANEL_LINES = 400
local READ_LIMIT = 200000

local function clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

local function count_text(n)
	local digits = tostring(math.floor(n))
	local out = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end

local function plural(n, one, many)
	return count_text(n) .. " " .. (n == 1 and one or many)
end

local function lower(value)
	return string.lower(value)
end

-- ---- 2. what the page holds -------------------------------------------------------------------

local ui = b.Ui.new()

local S = {
	-- What the program said at the start: the command line's, and the list.
	boot = nil,
	sum = nil,
	failure = nil,
	now = 0,
	size = { w = 800, h = 480 },
	-- The query: what is typed in the terminal's field, and the terms the mouse wrote.
	typed = "",
	chips = {},
	query_due = nil,
	query_seq = 0,
	-- Whether the keyboard is thought to be in the field.
	typing = false,
	-- The rows in sight, by place in the list; and the places asked for and not yet answered.
	cache = {},
	cached = 0,
	asked = {},
	cursor = 1,
	anchor = nil,
	follow = false,
	unseen = 0,
	-- Column widths the person set, in points, by column.
	widths = {},
	fields = nil,
	panel = { open = false, tab = "output" },
	column = 1,
	overlay = nil,
	palette = { filter = "", at = 1 },
	toast = nil,
	sending = false,
	escape_asked = -100,
	-- What the side panel shows.
	detail = nil,
	detail_due = nil,
	out = nil,
	out_due = nil,
	stats = nil,
	stats_for = nil,
	-- Gestures in progress.
	drag = nil,
	resize = nil,
	chart = nil,
	pointer = nil,
	menu = nil,
	pending_reply = nil,
	last_click = nil,
	press_mods = {},
}

local function toast(words, bad)
	S.toast = { words = words, bad = bad == true, over = S.now + (bad and 6 or 2.5) }
	return true
end

local function shown()
	return S.sum and S.sum.shown or 0
end

local function names()
	return S.sum and S.sum.columns or {}
end

-- ---- 3. what is asked of the program ----------------------------------------------------------

local send_query
local reset_list
local take_summary

-- Asks, and takes the answer: `done(result)` gives the reply (true when the page changed). An error
-- is said in words; `stale` (a place in a list that is gone) asks for the list again.
local function ask(method, params, done)
	return b.call(method, params, function(result, err)
		if err then
			if err.code == "stale" then
				send_query()
				return false
			end
			S.sending = false
			return toast(err.message or err.code or "it failed", true)
		end
		if done then
			return done(result)
		end
		return true
	end)
end

function reset_list(top)
	S.cache, S.cached, S.asked = {}, 0, {}
	S.detail, S.out, S.stats, S.stats_for = nil, nil, nil, nil
	if top then
		S.cursor, S.anchor, S.follow, S.unseen = 1, nil, false, 0
		ui:set_scroll(LIST, 0)
	end
end

-- The list as the program says it is. `fresh`: it answers what this page asked, and the cursor
-- goes to the top; otherwise it is a change of the program's own (rows came in, an order was
-- made again).
function take_summary(sum, fresh)
	local old = S.sum
	S.sum = sum
	if old == nil or sum.gen ~= old.gen then
		reset_list(fresh or old == nil)
	elseif sum.shown > old.shown then
		if S.follow then
			S.cursor = sum.shown
		else
			S.unseen += sum.shown - old.shown
		end
	end
	S.cursor = clamp(S.cursor, 1, math.max(sum.shown, 1))
	S.detail_due = S.now
	S.out_due = S.now
end

local function chip_sources()
	local sources = {}
	for _, chip in ipairs(S.chips) do
		sources[#sources + 1] = chip.source
	end
	return sources
end

function send_query()
	S.query_due = nil
	S.query_seq += 1
	local seq = S.query_seq
	ask("query", { typed = S.typed, chips = chip_sources() }, function(result)
		if result.superseded or seq ~= S.query_seq then
			return false
		end
		take_summary(result.summary, true)
		return true
	end)
end

-- The query changed: the program is asked, a moment after the last key when there are many rows.
local function query_changed()
	if S.sum and S.sum.total > 20000 then
		S.query_due = S.now + 0.06
	else
		send_query()
	end
end

-- The mouse writes a term of the query for a column (nil takes the column's term out): it stays
-- where it can be read and taken out, beside what is typed.
local function set_chip(column, term)
	local kept = {}
	for _, chip in ipairs(S.chips) do
		if chip.column ~= column then
			kept[#kept + 1] = chip
		end
	end
	if term ~= nil then
		kept[#kept + 1] = { column = column, source = term }
	end
	S.chips = kept
	send_query()
end

-- Asks for the rows around the ones in sight that the page does not have.
local function ensure(first, last)
	first, last = math.max(first, 1), math.min(last, shown())
	local at = first
	while at <= last do
		if S.cache[at] or S.asked[at] then
			at += 1
		else
			local to = at
			while to + 1 <= last and not S.cache[to + 1] and not S.asked[to + 1] and to - at < 99 do
				to += 1
			end
			local from, count, gen = at, to - at + 1, S.sum.gen
			for place = from, to do
				S.asked[place] = true
			end
			b.call("window", { gen = gen, from = from, count = count }, function(result, err)
				for place = from, to do
					S.asked[place] = nil
				end
				if err or result.stale or result.gen ~= S.sum.gen then
					return false
				end
				if S.cached > KEPT then
					S.cache, S.cached = {}, 0
				end
				for index, row in ipairs(result.rows) do
					S.cache[result.from + index - 1] = row
					S.cached += 1
				end
				return true
			end)
			at = to + 1
		end
	end
end

-- ---- 4. the cursor and the marks --------------------------------------------------------------

local function list_height()
	local bounds = b.layout.bounds(LIST)
	if bounds then
		return bounds.h
	end
	return math.max(S.size.h - 170, ROW * 3)
end

local function page_rows()
	return math.max(1, math.floor(list_height() / ROW))
end

-- Scrolls the least that shows the cursor's row.
local function reveal()
	local offset = ui:scroll_offset(LIST)
	local view = list_height()
	local top, bottom = (S.cursor - 1) * ROW, S.cursor * ROW
	if top < offset then
		ui:set_scroll(LIST, top)
	elseif bottom > offset + view then
		ui:set_scroll(LIST, bottom - view)
	end
end

local function move_to(place)
	if shown() == 0 then
		return true
	end
	S.cursor = clamp(place, 1, shown())
	S.follow = false
	S.detail_due = S.now + 0.1
	reveal()
	return true
end

local function move(delta)
	return move_to(S.cursor + delta)
end

local function go_last()
	move_to(shown())
	S.follow = true
	S.unseen = 0
	return true
end

local function marked_at(place)
	local row = S.cache[place]
	return row ~= nil and row.marked == true
end

-- What the program says of the marks after a call that changed them.
local function took_marks(result)
	S.sum.marked, S.sum.hidden = result.marked, result.hidden
	S.out_due = S.now
	return true
end

-- Marks (or unmarks) the places `from` to `to` of the list.
local function mark_range(from, to, on)
	from, to = math.min(from, to), math.max(from, to)
	from, to = math.max(from, 1), math.min(to, shown())
	for place = from, to do
		local row = S.cache[place]
		if row then
			row.marked = on or nil
		end
	end
	ask("mark", { gen = S.sum.gen, op = "range", from = from, to = to, on = on }, took_marks)
	return true
end

local function mark_all(on)
	for _, row in pairs(S.cache) do
		row.marked = on or nil
	end
	ask("mark", { gen = S.sum.gen, op = "all", on = on }, took_marks)
	return true
end

local function unmark_everything()
	for _, row in pairs(S.cache) do
		row.marked = nil
	end
	S.anchor = nil
	ask("mark", { gen = S.sum.gen, op = "none" }, took_marks)
	return true
end

local function invert()
	for _, row in pairs(S.cache) do
		row.marked = (not row.marked) or nil
	end
	ask("mark", { gen = S.sum.gen, op = "invert" }, took_marks)
	return true
end

local function toggle(place)
	S.anchor = place
	return mark_range(place, place, not marked_at(place))
end

-- Tab: marks (or unmarks) the row and steps on, as fzf does.
local function mark_and_move(delta)
	if shown() == 0 then
		return true
	end
	toggle(S.cursor)
	return move(delta)
end

local function extend_to(place)
	local anchor = S.anchor or place
	local on = S.anchor == nil or S.anchor == place or S.cache[anchor] == nil or marked_at(anchor)
	mark_range(anchor, place, on)
	if S.anchor == nil then
		S.anchor = place
	end
	S.cursor = place
	S.follow = false
	reveal()
	return true
end

-- ⇧↑ ⇧↓ and ⇧-click: every row from the anchor to here takes the anchor's mark.
local function extend(delta)
	if shown() == 0 then
		return true
	end
	if S.anchor == nil or not marked_at(S.anchor) then
		S.anchor = S.cursor
		mark_range(S.cursor, S.cursor, true)
	end
	return extend_to(clamp(S.cursor + delta, 1, shown()))
end

-- ---- 5. text with colour codes ----------------------------------------------------------------

local BASIC = { "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" }

-- A colour of the 256 of xterm, as the page says colours: the theme's own sixteen, and values for
-- the rest.
local function xterm(n)
	if n < 8 then
		return BASIC[n + 1]
	elseif n < 16 then
		return "bright-" .. BASIC[n - 7]
	elseif n < 232 then
		local m = n - 16
		local function level(v)
			return v == 0 and 0 or 55 + v * 40
		end
		return string.format("#%02x%02x%02x", level(m // 36), level((m // 6) % 6), level(m % 6))
	end
	local v = 8 + (n - 232) * 10
	return string.format("#%02x%02x%02x", v, v, v)
end

-- Text with colour codes as lines of pieces `{ text, color, bold, dim }`. Other codes are dropped.
local function ansi_lines(source, most)
	local lines, line = {}, {}
	local color, bold, dim = nil, false, false
	local function piece(words)
		if words ~= "" then
			line[#line + 1] = { words, color, bold, dim }
		end
	end
	local function sgr(parameters)
		local codes = {}
		for number in string.gmatch(parameters .. ";", "(%d*);") do
			codes[#codes + 1] = tonumber(number) or 0
		end
		local at = 1
		while at <= #codes do
			local code = codes[at]
			if code == 0 then
				color, bold, dim = nil, false, false
			elseif code == 1 then
				bold = true
			elseif code == 2 then
				dim = true
			elseif code == 22 then
				bold, dim = false, false
			elseif code >= 30 and code <= 37 then
				color = xterm(code - 30)
			elseif code >= 90 and code <= 97 then
				color = xterm(code - 90 + 8)
			elseif code == 39 then
				color = nil
			elseif code == 38 and codes[at + 1] == 5 and codes[at + 2] then
				color = xterm(clamp(codes[at + 2], 0, 255))
				at += 2
			elseif code == 38 and codes[at + 1] == 2 and codes[at + 4] then
				local r, g, bl = codes[at + 2], codes[at + 3], codes[at + 4]
				color = string.format(
					"#%02x%02x%02x",
					clamp(r, 0, 255),
					clamp(g, 0, 255),
					clamp(bl, 0, 255)
				)
				at += 4
			end
			at += 1
		end
	end
	local at, length = 1, #source
	while at <= length do
		local first = string.find(source, "[\27\n\r]", at)
		if not first then
			piece(string.sub(source, at))
			break
		end
		piece(string.sub(source, at, first - 1))
		local c = string.sub(source, first, first)
		if c == "\n" then
			lines[#lines + 1] = line
			line = {}
			if #lines >= most then
				return lines, true
			end
			at = first + 1
		elseif c == "\r" then
			at = first + 1
		else
			local pattern = "^(%[([0-?]*)[ -/]*([@-~]))"
			local whole, parameters, final = string.match(source, pattern, first + 1)
			if whole then
				if final == "m" then
					sgr(parameters)
				end
				at = first + 1 + #whole
			else
				at = first + 2
			end
		end
	end
	if #line > 0 then
		lines[#lines + 1] = line
	end
	return lines, false
end

local function plain_lines(source, most)
	local lines, count = {}, 0
	for line in string.gmatch(source, "([^\n]*)\n?") do
		count += 1
		lines[count] = { { line, nil, false, false } }
		if count >= most then
			return lines, true
		end
	end
	return lines, false
end

-- ---- 6. the side panel ------------------------------------------------------------------------

local function button(id, label, hint, kind)
	local primary = kind == "primary"
	local disabled = kind == "disabled"
	local ground = primary and "accent" or (ui.hover == id and "raised3" or "raised2")
	if disabled then
		ground = "raised1"
	end
	local ink = primary and "background" or (disabled and "quiet" or "foreground")
	local el = div():press(id):row():items_center():gap(6):px(10):py(3):rounded(6):no_shrink()
		:bg(ground)
		:child(text(label):color(ink):weight(primary and 650 or 500))
	if hint then
		el:child(text(hint):text_size(SMALL):color(primary and "background" or "dim"))
	end
	return el
end

local function tab_button(id, label, tab)
	local on = S.panel.open and S.panel.tab == tab
	local ground = on and "raised3" or (ui.hover == id and "raised2" or nil)
	return div():press(id):px(10):py(3):rounded(6):no_shrink():bg(ground)
		:child(text(label):color(on and "foreground" or "dim"):weight(on and 650 or 500))
end

local function section(title)
	return text(title):text_size(SMALL):color("quiet"):mt(10):mb(2)
end

local function pair_line(name, value)
	return div():row():gap(8):h(ROW - 4):items_center():no_shrink()
		:child(div():w(110):no_shrink():child(text(name):color("dim"):truncate()))
		:child(div():grow(1):min_w(0):child(text(value):truncate()))
end

local function fill_lines(el, lines, cut)
	for _, line in ipairs(lines) do
		local row = div():row():h(ROW - 6):items_center():no_shrink()
		for _, p in ipairs(line) do
			local piece = text(p[1]):no_shrink():color(p[2] or (p[4] and "dim" or "foreground"))
			if p[3] then
				piece = piece:weight(700)
			end
			row:child(piece)
		end
		el:child(row)
	end
	if cut then
		el:child(text("… more lines are not shown"):color("quiet"):text_size(SMALL))
	end
	return el
end

local function row_panel()
	local body = div():col():no_shrink():px(12):py(8)
	if shown() == 0 then
		return body:child(text("No row is under the cursor."):color("dim"))
	end
	local d = S.detail
	if S.boot.preview then
		body:child(section("Preview"))
		if d == nil or d.waiting then
			return body:child(text("Running…"):color("dim"))
		end
		local lines, cut = ansi_lines(d.text or "", PANEL_LINES)
		fill_lines(body, lines, cut or d.cut)
		if d.timed_out then
			body:child(text("It took too long and was ended."):color("warning"))
		elseif d.status ~= nil and d.status ~= 0 then
			body:child(text("It ended with status " .. d.status):color("dim"):text_size(SMALL))
		end
		return body
	end
	if d == nil or d.cells == nil then
		return body:child(text("…"):color("dim"))
	end
	body:child(section("Row " .. count_text(S.cursor)))
	for index, name in ipairs(names()) do
		body:child(pair_line(name, d.cells[index] or ""))
	end
	return body
end

local function chart_of(st)
	local highest = 1
	for _, bucket in ipairs(st.buckets) do
		highest = math.max(highest, bucket.count)
	end
	local from, to = nil, nil
	if S.chart then
		from, to = math.min(S.chart.from, S.chart.to), math.max(S.chart.from, S.chart.to)
	end
	local chart = div():row():items_end():h(64):no_shrink():gap(1)
	for index, bucket in ipairs(st.buckets) do
		local picked = from ~= nil and index >= from and index <= to
		local height = math.max(2, math.floor(60 * bucket.count / highest))
		chart:child(div():press("bar:" .. index):grow(1):min_w(0):h(64):col():justify_end()
			:child(div():h(height):rounded(1):bg(picked and "warning" or "accent")))
	end
	return chart
end

local function column_panel()
	local body = div():col():no_shrink():px(12):py(8)
	local list = names()
	if #list == 0 then
		return body:child(text("No columns yet."):color("dim"))
	end
	S.column = clamp(S.column, 1, #list)
	body:child(div():row():items_center():gap(6):no_shrink()
		:child(button("col-prev", "‹", nil))
		:child(div():grow(1):min_w(0):child(text(list[S.column]):weight(650):truncate()))
		:child(button("col-next", "›", nil)))
	local st = S.stats
	if st == nil or st.column ~= S.column then
		return body:child(text("…"):color("dim"):mt(8))
	end
	body:child(text(string.format("%s · %s filled · %s empty · %s different",
		st.kind, count_text(st.filled), count_text(st.empty), count_text(st.distinct)))
		:text_size(SMALL):color("dim"):mt(4))
	if st.buckets then
		body:child(section("Chart: drag across the bars to keep a range"))
		body:child(chart_of(st))
		body:child(div():row():justify_between():no_shrink()
			:child(text(st.edges[1]):text_size(SMALL):color("dim"))
			:child(text(st.edges[#st.edges]):text_size(SMALL):color("dim")))
	end
	body:child(section("Values: click to keep the rows with one, ⌘-click to leave them out"))
	for index, entry in ipairs(st.top) do
		local id = "value:" .. index
		local words = entry.value == "" and "(empty)" or entry.value
		body:child(div():press(id):row():gap(8):items_center():h(ROW - 2):px(4):rounded(4)
			:no_shrink():bg(ui.hover == id and "raised2" or nil)
			:child(div():grow(1):min_w(0):child(text(words):truncate()))
			:child(text(count_text(entry.count)):color("dim")))
	end
	if st.more then
		body:child(text("and more values"):text_size(SMALL):color("quiet"))
	end
	return body
end

local function field_chips(body)
	local list = names()
	if #list == 0 then
		return
	end
	body:child(section("Columns that go out"))
	local picked = S.fields or S.boot.given.field or {}
	local wrap = div():row():wrap():gap(4):no_shrink()
	for index, name in ipairs(list) do
		local on = false
		for _, field in ipairs(picked) do
			if lower(field) == lower(name) then
				on = true
			end
		end
		local id = "field:" .. index
		local ground = on and "accent" or (ui.hover == id and "raised3" or "raised2")
		wrap:child(div():press(id):px(8):py(2):rounded(10):no_shrink():bg(ground)
			:child(text((on and "✓ " or "") .. name):text_size(SMALL)
				:color(on and "background" or "foreground")))
	end
	body:child(wrap)
	if S.fields ~= nil then
		body:child(div():row():mt(6):no_shrink()
			:child(button("fields-reset", "Use the command line's columns", nil)))
	end
end

local function output_panel()
	local body = div():col():no_shrink():px(12):py(8)
	local out = S.out
	if out == nil then
		return body:child(text("…"):color("dim"))
	end
	body:child(section("What Send will write"))
	if out.problem then
		body:child(text(out.problem):color("error"))
	elseif out.count == 0 then
		local words = S.boot.confirm and "Nothing is marked: nothing would go out."
			or "No row to send."
		body:child(text(words):color("dim"))
	else
		local lines, cut = plain_lines(out.text or "", PANEL_LINES)
		fill_lines(body, lines, cut or out.truncated)
		body:child(text(plural(out.count, "row", "rows") .. " would go out.")
			:text_size(SMALL):color("dim"))
	end
	local again = out.again
	if again then
		body:child(section("And in a script, with nobody to ask"))
		body:child(text(again.line):color("foreground"))
		local words
		if again.kind == "same" then
			words = "This chooses the " .. plural(again.rows, "row", "rows") .. " marked."
		elseif again.kind == "different" then
			words = string.format("This would choose %s; %d are marked, and no query names them.",
				plural(again.rows, "row", "rows"), again.chosen)
		else
			words = "Mark the rows to see whether a query chooses them."
		end
		body:child(text(words):text_size(SMALL):color("dim"))
		body:child(div():row():mt(6):no_shrink()
			:child(button("copy-line", "Copy command line", nil)))
	end
	field_chips(body)
	return body
end

local function panel(width, full)
	local content
	if S.panel.tab == "row" then
		content = row_panel()
	elseif S.panel.tab == "column" then
		content = column_panel()
	else
		content = output_panel()
	end
	local head = div():row():items_center():gap(2):px(8):py(6):no_shrink()
		:child(tab_button("tab-row", "Row", "row"))
		:child(tab_button("tab-column", "Column", "column"))
		:child(tab_button("tab-output", "Output", "output"))
		:child(div():grow(1))
		:child(button("panel-close", "Close panel", "⌘I"))
	local el = div():col():min_h(0):bg("raised1")
	if full then
		el:grow(1)
	else
		el:w(width):no_shrink():border(1, alpha("border", 0.7))
	end
	local scroll = ui:scroll_offset("panel-body")
	return el:child(head)
		:child(div():col():id("panel-body"):scroll_y(scroll):grow(1):min_h(0):child(content))
end

-- ---- 7. the screen ----------------------------------------------------------------------------

-- The width of column `index` in points: what the person set, or what the first rows said.
local function column_width(index)
	if S.widths[index] then
		return S.widths[index]
	end
	local chars = S.sum.widths[index] or 12
	return chars * CHAR + 16
end

local function sort_arrow(index)
	local order = S.sum.order
	if order and order.column == index then
		return order.descending and " ▼" or " ▲"
	end
	return ""
end

local function right_aligned(index)
	local kind = S.sum.kinds[index]
	return kind ~= nil and kind ~= "text"
end

local function head_row()
	local row = div():row():items_center():h(HEAD):no_shrink():bg("raised1")
	row:child(div():w(BOX):no_shrink())
	for index, name in ipairs(names()) do
		local id = "head:" .. index
		local edge = "edge:" .. index
		local label = text(name .. sort_arrow(index)):weight(650):truncate()
		if right_aligned(index) then
			label = label:align("end")
		end
		local cell = div():press(id):grow(1):min_w(0):h(HEAD):px(6):row():items_center()
			:bg(ui.hover == id and "raised3" or nil)
			:child(div():grow(1):min_w(0):child(label))
		local handle = div():press(edge):w(6):h(HEAD):no_shrink()
			:bg(alpha("border", ui.hover == edge and 1 or 0.4))
		row:child(div():row():items_center():h(HEAD):w(column_width(index)):min_w(0)
			:child(cell):child(handle))
	end
	return row
end

local function data_row(place, record)
	local chosen = place == S.cursor
	local marked = record ~= nil and record.marked == true
	local ground = nil
	if chosen then
		ground = "selection"
	elseif marked then
		ground = alpha("accent", 0.14)
	elseif ui.hover == "row:" .. place then
		ground = "raised1"
	end
	local row = div():row():items_center():h(ROW):no_shrink():press("row:" .. place):bg(ground)
	row:child(div():row():justify_center():items_center():w(BOX):h(ROW):no_shrink()
		:press("box:" .. place)
		:child(text(marked and "☑" or "☐"):color(marked and "accent" or "dim")))
	if record == nil then
		return row:child(text("…"):color("quiet"))
	end
	for index = 1, #names() do
		local words = text(record.cells[index] or ""):truncate()
		if right_aligned(index) then
			words = words:align("end")
		end
		row:child(div():w(column_width(index)):min_w(0):px(6):child(words))
	end
	return row
end

local function list_area()
	local total = shown()
	local offset = ui:scroll_offset(LIST)
	local view = list_height()
	local first = math.max(math.floor(offset / ROW) + 1 - AROUND, 1)
	local last = math.min(math.floor((offset + view) / ROW) + 1 + AROUND, total)
	local body = div():col():id(LIST):grow(1):min_h(0):scroll_y(offset)
	if total == 0 then
		local words
		if not S.sum.done then
			words = "Waiting for rows…"
		elseif S.sum.total == 0 then
			words = "There are no rows to choose from."
		else
			words = "No row matches the query."
		end
		return body:child(div():p(16):child(text(words):color("dim")))
	end
	ensure(first, last)
	body:child(div():h((first - 1) * ROW):no_shrink())
	for place = first, last do
		body:child(data_row(place, S.cache[place]))
	end
	body:child(div():h((total - last) * ROW):no_shrink())
	return body
end

local function chips_row()
	local sum = S.sum
	if #sum.terms == 0 and #sum.unknown == 0 then
		return nil
	end
	local row = div():row():wrap():gap(6):px(12):pb(6):no_shrink():items_center()
	for index, term in ipairs(sum.terms) do
		local chip = div():row():items_center():gap(6):px(10):py(2):rounded(10):no_shrink()
			:bg("raised2"):child(text(term.label):text_size(SMALL))
		if term.chip then
			local id = "chip:" .. index
			chip:child(div():press(id):px(3):rounded(8):bg(ui.hover == id and "raised4" or nil)
				:child(text("✕"):text_size(SMALL):color("dim")))
		else
			chip:child(text("typed"):text_size(10):color("quiet"))
		end
		row:child(chip)
	end
	for _, name in ipairs(sum.unknown) do
		row:child(text("“" .. name .. "” is no column: looked for as a word")
			:text_size(SMALL):color("warning"))
	end
	return row
end

local function query_row(show_field)
	local sum = S.sum
	local count
	if sum.total == 0 and not sum.done then
		count = "reading…"
	elseif sum.shown == sum.total then
		count = plural(sum.total, "row", "rows")
	else
		count = count_text(sum.shown) .. " of " .. plural(sum.total, "row", "rows")
	end
	if not sum.done and sum.total > 0 then
		count = count .. " so far"
	end
	local box = div():press("query"):grow(1):min_w(0):h(28):row():items_center():px(8):rounded(6)
		:bg("raised1"):border(1, S.typing and "accent" or alpha("border", 0.8))
	if show_field then
		box:child(div():id("query-field"):text_field():grow(1):h(18):min_w(0))
	end
	return div():row():items_center():gap(10):px(12):py(8):no_shrink()
		:child(text("›"):color("accent"):weight(700))
		:child(box)
		:child(text(count):color("dim"):no_shrink())
end

local function status_row()
	local sum = S.sum
	local row = div():row():items_center():gap(14):px(12):h(24):no_shrink()
	if sum.marked > 0 then
		local words = "☑ " .. plural(sum.marked, "row", "rows") .. " marked"
		if sum.hidden > 0 then
			words = words .. " (" .. count_text(sum.hidden) .. " hidden by the query)"
		end
		row:child(text(words):color("accent"))
	elseif shown() > 0 then
		row:child(text(string.format("row %s of %s", count_text(S.cursor), count_text(shown())))
			:color("dim"))
	end
	if S.unseen > 0 then
		row:child(button("go-new", "Go to " .. plural(S.unseen, "new row", "new rows"), "⌘↓"))
	end
	if sum.capped then
		row:child(text("Reading stopped at " .. count_text(READ_LIMIT) .. " rows.")
			:color("warning"))
	end
	if sum.cut then
		row:child(text("Some cells were cut."):color("warning"))
	end
	for _, problem in ipairs(sum.problems) do
		row:child(text(problem):color("warning"):truncate())
	end
	return row
end

local function footer()
	local sum = S.sum
	local sendable = sum.marked > 0 or (not S.boot.confirm and shown() > 0)
	return div():row():items_center():gap(8):px(12):py(6):no_shrink():wrap()
		:child(button("send", "Send", "⏎", sendable and "primary" or "disabled"))
		:child(button("mark", "Mark", "⇥"))
		:child(button("mark-all", "Mark all", "⌘A"))
		:child(button("unmark", "Unmark all", "⇧⌘A"))
		:child(button("palette", "Commands", "⌘K"))
		:child(button("help", "Keys", "?"))
		:child(div():grow(1))
		:child(button("cancel", "Send nothing", "Esc"))
end

local function banner()
	if S.boot.confirm and S.boot.where then
		local marked = plural(S.sum.marked, "row", "rows")
		local words = "Rule “" .. S.boot.where .. "” marked " .. marked
			.. ". Look, unmark what should stay, then Send."
		return div():row():gap(8):px(12):py(4):no_shrink():bg(alpha("warning", 0.16))
			:child(text(words):text_size(SMALL))
	end
	return nil
end

local function title_row()
	if S.boot.title and S.boot.title ~= "" then
		return div():px(12):pt(8):no_shrink():child(text(S.boot.title):weight(650):truncate())
	end
	return nil
end

-- ---- 8. commands and keys ---------------------------------------------------------------------

local function send()
	if S.sending then
		return true
	end
	if S.sum.marked == 0 and (S.boot.confirm or shown() == 0) then
		if S.boot.confirm then
			return toast("Mark the rows to send first.")
		end
		return toast("There is no row to send.")
	end
	S.sending = true
	-- The program ends the view when it has taken the answer; a refusal comes back as an error,
	-- which gives the page back to the person.
	ask("choose", { gen = S.sum.gen, cursor = S.cursor, fields = S.fields })
	return true
end

local function cancel()
	if S.sending then
		return true
	end
	S.sending = true
	ask("cancel", {})
	return true
end

-- Esc, one step at a time toward sending nothing: what is open, the terms the mouse wrote, then
-- nothing (asked twice when rows are marked).
local function back()
	if S.overlay then
		S.overlay = nil
		return true
	end
	if #S.chips > 0 then
		S.chips = {}
		send_query()
		return true
	end
	if S.sum.marked > 0 and S.now - S.escape_asked > 2.5 then
		S.escape_asked = S.now
		return toast(string.format("Esc again to send nothing — %s marked would be dropped",
			plural(S.sum.marked, "row", "rows")))
	end
	return cancel()
end

local function open_panel(tab)
	if S.panel.open and S.panel.tab == tab then
		S.panel.open = false
	else
		S.panel = { open = true, tab = tab }
	end
	S.detail_due, S.out_due, S.stats_for = S.now, S.now, nil
	return true
end

-- A column's order: up, then down, then the input's (or `clear`: the input's at once).
local function order_by(index, clear)
	local column, descending = index, false
	local order = S.sum.order
	if clear then
		column = nil
	elseif order and order.column == index then
		if order.descending then
			column = nil
		else
			descending = true
		end
	end
	ask("order", { column = column, descending = descending }, function(result)
		if result.superseded then
			return false
		end
		take_summary(result.summary, true)
		return true
	end)
	return true
end

local function copy_row()
	if shown() == 0 then
		return true
	end
	ask("row", { gen = S.sum.gen, pos = S.cursor }, function(result)
		toast("Copied the row")
		return { redraw = true, copy = table.concat(result.cells, "\t") }
	end)
	return true
end

local function copy_text(words, what)
	toast("Copied " .. what)
	return { redraw = true, copy = words }
end

local function go_typing()
	S.typing = true
	return { redraw = true, keyboard = "field" }
end

local function open_palette()
	S.overlay = { kind = "palette" }
	S.palette = { filter = "", at = 1 }
	return true
end

local function open_help()
	S.overlay = { kind = "help" }
	return true
end

-- Every command: the keyboard runs them, the palette lists them, and the help shows them, from this
-- one list. A key is written `shift+mod+a`: ⌘ is `mod`.
local COMMANDS = {
	{ id = "down", title = "Next row", group = "Move", keys = { "down", "j" }, quiet = true,
		run = function() return move(1) end },
	{ id = "up", title = "Previous row", group = "Move", keys = { "up", "k" }, quiet = true,
		run = function() return move(-1) end },
	{ id = "page-down", title = "A page down", group = "Move", keys = { "page_down" }, quiet = true,
		run = function() return move(page_rows() - 1) end },
	{ id = "page-up", title = "A page up", group = "Move", keys = { "page_up" }, quiet = true,
		run = function() return move(-(page_rows() - 1)) end },
	{ id = "first", title = "First row", group = "Move", also = "top home beginning",
		keys = { "mod+up", "home" }, run = function() return move_to(1) end },
	{ id = "last", title = "Last row, and follow new rows", group = "Move",
		also = "bottom end tail follow", keys = { "mod+down", "end" }, run = go_last },
	{ id = "query", title = "Type in the query", group = "Move", also = "filter search",
		keys = { "/" }, run = go_typing },

	{ id = "mark", title = "Mark the row and go to the next", group = "Mark",
		keys = { "tab", "space" }, run = function() return mark_and_move(1) end },
	{ id = "mark-up", title = "Mark the row and go to the previous", group = "Mark",
		keys = { "shift+tab" }, quiet = true, run = function() return mark_and_move(-1) end },
	{ id = "extend-down", title = "Mark down from here", group = "Mark", keys = { "shift+down" },
		quiet = true, run = function() return extend(1) end },
	{ id = "extend-up", title = "Mark up from here", group = "Mark", keys = { "shift+up" },
		quiet = true, run = function() return extend(-1) end },
	{ id = "mark-shown", title = "Mark every row shown", group = "Mark",
		also = "select all check", keys = { "mod+a" }, run = function() return mark_all(true) end },
	{ id = "unmark", title = "Unmark every row", group = "Mark",
		also = "deselect clear none uncheck", keys = { "shift+mod+a" }, run = unmark_everything },
	{ id = "invert", title = "Invert the marks of the rows shown", group = "Mark",
		also = "select toggle reverse", run = invert },
	{ id = "unmark-shown", title = "Unmark the rows shown", group = "Mark",
		also = "deselect uncheck", run = function() return mark_all(false) end },

	{ id = "send", title = "Send", group = "Send", also = "choose accept ok done submit enter",
		keys = { "enter" }, run = send },
	{ id = "back", title = "Back: close, clear the terms, then send nothing", group = "Send",
		also = "escape clear", keys = { "escape" }, run = back },
	{ id = "cancel", title = "Send nothing and end", group = "Send",
		also = "quit exit abort close nothing", run = cancel },

	{ id = "order-clear", title = "Rows in the input's order", group = "Order",
		also = "sort unsorted original", keys = { "ctrl+0" },
		run = function() return order_by(nil, true) end },

	{ id = "palette", title = "Commands", group = "Panels", keys = { "mod+k" },
		run = open_palette },
	{ id = "help", title = "Keys, the mouse and the query", group = "Panels",
		also = "shortcuts keyboard syntax", keys = { "?", "mod+/" }, run = open_help },
	{ id = "panel", title = "Show or hide the side panel", group = "Panels", keys = { "mod+i" },
		run = function()
			S.panel.open = not S.panel.open
			S.detail_due, S.out_due = S.now, S.now
			return true
		end },
	{ id = "panel-row", title = "Panel: the row", group = "Panels", also = "preview",
		keys = { "r" }, run = function() return open_panel("row") end },
	{ id = "panel-column", title = "Panel: a column's values", group = "Panels", also = "chart",
		keys = { "c" }, run = function() return open_panel("column") end },
	{ id = "panel-output", title = "Panel: what goes out", group = "Panels",
		also = "again command line", keys = { "o" },
		run = function() return open_panel("output") end },

	{ id = "copy-row", title = "Copy the row", group = "Copy", keys = { "mod+c" }, run = copy_row },
}

-- Order by the first nine columns: ⌃1 to ⌃9.
for number = 1, 9 do
	COMMANDS[#COMMANDS + 1] = {
		id = "order-" .. number,
		title = "Order by column " .. number,
		group = "Order",
		also = "sort",
		keys = { "ctrl+" .. number },
		quiet = true,
		when = function()
			return number <= #names()
		end,
		run = function()
			return order_by(number)
		end,
	}
end

local KEY_OF = {}
for _, command in ipairs(COMMANDS) do
	for _, key in ipairs(command.keys or {}) do
		KEY_OF[key] = command
	end
end

-- A key event as `shift+mod+ctrl+name`, the way the commands write their keys.
local function key_name(event)
	local mods = event.mods or {}
	if mods.alt then
		-- ⌥ and a letter is how a Mac types @ # [ {: no command is on it.
		return nil
	end
	local name, shift = event.key, mods.shift == true
	if name == " " then
		name = "space"
	elseif utf8.len(name) == 1 then
		local low = lower(name)
		if low ~= name then
			name, shift = low, true
		elseif not string.match(name, "%a") then
			-- A symbol: ⇧ is part of it (`?` is a `/` with ⇧).
			shift = false
		end
	end
	local parts = {}
	if shift then
		parts[#parts + 1] = "shift"
	end
	if mods.command then
		parts[#parts + 1] = "mod"
	end
	if mods.control then
		parts[#parts + 1] = "ctrl"
	end
	parts[#parts + 1] = name
	return table.concat(parts, "+")
end

local LABELS = {
	{ "shift%+", "⇧" }, { "mod%+", "⌘" }, { "ctrl%+", "⌃" }, { "page_up", "PgUp" },
	{ "page_down", "PgDn" }, { "^up$", "↑" }, { "^down$", "↓" }, { "up$", "↑" },
	{ "down$", "↓" }, { "enter", "⏎" }, { "escape", "Esc" }, { "tab", "⇥" },
	{ "space", "Space" }, { "home", "Home" }, { "end", "End" },
}

local function key_label(key)
	for _, pair in ipairs(LABELS) do
		key = string.gsub(key, pair[1], pair[2])
	end
	return key
end

local function available(command)
	return command.when == nil or command.when()
end

-- ---- the palette, the help, the menus ---------------------------------------------------------

local function palette_items()
	local needle = lower(S.palette.filter)
	local items = {}
	for _, command in ipairs(COMMANDS) do
		if not command.quiet and available(command) then
			local hay = lower(command.title .. " " .. (command.also or "") .. " " .. command.group)
			if needle == "" or string.find(hay, needle, 1, true) then
				items[#items + 1] = command
			end
		end
	end
	return items
end

local function keys_text(command)
	local keys = {}
	for _, key in ipairs(command.keys or {}) do
		keys[#keys + 1] = key_label(key)
	end
	return table.concat(keys, "  ")
end

local function overlay_palette()
	local items = palette_items()
	S.palette.at = clamp(S.palette.at, 1, math.max(#items, 1))
	local list = div():col():gap(1):no_shrink()
	for index, command in ipairs(items) do
		local id = "command:" .. index
		local ground = ui.hover == id and "raised3" or nil
		if index == S.palette.at then
			ground = "selection"
		end
		list:child(div():press(id):row():items_center():gap(10):h(ROW):px(10):rounded(4):no_shrink()
			:bg(ground)
			:child(div():grow(1):min_w(0):child(text(command.title):truncate()))
			:child(text(keys_text(command)):color("dim"):text_size(SMALL):no_shrink()))
	end
	if #items == 0 then
		list:child(text("No command is called that."):color("dim"):px(10))
	end
	local filter = S.palette.filter
	local height = math.min(#items * (ROW + 1) + 4, math.max(S.size.h - 220, ROW * 3))
	return div():col():w(math.min(480, S.size.w - 40)):p(10):gap(8):rounded(10):bg("raised2")
		:border(1, "border"):shadow(0, 8, 24, "shadow")
		:child(div():row():gap(8):px(10):h(28):items_center():rounded(6):bg("raised1")
			:child(text("›"):color("accent"))
			:child(text(filter == "" and "type to narrow" or filter)
				:color(filter == "" and "quiet" or "foreground")))
		:child(text("← deletes · ↑↓ choose · ⏎ run · Esc clears, then closes")
			:text_size(10.5):color("quiet"):px(10))
		:child(div():col():id("palette-list"):h(height):scroll_y(ui:scroll_offset("palette-list"))
			:child(list))
end

local HELP_MOUSE = {
	{ "Click", "put the cursor on the row" },
	{ "Click the box, or drag down the boxes", "mark, or unmark, the rows" },
	{ "⌘-click, ⇧-click", "mark one row; every row from the last one marked" },
	{ "Double-click", "send the row, when nothing is marked" },
	{ "Right-click", "what can be done with the row, its cell, or a heading" },
	{ "Click a heading", "order by it: up, down, then as it came" },
	{ "Drag a heading's edge", "make the column wider or narrower" },
	{ "Click a value in the column panel",
		"keep only the rows with it (⌘-click: leave them out)" },
	{ "Drag across the chart", "keep only the rows in that range" },
}

local HELP_QUERY = {
	{ "word", "the row holds it, in any column, in any case" },
	{ "!word", "it does not" },
	{ "\"two words\"", "quotes keep spaces in a word or a value" },
	{ "STATUS=Running", "the column is that; =a|b either" },
	{ "STATUS!=Running", "it is not" },
	{ "NAME~web  NAME!~web", "it holds web, or does not" },
	{ "cpu>50  size>=1G  age<2h", "quantities compare as quantities" },
	{ "latency=100..400", "between, both ends included" },
}

local function two_columns(el, pairs_, left)
	for _, line in ipairs(pairs_) do
		el:child(div():row():gap(10):h(ROW - 4):no_shrink()
			:child(div():w(left):no_shrink():child(text(line[1]):color("accent"):truncate()))
			:child(div():grow(1):min_w(0):child(text(line[2]):truncate())))
	end
end

local function help_body()
	local el = div():col():no_shrink()
	el:child(text("The keyboard"):weight(700):mt(6))
	el:child(text("The query has the keyboard at the start: what you type filters."):color("dim"))
	el:child(text("⏎ ↓ ⇥ or Esc leave it for the rows, and / brings you back."):color("dim"))
	local last = nil
	local keyed = {}
	for _, command in ipairs(COMMANDS) do
		local numbered = string.match(command.id, "^order%-(%d)$")
		if command.keys and available(command) and (numbered == nil or numbered == "1") then
			if command.group ~= last then
				last = command.group
				keyed[#keyed + 1] = { group = command.group }
			end
			local title = numbered and "Order by a column: ⌃1 to ⌃9" or command.title
			local keys = numbered and "⌃1–⌃9" or keys_text(command)
			keyed[#keyed + 1] = { keys, title }
		end
	end
	for _, line in ipairs(keyed) do
		if line.group then
			el:child(text(line.group):text_size(SMALL):color("quiet"):mt(6))
		else
			two_columns(el, { line }, 150)
		end
	end
	el:child(text("The mouse"):weight(700):mt(10))
	two_columns(el, HELP_MOUSE, 250)
	el:child(text("The query"):weight(700):mt(10))
	two_columns(el, HELP_QUERY, 250)
	el:child(text("A column is named as its heading is, or by its letters alone (cpu for %CPU).")
		:text_size(SMALL):color("dim"):mt(4))
	return el
end

local function overlay_help()
	local height = math.max(S.size.h - 140, ROW * 4)
	return div():col():w(math.min(660, S.size.w - 40)):p(14):gap(6):rounded(10):bg("raised2")
		:border(1, "border"):shadow(0, 8, 24, "shadow")
		:child(div():row():items_center():no_shrink()
			:child(div():grow(1):child(text("Keys, the mouse and the query"):weight(700)))
			:child(button("overlay-close", "Close", "Esc")))
		:child(div():col():id("help-body"):h(height):scroll_y(ui:scroll_offset("help-body"))
			:child(help_body()))
end

-- The right-click menu of a cell or a heading: the entries (a table with a title and what it does,
-- or "-" for a line), remembered in the order the terminal will number them.
local function open_menu(at, entries)
	S.menu = {}
	local list = {}
	for _, entry in ipairs(entries) do
		if entry == "-" then
			list[#list + 1] = "-"
		else
			local enabled = entry.enabled ~= false
			list[#list + 1] = { title = entry.title, key = entry.key, enabled = enabled }
			S.menu[#S.menu + 1] = entry.run
		end
	end
	return { at = at, entries = list }
end

local function keep_term(column, value, negate)
	ask("term", { column = column, value = value, negate = negate }, function(result)
		set_chip(column, result.term)
		return true
	end)
end

local function show_column(column)
	S.column, S.panel, S.stats_for = column, { open = true, tab = "column" }, nil
end

local function send_only(name)
	S.fields = { name }
	S.out_due = S.now
	toast("Send writes only " .. name)
end

local function cell_menu(place, column, at)
	local name = names()[column] or ""
	local row = S.cache[place]
	local value = row and row.cells[column] or ""
	local short = #value > 24 and (string.sub(value, 1, 24) .. "…") or value
	S.cursor = place
	return open_menu(at, {
		{ title = "Only rows where " .. name .. " is " .. short,
			run = function() keep_term(column, value, false) end },
		{ title = "Rows where " .. name .. " is not " .. short,
			run = function() keep_term(column, value, true) end },
		"-",
		{ title = marked_at(place) and "Unmark the row" or "Mark the row",
			run = function() toggle(place) end },
		{ title = "Copy the cell",
			run = function() S.pending_reply = copy_text(value, "the cell") end },
		{ title = "Copy the row", run = copy_row },
		"-",
		{ title = "Show " .. name .. "'s values", run = function() show_column(column) end },
		{ title = "Send only " .. name, run = function() send_only(name) end },
	})
end

local function head_menu(column, at)
	local name = names()[column] or ""
	return open_menu(at, {
		{ title = "Order by " .. name, run = function() order_by(column) end },
		{ title = "Show " .. name .. "'s values", run = function() show_column(column) end },
		"-",
		{ title = "Send only " .. name, run = function() send_only(name) end },
		{ title = "Send the command line's columns", enabled = S.fields ~= nil,
			run = function() S.fields = nil; S.out_due = S.now end },
	})
end

-- ---- 9. the pointer and the keyboard ----------------------------------------------------------

local function cursor_shape()
	if ui.hover == "query" then
		return "text"
	elseif ui.hover ~= nil then
		return "pointer"
	end
	return "arrow"
end

local function reply(redraw, extra)
	local r = { redraw = redraw == true, cursor = cursor_shape() }
	if type(extra) == "table" then
		for key, value in pairs(extra) do
			r[key] = value
		end
	end
	return r
end

-- What a command gave: true or false, a reply table, or nothing (the page changed).
local function merged(result)
	if type(result) == "table" then
		result.cursor = result.cursor or cursor_shape()
		return result
	end
	return reply(result ~= false)
end

-- An id like `row:12` as its kind and its number.
local function place_of(id)
	if type(id) ~= "string" then
		return nil, nil
	end
	local kind, number = string.match(id, "^(%a+):(%d+)$")
	return kind, tonumber(number)
end

-- The pointer moved with a gesture on: a drag down the boxes, along a heading's edge, or across
-- the chart. Whether the page changed.
local function drag_over(at)
	if S.resize then
		S.widths[S.resize.column] = clamp(S.resize.width + (at.x - S.resize.x), MIN_COLUMN, 2000)
		return true
	end
	local kind, number = place_of(b.layout.hit(at))
	if S.drag and (kind == "box" or kind == "row") and number and number ~= S.drag.last then
		S.drag.last = number
		mark_range(S.drag.from, number, S.drag.on)
		S.cursor = number
		return true
	end
	if S.chart and kind == "bar" and number then
		S.chart.to = number
		return true
	end
	return false
end

-- Which column the pointer is over in a row, by where it is across it.
local function column_at(place, x)
	local bounds = b.layout.bounds("row:" .. place)
	if not bounds then
		return nil
	end
	local left = bounds.x + BOX
	for index = 1, #names() do
		local width = column_width(index)
		if x >= left and x < left + width then
			return index
		end
		left += width
	end
	return nil
end

local function press(event)
	local at = { x = event.x, y = event.y }
	S.pointer = at
	S.press_mods = event.mods or {}
	S.menu = nil
	local id = ui:press(b.layout, at)
	if id == nil then
		return reply(false)
	end
	if id == "query" then
		return merged(go_typing())
	end
	local kind, number = place_of(id)
	if event.button == "right" then
		if (kind == "row" or kind == "box") and number then
			local column = column_at(number, at.x)
			if column then
				return reply(true, { menu = cell_menu(number, column, at) })
			end
			S.cursor = number
			return reply(true)
		elseif kind == "head" and number then
			return reply(false, { menu = head_menu(number, at) })
		end
		return reply(false)
	end
	if kind == "box" and number then
		local on = not marked_at(number)
		S.drag = { from = number, on = on, last = number }
		S.cursor, S.anchor = number, number
		mark_range(number, number, on)
		return reply(true)
	elseif kind == "edge" and number then
		S.resize = { column = number, x = at.x, width = column_width(number) }
		return reply(false)
	elseif kind == "bar" and number then
		S.chart = { from = number, to = number }
		return reply(true)
	end
	return reply(false)
end

local function value_term(index, negate)
	local entry = S.stats and S.stats.top[index]
	if entry == nil then
		return true
	end
	set_chip(S.column, negate and entry.not_term or entry.term)
	return true
end

local function toggle_field(number)
	local name = names()[number]
	local current = S.fields or S.boot.given.field or {}
	local kept, found = {}, false
	for _, field in ipairs(current) do
		if lower(field) == lower(name) then
			found = true
		else
			kept[#kept + 1] = field
		end
	end
	if not found then
		kept[#kept + 1] = name
	end
	S.fields = kept
	S.out_due = S.now
	return true
end

local function remove_chip(number)
	local term = S.sum.terms[number]
	if term and term.chip then
		for index, chip in ipairs(S.chips) do
			if chip.source == term.source then
				table.remove(S.chips, index)
				break
			end
		end
		send_query()
	end
	return true
end

-- Buttons that do one thing, by their ids.
local BUTTONS = {
	send = send,
	cancel = cancel,
	mark = function() return mark_and_move(1) end,
	["mark-all"] = function() return mark_all(true) end,
	unmark = unmark_everything,
	palette = open_palette,
	help = open_help,
	["overlay-close"] = function() S.overlay = nil; return true end,
	["panel-close"] = function() S.panel.open = false; return true end,
	["tab-row"] = function() return open_panel("row") end,
	["tab-column"] = function() return open_panel("column") end,
	["tab-output"] = function() return open_panel("output") end,
	["col-prev"] = function()
		S.column, S.stats_for = clamp(S.column - 1, 1, #names()), nil
		return true
	end,
	["col-next"] = function()
		S.column, S.stats_for = clamp(S.column + 1, 1, #names()), nil
		return true
	end,
	["go-new"] = go_last,
	["fields-reset"] = function() S.fields = nil; S.out_due = S.now; return true end,
	["copy-line"] = function()
		if S.out and S.out.again then
			return copy_text(S.out.again.line, "the command line")
		end
		return false
	end,
}

-- A click on a row or its box: the cursor goes there; with ⌘ it marks, with ⇧ it marks a run,
-- and a second click at once sends the row when nothing is marked.
local function click_row(kind, number, mods)
	if mods.shift then
		return reply(extend_to(number))
	elseif mods.command then
		S.cursor = number
		return reply(toggle(number))
	end
	local before = S.last_click
	S.last_click = { number, S.now }
	S.cursor, S.follow, S.detail_due = number, false, S.now
	if kind == "row" and before and before[1] == number and S.now - before[2] < 0.4
		and S.sum.marked == 0 and not S.boot.confirm then
		return reply(send())
	end
	return reply(true)
end

local function release(event)
	local at = { x = event.x, y = event.y }
	local was_drag, was_resize, chart = S.drag, S.resize, S.chart
	S.drag, S.resize, S.chart = nil, nil, nil
	local id = ui:release(b.layout, at)
	local mods = S.press_mods or {}
	if was_resize or was_drag then
		return reply(true)
	end
	if chart then
		local st = S.stats
		if st and st.edges then
			local low, high = math.min(chart.from, chart.to), math.max(chart.from, chart.to)
			set_chip(S.column, st.name .. "=" .. st.edges[low] .. ".." .. st.edges[high + 1])
		end
		return reply(true)
	end
	if id == nil then
		return reply(false)
	end
	if BUTTONS[id] then
		return merged(BUTTONS[id]())
	end
	local kind, number = place_of(id)
	if number == nil then
		return reply(false)
	elseif kind == "head" then
		return reply(order_by(number))
	elseif kind == "chip" then
		return reply(remove_chip(number))
	elseif kind == "value" then
		return reply(value_term(number, mods.command == true))
	elseif kind == "field" then
		return reply(toggle_field(number))
	elseif kind == "command" then
		local command = palette_items()[number]
		S.overlay = nil
		if command then
			return merged(command.run())
		end
		return reply(true)
	elseif kind == "row" or kind == "box" then
		return click_row(kind, number, mods)
	end
	return reply(false)
end

-- A key while the palette or the help is up.
local function overlay_key(event)
	local key = event.key
	if S.overlay.kind == "help" then
		if key == "escape" or key == "?" or key == "enter" then
			S.overlay = nil
			return reply(true)
		end
		return reply(false)
	end
	local items = palette_items()
	if key == "escape" then
		if S.palette.filter ~= "" then
			S.palette.filter = ""
		else
			S.overlay = nil
		end
	elseif key == "down" then
		S.palette.at = clamp(S.palette.at + 1, 1, math.max(#items, 1))
	elseif key == "up" then
		S.palette.at = clamp(S.palette.at - 1, 1, math.max(#items, 1))
	elseif key == "left" then
		local filter = string.sub(S.palette.filter, 1, math.max(#S.palette.filter - 1, 0))
		while #filter > 0 and utf8.len(filter) == nil do
			filter = string.sub(filter, 1, #filter - 1)
		end
		S.palette.filter, S.palette.at = filter, 1
	elseif key == "enter" then
		local command = items[S.palette.at]
		S.overlay = nil
		if command then
			return merged(command.run())
		end
	elseif utf8.len(key) == 1 and not (event.mods.command or event.mods.control) then
		S.palette.filter, S.palette.at = S.palette.filter .. key, 1
	else
		return reply(false)
	end
	return reply(true)
end

local function key(event)
	S.typing = false
	if S.sending then
		return reply(false)
	end
	if S.overlay then
		return overlay_key(event)
	end
	local name = key_name(event)
	local command = name and KEY_OF[name]
	if command and available(command) then
		return merged(command.run())
	end
	return reply(false)
end

local function menu_pick(event)
	local run = S.menu and S.menu[event.index]
	S.menu = nil
	if run == nil then
		return reply(false)
	end
	run()
	local pending = S.pending_reply
	S.pending_reply = nil
	return merged(pending or true)
end

-- ---- 10. the page -----------------------------------------------------------------------------

-- What the side panel needs, asked for when it is stale: the row or its preview, the column's
-- values, what goes out.
local function refresh_panel()
	if not S.panel.open or S.sum == nil then
		return
	end
	local tab, gen = S.panel.tab, S.sum.gen
	if tab == "row" and S.detail_due and S.now >= S.detail_due and shown() > 0 then
		S.detail_due = nil
		local place = S.cursor
		if S.boot.preview then
			S.detail = { waiting = true }
			b.call("preview", { gen = gen, pos = place, width = 120 }, function(result, err)
				if err or S.cursor ~= place or S.sum.gen ~= gen then
					return false
				end
				S.detail = {
					text = result.text,
					status = result.status,
					cut = result.cut,
					timed_out = result.timed_out,
				}
				return true
			end)
		else
			b.call("row", { gen = gen, pos = place }, function(result, err)
				if err or S.cursor ~= place then
					return false
				end
				S.detail = { cells = result.cells }
				return true
			end)
		end
	elseif tab == "column" and S.stats_for ~= S.column + gen * 1000 then
		S.stats_for = S.column + gen * 1000
		local column = S.column
		b.call("column", { gen = gen, column = column }, function(result, err)
			if err or S.column ~= column or S.sum.gen ~= gen then
				return false
			end
			S.stats = result
			return true
		end)
	elseif tab == "output" and S.out_due and S.now >= S.out_due then
		S.out_due = nil
		b.call("output", { gen = gen, cursor = S.cursor, fields = S.fields }, function(result, err)
			if err or S.sum.gen ~= gen then
				return false
			end
			S.out = result
			return true
		end)
	end
end

local function overlay_layer(element)
	return div():absolute():inset(0, 0, 0, 0):row():justify_center():items_center()
		:bg(alpha("background", 0.55)):child(element)
end

local function toast_layer()
	if S.toast == nil then
		return nil
	end
	local bad = S.toast.bad
	return div():absolute():inset(nil, 0, 14, 0):row():justify_center()
		:child(div():px(14):py(6):rounded(8):bg(bad and "error" or "raised4")
			:child(text(S.toast.words):color(bad and "background" or "foreground")))
end

local function render(size, now)
	S.now = now
	S.size = size
	if S.toast and now >= S.toast.over then
		S.toast = nil
	end
	if S.failure then
		return div():size_full():p(20):bg("background"):color("foreground")
			:child(text("pickpen cannot go on"):weight(700))
			:child(text(S.failure):color("error"))
			:child(text("Press ⌃C to leave."):color("dim"))
	end
	if S.sum == nil or S.boot == nil then
		return div():size_full():p(20):bg("background"):color("dim"):child(text("Starting…"))
	end
	local wake = nil
	if S.query_due then
		if now >= S.query_due then
			send_query()
		else
			wake = S.query_due
		end
	end
	refresh_panel()
	if S.detail_due and S.detail_due > now then
		wake = math.min(wake or S.detail_due, S.detail_due)
	end
	if S.toast then
		wake = math.min(wake or S.toast.over, S.toast.over)
	end

	local body = div():row():grow(1):min_h(0)
	local list_side = div():col():grow(1):min_w(0):min_h(0):child(head_row()):child(list_area())
	if S.panel.open and size.w < PANEL_MIN_PAGE then
		body:child(panel(0, true))
	else
		body:child(list_side)
		if S.panel.open then
			body:child(panel(clamp(math.floor(size.w * 0.36), 280, 460), false))
		end
	end
	local root = div():col():size_full():bg("background"):color("foreground"):text_size(TEXT)
		:family("terminal")
		:child(title_row())
		:child(query_row(S.overlay == nil))
		:child(chips_row())
		:child(banner())
		:child(body)
		:child(status_row())
		:child(footer())
	if S.overlay then
		root:child(overlay_layer(S.overlay.kind == "help" and overlay_help() or overlay_palette()))
	end
	root:child(toast_layer())
	return root, false, wake
end

local function handle(event)
	if S.sum == nil or S.boot == nil then
		return reply(false)
	end
	local kind = event.type
	if kind == "move" then
		local at = { x = event.x, y = event.y }
		S.pointer = at
		local changed = ui:point(b.layout, at)
		local dragged = (S.drag or S.resize or S.chart) and drag_over(at)
		return reply(changed or dragged == true)
	elseif kind == "leave" then
		S.pointer = nil
		return reply(ui:point(b.layout, nil))
	elseif kind == "press" then
		return press(event)
	elseif kind == "release" then
		if event.button == "left" then
			return release(event)
		end
		return reply(false)
	elseif kind == "scroll" then
		return reply(ui:scroll_by(b.layout, { x = event.x, y = event.y }, event.dy))
	elseif kind == "key" then
		return key(event)
	elseif kind == "text" then
		if S.typed ~= event.text then
			S.typed = event.text
			S.typing = true
			query_changed()
		end
		return reply(true)
	elseif kind == "menu" then
		return menu_pick(event)
	end
	return reply(false)
end

-- The page was laid out: the lists are kept within their reach.
local function settle()
	return ui:settle(b.layout)
end

b.call("open", {}, function(result, err)
	if err then
		S.failure = err.message or err.code or "the program did not answer"
		return true
	end
	S.boot = result
	S.typed = result.query or ""
	S.typing = true
	take_summary(result.summary, true)
	if result.notice then
		toast(result.notice, true)
	end
	return { redraw = true, keyboard = "field" }
end)

b.subscribe("rows", nil, function(sum)
	if S.boot == nil then
		return false
	end
	take_summary(sum, false)
	return true
end)

return {
	render = render,
	handle = handle,
	settle = settle,
}
