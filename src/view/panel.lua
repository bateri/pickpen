-- The side panel, three tabs:
--
-- - the row the cursor is on: what `--preview` prints for it, or its cells;
-- - a column: its values by how often they come, or a chart of its quantities, among the rows the
--   rest of the query keeps; a click on a value, or a drag across the chart, writes the term into
--   the query, where the keyboard can change it;
-- - what goes out: the bytes Send would write, drawn by the program with the function that writes
--   them, and the command line that does it again with nobody to ask.

local L = require("./lib")
local state = require("./state")
local ansi = require("./ansi")
local S, A = state.S, state.A
local b, alpha, T, SIZE = L.b, L.alpha, L.T, L.SIZE

local P = {}

local TABS = {
	{ tab = "row", label = "Row", keys = "F2" },
	{ tab = "column", label = "Column", keys = "F3" },
	{ tab = "output", label = "Output", keys = "F4" },
}

-- The chart's width as it was laid out, and a drag across it: { from =, to = } as fractions.
P.chart_w = 300
P.drag = nil

-- The most lines of a preview or of what goes out the panel draws.
local LINES_MOST = 400

local function pad()
	return b.div():col():px(12):py(10)
end

-- A link: words in the accent, underlined, that the pointer presses.
local function link(id, words)
	local level = L.glow(id, L.ui.hover == id)
	return b.div()
		:press(id)
		:no_shrink()
		:child(T(words, level > 0 and L.mix("accent", "foreground", 0.3 * level) or "accent"):underline())
end

-- ---- the row ------------------------------------------------------------------------------------------

local function preview_tab(width)
	local p = S.preview
	local head = b.div()
		:row()
		:items_center()
		:gap(8)
		:px(12)
		:py(6)
		:no_shrink()
		:child(T(S.boot.preview, "dim"):truncate():min_w(0):grow(1))
	if S.preview_waiting then
		head:child(T("running", "info"))
	elseif p and p.status ~= 0 then
		local words = p.timed_out and "took too long"
			or (
				(p.status == nil or p.status == pencere.json.null) and "ended by a signal"
				or ("exit " .. tostring(p.status))
			)
		head:child(T(words, "warning"))
	end
	A.want_preview(math.max(20, math.min(1000, math.floor((width - 24) / L.char_width(12)) - 2)))
	local text = b.div()
		:id("preview")
		:col()
		:grow(1)
		:min_h(0)
		:px(12)
		:py(8)
		:scroll_y(L.ui:scroll_offset("preview"))
		:scroll_x(L.ui:scroll_offset_x("preview"))
		:text_size(12)
		:opacity(S.preview_waiting and 0.6 or 1)
	if p then
		local count = 0
		for line in string.gmatch(p.text .. "\n", "([^\n]*)\n") do
			count += 1
			if count > LINES_MOST then
				text:child(T("… " .. "the rest is not drawn", "quiet"))
				break
			end
			local row = b.div():row():h(18):no_shrink()
			for _, run in ipairs(ansi.runs(line)) do
				local piece = T(L.cut(run.text, 1000), run.fg):no_shrink()
				if run.bold then
					piece:weight(600)
				end
				if run.italic then
					piece:italic()
				end
				if run.underline then
					piece:underline()
				end
				if run.dim then
					piece:opacity(0.65)
				end
				if run.bg then
					row:child(b.div():bg(run.bg):no_shrink():child(piece))
				else
					row:child(piece)
				end
			end
			text:child(row)
		end
		if p.cut then
			text:child(T("… the rest was cut", "quiet"))
		end
	end
	return b.div():col():grow(1):min_h(0):child(head):child(b.div():h(1):bg(L.line2):no_shrink()):child(text)
end

