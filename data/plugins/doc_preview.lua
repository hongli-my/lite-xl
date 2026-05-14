-- mod-version:4
-- Markdown Preview Plugin
-- F6: Preview current Markdown file in system browser via rendered HTML
-- Requires: lowdown, pandoc, or cmark for Markdown→HTML conversion
-- Falls back: writes raw Markdown as HTML body (basic fallback)

local core = require "core"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local common = require "core.common"
local DocView = require "core.docview"
local process = require "core.process"

config.plugins.doc_preview = common.merge({
  -- Whether to auto-save before preview
  auto_save = true,
  -- Previewer command: "lowdown", "pandoc", "cmark", or nil for fallback
  renderer = nil,
  -- Extra args passed to the renderer
  renderer_args = {},
  -- Temp dir for generated HTML
  output_dir = os.tmpname():gsub("tmp.*$", ""),
}, config.plugins.doc_preview)

local function is_markdown(filename)
  if not filename then return false end
  return filename:match("%.md$") or filename:match("%.markdown$")
end

local function find_renderer()
  local candidates = { "lowdown", "pandoc", "cmark", "markdown" }
  for _, cmd in ipairs(candidates) do
    local p = process.start({ "which", cmd })
    p:wait(2)
    if p:returncode() == 0 then
      return cmd
    end
  end
  return nil
end

