-- What every file of the page shares: the kit's builders, the one `Ui` that remembers the pointer
-- and the scrolling between frames, the sizes, the colours mixed from the theme's roles, and the
-- small pieces a screen is made of (a line of text, an icon, keys as the Mac writes them, a button
-- that never takes the keyboard from the query).

local b = pencere
local alpha, mix = b.alpha, b.mix

local L = { b = b, alpha = alpha, mix = mix, ui = b.Ui.new() }

-- Sizes in points: the page is in the terminal's font, at the size of the web page's.
L.SIZE = {
	ui = 12, -- the words of the page
	cell = 12.5, -- the words of a row
	query = 13,
	small = 11.5,
	chip = 11,
	tiny = 10.5,
	row = 22, -- a row of the list
	head = 26, -- the line of headings over it
	mark = 30, -- the box in front of a row
	bar = 34, -- the line of keys at the bottom
	tabs = 30, -- the tabs of the side panel
	pad = 8, -- the room at each side of a cell
}

-- How wide a character of the terminal's font is at `size`: a little over a half of the size.
function L.char_width(size)
	return (size or L.SIZE.cell) * 0.6
end

-- The grounds of the web page, mixed from the theme: the bars a little above the page, a pop-up a
-- step above, and the highlights of the rows.
L.chrome = mix("background", "raised1", 0.3)
L.raised = "raised2"
L.hover = alpha("foreground", 0.05)
L.press = alpha("foreground", 0.1)
L.cursor = alpha("accent", 0.16)
L.marked = alpha("accent", 0.09)
L.marked_cursor = alpha("accent", 0.24)
L.match = alpha("warning", 0.3)
L.line = "border"
L.line2 = alpha("border", 0.6)

-- The longest line of text the page makes (the kit takes 64 KiB, and ends a page that makes more).
local LINE_MOST = 2000

-- `text` cut to at most `most` characters, ending in `…` where it was longer; never in the middle of
-- a character.
function L.cut(text, most)
	if #text <= most then
		return text
	end
	local stop = utf8.offset(text, most + 1)
	if stop == nil then
		return text
	end
	return string.sub(text, 1, stop - 1) .. "…"
end

-- A line of text in a role, a size and a weight.
function L.T(content, color, size, weight)
	if type(content) == "string" and #content > LINE_MOST then
		content = L.cut(content, LINE_MOST)
	end
	local t = b.text(content)
	if color then
		t:color(color)
	end
	if size then
		t:text_size(size)
	end
	if weight then
		t:weight(weight)
	end
	return t
end

