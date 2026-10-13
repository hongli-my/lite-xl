-- Verify surface colour contrast under the fork's actual slate theme
-- (the one shipped in the Desktop app).  Loads the theme file directly and
-- checks the lerp-derived surfaces against style.text luminance.
-- Run: lua tests/headless/verify_contrast.lua
local common = {
  color = function(s)
    local r, g, b, a = s:match("^#(%x%x)(%x%x)(%x%x)(%x?%x?)$")
    if r then
      return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16),
             a and tonumber(a, 16) or 255
    end
    -- rgba(...) form used by nagbar_dim etc.
    local f = s:gmatch("[%d.]+")
    return (f() or 0), (f() or 0), (f() or 0), (f() or 1) * 255
  end,
  lerp = function(a, b, t)
    if type(a) == "table" then
      local res = {}
      for k, v in pairs(b) do
        if type(v) == "number" and type(a[k]) == "number" then
          res[k] = a[k] + (v - a[k]) * t
        end
      end
      return res
    end
    return a + (b - a) * t
  end,
}

-- load data/colors/slate.lua with a stubbed style
local style = { syntax = {}, log = {} }
package.preload["core.style"] = function() return style end
package.preload["core.common"] = function() return common end

local f = assert(io.open("data/colors/slate.lua", "r"))
local src = f:read("*a"); f:close()
assert(load(src, "slate"))()

local function lum(c)
  local function ch(v)
    v = v / 255
    return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * ch(c[1]) + 0.7152 * ch(c[2]) + 0.0722 * ch(c[3])
end

local function ratio(a, b)
  local l1, l2 = lum(a), lum(b)
  if l1 < l2 then l1, l2 = l2, l1 end
  return (l1 + 0.05) / (l2 + 0.05)
end

local function hex(c) return string.format("#%02x%02x%02x",
  math.floor(c[1] + 0.5), math.floor(c[2] + 0.5), math.floor(c[3] + 0.5)) end

local surface = common.lerp(style.background, style.text, 0.06)
local raised  = common.lerp(style.background, style.text, 0.13)

print(string.format("editor bg   %s  text %s", hex(style.background), hex(style.text)))
print(string.format("surface     %s  (lerp .06)", hex(surface)))
print(string.format("raised      %s  (lerp .13)", hex(raised)))
print(string.format("surface vs text      contrast %.2f:1", ratio(surface, style.text)))
print(string.format("raised  vs text      contrast %.2f:1", ratio(raised, style.text)))
print(string.format("surface vs dim       contrast %.2f:1", ratio(surface, style.dim)))
print(string.format("surface vs accent    contrast %.2f:1", ratio(surface, style.accent)))
print(string.format("OLD background2 %s vs text contrast %.2f:1  <-- was unreadable",
  hex(style.background2), ratio(style.background2, style.text)))

local pass = true
if ratio(surface, style.text) < 4.5 then print("FAIL: surface/text below 4.5:1"); pass = false end
if ratio(raised, style.text) < 4.5 then print("FAIL: raised/text below 4.5:1"); pass = false end
if ratio(surface, style.dim) < 2.0 then print("WARN: surface/dim below 2:1 (dim text is secondary)") end
if pass then print("\nOK: WCAG AA contrast on task text") end
