-- mod-version:4
-- ------------------------------------------------------------
-- imageview.lua -- 直接在编辑器中预览图片文件
--
-- 功能：
--   * 打开 png/jpg/jpeg/bmp/gif/tga/psd/pic/pnm 等文件时，
--     自动用图片视图代替文本视图（树形视图双击、拖拽、命令面板均生效）
--   * 默认按窗口自适应显示；滚轮滚动，Ctrl+滚轮缩放
--   * 左键拖拽平移；双击在「适应窗口 / 100%」之间切换
--   * 命令：imageview:zoom-in / zoom-out / zoom-fit / zoom-100
--     （默认键位 ctrl+= / ctrl+- / ctrl+0）
--   * 图片以只读方式打开，任何情况下不会写回图片文件
-- ------------------------------------------------------------
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local DocView = require "core.docview"
local RootView = require "core.rootview"
local command = require "core.command"
local keymap = require "core.keymap"
local renderer = require "renderer"
local system = require "system"

if not renderer.image or not renderer.image.load then
  core.warn("imageview: 当前构建的 renderer 不支持 image API，插件已停用")
  return
end

config.plugins.imageview = common.merge({
  enabled = true,
  max_file_size = 64 * 1024 * 1024, -- 超过此大小的文件不加载
  max_pixels = 64 * 1024 * 1024,    -- 超过此像素数的图片不加载
  zoom_factor = 1.2,                -- 每次缩放的倍率
  fit_allow_upscale = false,        -- 适应窗口时是否允许放大（默认只缩小）
  fit_max_ratio = 0.75,             -- 适应窗口时最大占视口宽/高的比例（1 = 铺满）
}, config.plugins.imageview)

local IMAGE_EXTENSIONS = {
  png = true, jpg = true, jpeg = true, bmp = true, gif = true,
  tga = true, psd = true, pic = true, pnm = true,
  ppm = true, pgm = true, pbm = true, hdr = true,
}

local function is_image_file(filename)
  local ext = filename:match("%.([^./\\]+)$")
  return ext and IMAGE_EXTENSIONS[ext:lower()] or false
end

local PAD = 12 -- 内容四周留白（会乘以 SCALE）

local ImageView = View:extend()

function ImageView:new(doc)
  ImageView.super.new(self)
  self.context = "session"
  self.doc = doc
  self.cursor = "arrow"
  self.scrollable = true
  self.zoom = nil -- nil = 适应窗口；数字 = 相对原图的缩放比（1 = 100%）
  self.image = nil
  self.image_error = nil
  self.panning = nil
  self:load_image()
  self:attach_readonly(doc)
end


function ImageView:load_image()
  local path = self.doc.abs_filename or self.doc.filename
  local cfg = config.plugins.imageview
  local info = path and system.get_file_info(path)
  if info and cfg.max_file_size and info.size > cfg.max_file_size then
    self.image_error = string.format("文件过大（%.1f MB），已跳过加载",
      info.size / 1024 / 1024)
    return
  end
  local ok, img = pcall(renderer.image.load, path)
  if not ok or not img then
    self.image_error = tostring(img and img or "无法解码图片")
    return
  end
  local iw, ih = img:get_size()
  if cfg.max_pixels and iw * ih > cfg.max_pixels then
    self.image_error = string.format("图片过大（%d x %d），已跳过加载", iw, ih)
    return
  end
  self.image = img
  self.image_w, self.image_h = iw, ih
end


function ImageView:get_name()
  return common.basename(self.doc.filename or "image")
end


function ImageView:get_filename()
  return self.doc.abs_filename
    and common.home_encode(self.doc.abs_filename)
    or self:get_name()
end