local function render_markdown_to_html(md_text, filename)
  local renderer = config.plugins.doc_preview.renderer or find_renderer()
  local html_parts = {
    [[<!DOCTYPE html><html><head><meta charset="utf-8"><title>]],
    filename and common.basename(filename) or "Preview",
    [[</title>]],
    [[<style>body{max-width:800px;margin:40px auto;padding:0 20px;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;line-height:1.6;color:#333}pre{background:#f5f5f5;padding:10px;border-radius:4px;overflow-x:auto}code{background:#f0f0f0;padding:2px 4px;border-radius:3px}pre code{background:none;padding:0}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ddd;padding:8px;text-align:left}th{background:#f5f5f5}blockquote{border-left:4px solid #ddd;margin:0;padding:0 15px;color:#666}img{max-width:100%}h1,h2,h3,h4{color:#222;margin-top:24px}</style>]],
    [[</head><body>]]
  }

  if renderer then
    -- Use external renderer
    local cmd = { renderer }
    for _, arg in ipairs(config.plugins.doc_preview.renderer_args) do
      table.insert(cmd, arg)
    end

    local p = process.start(cmd, { stdin = process.REDIRECT_DEFAULT })
    p.stdin:write(md_text)
    p.stdin:close()
    p:wait(5)

    local ok, stdout = pcall(p.stdout.read, p.stdout, "all", { timeout = 5 })
    if ok and stdout and #stdout > 0 then
      table.insert(html_parts, stdout)
    else
      -- Fallback: try to render via Lua
      table.insert(html_parts, simple_markdown_render(md_text))
    end
  else
    -- No external renderer, try simple Lua renderer if cmark not available
    -- Install cmark: brew install cmark
    local msg = [[<div style="background:#fff3cd;border:1px solid #ffc107;padding:12px;border-radius:4px;margin:20px 0">
      <strong>No Markdown renderer found.</strong><br>
      Install one of: <code>brew install lowdown</code>, <code>brew install pandoc</code>, or <code>brew install cmark</code>
    </div>]]
    table.insert(html_parts, msg)
    table.insert(html_parts, simple_markdown_render(md_text))
  end

  table.insert(html_parts, [[</body></html>]])
  return table.concat(html_parts, "")
end

-- Simple Markdown renderer (basic subset, for fallback)
local function escape_html(s)
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
  return s
end

local function simple_markdown_render(md_text)
  local out = {}
  local in_code = false
  local code_buf = {}

  local function emit()
    if #code_buf > 0 then
      local esc = {}
      for _, l in ipairs(code_buf) do table.insert(esc, escape_html(l)) end
      out[#out + 1] = "<pre><code>" .. table.concat(esc, "\n") .. "</code></pre>"
      code_buf = {}
    end
    if not in_code then
      -- Remove trailing paragraph breaks for continuity
    end
  end

  local function emit_line(line)
    -- Handle code block fences
    if line:match("^```") then
      if in_code then
        emit()
        in_code = false
      else
        emit()
        in_code = true
      end
      return
    end

    if in_code then
      code_buf[#code_buf + 1] = line
      return
    end

    -- Empty line
    if line:match("^%s*$") then
      out[#out + 1] = ""
      return
    end

    -- Headings
    local hashes, heading_text = line:match("^(#+)%s+(.*)")
    if hashes then
      local level = math.min(#hashes, 6)
      out[#out + 1] = string.format("<h%d>%s</h%d>", level, escape_html(heading_text), level)
      return
    end

    -- Horizontal rule
    if line:match("^[-*_]{3,}$") then
      out[#out + 1] = "<hr>"
      return
    end

    -- Blockquote
    local q = line:match("^>%s*(.*)")
    if q then
      out[#out + 1] = "<blockquote>" .. escape_html(q) .. "</blockquote>"
      return
    end

    -- Unordered list
    local ul = line:match("^%s*[-*+]%s+(.*)")
    if ul then
      out[#out + 1] = "<li>" .. inline_markdown(ul) .. "</li>"
      return
    end

    -- Ordered list
    local ol = line:match("^%s*%d+[%.%)]%s+(.*)")
    if ol then
      out[#out + 1] = "<li>" .. inline_markdown(ol) .. "</li>"
      return
    end

    -- Regular paragraph
    out[#out + 1] = "<p>" .. inline_markdown(escape_html(line)) .. "</p>"
  end

  for l in md_text:gmatch("([^\n]*)\n?") do
    emit_line(l)
  end

  if in_code then
    local esc = {}
    for _, l in ipairs(code_buf) do table.insert(esc, escape_html(l)) end
    out[#out + 1] = "<pre><code>" .. table.concat(esc, "\n") .. "</code></pre>"
  end
  return table.concat(out, "\n")
end

local function inline_markdown(text)
  -- Images: ![alt](url)
  text = text:gsub("!%[([^%]]*)%]%(([^)]+)%)", '<img src="%2" alt="%1" style="max-width:100%">')
  -- Links: [text](url)
  text = text:gsub("%[([^%]]*)%]%(([^)]+)%)", '<a href="%2">%1</a>')
  -- Bold: **text** or __text__
  text = text:gsub("%*%*(.-)%*%*", "<strong>%1</strong>")
  text = text:gsub("__(.-)__", "<strong>%1</strong>")
  -- Italic: *text* or _text_
  text = text:gsub("%*(.-)%*", "<em>%1</em>")
  text = text:gsub("_(.-)_", "<em>%1</em>")
  -- Inline code: `code`
  text = text:gsub("`(.-)`", "<code>%1</code>")
  -- Strikethrough: ~~text~~
  text = text:gsub("~~(.-)~~", "<del>%1</del>")
  return text
end

local function preview_markdown()
  local view = core.active_view
  if not view or not view:is(DocView) then
    core.status_view:show_message("No document open", 2)
    return
  end

  local doc = view.doc
  if not is_markdown(doc.filename) then
    -- Allow preview even for unsaved new files
    if not doc.new_file then
      core.status_view:show_message("Not a Markdown file", 2)
      return
    end
  end

  -- Auto-save if configured
  if config.plugins.doc_preview.auto_save and not doc.new_file then
    command.perform("doc:save")
  end

  local md_text = doc:get_text(1, 1, math.huge, math.huge)
  local html = render_markdown_to_html(md_text, doc.filename)

  -- Write to temp file and open in browser
  local tmpfile = os.tmpname() .. ".html"
  local fp = io.open(tmpfile, "w")
  if fp then
    fp:write(html)
    fp:close()
    -- Open in system browser
    system.exec(string.format("open %q", tmpfile))
    core.status_view:show_message("Preview opened in browser", 2)
  else
    core.status_view:show_message("Failed to create preview file", 3)
  end
end

command.add("core.docview", {
  ["doc:preview"] = preview_markdown,
})

keymap.add({ ["f6"] = "doc:preview" })

-- Show welcome message
local core_run = core.run
function core.run(...)
  local result = core_run(...)
  -- Check if renderer is available
  local renderer = config.plugins.doc_preview.renderer or find_renderer()
  if not renderer then
    core.log_quiet("Markdown preview: no renderer found. Install one: brew install lowdown (recommended), pandoc, or cmark")
  end
  return result
end