-- The rows: only those in sight are made, so a few hundred thousand scroll as a few dozen, and the
-- program gives them a window at a time.
--
-- The mouse does what the keys do (page.lua reads it): a click puts the cursor on a row; the box in
-- front of a row marks it, and a drag down the boxes marks (or unmarks) every row it passes; ⌘-click
-- marks one row, ⇧-click every row from the last one marked; a double-click sends the row when
-- nothing is marked; a right-click offers what can be done with the row and the cell. A heading
-- sorts on a click and is resized by its edge. No click takes the keyboard from the query.

local L = require("./lib")
local state = require("./state")
local C = require("./commands")
local S, A = state.S, state.A
local b, alpha, T, SIZE = L.b, L.alpha, L.T, L.SIZE

local R = {}

-- The most of a cell drawn; a longer one is cut where it would not be seen anyway.
local DRAWN = 400
-- Rows made beyond those in sight, above and below: enough for a turn of the wheel to find them made.
local OVERSCAN = 3
-- Points of columns made beyond the edges of the list, so that a column coming into sight is there.
local OVERSCAN_X = 60

local QUANTITIES = { number = true, size = true, duration = true }

-- How big the list's box was laid out, from the last frame (`settle` keeps it).
R.view = { w = 800, h = 400 }

function R.is_quantity(column)
	local kinds = S.sum and S.sum.kinds or {}
	return QUANTITIES[kinds[column] or "text"] == true
end

-- The width of a column in points: the person's, or one from its name and first rows.
function R.width(column)
	if S.widths[column] then
		return S.widths[column]
	end
	local chars = (S.sum and S.sum.widths and S.sum.widths[column]) or 10
	return math.floor(chars * L.char_width(SIZE.cell) + 20 + 0.5)
end