-- 返回图片当前的显示尺寸（屏幕像素）
function ImageView:get_draw_size()
  local iw, ih = self.image_w, self.image_h
  if not iw then return 0, 0 end
  if self.zoom then
    return iw * self.zoom, ih * self.zoom
  end
  local pad = PAD * SCALE
  local vw, vh = self.size.x - pad * 2, self.size.y - pad * 2
  if vw <= 0 or vh <= 0 then return iw, ih end
  local s = math.min(vw / iw, vh / ih)
  local ratio = common.clamp(config.plugins.imageview.fit_max_ratio or 1, 0.05, 1)
  if s < 1 then
    -- 大图需要缩小：最多占视口 ratio 比例，留出周边空白
    s = s * ratio
  elseif not config.plugins.imageview.fit_allow_upscale then
    -- 小图按原尺寸显示，不放大铺满
    s = 1
  else
    s = s * ratio
  end
  return iw * s, ih * s
end


function ImageView:get_scrollable_size()
  local dw, dh = self:get_draw_size()
  return math.max(self.size.y, dh + PAD * SCALE * 2)
end


function ImageView:get_h_scrollable_size()
  local dw, dh = self:get_draw_size()
  return math.max(self.size.x, dw + PAD * SCALE * 2)
end


-- 图片绘制起点（屏幕坐标）
function ImageView:get_image_position()
  local dw, dh = self:get_draw_size()
  local pad = PAD * SCALE
  local x, y
  if self.size.x >= dw + pad * 2 then
    x = self.position.x + (self.size.x - dw) / 2
  else
    x = self.position.x + pad - self.scroll.x
  end
  if self.size.y >= dh + pad * 2 then
    y = self.position.y + (self.size.y - dh) / 2
  else
    y = self.position.y + pad - self.scroll.y
  end
  return x, y, dw, dh
end


function ImageView:set_zoom(zoom)
  local min_zoom = 0.02
  local max_zoom = 32
  self.zoom = common.clamp(zoom or 1, min_zoom, max_zoom)
  self:clamp_scroll_position()
end


function ImageView:zoom_fit()
  self.zoom = nil
  self.scroll.to.x, self.scroll.to.y = 0, 0
  self.scroll.x, self.scroll.y = 0, 0
end


function ImageView:zoom_around_center(factor)
  local old_dw, old_dh = self:get_draw_size()
  local cx, cy = self.scroll.x + self.size.x / 2, self.scroll.y + self.size.y / 2
  local new_zoom
  if self.zoom then
    new_zoom = self.zoom * factor
  else
    -- 从适应模式放大：以当前显示尺寸为基准
    local fit_w = old_dw > 0 and self.image_w / old_dw or 1
    new_zoom = 1 / fit_w * factor
  end
  self:set_zoom(new_zoom)
  -- 让缩放前后视口中心对应的图像内容保持不动
  local dw, dh = self:get_draw_size()
  local sx = common.clamp(cx / math.max(old_dw, 1), 0, 1)
  local sy = common.clamp(cy / math.max(old_dh, 1), 0, 1)
  self.scroll.to.x = math.max(0, sx * dw - self.size.x / 2)
  self.scroll.to.y = math.max(0, sy * dh - self.size.y / 2)
end


function ImageView:on_mouse_pressed(button, x, y, clicks)
  local consumed = ImageView.super.on_mouse_pressed(self, button, x, y, clicks)
  if consumed then return consumed end
  if button == "left" then
    if clicks == 2 then
      if self.zoom then self:zoom_fit() else self:set_zoom(1) end
      return true
    end
    self.panning = { x = x, y = y, sx = self.scroll.to.x, sy = self.scroll.to.y }
    self.cursor = "hand"
    return true
  end
end


function ImageView:on_mouse_moved(x, y, dx, dy)
  if self.panning then
    self.scroll.to.x = self.panning.sx - (x - self.panning.x)
    self.scroll.to.y = self.panning.sy - (y - self.panning.y)
    return true
  end
  return ImageView.super.on_mouse_moved(self, x, y, dx, dy)
end


function ImageView:on_mouse_released(button, x, y)
  self.panning = nil
  self.cursor = "arrow"
  return ImageView.super.on_mouse_released(self, button, x, y)
