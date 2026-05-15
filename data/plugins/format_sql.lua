-- mod-version:4
-- SQL Formatter plugin for Lite XL
-- Rules based on sql-formatter (https://github.com/sql-formatter-org/sql-formatter)
local core = require "core"
local command = require "core.command"
local DocView = require "core.docview"
local ContextMenu = require "core.contextmenu"

--------------------------------------------------------------------------------
-- Tokenizer
--------------------------------------------------------------------------------
local function tokenize(sql)
  local tokens = {}
  local i = 1
  local len = #sql

  while i <= len do
    local ch = sql:sub(i, i)

    if ch:match("%s") then
      local j = i
      while j <= len and sql:sub(j, j):match("%s") do j = j + 1 end
      i = j

    elseif sql:sub(i, i + 1) == "--" then
      local j = sql:find("\n", i, true)
      if j then
        table.insert(tokens, { "COMMENT", sql:sub(i, j - 1) })
        i = j + 1
      else
        table.insert(tokens, { "COMMENT", sql:sub(i) })
        i = len + 1
      end

    elseif sql:sub(i, i + 1) == "/*" then
      local j = sql:find("*/", i + 2, true)
      if j then
        table.insert(tokens, { "BLOCK_COMMENT", sql:sub(i, j + 1) })
        i = j + 2
      else
        table.insert(tokens, { "BLOCK_COMMENT", sql:sub(i) })
        i = len + 1
      end

    elseif ch == "'" or ch == '"' or ch == "`" then
      local quote = ch
      local j = i + 1
      while j <= len do
        if sql:sub(j, j) == quote then
          if sql:sub(j + 1, j + 1) == quote then
            j = j + 2
          else
            j = j + 1
            break
          end
        elseif sql:sub(j, j) == "\\" and quote ~= "`" then
          j = j + 2
        else
          j = j + 1
        end
      end
      table.insert(tokens, { "STRING", sql:sub(i, j - 1) })
      i = j

    elseif ch:match("%d") then
      local j = i
      while j <= len and sql:sub(j, j):match("%d") do j = j + 1 end
      if sql:sub(j, j) == "." and sql:sub(j + 1, j + 1):match("%d") then
        j = j + 1
        while j <= len and sql:sub(j, j):match("%d") do j = j + 1 end
      end
      if sql:sub(j, j):match("[eE]") then
        j = j + 1
        if sql:sub(j, j):match("[+-]") then j = j + 1 end
        while j <= len and sql:sub(j, j):match("%d") do j = j + 1 end
      end
      table.insert(tokens, { "NUMBER", sql:sub(i, j - 1) })
      i = j

    elseif ch == "(" then
      table.insert(tokens, { "OPEN_PAREN", "(" })
      i = i + 1
    elseif ch == ")" then
      table.insert(tokens, { "CLOSE_PAREN", ")" })
      i = i + 1
    elseif ch == "," then
      table.insert(tokens, { "COMMA", "," })
      i = i + 1
    elseif ch == ";" then
      table.insert(tokens, { "SEMICOLON", ";" })
      i = i + 1
    elseif ch == "." then
      table.insert(tokens, { "DOT", "." })
      i = i + 1
    elseif ch == "*" then
      table.insert(tokens, { "STAR", "*" })
      i = i + 1
    elseif ch == "?" then
      table.insert(tokens, { "PLACEHOLDER", "?" })
      i = i + 1

    elseif ch == ":" then
      local j = i + 1
      while j <= len and sql:sub(j, j):match("[%w_]") do j = j + 1 end
      if j > i + 1 then
        table.insert(tokens, { "PLACEHOLDER", sql:sub(i, j - 1) })
        i = j
      else
        table.insert(tokens, { "OP", ":" })
        i = i + 1
      end

    elseif ch == "@" then
      local j = i + 1
      while j <= len and sql:sub(j, j):match("[%w_]") do j = j + 1 end
      if j > i + 1 then
        table.insert(tokens, { "PLACEHOLDER", sql:sub(i, j - 1) })
        i = j
      else
        table.insert(tokens, { "OP", "@" })
        i = i + 1
      end

    elseif sql:sub(i, i + 1) == ">=" or sql:sub(i, i + 1) == "<=" or
           sql:sub(i, i + 1) == "!=" or sql:sub(i, i + 1) == "<>" or
           sql:sub(i, i + 1) == "||" or sql:sub(i, i + 1) == "&&" then
      table.insert(tokens, { "OP", sql:sub(i, i + 1) })
      i = i + 2

    elseif ch == "=" or ch == ">" or ch == "<" or ch == "!" or
           ch == "+" or ch == "-" or ch == "/" or ch == "%" or
           ch == "~" or ch == "|" or ch == "&" then
      table.insert(tokens, { "OP", ch })
      i = i + 1

    elseif ch:match("[%w_]") then
      local j = i
      while j <= len and sql:sub(j, j):match("[%w_]") do j = j + 1 end
      table.insert(tokens, { "WORD", sql:sub(i, j - 1) })
      i = j

    else
      table.insert(tokens, { "OTHER", ch })
      i = i + 1
    end
  end

  return tokens
end

--------------------------------------------------------------------------------
-- Merge multi-word keywords
--------------------------------------------------------------------------------
local multi_word_list = {
  "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN",
  "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "CROSS JOIN", "FULL JOIN",
  "GROUP BY", "ORDER BY", "UNION ALL",
  "INSERT INTO", "DELETE FROM",
  "CREATE TABLE", "CREATE INDEX", "CREATE VIEW", "CREATE DATABASE",
  "CREATE FUNCTION", "CREATE PROCEDURE", "CREATE UNIQUE INDEX",
  "ALTER TABLE", "DROP TABLE", "DROP INDEX", "DROP VIEW", "DROP DATABASE",
  "PARTITION BY", "IS NOT", "NOT IN", "NOT NULL", "NOT LIKE",
  "NOT BETWEEN", "NOT EXISTS", "IS NULL",
  "PRIMARY KEY", "FOREIGN KEY",
  "ORDER", "GROUP",
}

local function merge_keywords(tokens)
  table.sort(multi_word_list, function(a, b) return #a > #b end)
  local i = 1
  while i <= #tokens do
    if tokens[i][1] == "WORD" then
      local matched = false
      for _, kw in ipairs(multi_word_list) do
        local parts = {}
        for p in kw:gmatch("%S+") do table.insert(parts, p) end
        local n = #parts
        if i + n - 1 <= #tokens then
          local ok = true
          for p = 1, n do
            if tokens[i + p - 1][1] ~= "WORD" or
               tokens[i + p - 1][2]:upper() ~= parts[p]:upper() then
              ok = false
              break
            end
          end
          if ok then
            tokens[i] = { "WORD", kw:upper() }
            for p = n, 2, -1 do table.remove(tokens, i + p - 1) end
            matched = true
            break
          end
        end
      end
      if not matched then i = i + 1 end
    else
      i = i + 1
    end
  end
  return tokens
end

--------------------------------------------------------------------------------
-- Keyword classification
--------------------------------------------------------------------------------

-- Top-level clause: starts new section, content gets indented
local CLAUSE_KW = {
  SELECT = true, ["GROUP BY"] = true, ["ORDER BY"] = true,
  HAVING = true, WHERE = true, SET = true,
  LIMIT = true, OFFSET = true,
  ["INSERT INTO"] = true, VALUES = true,
  UPDATE = true, ["DELETE FROM"] = true,
  FROM = true, USING = true,
  ["CREATE TABLE"] = true, ["CREATE INDEX"] = true, ["CREATE VIEW"] = true,
  ["CREATE DATABASE"] = true, ["CREATE FUNCTION"] = true, ["CREATE PROCEDURE"] = true,
  ["CREATE UNIQUE INDEX"] = true,
  ["ALTER TABLE"] = true, ["DROP TABLE"] = true, ["DROP INDEX"] = true,
  ["DROP VIEW"] = true, ["DROP DATABASE"] = true,
  TRUNCATE = true, MERGE = true,
  UNION = true, ["UNION ALL"] = true, INTERSECT = true, EXCEPT = true,
  WITH = true, RECURSIVE = true,
  RETURN = true, OVER = true,
}

-- JOIN: same indent level as FROM content, new line
local JOIN_KW = {
  JOIN = true, ["INNER JOIN"] = true, ["LEFT JOIN"] = true,
  ["RIGHT JOIN"] = true, ["OUTER JOIN"] = true, ["CROSS JOIN"] = true,
  ["FULL JOIN"] = true, ["LEFT OUTER JOIN"] = true,
  ["RIGHT OUTER JOIN"] = true, ["FULL OUTER JOIN"] = true,
  ON = true,
}

-- Logical: AND/OR/XOR - newline before, same indent
local LOGICAL_KW = { AND = true, OR = true, XOR = true }

-- CASE expression
local CASE_KW = { CASE = true, WHEN = true, THEN = true, ELSE = true, END = true }

-- Words to uppercase
local UPPERCASE = {}
do
  local words = {
    "SELECT","FROM","WHERE","AND","OR","NOT","IN","IS","NULL","AS","ON","JOIN",
    "INNER","LEFT","RIGHT","OUTER","CROSS","FULL","NATURAL","BETWEEN","EXISTS",
    "LIKE","DISTINCT","ALL","ASC","DESC","GROUP","ORDER","BY","HAVING","LIMIT",
    "OFFSET","UNION","INTERSECT","EXCEPT","INSERT","INTO","VALUES","UPDATE",
    "SET","DELETE","CREATE","ALTER","DROP","TABLE","INDEX","VIEW","DATABASE",
    "TRUNCATE","BEGIN","COMMIT","ROLLBACK","CASE","WHEN","THEN","ELSE","END",
    "WITH","RECURSIVE","OVER","PARTITION","PRIMARY","FOREIGN","KEY","REFERENCES",
    "CONSTRAINT","DEFAULT","IF","TRUE","FALSE","USING","MERGE","MATCHED",
    "RETURN","XOR","WINDOW","NATURAL",
    "VARCHAR","INT","INTEGER","BIGINT","FLOAT","DOUBLE","DECIMAL","BOOLEAN",
    "TEXT","CHAR","DATE","TIMESTAMP","NUMERIC","REAL","SMALLINT","TINYINT",
    "BLOB","CLOB","SERIAL","BIGSERIAL",
    "COUNT","SUM","AVG","MAX","MIN","CAST","COALESCE","NULLIF","CONCAT",
    "ROW_NUMBER","RANK","DENSE_RANK","LEAD","LAG","FIRST_VALUE","LAST_VALUE",
    "EXTRACT","SUBSTRING","TRIM","UPPER","LOWER","LENGTH","REPLACE",
    "ROUND","FLOOR","CEIL","CEILING","ABS","MOD","POWER","SQRT",
    "NOW","CURRENT_DATE","CURRENT_TIME","CURRENT_TIMESTAMP",
    "IFNULL","ISNULL","NVL","UNIQUE","CHECK","GRANT","REVOKE",
    "FUNCTION","PROCEDURE","TRIGGER","SEQUENCE","SCHEMA",
  }
  for _, w in ipairs(words) do UPPERCASE[w] = true end
end

--------------------------------------------------------------------------------
-- Formatter
--------------------------------------------------------------------------------
local function format_sql(sql)
  sql = sql:gsub("\r\n", "\n")
  local tokens = tokenize(sql)
  tokens = merge_keywords(tokens)

  local IND = "  "
  local out = {}
  local top = 0       -- top-level indent (clause content)
  local blk = 0       -- block-level indent (parens/CASE)
  local fresh = true  -- at start of line
  local in_clause = false
  local paren_stack = {}  -- track inline vs multiline for each paren level
  local case_stack = {}
  local between_mode = false

  local function indent()
    return IND:rep(top + blk)
  end

  local function w(text)
    table.insert(out, text)
  end

  local function newline()
    if fresh then return end  -- already at start of line, avoid extra blank lines
    w("\n")
    fresh = true
  end

  local function add_indent()
    if fresh then
      w(indent())
      fresh = false
    end
  end

  local function emit(text)
    add_indent()
    w(text)
  end

  local function peek_ahead_simple(idx, max_chars)
    -- Look ahead to find matching close paren, count chars, check for complex content
    -- Starts with depth=1 because we're inside an already-opened paren
    local depth = 1
    local count = 0
    for j = idx, #tokens do
      local t = tokens[j]
      if t[1] == "OPEN_PAREN" then
        depth = depth + 1
      elseif t[1] == "CLOSE_PAREN" then
        depth = depth - 1
        if depth == 0 then
          return count <= max_chars
        end
      else
        count = count + #t[2]
        if t[1] == "WORD" then
          local cat = t[2]:upper()
          if CLAUSE_KW[cat] or JOIN_KW[cat] then
            return false
          end
        end
      end
    end
    return false
  end

  for idx, token in ipairs(tokens) do
    local tp = token[1]
    local val = token[2]
    local upper = tp == "WORD" and val:upper() or ""

    if tp == "COMMENT" then
      newline()
      emit(val)
      newline()

    elseif tp == "BLOCK_COMMENT" then
      newline()
      for line in val:gmatch("[^\n]*") do
        emit(line)
        newline()
      end

    elseif tp == "SEMICOLON" then
      emit(";")
      newline()
      top = 0
      blk = 0
      in_clause = false
      fresh = true
      newline()  -- blank line between queries

    elseif tp == "WORD" and CLAUSE_KW[upper] then
      -- Clause keyword: new line, no indent, then content on next indented line
      if in_clause then
        top = math.max(0, top - 1)
      end
      newline()
      emit(upper)
      top = top + 1
      in_clause = true
      between_mode = false

      -- UNION/INTERSECT/EXCEPT: they precede the next SELECT
      if upper == "UNION" or upper == "UNION ALL" or
         upper == "INTERSECT" or upper == "EXCEPT" then
        top = math.max(0, top - 1)
      end

      -- Content goes on the next indented line
      newline()

    elseif tp == "WORD" and JOIN_KW[upper] then
      if upper == "ON" then
        -- ON goes on new line at same level as join content
        newline()
        emit("ON ")
      else
        -- JOIN: dedent, newline, emit, indent
        if in_clause then
          top = math.max(0, top - 1)
        end
        newline()
        emit(upper)
        w(" ")
        top = top + 1
        in_clause = true
      end

    elseif tp == "WORD" and LOGICAL_KW[upper] then
      if upper == "AND" and between_mode then
        w("AND ")
        between_mode = false
      else
        -- Newline before, at clause content level
        top = math.max(0, top - 1)
        newline()
        emit(upper)
        w(" ")
        top = top + 1
      end

    elseif tp == "WORD" and CASE_KW[upper] then
      if upper == "CASE" then
        emit("CASE ")
        top = top + 1
        table.insert(case_stack, true)
      elseif upper == "WHEN" then
        newline()
        emit("WHEN ")
      elseif upper == "THEN" then
        newline()
        emit("THEN ")
        top = top + 1
      elseif upper == "ELSE" then
        top = math.max(0, top - 1)
        newline()
        emit("ELSE ")
        top = top + 1
      elseif upper == "END" then
        top = math.max(0, top - 1)
        newline()
        emit("END")
        if #case_stack > 0 then table.remove(case_stack) end
        top = math.max(0, top - 1)
        -- Add space after END unless special
        if idx < #tokens then
          local next_tp = tokens[idx + 1][1]
          if next_tp ~= "DOT" and next_tp ~= "COMMA" and next_tp ~= "SEMICOLON"
             and next_tp ~= "CLOSE_PAREN" and next_tp ~= "OP" then
            w(" ")
          end
        end
      end

    elseif tp == "OPEN_PAREN" then
      emit("(")
      -- Decide inline vs multiline
      local is_inline = peek_ahead_simple(idx + 1, 60)
      table.insert(paren_stack, is_inline)
      if is_inline then
        -- keep on same line
      else
        blk = blk + 1
        newline()
      end

    elseif tp == "CLOSE_PAREN" then
      if #paren_stack > 0 then
        local was_inline = table.remove(paren_stack)
        if not was_inline then
          blk = math.max(0, blk - 1)
          newline()
        end
      end
      emit(")")
      -- Add space unless followed by DOT, COMMA, SEMICOLON, CLOSE_PAREN, OP
      if idx < #tokens then
        local next_tp = tokens[idx + 1][1]
        if next_tp ~= "DOT" and next_tp ~= "COMMA" and next_tp ~= "SEMICOLON"
           and next_tp ~= "CLOSE_PAREN" and next_tp ~= "OP" then
          w(" ")
        end
      end

    elseif tp == "COMMA" then
      w(",")
      -- Check if we're in an inline paren
      local in_inline = false
      for _, v in ipairs(paren_stack) do
        if v then in_inline = true; break end
      end
      if in_inline then
        w(" ")
      else
        newline()
      end

    elseif tp == "DOT" then
      w(".")

    elseif tp == "STAR" then
      -- context: SELECT * vs multiplication
      if idx > 1 and tokens[idx - 1][1] == "DOT" then
        w("*")
      elseif fresh or (idx > 1 and (tokens[idx - 1][1] == "OPEN_PAREN" or
                 (tokens[idx - 1][1] == "WORD" and tokens[idx - 1][2]:upper() == "SELECT"))) then
        emit("*")
      else
        w(" * ")
      end

    elseif tp == "OP" then
      -- Dense operators (no spaces)
      if val == "::" or val == ":=" then
        w(val)
      else
        w(" " .. val .. " ")
      end

    elseif tp == "NUMBER" then
      emit(val)
      -- Add space unless followed by DOT, COMMA, SEMICOLON, CLOSE_PAREN
      if idx < #tokens then
        local next_tp = tokens[idx + 1][1]
        if next_tp ~= "DOT" and next_tp ~= "COMMA" and next_tp ~= "SEMICOLON"
           and next_tp ~= "CLOSE_PAREN" then
          w(" ")
        end
      end

    elseif tp == "STRING" then
      emit(val)
      if idx < #tokens then
        local next_tp = tokens[idx + 1][1]
        if next_tp ~= "DOT" and next_tp ~= "COMMA" and next_tp ~= "SEMICOLON"
           and next_tp ~= "CLOSE_PAREN" then
          w(" ")
        end
      end

    elseif tp == "PLACEHOLDER" then
      emit(val)
      if idx < #tokens then
        local next_tp = tokens[idx + 1][1]
        if next_tp ~= "DOT" and next_tp ~= "COMMA" and next_tp ~= "SEMICOLON"
           and next_tp ~= "CLOSE_PAREN" then
          w(" ")
        end
      end

    elseif tp == "WORD" then
      local display = UPPERCASE[upper] and upper or val
      emit(display)
      -- Add space after unless followed by certain tokens
      if idx < #tokens then
        local next_tp = tokens[idx + 1][1]
        if next_tp == "DOT" or next_tp == "COMMA" or next_tp == "SEMICOLON"
           or next_tp == "CLOSE_PAREN" or next_tp == "OP" then
          -- no space
        elseif next_tp == "OPEN_PAREN" then
          -- Function call: CAST(...) no space; Table name: users (...) with space
          if not UPPERCASE[upper] then w(" ") end
        else
          w(" ")
        end
      end

    else
      emit(val)
    end

    -- Track BETWEEN for AND
    if tp == "WORD" and upper == "BETWEEN" then
      between_mode = true
    end
    if tp == "WORD" and upper == "AND" then
      between_mode = false
    end
  end

  local output = table.concat(out)
  output = output:gsub("^%s+", "")
  output = output:gsub("%s+$", "\n")
  output = output:gsub("\n\n\n+", "\n\n")
  output = output:gsub(" +\n", "\n")
  return output
end

--------------------------------------------------------------------------------
-- Register the sql:format command
--------------------------------------------------------------------------------
command.add(function()
  local dv = core.active_view
  if not dv:is(DocView) then return false end
  return dv.doc.syntax and dv.doc.syntax.name == "SQL"
end, {
  ["sql:format"] = function()
    local dv = core.active_view
    local doc = dv.doc
    local text = doc:get_text(1, 1, #doc.lines, math.huge)
    local formatted = format_sql(text)
    if formatted ~= text then
      doc:remove(1, 1, #doc.lines, math.huge)
      doc:insert(1, 1, formatted:gsub("\n$", "") .. "\n")
      core.log("SQL formatted")
    else
      core.log("SQL already formatted")
    end
  end
})

--------------------------------------------------------------------------------
-- Hook ContextMenu:show to add "Format SQL" for SQL files
--------------------------------------------------------------------------------
local old_ContextMenu_show = ContextMenu.show
function ContextMenu:show(x, y, items, ...)
  local dv = core.active_view
  if dv and dv:is(DocView) and dv.doc and dv.doc.syntax and dv.doc.syntax.name == "SQL" then
    local has_format = false
    for _, item in ipairs(items) do
      if item ~= ContextMenu.DIVIDER and item.text == "Format SQL" then
        has_format = true
        break
      end
    end
    if not has_format then
      table.insert(items, ContextMenu.DIVIDER)
      table.insert(items, { text = "Format SQL", command = "sql:format" })
    end
  end
  return old_ContextMenu_show(self, x, y, items, ...)
end
