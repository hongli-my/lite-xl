local core = require "core"
local syntax = require "core.syntax"
local config = require "core.config"

local tokenizer = {}
local bad_patterns = {}

-- Optional C merged Lua-pattern matcher (Pike VM over all patterns of a
-- syntax at once). Patterns it cannot compile (backreferences, %b, empty
-- matches) automatically fall back to the original Lua path below.
local tokenizer_c = nil
if config.tokenizer_c ~= false then
  local ok, mod = pcall(require, "tokenizer_c")
  if ok then tokenizer_c = mod end
end

-- compiled-program cache, keyed by syntax table (weak so syntaxes can be
-- replaced by plugins at runtime)
local tc_compiled = setmetatable({ }, { __mode = "k" })

-- byte position of char position i (1-based); O(i), only used on cold paths
local function char_to_byte(text, i)
  return #text:usub(1, i - 1) + 1
end

-- Byte offsets of the most recent tokenizer_c match, set by the C paths and
-- consumed immediately by the caller that advances `i`.
local last_match_sb, last_match_eb

-- Compile a syntax's Lua patterns for the C matcher. Mirrors find_text's
-- lazy '^' normalization upfront (idempotent), and compiles each table
-- pattern's close part into a standalone program for delimiter searches.
local function tc_compile(syn)
  if not tokenizer_c or config.tokenizer_c == false then return nil end
  local comp = tc_compiled[syn]
  if comp then return comp end
  local opens, pos1 = { }, { }
  local count = 0
  for n, p in ipairs(syn.patterns) do
    local target = p.pattern
    opens[n], pos1[n] = false, false
    local okpat = not p.disabled and not p.regex and (
      type(target) == "string" or
      (type(target) == "table" and type(target[1]) == "string"
        and type(target[2]) == "string"))
    if okpat then
      p.whole_line = p.whole_line or { }
      local parts = type(target) == "table"
        and { target[1], target[2] } or { target }
      for pi = 1, #parts do
        local code = parts[pi]
        if p.whole_line[pi] == nil then
          p.whole_line[pi] = code:umatch("^%^") and true or false
          if p.whole_line[pi] then code = code:usub(2) end
        end
        parts[pi] = code
      end
      if type(target) == "table" then
        target[1], target[2] = parts[1], parts[2]
        p._tc = tokenizer_c.compile(parts[2])
      else
        p.pattern = parts[1]
      end
      opens[n] = parts[1]
      pos1[n] = p.whole_line[1] and true or false
      count = count + 1
    end
  end
  local set, supported = nil, { }
  if count > 0 then
    set, supported = tokenizer_c.compile_set(opens, pos1)
  end
  comp = { set = set, supported = supported }
  tc_compiled[syn] = comp
  return comp
end

