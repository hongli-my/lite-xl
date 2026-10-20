-- mod-version:4
--
-- Modal form dialog for remote-projects: host, user, password (optional),
-- port and remote directory, plus dropdowns of previously saved accounts
-- and directories. Shown by remote-projects:open-dialog.
--
-- Architecture follows core.dialog / core.nagview: the dialog grabs the
-- active view (force_focus) while visible, so text input and commands
-- route to it naturally; keymap.on_key_pressed swallows every key that is
-- not handled by the dialog's own commands (dialog visible => modal).
--
-- Keys: tab/shift+tab or up/down move between fields, return advances
-- (submits from the last field), escape closes, backspace edits. History
-- fields (host/user/port/dir) show a ▾ chevron — click it (or ctrl/cmd+p)
-- to open the saved-entries dropdown. The password field is drawn masked.
-- Editing: left/right (with shift to select), home/end, ctrl/cmd+a select
-- all, ctrl/cmd+c/x/v copy/cut/paste, forward delete, click positions the
-- caret, drag selects, double click selects a word.

if rawget(_G, "__lite_xl_remote_dialog") then
  return rawget(_G, "__lite_xl_remote_dialog")
end

local core = require "core"
local common = require "core.common"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local View = require "core.view"
local RootView = require "core.rootview"
local util = require "core.util"

local FIELDS = {
  { key = "host",     label = "主机 (IP)" },
  { key = "user",     label = "用户" },
  { key = "password", label = "密码 (可空, 免密登录)", mask = true },
  { key = "port",     label = "端口" },
  { key = "dir",      label = "远端目录" },
}
local RemoteDialog = View:extend()

local active_dialog = nil -- the currently shown dialog instance

function RemoteDialog:new(on_connect)
  RemoteDialog.super.new(self)
  self.visible = false
  self.force_focus = false
  self.on_connect = on_connect
  self.values = { host = "", user = "", password = "", port = "22", dir = "" }
  self.focus = 1
  self.caret = 1          -- caret character offset in the focused field
  self.sel_anchor = nil   -- selection anchor character offset while selecting
  self.drag = nil         -- { anchor = n } while drag-selecting with the mouse
  self.dropdown = nil      -- { items = {...}, selected = n } while open
  self.error_message = nil
  self.hovered_field = nil
  self.hovered_chevron = nil
  self.hovered_button = nil
  self.blink_start = system.get_time()
end

function RemoteDialog:get_name() return "Remote Connect" end
function RemoteDialog:supports_text_input() return true end

-- ---------------------------------------------------------------------------
-- layout
-- ---------------------------------------------------------------------------

---Shared layout metrics. Deliberately independent of style.padding (which is
---quite tight vertically) so the dialog always gets generous spacing.
local function metrics()
  local lh = style.font:get_height()
  local m = {}
  m.lh = lh
  m.pad_x = 24 * SCALE                          -- inner horizontal padding
  m.pad_y = 18 * SCALE                          -- top / bottom padding
  m.title_h = lh * 1.4                          -- header text height
  m.header_h = m.title_h + 12 * SCALE           -- title block incl. divider
  m.row_gap = 11 * SCALE                        -- gap between form rows
  m.label_gap = 4 * SCALE                       -- gap between label and field
  m.field_h = lh + 12 * SCALE                   -- input height
  m.row_h = lh + m.label_gap + m.field_h        -- one label + one field
  m.body_h = #FIELDS * m.row_h + (#FIELDS - 1) * m.row_gap
  m.footer_h = lh + 12 * SCALE                  -- hint / buttons row
  return m
end

local function dialog_geometry(self)
  local m = metrics()
  local w = math.min(460 * SCALE, self.size.x - 2 * style.padding.x)
  local h = m.pad_y + m.header_h + m.body_h + m.row_gap
    + m.footer_h + m.pad_y
  local x = self.position.x + (self.size.x - w) / 2
  local y = self.position.y + math.max((self.size.y - h) / 2, m.lh)
  return x, y, w, h
end

---Returns the input rect of field `i`: x, y, w, h.
local function field_rect(self, i)
  local m = metrics()
  local x, y, w = dialog_geometry(self)
  local inner_x = x + m.pad_x
  local inner_w = w - m.pad_x * 2
  local top = y + m.pad_y + m.header_h
  local fy = top + (i - 1) * (m.row_h + m.row_gap) + m.lh + m.label_gap
  return inner_x, fy, inner_w, m.field_h
end

