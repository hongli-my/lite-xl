-- kbgen merge test: 增量合并不冲掉用户布局 (沙箱, 不碰真实知识库)
local registered = {}
package.preload["core"] = function() return { log = function() end,
  root_project = function() return { path = "/tmp/sbx" } end } end
package.preload["core.command"] = function() return { add = function(_, map)
  if type(map) == "table" then for n, f in pairs(map) do registered[n] = f end end
end } end
package.preload["core.keymap"] = function() return { add = function() end } end
package.preload["core.config"] = function() return { plugins = {} } end
_G.common = { merge = function(a, b)
  local t = {}
  for k, v in pairs(a or {}) do t[k] = v end
  for k, v in pairs(b or {}) do t[k] = v end
  return t
end }

local fails, checks = 0, 0
local function ok(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print("FAIL: " .. msg) end
end
local function wfile(path, content)
  local f = io.open(path, "w"); f:write(content); f:close()
end
local function rfile(path)
  local f = io.open(path, "r"); local s = f:read("*a"); f:close(); return s
end
package.preload["core.common"] = function()
  return _G.common
end
package.preload["plugins.treeview"] = function()
  return { on_context_menu = function() end }
end

os.execute("rm -rf /tmp/sbx && mkdir -p /tmp/sbx/agent")
wfile("/tmp/sbx/agent/README.md", "# agent\n\n## A节\n- x\n\n## B节\n- y\n")

dofile("/Users/honglichang/ai-home/lite-xl/data/plugins/kbgen.lua")
local gen = assert(registered["kbgen:generate"])
-- 1) first generation
gen()
local c1 = rfile("/tmp/sbx/驾驶舱.canvas")
ok(c1:find("A节", 1, true) and c1:find("B节", 1, true), "first gen has sections")
ok(c1:find('"kind":"struct"') ~= nil, "struct arrows dir->section generated")
ok(c1:find('"dir":"agent"') ~= nil or c1:find('📂 agent') ~= nil,
  "directory entry card generated")
-- 2) simulate user layout: pin+move an md card, add a hand-drawn arrow.
--    Structured JSON surgery (decode -> mutate -> encode) so card order and
--    key order in the file never affect what we touch.
local json = load([==[
local dec, enc
return { decode = dec, encode = enc }
]==])
-- reuse kbgen's own decoder/encoder via dofile side effects is messy; inline:
local dec_src = function() return nil end
local data = { cards = {}, arrows = {} }
-- extract kbgen's json_decode/json_encode_value by loading the plugin source
local src = io.open("/Users/honglichang/ai-home/lite-xl/data/plugins/kbgen.lua"):read("*a")
local d0 = src:find("local function json_decode")
local d1 = src:find("\n-- %[%-", d0) or src:find("\nlocal function", d0 + 10)
local json_decode = assert(load(src:sub(d0, d1 - 1) .. "\nreturn json_decode"))()
local e0 = src:find("local function json_escape")
local e1 = src:find("\n%-", e0 + 200)
local json_encode_value = assert(load(src:sub(e0, e1 - 1) .. "\nreturn json_encode_value"))()
data = json_decode(c1)
-- pin & move one md card
local target
for _, c in ipairs(data.cards) do
  if c.type == "md" and not target then target = c end
end
target.pinned = true
target.x = 999
-- append a hand-drawn arrow (no kind)
data.arrows[#data.arrows + 1] = { from = target.id, to = "x1" }
local t = "{\n  \"cards\": " .. json_encode_value(data.cards) .. ",\n"
  .. "  \"arrows\": " .. json_encode_value(data.arrows) .. ",\n"
  .. "  \"frames\": " .. json_encode_value(data.frames or {}) .. "\n}"
wfile("/tmp/sbx/驾驶舱.canvas", t)
local check = json_decode(rfile("/tmp/sbx/驾驶舱.canvas"))
local moved_ok = false
for _, c in ipairs(check.cards) do
  if c.id == target.id and c.x == 999 then moved_ok = true end
end
ok(moved_ok, "user edit on disk (pin + move)")
local user_from = target.id
-- 3) new README section + regenerate: user layout survives, new card appended
local f = io.open("/tmp/sbx/agent/README.md", "a")
f:write("\n## C节-new\n- z\n"); f:close()
gen()
local c2 = rfile("/tmp/sbx/驾驶舱.canvas")
ok(c2:find('"x":999', 1, true) ~= nil, "user-moved card position preserved")
ok(c2:find('"from":"' .. user_from .. '"') ~= nil, "user arrow preserved")
ok(c2:find("C节%-new") ~= nil, "new section appended as new card")
local n_c = 0
for _ in c2:gmatch('"type":"md"') do n_c = n_c + 1 end
ok(n_c == 3, "exactly 3 md cards (no duplicates): " .. n_c)

-- 4) idempotent second regen (semantic compare: key order in JSON is not
--    stable across encodes because pairs() ordering varies)
gen()
local function canon(s)
  -- sort cards/arrows by a canonical projection so ordering noise drops out
  local items = {}
  for id, text, kind in s:gmatch('"id":"([^"]*)"[^}]*"text":"([^"]*)"[^}]*"kind":"([^"]*)"') do
    items[#items + 1] = id .. text .. kind
  end
  local n = {}
  for k in s:gmatch('"heading":"([^"]*)"') do n[#n + 1] = k end
  table.sort(items); table.sort(n)
  return table.concat(items, "|") .. "#" .. table.concat(n, "|") .. "#"
    .. tostring(select(2, s:gsub('"kind":"struct"', "")))
end
ok(canon(rfile("/tmp/sbx/驾驶舱.canvas")) == canon(c2), "regen idempotent (semantic)")

-- 5) user hand-added sticky survives regen
local c3 = rfile("/tmp/sbx/驾驶舱.canvas")
local with_sticky = c3:gsub('"cards": %[', '"cards": [{"id":"s1","type":"sticky","text":"我的便签","x":50,"y":50},', 1)
ok(with_sticky ~= c3, "sticky injection matched")
wfile("/tmp/sbx/驾驶舱.canvas", with_sticky)
gen()
local c4 = rfile("/tmp/sbx/驾驶舱.canvas")
ok(c4:find("我的便签", 1, true) ~= nil, "user sticky survives regen")
ok(c4:find('"x":999', 1, true) ~= nil, "moved card still preserved")

-- 6) deleted README section: card kept (user decides)
local rm = {}
for l in io.lines("/tmp/sbx/agent/README.md") do
  if not l:find("C节") then rm[#rm + 1] = l end
end
wfile("/tmp/sbx/agent/README.md", table.concat(rm, "\n") .. "\n")
gen()
ok(rfile("/tmp/sbx/驾驶舱.canvas"):find("C节%-new") ~= nil,
  "removed-section card kept for manual cleanup")

print(string.format("\n%d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
