local M = {}

local debounce_timer = nil

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

  debounce_timer = vim.uv.new_timer()
  debounce_timer:start(cfg.search.debounce_ms, 0, vim.schedule_wrap(function()
    debounce_timer = nil
    local url = string.format(
      "https://crates.io/api/v1/crates?q=%s&per_page=%d",
      vim.uri_encode(query), cfg.search.max_results)
    vim.system({ "curl", "-s", "-A", "cargo.nvim", url }, {}, function(r)
      vim.schedule(function()
        if r.code ~= 0 then callback({}) return end
        local ok, data = pcall(vim.json.decode, r.stdout)
        if not ok or not data or not data.crates then callback({}) return end
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

-- クレートの詳細情報（作者・依存関係）を取得
function M.get_detail(name, version, callback)
  local base = "https://crates.io/api/v1/crates/" .. name
  local done = { meta = false, deps = false }
  local detail = { name = name, version = version, authors = {}, deps = {} }

  local function finish()
    if done.meta and done.deps then callback(detail) end
  end

  -- メタ情報（説明・作者）
  vim.system({ "curl", "-s", "-A", "cargo.nvim", base }, {}, function(r)
    vim.schedule(function()
      done.meta = true
      if r.code == 0 then
        local ok, data = pcall(vim.json.decode, r.stdout)
        if ok and data and data.crate then
          detail.description = data.crate.description or ""
          detail.repository  = data.crate.repository or ""
        end
        if ok and data and data.owners then
          for _, o in ipairs(data.owners) do
            table.insert(detail.authors, o.name or o.login or "")
          end
        end
      end
      finish()
    end)
  end)

  -- 依存関係
  local dep_url = base .. "/" .. (version or "0.0.0") .. "/dependencies"
  vim.system({ "curl", "-s", "-A", "cargo.nvim", dep_url }, {}, function(r)
    vim.schedule(function()
      done.deps = true
      if r.code == 0 then
        local ok, data = pcall(vim.json.decode, r.stdout)
        if ok and data and data.dependencies then
          for _, d in ipairs(data.dependencies) do
            if d.kind == "normal" or d.kind == nil then
              table.insert(detail.deps, { name = d.crate_id, req = d.req })
            end
          end
        end
      end
      finish()
    end)
  end)
end

function M.format_downloads(n)
  if n >= 1e9 then return string.format("%.1fB", n / 1e9)
  elseif n >= 1e6 then return string.format("%.1fM", n / 1e6)
  elseif n >= 1e3 then return string.format("%.1fK", n / 1e3)
  end
  return tostring(n)
end

return M