---Returns the action button rects: connect and cancel.
local function button_rects(self)
  local m = metrics()
  local x, y, w, h = dialog_geometry(self)
  local bh = m.lh + 12 * SCALE
  local bw = 96 * SCALE
  local by = y + h - m.pad_y - bh
  local cancel_x = x + w - m.pad_x - bw
  local connect_x = cancel_x - 10 * SCALE - bw
  return
    { x = connect_x, y = by, w = bw, h = bh },
    { x = cancel_x, y = by, w = bw, h = bh }
end

---Returns the dropdown rect: x, y, w, h, item_h. Flips above the field
---when there is not enough room below the panel bottom.
local function dropdown_rect(self)
  local m = metrics()
  local fx, fy, fw, fh = field_rect(self, self.focus)
  local item_h = m.lh + 9 * SCALE
  local ddh = #self.dropdown.items * item_h + 8 * SCALE
  local ddy = fy + fh + 3 * SCALE
  local _, py, _, ph = dialog_geometry(self)
  -- never cover the footer button row
  local max_bottom = py + ph - m.pad_y - (m.lh + 12 * SCALE) - 4 * SCALE
  if ddy + ddh > max_bottom then
    ddy = fy - ddh - 3 * SCALE -- flip above the field
  end
  -- clamp inside the panel when even the flipped rect would overflow
  if ddy < py + 6 * SCALE then ddy = py + 6 * SCALE end
  if ddy + ddh > py + ph - 6 * SCALE then
    ddy = py + ph - 6 * SCALE - ddh
  end
  return fx, ddy, fw, ddh, item_h
end

---Returns the rect of dropdown item `n` (hit testing and drawing share it).
local function dropdown_item_rect(self, n)
  local fx, ddy, fw, _, item_h = dropdown_rect(self)
  return fx, ddy + 4 * SCALE + (n - 1) * item_h, fw, item_h
end

function RemoteDialog:hit_field(px, py)
  for i = 1, #FIELDS do
    local fx, fy, fw, fh = field_rect(self, i)
    if px >= fx and px <= fx + fw and py >= fy and py <= fy + fh then
      return i
    end
  end
end

---Fields that offer a history dropdown (every field except the password).
local function has_history(field)
  return field.key ~= "password"
end

---Returns the clickable history chevron (▾) rect of field `i`:
---x, y, w, h — or nil when the field has no history.
local function chevron_rect(self, i)
  if not has_history(FIELDS[i]) then return nil end
  local fx, fy, fw, fh = field_rect(self, i)
  local cw = fh
  return fx + fw - cw, fy, cw, fh
end

-- ---------------------------------------------------------------------------
-- editing: caret, selection, clipboard
-- (character/codepoint offsets; converted to bytes only at the boundaries)
-- ---------------------------------------------------------------------------

local TEXT_INSET = 10 * SCALE -- matches the text inset used by :draw

local function char_len_at(v, i)
  local c = v:byte(i)
  if not c then return 0 end
  if c >= 0xF0 then return 4 elseif c >= 0xE0 then return 3
  elseif c >= 0xC0 then return 2 end
  return 1
end

---Character (codepoint) count of `v`; falls back to bytes on invalid utf8.
local function ulen(v)
  if not v or v == "" then return 0 end
  return utf8.len(v) or #v
end

