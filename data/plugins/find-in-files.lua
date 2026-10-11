-- mod-version:4
-- find-in-files: Sublime's cmd+shift+F -- live full-project text search.
--
-- Typing in the prompt restarts a time-sliced background scan over the
-- project's files; results stream into the suggestion list as they are found
-- ("path:line" + the matching line right-aligned, jump with enter).  The
-- search is a literal substring match with smart case: all-lowercase
-- patterns ignore case, any uppercase makes it case-sensitive.

local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local command = require "core.command"

config.plugins.find_in_files = common.merge({
  -- stop collecting after this many results
  max_results = 1000,
  -- files bigger than this many bytes are skipped
  max_file_size = 1024 * 1024,
  -- minimum pattern length before the project is scanned
  min_pattern_length = 2,
}, config.plugins.find_in_files)

local token = 0        -- invalidates in-flight scans
local pattern = nil    -- the pattern the current scan is for
local results = {}     -- accumulated results for `pattern`

local function display_path(project_index, project, filename)
  if project_index == 1 then
    return filename:sub(#project.path + 2)
  end
  return common.home_encode(filename)
end

local function line_matches(line, plain, case_sensitive)
  if case_sensitive then
    return line:find(plain, 1, true)
  end
  return line:lower():find(plain, 1, true)
end

---Background scan: walks the project's files, collects matching lines into
---`results`, refreshing the suggestion list as it goes.  Dies silently when
---a newer scan starts (token mismatch) or the prompt closes.
local function start_scan(text, mytoken)
  local cfg = config.plugins.find_in_files
  local plain = text
  local case_sensitive = text ~= text:lower()
  core.add_thread(function()
    coroutine.yield(0.3)  -- debounce: give fast typists a chance to finish
    if mytoken ~= token then return end
    local slice_start = system.get_time()
    for pi, project in ipairs(core.projects) do
      for _, item in project:files() do
        if mytoken ~= token then return end
        if #results >= cfg.max_results then return end
        local path = item.filename
        if path and #path > 0 then
          local file = io.open(path, "rb")
          if file then
            local content = file:read("*a")
            file:close()
            if content and #content <= cfg.max_file_size
                and not content:find("%z") then
              local display = display_path(pi, project, path)
              local lineno, s = 0, 1
              while s <= #content do
                local e = content:find("\n", s, true) or #content + 1
                lineno = lineno + 1
                local line = content:sub(s, e - 1)
                local col = line_matches(line, plain, case_sensitive)
                if col then
                  results[#results + 1] = {
                    file = path, display = display, line = lineno,
                    col = col, content = line,
                  }
                  if #results >= cfg.max_results then break end
                end
                s = e + 1
              end
            end
          end
        end
        local diff = system.get_time() - slice_start
        if diff > 0.5 / config.fps then
          if core.command_view.state.suggest then
            core.command_view:update_suggestions()
          end
          coroutine.yield(0)
          slice_start = system.get_time()
        end
      end
    end
  end)
end

local function build_suggestions()
  local res = {}
  for _, r in ipairs(results) do
    local content = r.content:match("^%s*(.-)%s*$") or ""
    if #content > 120 then content = content:sub(1, 120) .. "…" end
    res[#res + 1] = {
      text = r.display .. ":" .. r.line,
      info = content,
      __file = r.file,
      __line = r.line,
      __col = r.col,
    }
  end
  return res
end

command.add(nil, {
  ["files:search"] = function()
    token = token + 1
    pattern, results = nil, {}
    core.command_view:enter("Find in Files", {
      submit = function(text, item)
        if item and item.__file then
          local doc = core.open_doc(common.home_expand(item.__file))
          core.root_view:open_doc(doc)
          doc:set_selection(item.__line, item.__col)
          local dv = core.active_view
          if dv and dv.scroll_to_line then
            dv:scroll_to_line(item.__line, true)
          end
        end
      end,
      suggest = function(text)
        local cfg = config.plugins.find_in_files
        if text ~= pattern then
          pattern = text
          results = {}
          token = token + 1
          if #text >= cfg.min_pattern_length then
            start_scan(text, token)
          end
        end
        return build_suggestions()
      end,
      cancel = function()
        token = token + 1
      end,
    })
  end,
})

keymap.add({
  [(PLATFORM == "Mac OS X" or PLATFORM == "macOS")
    and "cmd+shift+f" or "ctrl+shift+f"] = "files:search",
}, true)
