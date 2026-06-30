local M = {}

-- 指定ディレクトリから上方向に Cargo.toml を探す
local function search_up(start)
  -- パスを正規化してトレイリングスラッシュを除去
  local path = vim.fn.fnamemodify(start, ":p"):gsub("[/\\]+$", "")
  for _ = 1, 30 do
    if vim.fn.filereadable(path .. "/Cargo.toml") == 1 then
      return path
    end
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent == path then break end  -- ルートに到達
    path = parent
  end
  return nil
end

-- カレントバッファ → cwd の順で Cargo.toml を探す
function M.find_root()
  local buf_dir = vim.fn.expand("%:p:h")
  if buf_dir ~= "" and buf_dir ~= "." then
    local found = search_up(buf_dir)
    if found then return found end
  end
  return search_up(vim.fn.getcwd())
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