end


function ImageView:on_mouse_wheel(dy, dx)
  if keymap.modkeys["ctrl"] then
    local factor = dy > 0 and config.plugins.imageview.zoom_factor
      or 1 / config.plugins.imageview.zoom_factor
    if dx ~= 0 then factor = 1 / factor end
    self:zoom_around_center(factor)
    return true
  end
  local step = config.mouse_wheel_scroll or 50 * SCALE
  self.scroll.to.x = self.scroll.to.x + dx * step
  self.scroll.to.y = self.scroll.to.y - dy * step
  return true
end


function ImageView:draw()
  self:draw_background(style.background)
  if self.image then
    local x, y, dw, dh = self:get_image_position()
    -- 裁剪到视图区域
    core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
    renderer.draw_image(self.image, x, y, dw, dh)
    core.pop_clip_rect()
  else
    local msg = self.image_error or "图片加载失败"
    common.draw_text(style.font, style.dim, msg, "center",
      self.position.x, self.position.y, self.size.x, self.size.y / 2)
  end

  -- 底部信息条：文件名 · 尺寸 · 缩放比
  if self.image then
    local _, _, dw = self:get_draw_size()
    local zoom_text
    if self.zoom then
      zoom_text = string.format("%d%%", math.floor(self.zoom * 100 + 0.5))
    else
      zoom_text = "适应窗口"
    end
    local info = string.format("%s · %d x %d · %s",
      self:get_name(), self.image_w, self.image_h, zoom_text)
    local pad = PAD * SCALE
    common.draw_text(style.font, style.dim, info, "left",
      self.position.x + pad, self.position.y + self.size.y
        - style.font:get_height() - pad * 0.5,
      self.size.x - pad * 2, style.font:get_height())
  end

  self:draw_scrollbar()
end


-- 图片视图不参与任何文本命令（不继承 DocView 即天然隔离），
-- 这里再把 doc.save 置为空操作，作为兜底保护
function ImageView:attach_readonly(doc)
  doc.save = function(_, ...)
    core.log("imageview: 图片文件为只读，未保存")
  end
end


-- ------------------------------------------------------------
-- 接入打开文件的流程
-- ------------------------------------------------------------

function ImageView:try_close(do_close)
  do_close()
end


local function open_image_doc(self, doc)
  local node = self:get_active_node_default()
  for _, view in ipairs(node.views) do
    if view:is(ImageView) and view.doc == doc then
      node:set_active_view(view)
      return view
    end
  end
  local view = ImageView(doc)
  node:add_view(view)
  self.root_node:update_layout()
  return view
end


local rootview_open_doc = RootView.open_doc
function RootView:open_doc(doc)
  local filename = doc.filename or doc.abs_filename or ""
  if config.plugins.imageview.enabled and is_image_file(filename) then
    return open_image_doc(self, doc)
  end
  return rootview_open_doc(self, doc)
end


-- ------------------------------------------------------------
-- 命令
-- ------------------------------------------------------------

local function active_imageview()
  return core.active_view and core.active_view:is(ImageView)
end

command.add(active_imageview, {
  ["imageview:zoom-in"] = function()
    core.active_view:zoom_around_center(config.plugins.imageview.zoom_factor)
  end,

  ["imageview:zoom-out"] = function()
    core.active_view:zoom_around_center(1 / config.plugins.imageview.zoom_factor)
  end,

  ["imageview:zoom-fit"] = function()
    core.active_view:zoom_fit()
  end,

  ["imageview:zoom-100"] = function()
    core.active_view:set_zoom(1)
  end,
})

keymap.add({
  ["ctrl+="] = "imageview:zoom-in",
  ["ctrl+-"] = "imageview:zoom-out",
  ["ctrl+0"] = "imageview:zoom-fit",
})

-- 让 treeview 等地方对图片的判断可用（供其他插件引用）
core.imageview = ImageView

return ImageView
