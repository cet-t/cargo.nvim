local M = {}

M.commands = {
  { label = "test (all)",      args = { "test" } },
  { label = "test --release",  args = { "test", "--release" } },
  { label = "test <filter>",   args = { "test" }, prompt = "filter" },
  { label = "test --no-run",   args = { "test", "--no-run" } },
}

function M.render_lines(selected, results)
  local lines = {}
  local hl_map = {}

  local function add(line, hl)
    table.insert(lines, line)
    if hl then hl_map[#lines] = hl end
  end

  add("  COMMANDS", "CargoCategoryTitle")
  for i, cmd in ipairs(M.commands) do
    local prefix = (i == selected) and " ▶ " or "   "
    local hl = (i == selected) and "CargoSelected" or "CargoNormal"
    add(prefix .. cmd.label, hl)
  end

  if results and #results > 0 then
    add("", nil)
    add("  ──────────────────────", "CargoSeparator")
    add("  RESULTS", "CargoCategoryTitle")
    for _, r in ipairs(results) do
      local icon = r.ok and "✓" or "✗"
      local hl = r.ok and "CargoSuccess" or "CargoError"
      add("  " .. icon .. " " .. r.name, hl)
    end
  end

  return lines, hl_map
end

return M
