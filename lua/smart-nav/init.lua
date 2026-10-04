local M = {}

local api = vim.api

-- config
local config = {
	chunk_lines = 50, -- lines scanned at a time while searching for the next stop
	max_scan_cols = 2000, -- cap per-line scanning
	use_snippet_tabstops = false,
	normal_mode = "structural", -- "structural" or "hop"; insert mode always hops

	-- character stops (hop mode)
	opening_chars = { ["("] = "after", ["["] = "after", ["{"] = "after" },
	closing_chars = { [")"] = "both", ["]"] = "both", ["}"] = "both" },
	quotes = { ['"'] = true, ["'"] = true, ["`"] = true },
	operators = {
		[","] = true,
		[">"] = true,
		["+"] = true,
		["-"] = true,
		["*"] = true,
		["/"] = true,
		["%"] = true,
		["&"] = true,
		["|"] = true,
		["="] = true,
		["^"] = true,
		["!"] = true,
	},
	word_operators = {}, -- words to jump after, like "not"

	-- treesitter node types (hop mode)
	target_types = {
		identifier = true,
		property_identifier = true,
		field_identifier = true,
		number_literal = true,
		true_literal = true,
		false_literal = true,
		primitive_type = true,
		type_identifier = true,
		sized_type_specifier = true,
	},
	container_types = {
		parameter_list = true,
		argument_list = true,
		formal_parameters = true,
		parameters = true,
		arguments = true,
		compound_statement = true,
		statement_block = true,
		block = true,
	},
	string_types = {
		string = true,
		string_literal = true,
		raw_string_literal = true,
		char_literal = true,
		character_literal = true,
		template_string = true,
		interpreted_string_literal = true,
		rune_literal = true,
	},

	-- treesitter fields whose start is a stop (structural mode)
	structural_fields = {
		name = true, -- function, class and variable names
		key = true, -- object keys
		value = true, -- initialisers and object values
		condition = true, -- if / while / for / ternary conditions
		["function"] = true, -- the function being called
	},
}

local SCALAR_OPTS = { "chunk_lines", "max_scan_cols", "use_snippet_tabstops", "normal_mode" }
local TABLE_OPTS = {
	"opening_chars",
	"closing_chars",
	"quotes",
	"operators",
	"word_operators",
	"target_types",
	"container_types",
	"string_types",
	"structural_fields",
}

local op_chars = {} -- every character that appears in an enabled operator
local cache = {} -- bufnr -> { tick, [mode key] = { [chunk index] = stops } }

-- utf-8 helpers
local function char_len(b)
	if not b or b < 0xC0 then
		return 1
	end
	if b >= 0xF0 then
		return 4
	end
	if b >= 0xE0 then
		return 3
	end
	return 2
end

-- character starting at byte i (1-based) and its byte length
local function char_at(s, i)
	local n = char_len(s:byte(i))
	return s:sub(i, i + n - 1), n
end

-- 0-based byte column of the last character, where normal mode can sit
local function last_char_col(line)
	local i = #line
	while i > 1 do
		local b = line:byte(i)
		if b < 0x80 or b >= 0xC0 then
			break
		end
		i = i - 1
	end
	return math.max(i - 1, 0)
end

local function is_word_char(ch)
	return ch ~= "" and ch:match("^[%w_]") ~= nil
end

local function build_op_chars()
	op_chars = {}
	for op, enabled in pairs(config.operators) do
		if enabled then
			local i = 1
			while i <= #op do
				local ch, n = char_at(op, i)
				op_chars[ch] = true
				i = i + n
			end
		end
	end
end

