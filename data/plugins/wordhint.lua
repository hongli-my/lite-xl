-- mod-version:4
-- wordhint: English word completion with Chinese translation.
--
-- Registers an autocomplete source that matches the current word prefix
-- against a local dictionary (ECDICT subset, ~57k high-frequency words).
-- Each suggestion shows the translation as `info` (right-aligned summary)
-- and the full definition + phonetic as `desc` (description box on select).
--
-- Optionally, when an AI backend (pi-bridge or OpenAI-compatible) is
-- available, hovering a word also fetches a sentence-level translation of
-- the current line for context.  This is async and non-blocking.
--
-- Dictionary file: data/plugins/wordhint/ecdict.tsv
-- Format: word<TAB>phonetic<TAB>translation<TAB>pos  (sorted by word, lowercase)

local common = require "core.common"
local config = require "core.config"
local core   = require "core"
local autocomplete = require "plugins.autocomplete"
local json   = require "core.json"
local process = require "core.process"
local translate = require "core.doc.translate"

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------
config.plugins.wordhint = common.merge({
  -- Minimum prefix length to trigger word hints
  min_len = 3,
  -- Maximum suggestions to show
  max_suggestions = 15,
  -- AI sentence translation: "pibridge" | "openai" | "off"
  sentence_mode = "pibridge",
  -- pi-bridge endpoint (same default as aichat)
  pibridge_api_base = "http://127.0.0.1:8643",
  -- OpenAI-compatible settings (only used when sentence_mode == "openai")
  openai_api_key = os.getenv("OPENAI_API_KEY") or "",
  openai_endpoint = "https://api.openai.com/v1",
  openai_model = "gpt-4o-mini",
  curl_path = "/usr/bin/curl",
}, config.plugins.wordhint)

-------------------------------------------------------------------------------
-- Dictionary: sorted TSV with binary search
-------------------------------------------------------------------------------

local dict_file = nil
local dict_size = 0

local function resolve_dict_path()
  local candidates = {
    DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "wordhint" .. PATHSEP .. "ecdict.tsv",
  }
  if USERDIR then
    table.insert(candidates, USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "wordhint" .. PATHSEP .. "ecdict.tsv")
  end
  for _, p in ipairs(candidates) do
    local info = system.get_file_info(p)
    if info and info.type == "file" then
      return p
    end
  end
  return nil
end

local function open_dict()
  local path = resolve_dict_path()
  if not path then
    return false
  end
  dict_file = io.open(path, "rb")
  if not dict_file then
    return false
  end
  dict_size = dict_file:seek("end") or 0
  dict_file:seek("set")
  core.log_quiet("wordhint: loaded %s (%.1f KB)", common.home_encode(path), dict_size / 1024)
  return true
end

-- Find the byte offset of the start of the line containing byte offset `offset`.
-- Scans backwards for '\n'.
local function line_start(offset)
  if offset <= 0 then return 0 end
  local chunk_size = 512
  local pos = offset
  while pos > 0 do
    local start = math.max(0, pos - chunk_size)
    dict_file:seek("set", start)
    local data = dict_file:read(pos - start)
    if not data then return 0 end
    local nl = data:reverse():find("\n", 1, true)
    if nl then
      return start + #data - nl + 1 -- byte after the '\n'
    end
    pos = start
    if start == 0 then return 0 end
  end
  return 0
end

local function parse_entry(line)
  if not line or #line == 0 then return nil end
  local word, phonetic, trans, pos = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
  if not word then return nil end
  return word, phonetic, trans, pos
end

-- Binary search for the first word >= prefix (case-insensitive).
local function binary_search_prefix(prefix)
  if dict_size == 0 then return nil end
  prefix = prefix:lower()
  local lo, hi = 0, dict_size - 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local lstart = line_start(mid)
    dict_file:seek("set", lstart)
    local line = dict_file:read("*l")
    local word = parse_entry(line)
    if word then
      if word:lower() < prefix then
        lo = lstart + #line + 1
      else
        hi = lstart
      end
    else
      lo = lstart + 1
    end
  end
  return lo
end

