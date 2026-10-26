-- pickpen's view: rows come in on the program's stdin, a person filters, sorts and marks them here,
-- and the rows chosen go out on the program's stdout. The program holds the rows (it filters and
-- sorts them, and keeps the marks); this page holds what a person sees and where they are, and asks
-- the program for the rows in sight.
--
-- The page is the web page pickpen had, drawn by the terminal in its own font and theme: the query
-- (`chrome.lua`), the rows (`rows.lua`), the side panel (`panel.lua`), the bottom line and what is
-- over everything (`chrome.lua`). What the keys and the mouse do is here; what that does is in
-- `state.lua`, so that the two do the same.

local L = require("./lib")
local state = require("./state")
local C = require("./commands")
local R = require("./rows")
local P = require("./panel")
local K = require("./chrome")
local S, A = state.S, state.A
local b, T = L.b, L.T

-- Below this width the side panel lies over the rows instead of beside them.
local NARROW = 760

-- ---- starting --------------------------------------------------------------------------------------------

local started = false

local function on_boot(boot)
	S.boot = boot
	S.query = boot.query or ""
	S.out.fill = { query = S.query }
	S.out.keyboard = { field = "query" }
	S.panel = { open = S.width >= 1000, tab = boot.preview ~= nil and "row" or "output" }
	S.panel_width = math.floor(math.clamp(S.width * 0.32, 300, 560))
	if boot.order then
		S.order = { column = boot.order.column + 1, descending = boot.order.descending }
		S.column = S.order.column
	end
	if boot.sort_problem then
		A.toast(boot.sort_problem, "bad")
	end
	A.take(boot.summary, true)
	pencere.subscribe("table", {}, function(sum)
		A.take(sum, false)
		return A.reply()
	end)
end

-- ---- the page ------------------------------------------------------------------------------------------------

local function waiting()
	return b.div()
		:size_full()
		:col()
		:items_center()
		:justify_center()
		:gap(10)
		:family("terminal")
		:text_size(L.SIZE.ui)
		:child(L.mark(28))
		:child(T(S.error or "Waiting for the program…", S.error and "error" or "dim"))
end

local function build()
	local narrow = S.width < NARROW
	local root = b.div():size_full():col():family("terminal"):text_size(L.SIZE.ui):bg("background")
	root:child(K.query_bar())
	local body = b.div():row():grow(1):min_h(0)
	body:child(R.view_of())
	if S.panel.open then
		body:child(P.view(narrow))
	end
	root:child(body)
	root:child(K.bar(narrow))
	if S.overlay == "palette" then
		root:child(K.palette())
	elseif S.overlay == "help" then
		root:child(K.help())
	end
	if S.toast then
		root:child(K.toast())
	end
	if S.error then
		root:child(K.banner())
	end
	return root
end

local function render(size, now, reduce_motion)
	S.width, S.height, S.now = size.w, size.h, now
	L.reduce_motion = reduce_motion
	if not started then
		started = true
		A.ask("boot", {}, on_boot, function(err)
			S.error = err.message or "The program could not show its rows"
		end)
	end
	if S.toast and S.toast.until_ <= now then
		S.toast = nil
	end
	local wake = A.tick()
	if S.toast then
		wake = wake and math.min(wake, S.toast.until_) or S.toast.until_
	end
	L.ui.fades:advance(now, reduce_motion)
	if S.boot == nil or S.sum == nil then
		return waiting(), false, wake
	end
	if S.reveal then
		S.reveal = false
		R.reveal()
	end
	local root = build()
	L.ui.fades:advance(now, reduce_motion)
	-- The dot that says the input is still coming pulses while it does: a few steps a second are
	-- enough for it, and an input that never ends (`tail -f`) costs no more than that.
	if not S.sum.done and not reduce_motion then
		wake = math.min(wake or math.huge, now + 0.1)
	end
	return root, L.ui.fades:moving(), wake
end

-- Brings what depends on the layout within it: the list's size, the scrolled boxes, the cursor.
local function settle()
	local moved = L.ui:settle(pencere.layout)
	local extent = pencere.layout.scroll_extent("rows")
	if extent and (extent.view ~= R.view.h or extent.view_w ~= R.view.w) then
		R.view = { w = extent.view_w, h = extent.view }
		moved = true
		if S.cursor then
			R.reveal()
		end
	end
	if S.pointer then
		moved = L.ui:point(pencere.layout, S.pointer) or moved
	end
	return moved
