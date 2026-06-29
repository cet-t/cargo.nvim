local M = {}

M.commands = {
  { label = "fmt",               args = { "fmt" } },
  { label = "fmt --check",       args = { "fmt", "--", "--check" } },
  { label = "clippy",            args = { "clippy" } },
  { label = "clippy -D warnings",args = { "clippy", "--", "-D", "warnings" } },
  { label = "check",             args = { "check" } },
  { label = "doc",               args = { "doc" } },
  { label = "doc --open",        args = { "doc", "--open" } },
  { label = "clean",             args = { "clean" } },
  { label = "update",            args = { "update" } },
  { label = "publish --dry-run", args = { "publish", "--dry-run" } },
  { label = "publish",           args = { "publish" } },
}

function M.render_lines(selected)
  local lines = {}
  local hl_map = {}

  local function add(line, hl)
    table.insert(lines, line)
    if hl then hl_map[#lines] = hl end
  end

  add("  TOOLS", "CargoCategoryTitle")
  for i, cmd in ipairs(M.commands) do
    local prefix = (i == selected) and " ▶ " or "   "
    local hl = (i == selected) and "CargoSelected" or "CargoNormal"
    add(prefix .. cmd.label, hl)
  end

  return lines, hl_map
end

return M
