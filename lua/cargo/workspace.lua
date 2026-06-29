local M = {}

-- カレントバッファから上方向に Cargo.toml を探す
function M.find_root()
  local path = vim.fn.expand("%:p:h")
  if path == "" then
    path = vim.fn.getcwd()
  end

  local prev = nil
  while path ~= prev do
    if vim.fn.filereadable(path .. "/Cargo.toml") == 1 then
      return path
    end
    prev = path
    path = vim.fn.fnamemodify(path, ":h")
  end

  -- バッファで見つからなければ cwd から探す
  path = vim.fn.getcwd()
  prev = nil
  while path ~= prev do
    if vim.fn.filereadable(path .. "/Cargo.toml") == 1 then
      return path
    end
    prev = path
    path = vim.fn.fnamemodify(path, ":h")
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