local function row_tab(width)
	if S.cursor == nil then
		return pad():child(T("No row is under the cursor.", "quiet"))
	end
	if S.boot.preview ~= nil then
		return preview_tab(width)
	end
	local row = A.row(S.cursor)
	local list = b.div():id("panel"):col():w(width):grow(1):min_h(0):py(6):scroll_y(L.ui:scroll_offset("panel"))
	if row == nil then
		return list
	end
	local name_w = math.max(70, math.floor((width - 24) * 0.35))
	for column, name in ipairs(S.sum.columns) do
		local value = row.cells[column] or ""
		local id = "fv:" .. column
		local cell = b.div():press(id):px(3):ml(-3):rounded(3):min_w(0)
		local level = L.glow(id, L.ui.hover == id)
		if level > 0 then
			cell:bg(alpha("accent", 0.14 * level))
		end
		if #S.sum.columns > 1 then
			cell:tip("Only rows where " .. name .. " is this")
		end
		if value == "" then
			cell:child(T("empty", "quiet"))
		else
			cell:child(T(L.cut(value, 2000)):wrap():max_w(width - name_w - 34))
		end
		list:child(
			b.div()
				:row()
				:gap(10)
				:px(12)
				:py(2)
				:no_shrink()
				:child(b.div():w(name_w):no_shrink():child(T(name, "dim"):truncate()))
				:child(b.div():grow(1):min_w(0):child(cell))
		)
	end
	return list
end

-- ---- a column -------------------------------------------------------------------------------------------

local function chart(facet, width)
	local c = facet.chart
	if c == nil then
		return pad():child(T("No cell of these rows is a " .. facet.kind .. ".", "quiet"))
	end
	P.chart_w = width - 24
	local band = nil
	if P.drag then
		band = { math.min(P.drag.from, P.drag.to), math.max(P.drag.from, P.drag.to) }
	elseif c.range then
		band = { math.min(c.range[1], c.range[2]), math.max(c.range[1], c.range[2]) }
	end
	local peak = 1
	for _, n in ipairs(c.bins) do
		peak = math.max(peak, n)
	end
	local height = 84
	local area = b.div()
		:press("chart")
		:row()
		:items_end()
		:gap(1)
		:h(height)
		:w(P.chart_w)
		:no_shrink()
		:tip("Drag across to keep only that range; click to let every value in")
	local count = #c.bins
	for i, n in ipairs(c.bins) do
		local middle = (i - 0.5) / count
		local inside = band and middle >= band[1] and middle <= band[2]
		local fill = alpha("accent", 0.45)
		if band then
			fill = inside and "accent" or alpha("foreground", 0.14)
		end
		local h = n == 0 and 0 or math.max(4, math.sqrt(n / peak) * 100) * height / 100
		area:child(b.div():grow(1):w(0):h(h):rounded_corners({ 2, 2, 0, 0 }):bg(fill))
	end
	if band then
		area:child(
			b.div()
				:absolute()
				:inset(0, nil, 0, band[1] * P.chart_w)
				:w(math.max((band[2] - band[1]) * P.chart_w, 1))
				:bg(alpha("accent", 0.12))
				:border(1, "accent")
		)
	end
	return b.div():col():px(12):pb(10):no_shrink():child(area):child(b.div():h(1):bg(L.line):no_shrink()):child(
		b.div()
			:row()
			:justify_between()
			:pt(3)
			:child(T(c.min, "quiet", SIZE.chip))
			:child(T("median " .. c.median .. (c.log and " · log scale" or ""), "quiet", SIZE.chip))
			:child(T(c.max, "quiet", SIZE.chip))
	)
end

