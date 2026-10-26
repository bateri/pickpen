-- Colour codes in what a preview command prints (`git show --color`, `ls --color`), as runs of text
-- with a style. The sixteen colours are the terminal's own, from its theme; the 256 are folded onto
-- them, and the 24-bit ones are as written.

local ansi = {}

local ANSI_ROLES = {
	[0] = "black",
	"red",
	"green",
	"yellow",
	"blue",
	"magenta",
	"cyan",
	"white",
	"bright-black",
	"bright-red",
	"bright-green",
	"bright-yellow",
	"bright-blue",
	"bright-magenta",
	"bright-cyan",
	"bright-white",
}

-- The 256-colour cube folded onto the sixteen colours the theme has.
local function fold256(value)
	if value < 16 then
		return value
	end
	if value >= 232 then
		return value > 243 and 7 or 8
	end
	local v = value - 16
	local r, g, bl = v // 36, (v % 36) // 6, v % 6
	local bright = math.max(r, g, bl) > 3 and 8 or 0
	local index = (r > 2 and 1 or 0) + (g > 2 and 2 or 0) + (bl > 2 and 4 or 0)
	return index == 0 and (bright > 0 and 8 or 0) or index + bright
end

-- Whether a line has an escape in it.
function ansi.has(text)
	return string.find(text, "\27", 1, true) ~= nil
end

-- The text without what an escape says.
function ansi.strip(text)
	if not ansi.has(text) then
		return text
	end
	text = string.gsub(text, "\27%[[%d;?]*%a", "")
	text = string.gsub(text, "\27%][^\7\27]*[\7\27]\\?", "")
	return text
end

-- A line as runs of one style each: `{ text =, fg =, bg =, bold =, dim =, italic =, underline = }`.
-- Everything else an escape can do is dropped.
function ansi.runs(text)
	text = string.gsub(text, "\t", "    ")
	if not ansi.has(text) then
		return { { text = text } }
	end
	local runs = {}
	local style = {}
	local at = 1
	local function push(upto)
		if upto >= at then
			local piece = string.sub(text, at, upto)
			if piece ~= "" then
				runs[#runs + 1] = {
					text = piece,
					fg = style.fg,
					bold = style.bold,
					dim = style.dim,
					italic = style.italic,
					underline = style.underline,
					bg = style.bg,
				}
			end
		end
	end
	while true do
		local from, to, params, command = string.find(text, "\27%[([%d;?]*)(%a)", at)
		if from == nil then
			break
		end
		push(from - 1)
		at = to + 1
		if command == "m" then
			local codes = {}
			for number in string.gmatch(params, "%d+") do
				codes[#codes + 1] = tonumber(number)
			end
			if #codes == 0 then
				codes[1] = 0
			end
			local i = 1
			while i <= #codes do
				local code = codes[i]
				if code == 0 then
					style = {}
				elseif code == 1 then
					style.bold = true
				elseif code == 2 then
					style.dim = true
				elseif code == 3 then
					style.italic = true
				elseif code == 23 then
					style.italic = nil
				elseif code == 4 then
					style.underline = true
				elseif code == 22 then
					style.bold, style.dim = nil, nil
				elseif code == 24 then
					style.underline = nil
				elseif code >= 30 and code <= 37 then
					style.fg = ANSI_ROLES[code - 30]
				elseif code >= 90 and code <= 97 then
					style.fg = ANSI_ROLES[code - 90 + 8]
				elseif code >= 40 and code <= 47 then
					style.bg = ANSI_ROLES[code - 40]
				elseif code >= 100 and code <= 107 then
					style.bg = ANSI_ROLES[code - 100 + 8]
				elseif code == 39 then
					style.fg = nil
				elseif code == 49 then
					style.bg = nil
				elseif (code == 38 or code == 48) and codes[i + 1] == 5 then
					local role = ANSI_ROLES[fold256(codes[i + 2] or 0)]
					if code == 38 then
						style.fg = role
					else
						style.bg = role
					end
					i += 2
				elseif (code == 38 or code == 48) and codes[i + 1] == 2 then
					local value =
						string.format("#%02x%02x%02x", codes[i + 2] or 0, codes[i + 3] or 0, codes[i + 4] or 0)
					if code == 38 then
						style.fg = value
					else
						style.bg = value
					end
					i += 4
				end
				i += 1
			end
		end
	end
	push(#text)
	if #runs == 0 then
		runs[1] = { text = "" }
	end
	return runs
end

return ansi
