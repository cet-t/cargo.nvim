local M = {}

M.commands = {
  { label = "build",              args = { "build" } },
  { label = "build --release",    args = { "build", "--release" } },
  { label = "build --target …",   args = { "build", "--target" }, prompt = "target" },
  { label = "run",                args = { "run" } },
  { label = "run --release",      args = { "run", "--release" } },
  { label = "run -- <args>",      args = { "run", "--" }, prompt = "args" },
}

-- セクション区切り付きの表示行を返す
function M.render_lines(selected)
  local lines = {}
  local hl_map = {}  -- { line_index = hl_group }

  local function add(line, hl)
    table.insert(lines, line)
    if hl then hl_map[#lines] = hl end
  end

  add("  BUILD", "CargoCategoryTitle")
  for i, cmd in ipairs(M.commands) do
    if i == 4 then
      add("  ──────────────────────", "CargoSeparator")
      add("  RUN", "CargoCategoryTitle")
    end
    local prefix = (i == selected) and " ▶ " or "   "
    local hl = (i == selected) and "CargoSelected" or "CargoNormal"
    add(prefix .. cmd.label, hl)
  end

  return lines, hl_map
end

return M
