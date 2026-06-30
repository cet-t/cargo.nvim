local M = {}

function M.setup(opts)
  require("cargo.config").setup(opts)
end

function M.open()
  local ws = require("cargo.workspace")
  local root = ws.find_root()
  if not root then
    vim.notify(string.format(
      "[cargo.nvim] Cargo.toml が見つかりません (cwd: %s)", vim.fn.getcwd()),
      vim.log.levels.ERROR)
    return
  end
  require("cargo.ui.window").open(root)
end

return M
