local M = {}

-- config & state
local config = {
	throttle_ms = 50, -- min delay between jumps
	debounce_ms = 120, -- rebuild delay after edits
	viewport_margin = 50, -- extra lines around visible window
	bigfile_lines = 5000, -- above this, only scan viewport
	max_scan_cols = 2000, -- cap per-line scanning
	use_snippet_tabstops = false,

	-- extendable navigation targets
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

	-- treesitter node types
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
		compound_statement = true,
		statement_block = true,
		block = true,
	},
}

local state = {
	waypoints = nil,
	last_tick = -1,
	in_jump = false,
	last_call = 0,
}

-- expensive char scan cache
local char_cache = {
	tick = -1,
	items = {},
}

local timer = vim.loop.new_timer()
local aug = nil

-- utils
local function hrtime_ms()
	return vim.loop.hrtime() / 1e6
end

local function visible_range()
	local top = vim.fn.line("w0") - 1
	local bot = vim.fn.line("w$") - 1
	return top, bot
end

local function clamp(n, lo, hi)
	if n < lo then
		return lo
	end
	if n > hi then
		return hi
	end
	return n
end

local function goto_pos(r, c)
	pcall(vim.api.nvim_win_set_cursor, 0, { r + 1, c })
end

local function get_cursor_pos()
	local pos = vim.api.nvim_win_get_cursor(0)
	return pos[1] - 1, pos[2]
end

