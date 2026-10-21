-- mod-version:4
--
-- Git status for the treeview and the editor gutter.
--
-- Read-only, Sublime-style integration.  Only UNCOMMITTED changes are shown:
-- a file that is already in HEAD (clean) gets no colour, no badge and no line
-- marker, so committing a change makes all of it disappear on the next
-- refresh.
--
--   * sidebar: changed files are tinted by status and get a one-letter badge
--     on the right (A = added/untracked, M = modified, D = deleted,
--     R = renamed, C = conflict).  Directories show the aggregate status of
--     their children, and a small dot marks buffers with unsaved edits.
--   * editor: the gutter gets a thin green bar on added lines, an amber bar
--     on modified lines, and a red tick at deletion boundaries.  Markers are
--     computed against HEAD from the live buffer, so they follow typing and
--     vanish when the change is committed.
--
-- Local projects run git directly.  Remote projects (the cache directories
-- created by plugins/remote_projects.lua) run git over that plugin's ssh
-- channel, so password/askpass handling stays in exactly one place.
--
-- Colours live in style.git_{added,modified,deleted,renamed,conflict}.
-- Themes with a light sidebar can override them with
-- style.sidebar_git_* (see colors/sublime_dark.lua and colors/slate.lua).

-- The loader uses require(); this guard also makes a stray dofile() harmless.
if rawget(_G, "__lite_xl_git_status") then
  return rawget(_G, "__lite_xl_git_status")
end

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"
local Doc = require "core.doc"
local process = require "process"

config.plugins.git_status = common.merge({
  enabled = true,

  -- How often the repository is polled (seconds).
  poll_interval = 4,
  remote_poll_interval = 15,
  -- A file save queues a status refresh this many seconds later.
  save_refresh_delay = 0.3,
  -- A remote file that appears after the initial directory listing is
  -- materialized as a 0-byte placeholder so the treeview can show its badge.
  materialize_remote_new_files = true,

  -- Live buffer-vs-HEAD diff: minimum delay between two computations.
  live_diff_interval = 0.3,
  -- Also diff a clean file's unsaved buffer against HEAD (Sublime-style
  -- gutter markers).  The sidebar badge still only reflects git status.
  live_diff_clean_files = true,
  -- Files larger than this (lines) still get sidebar status but no gutter
  -- markers; running a diff on every keystroke would be too expensive.
  max_live_diff_lines = 20000,
  -- Refuse to load blobs larger than this into memory.
  max_head_bytes = 4 * 1024 * 1024,
  max_status_bytes = 16 * 1024 * 1024,

  -- Sidebar decorations.
  sidebar_colors = true,
  sidebar_badges = true,
  sidebar_dirty_dot = true,
  -- Gutter decorations.
  gutter_markers = true,

  -- Override when git is not on PATH (e.g. a Homebrew-only install).
  git_binary = "git",
}, config.plugins.git_status)

local M = {}

local cfg = config.plugins.git_status
local DEFAULT_POLL = 4
local REMOTE_DEFAULT_POLL = 15
local SIDEBAR_GAP = math.max(4, common.round(4 * SCALE))

-- Colors in Lite XL carry an alpha channel in the 0-255 range (common.color);
-- an alpha of 1 here would make the fallback almost invisible.
local FALLBACK = {
  added    = { 0.45, 0.78, 0.55, 255 },
  modified = { 0.95, 0.75, 0.40, 255 },
  deleted  = { 0.92, 0.40, 0.40, 255 },
  renamed  = { 0.45, 0.65, 0.95, 255 },
  conflict = { 0.76, 0.55, 0.95, 255 },
}

local STATUS_COLOR_KEY = {
  A = "added",
  M = "modified",
  D = "deleted",
  R = "renamed",
  C = "conflict",
}

local STATUS_RANK = {
  C = 6,
  D = 5,
  R = 4,
  A = 3,
  M = 2,
}

-- ---------------------------------------------------------------------------
-- paths and processes
-- ---------------------------------------------------------------------------