-- string / comment regions, bucketed by row. "hole" marks code inside a
-- string, like `${x}` or f"{x}", and wins over the string around it.
local function add_region(regions, top, bot, node, kind)
	local sr, sc, er, ec = node:range()
	for r = math.max(sr, top), math.min(er, bot) do
		local list = regions[r] or {}
		regions[r] = list
		list[#list + 1] = { r == sr and sc or 0, r == er and ec or math.huge, kind }
	end
end

local function kind_at(spans, col)
	local kind = "code"
	if spans then
		for _, s in ipairs(spans) do
			if col >= s[1] and col < s[2] then
				if s[3] == "hole" then
					return "code"
				end
				kind = s[3]
			end
		end
	end
	return kind
end

-- treesitter
local function get_root(buf)
	local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
	if not ok or not parser then
		return nil
	end
	local trees = parser:parse()
	return trees and trees[1] and trees[1]:root()
end

local function is_modifier_like(t)
	return t:match("specifier")
		or t:match("qualifier")
		or t:match("modifier")
		or t:match("keyword")
		or t == "storage_class_specifier"
		or t == "type_qualifier"
		or t == "cv_qualifier"
		or t == "virtual_specifier"
		or t == "explicit_function_specifier"
end

local function is_paren_wrapper(t)
	return t:match("^parenthesized") or t == "condition_clause"
end

-- delimited by brackets, unlike Lua or Python blocks which start at their first statement
local function is_bracketed(node)
	local first = node:child(0)
	return first ~= nil and not first:named()
end

local function is_block(t)
	return t:match("block") or t:match("compound")
end

-- look through `( ... )` so a condition stop lands on the expression itself
local function unwrap(node)
	while node and is_paren_wrapper(node:type()) and node:named_child_count() > 0 do
		node = node:named_child(0)
	end
	return node
end

local function collect_ts(root, top, bot, mode, out, regions)
	local function push(r, c)
		if r >= top and r <= bot and c >= 0 then
			out[#out + 1] = { r, c }
		end
	end

	local function push_start(node)
		if node then
			local r, c = node:start()
			push(r, c)
		end
	end

	local function push_end(node)
		local sr, _, er, ec = node:range()
		-- a node ending at column 0 swallowed the newline; its end is just the next line
		if ec > 0 or er == sr then
			push(er, ec)
		end
	end

	-- just before the closing delimiter, and just after the string
	local function string_stops(node)
		local count = node:child_count()
		local last = count > 1 and node:child(count - 1)
		if last and (not last:named() or last:type():match("end")) then
			push_start(last)
		end
		push_end(node)
	end

	local function hop_stops(node, t)
		-- declarations: the first meaningful child (parameters are already reached after `(` or `,`)
		if (t:match("declaration") or t:match("definition")) and not t:match("parameter") then
			for child in node:iter_children() do
				if child:named() then
					local ct = child:type()
					if config.target_types[ct] or is_modifier_like(ct) then
						push_start(child)
						break
					end
				end
			end
		end

		if config.target_types[t] or is_modifier_like(t) or t:match("statement") or t:match("expression") then
			push_end(node)
		end

		if (config.container_types[t] or is_paren_wrapper(t)) and is_bracketed(node) then
			local sr, sc = node:start()
			push(sr, sc + 1) -- after opening
			push_end(node)
		end
	end

	local function structural_stops(node, t)
		-- each argument / parameter, but not every statement in a block
		if config.container_types[t] and not is_block(t) then
			for child in node:iter_children() do
				if child:named() and not child:type():match("comment") then
					push_start(child)
				end
			end
		end

		-- in `std::vector<int>` the name is just part of a type
		if not (t:match("qualified") or t:match("scoped") or t:match("template") or t:match("generic")) then
			for child, field in node:iter_children() do
				if field and config.structural_fields[field] then
					push_start(unwrap(child))
				end
			end
		end

		-- C-style declarations name things through a chain of declarators
		if (t:match("declaration") or t:match("definition")) and not t:match("parameter") then
			for _, d in ipairs(node:field("declarator")) do
				while d:field("declarator")[1] do
					d = d:field("declarator")[1]
				end
				push_start(d)
			end
		end

		-- both sides of an assignment
		if t:match("assignment") and node:named_child_count() > 0 then
			push_start(node:field("left")[1])
			push_start(node:field("right")[1] or node:named_child(node:named_child_count() - 1))
		end

		if t:match("^return") then
			push_start(node:named_child(0))
		end
	end

	local function walk(node)
		local sr, _, er = node:range()
		if er < top or sr > bot then
			return
		end

		local t = node:type()
		if t:match("comment") then
			add_region(regions, top, bot, node, "comment")
			return
		end

		if config.string_types[t] then
			add_region(regions, top, bot, node, "string")
			if mode == "hop" then
				string_stops(node)
			end
			for child in node:iter_children() do
				local ct = child:type()
				if child:named() and (ct:match("interpolation") or ct:match("substitution")) then
					add_region(regions, top, bot, child, "hole")
					walk(child)
				end
			end
			return
		end

		if mode == "hop" then
			hop_stops(node, t)
		else
			structural_stops(node, t)
		end

		for child in node:iter_children() do
			if child:named() then
				walk(child)
			end
		end
	end

	walk(root)
end

-- character scan (hop mode, and the fallback without treesitter)
local function push_char(out, row, col, width, mode)
	if mode == "before" or mode == "both" then
		out[#out + 1] = { row, col }
	end
	if mode == "after" or mode == "both" or mode == true then
		out[#out + 1] = { row, col + width }
	end
end

local function scan_line(out, row, line, spans)
	local len = math.min(#line, config.max_scan_cols)
	local quote -- open quote, for strings treesitter didn't give us
	local i = 1

	while i <= len do
		local ch, n = char_at(line, i)
		local col = i - 1
		local kind = kind_at(spans, col)

		if kind == "string" then
			-- treesitter string: its stops come from the tree
		elseif quote then
			if ch == "\\" then
				i = i + n
				ch, n = char_at(line, i) -- skip the escaped character
			elseif ch == quote then
				-- jump inside and after closing quote
				out[#out + 1] = { row, col }
				out[#out + 1] = { row, col + n }
				quote = nil
			end
		elseif config.opening_chars[ch] then
			push_char(out, row, col, n, config.opening_chars[ch])
		elseif config.closing_chars[ch] then
			push_char(out, row, col, n, config.closing_chars[ch])
		elseif kind == "code" then
			if config.quotes[ch] then
				-- an apostrophe straight after a letter is prose ("don't", "users'"), not a string
				if not (ch == "'" and is_word_char(line:sub(i - 1, i - 1))) then
					quote = ch
				end
			elseif op_chars[ch] then
				-- a run like `->` or `!=` is one operator: stop after the whole run
				if not op_chars[char_at(line, i + n)] then
					out[#out + 1] = { row, col + n }
				end
			elseif is_word_char(ch) and not is_word_char(line:sub(i - 1, i - 1)) then
				local word = line:match("^[%w_]+", i)
				if config.word_operators[word] then
					out[#out + 1] = { row, col + #word }
				end
				n = #word
			end
		end

		i = i + n
	end

	-- end of line
	if line:find("%S") then
		out[#out + 1] = { row, len }
	end
end

-- stops for one chunk of lines, sorted and deduped
local function collect(buf, idx, mode, clamp)
	local top = idx * config.chunk_lines
	local bot = math.min(top + config.chunk_lines, api.nvim_buf_line_count(buf)) - 1
	local lines = api.nvim_buf_get_lines(buf, top, bot + 1, false)

	local out, regions = {}, {}
	local root = get_root(buf)
	if root then
		collect_ts(root, top, bot, mode, out, regions)
	end

	-- structural mode needs a tree; without one (or in prose) fall back to hopping
	if mode == "hop" or #out == 0 then
		for i, line in ipairs(lines) do
			scan_line(out, top + i - 1, line, regions[top + i - 1])
		end
	end

	-- normal mode can't sit past the last character
	if clamp then
		for _, wp in ipairs(out) do
			local line = lines[wp[1] - top + 1]
			if line then
				wp[2] = math.min(wp[2], last_char_col(line))
			end
		end
	end

	table.sort(out, function(a, b)
		return (a[1] < b[1]) or (a[1] == b[1] and a[2] < b[2])
	end)

	local deduped, lr, lc = {}, -1, -1
	for _, wp in ipairs(out) do
		if wp[1] ~= lr or wp[2] ~= lc then
			deduped[#deduped + 1] = wp
			lr, lc = wp[1], wp[2]
		end
	end
	return deduped
end

local function get_chunk(buf, idx, mode, clamp)
	local tick = api.nvim_buf_get_changedtick(buf)
	local c = cache[buf]
	if not c or c.tick ~= tick then
		c = { tick = tick }
		cache[buf] = c
	end

	local key = mode .. (clamp and ":normal" or ":insert")
	c[key] = c[key] or {}
	if not c[key][idx] then
		c[key][idx] = collect(buf, idx, mode, clamp)
	end
	return c[key][idx]
end

-- snippet tabstop navigation
local function try_snippet_jump(direction)
	if not config.use_snippet_tabstops then
		return false
	end

	-- native vim.snippet (nvim 0.10+)
	if vim.snippet and vim.snippet.active({ direction = direction }) then
		vim.snippet.jump(direction)
		return true
	end

	-- luasnip, only while the cursor is still inside the snippet
	local luasnip = package.loaded.luasnip
	if luasnip and luasnip.locally_jumpable(direction) then
		luasnip.jump(direction)
		return true
	end

	return false
end

-- navigation
local function jump(direction)
	local m = api.nvim_get_mode().mode:sub(1, 1)
	local insert = m == "i" or m == "R"

	-- select mode is a snippet placeholder; there is nothing else to do there
	if m == "s" then
		try_snippet_jump(direction)
		return
	end

	if insert and try_snippet_jump(direction) then
		return
	end

	local mode = insert and "hop" or config.normal_mode
	local buf = api.nvim_get_current_buf()
	local pos = api.nvim_win_get_cursor(0)
	local cr, cc = pos[1] - 1, pos[2]

	local last_idx = math.floor((api.nvim_buf_line_count(buf) - 1) / config.chunk_lines)
	local idx = math.floor(cr / config.chunk_lines)

	while idx >= 0 and idx <= last_idx do
		local wps = get_chunk(buf, idx, mode, not insert)
		local first, last, step = 1, #wps, 1
		if direction < 0 then
			first, last, step = #wps, 1, -1
		end
		for i = first, last, step do
			local r, c = wps[i][1], wps[i][2]
			local after = r > cr or (r == cr and c > cc)
			local before = r < cr or (r == cr and c < cc)
			if (direction > 0 and after) or (direction < 0 and before) then
				api.nvim_win_set_cursor(0, { r + 1, c })
				return
			end
		end
		idx = idx + direction
	end
end

function M.next()
	jump(1)
end

function M.prev()
	jump(-1)
end

-- merge user tables into defaults; `false` removes a default
local function merge_config(default, user)
	if not user then
		return default
	end

	local result = {}
	for k, v in pairs(default) do
		result[k] = v
	end
	for k, v in pairs(user) do
		if v == false then
			result[k] = nil
		else
			result[k] = v
		end
	end
	return result
end

-- setup
function M.setup(user_config)
	user_config = user_config or {}

	for _, k in ipairs(SCALAR_OPTS) do
		if user_config[k] ~= nil then
			config[k] = user_config[k]
		end
	end
	for _, k in ipairs(TABLE_OPTS) do
		config[k] = merge_config(config[k], user_config[k])
	end

	build_op_chars()
	cache = {}

	api.nvim_create_autocmd("BufWipeout", {
		group = api.nvim_create_augroup("SmartNav", { clear = true }),
		callback = function(args)
			cache[args.buf] = nil
		end,
	})
end

build_op_chars()

return M
