-- Words written so that a POSIX shell reads them back as they were: what a preview command and
-- the command line that does a choice again are made of.

local M = {}

local find, gsub = string.find, string.gsub

-- A word as a POSIX shell reads it back: bare when it is safe, in single quotes otherwise (a
-- single quote in it closes the quotes, is written escaped, and opens them again).
function M.shell_quote(word)
	if word ~= "" and find(word, "^[A-Za-z0-9_@%%+=:,./-]+$") then
		return word
	end
	return "'" .. gsub(word, "'", "'\\''") .. "'"
end

return M