local function is_under(child, parent, sep)
  sep = sep or PATHSEP
  return child == parent or child:sub(1, #parent + 1) == parent .. sep
end

local function map_local_path(root, rel)
  if PLATFORM == "Windows" then
    root = root:gsub("/", "\\")
  end
  return root .. PATHSEP .. rel:gsub("/", PATHSEP)
end

---Maps a path relative to a remote repository root to the matching file in
---the local cache directory.  Returns nil when the file lies outside the
---remote directory (the project only shows a subtree of the repository).
function M.map_remote_path(root, remote_dir, cache_path, rel)
  if not root or not remote_dir or not cache_path or not rel then return nil end
  remote_dir = remote_dir:gsub("/+$", "")
  local remote_abs = root .. "/" .. rel
  local tail
  if remote_abs == remote_dir then
    tail = ""
  elseif remote_abs:sub(1, #remote_dir + 1) == remote_dir .. "/" then
    tail = remote_abs:sub(#remote_dir + 2)
  else
    return nil
  end
  if tail == "" then return cache_path end
  return cache_path .. PATHSEP .. tail:gsub("/", PATHSEP)
end

local function shquote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

---Quotes a remote path for the remote shell while still letting a leading
---~ expand (single quotes would otherwise turn "~/proj" into a literal name).
local function sh_remote_path(path)
  path = tostring(path)
  if path:sub(1, 1) == "~" then
    local home = path:match("^~[^/]*") or "~"
    local tail = path:sub(#home + 1)
    if tail == "" then return home end
    return home .. shquote(tail)
  end
  return shquote(path)
end

---Runs a program in a coroutine, returning exit code, stdout, stderr and a
---truncation flag.  Never blocks the editor thread while the child runs.
local function run_capture(argv, cwd, env, max_bytes)
  local opts = {}
  if cwd then opts.cwd = cwd end
  if env then opts.env = env end
  if next(opts) == nil then opts = nil end

  local ok, proc = pcall(process.start, argv, opts)
  if not ok or not proc then
    return nil, nil, tostring(proc), false
  end
  if not coroutine.isyieldable() then
    -- All callers live in core.add_thread(); refuse rather than block.
    return nil, nil, "not in a coroutine", false
  end

  local cap = max_bytes or cfg.max_status_bytes
  local out, err = {}, {}
  local out_len, err_len = 0, 0
  local truncated = false

  while proc.process:running() do
    local chunk = proc.stdout:read(4096)
    if chunk and chunk ~= "" then
      if out_len < cap then
        local room = cap - out_len
        if #chunk > room then
          out[#out + 1] = chunk:sub(1, room)
          out_len = cap
          truncated = true
        else
          out[#out + 1] = chunk
          out_len = out_len + #chunk
        end
      else
        truncated = true
      end
    end
    local echunk = proc.stderr:read(4096)
    if echunk and echunk ~= "" and err_len < 65536 then
      err[#err + 1] = echunk
      err_len = err_len + #echunk
    end
    coroutine.yield(1 / config.fps)
  end

  local tail = proc.stdout:read("all")
  if tail and tail ~= "" and out_len < cap then
    local room = cap - out_len
    if #tail > room then
      out[#out + 1] = tail:sub(1, room)
      truncated = true
    else
      out[#out + 1] = tail
    end
  end
  local etail = proc.stderr:read("all")
  if etail and etail ~= "" and err_len < 65536 then
    err[#err + 1] = etail
  end

  return proc:wait(), table.concat(out), table.concat(err), truncated
end

local GIT_ENV = {
  GIT_TERMINAL_PROMPT = "0",
  GIT_OPTIONAL_LOCKS = "0",
  GIT_PAGER = "cat",
}

local function git()
  return cfg.git_binary or "git"
end

-- ---------------------------------------------------------------------------
-- parsing git status --porcelain -z (v1 format)
-- ---------------------------------------------------------------------------

---Turns the two porcelain status letters into the single letter shown in
---the sidebar.  Untracked files are "A"; unmerged entries are "C".
function M.display_code(xy)
  if not xy or #xy < 2 then return nil end
  local x, y = xy:sub(1, 1), xy:sub(2, 2)
  if x == "U" or y == "U" or xy == "AA" or xy == "DD" then return "C" end
  if xy == "??" then return "A" end
  if xy == "!!" then return nil end
  if x == "R" or y == "R" or x == "C" or y == "C" then return "R" end
  if x == "D" or y == "D" then return "D" end
  if x == "A" or y == "A" then return "A" end
  if x == "T" or y == "T" then return "M" end
  if x ~= " " or y ~= " " then return "M" end
  return nil
end

function M.merge_code(a, b)
  if not a then return b end
  if not b then return a end
  return (STATUS_RANK[a] or 0) >= (STATUS_RANK[b] or 0) and a or b
end

---Parses `git status --porcelain -z --untracked-files=all --branch`
---(the v1 format, spelled this way so git 1.8 on old remotes works).
---Returns the branch name and a list of { xy, path, old_path } entries.
function M.parse_status(out)
  local entries = {}
  local branch
  local i, n = 1, #out
  local first = true

  while i <= n do
    local j = out:find("\0", i, true)
    local item = out:sub(i, (j or n + 1) - 1)
    i = (j or n) + 1
    if item ~= "" then
      if first and item:sub(1, 3) == "## " then
        branch = item:sub(4)
        first = false
      else
        first = false
        local xy = item:sub(1, 2)
        local path = item:sub(4)
        local entry = { xy = xy, path = path }
        if xy:sub(1, 1) == "R" or xy:sub(1, 1) == "C" then
          local j2 = out:find("\0", i, true)
          entry.old_path = out:sub(i, (j2 or n + 1) - 1)
          i = (j2 or n) + 1
        end
        if xy ~= "!!" then
          entries[#entries + 1] = entry
        end
      end
    end
  end
  return branch, entries
end

---Splits `git rev-parse --verify -q HEAD; git status ...` output.
local function split_head_oid(out)
  local nl = out:find("\n", 1, true)
  if nl then
    local first = out:sub(1, nl - 1)
    if (#first == 40 or #first == 64) and first:match("^%x+$") then
      return out:sub(nl + 1), first
    end
  end
  return out, nil
end

-- ---------------------------------------------------------------------------
-- buffer-vs-HEAD diff (patience anchors + plain replacement fallback)
-- ---------------------------------------------------------------------------

---Longest increasing subsequence over pairs ordered by the first element.
local function lis_pairs(pairs_list)
  if #pairs_list == 0 then return {} end
  local tails, prev = {}, {}
  for idx = 1, #pairs_list do
    local v = pairs_list[idx][2]
    local lo, hi = 1, #tails
    while lo <= hi do
      local mid = (lo + hi) // 2
      if pairs_list[tails[mid]][2] < v then
        lo = mid + 1
      else
        hi = mid - 1
      end
    end
    prev[idx] = lo > 1 and tails[lo - 1] or nil
    tails[lo] = idx
  end
  -- Backtrack from the last tail.  Append + reverse: inserting at position 1
  -- on every step would turn this into an O(n^2) memmove.
  local anchors = {}
  local k = tails[#tails]
  while k do
    anchors[#anchors + 1] = pairs_list[k]
    k = prev[k]
  end
  for i = 1, math.floor(#anchors / 2) do
    local j = #anchors + 1 - i
    anchors[i], anchors[j] = anchors[j], anchors[i]
  end
  return anchors
end

---Finds lines that occur exactly once on both sides and keeps the longest
---monotone subset.  These become "anchors" between unchanged regions.
local function find_anchors(a, a0, a1, b, b0, b1)
  local count_a, count_b, pos_b = {}, {}, {}
  for i = a0, a1 - 1 do
    local x = a[i]
    count_a[x] = (count_a[x] or 0) + 1
  end
  for j = b0, b1 - 1 do
    local x = b[j]
    local n = (count_b[x] or 0) + 1
    count_b[x] = n
    if n == 1 then
      pos_b[x] = j
    else
      pos_b[x] = nil
    end
  end
  local pairs_list = {}
  for i = a0, a1 - 1 do
    local x = a[i]
    if count_a[x] == 1 then
      local j = pos_b[x]
      if j and count_b[x] == 1 then
        pairs_list[#pairs_list + 1] = { i, j }
      end
    end
  end
  return lis_pairs(pairs_list)
end

---Computes gutter markers for `b` (the buffer) against `a` (HEAD).
---Returns sets keyed by line number:
---  add[line]        line was added
---  mod[line]        line was modified
---  del_top[line]    lines were deleted just above this line
---  del_bottom[line] lines were deleted at the end of the file
function M.diff_markers(a, b)
  local add, mod, del_top, del_bottom = {}, {}, {}, {}
  local stack = { { 1, #a + 1, 1, #b + 1 } }

  local function mark_deleted(boundary)
    if boundary <= #b then
      del_top[boundary] = true
    elseif #b > 0 then
      del_bottom[#b] = true
    end
  end

  while #stack > 0 do
    local r = table.remove(stack)
    local a0, a1, b0, b1 = r[1], r[2], r[3], r[4]

    while a0 < a1 and b0 < b1 and a[a0] == b[b0] do
      a0 = a0 + 1
      b0 = b0 + 1
    end
    while a1 > a0 and b1 > b0 and a[a1 - 1] == b[b1 - 1] do
      a1 = a1 - 1
      b1 = b1 - 1
    end

    if a0 == a1 and b0 == b1 then
      -- identical
    elseif a0 == a1 then
      for j = b0, b1 - 1 do add[j] = true end
    elseif b0 == b1 then
      mark_deleted(b0)
    else
      local anchors = find_anchors(a, a0, a1, b, b0, b1)
      if #anchors == 0 then
        for j = b0, b1 - 1 do mod[j] = true end
        if (a1 - a0) > (b1 - b0) then mark_deleted(b0) end
      else
        local pa, pb = a0, b0
        for k = 1, #anchors do
          local ai, bj = anchors[k][1], anchors[k][2]
          if pa < ai or pb < bj then
            stack[#stack + 1] = { pa, ai, pb, bj }
          end
          pa, pb = ai + 1, bj + 1
        end
        if pa < a1 or pb < b1 then
          stack[#stack + 1] = { pa, a1, pb, b1 }
        end
      end
    end
  end

  return { add = add, mod = mod, del_top = del_top, del_bottom = del_bottom }
end

---Splits a blob into lines the same way core.doc does: every line keeps the
---"\n" that Doc:load appends, CR of CRLF is removed, and a trailing newline
---does not create an extra empty line.  Returns nil for binary data.
function M.head_lines_from_text(text)
  if not text then return nil end
  if text:find("\0", 1, true) then return nil, "binary" end
  -- Doc:load materializes an empty file as one empty line; mirror that.
  if text == "" then return { "\n" } end
  local lines = {}
  local pos, n = 1, #text
  while pos <= n do
    local nl = text:find("\n", pos, true)
    local line
    if nl then
      line = text:sub(pos, nl - 1)
      pos = nl + 1
    else
      line = text:sub(pos)
      pos = n + 1
    end
    if line:byte(-1) == 13 then line = line:sub(1, -2) end
    lines[#lines + 1] = line .. "\n"
  end
  return lines
end

local function all_added_markers(lines)
  local add = {}
  for i = 1, #lines do add[i] = true end
  return { add = add, mod = {}, del_top = {}, del_bottom = {} }
end

-- ---------------------------------------------------------------------------
-- repository contexts
-- ---------------------------------------------------------------------------

-- key -> context.  A context is one git repository (many local projects may
-- share it); remote projects get one context per ssh session.
local contexts = {}
-- project.path -> context (or nil while the repository is being resolved)
local project_ctx = {}
-- project.path / context key -> earliest retry time for a failed resolution
local retry_at = {}
-- remote context key -> true once the failure has been reported
local resolution_logged = {}

local function remote_api()
  return rawget(_G, "__lite_xl_remote_projects")
end

local function remote_session_for(path)
  local api = remote_api()
  if not api or not api._internal or not api._internal.session_for_path then
    return nil
  end
  return api._internal.session_for_path(path)
end

---Returns the remote plugin when it exposes the ssh helpers we need.
local function remote_ready()
  local api = remote_api()
  if api and api._internal and api._internal.ssh_command
     and api._internal.run_with_password then
    return api
  end
end

---Runs ssh through the remote plugin.  pcall here matters: a broken ssh
---spawn must fail one poll, not kill the polling coroutine.
local function remote_run(api, args, account)
  local ok, res, err = pcall(api._internal.run_with_password, args, account)
  if not ok then return false, tostring(res) end
  return res, err
end

local function new_local_ctx(root)
  return {
    key = "local:" .. root,
    kind = "local",
    root = root,
    name = root,
    projects = {},
    files = {},
    dirs = {},
    next_at = 0,
    interval = cfg.poll_interval or DEFAULT_POLL,
  }
end

local function new_remote_ctx(session, root, remote_dir_abs)
  return {
    key = "remote:" .. session.cache_path,
    kind = "remote",
    root = root,
    remote_dir_abs = remote_dir_abs,
    session = session,
    name = session.profile or session.cache_path,
    projects = { { path = session.cache_path } },
    files = {},
    dirs = {},
    next_at = 0,
    interval = cfg.remote_poll_interval or REMOTE_DEFAULT_POLL,
  }
end

local function add_project(ctx, path)
  for i = 1, #ctx.projects do
    if ctx.projects[i].path == path then return false end
  end
  ctx.projects[#ctx.projects + 1] = { path = path }
  return true
end

local function remove_project(ctx, path)
  for i = #ctx.projects, 1, -1 do
    if ctx.projects[i].path == path then
      table.remove(ctx.projects, i)
    end
  end
  if #ctx.projects == 0 then
    contexts[ctx.key] = nil
  end
end

---Finds the most specific project containing `abs`.
local function owner_project(ctx, abs)
  local best, best_len
  for i = 1, #ctx.projects do
    local p = ctx.projects[i]
    if is_under(abs, p.path, PATHSEP) then
      local len = #p.path
      if not best_len or len > best_len then
        best, best_len = p, len
      end
    end
  end
  return best
end

local function find_ctx_for_realpath(abs)
  local best, best_len
  for _, ctx in pairs(contexts) do
    for i = 1, #ctx.projects do
      local p = ctx.projects[i]
      if is_under(abs, p.path, PATHSEP) then
        local len = #p.path
        if not best_len or len > best_len then
          best, best_len = ctx, len
        end
      end
    end
  end
  return best
end

---Files opened through a symlinked path (a classic one on macOS is /tmp,
---which is a link to /private/tmp) carry the user's spelling in
---doc.abs_filename while projects and git status use the real path.  Try
---the spelling first (the common case, no syscall) and fall back to
---realpath only when it does not match.
local function real_path(abs)
  if system.absolute_path then
    local real = system.absolute_path(abs)
    if real and real ~= abs then return real end
  end
  return nil
end

local function find_ctx_for_abs(abs)
  local ctx = find_ctx_for_realpath(abs)
  if ctx then return ctx end
  local real = real_path(abs)
  if real then return find_ctx_for_realpath(real) end
end

---Public helper: "A"/"M"/"D"/"R"/"C" for a file or directory, or nil when
---the path is clean/untracked by the integration.
function M.status_for(abs)
  if not abs then return nil end
  -- Treeview paths are built from the (already canonical) project path, so
  -- the direct lookup always matches.  Do not fall back to realpath here:
  -- this runs for every visible row and every frame.
  local ctx = find_ctx_for_realpath(abs)
  if not ctx then return nil end
  local entry = ctx.files[abs]
  if entry then return entry.code end
  return ctx.dirs[abs]
end

local function find_entry(abs)
  local ctx = find_ctx_for_abs(abs)
  if not ctx then return nil end
  local entry = ctx.files[abs]
  if not entry then
    local real = real_path(abs)
    if real then entry = ctx.files[real] end
  end
  return ctx, entry
end

---Repository-relative path for a file that has no `git status` entry yet.
---Used to diff a clean file's unsaved buffer against HEAD (Sublime-style
---live gutter markers).
local function head_rel_for(ctx, abs)
  if ctx.kind == "local" then
    if not is_under(abs, ctx.root, PATHSEP) then return nil end
    return abs:sub(#ctx.root + 2):gsub(PATHSEP, "/")
  else
    local cache = ctx.session.cache_path
    if not is_under(abs, cache, PATHSEP) then return nil end
    local rel = abs:sub(#cache + 2):gsub(PATHSEP, "/")
    local remote_abs = ctx.remote_dir_abs .. "/" .. rel
    if not is_under(remote_abs, ctx.root, "/") then return nil end
    return remote_abs:sub(#ctx.root + 2)
  end
end

local function add_dir_status(dirs, abs, code, owner)
  local dir = common.dirname(abs)
  while dir and is_under(dir, owner.path, PATHSEP) do
    dirs[dir] = M.merge_code(dirs[dir], code)
    if dir == owner.path then break end
    local parent = common.dirname(dir)
    if not parent or parent == dir then break end
    dir = parent
  end
end

-- ---------------------------------------------------------------------------
-- repository discovery and status fetching
-- ---------------------------------------------------------------------------

local function resolve_local_root(path)
  local code, out, err = run_capture(
    { git(), "-C", path, "rev-parse", "--show-toplevel" }, nil, GIT_ENV, 8192)
  if code ~= 0 then return nil, err end
  local root = out:match("^([^\r\n]+)")
  if not root or root == "" then return nil, "empty rev-parse output" end
  if PLATFORM == "Windows" then root = root:gsub("/", "\\") end
  return root
end

local function resolve_remote_root(session)
  local api = remote_ready()
  if not api then return nil, "remote plugin unavailable" end
  local args = api._internal.ssh_command(session.account, {})
  args[#args + 1] = "cd " .. sh_remote_path(session.remote_dir)
    .. " && git rev-parse --show-toplevel --show-prefix"
  local ok, out = remote_run(api, args, session.account)
  if not ok then return nil, out end
  local root, prefix = out:match("^([^\r\n]+)\r?\n([^\r\n]*)\r?\n?$")
  if not root then return nil, "unexpected rev-parse output" end
  if root ~= "/" then root = root:gsub("/+$", "") end
  prefix = (prefix or ""):gsub("/+$", "")
  local remote_dir_abs = root
  if prefix ~= "" then
    remote_dir_abs = root == "/" and ("/" .. prefix) or (root .. "/" .. prefix)
  end
  return root, remote_dir_abs
end

local function fetch_local_status(ctx)
  local code, out, err, truncated = run_capture(
    -- Plain --porcelain is the v1 format and also works on old git (1.8).
    { git(), "-C", ctx.root, "status", "--porcelain", "-z",
      "--untracked-files=all", "--branch" },
    nil, GIT_ENV, cfg.max_status_bytes)
  if code ~= 0 then return nil, err or ("git status exited with " .. tostring(code)) end
  local ocode, oid_out = run_capture(
    { git(), "-C", ctx.root, "rev-parse", "--verify", "-q", "HEAD" },
    nil, GIT_ENV, 8192)
  local oid
  if ocode == 0 and oid_out then
    oid = oid_out:match("^(%x+)\r?\n?$")
  end
  return out, oid, truncated
end

local function fetch_remote_status(ctx)
  local api = remote_ready()
  if not api then return nil, "remote plugin unavailable" end
  local args = api._internal.ssh_command(ctx.session.account, {})
  args[#args + 1] = "cd " .. sh_remote_path(ctx.root)
    .. " && git rev-parse --verify -q HEAD; git status --porcelain -z"
    .. " --untracked-files=all --branch"
  local ok, out = remote_run(api, args, ctx.session.account)
  if not ok then return nil, out end
  return split_head_oid(out)
end

local find_treeview -- assigned in the treeview section below

---Creates the cache placeholder for a remote path that is not in the cache
---yet (a file added on the remote after the initial listing).  The file is
---not downloaded: it is a 0-byte, unpulled placeholder, exactly like the
---ones remote_projects creates when it connects.
local function ensure_remote_placeholder(cache_root, rel)
  if rel == "" then return false end
  local target = cache_root .. PATHSEP .. rel:gsub("/", PATHSEP)
  if system.get_file_info(target) then return false end
  local parent = common.dirname(target)
  if parent then common.mkdirp(parent) end
  local f = io.open(target, "wb")
  if not f then return false end
  f:close()
  return true
end

local function apply_status(ctx, out, oid)
  local branch, entries = M.parse_status(out)
  local files, dirs = {}, {}
  local created_remote = false

  for i = 1, #entries do
    local e = entries[i]
    local code = M.display_code(e.xy)
    if code then
      local abs, owner
      if ctx.kind == "local" then
        abs = map_local_path(ctx.root, e.path)
        owner = owner_project(ctx, abs)
      else
        abs = M.map_remote_path(ctx.root, ctx.remote_dir_abs,
          ctx.session.cache_path, e.path)
        owner = ctx.projects[1]
      end
      if abs and owner and is_under(abs, owner.path, PATHSEP) then
        files[abs] = {
          code = code,
          xy = e.xy,
          untracked = e.xy == "??",
          head_rel = e.path,
          head_old_rel = e.old_path,
        }
        add_dir_status(dirs, abs, code, owner)

        -- A file created on the remote after the tree was listed has no
        -- cache entry, so the treeview would never show it.  Materialize it
        -- as an unpulled placeholder (0 bytes); pulling it later fetches the
        -- content.  Only file-like statuses are created (never submodules).
        if ctx.kind == "remote" and cfg.materialize_remote_new_files then
          local first = e.xy:sub(1, 1)
          if e.xy == "??" or first == "A" or first == "R" or first == "C" then
            local prefix_len = #ctx.session.cache_path
            local rel = abs:sub(prefix_len + 2)
            if ensure_remote_placeholder(ctx.session.cache_path, rel) then
              created_remote = true
            end
          end
        end
      end
    end
  end

  ctx.files = files
  ctx.dirs = dirs
  ctx.branch = branch
  ctx.head = oid

  if created_remote then
    local tv = find_treeview and find_treeview()
    if tv then tv.cache = {} end
    core.redraw = true
  end
end

-- ---------------------------------------------------------------------------
-- live diff (HEAD vs buffer)
-- ---------------------------------------------------------------------------

-- doc -> { markers, change_id, status_code, head_oid, head_rel, head_lines,
--          head_old_rel, head_failed, head_error_at, last_try, fetching }
local doc_state = setmetatable({}, { __mode = "k" })

local function state_for(doc)
  local st = doc_state[doc]
  if not st then
    st = {}
    doc_state[doc] = st
  end
  return st
end

local function remote_placeholder(ctx, abs)
  if ctx.kind ~= "remote" then return false end
  local api = remote_api()
  if not api or not api._internal or not api._internal.is_pulled then
    return false
  end
  return not api._internal.is_pulled(ctx.session, real_path(abs) or abs)
end

local function fetch_head(ctx, entry, max_bytes)
  local rels = { entry.head_rel }
  if entry.head_old_rel then rels[#rels + 1] = entry.head_old_rel end

  for i = 1, #rels do
    local rel = rels[i]
    if rel and rel ~= "" then
      if ctx.kind == "local" then
        local code, out, err, truncated = run_capture(
          { git(), "-C", ctx.root, "show", "HEAD:" .. rel },
          nil, GIT_ENV, max_bytes)
        if truncated then return nil, "too large" end
        if code == 0 then
          local lines, why = M.head_lines_from_text(out)
          if not lines then return nil, why end
          return { lines = lines, rel = rel, text = out }
        end
        if i == #rels then return nil, err or "git show failed" end
      else
        local api = remote_ready()
        if not api then return nil, "remote plugin unavailable" end
        local args = api._internal.ssh_command(ctx.session.account, {})
        -- Refuse to pull a huge blob over ssh: cat-file -s is cheap.
        local spec = shquote("HEAD:" .. rel)
        args[#args + 1] = "cd " .. sh_remote_path(ctx.root)
          .. " && s=$(git cat-file -s " .. spec .. " 2>/dev/null || echo 0)"
          .. " && if [ \"$s\" -le " .. tostring(max_bytes) .. " ]; then git show " .. spec
          .. "; else exit 3; fi"
        local ok, out = remote_run(api, args, ctx.session.account)
        if ok then
          local lines, why = M.head_lines_from_text(out)
          if not lines then return nil, why end
          return { lines = lines, rel = rel, text = out }
        end
        if type(out) == "string" and out:find("exited with code 3", 1, true) then
          return nil, "too large"
        end
        if i == #rels then return nil, out end
      end
    end
  end
  return nil, "not in HEAD"
end

local EMPTY_MARKERS = { add = {}, mod = {}, del_top = {}, del_bottom = {} }

local function compute_markers(doc, ctx, entry, st, now)
  local max_lines = cfg.max_live_diff_lines or 20000
  if #doc.lines > max_lines then
    st.markers = EMPTY_MARKERS
    st.change_id = doc:get_change_id()
    st.status_code = entry.code
    st.head_oid = ctx.head
    st.head_rel = entry.head_rel
    st.head_old_rel = entry.head_old_rel
    st.synthetic = entry.synthetic == true
    return
  end

  if entry.untracked then
    st.markers = all_added_markers(doc.lines)
    st.change_id = doc:get_change_id()
    st.status_code = entry.code
    st.head_oid = ctx.head
    st.head_rel = entry.head_rel
    st.head_old_rel = entry.head_old_rel
    st.synthetic = false
    return
  end

  local need_fetch = not st.head_lines
    or st.head_oid ~= ctx.head
    or st.head_rel ~= entry.head_rel
    or st.head_old_rel ~= entry.head_old_rel
    or (st.head_failed and st.head_failed ~= "binary"
        and st.head_failed ~= "too large" and st.head_failed ~= "not in HEAD"
        and now - (st.head_error_at or 0) > 10)

  if need_fetch then
    st.fetching = true
    local head, why = fetch_head(ctx, entry, cfg.max_head_bytes)
    st.fetching = false
    -- The buffer/status may have changed while git was running: re-check.
    local ctx2, entry2 = find_entry(doc.abs_filename)
    if ctx2 ~= ctx then return end
    if entry.synthetic then
      -- A real status appeared while HEAD was loading: recompute next tick
      -- with the real entry instead of mixing the two.
      if entry2 then return end
    elseif not entry2 or entry2.code ~= entry.code then
      return
    end
    if head and head.lines then
      st.head_lines = head.lines
      st.head_rel = head.rel
      st.head_old_rel = entry.head_old_rel
      st.head_oid = ctx.head
      st.head_failed = nil
    else
      st.head_lines = nil
      st.head_failed = why or "unknown"
      st.head_error_at = now
      st.head_oid = ctx.head
      st.head_rel = entry.head_rel
      st.head_old_rel = entry.head_old_rel
    end
  end

  if st.head_lines then
    if #st.head_lines > max_lines then
      st.markers = EMPTY_MARKERS
    else
      st.markers = M.diff_markers(st.head_lines, doc.lines)
    end
  elseif st.head_failed == "binary" or st.head_failed == "too large" then
    -- Keep a non-nil marker table so this is not retried on every tick.
    st.markers = EMPTY_MARKERS
  elseif entry.code == "A" then
    st.markers = all_added_markers(doc.lines)
    st.head_failed = "not in HEAD"
  else
    -- Retryable failure: show nothing for now but look again in ~10s.
    st.markers = EMPTY_MARKERS
    st.retry_at = now + 10
  end
  st.change_id = doc:get_change_id()
  st.status_code = entry.code
  st.head_oid = ctx.head
  st.synthetic = entry.synthetic == true
  core.redraw = true
end

local function update_active_markers(now)
  local view = core.active_view
  local doc = view and view.doc
  if not doc or not doc.abs_filename then return end
  if not view.get_line_height then return end

  local abs = doc.abs_filename
  local ctx, entry = find_entry(abs)
  local st = state_for(doc)

  if not ctx then
    if st.markers then
      st.markers = nil
      st.change_id = nil
      st.head_oid = nil
      st.status_code = nil
      st.head_rel = nil
      st.head_old_rel = nil
      st.synthetic = nil
      core.redraw = true
    end
    return
  end

  if not entry then
    -- A clean file can still have unsaved edits.  Show them against HEAD
    -- (Sublime does the same); the sidebar badge only appears once the file
    -- is actually dirty on disk.
    if not doc:is_dirty() or not cfg.live_diff_clean_files then
      if st.markers then
        st.markers = nil
        st.change_id = nil
        st.head_oid = nil
        st.status_code = nil
        st.head_rel = nil
        st.head_old_rel = nil
        st.synthetic = nil
        core.redraw = true
      end
      return
    end
    local rel = head_rel_for(ctx, real_path(abs) or abs)
    if not rel then
      if st.markers then st.markers = nil; core.redraw = true end
      return
    end
    entry = { code = "M", head_rel = rel, synthetic = true }
  end

  if remote_placeholder(ctx, abs) then
    if st.markers ~= EMPTY_MARKERS then
      st.markers = EMPTY_MARKERS
      st.change_id = nil
      st.head_oid = nil
      st.synthetic = nil
      core.redraw = true
    end
    return
  end

  local id = doc:get_change_id()
  local code_changed
  if entry.synthetic then
    code_changed = st.synthetic ~= true or st.head_rel ~= entry.head_rel
  else
    code_changed = st.synthetic == true
      or st.status_code ~= entry.code
      or st.head_rel ~= entry.head_rel
      or st.head_old_rel ~= entry.head_old_rel
  end
  local head_changed = st.head_oid ~= ctx.head
  -- A failed HEAD read is retried every ~10s (network hiccups, a path that
  -- appears after a fetch); binary/too-large verdicts never retry.
  local retry_due = st.head_failed ~= nil
    and st.head_failed ~= "binary"
    and st.head_failed ~= "too large"
    and st.head_failed ~= "not in HEAD"
    and now >= (st.retry_at or 0)
  if st.markers and st.change_id == id and not code_changed and not head_changed
     and not retry_due then
    return
  end
  -- A new status code or a new HEAD invalidates a previous "not in HEAD" /
  -- binary verdict; let the next computation look again.
  if code_changed or head_changed then st.head_failed = nil end

  local interval = cfg.live_diff_interval or 0.3
  if #doc.lines > 5000 then interval = interval * 2 end
  if st.fetching or now - (st.last_try or 0) < interval then return end
  st.last_try = now
  compute_markers(doc, ctx, entry, st, now)
end

-- ---------------------------------------------------------------------------
-- context synchronisation and polling
-- ---------------------------------------------------------------------------

local function sync_local_projects(now)
  local projects = {}
  for i = 1, #core.projects do projects[i] = core.projects[i] end

  local seen = {}
  for i = 1, #projects do
    local path = projects[i].path
    if remote_session_for(path) then
      -- The remote thread owns this one; detach a local context that may have
      -- been created before the remote session was attached.
      seen[path] = true
      local stale = project_ctx[path]
      if type(stale) == "table" then
        remove_project(stale, path)
        project_ctx[path] = nil
      end
    else
      seen[path] = true
      local ctx = project_ctx[path]
      if type(ctx) ~= "table" then
        local retry = retry_at[path]
        if not retry or now >= retry then
          local root = resolve_local_root(path)
          if root then
            local key = "local:" .. root
            local nctx = contexts[key]
            if not nctx then
              nctx = new_local_ctx(root)
              contexts[key] = nctx
            end
            if add_project(nctx, path) then nctx.next_at = 0 end
            project_ctx[path] = nctx
            retry_at[path] = nil
          else
            retry_at[path] = now + 60
            project_ctx[path] = nil
          end
        end
      end
    end
  end

  for path, ctx in pairs(project_ctx) do
    if type(ctx) == "table" and not seen[path] then
      remove_project(ctx, path)
      project_ctx[path] = nil
    end
  end
end

local function sync_remote_projects(now)
  local api = remote_api()
  local seen = {}
  if api and api._internal and api._internal.session_for_path then
    local projects = {}
    for i = 1, #core.projects do projects[i] = core.projects[i] end
    for i = 1, #projects do
      local session = api._internal.session_for_path(projects[i].path)
      if session then
        seen[session.cache_path] = true
        local key = "remote:" .. session.cache_path
        local ctx = contexts[key]
        if ctx and ctx.session ~= session then
          contexts[key] = nil
          ctx = nil
        end
        if not ctx then
          local retry = retry_at[key]
          if not retry or now >= retry then
            local root, detail = resolve_remote_root(session)
            if root then
              contexts[key] = new_remote_ctx(session, root, detail)
              retry_at[key] = nil
              resolution_logged[key] = nil
            else
              retry_at[key] = now + 60
              if not resolution_logged[key] then
                resolution_logged[key] = true
                core.log_quiet("[git] %s: %s", session.profile or key,
                  detail or "not a git repository")
              end
            end
          end
        end
      end
    end
  end

  for key, ctx in pairs(contexts) do
    if ctx.kind == "remote" and not seen[ctx.session.cache_path] then
      contexts[key] = nil
    end
  end
end

local function refresh_context(ctx)
  if ctx.running then return false end
  local cfg_now = config.plugins.git_status
  local base = ctx.kind == "remote"
    and (cfg_now.remote_poll_interval or REMOTE_DEFAULT_POLL)
    or (cfg_now.poll_interval or DEFAULT_POLL)

  ctx.running = true
  local started = system.get_time()
  local out, oid, truncated
  if ctx.kind == "local" then
    out, oid, truncated = fetch_local_status(ctx)
  else
    out, oid = fetch_remote_status(ctx)
  end
  local duration = system.get_time() - started
  ctx.running = false

  if out then
    apply_status(ctx, out, oid)
    ctx.interval = math.max(base, duration * 5)
    ctx.failures = 0
    ctx.logged = nil
    if truncated and not ctx.truncated_logged then
      ctx.truncated_logged = true
      core.log_quiet("[git] %s: status output truncated", ctx.name)
    end
  else
    ctx.failures = (ctx.failures or 0) + 1
    local backoff = math.min(math.max(base, (ctx.interval or base) * 2), 60)
    ctx.interval = backoff
    if not ctx.logged then
      ctx.logged = true
      core.log_quiet("[git] %s: %s", ctx.name, oid or "git status failed")
    end
  end

  ctx.last_run = system.get_time()
  ctx.next_at = ctx.last_run + (ctx.interval or base)
  core.redraw = true
  return true
end

local function poll_contexts(kind)
  if not config.plugins.git_status.enabled then return end

  if kind == "local" then
    sync_local_projects(system.get_time())
  else
    sync_remote_projects(system.get_time())
  end

  local now = system.get_time()
  local list = {}
  for _, ctx in pairs(contexts) do
    if ctx.kind == kind then list[#list + 1] = ctx end
  end
  for i = 1, #list do
    local ctx = list[i]
    if contexts[ctx.key] == ctx and now >= (ctx.next_at or 0) then
      refresh_context(ctx)
    end
  end
end

-- ---------------------------------------------------------------------------
-- sidebar integration
-- ---------------------------------------------------------------------------

local function sidebar_color(code)
  local key = STATUS_COLOR_KEY[code]
  if not key then return nil end
  return style["sidebar_git_" .. key] or style["git_" .. key] or FALLBACK[key]
end

local function gutter_color(code)
  local key = STATUS_COLOR_KEY[code]
  if not key then return nil end
  return style["git_" .. key] or FALLBACK[key]
end

local function doc_is_dirty(tv, abs)
  local set = tv and rawget(tv, "_git_dirty")
  if set then return set[abs] == true end
  for i = 1, #core.docs do
    local d = core.docs[i]
    if d.abs_filename == abs and d:is_dirty() then return true end
  end
  return false
end

---Returns code, dirty, reserve-width for one tree row.
local function sidebar_decoration(tv, item)
  local c = config.plugins.git_status
  if not c.enabled then return nil end
  local code = c.sidebar_badges and M.status_for(item.abs_filename) or nil
  local dirty = c.sidebar_dirty_dot and doc_is_dirty(tv, item.abs_filename) or false
  if not code and not dirty then return nil end

  local w = 0
  if code then w = w + style.font:get_width(code) end
  if dirty then
    local dot = math.max(2, common.round(3 * SCALE))
    if w > 0 then w = w + SIDEBAR_GAP end
    w = w + dot
  end
  return code, dirty, w + SIDEBAR_GAP + style.padding.x
end

local function draw_sidebar_badges(tv, item, active, hovered, x, y, w, h)
  local code, dirty, reserve = sidebar_decoration(tv, item)
  if not reserve then return end

  local font = style.font
  local right = x + w - style.padding.x
  local ty = y + math.floor((h - font:get_height()) / 2)
  local cursor = right

  if code then
    local tw = font:get_width(code)
    renderer.draw_text(font, code, cursor - tw, ty,
      sidebar_color(code) or style.sidebar_text or style.text)
    cursor = cursor - tw - SIDEBAR_GAP
  end
  if dirty then
    local dot = math.max(2, common.round(3 * SCALE))
    renderer.draw_rounded_rect(cursor - dot, y + (h - dot) / 2, dot, dot, dot / 2,
      style.sidebar_text or style.text)
  end
end

find_treeview = function()
  local found
  local function walk(node)
    if not node or found then return end
    if type(node.get_cached) == "function" and node.watches and node.expanded then
      found = node
      return
    end
    if node.a then
      walk(node.a)
      walk(node.b)
    end
    if node.views then
      for _, view in ipairs(node.views) do walk(view) end
    end
  end
  walk(core.root_view and core.root_view.root_node)
  return found
end

local treeview_hooks_installed = false

local function install_treeview_hooks()
  if treeview_hooks_installed then return true end
  local tv = find_treeview()
  if not tv then return false end
  treeview_hooks_installed = true

  -- Dirty markers are collected once per frame instead of once per row.
  local orig_draw = tv.draw
  function tv:draw(...)
    if config.plugins.git_status.sidebar_dirty_dot
       and config.plugins.git_status.enabled then
      local set = {}
      for i = 1, #core.docs do
        local d = core.docs[i]
        if d.abs_filename and d:is_dirty() then set[d.abs_filename] = true end
      end
      self._git_dirty = set
    else
      self._git_dirty = nil
    end
    local res = orig_draw(self, ...)
    self._git_dirty = nil
    return res
  end

  -- Tint the filename with the status colour (Sublime colours the name).
  local orig_get_item_text = tv.get_item_text
  function tv:get_item_text(item, active, hovered)
    local text, font, color = orig_get_item_text(self, item, active, hovered)
    local c = config.plugins.git_status
    if c.enabled and c.sidebar_colors and not active and not hovered then
      local code = M.status_for(item.abs_filename)
      local sc = code and sidebar_color(code)
      if sc then
        if item.ignored then
          -- Remote placeholder (not pulled): keep the dimmed look but let
          -- the status hue through, so a new remote file is not just a
          -- barely visible grey row.
          color = { sc[1], sc[2], sc[3], math.floor((sc[4] or 255) * 0.6) }
        else
          color = sc
        end
      end
    end
    return text, font, color
  end

  -- Keep a long filename from running underneath the badge.
  local orig_draw_item_text = tv.draw_item_text
  function tv:draw_item_text(item, active, hovered, x, y, w, h)
    local _, _, reserve = sidebar_decoration(self, item)
    if reserve and reserve > 0 then
      local avail = self.position.x + self.size.x - x - reserve
      if avail <= 0 then return end
      core.push_clip_rect(x, y, avail, h)
      orig_draw_item_text(self, item, active, hovered, x, y, w, h)
      core.pop_clip_rect()
    else
      orig_draw_item_text(self, item, active, hovered, x, y, w, h)
    end
  end

  local orig_draw_item = tv.draw_item
  function tv:draw_item(item, active, hovered, x, y, w, h)
    orig_draw_item(self, item, active, hovered, x, y, w, h)
    draw_sidebar_badges(self, item, active, hovered, x, y, w, h)
  end

  return true
end

-- ---------------------------------------------------------------------------
-- gutter integration
-- ---------------------------------------------------------------------------

local old_draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(line, x, y, width)
  local lh = old_draw_line_gutter(self, line, x, y, width)
  if not config.plugins.git_status.enabled
     or not config.plugins.git_status.gutter_markers then
    return lh
  end
  local st = self.doc and doc_state[self.doc]
  local m = st and st.markers
  if not m then return lh end

  local bar_x = x + math.max(1, common.round(1 * SCALE))
  -- Keep clear of the folding chevron, which lives in the same left padding.
  local bar_w = math.max(2, common.round(2 * SCALE))
  local tick_w = math.max(bar_w, common.round(6 * SCALE))
  local tick_h = math.max(2, common.round(2 * SCALE))
  local lh_draw = self:get_line_height()

  if m.add[line] then
    renderer.draw_rect(bar_x, y, bar_w, lh_draw, gutter_color("A"))
  elseif m.mod[line] then
    renderer.draw_rect(bar_x, y, bar_w, lh_draw, gutter_color("M"))
  end
  if m.del_top[line] then
    renderer.draw_rect(bar_x, y, tick_w, tick_h, gutter_color("D"))
  end
  if m.del_bottom[line] then
    renderer.draw_rect(bar_x, y + lh_draw - tick_h, tick_w, tick_h, gutter_color("D"))
  end
  return lh
end

-- ---------------------------------------------------------------------------
-- lifecycle hooks
-- ---------------------------------------------------------------------------

local old_doc_save = Doc.save
function Doc:save(...)
  local result = old_doc_save(self, ...)
  local abs = self.abs_filename
  if abs then
    local ctx = find_ctx_for_abs(abs)
    if ctx then
      ctx.next_at = math.min(ctx.next_at or math.huge,
        system.get_time() + (config.plugins.git_status.save_refresh_delay or 0.3))
    end
    local st = doc_state[self]
    if st then
      st.last_try = 0
    end
  end
  return result
end

local old_doc_close = Doc.on_close
function Doc:on_close()
  doc_state[self] = nil
  return old_doc_close(self)
end

-- ---------------------------------------------------------------------------
-- commands
-- ---------------------------------------------------------------------------

function M.refresh()
  for _, ctx in pairs(contexts) do
    ctx.next_at = 0
    ctx.interval = nil
  end
  local doc = core.active_view and core.active_view.doc
  if doc then
    local st = doc_state[doc]
    if st then
      st.head_oid = nil
      st.last_try = 0
    end
  end
  core.redraw = true
end

command.add(nil, {
  ["git-status:refresh"] = function()
    M.refresh()
  end,
  ["git-status:toggle"] = function()
    local c = config.plugins.git_status
    c.enabled = not c.enabled
    if not c.enabled then
      for _, st in pairs(doc_state) do st.markers = nil end
      for _, ctx in pairs(contexts) do
        ctx.files = {}
        ctx.dirs = {}
      end
    else
      M.refresh()
    end
    core.redraw = true
    core.log_quiet("[git] status display %s", c.enabled and "enabled" or "disabled")
  end,
})

keymap.add {
  ["ctrl+shift+g"] = "git-status:refresh",
}

-- ---------------------------------------------------------------------------
-- threads
-- ---------------------------------------------------------------------------

core.add_thread(function()
  while true do
    poll_contexts("local")
    coroutine.yield(0.1)
  end
end)

core.add_thread(function()
  while true do
    poll_contexts("remote")
    coroutine.yield(0.15)
  end
end)

core.add_thread(function()
  while true do
    if config.plugins.git_status.enabled then
      update_active_markers(system.get_time())
    end
    coroutine.yield(0.1)
  end
end)

if not install_treeview_hooks() then
  -- The treeview loads after this plugin (plugins load in name order); wait
  -- for its view to appear, then patch it once.
  core.add_thread(function()
    for _ = 1, 200 do
      if install_treeview_hooks() then return end
      coroutine.yield(0.05)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- test/debug surface
-- ---------------------------------------------------------------------------

M._internal = {
  parse_status = M.parse_status,
  display_code = M.display_code,
  merge_code = M.merge_code,
  diff_markers = M.diff_markers,
  head_lines_from_text = M.head_lines_from_text,
  map_remote_path = M.map_remote_path,
  map_local_path = map_local_path,
  shquote = shquote,
  sh_remote_path = sh_remote_path,
  is_under = is_under,
  all_added_markers = all_added_markers,
  install_treeview_hooks = install_treeview_hooks,
  contexts = contexts,
  project_ctx = project_ctx,
  doc_state = doc_state,
}

rawset(_G, "__lite_xl_git_status", M)

return M
