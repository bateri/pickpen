-- What the page sends is not trusted: each call says what it asks (a schema), and what does not
-- fit it is answered `bad-params`, never run. A schema is a function from a value to the value as
-- the program takes it, or to nil and the words for what is wrong. A key a call may leave out is
-- `optional`.
--
-- This is api/'s: the files of api/ know the page, and input/, query/, output/ and state/ do not.

local M = {}

local function describe(value)
	if value == nil then
		return "nothing"
	end
	return type(value)
end

local function wrong(path, words)
	local where = #path == 0 and "" or (table.concat(path, ".") .. ": ")
	return nil, where .. words
end

function M.string()
	return function(value, path)
		if type(value) ~= "string" then
			return wrong(path, "expected a string, got " .. describe(value))
		end
		return value
	end
end

local function whole(value)
	return type(value) == "number" and value == math.floor(value) and math.abs(value) < 2 ^ 53
end

function M.integer(minimum, maximum)
	return function(value, path)
		if not whole(value) then
			return wrong(path, "expected an integer, got " .. describe(value))
		end
		if minimum and value < minimum then
			return wrong(path, "expected at least " .. minimum)
		end
		if maximum and value > maximum then
			return wrong(path, "expected at most " .. maximum)
		end
		return value
	end
end

function M.boolean()
	return function(value, path)
		if type(value) ~= "boolean" then
			return wrong(path, "expected true or false, got " .. describe(value))
		end
		return value
	end
end

function M.enum(...)
	local names = { ... }
	return function(value, path)
		for _, name in ipairs(names) do
			if value == name then
				return value
			end
		end
		return wrong(path, "expected one of " .. table.concat(names, ", "))
	end
end

-- Not there is as good as there: for a key a call may leave out (a null arrives as nothing).
function M.optional(schema)
	return function(value, path)
		if value == nil then
			return nil, nil, true
		end
		return schema(value, path)
	end
end

function M.array(schema, longest)
	return function(value, path)
		if type(value) ~= "table" then
			return wrong(path, "expected a list, got " .. describe(value))
		end
		if longest and #value > longest then
			return wrong(path, "expected at most " .. longest .. " items")
		end
		local out = {}
		for index = 1, #value do
			path[#path + 1] = tostring(index)
			local item, why = schema(value[index], path)
			path[#path] = nil
			if why then
				return nil, why
			end
			out[index] = item
		end
		return out
	end
end

-- An object with these members; others it was sent are left out of what it gives.
function M.object(shape)
	local keys = {}
	for key in pairs(shape) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return function(value, path)
		if value == nil then
			value = {}
		end
		if type(value) ~= "table" then
			return wrong(path, "expected an object, got " .. describe(value))
		end
		local out = {}
		for _, key in ipairs(keys) do
			path[#path + 1] = key
			local item, why, absent = shape[key](value[key], path)
			path[#path] = nil
			if why then
				return nil, why
			end
			if not absent then
				out[key] = item
			end
		end
		return out
	end
end

-- The params a call was sent, as its schema takes them: the value, or nil and why not.
function M.parse(schema, value)
	return schema(value, {})
end

return M
