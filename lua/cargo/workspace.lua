local M = {}

local function search_up(start)
  if not start or start == "" then return nil end
  local path = start:gsub("[/\\]+$", "")
  for _ = 1, 40 do
    -- vim.uv.fs_stat はクロスプラットフォームで確実
    if vim.uv.fs_stat(path .. "/Cargo.toml") then
      return path
    end
    if vim.uv.fs_stat(path .. "\\Cargo.toml") then
      return path
    end
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent == path then break end
    path = parent
  end
  return nil
end

function M.find_root()
  -- 1. cwd を最優先（ターミナルで開いたプロジェクトルートが多い）
  local cwd = vim.fn.getcwd()
  if cwd and cwd ~= "" then
    local found = search_up(cwd)
    if found then return found end
  end

  -- 2. カレントバッファのパスから上方向に探索
  local buf = vim.fn.expand("%:p:h")
  if buf and buf ~= "" and buf ~= "." then
    local found = search_up(buf)
    if found then return found end
  end

  return nil
end

-- Cargo.toml から package 名を取得
function M.get_package_name(root)
  local toml_path = root .. "/Cargo.toml"
  local lines = vim.fn.readfile(toml_path)
  for _, line in ipairs(lines) do
    local name = line:match('^name%s*=%s*"([^"]+)"')
    if name then return name end
  end
  return vim.fn.fnamemodify(root, ":t")
end

-- Cargo.toml から dependencies を取得
function M.get_dependencies(root)
  local toml_path = root .. "/Cargo.toml"
  if vim.fn.filereadable(toml_path) == 0 then return {} end

  local lines = vim.fn.readfile(toml_path)
  local deps = {}
  local in_deps = false

  for _, line in ipairs(lines) do
    if line:match("^%[dependencies%]") or line:match("^%[dev%-dependencies%]") then
      in_deps = true
    elseif line:match("^%[") then
      in_deps = false
    elseif in_deps then
      -- name = "version" 形式
      local name, ver = line:match('^([%w_%-]+)%s*=%s*"([^"]+)"')
      if name then
        table.insert(deps, { name = name, version = ver })
      else
        -- name = { version = "..." } 形式
        name, ver = line:match('^([%w_%-]+)%s*=.*version%s*=%s*"([^"]+)"')
        if name then
          table.insert(deps, { name = name, version = ver })
        end
      end
    end
  end

  return deps
end

return M
