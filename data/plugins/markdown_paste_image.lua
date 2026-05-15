-- mod-version:4
-- markdown_paste_image.lua
-- Paste images from clipboard into Markdown files
-- On macOS: uses `pngpaste` (brew install pngpaste)
-- On Linux: uses `xclip` (apt install xclip)

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"

-- Debug: confirm plugin loaded
core.log_quiet("markdown_paste_image plugin loaded, PLATFORM=%s", PLATFORM or "nil")

-- Configuration
config.markdown_paste_image = common.merge(config.markdown_paste_image or {}, {
  image_dir = "images",     -- Directory to save images (relative to markdown file)
  prefix = "image",         -- Image filename prefix
  format = "png",           -- Image format
  use_timestamp = true,     -- Use timestamp in filename
})

-- Check if the active view is a Markdown file
local function is_markdown()
  local dv = core.active_view
  if not dv or not dv.doc or not dv.doc.filename then return false end
  local ext = dv.doc.filename:match("%.([^.]+)$")
  return ext and (ext:lower() == "md" or ext:lower() == "markdown")
end

-- Generate a unique filename
local function generate_image_filename()
  local conf = config.markdown_paste_image
  local name = conf.prefix or "image"
  if conf.use_timestamp ~= false then
    name = name .. "-" .. os.date("%Y%m%d%H%M%S")
  end
  name = name .. "-" .. math.random(1000, 9999)
  return name .. "." .. (conf.format or "png")
end

-- Get relative path from markdown file to image
local function get_relative_path(doc_abs_path, filename)
  local conf = config.markdown_paste_image
  local dir_name = conf.image_dir or "images"
  local relative = dir_name .. "/" .. filename
  return relative
end
local function get_image_dir(doc_abs_path)
  local conf = config.markdown_paste_image
  local dir_name = conf.image_dir or "images"
  local doc_dir = doc_abs_path:match("(.*)[/\\]") or "."
  return doc_dir .. PATHSEP .. dir_name
end

-- Full path to pngpaste (cached)
local PNGPASTE_PATH = nil

-- Try to find pngpaste in common locations
local function find_pngpaste()
  if PNGPASTE_PATH then return PNGPASTE_PATH end
  -- Try common paths
  local paths = {
    "/opt/homebrew/bin/pngpaste",
    "/usr/local/bin/pngpaste",
    "/usr/bin/pngpaste",
    "pngpaste",
  }
  for _, p in ipairs(paths) do
    local f = io.open(p, "rb")
    if f then
      f:close()
      PNGPASTE_PATH = p
      return p
    end
  end
  -- Fallback: try which
  local h = io.popen("which pngpaste 2>/dev/null")
  if h then
    local p = h:read("*l")
    h:close()
    if p and p ~= "" then
      PNGPASTE_PATH = p
      return p
    end
  end
  return "pngpaste" -- last resort
end

-- Try to save clipboard image using pngpaste (macOS) or xclip (Linux)
-- Returns true on success, false if no image or failed
local function save_clipboard_image(dest_path)
  if PLATFORM == "macOS" or PLATFORM == "Mac OS X" then
    local pngpaste = find_pngpaste()
    core.log("Using pngpaste: %s", pngpaste)
    -- Use pngpaste: if clipboard has no image, it exits with error
    local cmd = string.format('%s %q 2>/dev/null; echo $?', pngpaste, dest_path)
    local handle = io.popen(cmd)
    if not handle then
      core.log("io.popen failed for pngpaste")
      return false
    end
    local result = handle:read("*a")
    handle:close()
    core.log("pngpaste output: [%s]", result or "nil")
    local exit_code = result:match("(%d+)%s*$")
    core.log("pngpaste exit code: %s", tostring(exit_code))
    if exit_code == "0" then
      -- Verify file was actually created and has content
      local f = io.open(dest_path, "rb")
      if f then
        local size = f:seek("end")
        f:close()
        core.log("Image saved, size=%d", size)
        return size > 0
      else
        core.log("File not found after pngpaste: %s", dest_path)
      end
    end
    return false

  elseif PLATFORM == "Linux" then
    local cmd = string.format(
      'xclip -selection clipboard -t image/png -o > %q 2>/dev/null; echo $?',
      dest_path
    )
    local handle = io.popen(cmd)
    if not handle then return false end
    local result = handle:read("*a")
    handle:close()
    if result:match("^0") then
      local f = io.open(dest_path, "rb")
      if f then
        local size = f:seek("end")
        f:close()
        return size > 0
      end
    end
    return false
  end

  return false
end

-- Debug command: always available, test if plugin commands work at all
command.add(nil, {
  ["markdown:test-paste-image"] = function()
    core.log("markdown_paste_image test: PLATFORM=%s, is_markdown=%s",
      PLATFORM or "nil", tostring(is_markdown()))

    -- Test pngpaste directly
    local test_path = "/tmp/lite_paste_test.png"
    local ok = save_clipboard_image(test_path)
    if ok then
      core.log("Image saved to %s successfully!", test_path)
    else
      core.log("No image in clipboard or save failed")
    end
  end,
})

-- Main command: smart paste for markdown files
command.add(function()
  local md = is_markdown()
  core.log_quiet("markdown:smart-paste predicate: is_markdown=%s", tostring(md))
  if md then
    return true, core.active_view
  end
  return false
end, {
  ["markdown:smart-paste"] = function(dv)
    core.log("markdown:smart-paste triggered!")
    local doc = dv.doc

    -- Need a saved file to know where to put images
    if not doc.abs_filename then
      core.log("No abs_filename, doing normal paste")
      command.perform("doc:paste")
      return
    end

    core.log("abs_filename: %s", doc.abs_filename)
    core.log("PLATFORM value: [%s]", tostring(PLATFORM))

    -- Ensure image directory exists
    local image_dir = get_image_dir(doc.abs_filename)
    core.log("image_dir: %s", image_dir)
    os.execute(string.format('mkdir -p %q', image_dir))

    -- Try to save clipboard image
    local filename = generate_image_filename()
    local abs_path = image_dir .. PATHSEP .. filename
    core.log("Trying to save to: %s", abs_path)

    local ok = save_clipboard_image(abs_path)
    core.log("save_clipboard_image returned: %s", tostring(ok))

    if ok then
      -- Success! Insert markdown image syntax
      local relative_path = get_relative_path(doc.abs_filename, filename)

      local line, col = doc:get_selection()
      local md_text = "![](" .. relative_path .. ")"
      doc:insert(line, col, md_text)
      -- Position cursor inside the [] for alt text
      doc:set_selection(line, col + 2)

      core.log("Image pasted: %s", relative_path)
    else
      -- No image in clipboard, or save failed -> normal text paste
      core.log("No image saved, doing normal paste")
      command.perform("doc:paste")
    end
  end,
})

-- Bind cmd+v / ctrl+v to smart-paste in markdown files
keymap.add({
  ["cmd+v"] = { "markdown:smart-paste", "doc:paste" },
})
