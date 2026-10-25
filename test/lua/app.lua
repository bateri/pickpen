-- The Lua tests of pickpen: every file of the suite's directory registers tests with `t.test`,
-- and this runs them. `make test-lua` packs it with src/program/ (whose app.lua it replaces) and
-- runs it with the runner of the pencere command; `make test-binary` does the same for the tests
-- that run the built program.
--
--   test-run [suite [piece-of-a-test-name]]       suite: "cases" (default) or "binary"

local pencere = require("pencere")
local t = require("t")

local suite = pencere.args[1] or "cases"
for _, name in ipairs(pencere.app.list(suite)) do
	local module = string.match(name, "([^/]+)%.lua$")
	if module then
		require(suite .. "." .. module)
	end
end

pencere.exit(t.run(pencere.args[2]) == 0 and 0 or 1)
