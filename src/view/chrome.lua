-- What is around the rows: the line the person types in, which always has the keyboard, with what
-- the query means term by term under it; the bottom line, with the keys that matter most and the two
-- answers; and what is over everything: the palette (⌘K), the keys on one page (F1), a toast.

local L = require("./lib")
local state = require("./state")
local C = require("./commands")
local S, A = state.S, state.A
local b, alpha, T, SIZE = L.b, L.alpha, L.T, L.SIZE

local K = {}

-- ---- the query ------------------------------------------------------------------------------------------

local WORDS = {
	["="] = "is",
	["!="] = "is not",
	["~"] = "holds",
	["!~"] = "does not hold",
	[">"] = "above",
	[">="] = "at least",
	["<"] = "below",
	["<="] = "at most",
}

-- How a term was read, a chip that says it; its × takes it out.
local function chip(index, term)
	local box = b.div()
		:row()
		:items_center()
		:gap(4)
		:h(18)
		:pl(7)
		:pr(3)
		:rounded(9)
		:bg(alpha("foreground", 0.07))
		:no_shrink()
		:text_size(SIZE.chip)
	local function op(words)
		box:child(T(words, "quiet"))
	end
	local function value(words)
		box:child(T(L.cut(words, 60), "foreground", nil, 600))
	end
	if term.kind == "text" then
		op(term.negate and "without" or "has")
		value(term.text)
	else
		box:child(T(L.cut(term.name, 40), "accent", nil, 600))
		if term.range then
			op("between")
			value(term.range[1])
			op("and")
			value(term.range[2])
		else
			op(WORDS[term.op] or term.op)
			for i, v in ipairs(term.values) do
				if i > 1 then
					op("or")
				end
				value(v == "" and "empty" or v)
			end
		end
	end
	box:child(L.icon_button("cx:" .. index, "x", 11, 15, "Take this term out"))
	return box
end

-- The query without the term at `index`: its bytes taken out, the spaces closed up.
function K.without_term(index)
	local term = S.terms[index]
	if term == nil then
		return S.query
	end
	local text = string.sub(S.query, 1, term.from) .. string.sub(S.query, term.to + 1)
	text = string.gsub(text, "%s%s+", " ")
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	return text
end

-- The dot that says the input is still coming, and pulses while it is.
local function live_dot()
	local level = 1
	if not L.reduce_motion then
		level = 0.25 + 0.75 * (0.5 + 0.5 * math.cos(S.now * math.pi / 0.6))
	end
	return b.div():size(6, 6):rounded(3):bg(alpha("info", level)):no_shrink()
end

function K.query_bar()
	local sum = S.sum
	local bar = b.div():col():gap(3):px(10):pt(4):pb(5):bg(L.chrome):no_shrink()
	if S.boot.title then
		bar:child(
			b.div()
				:row()
				:items_center()
				:gap(7)
				:pt(2)
				:pb(1)
				:child(L.mark(14))
				:child(T(S.boot.title, "foreground", nil, 600):truncate():min_w(0))
		)
	end
	local line = b.div():row():items_center():gap(8):min_w(0)
	line:child(T("›", "accent", 15, 700))
	line:child(
		b.div()
			:text_field("query")
			:grow(1)
			:min_w(0)
			:h(24)
			:child(T(sum.placeholder or "Type to filter", "quiet", SIZE.query))
	)
	local counts = b.div():row():items_center():no_shrink():max_w(math.floor(S.width * 0.55)):clip()
	if S.query == "" then
		counts:child(T(L.plural(sum.total, "row"), "dim"))
	else
		counts:child(T(L.count(sum.shown) .. " of " .. L.plural(sum.total, "row"), "dim"))
	end
	if sum.marked > 0 then
		counts:child(T(" · " .. L.count(sum.marked) .. " marked", "accent"))
	end
	if sum.capped then
		counts:child(T(" · ", "dim"))
		counts:child(T("the first " .. L.count(sum.total) .. " rows; the rest was not read", "warning"))
	elseif not sum.done then
		counts:child(T(" · ", "dim"))
		counts:child(b.div():row():items_center():gap(5):child(live_dot()):child(T("reading…", "info")))
	end
	line:child(counts)
	bar:child(line)
	if #S.terms > 0 or #S.unknown > 0 then
		local terms = b.div():row():wrap():gap(4):pl(16):pb(2)
		for index, term in ipairs(S.terms) do
			terms:child(chip(index, term))
		end
		for _, name in ipairs(S.unknown) do
			terms:child(
				b.div()
					:row()
					:items_center()
					:gap(4)
					:h(18)
					:px(7)
					:rounded(9)
					:bg(alpha("warning", 0.14))
					:text_size(SIZE.chip)
					:child(T("no column named ", "warning"))
					:child(T(L.cut(name, 40), "warning", nil, 600))
					:child(T(": looked for as a word", "warning"))
			)
		end
		bar:child(terms)
	end
	return b.div():col():no_shrink():child(bar):child(b.div():h(1):bg(L.line))
end

-- ---- the bottom line ------------------------------------------------------------------------------------------