-- Collect up to max_results words starting with prefix.
local function search_prefix(prefix, max_results)
  if not dict_file then return {} end
  prefix = prefix:lower()
  if #prefix < 1 then return {} end
  local start = binary_search_prefix(prefix)
  if not start then return {} end

  local results = {}
  local pos = start
  for _ = 1, 1000 do
    dict_file:seek("set", pos)
    local line = dict_file:read("*l")
    if not line or #line == 0 then break end
    local word, phonetic, trans, ppos = parse_entry(line)
    if not word then break end
    if word:lower():sub(1, #prefix) == prefix then
      table.insert(results, { word = word, phonetic = phonetic, trans = trans, pos = ppos })
      pos = pos + #line + 1
    else
      break
    end
    if #results >= max_results then break end
  end
  return results
end

-------------------------------------------------------------------------------
-- Formatting
-------------------------------------------------------------------------------

local function format_info(entry)
  local trans = entry.trans or ""
  local first = trans:match("^([^;；\n]+)") or trans
  first = first:gsub("^[a-z]+%.%s*", "")
  if #first > 25 then
    first = first:sub(1, 24) .. "…"
  end
  return first
end

local function format_desc(entry)
  local parts = {}
  if entry.phonetic and #entry.phonetic > 0 then
    table.insert(parts, "/" .. entry.phonetic .. "/")
  end
  if entry.pos and #entry.pos > 0 then
    table.insert(parts, "[" .. entry.pos .. "]")
  end
  local header = #parts > 0 and table.concat(parts, " ") .. "\n" or ""
  return header .. (entry.trans or ""):gsub("\\n", "\n")
end

-------------------------------------------------------------------------------
-- Sentence-level AI translation (async, non-blocking)
-------------------------------------------------------------------------------

local sentence_cache = {}

local function build_sentence_prompt(line_text, word)
  return string.format(
    'Translate the following English sentence to Chinese. '
    .. 'The user is looking at the word "%s". '
    .. 'Reply with ONLY the Chinese translation, no explanation.\n\n%s',
    word, line_text
  )
end

local function get_current_line_text()
  local av = core.active_view
  if not av or not av.doc then return nil end
  local line = av.doc:get_selection()
  return av.doc.lines[line], line
end

local function fetch_sentence_pibridge(line_text, word, callback)
  local cfg = config.plugins.wordhint
  local body = json.encode({ message = build_sentence_prompt(line_text, word) })
  core.add_thread(function()
    local ok, proc = pcall(process.start, {
      cfg.curl_path, "-s", "-m", "10",
      "-X", "POST", "-H", "Content-Type: application/json",
      "-d", body,
      cfg.pibridge_api_base .. "/chat/nonstream"
    })
    if not ok or not proc then callback(nil); return end
    proc:wait(12)
    local pok, out = pcall(proc.stdout.read, proc.stdout, "all", { timeout = 2 })
    if not pok then out = nil end
    if not out or out == "" then callback(nil); return end
    local jok, obj = pcall(json.decode, out)
    if jok and type(obj) == "table" then
      local reply = obj.reply or obj.content or obj.response or obj.text
      if reply and #reply > 0 then callback(reply); return end
    end
    callback(#out > 0 and out or nil)
  end)
end

local function fetch_sentence_openai(line_text, word, callback)
  local cfg = config.plugins.wordhint
  if not cfg.openai_api_key or #cfg.openai_api_key == 0 then
    callback(nil); return
  end
  local body = json.encode({
    model = cfg.openai_model,
    messages = {
      { role = "system", content = "You are a translator. Reply with ONLY the Chinese translation." },
      { role = "user", content = build_sentence_prompt(line_text, word) },
    },
    stream = false,
  })
  core.add_thread(function()
    local ok, proc = pcall(process.start, {
      cfg.curl_path, "-s", "-m", "10",
      "-H", "Authorization: Bearer " .. cfg.openai_api_key,
      "-H", "Content-Type: application/json",
      "-d", "@-",
      cfg.openai_endpoint .. "/chat/completions",
    })
    if not ok or not proc then callback(nil); return end
    pcall(function() proc.stdin:write(body); proc.stdin:close() end)
    proc:wait(12)
    local pok, out = pcall(proc.stdout.read, proc.stdout, "all", { timeout = 2 })
    if not pok then out = nil end
    if not out or out == "" then callback(nil); return end
    local jok, obj = pcall(json.decode, out)
    if jok and obj and obj.choices and obj.choices[1] then
      local content = obj.choices[1].message and obj.choices[1].message.content
      if content and #content > 0 then callback(content); return end
    end
    callback(nil)
  end)
end

local function on_item_hover(idx, item)
  if not item or not item.data or not item.data.word then return end
  local word = item.data.word
  local cfg = config.plugins.wordhint

  if sentence_cache[word] ~= nil then
    if sentence_cache[word] and #sentence_cache[word] > 0 then
      item.desc = item.data.base_desc .. "\n\n📜 " .. sentence_cache[word]
      core.redraw = true
    end
    return
  end
  sentence_cache[word] = "" -- mark in-progress

  local line_text = get_current_line_text()
  if not line_text or #line_text < 2 then return end

  local fetch_fn
  if cfg.sentence_mode == "pibridge" then
    fetch_fn = fetch_sentence_pibridge
  elseif cfg.sentence_mode == "openai" then
    fetch_fn = fetch_sentence_openai
  else
    return
  end

  fetch_fn(line_text, word, function(translation)
    sentence_cache[word] = translation or false
    if translation and #translation > 0 then
      item.desc = item.data.base_desc .. "\n\n📜 " .. translation
      core.redraw = true
    end
  end)
end

local item_mt = { __tostring = function(t) return t.text end }

local function build_items(prefix)
  local cfg = config.plugins.wordhint
  if #prefix < cfg.min_len then return {} end
  if not prefix:match("^[a-zA-Z]+$") then return {} end

  local entries = search_prefix(prefix, cfg.max_suggestions)
  local items = {}
  for _, entry in ipairs(entries) do
    local desc = format_desc(entry)
    table.insert(items, setmetatable({
      text = entry.word,
      info = format_info(entry),
      desc = desc,
      icon = "function",
      onhover = on_item_hover,
      data = { word = entry.word, base_desc = desc },
    }, item_mt))
  end
  return items
end

-- Register the source with empty items; we update them dynamically on each keystroke.
autocomplete.add({ name = "wordhint", files = ".*", items = {} })

-- We hook Doc:text_input and Doc.remove to refresh items AFTER the text
-- changes but BEFORE autocomplete's show_autocomplete() reads them.
local function refresh_wordhint_items()
  if not autocomplete.map["wordhint"] then return end
  local av = core.active_view
  if not av or not av.doc then
    autocomplete.map["wordhint"].items = {}
    return
  end
  local line2, col2 = av.doc:get_selection()
  local line1, col1 = av.doc:position_offset(line2, col2, translate.start_of_word)
  local prefix = av.doc:get_text(line1, col1, line2, col2)
  autocomplete.map["wordhint"].items = build_items(prefix)
end

-- We hook Doc:text_input (not RootView.on_text_input) because we need to
-- refresh items AFTER the text is inserted into the doc, but BEFORE
-- autocomplete's show_autocomplete() runs.  The call chain is:
--   RootView.on_text_input (autocomplete patch) → original → DocView:on_text_input
--   → Doc:text_input (our hook refreshes items here)
--   → back to autocomplete patch → show_autocomplete() reads fresh items
local Doc = require "core.doc"
local orig_doc_text_input = Doc.text_input
Doc.text_input = function(self, text, idx)
  orig_doc_text_input(self, text, idx)
  refresh_wordhint_items()
end

local orig_doc_remove = Doc.remove
Doc.remove = function(self, line1, col1, line2, col2)
  local r = orig_doc_remove(self, line1, col1, line2, col2)
  refresh_wordhint_items()
  return r
end
-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------

if not open_dict() then
  core.warn("wordhint: dictionary not found (expected data/plugins/wordhint/ecdict.tsv)")
else
  core.log_quiet("wordhint: ready")
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------
local wordhint = {}

function wordhint.search(prefix, max_results)
  return search_prefix(prefix, max_results or 20)
end

function wordhint.lookup(word)
  local entries = search_prefix(word:lower(), 1)
  if entries[1] and entries[1].word:lower() == word:lower() then
    return entries[1]
  end
  return nil
end

return wordhint
