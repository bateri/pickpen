-- The query language and everything that reads a table by it: the terms a person types, the
-- rows they keep, the order of the rows and what a column holds. Plain rows in
-- (`{ cells = {...}, lower = text or nil }`), plain lists of row numbers out; nothing here knows
-- the page, the input or the output.
--
--   require("query").parse(source, columns)      the terms
--   require("query").compile(query)              a function of a row, for a loop over many
--   require("query").order(rows, indices, column, descending)
--   require("query.stats").column(rows, indices, column, options)
--
-- The modules are `query.fold` (text), `query.values` (quantities), `query.parse`,
-- `query.match`, `query.order` and `query.stats`; their functions are here too, as one table.

local fold = require("query.fold")
local match = require("query.match")
local order = require("query.order")
local parse = require("query.parse")
local stats = require("query.stats")
local values = require("query.values")

return {
	fold = fold,
	values = values,
	stats = stats,

	-- values
	quantity = values.quantity,
	comparable = values.comparable,
	column_kind = values.column_kind,
	write_quantity = values.write_quantity,

	-- the language
	parse = parse.parse,
	simple_name = parse.simple_name,
	column_named = parse.column_named,
	unknown_names = parse.unknown_names,
	quote_value = parse.quote_value,
	quote_name = parse.quote_name,
	with_term = parse.with_term,

	-- the rows a query keeps
	row_lower = match.row_lower,
	holds = match.holds,
	matches = match.matches,
	compile = match.compile,
	filter = order.filter,

	-- the order
	compare_text = order.compare_text,
	sort_key = order.sort_key,
	compare_keys = order.compare_keys,
	compare_ordered = order.compare_ordered,
	order = order.order,
}
