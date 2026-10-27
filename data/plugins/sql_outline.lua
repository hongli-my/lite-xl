-- mod-version:4
--
-- sql_outline: outline navigation for SQL buffers.
-- Scans the buffer for statements, CTEs (WITH ... AS name) and subqueries
-- and offers them in a fuzzy-searchable outline (right-click menu).
-- Selecting an entry jumps to its line and column, so one-line or
-- minified SQL stays navigable.

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local DocView = require "core.docview"

local M = {}

local CLAUSE_WORDS = {
  SELECT = true, FROM = true, WHERE = true, GROUP = true, ORDER = true,
  HAVING = true, LIMIT = true, OFFSET = true, UNION = true, INTERSECT = true,
  EXCEPT = true, INSERT = true, UPDATE = true, DELETE = true, VALUES = true,
  SET = true, WITH = true,
}
local STMT_STARTERS = {
  SELECT = true, WITH = true, INSERT = true, UPDATE = true, DELETE = true,
}
local SUBQUERY_CONTEXT = {
  FROM = true, JOIN = true, WHERE = true, ON = true, HAVING = true,
  AND = true, OR = true, NOT = true, IN = true, EXISTS = true, SELECT = true,
  UNION = true, INTERSECT = true, EXCEPT = true, WHEN = true, THEN = true,
  ELSE = true, ALL = true, ANY = true, SOME = true, VALUES = true, USING = true,
}
local BY_WORDS = {
  GROUP = "GROUP BY", ORDER = "ORDER BY", PARTITION = "PARTITION BY",
}
local NOT_ALIAS = {}
for k in pairs(CLAUSE_WORDS) do NOT_ALIAS[k] = true end
for _, k in ipairs {
  "AS", "JOIN", "ON", "LEFT", "RIGHT", "INNER", "OUTER", "CROSS", "FULL",
  "NATURAL", "AND", "OR", "WHEN", "THEN", "ELSE", "END", "USING", "FOR",
  "IS", "NOT", "IN",
} do NOT_ALIAS[k] = true end

