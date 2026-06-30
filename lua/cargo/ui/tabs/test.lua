local M = {}

M.commands = {
  { label = "test (all)",       args = { "test" } },
  { label = "test --release",   args = { "test", "--release" } },
  { label = "test <filter>",    args = { "test" }, prompt = "filter" },
  { label = "test --no-run",    args = { "test", "--no-run" } },
}

function M.render_rows(selected, results)
  local rows = {}
  table.insert(rows, { text = "  COMMANDS", hl = "CargoCategoryTitle" })
  for i, cmd in ipairs(M.commands) do
    local sel = i == selected
    table.insert(rows, {
      text    = (sel and " ▶  " or "    ") .. cmd.label,
      hl      = sel and "CargoSelected" or "CargoNormal",
      cmd_idx = i,
    })
  end
  if results and #results > 0 then
    table.insert(rows, { text = "  ─────────────────────", hl = "CargoSeparator" })
    table.insert(rows, { text = "  RESULTS", hl = "CargoCategoryTitle" })
    for _, r in ipairs(results) do
      table.insert(rows, {
        text = "  " .. (r.ok and "✓" or "✗") .. "  " .. r.name,
        hl   = r.ok and "CargoSuccess" or "CargoError",
      })
    end
  end
  return rows
end

return M
