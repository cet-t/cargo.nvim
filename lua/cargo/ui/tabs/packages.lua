local M = {}

-- インストール済みリストの行
function M.installed_rows(deps, selected, filter)
  local rows = {}
  table.insert(rows, { text = "  Installed", hl = "CargoCategoryTitle" })
  local count = 0
  for i, dep in ipairs(deps) do
    local f = filter or ""
    if f == "" or dep.name:lower():find(f:lower(), 1, true) then
      count = count + 1
      local sel = count == selected
      table.insert(rows, {
        text     = string.format("%s%-20s %s",
                     sel and " ▶  " or "    ", dep.name, dep.version or ""),
        hl       = sel and "CargoSelected" or "CargoNormal",
        dep_idx  = i,
      })
    end
  end
  if count == 0 then
    table.insert(rows, { text = "    (なし)", hl = "CargoMuted" })
  end
  return rows
end

-- 検索セクションの行（検索バー + 結果）
function M.search_rows(state)
  local rows = {}
  local bar = string.format("  Search: %-24s", state.pkg_query or "")
  table.insert(rows, { text = bar, hl = "CargoNormal", is_search_bar = true })

  if state.pkg_loading then
    table.insert(rows, { text = "    検索中…", hl = "CargoMuted" })
    return rows
  end
  for i, r in ipairs(state.pkg_results or {}) do
    local sel = i == state.pkg_sel_search
    table.insert(rows, {
      text    = string.format("%s%-20s %s",
                  sel and " ▶  " or "    ", r.name, r.version),
      hl      = sel and "CargoSelected" or "CargoNormal",
      res_idx = i,
    })
  end
  if #(state.pkg_results or {}) == 0 and not state.pkg_loading then
    table.insert(rows, { text = "    (s キーで検索)", hl = "CargoMuted" })
  end
  return rows
end

-- 右列: クレート詳細（markdown 風）
function M.detail_rows(item)
  if not item then return {} end
  local rows = {}
  local function add(t, hl) table.insert(rows, { text = "  " .. t, hl = hl or "CargoNormal" }) end

  add("# " .. (item.name or ""), "CargoCategoryTitle")
  if item.version and item.version ~= "" then
    add("  v" .. item.version, "CargoMuted")
  end
  add("", nil)

  if item.description and item.description ~= "" then
    add("## description", "CargoSeparator")
    -- 折り返し（右列幅を仮定して ~35 文字）
    local desc = item.description:gsub("\n", " ")
    for chunk in desc:gmatch(".-%S.-%s*") do
      add(chunk:match("^%s*(.-)%s*$"), "CargoNormal")
    end
    add("", nil)
  end

  if item.authors and #item.authors > 0 then
    add("### author(s)", "CargoSeparator")
    for _, a in ipairs(item.authors) do
      add(a, "CargoNormal")
    end
    add("", nil)
  end

  if item.deps and #item.deps > 0 then
    add("## dependencies", "CargoSeparator")
    for _, d in ipairs(item.deps) do
      add(string.format("%-18s %s", d.name, d.req or ""), "CargoNormal")
    end
  end

  if item.repository and item.repository ~= "" then
    add("", nil)
    add(item.repository, "CargoMuted")
  end

  return rows
end

return M