---Scans the document line by line, tracking comments, quoting and paren
---depth, and collects outline items.
local function parse(doc)
  local items = {}
  local paren = {}
  local in_block_comment = false
  local cte_list = false
  local started = false
  local stmt = 0
  local seen_clause = {}
  local last_word, last_word_line, last_word_col, prev_word, prev_word_line, prev_word_col
  local pending_alias

  for i, text in ipairs(doc.lines) do
    local j, n = 1, #text
    while j <= n do
      local c = text:byte(j)
      if in_block_comment then
        local close = text:find("*/", j, true)
        if close then
          in_block_comment = false
          j = close + 2
        else
          break
        end
      elseif c == 45 and text:byte(j + 1) == 45 then -- --
        break
      elseif c == 47 and text:byte(j + 1) == 42 then -- /*
        in_block_comment = true
        j = j + 2
      elseif c == 39 or c == 34 or c == 96 then -- ' " `
        local quote = c
        j = j + 1
        while j <= n do
          local q = text:byte(j)
          if q == 92 and quote ~= 96 then -- backslash escape
            j = j + 2
          elseif q == quote then
            if quote == 39 and text:byte(j + 1) == 39 then
              j = j + 2 -- '' doubling
            else
              j = j + 1
              break
            end
          else
            j = j + 1
          end
        end
        prev_word, last_word = nil, nil
      elseif c == 40 then -- (
        local upper = last_word and last_word:upper() or ""
        if upper == "AS" and prev_word and cte_list and #paren == 0 then
          items[#items + 1] = {
            kind = "cte", label = "CTE " .. prev_word,
            name = prev_word, line = prev_word_line or last_word_line or i,
            col = prev_word_col or last_word_col,
          }
        end
        paren[#paren + 1] = { ctx = upper, line = i, col = j, has_select = false }
        prev_word, last_word, pending_alias = nil, nil, nil
        j = j + 1
      elseif c == 41 then -- )
        local top = paren[#paren]
        if top then
          paren[#paren] = nil
          if top.has_select and top.ctx and SUBQUERY_CONTEXT[top.ctx] then
            items[#items + 1] = {
              kind = "sub", label = "子查询 " .. top.ctx, line = top.line,
              col = top.col,
            }
            pending_alias = #items
          else
            pending_alias = nil
          end
        end
        prev_word, last_word = nil, nil
        j = j + 1
      elseif c == 59 then -- ;
        if #paren == 0 then
          cte_list, started = false, false
          seen_clause = {}
        end
        prev_word, last_word, pending_alias = nil, nil, nil
        j = j + 1
      elseif c == 44 then -- ,
        pending_alias = nil
        j = j + 1
      else
        local w = text:match("[%w_]+", j)
        if w and j == text:find("[%w_]", j) then
          local wcol = j
          j = j + #w
          local upper = w:upper()
          if pending_alias and upper ~= "AS" then
            local it = items[pending_alias]
            if it and not NOT_ALIAS[upper] then
              it.label = it.label .. " · " .. w
              it.alias = w
            end
            pending_alias = nil
          end
          if upper == "SELECT" and #paren > 0 then
            paren[#paren].has_select = true
          end
          if #paren == 0 then
            if upper == "WITH" then
              cte_list = true
            elseif cte_list and CLAUSE_WORDS[upper] then
              cte_list = false
            end
            if CLAUSE_WORDS[upper] and not seen_clause[upper] then
              seen_clause[upper] = true
              if not started and STMT_STARTERS[upper] then
                stmt = stmt + 1
                started = true
                items[#items + 1] = {
                  kind = "stmt", label = "语句 " .. stmt, line = i, col = wcol,
                }
              end
              items[#items + 1] = {
                kind = "clause", label = BY_WORDS[upper] or upper, line = i, col = wcol,
              }
            end
          end
          prev_word, prev_word_line, prev_word_col, last_word, last_word_line, last_word_col =
            last_word, last_word_line, last_word_col, w, i, wcol
        else
          j = j + 1
        end
      end
    end
  end
  return items
end

local cache = setmetatable({}, { __mode = "k" })

local function get_items(doc)
  local c = cache[doc]
  local id = doc:get_change_id()
  if not c or c.id ~= id then
    c = { id = id, items = parse(doc) }
    cache[doc] = c
  end
  return c.items
end

local function is_sql_doc()
  local dv = core.active_view
  return dv and dv:is(DocView) and dv.doc
    and dv.doc.syntax and dv.doc.syntax.name == "SQL"
end

command.add(is_sql_doc, {
  ["sql:outline"] = function()
    local dv = core.active_view
    local doc = dv.doc
    local items = get_items(doc)
    if #items == 0 then
      core.log("未找到大纲条目")
      return
    end
    core.command_view:enter("SQL 大纲", {
      submit = function(text, item)
        if item and item.line then
          doc:set_selection(item.line, item.col or 1)
          dv:scroll_to_make_visible(item.line, item.col or 1)
        end
      end,
      suggest = function(text)
        local q = text:lower()
        local single_line = #doc.lines <= 1
        local res = {}
        for _, it in ipairs(items) do
          if q == "" or (common.fuzzy_match({ it.label:lower() }, q))[1] then
            local info = single_line and ("列 " .. (it.col or 1)) or ("行 " .. it.line)
            res[#res + 1] = { text = it.label, info = info, line = it.line, col = it.col }
          end
        end
        return res
      end,
    })
  end,
})

-- the outline is reachable from the right-click menu of SQL documents
local old_DocView_on_context_menu = DocView.on_context_menu
function DocView:on_context_menu()
  local args = { old_DocView_on_context_menu(self) }
  local cmds = args[1]
  if self.doc and self.doc.syntax and self.doc.syntax.name == "SQL" then
    -- right after Replace, in the same navigation group
    local idx
    for k, it in ipairs(cmds.items) do
      if type(it) == "table" and it.command == "find-replace:replace" then idx = k + 1 end
    end
    table.insert(cmds.items, idx or (#cmds.items + 1),
      { text = "SQL 大纲", command = "sql:outline" })
  end
  return table.unpack(args)
end

M.parse = parse
M.get_items = get_items

return M
