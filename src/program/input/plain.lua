-- Colour and other terminal codes: dropped, from what is shown and from what goes out.
--
-- What goes is the escape sequences of a terminal, whole: `ESC [ ... final` (colours, cursor
-- moves), `ESC ] ... BEL` or `ESC ] ... ESC \` (a title, a link), and the two-byte ones such as
-- `ESC M`. An ESC that begins none of them stays, as it is no code anyone can name.

local M = {}

local byte, find, sub, concat = string.byte, string.find, string.sub, table.concat

-- How many bytes the code that begins at the escape `at` takes, or nil when none begins there.
local function code_length(text, at)
	local b = byte(text, at + 1)
	if b == 91 then
		-- `[`: parameters (0-?), intermediates (space to /), and a final byte (@ to ~).
		local _, stop = find(text, "^[0-?]*[ -/]*[@-~]", at + 2)
		return stop and (stop - at + 1)
	elseif b == 93 then
		-- `]`: up to a bell, or to ESC \. Else it is a two-byte code, ESC ].
		local stop = find(text, "[\7\27]", at + 2)
		if stop then
			if byte(text, stop) == 7 then
				return stop - at + 1
			elseif byte(text, stop + 1) == 92 then
				return stop - at + 2
			end
		end
		return 2
	elseif b and ((b >= 64 and b <= 90) or (b >= 92 and b <= 95)) then
		return 2
	end
	return nil
end

function M.plain(text)
	local at = find(text, "\27", 1, true)
	if not at then
		return text
	end
	local parts, n, from = {}, 0, 1
	while at do
		local length = code_length(text, at)
		if length then
			n += 1
			parts[n] = sub(text, from, at - 1)
			from = at + length
			at = find(text, "\27", from, true)
		else
			at = find(text, "\27", at + 1, true)
		end
	end
	n += 1
	parts[n] = sub(text, from)
	return concat(parts)
end

return M