K.HINTS = {
	{ id = "hint:mark", spec = "Tab", label = "mark" },
	{ id = "hint:send", spec = "Enter", label = "send" },
	{ id = "hint:back", spec = "Escape", label = "back" },
	{ id = "hint:palette", spec = "Mod-k", label = "commands" },
	{ id = "hint:help", spec = "F1", label = "help" },
}

function K.bar(narrow)
	local sum = S.sum
	local hints = b.div():row():items_center():gap(2):grow(1):min_w(0):clip()
	for i, hint in ipairs(K.HINTS) do
		if not narrow or i <= 3 then
			local level = L.glow(hint.id, L.ui.hover == hint.id)
			local el = b.div()
				:press(hint.id)
				:row()
				:items_center()
				:gap(4)
				:px(6)
				:h(20)
				:rounded(4)
				:no_shrink()
				:child(L.keys(hint.spec, true))
				:child(T(hint.label, level > 0 and L.mix("dim", "foreground", level) or "dim"))
			if level > 0 then
				el:bg(alpha("foreground", 0.05 * level))
			end
			hints:child(el)
		end
	end
	local rows = A.to_send()
	local hidden = sum.marked > 0 and (sum.hidden_marks or 0) or 0
	local label
	if S.sending then
		label = "Sending…"
	elseif sum.marked > 0 then
		label = "Send "
			.. L.plural(sum.marked, "row")
			.. (hidden > 0 and (" (" .. L.count(hidden) .. " not shown)") or "")
	elseif S.boot.confirm then
		label = "Mark the rows to send"
	elseif S.cursor ~= nil then
		label = "Send this row"
	else
		label = "Send"
	end
	local answers = b.div():row():items_center():gap(6):no_shrink()
	answers:child(L.button("nothing", "Send nothing", {
		icon = "undo-2",
		label = "Send nothing and end",
		disabled = S.sending,
		px = narrow and 6 or 10,
	}))
	answers:child(L.button("send", label, {
		tone = "primary",
		icon = "send",
		keys = "Enter",
		disabled = S.sending or rows == 0,
		warned = hidden > 0,
	}))
	return b.div()
		:col()
		:no_shrink()
		:child(b.div():h(1):bg(L.line))
		:child(b.div():row():items_center():gap(10):px(8):py(4):bg(L.chrome):child(hints):child(answers))
end

-- ---- over everything --------------------------------------------------------------------------------------

local function scrim(id)
	return b.div()
		:press(id)
		:absolute()
		:inset(0, 0, 0, 0)
		:bg(alpha("background", 0.5))
		:col()
		:items_center()
		:pt(math.floor(S.height * 0.08))
end

local function pop()
	return b.div()
		:col()
		:bg(L.raised)
		:rounded(10)
		:border(1, L.mix("border", "foreground", 0.1))
		:shadow(0, 18, 48, alpha("shadow", 0.55))
		:clip()
end