local function push_token(t, type, text)
  if not text or #text == 0 then return end
  type = type or "normal"
  local prev_type = t[#t-1]
  local prev_text = t[#t]
  if prev_type and (prev_type == type or (prev_text:ufind("^%s*$") and type ~= "incomplete")) then
    t[#t-1] = type
    t[#t] = prev_text .. text
  else
    table.insert(t, type)
    table.insert(t, text)
  end
end


-- Advance a byte position by n characters from a known anchor; O(n).
local function advance_bytes(text, b, n)
  for _ = 1, n do
    local c = string.byte(text, b)
    if not c then break end
    if c < 0x80 or c < 0xC0 then b = b + 1
    elseif c < 0xE0 then b = b + 2
    elseif c < 0xF0 then b = b + 3
    else b = b + 4 end
  end
  return b
end

-- Convert a char position to a byte position incrementally from a known
-- (char, byte) anchor; O(char_pos - anchor_char).
local function char_to_byte_at(text, char_pos, anchor_char, anchor_byte)
  return advance_bytes(text, anchor_byte, char_pos - anchor_char)
end

local function push_tokens(t, syn, pattern, full_text, find_results, anchor_char, anchor_byte)
  if #find_results > 2 then
    -- We do some manipulation with find_results so that it's arranged
    -- like this:
    -- { start, end, i_1, i_2, i_3, …, i_last }
    -- Each position spans characters from i_n to ((i_n+1) - 1), to form
    -- consecutive spans of text.
    --
    -- Insert the start index at i_1 to make iterating easier
    table.insert(find_results, 3, find_results[1])
    -- Copy the ending index to the end of the table, so that an ending index
    -- always follows a starting index after position 3 in the table.
    table.insert(find_results, find_results[2] + 1)
    -- Convert char positions to byte positions incrementally from the anchor
    local byte_pos = { }
    for i = 3, #find_results do
      byte_pos[i - 2] = char_to_byte_at(full_text, find_results[i], anchor_char, anchor_byte)
    end
    -- Then, we just iterate over our modified table.
    for i = 3, #find_results - 1 do
      local start = byte_pos[i - 2]
      local fin = byte_pos[i - 1] - 1
      local type = pattern.type[i - 2]
        -- ↑ (i - 2) to convert from [3; n] to [1; n]
      if fin >= start then
        local text = full_text:sub(start, fin)
        push_token(t, syn.symbols[text] or type, text)
      end
    end
  else
    local start, fin = find_results[1], find_results[2]
    local bs = char_to_byte_at(full_text, start, anchor_char, anchor_byte)
    local be = char_to_byte_at(full_text, fin + 1, anchor_char, anchor_byte) - 1
    local text = full_text:sub(bs, be)
    push_token(t, syn.symbols[text] or pattern.type, text)
  end
end

-- State is a string of bytes, where the count of bytes represents the depth
-- of the subsyntax we are currently in. Each individual byte represents the
-- index of the pattern for the current subsyntax in relation to its parent
-- syntax. Using a string of bytes allows us to have as many subsyntaxes as
-- bytes can be stored on a string while keeping some level of performance in
-- comparison to a Lua table. The only limitation is that a syntax would not
-- be able to contain more than 255 patterns.
--
-- Lets say a state contains 2 bytes byte #1 with value `3` and byte #2 with
-- a value of `5`. This would mean that on the parent syntax at index `3` a
-- pattern subsyntax that matched current text was found, then inside that
-- subsyntax another subsyntax pattern at index `5` that matched current text
-- was also found.

-- Calling `push_subsyntax` appends the current subsyntax pattern index to the
-- state and increases the stack depth. Calling `pop_subsyntax` clears the
-- last appended subsyntax and decreases the stack.

local function retrieve_syntax_state(incoming_syntax, state)
  local current_syntax, subsyntax_info, current_pattern_idx, current_level =
    incoming_syntax, nil, state:byte(1) or 0, 1
  if
    current_pattern_idx > 0
    and
    current_syntax.patterns[current_pattern_idx]
  then
    -- If the state is not empty we iterate over each byte, and find which
    -- syntax we're using. Rather than walking the bytes, and calling into
    -- `syntax` each time, we could probably cache this in a single table.
    for i = 1, #state do
      local target = state:byte(i)
      if target ~= 0 then
        if current_syntax.patterns[target].syntax then
          subsyntax_info = current_syntax.patterns[target]
          current_syntax = type(subsyntax_info.syntax) == "table" and
            subsyntax_info.syntax or syntax.get(subsyntax_info.syntax)
          current_pattern_idx = 0
          current_level = i+1
        else
          current_pattern_idx = target
          break
        end
      else
        break
      end
    end
  end
  return current_syntax, subsyntax_info, current_pattern_idx, current_level
end

---Return the list of syntaxes used in the specified state.
---@param base_syntax table @The initial base syntax (the syntax of the file)
---@param state string @The state of the tokenizer to extract from
---@return table @Array of syntaxes starting from the innermost one
function tokenizer.extract_subsyntaxes(base_syntax, state)
  local current_syntax
  local t = {}
  repeat
    current_syntax = retrieve_syntax_state(base_syntax, state)
    table.insert(t, current_syntax)
    state = string.sub(state, 2)
  until #state == 0
  return t
end

local function report_bad_pattern(log_fn, syntax, pattern_idx, msg, ...)
  if not bad_patterns[syntax] then
    bad_patterns[syntax] = { }
  end
  if bad_patterns[syntax][pattern_idx] then return end
  bad_patterns[syntax][pattern_idx] = true
  log_fn("Malformed pattern #%d <%s> in %s language plugin.\n" .. msg,
            pattern_idx,
            syntax.patterns[pattern_idx].pattern or syntax.patterns[pattern_idx].regex,
            syntax.name or "unnamed", ...)
end

---@param incoming_syntax table
---@param text string
---@param state string
function tokenizer.tokenize(incoming_syntax, text, state, resume)
  local res
  local i = 1
  local byte_i = 1

  state = state or string.char(0)

  if #incoming_syntax.patterns == 0 then
    return { "normal", text }, state
  end

  if resume then
    res = resume.res
    -- Remove "incomplete" tokens
    while res[#res-1] == "incomplete" do
      table.remove(res, #res)
      table.remove(res, #res)
    end
    i = resume.i
    state = resume.state
    byte_i = resume.byte_i or char_to_byte(text, i)
  end

  res = res or {}

  -- incoming_syntax    : the parent syntax of the file.
  -- state              : a string of bytes representing syntax state (see above)

  -- current_syntax     : the syntax we're currently in.
  -- subsyntax_info     : info about the delimiters of this subsyntax.
  -- current_pattern_idx: the index of the pattern we're on for this syntax.
  -- current_level      : how many subsyntaxes deep we are.
  local current_syntax, subsyntax_info, current_pattern_idx, current_level =
    retrieve_syntax_state(incoming_syntax, state)

  -- Should be used to set the state variable. Don't modify it directly.
  local function set_subsyntax_pattern_idx(pattern_idx)
    current_pattern_idx = pattern_idx
    local state_len = #state
    if current_level > state_len then
      state = state .. string.char(pattern_idx)
    elseif state_len == 1 then
      state = string.char(pattern_idx)
    else
      state = ("%s%s%s"):format(
        state:sub(1,current_level-1),
        string.char(pattern_idx),
        state:sub(current_level+1)
      )
    end
  end


  local function push_subsyntax(entering_syntax, pattern_idx)
    set_subsyntax_pattern_idx(pattern_idx)
    current_level = current_level + 1
    subsyntax_info = entering_syntax
    current_syntax = type(entering_syntax.syntax) == "table" and
      entering_syntax.syntax or syntax.get(entering_syntax.syntax)
    current_pattern_idx = 0
  end

  local function pop_subsyntax()
    current_level = current_level - 1
    state = string.sub(state, 1, current_level)
    set_subsyntax_pattern_idx(0)
    current_syntax, subsyntax_info, current_pattern_idx, current_level =
      retrieve_syntax_state(incoming_syntax, state)
  end

  local function find_text(text, p, offset, at_start, close, byte_offset)
    local target, res = p.pattern or p.regex, { 1, offset - 1 }
    local p_idx = close and 2 or 1
    local code = type(target) == "table" and target[p_idx] or target
    if p.disabled then return end

    if p.whole_line == nil then p.whole_line = { } end
    if p.whole_line[p_idx] == nil then
      -- Match patterns that start with '^'
      p.whole_line[p_idx] = code:umatch("^%^") and true or false
      if p.whole_line[p_idx] then
        -- Remove '^' from the beginning of the pattern
        if type(target) == "table" then
          target[p_idx] = code:usub(2)
          code = target[p_idx]
        else
          p.pattern = p.pattern and code:usub(2)
          p.regex = p.regex and code:usub(2)
          code = p.pattern or p.regex
        end
      end
    end

    if p.regex and type(p.regex) ~= "table" then
      p._regex = p._regex or regex.compile(p.regex)
      code = p._regex
    end

    -- C merged-matcher path for close-delimiter searches. Mirrors the
    -- escaped-start check above (bug-compatible: an offset right after an
    -- odd number of escape characters gives up without searching further)
    -- and the escaped-match retry of the repeat loop below.
    if close and p._tc then
      if type(target) == "table" and target[3] then
        local count = 0
        local jb = (byte_offset or char_to_byte(text, offset)) - 1
        while jb >= 1 do
          if string.byte(text, jb) ~= target[3]:ubyte(1) then break end
          count = count + 1
          jb = jb - 1
        end
        if count % 2 == 1 then return end
      end
      local esc = type(target) == "table" and target[3] or nil
      local next_pos = offset
      local next_byte = byte_offset or char_to_byte(text, offset)
      while true do
        if p.whole_line[p_idx] and next_pos > 1 then return end
        local r = table.pack(tokenizer_c.search(p._tc, text, next_byte, next_pos,
          at_start or p.whole_line[p_idx] or false))
        if r[1] == nil then return end
        last_match_sb, last_match_eb = r[3] + 1, r[4] + 1
        if not esc then return r[1], r[2], table.unpack(r, 5, r.n) end
        local count = 0
        local jb = r[3]
        while jb >= 1 do
          if string.byte(text, jb) ~= esc:ubyte(1) then break end
          count = count + 1
          jb = jb - 1
        end
        if count % 2 == 0 then
          return r[1], r[2], table.unpack(r, 5, r.n)
        elseif at_start then
          return
        end
        next_pos = r[2] + 1
        next_byte = r[4] + 1
      end
    end

    -- byte-position anchor for O(1) regex offsets instead of ucharpos/ulen
    -- rescans from the start of the line (quadratic on long lines)
    local anchor_byte = byte_offset or char_to_byte(text, offset)
    -- (search_char, search_byte) track the current search start: the regex
    -- is searched from a byte offset while char results are derived by
    -- counting lead bytes incrementally from this anchor.
    local search_byte, search_char = anchor_byte, offset

    repeat
      local next = res[2] + 1
      -- If the pattern contained '^', allow matching only the whole line
      if p.whole_line[p_idx] and next > 1 then
        return
      end
      res = p.pattern and { text:ufind((at_start or p.whole_line[p_idx]) and "^" .. code or code, next) }
        or { regex.find(code, text, search_byte, (at_start or p.whole_line[p_idx]) and regex.ANCHORED or 0) }
      if p.regex and #res > 0 then -- set correct utf8 len for regex result
        last_match_eb = res[2] + 1 -- byte end (before char conversion below)
        -- count chars incrementally from the anchor instead of ulen(text:sub(1, x))
        local function chars_to(byte_pos)
          local n = 0
          for b = search_byte, byte_pos - 1 do
            local c = string.byte(text, b)
            if c < 0x80 or c >= 0xC0 then n = n + 1 end
          end
          return n
        end
        local char_pos_1 = res[1] > search_byte and (search_char + chars_to(res[1])) or next
        local char_pos_2 = search_char + chars_to(res[2])
        for i=3,#res do
          res[i] = search_char + chars_to(res[i])
        end
        res[1] = char_pos_1
        res[2] = char_pos_2
      end
      if not res[1] then return end
      if not p.regex then
        last_match_eb = advance_bytes(text, anchor_byte, res[2] - offset + 1)
      end
      if res[1] and target[3] then
        -- Check to see if the escaped character is there,
        -- and if it is not itself escaped.
        local count = 0
        local jb = advance_bytes(text, anchor_byte, res[1] - offset) - 1
        while jb >= 1 do
          if string.byte(text, jb) ~= target[3]:ubyte(1) then break end
          count = count + 1
          jb = jb - 1
        end
        if count % 2 == 0 then
          -- The match is not escaped, so confirm it
          break
        else
          -- The match is escaped, so avoid it
          res[1] = false
          search_byte = last_match_eb
          search_char = res[2] + 1
        end
      end
    until at_start or not close or not target[3]
    return table.unpack(res)
  end

  local text_len = text:ulen()
  local start_time = system.get_time()
  local starting_i = i
  while i <= text_len do
    -- Every 200 chars, check if we're out of time
    if i - starting_i > 200 then
      starting_i = i
      if system.get_time() - start_time > 0.5 / config.fps then
        -- We're out of time
        push_token(res, "incomplete", text:sub(byte_i))
        return res, string.char(0), {
          res = res,
          i = i,
          state = state,
          byte_i = byte_i,
        }
      end
    end
    -- continue trying to match the end pattern of a pair if we have a state set
    if current_pattern_idx > 0 then
      local p = current_syntax.patterns[current_pattern_idx]
      local find_results = { find_text(text, p, i, false, true, byte_i) }
      local s, e = find_results[1], find_results[2]
      local p_sb, p_eb = last_match_sb, last_match_eb
      -- Use the first token type specified in the type table for the "middle"
      -- part of the subsyntax.
      local token_type = type(p.type) == "table" and p.type[1] or p.type

      local cont = true
      -- If we're in subsyntax mode, always check to see if we end our syntax
      -- first, before the found delimeter, as ending the subsyntax takes
      -- precedence over ending the delimiter in the subsyntax.
      if subsyntax_info then
        local ss, se = find_text(text, subsyntax_info, i, false, true, byte_i)
        local ss_sb, ss_eb = last_match_sb, last_match_eb
        -- If we find that we end the subsyntax before the
        -- delimiter, push the token, and signal we shouldn't
        -- treat the bit after as a token to be normally parsed
        -- (as it's the syntax delimiter).
        if ss and (s == nil or ss < s) then
          push_token(res, token_type, text:usub(i, ss - 1))
          i = ss
          byte_i = ss_sb or char_to_byte(text, i)
          cont = false
        end
      end
      -- If we don't have any concerns about syntax delimiters,
      -- continue on as normal.
      if cont then
        if s then
          -- Push remaining token before the end delimiter
          if s > i then
            push_token(res, token_type, text:usub(i, s - 1))
          end
          -- Push the end delimiter
          push_tokens(res, current_syntax, p, text, find_results, i, byte_i)
          set_subsyntax_pattern_idx(0)
          i = e + 1
          byte_i = p_eb or char_to_byte(text, i)
        else
          push_token(res, token_type, text:sub(byte_i))
          break
        end
      end
    end
    -- General end of syntax check. Applies in the case where
    -- we're ending early in the middle of a delimiter, or
    -- just normally, upon finding a token.
    while subsyntax_info do
      local find_results = { find_text(text, subsyntax_info, i, true, true, byte_i) }
      local s, e = find_results[1], find_results[2]
      if s then
        push_tokens(res, current_syntax, subsyntax_info, text, find_results, i, byte_i)
        -- On finding unescaped delimiter, pop it.
        pop_subsyntax()
        i = e + 1
        byte_i = last_match_eb or char_to_byte(text, i)
      else
        break
      end
    end

    -- find matching pattern
    local matched = false
    last_match_sb, last_match_eb = nil, nil
    local find_results, matched_n, matched_p
    local comp = tc_compile(current_syntax)
    if comp and comp.set then
      -- C merged matcher: match_set answers "best supported match from
      -- `from` onward" in one pass; regex / uncompilable / disabled
      -- patterns keep their original relative order and run between
      -- `from` and the C winner exactly as the loop below would.
      local from, rejected, wlen = 1, false, nil
      repeat
        rejected = false
        find_results = nil
        local r = table.pack(tokenizer_c.match_set(comp.set, text, byte_i, i, i == 1, from))
        local widx = r[1]
        if not widx then wlen = r[2] end
        for k = from, (widx or #current_syntax.patterns + 1) - 1 do
          if not comp.supported[k] then
            local pk = current_syntax.patterns[k]
            if not pk.disabled then
              local fr = { find_text(text, pk, i, true, false, byte_i) }
              if fr[1] then
                find_results, matched_n, matched_p = fr, k, pk
                break
              end
            end
          end
        end
        if not find_results and widx then
          local wp = current_syntax.patterns[widx]
          local target = wp.pattern
          local esc = type(target) == "table" and target[3] or nil
          local escaped = false
          if esc then
            -- mirror find_text's escaped-open check
            local count = 0
            local jb = r[4] -- 1-based byte of the char before r[2]
            while jb >= 1 do
              if string.byte(text, jb) ~= esc:ubyte(1) then break end
              count = count + 1
              jb = jb - 1
            end
            escaped = count % 2 == 1
          end
          if wp.disabled or escaped then
            from, rejected = widx + 1, true
          else
            find_results = { r[2], r[3], table.unpack(r, 6, r.n) }
            matched_n, matched_p = widx, wp
            last_match_sb, last_match_eb = r[4] + 1, r[5] + 1
          end
        end
        if find_results and find_results[1] > find_results[2] then
          report_bad_pattern(core.warn, current_syntax, matched_n,
              "Pattern successfully matched, but nothing was captured.")
          find_results = nil
          from, rejected = matched_n + 1, true
        end
      until not rejected
      if not find_results and wlen then
        -- no pattern matched at this position: consume one character
        local bw = advance_bytes(text, byte_i, 1) - byte_i
        push_token(res, "normal", text:sub(byte_i, byte_i + bw - 1))
        i = i + 1
        byte_i = byte_i + bw
        matched = true
      end
    else
      -- original per-pattern loop (fallback when the C matcher is off or
      -- compiled nothing for this syntax)
      for n, p in ipairs(current_syntax.patterns) do
        local fr = { find_text(text, p, i, true, false, byte_i) }
        if fr[1] then
          if fr[1] > fr[2] then
            report_bad_pattern(core.warn, current_syntax, n,
              "Pattern successfully matched, but nothing was captured.")
          else
            find_results, matched_n, matched_p = fr, n, p
            break
          end
        end
      end
    end

    if find_results then
      local p = matched_p
      -- Check for patterns with mismatching number of `types`
      local type_is_table = type(p.type) == "table"
      local n_types = type_is_table and #p.type or 1
      if #find_results == 2 and type_is_table then
        report_bad_pattern(core.warn, current_syntax, matched_n,
          "Token type is a table, but a string was expected.")
        p.type = p.type[1]
      elseif #find_results - 1 > n_types then
        report_bad_pattern(core.error, current_syntax, matched_n,
          "Not enough token types: got %d needed %d.", n_types, #find_results - 1)
      elseif #find_results - 1 < n_types then
        report_bad_pattern(core.warn, current_syntax, matched_n,
          "Too many token types: got %d needed %d.", n_types, #find_results - 1)
      end

      -- matched pattern; make and add tokens
      push_tokens(res, current_syntax, p, text, find_results, i, byte_i)
      -- update state if this was a start|end pattern pair
      if type(p.pattern or p.regex) == "table" then
        -- If we have a subsyntax, push that onto the subsyntax stack.
        if p.syntax then
          push_subsyntax(p, matched_n)
        else
          set_subsyntax_pattern_idx(matched_n)
        end
      end
      -- move cursor past this token
      i = find_results[2] + 1
      byte_i = last_match_eb or char_to_byte(text, i)
      matched = true
    end

    -- consume character if we didn't match
    if not matched then
      push_token(res, "normal", text:usub(i, i))
      i = i + 1
      byte_i = char_to_byte(text, i)
    end
  end

  return res, state
end


local function iter(t, i)
  i = i + 2
  local type, text = t[i], t[i+1]
  if type then
    return i, type, text
  end
end

function tokenizer.each_token(t)
  return iter, t, -1
end


return tokenizer