local function values(facet, width)
	local box = b.div():col():no_shrink()
	local head = b.div():row():wrap():px(12):pb(4):child(
		T(
			(facet.distinct == 1 and "one value" or (L.count(facet.distinct) .. " values"))
				.. " in "
				.. L.plural(facet.rows, "row"),
			"dim"
		)
	)
	if facet.distinct > #facet.values then
		head:child(T(" · the " .. #facet.values .. " most common", "quiet"))
	end
	box:child(head)
	local most = (facet.values[1] and facet.values[1].count) or 1
	for i, value in ipairs(facet.values) do
		local id = "fval:" .. i
		local row = b.div()
			:press(id)
			:row()
			:items_center()
			:gap(8)
			:px(12)
			:h(20)
			:no_shrink()
			:tip("Click: only rows with this · ⌘-click: or with this · right-click: more")
		local bg = L.hover_bg(id)
		if bg then
			row:bg(bg)
		end
		row:child(
			b.div()
				:absolute()
				:inset(2, nil, 2, 0)
				:w(math.max(width * value.count / most, 1))
				:rounded_corners({ 0, 3, 3, 0 })
				:bg(alpha("accent", 0.1))
		)
		local ink = value.chosen and "accent" or nil
		if value.value == "" then
			row:child(b.div():grow(1):min_w(0):child(T("empty", "quiet")))
		else
			row:child(b.div():grow(1):min_w(0):child(T(L.cut(value.value, 300), ink):truncate()))
		end
		row:child(T(L.count(value.count), "dim"))
		if value.chosen then
			row:child(L.icon("check", 12, "accent"))
		end
		box:child(row)
	end
	return box
end

local function column_tab(width)
	A.want_facet()
	local facet = S.facet
	local columns = S.sum.columns
	local column = math.clamp(S.column, 1, math.max(#columns, 1))
	local list = b.div():id("panel"):col():w(width):grow(1):min_h(0):py(8):scroll_y(L.ui:scroll_offset("panel"))
	if #columns == 0 then
		return list
	end
	local kind = (S.sum.kinds or {})[column] or "text"
	local id = "cpick"
	local level = L.glow(id, L.ui.hover == id)
	list:child(
		b.div():row():px(12):pb(8):no_shrink():child(
			b.div()
				:press(id)
				:row()
				:items_center()
				:gap(6)
				:px(8)
				:h(24)
				:rounded(6)
				:bg(alpha("foreground", 0.05 + 0.05 * level))
				:child(T(columns[column], "foreground", nil, 700))
				:child(T(kind == "text" and "words" or (kind .. "s"), "quiet"))
				:child(L.icon("chevron-down", 13, "dim"))
		)
	)
	if facet == nil or facet.column ~= column - 1 then
		return list
	end
	if kind ~= "text" then
		list:child(chart(facet, width))
	end
	list:child(values(facet, width))
	return list
end

-- ---- what goes out ----------------------------------------------------------------------------------------

-- A part of the panel, `width` wide: what is in it is held to the panel's width, so that a long line
-- of what goes out scrolls in its own box and does not widen the rest.
local function section(width, title, extra)
	local box = b.div():col():w(width):px(12):py(10):no_shrink()
	local head = b.div():row():items_center():gap(4):pb(6):child(T(title, "dim", SIZE.small, 600))
	if extra then
		head:child(T(extra, "quiet", SIZE.small))
	end
	return box:child(head)
end

local function output_tab(width)
	A.want_output()
	local out = S.output
	local list = b.div():id("panel"):col():w(width):grow(1):min_h(0):scroll_y(L.ui:scroll_offset("panel"))
	if out == nil then
		return list
	end
	local again = out.again
	local inner = width - 24
	local command = b.div()
		:row()
		:w(inner)
		:items_start()
		:gap(6)
		:px(8)
		:py(6)
		:rounded(6)
		:bg("background")
		:border(1, L.line2)
		:child(T(again.line, "foreground"):wrap():max_w(inner - 50):grow(1):min_w(0))
		:child(L.icon_button("copycmd", "copy", 13, 22, "Copy the command"))
	local said = b.div():row():wrap():w(inner):items_center():gap_x(4):pt(6)
	local where_said = again.where == ""
	if again.kind == "same" then
		said:child(L.icon("check", 13, "success"))
		said:child(
			T(
				"Sends the same "
					.. L.plural(again.rows, "row")
					.. ": the ones marked are the ones "
					.. (where_said and "there are" or "it matches")
					.. ".",
				"success"
			):wrap():max_w(inner - 20)
		)
	elseif again.kind == "different" then
		said:child(L.icon("info", 13, "dim"))
		said:child(
			T(
				"Would send "
					.. (where_said and "every row" or ("the " .. L.plural(again.rows, "row") .. " it matches"))
					.. "; "
					.. L.count(again.chosen)
					.. (again.chosen == 1 and " is" or " are")
					.. " marked, by hand.",
				"dim"
			):wrap():max_w(inner - 20)
		)
		if again.where == S.query then
			said:child(link("marksh", "Mark just the rows shown"))
		end
	else
		said:child(L.icon("info", 13, "dim"))
		local words = "Sends " .. (where_said and "every row" or "the rows it matches") .. "."
		if again.where == S.query then
			words = words .. " Mark them (" .. L.label("Mod-a") .. ") to send the same now."
		end
		said:child(T(words, "dim"):wrap():max_w(inner - 20))
	end
	list:child(section(width, "Again, with nobody to ask"):child(command):child(said))
	list:child(b.div():h(1):bg(L.line2):no_shrink())

	local count = out.count
	local extra = count == 0 and "· nothing yet"
		or ("· " .. L.plural(count, "row") .. (count > 200 and ", the first 200 shown" or ""))
	local goes = section(width, "What goes out", extra)
	local fields = b.div():row():wrap():w(inner):items_center():gap(4):pb(6)
	local sent = A.sent_fields()
	if #sent > 0 then
		for i, field in ipairs(sent) do
			fields:child(
				b.div()
					:row()
					:items_center()
					:gap(4)
					:h(18)
					:pl(7)
					:pr(3)
					:rounded(9)
					:bg(alpha("foreground", 0.07))
					:child(T(field, "foreground", SIZE.chip))
					:child(L.icon_button("sf:" .. i, "x", 11, 15, "Stop sending " .. field))
			)
		end
		if S.fields ~= nil then
			fields:child(link("fieldsreset", "as the command line said"))
		end
	else
		fields:child(T("Each row whole. Right-click a heading to send only that column.", "quiet"):wrap():max_w(inner))
	end
	goes:child(fields)
	if out.error then
		goes:child(T(out.error, "error"):wrap():max_w(inner):pb(6))
	end
	local text = b.div()
		:id("out")
		:col()
		:w(inner)
		:px(8)
		:py(6)
		:rounded(6)
		:bg("background")
		:border(1, L.line2)
		:min_h(34)
		:scroll_x(L.ui:scroll_offset_x("out"))
	local lines = 0
	for line in string.gmatch(out.text, "([^\n]*)\n") do
		lines += 1
		if lines > LINES_MOST then
			text:child(T("…", "quiet"))
			break
		end
		text:child(T(L.cut(line, 1000)):no_shrink())
	end
	goes:child(text)
	list:child(goes)
	return list
end

-- ---- the panel ------------------------------------------------------------------------------------------------

function P.width(narrow)
	if narrow then
		return math.min(S.panel_width, S.width - 24)
	end
	return S.panel_width
end

function P.view(narrow)
	local width = P.width(narrow)
	local aside = b.div():col():w(width):no_shrink():min_h(0):bg(narrow and L.raised or L.chrome)
	if narrow then
		aside:absolute():inset(0, 0, 0, nil):shadow(0, 18, 48, alpha("shadow", 0.55)):border(1, alpha("border", 0.9))
	end
	local tabs = b.div():row():items_stretch():gap(2):px(6):h(SIZE.tabs):no_shrink()
	for _, tab in ipairs(TABS) do
		local id = "tab:" .. tab.tab
		local active = S.panel.tab == tab.tab
		local level = L.glow(id, L.ui.hover == id and not active)
		tabs:child(
			b.div()
				:press(id)
				:col()
				:px(8)
				:no_shrink()
				:child(
					b.div()
						:grow(1)
						:row()
						:items_center()
						:gap(5)
						:child(T(tab.label, active and "foreground" or L.mix("dim", "foreground", level)))
						:child(L.keys(tab.keys, true))
				)
				:child(b.div():h(2):bg(active and "accent" or nil))
		)
	end
	tabs:child(b.spacer())
	tabs:child(b.div():row():items_center():child(L.icon_button("pclose", "x", 13, 20, "Close the panel")))
	aside:child(tabs):child(b.div():h(1):bg(L.line):no_shrink())
	local body
	if S.panel.tab == "row" then
		body = row_tab(width)
	elseif S.panel.tab == "column" then
		body = column_tab(width)
	else
		body = output_tab(width)
	end
	aside:child(body)
	if narrow then
		return aside
	end
	-- The line between the rows and the panel, which the pointer drags: seven points wide to the
	-- pointer, three of them over the rows, and a point wide to the eye. It is laid over the panel's
	-- edge rather than between the two with negative margins, which the engine counts against the
	-- room the rows have.
	return aside:child(
		b.div()
			:press("pedge")
			:absolute()
			:inset(0, nil, 0, -3)
			:w(7)
			:row()
			:justify_center()
			:child(b.div():w(1):h_full():bg(L.ui.pressed == "pedge" and alpha("accent", 0.6) or L.line))
	)
end

return P