-- Where each shown column is across the table: `{ { column =, x =, w = } }`, and the table's width.
-- A last column of words takes the room that is left; one of quantities keeps its width, so that it
-- stays beside the others, and the room is left empty after it.
function R.columns()
	local shown = C.visible_columns()
	local out, x = {}, SIZE.mark
	for _, column in ipairs(shown) do
		local w = R.width(column)
		out[#out + 1] = { column = column, x = x, w = w }
		x += w
	end
	local total = x
	local last = out[#out]
	if last and not R.is_quantity(last.column) and total < R.view.w then
		last.w += R.view.w - total
		total = R.view.w
	end
	return out, math.max(total, R.view.w)
end

-- The words of the query, for drawing where they are in each cell: longest first.
local function words_of()
	local words = {}
	for _, term in ipairs(S.terms) do
		if term.kind == "text" and not term.negate and term.text ~= "" then
			words[#words + 1] = string.lower(term.text)
		end
	end
	table.sort(words, function(x, y)
		return #x > #y
	end)
	return words
end

local function cell_of(text, width, words, quantity, ink)
	local shown = L.cut(text, DRAWN)
	local box = b.div():row():items_center():w(width):no_shrink():px(SIZE.pad):clip():h_full()
	if quantity then
		box:justify_end()
	end
	if #words == 0 or shown == "" then
		return box:child(T(shown, ink):truncate():min_w(0))
	end
	local lower = string.lower(shown)
	local at = 1
	local any = false
	while at <= #shown do
		local best, length = nil, 0
		for _, word in ipairs(words) do
			local found = string.find(lower, word, at, true)
			if found and (best == nil or found < best) then
				best, length = found, #word
			end
		end
		if best == nil then
			break
		end
		any = true
		if best > at then
			box:child(T(string.sub(shown, at, best - 1), ink):no_shrink())
		end
		box:child(b.div():rounded(2):bg(L.match):no_shrink():child(T(string.sub(shown, best, best + length - 1), ink)))
		at = best + length
	end
	if not any then
		return box:child(T(shown, ink):truncate():min_w(0))
	end
	if at <= #shown then
		box:child(T(string.sub(shown, at), ink):truncate():min_w(0))
	end
	return box
end

-- The box in front of a row, or of the headings: ticked, half (some marked), or empty.
local function tick(on, half, hover)
	local t = b.div():size(14, 14):rounded(4):row():items_center():justify_center():no_shrink()
	if on or half then
		t:bg("accent"):child(L.icon(on and "check" or "minus", 11, "background"))
	else
		t:border(1.5, hover and alpha("accent", 0.7) or alpha("foreground", 0.22))
	end
	return t
end

local function row_of(index, layout)
	local row = A.row(index)
	local id = "r:" .. index
	local el = b.div():press(id):row():h(SIZE.row):w(layout.total):no_shrink():items_center()
	local is_cursor = index == S.cursor
	local marked = row ~= nil and row.marked
	if is_cursor then
		el:bg(marked and L.marked_cursor or L.cursor)
		el:child(b.div():absolute():inset(0, nil, 0, 0):w(2):bg("accent"))
	elseif marked then
		el:bg(L.marked)
	elseif L.ui.hover == id or L.ui.hover == "k:" .. index then
		el:bg(L.hover)
	end
	local box_id = "k:" .. index
	el:child(
		b.div()
			:press(box_id)
			:row()
			:items_center()
			:justify_center()
			:w(SIZE.mark)
			:h_full()
			:no_shrink()
			:label(marked and "Marked" or "Not marked")
			:child(tick(marked, false, L.ui.hover == box_id))
	)
	if row == nil then
		return el
	end
	if layout.skipped > 0 then
		el:child(b.div():w(layout.skipped):no_shrink())
	end
	for _, place in ipairs(layout.visible) do
		local cell = row.cells[place.column] or ""
		el:child(cell_of(cell, place.w, layout.words, R.is_quantity(place.column), nil))
	end
	return el
end

local function head_of(layout)
	local sum = S.sum
	local shown, marked_shown = sum.shown, sum.marked_shown or 0
	local all = shown > 0 and marked_shown >= shown
	local some = not all and marked_shown > 0
	local head = b.div():row():h(SIZE.head):w(layout.total):no_shrink():items_center()
	head:child(
		b.div()
			:press("hb")
			:row()
			:items_center()
			:justify_center()
			:w(SIZE.mark)
			:h_full()
			:no_shrink()
			:tip(all and "Unmark the rows shown" or "Mark every row shown", L.label("Mod-a"))
			:child(tick(all, some, L.ui.hover == "hb"))
	)
	if layout.skipped > 0 then
		head:child(b.div():w(layout.skipped):no_shrink())
	end
	for _, place in ipairs(layout.visible) do
		local column = place.column
		local id = "h:" .. column
		local sorted = S.order and S.order.column == column
		local over = L.ui.hover == id
		local name = sum.columns[column] or ""
		local cell = b.div()
			:press(id)
			:row()
			:items_center()
			:gap(4)
			:px(SIZE.pad)
			:w(place.w)
			:h_full()
			:no_shrink()
			:tip(name .. ": click to order, right-click for more")
		if R.is_quantity(column) then
			cell:justify_end()
		end
		local bg = L.hover_bg(id)
		if bg then
			cell:bg(bg)
		end
		local ink = sorted and "accent" or (over and "foreground" or "dim")
		cell:child(T(name, ink, SIZE.small, 600):truncate():min_w(0))
		if sorted then
			cell:child(L.icon(S.order.descending and "arrow-down" or "arrow-up", 12, "accent"))
		end
		-- The edge that resizes it: wider to the pointer than it is drawn.
		local edge = "z:" .. column
		local lit = L.ui.hover == edge or over or L.ui.pressed == edge
		cell:child(
			b.div()
				:press(edge)
				:absolute()
				:inset(0, -3, 0, nil)
				:w(7)
				:row()
				:justify_center()
				:py(7)
				:child(b.div():w(1):h_full():bg(lit and "accent" or L.line))
		)
		head:child(cell)
	end
	return head
end

-- A note over the bottom of the list: the new rows below, the hidden columns, a problem of the input.
local function pill(id, content, ink)
	local el = b.div()
		:press(id)
		:row()
		:items_center()
		:gap(5)
		:px(10)
		:h(22)
		:rounded(11)
		:bg(L.raised)
		:border(1, alpha("border", 0.9))
		:shadow(0, 6, 14, alpha("shadow", 0.5))
	if type(content) == "string" then
		el:child(T(content, ink or "foreground", SIZE.small))
	else
		el:child(content)
	end
	return el
end

local function empty()
	local sum = S.sum
	local box = b.div():absolute():inset(60, 0, nil, 0):row():justify_center():px(16)
	if sum.total == 0 then
		return box:child(T(sum.done and "The input has no rows." or "Waiting for rows…", "dim"))
	end
	return box:child(
		b.div()
			:row()
			:wrap()
			:justify_center()
			:child(T("No row of " .. L.count(sum.total) .. " matches ", "dim"))
			:child(T(S.query, "foreground", nil, 700))
			:child(T(". ", "dim"))
			:child(T("Esc clears the query.", "quiet"))
	)
end

-- The list, its headings, and what is said over it.
function R.view_of()
	local sum = S.sum
	local columns, total = R.columns()
	local oy, ox = L.scrolled("rows"), L.scrolled_x("rows")
	-- Only the columns in sight are made (a row of a wide table is a few of its cells, not all), the
	-- room of those to their left kept by one empty box; those to the right need none.
	local visible, skipped = {}, 0
	for _, place in ipairs(columns) do
		if place.x + place.w < ox - OVERSCAN_X then
			skipped = place.x + place.w - SIZE.mark
		elseif place.x <= ox + R.view.w + OVERSCAN_X then
			visible[#visible + 1] = place
		end
	end
	local layout = { columns = columns, visible = visible, skipped = skipped, total = total, words = words_of() }
	R.last_layout = layout
	local shown = sum.shown
	local view_h = math.max(R.view.h, SIZE.row)
	local first = math.max(1, math.floor(oy / SIZE.row) + 1 - OVERSCAN)
	local last = math.min(shown, math.ceil((oy + view_h) / SIZE.row) + OVERSCAN)
	A.set_page_rows(math.floor(view_h / SIZE.row))
	A.need(first, last)

	local list = b.div():id("rows"):col():grow(1):min_h(0):scroll():family("terminal"):text_size(SIZE.cell)
	list:child(b.div():h(math.max(first - 1, 0) * SIZE.row):w(total):no_shrink())
	for index = first, last do
		list:child(row_of(index, layout))
	end
	list:child(b.div():h(math.max(shown - last, 0) * SIZE.row):w(total):no_shrink())

	local head = b.div():h(SIZE.head):no_shrink():clip():bg("background"):child(b.div():ml(-ox):child(head_of(layout)))
	local area = b.div():col():grow(1):min_w(0):min_h(0):opacity(S.sending and 0.55 or 1)
	area:child(head):child(b.div():h(1):bg(L.line):no_shrink()):child(list)

	local wrap = b.div():col():grow(1):min_w(0):min_h(0):child(area)
	if shown == 0 then
		wrap:child(empty())
	end
	if S.unseen > 0 then
		wrap:child(
			b.div():absolute():inset(nil, 0, 10, 0):row():justify_center():child(
				pill(
					"unseen",
					b.div()
						:row()
						:items_center()
						:gap(5)
						:child(L.icon("arrow-down", 12, "accent"))
						:child(T(L.plural(S.unseen, "new row"), "accent", SIZE.small))
				)
			)
		)
	end
	local hidden = 0
	for _ in pairs(S.hidden) do
		hidden += 1
	end
	if hidden > 0 then
		wrap:child(
			b.div()
				:absolute()
				:inset(nil, 12, 10, nil)
				:child(pill("hidden", L.plural(hidden, "column") .. " hidden · show", "dim"))
		)
	end
	if sum.problem then
		wrap:child(b.div():absolute():inset(nil, nil, 10, 12):child(T(sum.problem, "warning", SIZE.small)))
	end
	return wrap
end

-- What is under the pointer on the list: the row's index, the column, whether it is the box.
function R.hit(at)
	local rect = pencere.layout.bounds("rows")
	if rect == nil or R.last_layout == nil then
		return nil
	end
	if at.x < rect.x or at.x >= rect.x + rect.w or at.y < rect.y or at.y >= rect.y + rect.h then
		return nil
	end
	local y = at.y - rect.y + L.scrolled("rows")
	local index = math.floor(y / SIZE.row) + 1
	if index < 1 or index > A.shown() then
		return nil
	end
	local x = at.x - rect.x + L.scrolled_x("rows")
	local column = nil
	for _, place in ipairs(R.last_layout.columns) do
		if x >= place.x and x < place.x + place.w then
			column = place.column
		end
	end
	return { index = index, column = column, box = x < SIZE.mark }
end

-- Scrolls the least that shows the cursor's row.
function R.reveal()
	if S.cursor == nil then
		return
	end
	local top = (S.cursor - 1) * SIZE.row
	local offset = L.scrolled("rows")
	local view = R.view.h
	if top < offset then
		L.scroll_to("rows", top)
	elseif top + SIZE.row > offset + view then
		L.scroll_to("rows", math.max(top + SIZE.row - view, 0))
	end
end

return R