end

-- ---- menus ---------------------------------------------------------------------------------------------------

-- Opens a menu at the pointer: `items` are `{ label =, keys =, run =, disabled = }` or `{ separator = true }`.
local function open_menu(at, items)
	local entries = {}
	for _, item in ipairs(items) do
		if item.separator then
			entries[#entries + 1] = "-"
		else
			entries[#entries + 1] = {
				title = item.label,
				key = item.keys and L.label(item.keys) or nil,
				enabled = not item.disabled,
			}
		end
	end
	S.menu = items
	S.out.menu = { at = { x = at.x, y = at.y }, entries = entries }
end

local function short(value)
	if value == "" then
		return "empty"
	end
	return L.cut(value, 23)
end

local function row_menu(index, column)
	local row = A.row(index)
	if row == nil then
		return {}
	end
	local marks = S.sum.marked
	local items = {
		{
			label = row.marked and "Unmark the row" or "Mark the row",
			keys = "Tab",
			run = function()
				A.toggle(index)
			end,
		},
	}
	if not S.boot.confirm and marks == 0 then
		items[#items + 1] = {
			label = "Send this row",
			keys = "Enter",
			run = function()
				A.send(row.id)
			end,
		}
	end
	local columns = S.sum.columns
	if column ~= nil and #columns > 1 then
		local name = columns[column]
		local value = short(row.cells[column] or "")
		items[#items + 1] = { separator = true }
		items[#items + 1] = {
			label = "Only rows where " .. name .. " is " .. value,
			run = function()
				A.term({ column = column - 1, id = row.id })
			end,
		}
		items[#items + 1] = {
			label = "Leave out rows where " .. name .. " is " .. value,
			run = function()
				A.term({ column = column - 1, id = row.id, negate = true })
			end,
		}
		items[#items + 1] = {
			label = "Mark every row where " .. name .. " is " .. value,
			run = function()
				A.mark_value(column, row.id, false)
			end,
		}
		items[#items + 1] = { separator = true }
		items[#items + 1] = {
			label = "Look at the column " .. name,
			keys = "F3",
			run = function()
				A.show_column(column)
			end,
		}
		items[#items + 1] = {
			label = "Copy the value",
			run = function()
				A.ask("copy_row", { id = row.id, column = column - 1 }, function(result)
					A.copy(result.text, "the value")
				end)
			end,
		}
	else
		items[#items + 1] = { separator = true }
	end
	items[#items + 1] = {
		label = "Copy the row",
		keys = "Mod-c",
		run = function()
			A.copy_row(row.id)
		end,
	}
	return items
end

local function column_menu(column)
	local name = S.sum.columns[column]
	local kind = (S.sum.kinds or {})[column] or "text"
	local quantities = kind ~= "text"
	local sending = false
	for _, field in ipairs(A.sent_fields()) do
		if string.lower(field) == string.lower(name) then
			sending = true
		end
	end
	local order = S.order
	return {
		{
			label = quantities and "Smallest first" or "A to Z",
			disabled = order ~= nil and order.column == column and not order.descending,
			run = function()
				A.set_order({ column = column, descending = false })
			end,
		},
		{
			label = quantities and "Largest first" or "Z to A",
			disabled = order ~= nil and order.column == column and order.descending,
			run = function()
				A.set_order({ column = column, descending = true })
			end,
		},
		{
			label = "The input's order",
			keys = "Ctrl-0",
			disabled = order == nil,
			run = function()
				A.set_order(nil)
			end,
		},
		{ separator = true },
		{
			label = "Look at the column " .. name,
			keys = "F3",
			run = function()
				A.show_column(column)
			end,
		},
		{
			label = sending and ("Stop sending " .. name) or ("Send " .. name .. " of each row"),
			run = function()
				A.toggle_field(name)
			end,
		},
		{
			label = "Hide " .. name,
			disabled = #C.visible_columns() <= 1,
			run = function()
				S.hidden[column] = true
			end,
		},
	}
end

-- A value of the column panel: only it, or ⌘-click: it as well as the ones chosen.
local function pick_value(i, mods)
	local facet = S.facet
	local value = facet and facet.values[i]
	if value == nil then
		return
	end
	local column = facet.column
	if mods and (mods.command or mods.control) then
		local kept = {}
		for _, other in ipairs(facet.values) do
			local on = other.chosen
			if other == value then
				on = not on
			end
			if on then
				kept[#kept + 1] = other.value
			end
		end
		if #kept == 0 then
			A.term({ column = column, clear = true })
		else
			A.term({ column = column, values = A.list(kept) })
		end
		return
	end
	local chosen = 0
	for _, other in ipairs(facet.values) do
		if other.chosen then
			chosen += 1
		end
	end
	if chosen == 1 and value.chosen then
		A.term({ column = column, clear = true })
	else
		A.term({ column = column, value = value.value })
	end
end

local function value_menu(i)
	local facet = S.facet
	local value = facet and facet.values[i]
	if value == nil then
		return {}
	end
	local column = facet.column
	return {
		{
			label = "Only rows with this",
			run = function()
				A.term({ column = column, value = value.value })
			end,
		},
		{
			label = "Leave out rows with this",
			run = function()
				A.term({ column = column, value = value.value, negate = true })
			end,
		},
		{
			label = "Mark the rows with this",
			run = function()
				A.ask("mark_value", { column = column, value = value.value, facet = true }, function(result)
					A.take(result.summary, false)
					for _, row in pairs(S.rows) do
						row.rev = -1
					end
					A.toast("Marked " .. L.plural(result.count, "row"))
				end)
			end,
		},
	}
end

local function field_menu(column)
	local row = A.row(S.cursor)
	if row == nil then
		return {}
	end
	local name = S.sum.columns[column]
	return {
		{
			label = "Only rows where " .. name .. " is this",
			run = function()
				A.term({ column = column - 1, id = row.id })
			end,
		},
		{
			label = "Leave out rows where " .. name .. " is this",
			run = function()
				A.term({ column = column - 1, id = row.id, negate = true })
			end,
		},
		{ separator = true },
		{
			label = "Copy the value",
			run = function()
				A.ask("copy_row", { id = row.id, column = column - 1 }, function(result)
					A.copy(result.text, "the value")
				end)
			end,
		},
	}
end

local function column_pick_menu()
	local items = {}
	for column, name in ipairs(S.sum.columns) do
		items[#items + 1] = {
			label = name,
			run = function()
				S.column = column
				S.facet_key = nil
			end,
		}
	end
	return items
end

-- ---- the keys ---------------------------------------------------------------------------------------------------

local function palette_key(key, mods)
	local shown = K.palette_list or C.palette_shown()
	if key == "escape" or (L.matches(key, mods, "Mod-k")) then
		S.overlay = nil
		A.keep_keyboard()
	elseif key == "down" or L.matches(key, mods, "Ctrl-n") then
		S.palette.chosen = math.min(S.palette.chosen + 1, math.max(#shown, 1))
		K.palette_reveal()
	elseif key == "up" or L.matches(key, mods, "Ctrl-p") then
		S.palette.chosen = math.max(S.palette.chosen - 1, 1)
		K.palette_reveal()
	elseif key == "enter" then
		local command = shown[S.palette.chosen]
		if command and C.can_run(command) then
			S.overlay = nil
			A.keep_keyboard()
			command.run()
		end
	elseif key == "tab" then
		S.out.keyboard = { field = "palette" }
	elseif #key == 1 and not (mods and (mods.command or mods.control)) then
		S.palette.text = S.palette.text .. key
		S.palette.chosen = 1
		S.out.fill = { palette = S.palette.text }
		S.out.keyboard = { field = "palette" }
	end
end

local function on_key(key, mods)
	mods = mods or {}
	if S.sending then
		return
	end
	if S.overlay == "palette" then
		palette_key(key, mods)
		return
	end
	if S.overlay == "help" then
		if key == "escape" or key == "f1" then
			S.overlay = nil
			A.keep_keyboard()
		end
		return
	end
	if C.run_key(key, mods) then
		-- After a command the keyboard is the query's again (a forwarded key leaves it there).
		if S.overlay == nil then
			A.keep_keyboard()
		end
		return
	end
	-- A key that types, with the keyboard on the page: it is the query's.
	if #key == 1 and not (mods.command or mods.control) then
		A.set_query(S.query .. key, true)
		A.keep_keyboard()
	elseif key == "backspace" and S.query ~= "" then
		local cut = utf8.offset(S.query, -1) or #S.query
		A.set_query(string.sub(S.query, 1, cut - 1), true)
		A.keep_keyboard()
	end
end

-- ---- the mouse --------------------------------------------------------------------------------------------------

-- A drag that is going on: the boxes being painted, a column or the panel being resized, the chart.
local drag = nil
local press_mods = {}

local function chart_fraction(x)
	local rect = pencere.layout.bounds("chart")
	if rect == nil or rect.w <= 0 then
		return 0
	end
	return math.clamp((x - rect.x) / rect.w, 0, 1)
end

local function on_press(event)
	local at = { x = event.x, y = event.y }
	S.pointer = at
	press_mods = event.mods or {}
	local hit = L.ui:press(pencere.layout, at)
	A.keep_keyboard()
	if S.sending then
		return
	end
	local kind, rest = nil, nil
	if hit ~= nil then
		kind, rest = string.match(tostring(hit), "^([%a]+):?(.*)$")
	end
	if event.button == "right" then
		if kind == "r" or kind == "k" then
			local where = R.hit(at)
			if where then
				A.set_cursor(where.index)
				open_menu(at, row_menu(where.index, where.column))
			end
		elseif kind == "h" then
			open_menu(at, column_menu(tonumber(rest)))
		elseif kind == "fv" then
			open_menu(at, field_menu(tonumber(rest)))
		elseif kind == "fval" then
			open_menu(at, value_menu(tonumber(rest)))
		end
		return
	end
	if kind == "k" then
		local index = tonumber(rest)
		local row = A.row(index)
		if row then
			local on = not row.marked
			drag = { kind = "paint", on = on, done = { [row.id] = true } }
			A.set_marked({ row.id }, on)
			S.anchor, S.anchor_on = row.id, on
			A.set_cursor(index)
		end
	elseif kind == "r" then
		local index = tonumber(rest)
		local row = A.row(index)
		if row == nil then
			return
		end
		local mods = event.mods or {}
		if event.count == 2 then
			-- Nothing goes out on a double-click when rows are marked, nor ever when a person confirms.
			if S.sum.marked == 0 and not S.boot.confirm then
				A.send(row.id)
			else
				A.toggle(index)
			end
		elseif mods.shift then
			A.extend_to(index)
		elseif mods.command or mods.control then
			A.toggle(index)
			A.set_cursor(index)
		else
			A.set_cursor(index)
			S.anchor, S.anchor_on = row.id, row.marked
		end
	elseif kind == "z" then
		local column = tonumber(rest)
		drag = { kind = "column", column = column, x = at.x, from = R.width(column) }
	elseif kind == "pedge" then
		drag = { kind = "panel", x = at.x, from = S.panel_width }
	elseif kind == "chart" then
		local f = chart_fraction(at.x)
		P.drag = { from = f, to = f }
		drag = { kind = "chart" }
	end
end

local function on_move(event)
	local at = { x = event.x, y = event.y }
	S.pointer = at
	local changed = L.ui:point(pencere.layout, at)
	if drag == nil then
		local over = L.ui.hover and tostring(L.ui.hover) or ""
		if string.find(over, "^z:") or over == "pedge" then
			S.out.cursor = "resize_horizontal"
		elseif over == "chart" then
			S.out.cursor = "crosshair"
		else
			S.out.cursor = "arrow"
		end
		return changed
	end
	if drag.kind == "paint" then
		local where = R.hit(at)
		local row = where and A.row(where.index)
		if row and not drag.done[row.id] and row.marked ~= drag.on then
			drag.done[row.id] = true
			A.set_marked({ row.id }, drag.on)
		end
	elseif drag.kind == "column" then
		S.widths[drag.column] = math.max(36, math.floor(drag.from + at.x - drag.x + 0.5))
		S.out.cursor = "resize_horizontal"
	elseif drag.kind == "panel" then
		S.panel_width = math.floor(math.clamp(drag.from - (at.x - drag.x), 240, math.max(S.width - 280, 240)))
		S.out.cursor = "resize_horizontal"
	elseif drag.kind == "chart" then
		P.drag.to = chart_fraction(at.x)
	end
	return true
end

local function on_click(id, at)
	local kind, rest = string.match(tostring(id), "^([%a]+):?(.*)$")
	local n = tonumber(rest)
	if kind == "hb" then
		local sum = S.sum
		A.mark_shown(not (sum.shown > 0 and (sum.marked_shown or 0) >= sum.shown))
	elseif kind == "h" then
		A.cycle_order(n)
	elseif kind == "unseen" then
		A.last()
	elseif kind == "hidden" then
		S.hidden = {}
	elseif kind == "cx" then
		A.set_query(K.without_term(n), true)
	elseif kind == "hint" then
		if rest == "mark" then
			A.mark_and_move(1)
		elseif rest == "send" then
			A.send()
		elseif rest == "back" then
			A.back()
		elseif rest == "palette" then
			C.open_palette()
		elseif rest == "help" then
			S.overlay = "help"
			S.out.keyboard = "page"
		end
	elseif kind == "nothing" then
		A.cancel()
	elseif kind == "send" then
		A.send()
	elseif kind == "tab" then
		S.panel = { open = true, tab = rest }
	elseif kind == "pclose" then
		A.toggle_panel()
	elseif kind == "copycmd" then
		if S.output then
			A.copy(S.output.again.line, "the command")
		end
	elseif kind == "marksh" then
		A.unmark_all()
		A.mark_shown(true)
	elseif kind == "sf" then
		local field = A.sent_fields()[n]
		if field then
			A.toggle_field(field)
		end
	elseif kind == "fieldsreset" then
		A.reset_fields()
	elseif kind == "cpick" then
		open_menu(at, column_pick_menu())
	elseif kind == "fv" then
		local row = A.row(S.cursor)
		if row and #S.sum.columns > 1 then
			A.term({ column = n - 1, id = row.id })
		end
	elseif kind == "fval" then
		pick_value(n, press_mods)
	elseif kind == "pal" then
		local command = (K.palette_list or {})[n]
		if command and C.can_run(command) then
			S.overlay = nil
			A.keep_keyboard()
			command.run()
		end
	elseif kind == "helpclose" or kind == "scrim" then
		S.overlay = nil
		A.keep_keyboard()
	end
end

local function on_release(event)
	local at = { x = event.x, y = event.y }
	local finished = drag
	drag = nil
	if finished and finished.kind == "chart" and P.drag then
		local from, to = P.drag.from, P.drag.to
		P.drag = nil
		local column = S.facet and S.facet.column
		if column ~= nil then
			if math.abs(to - from) < 0.01 then
				A.term({ column = column, clear = true })
			else
				A.term({ column = column, range = A.list({ math.min(from, to), math.max(from, to) }) })
			end
		end
		L.ui:release(pencere.layout, at)
		return
	end
	local clicked = L.ui:release(pencere.layout, at)
	if clicked ~= nil and event.button ~= "right" and (finished == nil or finished.kind ~= "column") then
		on_click(clicked, at)
	end
	A.keep_keyboard()
end

local function on_scroll(event)
	local at = { x = event.x, y = event.y }
	local moved = L.ui:scroll_by(pencere.layout, at, event.dx, event.dy)
	local extent = pencere.layout.scroll_extent("rows")
	if extent and L.ui:scroll_offset("rows") >= extent.max_offset - L.SIZE.row and S.unseen > 0 then
		S.unseen = 0
		moved = true
	end
	return moved
end

local function handle(event)
	local kind = event.type
	if kind == "text" then
		if event.field == "query" then
			A.set_query(event.text or "")
		elseif event.field == "palette" then
			S.palette.text = event.text or ""
			S.palette.chosen = 1
		end
		return A.reply()
	elseif kind == "focus" then
		return nil
	elseif kind == "key" then
		on_key(event.key, event.mods)
		return A.reply()
	elseif kind == "press" then
		on_press(event)
		return A.reply()
	elseif kind == "release" then
		on_release(event)
		return A.reply()
	elseif kind == "move" then
		local changed = on_move(event)
		local out = S.out
		S.out = {}
		out.redraw = changed and true or false
		return out
	elseif kind == "leave" then
		S.pointer = nil
		return L.ui:point(pencere.layout, nil)
	elseif kind == "scroll" then
		return on_scroll(event)
	elseif kind == "menu" then
		local items = S.menu
		S.menu = nil
		local item = items and items[event.index]
		if item and item.run and not item.disabled then
			item.run()
		end
		A.keep_keyboard()
		return A.reply()
	end
	return nil
end

return {
	render = render,
	handle = handle,
	settle = settle,
}
