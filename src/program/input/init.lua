-- Reading the pipeline's input as rows, in the shape it has: lines, CSV, TSV, a table lined up
-- with spaces, JSON lines, or a JSON document. Knows nothing of the page, of the query or of
-- what goes out.
--
--   local reader = input.Reader.new(sink, format)     format nil: read it from the first lines
--   reader:feed(text)  ...  reader:finish()
--
-- See `input.reader` for the sink. Each shape is a module of its own: `input.lines`,
-- `input.delimited` (CSV and TSV), `input.columns`, `input.jsonl`, `input.document`.

local M = {}

M.FORMATS = { "lines", "csv", "tsv", "columns", "jsonl", "json" }

M.Reader = require("input.reader")
M.detect = require("input.detect").detect
M.plain = require("input.plain").plain
M.columns = require("input.columns")
M.json = require("input.json")

return M
