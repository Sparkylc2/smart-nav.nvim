# smart-nav.nvim
Smart semantic navigation for Neovim. Jump to meaningful positions in your code and jump in and out of parentheses, quotes, and other delimiters with one key.

I made this as a personal utility, and as such is primarily tested/adapted for C++ and JS.


## Features

- **Insert mode hops**: after brackets, operators, identifiers, just before a closing quote and just after it
- **Normal mode jumps structurally**: to names being defined, the function being called, each argument and parameter, conditions, both sides of assignments, object keys and values, and return values
- Treesitter-aware: quotes and operators in comments are ignored, and nothing inside a string is a stop except `${...}` / `{...}` interpolations
- Integrates with snippet tabstops (optional)
- Falls back to character-based navigation without treesitter
- Only scans the lines around the cursor, cached per buffer until the next edit
- Somewhat customizable jump targets


## Installation

lazy.nvim:
```lua
{
  "sparkylc2/smart-nav.nvim",
  config = function()
    require("smart-nav").setup()
    vim.keymap.set({ "n", "i", "s" }, "<C-;>", require("smart-nav").next)
    vim.keymap.set({ "n", "i", "s" }, "<C-S-;>", require("smart-nav").prev)
  end,
}
```

packer.nvim:
```lua
use {
  "sparkylc2/smart-nav.nvim",
  config = function()
    require("smart-nav").setup()
    vim.keymap.set({ "n", "i", "s" }, "<C-;>", require("smart-nav").next)
    vim.keymap.set({ "n", "i", "s" }, "<C-S-;>", require("smart-nav").prev)
  end,
}
```

Mapping select mode (`"s"`) matters when `use_snippet_tabstops` is on: snippet placeholders with default text are selected, and an unmapped key there acts as a Visual mode command.

## Usage
The plugin provides two functions:

`require("smart-nav").next()` - jump to next stop
`require("smart-nav").prev()` - jump to previous stop

Stops don't wrap around: at the last stop in the buffer, `next()` stays put.


## Customization
Navigation targets are customizable. Your config extends the defaults:
- Set to `true` to enable (or add new)
- Set to `false` to disable a default
- Omit to keep the default
(for `opening_chars` and `closing_chars`, set to "before", "after", "both", or "neither", where "neither" disables the target)

Character-based targets (insert mode)

`closing_chars` - characters to jump to (brackets, etc.)
`opening_chars` - characters to jump to (similar to closing)
`quotes` - quote characters, for strings treesitter doesn't know about (jumps inside and after)
`operators` - operator characters to jump after. Consecutive operator characters are one operator, so `->`, `!=` and `+=` get a single stop after them
`word_operators` - words to jump after

Treesitter targets

`target_types` - node types to jump to the end of (insert mode)
`container_types` - container nodes: after the opening bracket and after the close in insert mode; in normal mode each item of a non-block container (each argument, parameter, and so on)
`string_types` - string nodes: just before the closing delimiter and just after the string
`structural_fields` - node fields whose start is a stop in normal mode

## Configuration
```lua
require("smart-nav").setup({
  chunk_lines = 50,              -- lines scanned at a time while searching for the next stop
  max_scan_cols = 2000,          -- cap per-line scanning
  use_snippet_tabstops = false,  -- jump through snippet tabstops instead when available
  normal_mode = "structural",    -- or "hop" to use the insert mode stops in normal mode too

  -- customize navigation targets (extends defaults).
  -- use "before" to jump before the char, "after" to jump after, "both" for both, and "neither" to disable.
  opening_chars = {
    ["("] = "after",  -- keep default
    ["‹"] = "after",  -- add custom
    ["{"] = "both",   -- change default
  },
  closing_chars = {
    [")"] = "both",     -- keep default
    ["›"] = "both",     -- add custom
    ["}"] = "neither",  -- disable default
  },
  operators = {
    [":"] = true,   -- also stop after `::` and `:`
    [","] = false,  -- disable comma jumping
  },
  word_operators = {
    ["not"] = true,  -- jump after "not" keyword
    ["and"] = true,  -- jump after "and"
    ["or"] = true,   -- jump after "or"
  },

  -- treesitter node types (extends defaults)
  target_types = {
    jsx_element = true,  -- add jsx support
    identifier = false,  -- disable identifier jumping
  },
  container_types = {
    object = true,  -- add object literals
    array = true,   -- add arrays
  },
  structural_fields = {
    key = false,  -- don't stop on object keys in normal mode
  },
})
```

## Default configuration:
```lua
local default_config = {
	chunk_lines = 50,
	max_scan_cols = 2000,
	use_snippet_tabstops = false,
	normal_mode = "structural",

	opening_chars = { ["("] = "after", ["["] = "after", ["{"] = "after" },
	closing_chars = { [")"] = "both", ["]"] = "both", ["}"] = "both" },
	quotes = { ['"'] = true, ["'"] = true, ["`"] = true },
	operators = {
		[","] = true, [">"] = true, ["+"] = true, ["-"] = true,
		["*"] = true, ["/"] = true, ["%"] = true, ["&"] = true,
		["|"] = true, ["="] = true, ["^"] = true, ["!"] = true,
	},
	word_operators = {},

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
	structural_fields = {
		name = true,
		key = true,
		value = true,
		condition = true,
		["function"] = true,
	},
}
```
