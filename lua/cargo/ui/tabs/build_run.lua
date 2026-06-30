local M = {}

M.commands = {
  -- BUILD
  { label = "build",              args = { "build" },                section = "BUILD" },
  { label = "build --release",    args = { "build", "--release" },   section = "BUILD" },
  { label = "build --target …",   args = { "build", "--target" },    section = "BUILD", prompt = "target" },
  -- RUN
  { label = "run",                args = { "run" },                  section = "RUN" },
  { label = "run --release",      args = { "run", "--release" },     section = "RUN" },
  { label = "run -- <args>",      args = { "run", "--" },            section = "RUN",   prompt = "args" },
  -- TOOLS
  { label = "fmt",                args = { "fmt" },                  section = "TOOLS" },
  { label = "clippy",             args = { "clippy" },               section = "TOOLS" },
  { label = "check",              args = { "check" },                section = "TOOLS" },
  { label = "clean",              args = { "clean" },                section = "TOOLS" },
  { label = "doc --open",         args = { "doc", "--open" },        section = "TOOLS" },
  { label = "publish --dry-run",  args = { "publish", "--dry-run" }, section = "TOOLS" },
  { label = "publish",            args = { "publish" },              section = "TOOLS" },
}

function M.render_rows(selected)
  local rows = {}
  local last_section = nil
  for i, cmd in ipairs(M.commands) do
    if cmd.section ~= last_section then
      if last_section then
        table.insert(rows, { text = "  ─────────────────────", hl = "CargoSeparator" })
      end
      table.insert(rows, { text = "  " .. cmd.section, hl = "CargoCategoryTitle" })
      last_section = cmd.section
    end
    local sel = i == selected
    table.insert(rows, {
      text    = (sel and " ▶  " or "    ") .. cmd.label,
      hl      = sel and "CargoSelected" or "CargoNormal",
      cmd_idx = i,
    })
  end
  return rows
end

return M
