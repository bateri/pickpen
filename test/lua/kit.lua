-- The kit's page API, as a terminal gives it to a page: the prelude of pencere's kit (the Lua that
-- is built into the interpreter a terminal runs pages with), loaded over a stand-in for the host's
-- own functions. A page is run in it as it is in a terminal, except that nothing is laid out:
-- what the page asks of the layout (`pencere.layout`) is answered by what a test says.
--
-- The prelude is read from a pencere checkout (PENCERE_PRELUDE, the Makefile's PRELUDE), so that the
-- page is held to the kit that is, not to a copy of it.

local runner = require("pencere")

local M = {}

-- The parts of the prelude: every Lua file of its directory, in the order of their names, as pencere
-- builds them into the interpreter (kit/luau/build.sh), so that a part the kit gains is loaded too.
local function parts(prelude_dir)
	local list = {}
	for _, entry in ipairs(runner.fs.list(prelude_dir)) do
		local name = string.match(entry.name, "^(.*)%.lua$")
		if name and entry.kind == "file" then
			list[#list + 1] = name
		end
	end
	return list
end

-- The globals a page may use: the ones the kit's interpreter gives it. Anything else is a name the
-- page misspelt or a local it forgot, which Luau would not catch until the line ran.
local function strict_globals()
	return setmetatable({}, {
		__index = function(_, name)
			local value = _G[name]
			if value == nil then
				error("the page reads a global that does not exist: " .. tostring(name), 2)
			end
			return value
		end,
	})
end

-- The path of what `request` names, from the file `from` (both relative to the view's directory):
-- `./x` and `../x`, by Luau's rules for requiring by string.
local function resolve(from, request)
	assert(
		string.sub(request, 1, 2) == "./" or string.sub(request, 1, 3) == "../",
		"require: not a relative path: " .. request
	)
	local parts = {}
	for part in string.gmatch(from, "[^/]+") do
		parts[#parts + 1] = part
	end
	parts[#parts] = nil
	for part in string.gmatch(request, "[^/]+") do
		if part == ".." then
			assert(#parts > 0, "require: out of the view: " .. request)
			parts[#parts] = nil
		elseif part ~= "." then
			parts[#parts + 1] = part
		end
	end
	return table.concat(parts, "/")
end

-- The page, loaded as a terminal loads it: `page.lua` of the view's directory, which requires the
-- other scripts of the directory, each run once with globals of its own (the kit's, and nothing it
-- did not give), a cycle an error.
function M.load_page(page_path)
	local dir = string.match(page_path, "^(.*)/[^/]*$")
	local loaded, loading = {}, {}
	local function load(name, chain)
		if loaded[name] ~= nil then
			return loaded[name]
		end
		assert(not loading[name], "require cycle: " .. table.concat(chain, " -> ") .. " -> " .. name)
		loading[name] = true
		chain[#chain + 1] = name
		local file, source
		for _, candidate in ipairs({ name .. ".luau", name .. ".lua", name .. "/init.luau", name .. "/init.lua" }) do
			local ok, text = pcall(runner.fs.read, dir .. "/" .. candidate)
			if ok and text then
				file, source = candidate, text
				break
			end
		end
		assert(source, "require: no script at " .. name)
		local chunk, err = loadstring(source, "@" .. file)
		assert(chunk, err)
		local env = strict_globals()
		rawset(env, "require", function(request)
			return load(resolve(file, request), chain)
		end)
		setfenv(chunk, env)
		local value = chunk()
		chain[#chain] = nil
		loading[name] = nil
		loaded[name] = value == nil and true or value
		return loaded[name]
	end
	return load("page", {})
end

local Kit = {}
Kit.__index = Kit

-- A kit with the page at `page_path` started in it.
function M.start(prelude_dir, page_path)
	local self =
		setmetatable({ sent = {}, taken = 0, hit_id = nil, extents = {}, bounds_of = {}, offsets = {}, asks = {} }, Kit)
	-- What the host gives the interpreter, before the prelude takes it over.
	local globals = {
		send = function(text)
			self.sent[#self.sent + 1] = text
			return true
		end,
		hit = function()
			return self.hit_id
		end,
		ids_at = function()
			return self.hit_id and { self.hit_id } or {}
		end,
		bounds = function(id)
			return self.bounds_of[id]
		end,
		scroll_extent = function(id)
			local extent = self.extents[id]
			if extent then
				-- A test says how far a box reaches down, and across; unsaid, across it reaches no
				-- further than it is. How far it is scrolled is the stand-in host's.
				local content_w, view_w = extent.content_w or 0, extent.view_w or 0
				local at = self.offsets[id] or { x = 0, y = 0 }
				return {
					content = extent.content,
					view = extent.view,
					content_w = content_w,
					view_w = view_w,
					offset = at.y,
					offset_x = at.x,
				}
			end
			return nil
		end,
		-- The host does what the page asks at once, within the box's reach where the test said it.
		scroll_to = function(id, x, y, animate)
			self.asks[#self.asks + 1] = { id = id, x = x, y = y, animate = animate }
			self:move_to(id, x, y)
		end,
		focus_order = function()
			return {}
		end,
		path_of = function()
			return {}
		end,
		-- Nothing on the stand-in's page can be dragged, or have something dropped on it.
		drag_source = function()
			return nil
		end,
		drop_target = function()
			return nil
		end,
	}
	pencere = globals
	for _, name in ipairs(parts(prelude_dir)) do
		local source = runner.fs.read(prelude_dir .. "/" .. name .. ".lua")
		local chunk, err = loadstring(source, "@" .. name)
		assert(chunk, err)
		chunk()
	end
	self.page = M.load_page(page_path)
	pencere.start(self.page)
	self.kit = pencere
	return self
end

function Kit:render(width, height, now)
	self.now = now or self.now or 100
	local root, animating, wake = pencere.render(width or 1200, height or 700, self.now, false)
	self.root = root
	return root, animating, wake
end

-- The host laid the page out: what depends on the layout is brought within it. Whether the page
-- wants to be rendered again.
function Kit:settle()
	return pencere.settle()
end

function Kit:event(event)
	event.mods = event.mods or {}
	return pencere.handle(event)
end

-- The host has the box `id` at `x` across and `y` down (nil: where it is), within its reach.
function Kit:move_to(id, x, y)
	local at = self.offsets[id] or { x = 0, y = 0 }
	local extent = self.extents[id]
	local reach_y = extent and math.max(0, extent.content - extent.view) or math.huge
	local reach_x = extent and math.max(0, (extent.content_w or 0) - (extent.view_w or 0)) or math.huge
	self.offsets[id] = {
		x = math.clamp(x or at.x, 0, reach_x),
		y = math.clamp(y or at.y, 0, reach_y),
	}
end

-- The wheel over the box `id`: the host scrolls it by `dx` and `dy`, and tells the page where it went.
function Kit:wheel(id, dx, dy)
	local at = self.offsets[id] or { x = 0, y = 0 }
	self:move_to(id, at.x + (dx or 0), at.y + (dy or 0))
	local now = self.offsets[id]
	return self:event({ type = "scrolled", boxes = { { id = id, x = now.x, y = now.y } } })
end

function Kit:key(name, mods)
	return self:event({ type = "key", key = name, mods = mods or {} })
end

-- A click on the element named `id`: the pointer is over it when it goes down and when it comes up.
function Kit:click(id, button, mods)
	self.hit_id = id
	self:event({ type = "move", x = 10, y = 10 })
	self:event({ type = "press", x = 10, y = 10, button = button or "left", mods = mods or {} })
	local reply = self:event({ type = "release", x = 10, y = 10, button = button or "left" })
	self.hit_id = nil
	return reply
end

function Kit:text(words)
	return self:event({ type = "text", text = words })
end

-- What the program is told since the last time this was asked: each message, decoded.
function Kit:told()
	local list = {}
	for index = self.taken + 1, #self.sent do
		list[#list + 1] = pencere.json.decode(self.sent[index])
	end
	self.taken = #self.sent
	return list
end

-- Every message the page has said, decoded.
function Kit:all_told()
	local list = {}
	for index, text in ipairs(self.sent) do
		list[index] = pencere.json.decode(text)
	end
	return list
end

local function find_call(self, method)
	for index = #self.sent, 1, -1 do
		local message = pencere.json.decode(self.sent[index])
		if message.call and message.call.method == method then
			return message.call
		end
	end
	return nil
end

-- The program answers the last call of `method` with `result`.
function Kit:answer(method, result)
	local call = find_call(self, method)
	assert(call, "the page has not asked " .. method)
	pencere.message(pencere.json.encode({ response = { id = call.id, result = result } }))
end

function Kit:fail(method, code, message)
	local call = find_call(self, method)
	assert(call, "the page has not asked " .. method)
	pencere.message(pencere.json.encode({ response = { id = call.id, error = { code = code, message = message } } }))
end

-- The last call of `method` the page made, with its params.
function Kit:last_call(method)
	return find_call(self, method)
end

function Kit:calls_of(method)
	local list = {}
	for _, message in ipairs(self:all_told()) do
		if message.call and message.call.method == method then
			list[#list + 1] = message.call
		end
	end
	return list
end

-- The program pushes `value` to the page's subscription to `topic`.
function Kit:push(topic, value)
	for index = #self.sent, 1, -1 do
		local message = pencere.json.decode(self.sent[index])
		if message.subscribe and message.subscribe.topic == topic then
			pencere.message(pencere.json.encode({ push = { id = message.subscribe.id, value = value } }))
			return
		end
	end
	error("the page has not subscribed to " .. topic)
end

-- Whether the page listens to `topic` now: it subscribed and has not cancelled.
function Kit:subscribed(topic)
	local active = {}
	for _, message in ipairs(self:all_told()) do
		if message.subscribe then
			active[message.subscribe.id] = message.subscribe.topic
		elseif message.cancel then
			active[message.cancel.id] = nil
		end
	end
	for _, name in pairs(active) do
		if name == topic then
			return true
		end
	end
	return false
end

-- ---- reading a page ---------------------------------------------------------------------------

-- Every line of text of the page, in the order it is written.
function M.texts(root)
	local list = {}
	local function walk(element)
		if element.kind == "text" and element.text then
			list[#list + 1] = element.text
		end
		for _, child in ipairs(element.kids or {}) do
			walk(child)
		end
	end
	walk(root)
	return list
end

-- How many elements the page is made of.
function M.count(root)
	local n = 0
	local function walk(element)
		n += 1
		for _, child in ipairs(element.kids or {}) do
			walk(child)
		end
	end
	walk(root)
	return n
end

-- The elements that answer the pointer, by their names.
function M.pressables(root)
	local set = {}
	local function walk(element)
		if element.meta and element.meta.pressable then
			set[element.meta.id] = true
		end
		for _, child in ipairs(element.kids or {}) do
			walk(child)
		end
	end
	walk(root)
	return set
end

-- Whether an element is in the page with this name.
function M.named(root, id)
	local found = false
	local function walk(element)
		if element.meta and element.meta.id == id then
			found = true
		end
		for _, child in ipairs(element.kids or {}) do
			walk(child)
		end
	end
	walk(root)
	return found
end

-- The element with the name, and what is below it (so that a test can look at one part).
function M.find(root, id)
	local found
	local function walk(element)
		if found then
			return
		end
		if element.meta and element.meta.id == id then
			found = element
			return
		end
		for _, child in ipairs(element.kids or {}) do
			walk(child)
		end
	end
	walk(root)
	return found
end

return M
