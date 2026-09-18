-- mod-version:4
-- JSON formatter plugin for Lite XL.
--
-- The formatter rewrites the indentation of the document only: keys keep
-- their order and comments are preserved. A document that cannot be parsed is
-- left untouched and an error is reported instead.
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local DocView = require "core.docview"

---Formats a JSON document.
---@param text string
---@param indent_unit string Indentation for one level
---@return string? formatted The formatted document, or nil on error
---@return string? error_message
local function format_json(text, indent_unit)
  text = text:gsub("\r\n", "\n")
  local out = {}
  local i, len = 1, #text
  local line = 1
  local depth = 0
  local at_line_start = true
  local containers = {}      -- kind of each open container: "object" | "array"
  local last = nil           -- kind of the last significant token
  local error_message

  local function fail(message)
    error_message = error_message or message
  end

  local function newline()
    out[#out + 1] = "\n"
    at_line_start = true
  end

  local function put(text)
    if at_line_start then
      out[#out + 1] = indent_unit:rep(depth)
      at_line_start = false
    end
    out[#out + 1] = text
  end

  local function skip_blanks()
    while i <= len do
      local c = text:sub(i, i)
      if c == "\n" then
        line = line + 1
        i = i + 1
      elseif c == " " or c == "\t" or c == "\r" then
        i = i + 1
      else
        return
      end
    end
  end

  -- Returns the next significant character (and its index), skipping blanks
  -- and comments. Used to detect empty containers and trailing commas.
  local function lookahead(from)
    local j = from or i
    while j <= len do
      local c = text:sub(j, j)
      if c == "\n" or c == " " or c == "\t" or c == "\r" then
        j = j + 1
      elseif c == "/" and text:sub(j + 1, j + 1) == "/" then
        local e = text:find("\n", j, true)
        if not e then return nil end
        j = e
      elseif c == "/" and text:sub(j + 1, j + 1) == "*" then
        local e = text:find("*/", j + 2, true)
        if not e then return nil end
        j = e + 2
      else
        return c, j
      end
    end
  end

  -- Returns true if the next significant thing on the current line is a
  -- comment (used to keep trailing comments on the line they belong to).
  local function comment_follows(from)
    local j = from
    while j <= len do
      local c = text:sub(j, j)
      if c == "\n" then return false end
      if c == " " or c == "\t" or c == "\r" then
        j = j + 1
      elseif c == "/" and (text:sub(j + 1, j + 1) == "/" or text:sub(j + 1, j + 1) == "*") then
        return true
      else
        return false
      end
    end
    return false
  end

  local closers = { object = "}", array = "]" }
  local kinds = { ["{"] = "object", ["["] = "array", ["}"] = "object", ["]"] = "array" }

  while i <= len and not error_message do
    skip_blanks()
    if i > len then break end
    local c = text:sub(i, i)
    local kind = kinds[c]

    if c == "/" and (text:sub(i + 1, i + 1) == "/" or text:sub(i + 1, i + 1) == "*") then
      -- comments are kept as they are
      local block = text:sub(i + 1, i + 1) == "*"
      local after  -- index just after the end of the comment
      if block then
        local s = text:find("*/", i + 2, true)
        after = s and (s + 2)
      else
        after = text:find("\n", i, true) or (len + 1)
      end
      after = after or (len + 1)
      local comment = text:sub(i, after - 1)
      if at_line_start then
        put(comment)
      else
        out[#out + 1] = " "
        out[#out + 1] = comment
      end
      newline()
      if block then
        -- a block comment may span several lines
        local _, count = comment:gsub("\n", "")
        line = line + count
      end
      i = after

    elseif kind == "object" or kind == "array" then
      if c == "{" or c == "[" then
        if last == "value" or last == "close" then
          fail("missing ',' before '" .. c .. "'")
        else
          put(c)
          i = i + 1
          local next_char, next_index = lookahead()
          local closer = closers[kind]
          local between = next_index and text:sub(i, next_index - 1) or ""
          if next_char == closer and not between:find("/", 1, true) then
            -- empty container: keep it on a single line ({}, [])
            put(closer)
            i = next_index + 1
            last = "value"
          else
            table.insert(containers, kind)
            depth = depth + 1
            newline()
            last = "open"
          end
        end
      else
        if #containers == 0 then
          fail("unexpected '" .. c .. "'")
        elseif containers[#containers] ~= kind then
          fail("expected '" .. closers[containers[#containers]] .. "' but found '" .. c .. "'")
        elseif last == "open" or last == "comma" or last == "colon" then
          fail("unexpected '" .. c .. "'")
        else
          table.remove(containers)
          depth = depth - 1
          newline()
          put(c)
          last = "close"
        end
        i = i + 1
      end

    elseif c == "," then
      if last ~= "value" and last ~= "close" then
        fail("unexpected ','")
      else
        local next_char = lookahead(i + 1)
        if next_char == "}" or next_char == "]" then
          fail("trailing ',' before '" .. next_char .. "'")
        else
          put(",")
          -- a trailing comment stays on the same line
          if not comment_follows(i + 1) then newline() end
          last = "comma"
        end
      end
      i = i + 1

    elseif c == ":" then
      if #containers == 0 or containers[#containers] ~= "object" or last == "colon" then
        fail("unexpected ':'")
      else
        put(": ")
        last = "colon"
      end
      i = i + 1

    elseif c == '"' then
      local j, escaped = i + 1, false
      while j <= len do
        local char = text:sub(j, j)
        if escaped then
          escaped = false
        elseif char == "\\" then
          escaped = true
        elseif char == '"' then
          break
        elseif char == "\n" then
          j = nil
          break
        end
        j = j + 1
      end
      if not j or j > len then
        fail("unterminated string")
        i = len + 1
      else
        put(text:sub(i, j))
        i = j + 1
        last = "value"
      end

    else
      local s, e = text:find("[^%w%+%-%.]", i)
      local token = e and text:sub(i, e - 1) or text:sub(i)
      local is_number = token:match("^%-?%d+$") or token:match("^%-?%d+%.%d+$")
        or token:match("^%-?%d+[eE][%+%-]?%d+$") or token:match("^%-?%d+%.%d+[eE][%+%-]?%d+$")
      if token == "" then
        fail(string.format("unexpected character '%s'", c))
        i = i + 1
      elseif token == "true" or token == "false" or token == "null" or is_number then
        put(token)
        i = e or (len + 1)
        last = "value"
      else
        fail(string.format("unexpected token '%s'", token))
        i = e or (len + 1)
      end
    end
  end

  if not error_message and #containers > 0 then
    fail("unexpected end of document, '" .. closers[containers[#containers]] .. "' expected")
  end
  if error_message then
    return nil, string.format("line %d: %s", line, error_message)
  end

  local formatted = table.concat(out):gsub("^%s+", ""):gsub("%s+$", "")
  return formatted .. "\n"
end


---Returns the indentation unit used by a document.
---@param doc core.doc
---@return string
local function get_indent_unit(doc)
  local indent_type, indent_size = doc:get_indent_info()
  if indent_type == "hard" then return "\t" end
  return string.rep(" ", indent_size or config.indent_size)
end


command.add(function()
  local dv = core.active_view
  if not dv:is(DocView) then return false end
  return dv.doc.syntax and dv.doc.syntax.name == "JSON"
end, {
  ["json:format"] = function()
    local dv = core.active_view
    local doc = dv.doc
    -- `inclusive` is needed, otherwise the newline terminating the last line
    -- is dropped and "already formatted" documents never compare equal
    local text = doc:get_text(1, 1, #doc.lines, math.huge, true)
    local formatted, error_message = format_json(text, get_indent_unit(doc))
    if not formatted then
      core.error("Cannot format JSON: %s", error_message or "invalid document")
      return
    end
    if formatted == text then
      core.log("JSON already formatted")
      return
    end

    local line, col = doc:get_selection()
    -- `Doc:remove` keeps the newline terminating the last line, so the
    -- formatted text is inserted without its own trailing newline.
    doc:remove(1, 1, #doc.lines, math.huge)
    doc:insert(1, 1, formatted:sub(-1) == "\n" and formatted:sub(1, -2) or formatted)
    -- keep the cursor close to where it was
    line = math.min(line, #doc.lines)
    col = math.min(col, #doc.lines[line])
    doc:set_selection(line, col)
    core.log("JSON formatted")
  end
})


return { format = format_json }