function K.palette()
	local shown = C.palette_shown()
	S.palette.chosen = math.clamp(S.palette.chosen, 1, math.max(#shown, 1))
	local width = math.min(560, S.width - 24)
	local box = pop():w(width):max_w(width)
	box:child(
		b.div():px(14):py(9):no_shrink():child(
			b.div():text_field("palette"):h(20):w_full():child(T("A command, or a column's name", "quiet", SIZE.query))
		)
	)
	box:child(b.div():h(1):bg(L.line):no_shrink())
	local list = b.div():id("palette"):col():p(4):scroll_y(L.ui:scroll_offset("palette"))
	list:h(math.min(math.max(#shown, 1) * 26 + 8, math.min(400, math.floor(S.height * 0.8) - 50)))
	if #shown == 0 then
		list:child(b.div():p(10):child(T("No command has those words.", "quiet")))
	end
	for i, command in ipairs(shown) do
		local id = "pal:" .. i
		local enabled = C.can_run(command)
		local row = b.div()
			:press(id)
			:row()
			:items_center()
			:gap(10)
			:h(26)
			:px(10)
			:rounded(6)
			:no_shrink()
			:opacity(enabled and 1 or 0.45)
		if i == S.palette.chosen then
			row:bg(L.cursor)
		end
		row:child(b.div():w(52):no_shrink():child(T(command.group, "quiet", SIZE.chip)))
		row:child(b.div():grow(1):min_w(0):child(T(command.title):truncate()))
		if command.keys and command.keys[1] then
			row:child(L.keys(command.keys[1], true))
		end
		list:child(row)
	end
	box:child(list)
	K.palette_list = shown
	return scrim("scrim"):child(box)
end

-- Scrolls the palette's list to the entry the cursor is on.
function K.palette_reveal()
	local top = (S.palette.chosen - 1) * 26
	local offset = L.ui:scroll_offset("palette")
	local extent = pencere.layout.scroll_extent("palette")
	local view = extent and extent.view or 300
	if top < offset then
		L.ui:set_scroll("palette", top)
	elseif top + 26 + 8 > offset + view then
		L.ui:set_scroll("palette", top + 26 + 8 - view)
	end
end

local MOUSE = {
	{ "Click", "put the cursor on the row" },
	{ "Click the box, or drag down the boxes", "mark, or unmark, the rows" },
	{ "⌘-click, ⇧-click", "mark one row; every row from the last one marked" },
	{ "Double-click", "send the row, when nothing is marked" },
	{ "Right-click", "what can be done with the row, its cell, or a heading" },
	{ "Click a heading", "order by it: up, down, then as it came" },
	{ "Drag a heading's edge", "make the column wider or narrower" },
	{ "Click a value in the column panel", "keep only the rows with it (⌘-click: or with it)" },
	{ "Drag across the chart", "keep only the rows in that range" },
}

local QUERY = {
	{ "word", "the row holds it, in any column, in any case" },
	{ "!word", "it does not" },
	{ '"two words"', "quotes keep spaces in a word or a value" },
	{ "STATUS=Running", "the column is that; =a|b either" },
	{ "STATUS!=Running", "it is not" },
	{ "NAME~web  NAME!~web", "it holds web, or does not" },
	{ "cpu>50  size>=1G  age<2h", "quantities compare as quantities" },
	{ "latency=100..400", "between, both ends included" },
}

local function help_row(what, does, code)
	local left = b.div():w(150):no_shrink()
	if type(what) == "string" then
		left:child(T(what, code and "info" or "dim"):wrap():max_w(150))
	else
		left:child(what)
	end
	return b.div():row():gap(10):py(2):no_shrink():child(left):child(b.div():grow(1):min_w(0):child(T(does):wrap()))
end

local function help_group(title)
	return b.div():col():no_shrink():child(T(string.upper(title), "accent", SIZE.chip, 600):mt(12):mb(4))
end

function K.help()
	local width = math.min(860, S.width - 24)
	local two = width >= 2 * 330 + 26
	local keys_col = b.div():col():grow(1):min_w(0)
	for _, group in ipairs(C.GROUPS) do
		local g = help_group(group)
		for _, command in ipairs(C.COMMANDS) do
			if command.group == group and command.keys and not string.find(command.id, "^order%-%d") then
				local caps = b.div():row():wrap():gap(4):items_center()
				for _, spec in ipairs(command.keys) do
					caps:child(L.keys(spec))
				end
				g:child(help_row(caps, command.title))
			end
		end
		if group == "Order" then
			g:child(
				help_row(
					b.div()
						:row()
						:items_center()
						:gap(4)
						:child(L.keys("Ctrl-1"))
						:child(T("…", "dim"))
						:child(L.keys("Ctrl-9")),
					"Order by the column at that place; again for the other way"
				)
			)
		end
		keys_col:child(g)
	end
	local other = b.div():col():grow(1):min_w(0)
	local mouse = help_group("The mouse")
	for _, pair in ipairs(MOUSE) do
		mouse:child(help_row(pair[1], pair[2]))
	end
	local query = help_group("The query")
	for _, pair in ipairs(QUERY) do
		query:child(help_row(pair[1], pair[2], true))
	end
	query:child(
		T(
				"Every term must hold. A column is named as its heading is, or with only its letters (cpu for %CPU). The same query, given to --where, chooses the same rows with no one to ask.",
				"quiet"
			)
			:wrap()
			:mt(8)
	)
	other:child(mouse):child(query)
	local columns = b.div():gap_x(26)
	if two then
		columns:row():items_start()
	else
		columns:col()
	end
	columns:child(keys_col):child(other)
	local box = pop():w(width)
	box:child(
		b.div()
			:row()
			:items_center()
			:gap(8)
			:px(18)
			:pt(14)
			:pb(10)
			:no_shrink()
			:child(T("Typing always goes to the query.", "foreground", nil, 700))
			:child(T("The commands are on keys that do not type.", "dim"):truncate():min_w(0):grow(1))
			:child(b.div():press("helpclose"):child(L.keys("Escape", true)))
	)
	box:child(b.div():h(1):ml(18):mr(18):bg(L.line2):no_shrink())
	box:child(
		b.div()
			:id("help")
			:col()
			:px(18)
			:pb(16)
			:h(math.min(math.floor(S.height * 0.84) - 60, 1400))
			:scroll_y(L.ui:scroll_offset("help"))
			:child(columns)
	)
	return scrim("scrim"):child(box)
end

function K.toast()
	local toast = S.toast
	return b.div():absolute():inset(nil, 0, 44, 0):row():justify_center():child(
		b.div()
			:id("toast")
			:px(12)
			:py(6)
			:rounded(6)
			:bg(L.raised)
			:border(1, alpha("border", 0.9))
			:shadow(0, 18, 48, alpha("shadow", 0.55))
			:max_w(S.width - 24)
			:motion({ seconds = 0.11, enter = { opacity = 0, dy = 4 } })
			:child(T(toast.text, toast.tone == "bad" and "error" or "foreground"):wrap())
	)
end

function K.banner()
	return b.div()
		:absolute()
		:inset(0, 0, nil, 0)
		:px(12)
		:py(6)
		:bg(L.mix("background", "error", 0.18))
		:child(T(S.error, "error"):wrap())
end

return K
