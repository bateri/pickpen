-- Every command of the page, with its keys: the keyboard runs them, the palette lists them, and the
-- help shows them, from this one list.
--
-- What is typed goes to the query, always, so no command is on a key that types: they are on the
-- arrows, Tab, Enter, Esc, the function keys, and ⌘ or ⌃ with a letter. The keys a terminal keeps for
-- itself (in bateri ⌘P ⌘W ⌘O ⌘T ⌘N ⌘D ⌘1–⌘9) and ⌥ with a letter (how a Mac types @ # [ { on many
-- layouts) are left alone.

local L = require("./lib")
local state = require("./state")
local S, A = state.S, state.A

local C = {}

local function has_rows()
	return A.shown() > 0
end

-- The columns shown, in order: what ⌃1 to ⌃9 count.
function C.visible_columns()
	local out = {}
	for column = 1, #(S.sum and S.sum.columns or {}) do
		if not S.hidden[column] then
			out[#out + 1] = column
		end
	end
	return out
end

C.GROUPS = { "Move", "Mark", "Send", "Order", "Panels", "Copy" }

C.COMMANDS = {
	{
		id = "down",
		title = "Next row",
		group = "Move",
		keys = { "ArrowDown", "Ctrl-n" },
		quiet = true,
		run = function()
			A.move(1)
		end,
	},
	{
		id = "up",
		title = "Previous row",
		group = "Move",
		keys = { "ArrowUp", "Ctrl-p" },
		quiet = true,
		run = function()
			A.move(-1)
		end,
	},
	{
		id = "page-down",
		title = "A page down",
		group = "Move",
		keys = { "PageDown" },
		quiet = true,
		run = function()
			A.page(1)
		end,
	},
	{
		id = "page-up",
		title = "A page up",
		group = "Move",
		keys = { "PageUp" },
		quiet = true,
		run = function()
			A.page(-1)
		end,
	},
	{
		id = "first",
		also = "top home beginning",
		title = "First row",
		group = "Move",
		keys = { "Mod-ArrowUp" },
		run = A.first,
	},
	{
		id = "last",
		also = "bottom end tail follow",
		title = "Last row, and follow new rows",
		group = "Move",
		keys = { "Mod-ArrowDown" },
		run = A.last,
	},

	{
		id = "mark",
		title = "Mark the row and go to the next",
		group = "Mark",
		keys = { "Tab" },
		run = function()
			A.mark_and_move(1)
		end,
	},
	{
		id = "mark-up",
		title = "Mark the row and go to the previous",
		group = "Mark",
		keys = { "Shift-Tab" },
		quiet = true,
		run = function()
			A.mark_and_move(-1)
		end,
	},
	{
		id = "extend-down",
		title = "Mark down from here",
		group = "Mark",
		keys = { "Shift-ArrowDown" },
		quiet = true,
		when = has_rows,
		run = function()
			A.extend(1)
		end,
	},
	{
		id = "extend-up",
		title = "Mark up from here",
		group = "Mark",
		keys = { "Shift-ArrowUp" },
		quiet = true,
		when = has_rows,
		run = function()
			A.extend(-1)
		end,
	},
	{
		id = "mark-shown",
		also = "select all check",
		title = "Mark every row shown",
		group = "Mark",
		keys = { "Mod-a" },
		run = function()
			A.mark_shown(true)
		end,
	},
	{
		id = "unmark",
		also = "deselect clear none uncheck",
		title = "Unmark every row",
		group = "Mark",
		keys = { "Shift-Mod-a" },
		run = A.unmark_all,
	},
	{
		id = "invert",
		also = "select toggle reverse",
		title = "Invert the marks of the rows shown",
		group = "Mark",
		run = A.invert,
	},
	{
		id = "unmark-shown",
		also = "deselect uncheck",
		title = "Unmark the rows shown",
		group = "Mark",
		run = function()
			A.mark_shown(false)
		end,
	},

	{
		id = "send",
		also = "choose accept ok done submit enter",
		title = "Send",
		group = "Send",
		keys = { "Enter" },
		when = function()
			return A.to_send() > 0
		end,
		run = function()
			A.send()
		end,
	},
	{
		id = "back",
		also = "escape clear",
		title = "Back: close, clear the query, then send nothing",
		group = "Send",
		keys = { "Escape" },
		run = A.back,
	},
	{
		id = "cancel",
		also = "quit exit abort close nothing",
		title = "Send nothing and end",
		group = "Send",
		run = A.cancel,
	},

	{
		id = "order-clear",
		also = "sort unsorted original",
		title = "Rows in the input's order",
		group = "Order",
		keys = { "Ctrl-0" },
		run = function()
			A.set_order(nil)
		end,
	},

	{
		id = "palette",
		title = "Commands",
		group = "Panels",
		keys = { "Mod-k" },
		run = function()
			C.open_palette()
		end,
	},
	{
		id = "help",
		also = "shortcuts keyboard f1 syntax",
		title = "Keys, the mouse and the query",
		group = "Panels",
		keys = { "F1" },
		run = function()
			S.overlay = "help"
			S.out.keyboard = "page"
		end,
	},
	{
		id = "panel",
		also = "inspector sidebar preview details",
		title = "Show or hide the side panel",
		group = "Panels",
		keys = { "Mod-i" },
		run = A.toggle_panel,
	},
	{
		id = "tab-row",
		also = "preview details fields",
		title = "The row the cursor is on",
		group = "Panels",
		keys = { "F2" },
		run = function()
			A.open_tab("row")
		end,
	},
	{
		id = "tab-column",
		also = "histogram chart distribution values facets",
		title = "A column: its values, and a chart of its quantities",
		group = "Panels",
		keys = { "F3" },
		run = function()
			A.open_tab("column")
		end,
	},
	{
		id = "tab-output",
		also = "stdout result command again script",
		title = "What goes out, and the command that does it again",
		group = "Panels",
		keys = { "F4" },
		run = function()
			A.open_tab("output")
		end,
	},

	{
		id = "copy-row",
		also = "clipboard",
		title = "Copy the row",
		group = "Copy",
		keys = { "Mod-c" },
		when = function()
			return S.cursor ~= nil
		end,
		run = function()
			A.copy_row()
		end,
	},
	{
		id = "copy-command",
		also = "clipboard script cron",
		title = "Copy the command that does it again",
		group = "Copy",
		run = A.copy_command,
	},
}

for n = 1, 9 do
	C.COMMANDS[#C.COMMANDS + 1] = {
		id = "order-" .. n,
		title = "Order by column " .. n .. ", again for the other way",
		group = "Order",
		keys = { "Ctrl-" .. n },
		quiet = true,
		when = function()
			return #C.visible_columns() >= n
		end,
		run = function()
			local column = C.visible_columns()[n]
			if column then
				A.cycle_order(column)
			end
		end,
	}
end

function C.open_palette()
	S.overlay = "palette"
	S.palette = { text = "", chosen = 1 }
	S.out.fill = { palette = "" }
	S.out.keyboard = { field = "palette" }
end

-- The palette's commands: the fixed ones, how words are looked for, and one for each thing a
-- column offers.
function C.palette_commands()
	local out = {}
	for _, command in ipairs(C.COMMANDS) do
		if not command.quiet then
			out[#out + 1] = command
		end
	end
	local fuzzy = S.sum and S.sum.fuzzy
	out[#out + 1] = {
		id = "fuzzy",
		title = fuzzy and "Words as they are typed, not fuzzy"
			or "Fuzzy words: their letters in order, best matches first",
		also = "fzf fuzzy exact approximate letters",
		group = "Order",
		run = function()
			A.set_fuzzy(not fuzzy)
		end,
	}
	for column, name in ipairs(S.sum and S.sum.columns or {}) do
		out[#out + 1] = {
			id = "sort:" .. column,
			title = "Order by " .. name .. ", smallest or A first",
			also = "sort ascending",
			group = "Order",
			run = function()
				A.set_order({ column = column, descending = false })
			end,
		}
		out[#out + 1] = {
			id = "sort-down:" .. column,
			title = "Order by " .. name .. ", largest or Z first",
			also = "sort descending reverse",
			group = "Order",
			run = function()
				A.set_order({ column = column, descending = true })
			end,
		}
		out[#out + 1] = {
			id = "column:" .. column,
			title = "Look at the column " .. name,
			also = "histogram chart values",
			group = "Panels",
			run = function()
				A.show_column(column)
			end,
		}
		out[#out + 1] = {
			id = "field:" .. column,
			title = "Send the column " .. name .. " (or stop sending it)",
			also = "field output only",
			group = "Send",
			run = function()
				A.toggle_field(name)
			end,
		}
		out[#out + 1] = {
			id = "hide:" .. column,
			title = (S.hidden[column] and "Show" or "Hide") .. " the column " .. name,
			group = "Panels",
			run = function()
				S.hidden[column] = (not S.hidden[column]) or nil
			end,
		}
	end
	return out
end

-- The palette's commands that hold every word typed.
function C.palette_shown()
	local words = {}
	for word in string.gmatch(string.lower(S.palette.text), "%S+") do
		words[#words + 1] = word
	end
	local out = {}
	for _, command in ipairs(C.palette_commands()) do
		local hay = string.lower(command.title .. " " .. command.group .. " " .. (command.also or ""))
		local all = true
		for _, word in ipairs(words) do
			if not string.find(hay, word, 1, true) then
				all = false
				break
			end
		end
		if all then
			out[#out + 1] = command
		end
	end
	return out
end

function C.can_run(command)
	return command.when == nil or command.when()
end

-- Runs the command of a key, when there is one: whether there was.
function C.run_key(key, mods)
	for _, command in ipairs(C.COMMANDS) do
		for _, spec in ipairs(command.keys or {}) do
			if L.matches(key, mods, spec) and C.can_run(command) then
				command.run()
				return true
			end
		end
	end
	return false
end

return C
