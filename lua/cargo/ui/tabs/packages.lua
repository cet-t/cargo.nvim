local M = {}

-- state はウィンドウごとに管理するため外部から渡す
function M.render_installed(deps, selected, filter)
  local lines = {}
  local hl_map = {}
  local index_map = {}  -- 行番号 → deps インデックス

  local function add(line, hl, dep_i)
    table.insert(lines, line)
    if hl then hl_map[#lines] = hl end
    if dep_i then index_map[#lines] = dep_i end
  end

  add("  INSTALLED", "CargoCategoryTitle")

  local filtered = {}
  for i, dep in ipairs(deps) do
    if filter == "" or dep.name:lower():find(filter:lower(), 1, true) then
      table.insert(filtered, { dep = dep, orig_i = i })
    end
  end

  for fi, entry in ipairs(filtered) do
    local prefix = (fi == selected) and " ▶ " or "   "
    local hl = (fi == selected) and "CargoSelected" or "CargoNormal"
    local ver = entry.dep.version or ""
    add(string.format("%s%-20s %s", prefix, entry.dep.name, ver), hl, entry.orig_i)
  end

  if #filtered == 0 then
    add("   (なし)", "CargoMuted")
  end

  return lines, hl_map, index_map
end

function M.render_search(results, selected, loading)
  local lines = {}
  local hl_map = {}

  local function add(line, hl)
    table.insert(lines, line)
    if hl then hl_map[#lines] = hl end
  end

  add("  SEARCH RESULTS", "CargoCategoryTitle")

  if loading then
    add("   検索中…", "CargoMuted")
    return lines, hl_map
  end

  if #results == 0 then
    add("   (結果なし)", "CargoMuted")
    return lines, hl_map
  end

  for i, r in ipairs(results) do
    local prefix = (i == selected) and " ▶ " or "   "
    local hl = (i == selected) and "CargoSelected" or "CargoNormal"
    local downloads = require("cargo.crates").format_downloads(r.downloads)
    add(string.format("%s%-20s %-10s ↓%s", prefix, r.name, r.version, downloads), hl)
  end

  return lines, hl_map
end

-- 選択中クレートの詳細行
function M.render_detail(item)
  if not item then return {} end
  local lines = {
    string.format("  %s v%s", item.name, item.version),
  }
  if item.description and item.description ~= "" then
    -- 長い説明は折り返す
    local desc = item.description:gsub("\n", " ")
    if #desc > 72 then desc = desc:sub(1, 69) .. "…" end
    table.insert(lines, "  " .. desc)
  end
  if item.downloads then
    local dl = require("cargo.crates").format_downloads(item.downloads)
    table.insert(lines, "  ↓ " .. dl .. " downloads")
  end
  return lines
end

return M
