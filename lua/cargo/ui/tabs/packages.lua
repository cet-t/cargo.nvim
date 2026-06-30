local M = {}

-- テキストを幅 width で折り返す（単語単位）
local function word_wrap(text, width)
  if not text or text == "" then return {} end
  local lines = {}
  local current = ""
  for word in text:gsub("\n", " "):gmatch("%S+") do
    local sep = current == "" and "" or " "
    if vim.fn.strdisplaywidth(current .. sep .. word) > width then
      if current ~= "" then table.insert(lines, current) end
      current = word
    else
      current = current .. sep .. word
    end
  end
  if current ~= "" then table.insert(lines, current) end
  return lines
end

-- インストール済みリスト行
function M.installed_rows(deps, selected)
  local rows = {}
  table.insert(rows, { text = "  Installed", hl = "CargoCategoryTitle" })
  if #deps == 0 then
    table.insert(rows, { text = "    (なし)", hl = "CargoMuted" })
    return rows
  end
  for i, dep in ipairs(deps) do
    local sel = i == selected
    table.insert(rows, {
      text = string.format("%s%-20s %s",
        sel and " ▶  " or "    ", dep.name, dep.version or ""),
      hl = sel and "CargoSelected" or "CargoNormal",
    })
  end
  return rows
end

-- 検索セクション行（検索バー + 結果一覧）
function M.search_rows(query, results, loading, search_mode, lw)
  local rows = {}
  -- 検索バー: "  Search: [query]▌"
  local q      = query or ""
  local cursor = search_mode and "▌" or ""
  table.insert(rows, {
    text = "  Search: " .. q .. cursor,
    hl   = search_mode and "CargoSelected" or "CargoNormal",
    is_search_bar = true,
  })
  if loading then
    table.insert(rows, { text = "    検索中…", hl = "CargoMuted" })
    return rows
  end
  if #results == 0 then
    table.insert(rows, { text = "    (s で検索)", hl = "CargoMuted" })
    return rows
  end
  for i, r in ipairs(results) do
    local sel = i == selected
    table.insert(rows, {
      text = string.format("%s%-20s %s",
        sel and " ▶  " or "    ", r.name, r.version),
      hl = sel and "CargoSelected" or "CargoNormal",
    })
  end
  return rows
end

-- 右列: クレート詳細（markdown 風、右パネル幅でラップ）
function M.detail_rows(item, rw)
  if not item then return {} end
  local indent = "  "
  local text_w = math.max(10, rw - 2)
  local rows = {}
  local function add(t, hl)
    table.insert(rows, { text = indent .. t, hl = hl or "CargoNormal" })
  end
  local function blank()
    table.insert(rows, { text = "", hl = "CargoNormal" })
  end

  add("# " .. (item.name or ""),          "CargoCategoryTitle")
  add("v" .. (item.version or ""),        "CargoMuted")
  blank()

  if item.description and item.description ~= "" then
    add("## description",                  "CargoSeparator")
    for _, wl in ipairs(word_wrap(item.description, text_w)) do
      add(wl)
    end
    blank()
  end

  if item.authors and #item.authors > 0 then
    add("### author(s)",                   "CargoSeparator")
    for _, a in ipairs(item.authors) do
      add(a)
    end
    blank()
  end

  if item.deps and #item.deps > 0 then
    add("## dependencies",                 "CargoSeparator")
    for _, d in ipairs(item.deps) do
      add(string.format("%-18s %s", d.name, d.req or ""))
    end
  end

  return rows
end

return M
