-- A stand-in for the terminal that draws pickpen's page, so that the page runs in the tests with
-- the kit's own page API and the program's own calls behind it: the kit's prelude (the Lua the
-- terminal's sandbox gives a page) is read from a pencere checkout (`PENCERE_KIT`, the directory
-- `kit/luau/prelude`), the page's messages are answered by the handlers of `api/` in the same
-- process, and the pointer, the keys and the layout are whatever a test says they are. There is no
-- layout engine here: a test says what is under the pointer (`host.over`) and where an element is
-- (`host.boxes`).

local pencere = require("pencere")
local json = pencere.json

local M = {}

local PRELUDE = { "00-core", "10-element", "20-memory", "30-json", "40-page" }

-- The tree of elements as text: every string in it, in order.
function M.texts(tree)
	local out = {}
	local function walk(node)
		if type(node) ~= "table" then
			return
		end
		if node.text then
			out[#out + 1] = node.text
		end
		for _, kid in ipairs(node.kids or {}) do
			walk(kid)
		end
	end
	walk(tree)
	return out
end

-- The first element for which `test(node)` holds, depth first.
function M.find(tree, test)
	local found
	local function walk(node)
		if found or type(node) ~= "table" then
			return
		end
		if test(node) then
			found = node
			return
		end
		for _, kid in ipairs(node.kids or {}) do
			walk(kid)
		end
	end
	walk(tree)
	return found
end

function M.count(tree)
	local n = 0
	local function walk(node)
		if type(node) ~= "table" then
			return
		end
		n += 1
		for _, kid in ipairs(node.kids or {}) do
			walk(kid)
		end
	end
	walk(tree)
	return n
end

-- Whether any text of the tree holds `piece`.
function M.says(tree, piece)
	for _, words in ipairs(M.texts(tree)) do
		if string.find(words, piece, 1, true) then
			return true
		end
	end
	return false
end

-- The ids of the pressable elements of the tree, in order.
function M.pressables(tree)
	local out = {}
	local function walk(node)
		if type(node) ~= "table" then
			return
		end
		if node.meta and node.meta.pressable then
			out[#out + 1] = node.meta.id
		end
		for _, kid in ipairs(node.kids or {}) do
			walk(kid)
		end
	end
	walk(tree)
	return out
end

-- `calls`: the handlers of the program's calls (`api` modules' `calls(session)` merged); `topics`
-- the same for topics. Gives the host: `host:render()`, `host:event(e)`, `host:pump()`.
function M.new(page_source, calls, topics, size)
	local kit_dir = pencere.env.get("PENCERE_KIT")
	assert(kit_dir, "PENCERE_KIT names the directory of the kit's prelude (kit/luau/prelude)")
	local host = {
		sent = {},
		calls = calls,
		topics = topics,
		subscriptions = {},
		over = nil,
		boxes = {},
		size = size or { w = 900, h = 520 },
		now = 1.0,
		pending = {},
	}
	local env = setmetatable({}, { __index = _G })
	local kit = {}
	env.pencere = kit
	-- What the terminal gives the page before the prelude takes it.
	kit.send = function(text)
		host.sent[#host.sent + 1] = text
		host.pending[#host.pending + 1] = text
		return true
	end
	kit.hit = function()
		return host.over
	end
	kit.ids_at = function()
		return host.over and { host.over } or {}
	end
	kit.bounds = function(id)
		return host.boxes[id]
	end
	kit.scroll_extent = function(id)
		local box = host.boxes[id]
		if box and box.content then
			return { content = box.content, view = box.h }
		end
		return nil
	end
	kit.focus_order = function()
		return {}
	end
	kit.path_of = function(id)
		return { id }
	end
	kit.text_field = function()
		return nil
	end
	for _, name in ipairs(PRELUDE) do
		local source = pencere.fs.read(kit_dir .. "/" .. name .. ".lua")
		local chunk = assert(loadstring(source, "@" .. name))
		setfenv(chunk, env)
		chunk()
	end
	local chunk = assert(loadstring(page_source, "@page.lua"))
	setfenv(chunk, env)
	local page = chunk()
	kit.start(page)
	host.kit = kit

	function host:render()
		local tree, animating, wake = kit.render(self.size.w, self.size.h, self.now, false)
		self.tree, self.wake = tree, wake
		self:pump()
		return tree
	end

	-- The page's messages to the program are answered, one after another, until there are none.
	function host:pump()
		local rounds = 0
		while #self.pending > 0 and rounds < 200 do
			rounds += 1
			local text = table.remove(self.pending, 1)
			local message = json.decode(text)
			if message.call then
				local handler = self.calls[message.call.method]
				local answer
				if handler == nil then
					answer = { response = { id = message.call.id, error = { code = "not-found" } } }
				else
					local ok, result = pcall(handler, message.call.params, { cancelled = false })
					if ok then
						answer = { response = { id = message.call.id, result = result } }
					else
						local err = type(result) == "table" and result
							or { code = "failed", message = tostring(result) }
						answer = { response = { id = message.call.id, error = err } }
					end
				end
				self.last_reply = kit.message(json.encode(answer))
			elseif message.subscribe then
				local handler = self.topics[message.subscribe.topic]
				local subscription = {
					push = function(_, value)
						self.pushes = (self.pushes or 0) + 1
						self.pending_push = self.pending_push or {}
						table.insert(self.pending_push, {
							push = { id = message.subscribe.id, value = value },
						})
					end,
					on_end = function() end,
					cancelled = false,
				}
				handler(nil, subscription)
				self.subscriptions[message.subscribe.id] = subscription
				self:deliver_pushes()
			end
		end
	end

	function host:deliver_pushes()
		local queue = self.pending_push or {}
		self.pending_push = nil
		for _, message in ipairs(queue) do
			self.last_reply = kit.message(json.encode(message))
		end
		-- The page may have said more.
		self:pump()
	end

	-- A push of the topic, as the program makes one when the throttle lets it.
	function host:push_now(summary)
		for id in pairs(self.subscriptions) do
			self.last_reply = kit.message(json.encode({ push = { id = id, value = summary } }))
		end
		self:pump()
	end

	-- Renders until the page has nothing more to ask of the program.
	function host:settle()
		for _ = 1, 8 do
			local before = #self.sent
			self:render()
			if #self.sent == before then
				break
			end
		end
		return self.tree
	end

	function host:event(event)
		local reply = kit.handle(event)
		self:pump()
		return reply
	end

	function host:key(name, mods)
		return self:event({ type = "key", key = name, mods = mods or {} })
	end

	return host
end

return M