-- An icon of src/assets/icons/ (Lucide's), `size` points square, in a role of the theme.
function L.icon(name, size, role)
	size = size or 14
	return b.image("assets/icons/" .. name .. ".svg"):size(size, size):tint(role or "dim"):no_shrink()
end

-- pickpen's mark: three rows, the first and the last of them chosen.
function L.mark(size)
	size = size or 14
	return b.image("assets/mark.svg"):size(size, size):tint("accent"):no_shrink()
end

-- A count as a person reads it: 12,480.
function L.count(n)
	local s = tostring(math.floor(n))
	local sign = ""
	if string.sub(s, 1, 1) == "-" then
		sign, s = "-", string.sub(s, 2)
	end
	local out = ""
	while #s > 3 do
		out = "," .. string.sub(s, -3) .. out
		s = string.sub(s, 1, -4)
	end
	return sign .. s .. out
end

function L.plural(n, one, many)
	return L.count(n) .. " " .. (n == 1 and one or (many or (one .. "s")))
end

-- ---- keys ----------------------------------------------------------------------------------------

-- The keys of a command are named as the web page named them: `Mod-k`, `Shift-Mod-a`, `Ctrl-1`,
-- `F1`, `ArrowDown`. `Mod` is ⌘: the terminal that shows the page is a Mac's.

local GLYPHS = { Mod = "⌘", Cmd = "⌘", Ctrl = "⌃", Alt = "⌥", Shift = "⇧" }
local ORDER = { "Ctrl", "Alt", "Shift", "Mod", "Cmd" }
local KEY_NAMES = {
	arrowup = "↑",
	arrowdown = "↓",
	arrowleft = "←",
	arrowright = "→",
	enter = "⏎",
	escape = "Esc",
	backspace = "⌫",
	tab = "⇥",
	space = "Space",
	pageup = "PgUp",
	pagedown = "PgDn",
	home = "Home",
	["end"] = "End",
}

local function split(spec)
	local parts = {}
	for part in string.gmatch(spec, "[^-]+") do
		parts[#parts + 1] = part
	end
	local key = table.remove(parts)
	return parts, key
end

-- The parts of a key as the Mac writes them: `{ "⌘", "K" }`.
function L.glyphs(spec)
	local parts, key = split(spec)
	local has = {}
	for _, part in ipairs(parts) do
		has[part] = true
	end
	local out = {}
	for _, mod in ipairs(ORDER) do
		if has[mod] then
			out[#out + 1] = GLYPHS[mod]
		end
	end
	local name = KEY_NAMES[string.lower(key)] or (#key == 1 and string.upper(key) or key)
	out[#out + 1] = name
	return out
end

-- A key as one string: `⌘K`.
function L.label(spec)
	return table.concat(L.glyphs(spec), "")
end

-- A key drawn as keycaps; `quiet` ones are its glyphs alone, in the quiet role.
function L.keys(spec, quiet, ink)
	local row = b.div():row():items_center():gap(quiet and 1 or 2):no_shrink()
	for _, part in ipairs(L.glyphs(spec)) do
		if quiet then
			row:child(L.T(part, ink or "quiet", L.SIZE.tiny))
		else
			row:child(
				b.div()
					:row()
					:items_center()
					:justify_center()
					:min_w(15)
					:h(16)
					:px(4)
					:rounded(3)
					:bg(alpha("foreground", 0.08))
					:child(L.T(part, "dim", L.SIZE.tiny))
			)
		end
	end
	return row
end

-- What an event says of the modifiers, and what a spec asks for: whether they are the same key.
-- A letter is matched in either case; `+`, `?` and the like are typed with ⇧, so ⇧ does not count
-- against them.
local SHIFTED = { ["+"] = true, ["?"] = true, ["`"] = true, ["~"] = true }
local EVENT_KEYS = {
	up = "arrowup",
	down = "arrowdown",
	left = "arrowleft",
	right = "arrowright",
	page_up = "pageup",
	page_down = "pagedown",
	[" "] = "space",
}

function L.key_name(key)
	return EVENT_KEYS[key] or string.lower(key)
end

function L.matches(key, mods, spec)
	mods = mods or {}
	local parts, want = split(spec)
	local need = { ctrl = false, alt = false, shift = false, meta = false }
	for _, part in ipairs(parts) do
		if part == "Mod" or part == "Cmd" then
			need.meta = true
		elseif part == "Ctrl" then
			need.ctrl = true
		elseif part == "Alt" then
			need.alt = true
		elseif part == "Shift" then
			need.shift = true
		end
	end
	if (mods.control == true) ~= need.ctrl or (mods.alt == true) ~= need.alt or (mods.command == true) ~= need.meta then
		return false
	end
	want = string.lower(want)
	if (mods.shift == true) ~= need.shift and not SHIFTED[want] then
		return false
	end
	return L.key_name(key) == want
end

-- ---- highlights ------------------------------------------------------------------------------------

-- How far the highlight named `key` has come, 0 to 1: a ground the pointer brings comes and goes over
-- the kit's fade instead of switching, as the web page's did over its transition.
function L.glow(key, on)
	local name = "glow:" .. key
	if L.reduce_motion then
		L.ui.fades:snap(name, on and 1 or 0)
	else
		L.ui.fades:to(name, on and 1 or 0)
	end
	return L.ui.fades:level(name)
end

function L.hovered(id)
	return L.ui.hover == id
end

-- The ground of something the pointer can press: the hover's, faded in and out.
function L.hover_bg(id, strength)
	local level = L.glow(id, L.ui.hover == id)
	if L.ui.pressed == id and L.ui.hover == id then
		return L.press
	end
	if level <= 0 then
		return nil
	end
	return alpha("foreground", (strength or 0.05) * level)
end

-- A button of the bottom line or a pop-up: `o.tone` is "primary" or "quiet", `o.keys` a key drawn
-- after its words, `o.icon` the icon before them.
function L.button(id, label, o)
	o = o or {}
	local level = L.glow(id, L.ui.hover == id and not o.disabled)
	local down = L.ui.pressed == id and L.ui.hover == id and not o.disabled
	local el = b.div():row():items_center():gap(6):h(26):px(o.px or 10):rounded(6):no_shrink()
	local ink = "dim"
	if o.tone == "primary" then
		if o.disabled then
			el:bg(alpha("foreground", 0.1))
			ink = "quiet"
		else
			el:bg(level > 0 and mix("accent", "foreground", 0.12 * level) or "accent")
			ink = "background"
		end
		if o.warned then
			el:child(b.div():absolute():inset(-2, -2, -2, -2):rounded(8):border(2, alpha("warning", 0.6)))
		end
	else
		if o.disabled then
			ink = "quiet"
		else
			ink = level > 0 and mix("dim", "foreground", level) or "dim"
			if down then
				el:bg(L.press)
			elseif level > 0 then
				el:bg(alpha("foreground", 0.05 * level))
			end
		end
	end
	if not o.disabled then
		el:press(id)
	end
	if o.label then
		el:label(o.label):tip(o.label, o.keys and L.label(o.keys) or nil)
	end
	if o.icon then
		el:child(L.icon(o.icon, 14, ink))
	end
	el:child(L.T(label, ink, L.SIZE.ui, o.tone == "primary" and 600 or nil))
	if o.keys then
		el:child(L.keys(o.keys, true, o.tone == "primary" and not o.disabled and alpha("background", 0.7) or "quiet"))
	end
	return el
end

-- A small round button that is an icon alone: a chip's ×, the panel's close, the copy of a command.
function L.icon_button(id, name, size, box, words)
	local level = L.glow(id, L.ui.hover == id)
	local el = b.div()
		:press(id)
		:row()
		:items_center()
		:justify_center()
		:size(box, box)
		:rounded(box / 2 >= 10 and 4 or box / 2)
		:no_shrink()
		:child(L.icon(name, size, level > 0 and mix("quiet", "foreground", level) or "quiet"))
	if level > 0 then
		el:bg(alpha("foreground", 0.1 * level))
	end
	if words then
		el:label(words):tip(words)
	end
	return el
end

return L
