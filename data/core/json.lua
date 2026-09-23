-- mod-version:2
-- Minimal JSON encoder + decoder with no external dependencies.
-- Extracted from data/plugins/aichat.lua so that any plugin or core module
-- can reuse it. Handles strings (with UTF-8 safe escapes), numbers (NaN/inf
-- -> null), booleans, nil, arrays and objects; the decoder is a small
-- recursive-descent parser over bytes.
local json = {}

local function json_escape(s)
  local map = {
    ['\\'] = '\\\\',
    ['"']  = '\\"',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
  }
  s = s:gsub('[\\"\n\r\t]', map)
  s = s:gsub('[%z\1-\31]', function(c)
    return string.format('\\u%04x', c:byte())
  end)
  return s
end

local function json_encode(value)
  local t = type(value)
  if t == "string" then
    return '"' .. json_escape(value) .. '"'
  elseif t == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return "null"
    end
    return string.format("%.14g", value)
  elseif t == "boolean" then
    return value and "true" or "false"
  elseif t == "nil" then
    return "null"
  elseif t == "table" then
    local is_array = true
    local count = 0
    for k in pairs(value) do
      count = count + 1
      if type(k) ~= "number" then is_array = false; break end
    end
    if count == 0 then return "{}" end
    local parts = {}
    if is_array then
      for i = 1, #value do parts[i] = json_encode(value[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      for k, v in pairs(value) do
        parts[#parts + 1] = '"' .. json_escape(tostring(k)) .. '":' .. json_encode(v)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

local decode_value
local function decode_whitespace(s, pos)
  while pos <= #s and s:byte(pos) <= 32 do pos = pos + 1 end
  return pos
end
local function decode_string(s, pos)
  pos = pos + 1 -- skip opening quote
  local buf = {}
  while pos <= #s do
    local b = s:byte(pos)
    if b == 34 then -- closing quote
      return table.concat(buf), pos + 1
    elseif b == 92 then -- backslash escape
      pos = pos + 1
      local c = s:byte(pos)
      if c == 110 then buf[#buf+1] = "\n"
      elseif c == 114 then buf[#buf+1] = "\r"
      elseif c == 116 then buf[#buf+1] = "\t"
      elseif c == 98 then buf[#buf+1] = "\b"
      elseif c == 102 then buf[#buf+1] = "\f"
      elseif c == 34 then buf[#buf+1] = '"'
      elseif c == 92 then buf[#buf+1] = "\\"
      elseif c == 47 then buf[#buf+1] = "/" -- '/'
      elseif c == 117 then -- 'u' followed by 4 hex digits
        local hex = s:sub(pos+1, pos+4)
        local code = tonumber(hex, 16)
        pos = pos + 4
        if code then
          if code < 0x80 then
            buf[#buf+1] = string.char(code)
          elseif code < 0x800 then
            buf[#buf+1] = string.char(0xC0 + math.floor(code/64), 0x80 + code%64)
          else
            buf[#buf+1] = string.char(0xE0 + math.floor(code/4096),
                                    0x80 + math.floor(code/64)%64,
                                    0x80 + code%64)
          end
        end
      else
        buf[#buf+1] = string.char(c)
      end
      pos = pos + 1
    else
      buf[#buf+1] = string.char(b)
      pos = pos + 1
    end
  end
  error("unterminated string")
end
local function decode_number(s, pos)
  local start = pos
  if s:byte(pos) == 45 then pos = pos + 1 end -- '-'
  while pos <= #s do
    local c = s:byte(pos)
    if (c >= 48 and c <= 57) or c == 46 or c == 101 or c == 69 or c == 43 or c == 45 then
      pos = pos + 1
    else break end
  end
  return tonumber(s:sub(start, pos - 1)), pos
end
decode_value = function(s, pos)
  pos = decode_whitespace(s, pos)
  local c = s:byte(pos)
  if c == 34 then -- '"'
    return decode_string(s, pos)
  elseif c == 123 then -- '{'
    pos = pos + 1
    local obj = {}
    pos = decode_whitespace(s, pos)
    if s:byte(pos) == 125 then return obj, pos + 1 end -- '}'
    while true do
      pos = decode_whitespace(s, pos)
      local key, kpos = decode_string(s, pos)
      pos = kpos
      pos = decode_whitespace(s, pos)
      if s:byte(pos) ~= 58 then error("expected ':'") end -- ':'
      pos = pos + 1
      local val
      val, pos = decode_value(s, pos)
      obj[key] = val
      pos = decode_whitespace(s, pos)
      local sep = s:byte(pos)
      if sep == 44 then pos = pos + 1 -- ','
      elseif sep == 125 then return obj, pos + 1 -- '}'
      else error("expected ',' or '}'") end
    end
  elseif c == 91 then -- '['
    pos = pos + 1
    local arr = {}
    pos = decode_whitespace(s, pos)
    if s:byte(pos) == 93 then return arr, pos + 1 end -- ']'
    local idx = 1
    while true do
      local val
      val, pos = decode_value(s, pos)
      arr[idx] = val
      idx = idx + 1
      pos = decode_whitespace(s, pos)
      local sep = s:byte(pos)
      if sep == 44 then pos = pos + 1 -- ','
      elseif sep == 93 then return arr, pos + 1 -- ']'
      else error("expected ',' or ']'") end
    end
  elseif c == 45 or (c >= 48 and c <= 57) then -- '-' or digit
    return decode_number(s, pos)
  elseif c == 116 then return true, pos + 4 -- 'true'
  elseif c == 102 then return false, pos + 5 -- 'false'
  elseif c == 110 then return nil, pos + 4 -- 'null'
  else error("unexpected character at position " .. pos) end
end
function json.decode(s)
  if not s or s == "" then return nil end
  local val = decode_value(s, 1)
  return val
end
json.encode = json_encode

return json