-- character-based waypoint collection
local function collect_char_waypoints(range_top, range_bot)
	local tick = vim.b.changedtick or 0

	-- reuse cache if unchanged
	if char_cache.tick == tick and char_cache.items then
		local filtered = {}
		for i = 1, #char_cache.items do
			local r, c = char_cache.items[i][1], char_cache.items[i][2]
			if r >= range_top and r <= range_bot then
				filtered[#filtered + 1] = { r, c }
			end
		end
		return filtered
	end

	local items = {}

	-- scan lines for jump targets
	for row = range_top, range_bot do
		local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1]
		if line then
			local len = math.min(#line, config.max_scan_cols)
			local in_string = false
			local string_char = nil

			for col = 0, len - 1 do
				local ch = string.sub(line, col + 1, col + 1)

				if config.quotes[ch] then
					if not in_string then
						in_string = true
						string_char = ch
					elseif ch == string_char then
						-- jump inside and after closing quote
						items[#items + 1] = { row, col }
						items[#items + 1] = { row, col + 1 }
						in_string = false
						string_char = nil
					end
				elseif config.opening_chars[ch] and not in_string then
					local mode = config.opening_chars[ch]
					if mode ~= "neither" then
						if mode == "before" or mode == "both" then
							items[#items + 1] = { row, col }
						end
						if mode == "after" or mode == "both" or mode == true then
							items[#items + 1] = { row, col + 1 }
						end
					end
				elseif config.closing_chars[ch] and not in_string then
					local mode = config.closing_chars[ch]
					if mode ~= "neither" then
						if mode == "before" or mode == "both" then
							items[#items + 1] = { row, col }
						end
						if mode == "after" or mode == "both" or mode == true then
							items[#items + 1] = { row, col + 1 }
						end
					end
				elseif config.operators[ch] and not in_string then
					local prev_ch = col > 0 and string.sub(line, col, col) or nil
					if prev_ch == ch then
					else
						local next_ch = col + 1 < len and string.sub(line, col + 2, col + 2) or nil
						if next_ch == ch then
							items[#items + 1] = { row, col + 2 } -- after both operators
						else
							items[#items + 1] = { row, col + 1 } -- after single operator
						end
					end
				end
			end -- check for word operators
			for word, enabled in pairs(config.word_operators) do
				if enabled then
					local word_len = #word
					local idx = 1
					while idx <= len do
						local found = string.find(line, word, idx, true)
						if found then
							-- check it's a word boundary
							local before_ok = found == 1 or not string.sub(line, found - 1, found - 1):match("[%a_]")
							local after_idx = found + word_len - 1
							local after_ok = after_idx >= #line
								or not string.sub(line, after_idx + 1, after_idx + 1):match("[%a_]")

							if before_ok and after_ok then
								items[#items + 1] = { row, found + word_len - 1 } -- after word
							end
							idx = found + 1
						else
							break
						end
					end
				end
			end

			-- end of line waypoint
			if len > 0 then
				local last_added = items[#items]
				if not last_added or last_added[1] ~= row or last_added[2] ~= len then
					items[#items + 1] = { row, len }
				end
			end
		end
	end

	char_cache.tick = tick
	char_cache.items = items
	return items
end

-- main waypoint collection
local function collect_waypoints()
	local total_lines = vim.api.nvim_buf_line_count(0)
	local top, bot = visible_range()
	local margin = config.viewport_margin

	-- restrict for big files
	if total_lines > config.bigfile_lines then
		margin = math.min(margin, 200)
	end

	local range_top = clamp(top - margin, 0, total_lines - 1)
	local range_bot = clamp(bot + margin, 0, total_lines - 1)

	local waypoints = {}

	-- always get char-based waypoints
	local char_waypoints = collect_char_waypoints(range_top, range_bot)
	for i = 1, #char_waypoints do
		waypoints[#waypoints + 1] = char_waypoints[i]
	end

	-- try treesitter if available
	local ok, parser = pcall(vim.treesitter.get_parser, 0)
	if ok and parser then
		local trees = parser:parse()
		if trees and #trees > 0 then
			local root = trees[1]:root()

			local function push(out, r, c)
				if r and c and r >= range_top and r <= range_bot and r >= 0 and c >= 0 then
					out[#out + 1] = { r, c }
				end
			end

			local function nr4(n)
				if not n then
					return 0, 0, 0, 0
				end
				local r1, c1, r2, c2 = n:range()
				return r1, c1, r2 or r1, c2 or c1
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

			-- walk only nodes in range
			local function walk(node)
				if not node then
					return
				end
				local sr, sc, er, ec = nr4(node)
				if er < range_top or sr > range_bot then
					return
				end

				local t = node:type()

				-- declarations: jump to first meaningful child
				if t:match("declaration") or t:match("definition") then
					for child in node:iter_children() do
						if child:named() then
							local ct = child:type()
							if config.target_types[ct] or is_modifier_like(ct) then
								local cr, cc = nr4(child)
								push(waypoints, cr, cc)
								break
							end
						end
					end
				end

				if config.target_types[t] then
					push(waypoints, er, ec)
				end

				if is_modifier_like(t) then
					push(waypoints, er, ec)
				end

				if config.container_types[t] then
					push(waypoints, sr, sc + 1) -- after opening
					push(waypoints, er, ec) -- at closing
				end

				if t:match("parenthesized") or t:match("condition") then
					push(waypoints, sr, sc + 1)
					push(waypoints, er, ec)
				end

				if t:match("statement") or t:match("expression") then
					push(waypoints, er, ec)
				end

				for child in node:iter_children() do
					if child:named() then
						walk(child)
					end
				end
			end

			walk(root)
		end
	end

	-- sort and dedupe
	table.sort(waypoints, function(a, b)
		return (a[1] < b[1]) or (a[1] == b[1] and a[2] < b[2])
	end)

	local deduped, lr, lc = {}, -1, -1
	for _, wp in ipairs(waypoints) do
		if wp[1] ~= lr or wp[2] ~= lc then
			deduped[#deduped + 1] = wp
			lr, lc = wp[1], wp[2]
		end
	end

	return deduped
end

-- cache access without rebuild
local function get_waypoints()
	local tick = vim.b.changedtick or 0
	if state.waypoints and state.last_tick == tick then
		return state.waypoints
	end
	state.waypoints = collect_waypoints()
	state.last_tick = tick
	return state.waypoints
end

-- snippet tabstop navigation helpers
local function try_snippet_jump(direction)
	if not config.use_snippet_tabstops then
		return false
	end

	-- try native vim.snippet (nvim 0.10+)
	if vim.snippet then
		local ok, active = pcall(vim.snippet.active)
		if ok and active then
			vim.snippet.jump(direction)
			return true
		end
	end

	-- fallback to luasnip
	local ok, luasnip = pcall(require, "luasnip")
	if ok and luasnip then
		if luasnip.jumpable(direction) then
			luasnip.jump(direction)
			return true
		end
	end

	return false
end
-- debounced rebuild on edits
local function schedule_rebuild()
	timer:stop()
	timer:start(config.debounce_ms, 0, function()
		vim.schedule(function()
			if state.in_jump then
				return
			end
			state.waypoints = collect_waypoints()
			state.last_tick = vim.b.changedtick or 0
		end)
	end)
end

-- navigation functions
function M.next()
	local now = hrtime_ms()
	if (now - state.last_call) < config.throttle_ms then
		return
	end
	state.last_call = now

	-- try snippet jump first
	if try_snippet_jump(1) then
		return
	end

	if state.in_jump then
		return
	end
	state.in_jump = true

	local wps = get_waypoints()
	if #wps == 0 then
		state.in_jump = false
		return
	end

	local cr, cc = get_cursor_pos()
	local target

	-- find first waypoint after cursor
	for i = 1, #wps do
		local r, c = wps[i][1], wps[i][2]
		if (r > cr) or (r == cr and c > cc) then
			target = wps[i]
			break
		end
	end
	if not target then
		target = wps[1] -- wrap around
	end

	if target then
		goto_pos(target[1], target[2])
	end

	vim.schedule(function()
		state.in_jump = false
	end)
end

function M.prev()
	local now = hrtime_ms()
	if (now - state.last_call) < config.throttle_ms then
		return
	end
	state.last_call = now

	if try_snippet_jump(-1) then
		return
	end

	if state.in_jump then
		return
	end
	state.in_jump = true

	local wps = get_waypoints()
	if #wps == 0 then
		state.in_jump = false
		return
	end

	local cr, cc = get_cursor_pos()
	local target

	-- find last waypoint before cursor
	for i = #wps, 1, -1 do
		local r, c = wps[i][1], wps[i][2]
		if (r < cr) or (r == cr and c < cc) then
			target = wps[i]
			break
		end
	end
	if not target then
		target = wps[#wps] -- wrap around
	end

	if target then
		goto_pos(target[1], target[2])
	end

	vim.schedule(function()
		state.in_jump = false
	end)
end

-- helper to merge user config with defaults, handling false values
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

	-- handle simple values
	config.throttle_ms = user_config.throttle_ms or config.throttle_ms
	config.debounce_ms = user_config.debounce_ms or config.debounce_ms
	config.viewport_margin = user_config.viewport_margin or config.viewport_margin
	config.bigfile_lines = user_config.bigfile_lines or config.bigfile_lines
	config.max_scan_cols = user_config.max_scan_cols or config.max_scan_cols
	config.use_snippet_tabstops = user_config.use_snippet_tabstops or config.use_snippet_tabstops

	-- handle extendable configs
	config.closing_chars = merge_config(config.closing_chars, user_config.closing_chars)
	config.opening_chars = merge_config(config.opening_chars, user_config.opening_chars)
	config.quotes = merge_config(config.quotes, user_config.quotes)
	config.operators = merge_config(config.operators, user_config.operators)
	config.word_operators = merge_config(config.word_operators, user_config.word_operators)
	config.target_types = merge_config(config.target_types, user_config.target_types)
	config.container_types = merge_config(config.container_types, user_config.container_types)

	-- create autocmds
	aug = vim.api.nvim_create_augroup("SmartNav", { clear = true })

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
		group = aug,
		callback = function()
			-- mark dirty and rebuild
			state.waypoints = nil
			state.last_tick = -1
			schedule_rebuild()
		end,
	})
end

return M
