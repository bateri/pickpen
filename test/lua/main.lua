-- The entry of the Lua tests: the page against the kit's page API, with a stand-in for its program.
-- test/lua.test.mjs packs this into a program of pencere's Lua runner and runs it.

local t = require("t")

require("page_test")

t.run()
