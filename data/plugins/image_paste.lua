-- mod-version:4
-- Image Paste Plugin
-- When pasting images (from clipboard), auto-save to an assets/ directory
-- relative to the current document, and insert Markdown image reference.
--
-- Also handles image files dragged from Finder.
-- On macOS, requires: brew install pngpaste

local core = require "core"
local command = require "core.command"
local config = require "core.config"
local common = require "core.common"
local keymap = require "core.keymap"
local DocView = require "core.docview"
local process = require "core.process"

config.plugins.image_paste = common.merge({
  images_dir = "assets",
  prefix = "",
  image_extensions = { ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".bmp" },
  output_format = "png",
  short_names = true,
}, config.plugins.image_paste)

local function is_image_file(filename)
  if not filename then return false end
  local lower = filename:lower()
  for _, ext in ipairs(config.plugins.image_paste.image_extensions) do
    if lower:match(ext .. "$") then return true end
  end
  return false
end

local function ensure_dir(dirpath)
  local info = system.get_file_info(dirpath)
  if info and info.type == "dir" then return true end
  return system.mkdir(dirpath)
end

local function generate_filename()
  if config.plugins.image_paste.short_names then
    local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    local name = {}
    for i = 1, 4 do local p = math.random(1, #chars); name[i] = chars:sub(p, p) end
    return table.concat(name)
  else
    return tostring(os.time())
  end
end

local function paste_image_from_clipboard()
  local view = core.active_view
  if not view or not view:is(DocView) then return false end

  local doc = view.doc
  if not doc.filename and doc.new_file then
    core.status_view:show_message("Save the document first before pasting images", 3)
    return false
  end

  local doc_dir = doc.filename:match("^(.+)[/\\][^/\\]+$") or "."
  local img_dir = doc_dir .. "/" .. config.plugins.image_paste.images_dir
  if not ensure_dir(img_dir) then
    core.status_view:show_message("Failed to create images directory", 3)
    return false
  end

  local ext = config.plugins.image_paste.output_format
  local name = config.plugins.image_paste.prefix .. generate_filename() .. "." .. ext
  local img_path = img_dir .. "/" .. name

  -- macOS: use pngpaste (brew install pngpaste)
  if PLATFORM == "macOS" then
    -- Check pngpaste availability
    local pp = process.start({ "which", "pngpaste" })
    pp:wait(2)
    if pp:returncode() ~= 0 then
      core.status_view:show_message("Install pngpaste: brew install pngpaste", 4)
      return false
    end

    local cp = process.start({ "pngpaste", img_path })
    cp:wait(5)
    if cp:returncode() ~= 0 then
      core.status_view:show_message("No image in clipboard", 2)
      return false
    end
  elseif PLATFORM == "Windows" then
    -- Windows: use PowerShell to get clipboard image
    local ps = process.start({
      "powershell", "-NoProfile", "-Command",
      [[Add-Type -AssemblyName System.Windows.Forms;
        $img = [System.Windows.Forms.Clipboard]::GetImage();
        if ($img) { $img.Save(']] .. img_path:gsub("\\", "\\\\") .. [[''); Write-Output 'ok' }
        else { Write-Output 'noimage' }]]
    })
    ps:wait(5)
    local ok = ps.stdout:read("all", { timeout = 3 })
    if not ok or ok:match("noimage") then
      core.status_view:show_message("No image in clipboard", 2)
      return false
    end
  else
    -- Linux: use xclip or wl-paste
    local p = process.start({ "which", "xclip" })
    p:wait(2)
    if p:returncode() == 0 then
      system.exec(string.format("xclip -selection clipboard -t image/png -o > %q 2>/dev/null", img_path))
    else
      local wp = process.start({ "which", "wl-paste" })
      wp:wait(2)
      if wp:returncode() == 0 then
        system.exec(string.format("wl-paste --type image/png > %q 2>/dev/null", img_path))
      else
        core.status_view:show_message("Install xclip or wl-paste for image paste", 4)
        return false
      end
    end
  end

  -- Verify
  local img_info = system.get_file_info(img_path)
  if not img_info or img_info.type ~= "file" or img_info.size == 0 then
    if PLATFORM ~= "macOS" then os.remove(img_path) end
    core.status_view:show_message("Failed to save clipboard image", 3)
    return false
  end

  -- Insert Markdown reference at cursor
  local relative_path = config.plugins.image_paste.images_dir .. "/" .. name
  local name_part = name:gsub("%." .. ext .. "$", "")
  local md_ref = "![" .. name_part .. "](" .. relative_path .. ")"
  doc:insert(doc:get_selection())
  doc:insert(doc:get_selection(), md_ref)

  core.status_view:show_message("Pasted: " .. relative_path, 3)
  return true
end

local function paste_image_command()
  if not paste_image_from_clipboard() then
    -- If no image in clipboard, let user know
    if PLATFORM == "macOS" then
      local pp = process.start({ "which", "pngpaste" })
      pp:wait(2)
      if pp:returncode() == 0 then
        core.status_view:show_message("No image in clipboard", 2)
      end
    end
  end
end

-- Handle file drops (image files dragged from Finder)
local root_view_on_file_dropped = core.root_view.on_file_dropped
function core.root_view:on_file_dropped(filename, x, y)
  if is_image_file(filename) then
    local view = core.active_view
    if view and view:is(DocView) then
      local doc = view.doc
      if doc.filename then
        local doc_dir = doc.filename:match("^(.+)[/\\][^/\\]+$") or "."
        local img_dir = doc_dir .. "/" .. config.plugins.image_paste.images_dir
        if not ensure_dir(img_dir) then return true end

        local basename = filename:match("[^/\\]+$")
        local dest = img_dir .. "/" .. basename

        if system.get_file_info(dest) then
          local name_no_ext = basename:match("^(.+)%.") or basename
          local ext = basename:match("%.(%w+)$") or ""
          basename = name_no_ext .. "_" .. tostring(os.time()) .. "." .. ext
          dest = img_dir .. "/" .. basename
        end

        -- Read and write file
        local sfp = io.open(filename, "rb")
        local dfp = io.open(dest, "wb")
        if sfp and dfp then
          dfp:write(sfp:read("a"))
          sfp:close()
          dfp:close()

          local relative_path = config.plugins.image_paste.images_dir .. "/" .. basename
          local name_part = basename:gsub("%.[%w]+$", "")
          local md_ref = "![" .. name_part .. "](" .. relative_path .. ")"
          doc:insert(doc:get_selection(), md_ref)
          core.status_view:show_message("Image dropped: " .. relative_path, 3)
        else
          if sfp then sfp:close() end
          if dfp then dfp:close() end
        end
        return true
      end
    end
  end
  return root_view_on_file_dropped and root_view_on_file_dropped(self, filename, x, y)
end

command.add("core.docview", {
  ["doc:paste-image"] = paste_image_command,
})

-- ctrl+shift+v for paste image
keymap.add({ ["ctrl+shift+v"] = "doc:paste-image" })

return {
  paste_image = paste_image_from_clipboard,
}