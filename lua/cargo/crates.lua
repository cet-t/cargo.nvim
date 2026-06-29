local M = {}

local debounce_timer = nil

-- crates.io API で検索
-- callback(results: {name, version, description, downloads}[])
function M.search(query, callback)
  local cfg = require("cargo.config").options

  if debounce_timer then
    debounce_timer:stop()
    debounce_timer:close()
    debounce_timer = nil
  end

  if query == "" then
    callback({})
    return
  end

  debounce_timer = vim.loop.new_timer()
  debounce_timer:start(cfg.search.debounce_ms, 0, vim.schedule_wrap(function()
    debounce_timer = nil

    local url = string.format(
      "https://crates.io/api/v1/crates?q=%s&per_page=%d",
      vim.uri_encode(query),
      cfg.search.max_results
    )

    -- curl で非同期取得
    vim.system({ "curl", "-s", "-A", "cargo.nvim (neovim plugin)", url }, {}, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback({})
          return
        end

        local ok, data = pcall(vim.json.decode, result.stdout)
        if not ok or not data or not data.crates then
          callback({})
          return
        end

        local results = {}
        for _, c in ipairs(data.crates) do
          table.insert(results, {
            name        = c.name or "",
            version     = c.newest_version or "",
            description = c.description or "",
            downloads   = c.downloads or 0,
          })
        end
        callback(results)
      end)
    end)
  end))
end

-- ダウンロード数を人間が読みやすい形式に変換
function M.format_downloads(n)
  if n >= 1e9 then
    return string.format("%.1fB", n / 1e9)
  elseif n >= 1e6 then
    return string.format("%.1fM", n / 1e6)
  elseif n >= 1e3 then
    return string.format("%.1fK", n / 1e3)
  end
  return tostring(n)
end

return M