---Byte offset (1-based) where character offset `n` starts; #v + 1 past end.
local function ubyte_offset(v, n)
  if n <= 1 then return 1 end
  if n > ulen(v) then return #v + 1 end
  return utf8.offset(v, n) or (#v + 1)
end

---Substring of `v` by inclusive character offsets [a, b] (b may exceed len).
local function char_sub(v, a, b)
  return v:sub(ubyte_offset(v, a), ubyte_offset(v, b + 1) - 1)
end

---Clamps caret and selection anchor into the focused field's range
---(both are character offsets).
function RemoteDialog:normalise_caret()
  local last = ulen(self.values[FIELDS[self.focus].key]) + 1
  if self.caret < 1 then self.caret = 1 end
  if self.caret > last then self.caret = last end
  if self.sel_anchor then
    if self.sel_anchor < 1 then self.sel_anchor = 1 end
    if self.sel_anchor > last then self.sel_anchor = last end
    if self.sel_anchor == self.caret then self.sel_anchor = nil end
  end
end

---Returns lo, hi of the active selection (character offsets), or nil.
function RemoteDialog:selection()
  if not self.sel_anchor then return nil end
  local a, b = self.sel_anchor, self.caret
  if a > b then a, b = b, a end
  if a == b then return nil end
  return a, b
end

---Replaces the selection (or inserts at the caret) with `text`.
function RemoteDialog:replace_selection(text)
  local key = FIELDS[self.focus].key
  local v = self.values[key] or ""
  local a, b = self:selection()
  local s = a or self.caret                  -- first replaced char offset
  local e = (b or (self.caret - 1)) + 1      -- exclusive end char offset
  v = v:sub(1, ubyte_offset(v, s) - 1)
    .. text
    .. v:sub(ubyte_offset(v, e))
  self.values[key] = v
  self.caret = s + (ulen(text) or #text)
  self.sel_anchor = nil
end

function RemoteDialog:on_text_input(text)
  self:replace_selection(text)
  self.dropdown = nil
  self.blink_start = system.get_time()
  core.redraw = true
end

function RemoteDialog:backspace()
  self:normalise_caret()
  if not self:selection() and self.caret > 1 then
    self.sel_anchor = self.caret - 1 -- delete the whole character before
  end
  if self:selection() then
    self:replace_selection("")
    self.dropdown = nil
    self.blink_start = system.get_time()
    core.redraw = true
  end
end

---Forward delete: removes the character after the caret (or the selection).
function RemoteDialog:forward_delete()
  self:normalise_caret()
  if not self:selection()
      and self.caret <= ulen(self.values[FIELDS[self.focus].key]) then
    self.sel_anchor = self.caret
  end
  if self:selection() then
    self:replace_selection("")
    self.blink_start = system.get_time()
    core.redraw = true
  end
end

---Moves the caret by `delta` characters, extending the selection when
---`select` is set. The first move without select collapses a selection.
function RemoteDialog:caret_move(delta, select)
  self:normalise_caret()
  if not select then
    local a, b = self:selection()
    if a then
      self.caret = delta < 0 and a or b
      self.sel_anchor = nil
      self.dropdown = nil
      self.blink_start = system.get_time()
      core.redraw = true
      return
    end
  else
    if not self.sel_anchor then self.sel_anchor = self.caret end
  end
  self.caret = self.caret + delta
  self:normalise_caret()
  self.dropdown = nil
  self.blink_start = system.get_time()
  core.redraw = true
end

---Moves the caret to character offset `pos`, optionally extending selection.
function RemoteDialog:caret_to(pos, select)
  self:normalise_caret()
  if select then
    if not self.sel_anchor then self.sel_anchor = self.caret end
  else
    self.sel_anchor = nil
  end
  self.caret = pos
  self:normalise_caret()
  self.dropdown = nil
  self.blink_start = system.get_time()
  core.redraw = true
end

function RemoteDialog:select_all()
  self.sel_anchor = 1
  self.caret = ulen(self.values[FIELDS[self.focus].key]) + 1
  self.blink_start = system.get_time()
  core.redraw = true
end

function RemoteDialog:copy()
  if FIELDS[self.focus].mask then return end -- never leak the password
  local v = self.values[FIELDS[self.focus].key] or ""
  local a, b = self:selection()
  if a then system.set_clipboard(char_sub(v, a, b)) end
end

function RemoteDialog:cut()
  if FIELDS[self.focus].mask then return end
  local v = self.values[FIELDS[self.focus].key] or ""
  local a, b = self:selection()
  if a then
    system.set_clipboard(char_sub(v, a, b))
    self:replace_selection("")
  end
end

function RemoteDialog:paste()
  local text = system.get_clipboard()
  if text and text ~= "" then
    self:replace_selection(text)
    self.dropdown = nil
    self.blink_start = system.get_time()
    core.redraw = true
  end
end

function RemoteDialog:move_focus(delta)
  self.focus = ((self.focus - 1 + delta) % #FIELDS) + 1
  self.caret = ulen(self.values[FIELDS[self.focus].key]) + 1
  self.sel_anchor = nil
  self.dropdown = nil
  self.blink_start = system.get_time()
  core.redraw = true
end

-- ---------------------------------------------------------------------------
-- dropdown (history)
-- ---------------------------------------------------------------------------

function RemoteDialog:open_dropdown()
  local key = FIELDS[self.focus].key
  local rp = package.loaded["plugins.remote_projects"] or require "plugins.remote_projects"
  local items = {}
  if key == "host" or key == "user" or key == "port" then
    if rp and rp.list_accounts then
      for _, acc in ipairs(rp.list_accounts()) do
        table.insert(items, {
          text = (acc.user or "") .. "@" .. acc.host
            .. (acc.port and acc.port ~= 22 and (":" .. acc.port) or ""),
          account = acc,
        })
      end
    end
  elseif key == "dir" then
    if rp and rp.list_dirs then
      local accounts = {}
      for i, acc in ipairs(rp.list_accounts and rp.list_accounts() or {}) do
        accounts[acc.id or i] = acc
      end
      for _, d in ipairs(rp.list_dirs()) do
        local acc = accounts[d.account_id]
        if acc then
          table.insert(items, {
            text = d.path,
            -- shown on the right for context: which account it belongs to
            info = (acc.user or "") .. "@" .. acc.host,
            account = acc,
            dir = d,
          })
        end
      end
    end
  end
  if #items == 0 then
    self.error_message = "没有已保存的记录"
    core.redraw = true
    return
  end
  self.dropdown = { items = items, selected = 1 }
  self.error_message = nil
  core.redraw = true
end

function RemoteDialog:pick_dropdown(choice)
  local key = FIELDS[self.focus].key
  local item = self.dropdown and self.dropdown.items[choice]
  self.dropdown = nil
  if not item then return end
  local acc = item.account
  if acc then
    self.values.user = acc.user or ""
    self.values.host = acc.host or ""
    self.values.port = tostring(acc.port or 22)
    self.values.password = acc.password or ""
  end
  if key == "dir" then
    -- just fill the form; the user presses 连接 themselves
    self.values.dir = item.text
    self.focus = 5 -- move focus to the dir field so the caret lands there
  end
  -- caret to the end of the refilled focused field, selection cleared
  self.caret = ulen(self.values[FIELDS[self.focus].key]) + 1
  self.sel_anchor = nil
  core.redraw = true
end

-- ---------------------------------------------------------------------------
-- submit / dismiss
-- ---------------------------------------------------------------------------

function RemoteDialog:submit()
  local v = self.values
  if v.host == "" or v.user == "" or v.dir == "" then
    self.error_message = "主机、用户和远端目录必填"
    core.redraw = true
    return
  end
  if not v.dir:match("^/") then
    self.error_message = "远端目录必须是绝对路径 (以 / 开头)"
    core.redraw = true
    return
  end
  local on_connect = self.on_connect
  local host, user, password, port, dir =
    v.host, v.user, v.password, tonumber(v.port) or 22, v.dir
  self:dismiss()
  if on_connect then on_connect(host, user, password, port, dir) end
end

function RemoteDialog:dismiss()
  if not self.visible then return end
  self.visible = false
  active_dialog = nil
  self.force_focus = false
  -- restore the view that was active before the dialog took the focus
  core.set_active_view(core.next_active_view or core.last_active_view)
  core.next_active_view = nil
  core.redraw = true
end

-- ---------------------------------------------------------------------------
-- mouse
-- ---------------------------------------------------------------------------

---Returns the character range of the "word" around char offset `pos` (covers
---IPs, user@host and paths). Returns nil when there is no word there.
local function word_range(v, pos)
  local pattern = "[%w%.%-%_:/@]"
  local ul = ulen(v)
  if ul == 0 or pos < 1 or pos > ul then return nil end
  local char_at = function(i)
    return char_sub(v, i, i)
  end
  if not char_at(pos):match(pattern) then return nil end
  local s = pos
  while s > 1 and char_at(s - 1):match(pattern) do s = s - 1 end
  local e = pos
  while e < ul and char_at(e + 1):match(pattern) do e = e + 1 end
  return s, e + 1 -- insertion-offset style, exclusive end
end

---Converts a mouse x position inside field `i` into a caret character
---offset (1..ulen+1) by walking the per-character text widths.
local function caret_from_mouse(self, i, px)
  local fx, _, fw = field_rect(self, i)
  local text_w = fw - TEXT_INSET * 2
  local crx, _, crw = chevron_rect(self, i)
  if crx then text_w = text_w - crw - 2 * SCALE end
  local raw = self.values[FIELDS[i].key] or ""
  -- map the click against the string actually drawn (bullets for masks)
  local v = FIELDS[i].mask and ("•"):rep(ulen(raw)) or raw
  local rel = px - (fx + TEXT_INSET)
  if rel <= 0 then return 1 end
  local font = style.font
  local acc = 0
  local pos = 1
  while pos <= ulen(v) do
    local c = char_sub(v, pos, pos)
    local cw = font:get_width(c)
    if acc + cw / 2 >= rel then return pos end
    acc = acc + cw
    pos = pos + 1
  end
  return ulen(v) + 1
end

function RemoteDialog:on_mouse_moved(px, py, ...)
  -- drag selection: caret follows the mouse inside the pressed field
  if self.drag then
    local hit = self:hit_field(px, py)
    if hit and hit == self.drag.field then
      local pos = caret_from_mouse(self, hit, px)
      if pos ~= self.caret then
        self.caret = pos
        self.sel_anchor = self.drag.anchor
        self.blink_start = system.get_time()
        core.redraw = true
      end
    end
  end
  local hovered = self:hit_field(px, py)
  local hovered_chevron = nil
  for i = 1, #FIELDS do
    local cx, cy, cw, ch = chevron_rect(self, i)
    if cx and px >= cx and px <= cx + cw and py >= cy and py <= cy + ch then
      hovered_chevron = i
      break
    end
  end
  if hovered ~= self.hovered_field or hovered_chevron ~= self.hovered_chevron then
    self.hovered_field = hovered
    self.hovered_chevron = hovered_chevron
    core.redraw = true
  end
  -- action buttons hover state (for press feedback in draw)
  local connect_rect, cancel_rect = button_rects(self)
  local function inside_btn(r)
    return px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h
  end
  local hovered_button = inside_btn(connect_rect) and "connect"
    or inside_btn(cancel_rect) and "cancel" or nil
  if hovered_button ~= self.hovered_button then
    self.hovered_button = hovered_button
    core.redraw = true
  end
  if hovered_chevron or hovered_button then
    core.request_cursor("hand")
  elseif hovered then
    core.request_cursor("arrow")
  end
  return true
end

function RemoteDialog:on_mouse_pressed(button, px, py)
  if button ~= "left" then return true end
  -- history chevron (▾): opens the dropdown for that field, even when a
  -- dropdown is already open for another field
  for i = 1, #FIELDS do
    local cx, cy, cw, ch = chevron_rect(self, i)
    if cx and px >= cx and px <= cx + cw and py >= cy and py <= cy + ch then
      if self.focus ~= i then
        self.focus = i
        self.blink_start = system.get_time()
      end
      self:open_dropdown()
      return true
    end
  end
  if self.dropdown then
    local _, _, _, ddh, item_h = dropdown_rect(self)
    for n in ipairs(self.dropdown.items) do
      local rx, ry, rw, rh = dropdown_item_rect(self, n)
      if (n - 1) * item_h + 8 * SCALE > ddh then break end -- beyond the box
      if py >= ry and py < ry + rh and px >= rx and px <= rx + rw then
        self:pick_dropdown(n)
        return true
      end
    end
    self.dropdown = nil
    core.redraw = true
    return true
  end
  -- action buttons
  local connect_rect, cancel_rect = button_rects(self)
  local function inside(r)
    return px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h
  end
  if inside(connect_rect) then
    self:submit()
    return true
  end
  if inside(cancel_rect) then
    self:dismiss()
    return true
  end
  local hit = self:hit_field(px, py)
  if hit then
    if self.focus ~= hit then
      self.focus = hit
      self.caret = ulen(self.values[FIELDS[hit].key]) + 1
      self.sel_anchor = nil
    end
    local pos = caret_from_mouse(self, hit, px)
    local now = system.get_time()
    if self.last_click_field == hit and now - (self.last_click_time or 0) < 0.35 then
      -- double click: select the word around the clicked position
      local v = self.values[FIELDS[hit].key] or ""
      local s, e = word_range(v, math.min(pos, ulen(v)))
      if s then
        self.sel_anchor = s
        self.caret = e
      else
        self.sel_anchor = nil
      end
      self.drag = nil
    else
      self.caret = pos
      self.sel_anchor = nil
      self.drag = { field = hit, anchor = pos } -- possible drag selection
    end
    self.last_click_field = hit
    self.last_click_time = now
    self.blink_start = system.get_time()
    core.redraw = true
  end
  return true -- modal: swallow everything
end

function RemoteDialog:on_mouse_released(button, px, py)
  self.drag = nil
  return true
end

-- ---------------------------------------------------------------------------
-- commands (predicate: the dialog holds the active view)
-- ---------------------------------------------------------------------------

local function dialog_active()
  local v = core.active_view
  if v and getmetatable(v) == RemoteDialog then return true, v end
  return false
end

command.add(dialog_active, {
  ["remote-dialog:next-field"] = function(v)
    if v.dropdown then
      v.dropdown.selected = math.min(v.dropdown.selected + 1, #v.dropdown.items)
      core.redraw = true
    else
      v:move_focus(1)
    end
  end,
  ["remote-dialog:previous-field"] = function(v)
    if v.dropdown then
      v.dropdown.selected = math.max(v.dropdown.selected - 1, 1)
      core.redraw = true
    else
      v:move_focus(-1)
    end
  end,
  ["remote-dialog:backspace"] = function(v) v:backspace() end,
  ["remote-dialog:delete"] = function(v) v:forward_delete() end,
  ["remote-dialog:open-history"] = function(v) v:open_dropdown() end,
  ["remote-dialog:caret-left"] = function(v) v:caret_move(-1, false) end,
  ["remote-dialog:caret-right"] = function(v) v:caret_move(1, false) end,
  ["remote-dialog:select-left"] = function(v) v:caret_move(-1, true) end,
  ["remote-dialog:select-right"] = function(v) v:caret_move(1, true) end,
  ["remote-dialog:caret-home"] = function(v) v:caret_to(1, false) end,
  ["remote-dialog:caret-end"] = function(v) v:caret_to(math.huge, false) end,
  ["remote-dialog:select-home"] = function(v) v:caret_to(1, true) end,
  ["remote-dialog:select-end"] = function(v) v:caret_to(math.huge, true) end,
  ["remote-dialog:select-all"] = function(v) v:select_all() end,
  ["remote-dialog:copy"] = function(v) v:copy() end,
  ["remote-dialog:cut"] = function(v) v:cut() end,
  ["remote-dialog:paste"] = function(v) v:paste() end,
  ["remote-dialog:submit"] = function(v)
    if v.dropdown then
      v:pick_dropdown(v.dropdown.selected)
    elseif v.focus == #FIELDS then
      v:submit()
    else
      v:move_focus(1)
    end
  end,
  ["remote-dialog:cancel"] = function(v) v:dismiss() end,
})

keymap.add({
  ["tab"] = "remote-dialog:next-field",
  ["shift+tab"] = "remote-dialog:previous-field",
  ["down"] = "remote-dialog:next-field",
  ["up"] = "remote-dialog:previous-field",
  ["backspace"] = "remote-dialog:backspace",
  ["delete"] = "remote-dialog:delete",
  ["left"] = "remote-dialog:caret-left",
  ["right"] = "remote-dialog:caret-right",
  ["shift+left"] = "remote-dialog:select-left",
  ["shift+right"] = "remote-dialog:select-right",
  ["home"] = "remote-dialog:caret-home",
  ["end"] = "remote-dialog:caret-end",
  ["shift+home"] = "remote-dialog:select-home",
  ["shift+end"] = "remote-dialog:select-end",
  ["ctrl+p"] = "remote-dialog:open-history",
  ["cmd+p"] = "remote-dialog:open-history",
  ["ctrl+a"] = "remote-dialog:select-all",
  ["cmd+a"] = "remote-dialog:select-all",
  ["ctrl+c"] = "remote-dialog:copy",
  ["cmd+c"] = "remote-dialog:copy",
  ["ctrl+x"] = "remote-dialog:cut",
  ["cmd+x"] = "remote-dialog:cut",
  ["ctrl+v"] = "remote-dialog:paste",
  ["cmd+v"] = "remote-dialog:paste",
})

keymap.add({
  ["escape"] = "remote-dialog:cancel",
  ["return"] = "remote-dialog:submit",
  ["keypad enter"] = "remote-dialog:submit",
})


-- NOTE: no keymap.on_key_pressed wrapper here. core.step discards the
-- textinput event that follows a key press when the keymap reported the key
-- as handled, so swallowing keys would make the dialog untypeable. Editor
-- commands are already inert while the dialog holds the active view (their
-- DocView/CommandView predicates fail); the remote-dialog:* bindings above
-- handle navigation, and text arrives through the textinput event, which
-- core routes to the active view.

-- ---------------------------------------------------------------------------
-- draw
-- ---------------------------------------------------------------------------

---Mixes two colors: t=0 returns a, t=1 returns b.
local function blend(a, b, t)
  return {
    a[1] + (b[1] - a[1]) * t,
    a[2] + (b[2] - a[2]) * t,
    a[3] + (b[3] - a[3]) * t,
    (a[4] or 255) + ((b[4] or 255) - (a[4] or 255)) * t,
  }
end

---The palette for the dialog. This fork's default theme uses a light
---"chrome" (sidebar, tab bar, status bar) with a dark editor, so the
---dialog is drawn as light chrome: panel = background2, text = chrome_text
---(falls back to style.text for the stock dark themes).
local function palette()
  local panel = style.background2 or style.background3 or style.background
  local text = style.chrome_text or style.text
  local accent = style.sidebar_accent or style.accent
  return {
    panel = panel,
    text = text,
    label = blend(text, panel, 0.30),
    hint = blend(text, panel, 0.48),
    field_bg = blend(panel, text, 0.045),
    field_bg_focus = blend(panel, accent, 0.06),
    field_border = blend(panel, text, 0.18),
    field_border_hover = blend(panel, text, 0.32),
    divider = blend(panel, text, 0.14),
    hover = blend(panel, text, 0.08),
    btn_border = blend(panel, text, 0.20),
    accent = accent,
    on_accent = blend(accent, { 255, 255, 255 }, 0.94),
    error_color = style.error or style.warn or text,
  }
end

---Cached slightly-larger header font (rebuilt if style.font or SCALE changes).
local title_font, title_font_key
local function get_title_font()
  local key = tostring(style.font) .. "/" .. SCALE
  if not title_font or title_font_key ~= key then
    title_font = style.font:copy(16 * SCALE)
    title_font_key = key
  end
  return title_font
end

---Fills a rounded rect with an inset hairline stroke of `border_color`.
local function outlined_rect(x, y, w, h, r, bg, border_color, t)
  renderer.draw_rounded_rect(x, y, w, h, r, border_color)
  renderer.draw_rounded_rect(x + t, y + t, w - t * 2, h - t * 2,
    math.max(0, r - t), bg)
end

function RemoteDialog:draw()
  if not self.visible then return end
  local m = metrics()
  local lh = m.lh
  local p = palette()
  -- the renderer's rounded rects are not anti-aliased, so keep radii small
  local panel_r = math.max(6, common.round(8 * SCALE))
  local ctl_r = math.max(3, common.round(5 * SCALE))
  local hairline = math.max(1, common.round(1 * SCALE))
  local text_inset = 10 * SCALE

  -- dark scrim over the editor
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y,
    { 0, 0, 0, 90 })

  local bx, by, bw, bh = dialog_geometry(self)

  -- soft drop shadow (two layered translucent sheets), hairline ring, panel
  renderer.draw_rounded_rect(bx + 2 * SCALE, by + 4 * SCALE, bw, bh,
    panel_r + 1, { 0, 0, 0, 30 })
  renderer.draw_rounded_rect(bx, by + 2 * SCALE, bw, bh, panel_r, { 0, 0, 0, 55 })
  outlined_rect(bx, by, bw, bh, panel_r, p.panel, p.divider, hairline)

  -- header: title + thin divider
  local tf = get_title_font()
  common.draw_text(tf, p.text, "打开远端目录", nil,
    bx + m.pad_x, by + m.pad_y, 0, m.title_h)
  renderer.draw_rect(bx + m.pad_x, by + m.pad_y + m.header_h - 6 * SCALE,
    bw - m.pad_x * 2, hairline, p.divider)

  for i, field in ipairs(FIELDS) do
    local fx, fy, fw, fh = field_rect(self, i)
    local focused = i == self.focus
    local hovered = i == self.hovered_field

    common.draw_text(style.font, focused and p.text or p.label, field.label,
      nil, fx, fy - m.label_gap - lh, 0, lh)

    -- input surface: hairline border, accent border + subtle tint when focused
    local bg = focused and p.field_bg_focus or p.field_bg
    local ring = focused and p.accent
      or hovered and p.field_border_hover or p.field_border
    outlined_rect(fx, fy, fw, fh, ctl_r, bg, ring, hairline)

    -- history chevron (▾); the value is truncated so it never runs under it
    local cx, cy, cw, ch = chevron_rect(self, i)
    local text_w = fw - text_inset * 2
    if cx then text_w = text_w - cw - 2 * SCALE end

    local raw = self.values[field.key] or ""
    -- masked fields draw one bullet per character (not per byte)
    local value = field.mask and ("•"):rep(ulen(raw)) or raw
    value = util.truncate_to_width(style.font, value, text_w)
    -- selection highlight (before the text) for the focused field
    if focused then
      self:normalise_caret()
      local a, b = self:selection()
      if a then
        local sel_x1 = fx + text_inset
          + style.font:get_width(char_sub(value, 1, a - 1))
        local sel_x2 = fx + text_inset
          + style.font:get_width(char_sub(value, 1, b - 1))
        if sel_x2 > fx + text_inset + text_w then
          sel_x2 = fx + text_inset + text_w
        end
        if sel_x1 < sel_x2 then
          renderer.draw_rounded_rect(sel_x1, fy + (fh - lh) / 2,
            sel_x2 - sel_x1, lh, math.max(1, ctl_r - 3),
            blend(p.accent, p.panel, 0.55))
        end
      end
    end
    common.draw_text(style.font, p.text, value, nil,
      fx + text_inset, fy + (fh - lh) / 2, 0, lh)
    -- caret at the caret character offset, clamped to the visible text width
    if focused and not self.dropdown
       and (system.get_time() - self.blink_start) % 1 < 0.5 then
      local caret_x = fx + text_inset
        + style.font:get_width(char_sub(value, 1, self.caret - 1))
      if caret_x > fx + text_inset + text_w then
        caret_x = fx + text_inset + text_w
      end
      renderer.draw_rect(caret_x, fy + (fh - lh) / 2, hairline + 1, lh, p.text)
    end
    -- clickable history chevron (▾): subtle hover chip + glyph
    if cx then
      local c_hover = self.hovered_chevron == i
      if c_hover then
        renderer.draw_rounded_rect(cx + 3 * SCALE, cy + 3 * SCALE,
          cw - 6 * SCALE, ch - 6 * SCALE, math.max(2, ctl_r - 1), p.hover)
      end
      common.draw_text(style.font, (c_hover or focused) and p.text or p.hint,
        "▾", "center", cx, cy, cw, ch)
    end
  end

  -- footer: hint on the left, action buttons on the right
  local connect_rect, cancel_rect = button_rects(self)
  local function draw_button(rect, label, primary)
    local hovered = self.hovered_button == (primary and "connect" or "cancel")
    if primary then
      local bg = hovered and blend(p.accent, { 0, 0, 0 }, 0.12) or p.accent
      renderer.draw_rounded_rect(rect.x, rect.y, rect.w, rect.h, ctl_r, bg)
      common.draw_text(style.font, p.on_accent, label, "center",
        rect.x, rect.y, rect.w, rect.h)
    else
      outlined_rect(rect.x, rect.y, rect.w, rect.h, ctl_r, p.panel,
        p.btn_border, hairline)
      if hovered then
        renderer.draw_rounded_rect(rect.x + hairline, rect.y + hairline,
          rect.w - hairline * 2, rect.h - hairline * 2,
          math.max(1, ctl_r - hairline), p.hover)
      end
      common.draw_text(style.font, p.text, label, "center",
        rect.x, rect.y, rect.w, rect.h)
    end
  end
  draw_button(cancel_rect, "取消", false)
  draw_button(connect_rect, "连接", true)

  -- footer hint / error, vertically centered on the button row
  local footer_y = connect_rect.y + (connect_rect.h - lh) / 2
  if self.error_message then
    common.draw_text(style.font, p.error_color, self.error_message, nil,
      bx + m.pad_x, footer_y, 0, lh)
  else
    common.draw_text(style.font, p.hint,
      "tab 切换 · esc 取消", nil,
      bx + m.pad_x, footer_y, 0, lh)
  end

  -- history dropdown, drawn last so it always sits above fields and buttons
  if self.dropdown then
    local fx, ddy, fw, ddh, item_h = dropdown_rect(self)
    local dd = self.dropdown
    renderer.draw_rounded_rect(fx, ddy + 2 * SCALE, fw, ddh, ctl_r + 1,
      { 0, 0, 0, 45 })
    outlined_rect(fx, ddy, fw, ddh, ctl_r + 1, p.panel, p.divider, hairline)
    for n, item in ipairs(dd.items) do
      if (n - 1) * item_h + 8 * SCALE > ddh then break end -- beyond the box
      local rx, ry, rw, rh = dropdown_item_rect(self, n)
      if n == dd.selected then
        renderer.draw_rounded_rect(rx + 3 * SCALE, ry, rw - 6 * SCALE, rh,
          math.max(2, ctl_r - 1), p.hover)
      end
      common.draw_text(style.font, p.text,
        type(item) == "table" and item.text or item, nil,
        rx + text_inset, ry + (rh - lh) / 2, 0, lh)
      if type(item) == "table" and item.info then
        common.draw_text(style.font, p.hint, item.info, "right",
          rx + text_inset, ry + (rh - lh) / 2, rw - text_inset * 2, lh)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- showing: overlay draw + focus grab, modeled on core.dialog
-- ---------------------------------------------------------------------------

local old_root_draw = RootView.draw
function RootView:draw(...)
  old_root_draw(self, ...)
  if active_dialog and active_dialog.visible then
    local ok, err = pcall(active_dialog.draw, active_dialog)
    if not ok then
      active_dialog:dismiss()
      core.error("[remote-dialog] draw failed: %s", err)
    end
  end
end

local old_root_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(...)
  if active_dialog and active_dialog.visible then
    return active_dialog:on_mouse_pressed(...)
  end
  return old_root_mouse_pressed(self, ...)
end

local old_root_mouse_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(...)
  if active_dialog and active_dialog.visible then
    return active_dialog:on_mouse_moved(...)
  end
  return old_root_mouse_moved(self, ...)
end

local old_root_mouse_released = RootView.on_mouse_released
function RootView:on_mouse_released(...)
  if active_dialog and active_dialog.visible then
    return active_dialog:on_mouse_released(...)
  end
  return old_root_mouse_released(self, ...)
end

---Shows the connect dialog. `on_connect(host, user, password, port, dir)`.
function RemoteDialog.show(on_connect)
  if active_dialog and active_dialog.visible then return end
  local d = RemoteDialog(on_connect)
  d.size.x, d.size.y = core.root_view.size.x, core.root_view.size.y
  d.position.x, d.position.y = core.root_view.position.x, core.root_view.position.y
  d.visible = true
  d.force_focus = true
  active_dialog = d
  core.set_active_view(d)
  core.redraw = true
end

rawset(_G, "__lite_xl_remote_dialog", RemoteDialog)

return RemoteDialog
