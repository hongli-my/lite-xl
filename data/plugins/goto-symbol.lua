-- mod-version:4
-- goto-symbol: Sublime's cmd+R -- fuzzy-jump to a definition in the current
-- document.
--
-- Symbols are extracted from the syntax highlighter's token stream: an
-- identifier that follows a definition keyword (function / def / class /
-- struct / fn / ...) counts as a definition.  That heuristic covers the
-- common C-family / scripting languages without per-language grammars, and
-- rides on the already-cached tokenization, so it costs nothing extra while
-- editing.  Results are cached per document change-id.
--
-- The prompt reuses the CommandView suggestion machinery, including the
-- match-character highlighting added for findfile.

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"

-- Keywords whose following identifier is a definition.
local DEFINITION_KEYWORDS = {
  ["function"] = true, ["def"] = true, ["class"] = true, ["struct"] = true,
  ["fn"] = true, ["func"] = true, ["interface"] = true, ["enum"] = true,
  ["method"] = true, ["impl"] = true, ["trait"] = true, ["type"] = true,
}

local IDENTIFIER = "^[%a_][%w_]*"

local cache = setmetatable({}, { __mode = "k" })  -- doc -> { change_id, symbols }

---Extracts { name, line, col } definitions from the doc's token stream.
---A definition keyword arms `pending`; the next identifier-looking token is
---the symbol.  Punctuation cancels, leading whitespace keeps it armed, and
---each line starts fresh.
local function extract_symbols(doc)
  local symbols = {}
  for line = 1, #doc.lines do
    local col = 1
    local pending = false
    for _, type_, text in doc.highlighter:each_token(line) do
      local start_col = col
      col = col + #text
      if type_ == "keyword" and DEFINITION_KEYWORDS[text] then
        pending = true
      elseif pending and type_ ~= "keyword" and type_ ~= "comment"
          and type_ ~= "string" then
        local lead = select(2, text:find("^%s*")) or 0
        local body = text:sub(lead + 1)
        local ident = body:match(IDENTIFIER)
        if ident then
          symbols[#symbols + 1] = { name = ident, line = line,
            col = start_col + lead }
          pending = false
        elseif body ~= "" then
          pending = false
        end
      end
    end
  end
  return symbols
end

local function get_symbols(doc)
  local change_id = doc:get_change_id()
  local cached = cache[doc]
  if not cached or cached.change_id ~= change_id then
    cached = { change_id = change_id, symbols = extract_symbols(doc) }
    cache[doc] = cached
  end
  return cached.symbols
end

local function goto_symbol()
  local dv = core.active_view
  if not (dv and dv:is(DocView) and dv.doc) then return end
  local doc = dv.doc

  core.command_view:enter("Goto Symbol", {
    submit = function(text, item)
      if item and item.__line then
        doc:set_selection(item.__line, item.__col, item.__line, item.__col + #item.text)
        dv:scroll_to_line(item.__line, true)
      end
    end,
    suggest = function(text)
      local symbols = get_symbols(doc)
      if text == "" then
        local res = {}
        for _, sym in ipairs(symbols) do
          res[#res + 1] = { text = sym.name, info = tostring(sym.line),
            __line = sym.line, __col = sym.col }
        end
        return res
      end
      -- fuzzy filter with hit positions for the suggestion highlight
      local res = {}
      for _, sym in ipairs(symbols) do
        local score, hits = system.fuzzy_match_hits(sym.name, text)
        if score then
          local set = {}
          for _, idx in ipairs(hits) do set[idx] = true end
          res[#res + 1] = { text = sym.name, hits = set, score = score,
            info = tostring(sym.line), __line = sym.line, __col = sym.col }
        end
      end
      table.sort(res, function(a, b)
        if a.score == b.score then return a.__line < b.__line end
        return a.score > b.score
      end)
      return res
    end,
  })
end

command.add("core.docview!", {
  ["doc:goto-symbol"] = goto_symbol,
})

-- Sublime's cmd+R.  This overwrites the findbar's cmd+r (find-replace) for
-- Sublime alignment; the replace panel stays on cmd+alt+f and in the palette.
keymap.add({
  [(PLATFORM == "Mac OS X" or PLATFORM == "macOS") and "cmd+r" or "ctrl+r"] = "doc:goto-symbol",
}, true)
