-- The little test framework of the Lua tests: `t.test(name, fn)` registers a test, the `t.eq`
-- family checks, and `t.run()` runs what was registered and says how it went.

local t = {}

local tests = {}

-- Registers a test; `fn` fails by raising (the checks below do).
function t.test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

-- A value as a failure message shows it: tables in order, strings quoted.
local function show(value, seen)
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) ~= "table" then
		return tostring(value)
	end
	seen = seen or {}
	if seen[value] then
		return "<cycle>"
	end
	seen[value] = true
	local keys = {}
	for key in pairs(value) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then
			return a < b
		end
		return type(a) < type(b)
	end)
	local parts = {}
	for _, key in ipairs(keys) do
		local label = type(key) == "number" and "" or (tostring(key) .. " = ")
		parts[#parts + 1] = label .. show(value[key], seen)
	end
	seen[value] = nil
	return "{ " .. table.concat(parts, ", ") .. " }"
end
t.show = show

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

-- Deep equality (plain tables by their keys; metatables are not looked at).
function t.eq(actual, expected, note)
	if not same(actual, expected) then
		local prefix = note and (note .. ": ") or ""
		error(prefix .. "expected " .. show(expected) .. ", got " .. show(actual), 2)
	end
end

function t.ok(value, note)
	if not value then
		error(note or "expected something true", 2)
	end
end

-- The function raises, and the message holds `pattern` (a plain text, not a pattern).
function t.raises(fn, text)
	local ok, err = pcall(fn)
	if ok then
		error("expected an error", 2)
	end
	local said = type(err) == "table" and (err.message or err.code) or err
	if text and not string.find(tostring(said), text, 1, true) then
		error("expected an error holding " .. show(text) .. ", got " .. show(err), 2)
	end
end

-- Runs every test; gives the number that failed.
function t.run(only)
	local failed = 0
	for _, case in ipairs(tests) do
		if not only or string.find(case.name, only, 1, true) then
			local ok, err = pcall(case.fn)
			if ok then
				print("ok     " .. case.name)
			else
				failed += 1
				print("FAILED " .. case.name)
				print("       " .. tostring(type(err) == "table" and show(err) or err))
			end
		end
	end
	print(string.format("%d tests, %d failed", #tests, failed))
	return failed
end

return t
