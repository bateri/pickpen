-- What the tests of the built program share: where the program, the stand-in terminal and the demo
-- inputs are, running the program as cron would, and running it in a pipeline in a pane.
--
-- Nothing here is skipped: a program or a stand-in that is not there stops the run, because a gate
-- that passes without looking proves nothing.

local pencere = require("pencere")

local M = {}

local function required(name)
	local value = pencere.env.get(name)
	assert(value and value ~= "", name .. " is not set: run these tests with make test-binary")
	assert(pencere.fs.exists(value), name .. " names " .. value .. ", which is not there")
	return value
end

M.BIN = required("PICKPEN_BIN")
M.HOST = required("PENCERE_FAKE_HOST")
M.DEMO = required("PICKPEN_DEMO") .. "/"

function M.quoted(text)
	return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

function M.read(path)
	return pencere.fs.read(path)
end

local counter = 0

-- A directory of its own for a test, made new; removed with `M.clean`.
function M.scratch()
	counter += 1
	local stamp = math.floor(pencere.time.now() * 1000) % 100000000
	local dir = pencere.path.join(
		pencere.os.tmpdir(),
		string.format("pickpen-binary-%d-%d", stamp, counter)
	)
	pencere.fs.mkdir(dir)
	return dir
end

function M.clean(dir)
	pencere.fs.remove(dir, true)
end

-- Runs the program the way cron would: in a session of its own, with no controlling terminal, so
-- that a test run from a terminal that shows pencere views opens none in it.
function M.run(args, input)
	local argv = { M.BIN }
	for _, word in ipairs(args) do
		argv[#argv + 1] = word
	end
	local ran = pencere.process.run({
		argv = argv,
		input = input,
		raw = true,
		session = true,
		timeout = 60,
	})
	return { out = ran.stdout, err = ran.stderr, status = ran.code, signal = ran.signal }
end

-- Runs `pipeline` in a pane under the stand-in terminal, `$PICKPEN` standing for the program; the
-- page makes the `calls` (`name=json`), then `after` happens (`--then`). What the program wrote
-- on stdout is `out`, on stderr `err`, its status `status`, and the host's record `log`.
function M.pane(pipeline, calls, after, extra)
	local dir = M.scratch()
	local argv = { M.HOST, "--size", "100x30", "--limit", "40" }
	for _, call in ipairs(calls or {}) do
		argv[#argv + 1] = "--call"
		argv[#argv + 1] = call
	end
	for _, word in ipairs(after or {}) do
		argv[#argv + 1] = word
	end
	for _, word in ipairs(extra or {}) do
		argv[#argv + 1] = word
	end
	argv[#argv + 1] = "--"
	argv[#argv + 1] = "sh"
	argv[#argv + 1] = "-c"
	argv[#argv + 1] = string.format(
		'%s > "%s/out" 2> "%s/err"; echo $? > "%s/status"',
		pipeline,
		dir,
		dir,
		dir
	)
	local started = pencere.time.monotonic()
	local ran = pencere.process.run({
		argv = argv,
		raw = true,
		timeout = 90,
		env = { PICKPEN = M.BIN, PENCERE_FAKE_GIST = "100000", DIR = dir },
	})
	local function read(name)
		local ok, text = pcall(pencere.fs.read, dir .. "/" .. name)
		return ok and text or ""
	end
	local result = {
		log = ran.stderr,
		out = read("out"),
		err = read("err"),
		status = tonumber((string.gsub(read("status"), "%s", ""))) or -1,
		seconds = pencere.time.monotonic() - started,
		dir = dir,
	}
	M.clean(dir)
	return result
end

return M
