-- Headless tests for plugins/git_status.lua
-- Run: lua5.4 tests/headless/test_git_status.lua
--
-- The plugin needs the editor runtime; this file stubs just enough of it to
-- exercise the pure logic (status parsing, path mapping, patience diff) and
-- then drives the parser with REAL `git` output from a scratch repository.

local ROOT = (arg and arg[0] and arg[0]:match("^(.*)/tests/headless/")) or "."
if ROOT == "" then ROOT = "." end
local REPO = ROOT
local PLUGIN = REPO .. "/data/plugins/git_status.lua"

local passed, failed = 0, 0
local function ok(v, msg)
  if v then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. msg)
  end
end
local function eq(a, b, msg)
  if a == b then
    passed = passed + 1
  else
    failed = failed + 1
    print(string.format("FAIL: %s\n  expected: %s\n  got:      %s",
      msg, tostring(b), tostring(a)))
  end
end

-- ---------------------------------------------------------------------------
-- minimal editor stubs
-- ---------------------------------------------------------------------------

PLATFORM = "Linux"
PATHSEP = "/"
SCALE = 1
HOME = "/tmp"

local commands = {}
local threads = {}
local fake_process = { start = function() return nil, "process disabled in tests" end }

local core = {
  docs = {},
  projects = {},
  redraw = false,
  log = function() end,
  log_quiet = function() end,
  add_thread = function(fn) threads[#threads + 1] = coroutine.create(fn) end,
  set_active_view = function() end,
  root_view = { root_node = {} },
}

package.preload["core"] = function() return core end
package.preload["core.common"] = function()
  return dofile(REPO .. "/data/core/common.lua")
end
package.preload["core.config"] = function()
  return { plugins = {}, fps = 60 }
end
package.preload["core.style"] = function()
  return {
    font = {
      get_width = function(_, s) return #s * 8 end,
      get_height = function() return 16 end,
    },
    padding = { x = 14, y = 7 },
    text = { 1, 1, 1, 1 },
    sidebar_text = { 0, 0, 0, 1 },
    sidebar_dim = { 0.5, 0.5, 0.5, 1 },
    sidebar_accent = { 0, 0, 1, 1 },
  }
end
package.preload["core.command"] = function()
  return {
    add = function(_, map)
      if type(map) == "table" then
        for name, fn in pairs(map) do commands[name] = fn end
      end
    end,
  }
end
package.preload["core.keymap"] = function()
  return { add = function() end, modkeys = {} }
end
package.preload["core.doc"] = function()
  return {
    save = function() return true end,
    on_close = function() end,
  }
end
package.preload["core.docview"] = function()
  return { draw_line_gutter = function() end }
end
package.preload["process"] = function()
  return fake_process
end

system = {
  get_time = os.time,
  get_file_info = function(path)
    local f = io.open(path, "rb")
    if f then
      local size = f:seek("end")
      f:close()
      return { type = "file", size = size, modified = 1 }
    end
    local ok, _, code = os.execute("test -d '" .. path .. "'")
    if ok == true or code == 0 then return { type = "dir", modified = 1 } end
    return nil
  end,
  mkdir = function(path)
    local ok, _, code = os.execute("mkdir -p '" .. path .. "'")
    return ok == true or code == 0
  end,
}

-- renderer / clip stubs for the treeview drawing checks
local render_calls = { text = 0, rect = 0, rounded = 0 }
renderer = {
  draw_text = function() render_calls.text = render_calls.text + 1 end,
  draw_rect = function() render_calls.rect = render_calls.rect + 1 end,
  draw_rounded_rect = function() render_calls.rounded = render_calls.rounded + 1 end,
}
local clip_depth = 0
core.push_clip_rect = function() clip_depth = clip_depth + 1 end
core.pop_clip_rect = function() clip_depth = clip_depth - 1 end

local M = dofile(PLUGIN)
ok(type(M) == "table", "plugin returns a module table")
ok(type(M.status_for) == "function", "status_for exposed")
ok(type(M.refresh) == "function", "refresh exposed")
ok(commands["git-status:refresh"] ~= nil, "refresh command registered")

local I = M._internal

-- ---------------------------------------------------------------------------
-- display_code / merge_code
-- ---------------------------------------------------------------------------

eq(I.display_code(" M"), "M", "unstaged modification")
eq(I.display_code("M "), "M", "staged modification")
eq(I.display_code("MM"), "M", "both modified")
eq(I.display_code("A "), "A", "staged add")
eq(I.display_code("??"), "A", "untracked -> A")
eq(I.display_code("D "), "D", "staged delete")
eq(I.display_code(" D"), "D", "unstaged delete")
eq(I.display_code("R "), "R", "rename")
eq(I.display_code("C "), "R", "copy -> rename bucket")
eq(I.display_code("UU"), "C", "unmerged -> conflict")
eq(I.display_code("AA"), "C", "both added -> conflict")
eq(I.display_code("DD"), "C", "both deleted -> conflict")
eq(I.display_code("!!"), nil, "ignored is skipped")
eq(I.display_code("  "), nil, "clean is skipped")
eq(I.display_code("T "), "M", "typechange -> modified")

eq(I.merge_code(nil, "M"), "M", "merge with nil")
eq(I.merge_code("M", nil), "M", "merge nil on the right")
eq(I.merge_code("M", "A"), "A", "added beats modified")
eq(I.merge_code("A", "D"), "D", "deleted beats added")
eq(I.merge_code("D", "C"), "C", "conflict beats deleted")

-- ---------------------------------------------------------------------------
-- status parsing (fixtures)
-- ---------------------------------------------------------------------------

local branch, entries = I.parse_status(
  "## main\0 M a.txt\0?? b.txt\0R  c.txt\0old-c.txt\0!! ignored.log\0")
eq(branch, "main", "branch header parsed")
eq(#entries, 3, "ignored entry dropped")
eq(entries[1].xy, " M", "first entry xy")
eq(entries[1].path, "a.txt", "first entry path")
eq(entries[2].xy, "??", "untracked entry")
eq(entries[3].path, "c.txt", "rename new path")
eq(entries[3].old_path, "old-c.txt", "rename old path")

branch, entries = I.parse_status("## No commits yet on main\0?? first.txt\0")
eq(branch, "No commits yet on main", "unborn branch header")
eq(#entries, 1, "unborn branch entry")

branch, entries = I.parse_status("## HEAD (no branch)\0")
eq(branch, "HEAD (no branch)", "detached HEAD header")
eq(#entries, 0, "detached HEAD has no entries")

-- Without --branch the first token is a normal entry.
branch, entries = I.parse_status(" M only.txt\0")
eq(branch, nil, "no branch header")
eq(entries[1].path, "only.txt", "entry without branch header")

local _, empty_entries = I.parse_status("")
eq(#empty_entries, 0, "empty status output")

-- ---------------------------------------------------------------------------
-- path mapping
-- ---------------------------------------------------------------------------

eq(I.map_remote_path("/srv/repo", "/srv/repo/sub", "/cache/p",
    "sub/a.txt"), "/cache/p/a.txt", "remote path inside the project")
eq(I.map_remote_path("/srv/repo", "/srv/repo/sub/", "/cache/p",
    "sub/dir/a.txt"), "/cache/p/dir/a.txt", "trailing slash on remote dir")
eq(I.map_remote_path("/srv/repo", "/srv/repo/sub", "/cache/p",
    "other/a.txt"), nil, "remote path outside the project")
eq(I.map_remote_path("/srv/repo", "/srv/repo", "/cache/p",
    "a.txt"), "/cache/p/a.txt", "remote project == repo root")
eq(I.map_remote_path("/srv/repo", "/srv/repo", "/cache/p",
    ""), "/cache/p", "remote root itself")
eq(I.map_local_path("/repo", "sub/a.txt"), "/repo/sub/a.txt", "local path join")

ok(I.is_under("/a/b/c", "/a/b", "/"), "is_under descendant")
ok(I.is_under("/a/b", "/a/b", "/"), "is_under equal")
ok(not I.is_under("/a/bc", "/a/b", "/"), "is_under respects separator")

eq(I.shquote("a'b"), "'a'\\''b'", "shell quote escapes single quotes")
eq(I.sh_remote_path("~/my proj"), "~'/my proj'", "remote path keeps ~ expandable")
eq(I.sh_remote_path("~"), "~", "bare tilde stays expandable")
eq(I.sh_remote_path("~user/x"), "~user'/x'", "named tilde stays expandable")
eq(I.sh_remote_path("/srv/my proj"), "'/srv/my proj'", "absolute remote path quoted")
eq(I.sh_remote_path("/srv/it's"), "'/srv/it'\\''s'", "remote path escapes quotes")

-- ---------------------------------------------------------------------------
-- HEAD blob splitting
-- ---------------------------------------------------------------------------

local lines = I.head_lines_from_text("a\nb\n")
eq(#lines, 2, "trailing newline does not add a line")
eq(lines[1], "a\n", "first line keeps the Doc newline")
eq(lines[2], "b\n", "second line keeps the Doc newline")

lines = I.head_lines_from_text("a\r\nb\r\n")
eq(#lines, 2, "CRLF lines")
eq(lines[1], "a\n", "CR stripped")
eq(lines[2], "b\n", "CR stripped on second line")

lines = I.head_lines_from_text("")
eq(#lines, 1, "empty blob matches Doc's single empty line")
eq(lines[1], "\n", "empty blob content")
lines = I.head_lines_from_text("\n")
eq(#lines, 1, "blob with one empty line")
eq(lines[1], "\n", "empty line content")

local binary, why = I.head_lines_from_text("a\0b")
eq(binary, nil, "NUL byte detected")
eq(why, "binary", "binary reason")

-- ---------------------------------------------------------------------------
-- patience diff markers
-- ---------------------------------------------------------------------------

local function keys(set)
  local t = {}
  for k in pairs(set) do t[#t + 1] = k end
  table.sort(t)
  return table.concat(t, ",")
end

local function check_diff(a, b, add, mod, del_top, del_bottom, name)
  local m = I.diff_markers(a, b)
  eq(keys(m.add), add or "", name .. " [add]")
  eq(keys(m.mod), mod or "", name .. " [mod]")
  eq(keys(m.del_top), del_top or "", name .. " [del_top]")
  eq(keys(m.del_bottom), del_bottom or "", name .. " [del_bottom]")
end

check_diff({ "a", "b", "c" }, { "a", "b", "c" }, "", "", "", "", "identical")
check_diff({ "a", "b", "c" }, { "a", "B", "c" }, "", "2", "", "", "one line modified")
check_diff({ "a", "b", "c" }, { "a", "x", "b", "c" }, "2", "", "", "", "insertion")
check_diff({ "a", "b", "c" }, { "a", "c" }, "", "", "2", "", "deletion in the middle")
check_diff({ "a", "b", "c" }, { "a", "b", "c", "d" }, "4", "", "", "", "append")
check_diff({ "a", "b", "c" }, { "a", "b" }, "", "", "", "2", "delete at EOF")
check_diff({ "a", "b", "c", "d" }, { "a", "X", "Y", "d" }, "", "2,3", "", "", "replacement block")
check_diff({}, { "x", "y" }, "1,2", "", "", "", "new file (empty HEAD)")
check_diff({ "x", "x", "x", "y" }, { "x", "y" }, "", "", "2", "", "repeated lines")

-- A pathological all-identical file must not hang or crash.
local big_a, big_b = {}, {}
for i = 1, 500 do big_a[i] = "same"; big_b[i] = "same" end
big_b[250] = "changed"
local m = I.diff_markers(big_a, big_b)
eq(m.mod[250], true, "large repeated file marks the changed line")

-- ---------------------------------------------------------------------------
-- real git integration
-- ---------------------------------------------------------------------------

local GITDIR = "/tmp/lite-xl-git-status-test"
local function sh(cmd)
  local p = io.popen(cmd)
  local out = p:read("*a")
  local ok_, _, code = p:close()
  return out, ok_ == true or code == 0
end
local function run(cmd)
  local out, okk = sh(cmd)
  if not okk then error("command failed: " .. cmd .. "\n" .. out) end
  return out
end

os.execute("rm -rf " .. GITDIR)
run("mkdir -p " .. GITDIR)
run("cd " .. GITDIR .. " && git init -q && git config user.email t@t.t && git config user.name t")
run("cd " .. GITDIR .. " && mkdir -p sub && printf 'one\\n' > a.txt"
  .. " && printf 'two\\n' > b.txt && printf 'three\\n' > sub/c.txt"
  .. " && git add -A && git commit -qm init")
run("cd " .. GITDIR .. " && printf 'one\\nmore\\n' > a.txt"
  .. " && printf 'new\\n' > new.txt && git mv b.txt b2.txt && rm sub/c.txt")

local out = run("cd " .. GITDIR
  .. " && git status --porcelain=v1 -z --untracked-files=all --branch")
branch, entries = I.parse_status(out)
eq(branch, "main", "real repo branch")
local by_path = {}
for _, e in ipairs(entries) do
  by_path[e.path] = { code = I.display_code(e.xy), old = e.old_path }
end
eq(by_path["a.txt"] and by_path["a.txt"].code, "M", "real repo modified file")
eq(by_path["new.txt"] and by_path["new.txt"].code, "A", "real repo untracked file")
eq(by_path["b2.txt"] and by_path["b2.txt"].code, "R", "real repo renamed file")
eq(by_path["b2.txt"] and by_path["b2.txt"].old, "b.txt", "real repo rename source")
eq(by_path["sub/c.txt"] and by_path["sub/c.txt"].code, "D", "real repo deleted file")

local head = run("cd " .. GITDIR .. " && git show HEAD:a.txt")
lines = I.head_lines_from_text(head)
eq(#lines, 1, "HEAD blob line count")
eq(lines[1], "one\n", "HEAD blob content")

local oid = run("cd " .. GITDIR .. " && git rev-parse --verify -q HEAD"):gsub("%s+$", "")
eq(#oid, 40, "HEAD oid length")

os.execute("rm -rf " .. GITDIR)

-- ---------------------------------------------------------------------------
-- randomized invariant: unmarked buffer lines must stay a subsequence of HEAD
-- ---------------------------------------------------------------------------

math.randomseed(7)
local alphabet = { "a", "b", "c", "d", "{", "}" }
for case = 1, 300 do
  local a, b = {}, {}
  for i = 1, math.random(0, 8) do a[i] = alphabet[math.random(#alphabet)] end
  for i = 1, math.random(0, 8) do b[i] = alphabet[math.random(#alphabet)] end
  local m = I.diff_markers(a, b)
  local ai = 1
  local ok_seq = true
  for j = 1, #b do
    if not m.add[j] and not m.mod[j] then
      while ai <= #a and a[ai] ~= b[j] do ai = ai + 1 end
      if ai > #a then ok_seq = false break end
      ai = ai + 1
    end
  end
  if not ok_seq then
    ok(false, "unmarked lines are a subsequence of HEAD (case " .. case .. ")")
    break
  end
end
ok(true, "randomized diff invariant")

-- ---------------------------------------------------------------------------
-- end-to-end: fake process -> real git -> status map -> live markers -> commit
-- ---------------------------------------------------------------------------

local LIVE = "/tmp/lite-xl-git-status-live"
os.execute("rm -rf " .. LIVE)
run("mkdir -p " .. LIVE)
run("cd " .. LIVE .. " && git init -q && git config user.email t@t.t && git config user.name t")
run("cd " .. LIVE .. " && printf 'one\\ntwo\\n' > a.txt && git add -A && git commit -qm init")
run("cd " .. LIVE .. " && printf 'one\\nTWO\\n' > a.txt")
local LIVE_REAL = run("cd " .. LIVE .. " && pwd -P"):gsub("%s+$", "")

-- Replace the load-time no-op with a synchronous shim.  The plugin captured
-- the same table, so mutating it is enough.
local ERR_FILE = "/tmp/lite-xl-git-status-live.err"
fake_process.start = function(argv, opts)
  local quoted = {}
  for _, a in ipairs(argv) do
    quoted[#quoted + 1] = "'" .. tostring(a):gsub("'", "'\\''") .. "'"
  end
  local cmd = table.concat(quoted, " ")
  if opts and opts.cwd then cmd = "cd '" .. opts.cwd .. "' && " .. cmd end
  local p = io.popen(cmd .. " 2>" .. ERR_FILE .. "; echo __EXIT:$?")
  local out = p:read("*a")
  p:close()
  local code = tonumber(out:match("__EXIT:(%d+)%s*$")) or 0
  out = out:gsub("__EXIT:%d+%s*$", "")
  local err = ""
  local ef = io.open(ERR_FILE, "rb")
  if ef then err = ef:read("*a"); ef:close() end
  local stdout = { data = out }
  function stdout:read(what)
    if what == "all" or what == "a" then
      local d = self.data
      self.data = ""
      return d
    end
    return nil
  end
  local stderr = { data = err }
  function stderr:read(what)
    if what == "all" or what == "a" then
      local d = self.data
      self.data = ""
      return d
    end
    return nil
  end
  local proc = {
    process = { running = function() return false end },
    stdout = stdout,
    stderr = stderr,
  }
  function proc:wait() return code end
  return proc
end

core.projects = { { path = LIVE_REAL } }

-- threads[1] is the local poller, [2] the remote poller, [3] live markers.
local function pump(n)
  local res, err = coroutine.resume(threads[n])
  ok(res, "thread " .. n .. " resumes" .. (err and (": " .. tostring(err)) or ""))
end

pump(1)
eq(M.status_for(LIVE_REAL .. "/a.txt"), "M", "end-to-end: modified file in the sidebar")
local ctx = I.contexts["local:" .. LIVE_REAL]
ok(ctx ~= nil, "end-to-end: local context created")
eq(ctx and ctx.head ~= nil, true, "end-to-end: HEAD oid captured")

local change_id = 1
local dirty = true
local doc = {
  abs_filename = LIVE_REAL .. "/a.txt",
  lines = { "one\n", "TWO\n" },
  get_change_id = function() return change_id end,
  is_dirty = function() return dirty end,
}
core.docs = { doc }
core.active_view = {
  doc = doc,
  get_line_height = function() return 16 end,
}
pump(3)
local st = I.doc_state[doc]
ok(st and st.markers ~= nil, "end-to-end: markers computed")
ok(st and st.markers.mod[2] == true, "end-to-end: changed line marked")
ok(st and st.markers.add[1] ~= true, "end-to-end: unchanged line not marked")

-- Treeview integration: patch a fake live instance (the real plugin
-- discovers the treeview through the view tree) and draw one changed row.
local fake = {
  get_cached = function() end,
  watches = {},
  expanded = {},
  position = { x = 0, y = 0 },
  size = { x = 200, y = 300 },
}
function fake:draw() self.drawn = (self.drawn or 0) + 1 end
function fake:get_item_text(item, active, hovered)
  return item.name, require("core.style").font, { 0, 0, 0, 1 }
end
function fake:draw_item_text(item, active, hovered, x, y, w, h)
  self.text_drawn = (self.text_drawn or 0) + 1
end
function fake:draw_item(item, active, hovered, x, y, w, h)
  self:draw_item_text(item, active, hovered, x, y, w, h)
end
core.root_view.root_node = { views = { fake } }
ok(I.install_treeview_hooks(), "treeview hooks installed")
local item = { abs_filename = LIVE_REAL .. "/a.txt", name = "a.txt", type = "file", ignored = false }
fake:draw()
fake:draw_item(item, false, false, 0, 0, 200, 20)
ok(fake.text_drawn == 1, "treeview row still drawn")
ok(render_calls.text >= 1, "treeview status badge drawn")
eq(clip_depth, 0, "treeview text clip balanced")
local _, _, row_color = fake:get_item_text(item, false, false)
ok(type(row_color) == "table", "treeview filename colour replaced")

-- Gutter integration: the patched DocView method must draw the marker for the
-- modified line without touching the other lines.
local DocViewStub = require("core.docview")
local fake_view = {
  doc = doc,
  get_line_height = function() return 16 end,
}
local rects_before = render_calls.rect
DocViewStub.draw_line_gutter(fake_view, 2, 0, 0, 100)
ok(render_calls.rect > rects_before, "gutter marker drawn for the changed line")
rects_before = render_calls.rect
DocViewStub.draw_line_gutter(fake_view, 1, 0, 0, 100)
eq(render_calls.rect, rects_before, "gutter marker not drawn for unchanged line")

-- Deletion ticks use the same gutter path.
st.markers.del_top[1] = true
rects_before = render_calls.rect
DocViewStub.draw_line_gutter(fake_view, 1, 0, 0, 100)
ok(render_calls.rect > rects_before, "deletion tick drawn at the boundary")
st.markers.del_top[1] = nil
st.markers.del_bottom[2] = true
rects_before = render_calls.rect
DocViewStub.draw_line_gutter(fake_view, 2, 0, 0, 100)
ok(render_calls.rect > rects_before, "deletion tick drawn at EOF")

-- Committing must remove both the sidebar status and the gutter markers.
run("cd " .. LIVE .. " && git add -A && git commit -qm second")
for _, c in pairs(I.contexts) do c.next_at = 0 end
pump(1)
eq(M.status_for(LIVE_REAL .. "/a.txt"), nil, "end-to-end: committed file is clean")
dirty = false
pump(3)
eq(st.markers, nil, "end-to-end: committed line markers cleared")

-- A clean committed file with unsaved edits still gets live gutter markers
-- (the sidebar badge stays absent until the file is saved).
dirty = true
change_id = change_id + 1
doc.lines = { "one\n", "UNSAVED\n", "three\n" }
st.last_try = 0
pump(3)
eq(st.synthetic, true, "end-to-end: unsaved edit uses a synthetic entry")
ok(st.markers and st.markers.mod[2] == true, "end-to-end: unsaved edit marked")

-- Undoing back to HEAD clears them again.
dirty = false
change_id = change_id + 1
doc.lines = { "one\n", "TWO\n", "three\n" }
pump(3)
eq(st.markers, nil, "end-to-end: reverted unsaved edit clears markers")

os.execute("rm -rf " .. LIVE)
os.remove(ERR_FILE)

-- ---------------------------------------------------------------------------
-- remote project: un-pulled placeholders get sidebar status but no line marks
-- ---------------------------------------------------------------------------

local CACHE = run("cd /tmp && mkdir -p lite-xl-git-status-cache && cd lite-xl-git-status-cache && pwd -P"):gsub("%s+$", "")
local pulled = false
local remote_head = "a\nb\n"
local remote_session = {
  cache_path = CACHE,
  remote_dir = "/remote/repo",
  account = {},
  profile = "test@host:/remote/repo",
}
local fake_remote = {
  _internal = {
    session_for_path = function(path)
      if path == CACHE or path:sub(1, #CACHE + 1) == CACHE .. "/" then
        return remote_session
      end
    end,
    ssh_command = function() return { "ssh", "test@host" } end,
    run_with_password = function(args)
      local cmd = args[#args] or ""
      if cmd:find("rev-parse --show-toplevel", 1, true) then
        return true, "/remote/repo\n\n"
      elseif cmd:find("git status", 1, true) then
        return true, string.rep("a", 40) .. "\n## main\0 M sub/a.txt\0?? new.txt\0"
      elseif cmd:find("git show", 1, true) then
        return true, remote_head
      end
      return nil, "unexpected command: " .. cmd
    end,
    is_pulled = function() return pulled end,
  },
}
_G.__lite_xl_remote_projects = fake_remote
core.projects = { { path = CACHE } }
fake.cache = { stale = true }
pump(2)

local nf = io.open(CACHE .. "/new.txt", "rb")
ok(nf ~= nil, "remote: file added after the listing materialized as a placeholder")
if nf then nf:close() end
ok(fake.cache.stale == nil, "remote: treeview cache refreshed for the new placeholder")

eq(M.status_for(CACHE .. "/sub/a.txt"), "M", "remote: un-pulled modified file has a badge")
eq(M.status_for(CACHE .. "/new.txt"), "A", "remote: un-pulled untracked file has a badge")
eq(M.status_for(CACHE .. "/sub"), "M", "remote: directory aggregates its children")
eq(M.status_for(CACHE), "A", "remote: project root aggregates (A wins)")
eq(I.contexts["remote:" .. CACHE] ~= nil, true, "remote: context created over the ssh shim")

-- The un-pulled placeholder is drawn dimmed but still gets its status badge.
local ignored_item = {
  abs_filename = CACHE .. "/sub/a.txt",
  name = "a.txt",
  type = "file",
  ignored = true,
}
local text_before = render_calls.text
fake:draw_item(ignored_item, false, false, 0, 0, 200, 20)
ok(render_calls.text > text_before, "remote: un-pulled row draws a status badge")
local _, _, ignored_color = fake:get_item_text(ignored_item, false, false)
eq(ignored_color[1], 0.95, "remote: un-pulled filename shows a muted status hue")
eq(ignored_color[4], 153, "remote: un-pulled filename stays muted")

local remote_change_id = 1
local remote_doc = {
  abs_filename = CACHE .. "/sub/a.txt",
  lines = { "a\n", "B\n" },
  get_change_id = function() return remote_change_id end,
  is_dirty = function() return true end,
}
core.docs = { remote_doc }
core.active_view = {
  doc = remote_doc,
  get_line_height = function() return 16 end,
}
pump(3)
local remote_st = I.doc_state[remote_doc]
ok(remote_st and remote_st.markers ~= nil, "remote: placeholder processed")
ok(remote_st and next(remote_st.markers.add) == nil
  and next(remote_st.markers.mod) == nil, "remote: placeholder gets no line markers")

-- Once pulled, the same buffer gets live line markers against the remote HEAD.
pulled = true
remote_st.last_try = 0
remote_change_id = remote_change_id + 1
pump(3)
ok(remote_st and remote_st.markers.mod[2] == true,
  "remote: pulled file gets live line markers")

_G.__lite_xl_remote_projects = nil
os.execute("rm -rf " .. CACHE)

print(string.format("checks: %d, fails: %d", passed, failed))
if failed > 0 then os.exit(1) end
