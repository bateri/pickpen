-- A small test harness for the Lua tests: `test(name, fn)` collects, `run()` runs them and says
-- what happened in TAP, so that test/lua.test.mjs can make a test of each.

local pencere = require("pencere")

local M = {}

local tests = {}

function M.test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

local function show(value, depth)
	depth = depth or 0
	if type(value) == "string" then
		return string.format("%q", value)
	elseif type(value) ~= "table" then
		return tostring(value)
	elseif depth > 3 then
		return "{…}"
	end
	local keys = {}
	for key in pairs(value) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, key in ipairs(keys) do
		parts[#parts + 1] = (type(key) == "number" and "" or (tostring(key) .. " = ")) .. show(value[key], depth + 1)
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

local function same(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for key, value in pairs(a) do
		if not same(value, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- A failure that stops the test: `what` is what was meant.
local function fail(message)
	if #message > 700 then
		message = string.sub(message, 1, 700) .. " …"
	end
	error({ failed = message }, 0)
end

function M.eq(actual, expected, what)
	if not same(actual, expected) then
		fail((what and (what .. ": ") or "") .. "expected " .. show(expected) .. ", got " .. show(actual))
	end
end

function M.ok(value, what)
	if not value then
		fail(what or "expected something true")
	end
end

-- Whether a list of words has one that holds `needle` (plain).
function M.has(list, needle, what)
	for _, item in ipairs(list) do
		if string.find(item, needle, 1, true) then
			return
		end
	end
	fail((what and (what .. ": ") or "") .. "no " .. string.format("%q", needle) .. " among " .. show(list))
end

function M.lacks(list, needle, what)
	for _, item in ipairs(list) do
		if string.find(item, needle, 1, true) then
			fail((what and (what .. ": ") or "") .. "there is " .. string.format("%q", needle) .. " in " .. show(list))
		end
	end
end

-- Runs every test; prints TAP. Exits 1 when any failed.
function M.run()
	local failed = 0
	pencere.io.write("TAP version 13\n1.." .. #tests .. "\n")
	for index, one in ipairs(tests) do
		local ok, err = pcall(one.fn)
		if ok then
			pencere.io.write("ok " .. index .. " - " .. one.name .. "\n")
		else
			failed += 1
			local why = type(err) == "table" and err.failed or tostring(err)
			pencere.io.write("not ok " .. index .. " - " .. one.name .. "\n")
			for line in string.gmatch(why, "[^\n]+") do
				pencere.io.write("# " .. line .. "\n")
			end
		end
	end
	pencere.exit(failed == 0 and 0 or 1)
end

return M
