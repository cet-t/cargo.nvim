local M = {}

M.defaults = {
  spinner = {
    frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    interval = 80,
  },

  icons = {
    success = "✓",
    error   = "✗",
    running = "…",
    crate   = "󰏗 ",
  },

  keymaps = {
    run        = "<CR>",
    args       = "a",
    rerun      = "r",
    kill       = "<C-c>",
    panel_next = "<Tab>",
    panel_prev = "<S-Tab>",
    tab_next   = "]",
    tab_prev   = "[",
    tab_build  = "1",
    tab_pkgs   = "2",
    tab_test   = "3",
    tab_tools  = "4",
    pkg_add    = "<CR>",
    pkg_remove = "d",
    pkg_feats  = "f",
    close      = "q",
  },

  window = {
    width  = 0.85,
    height = 0.80,
    border = "rounded",
  },

  search = {
    debounce_ms = 300,
    max_results = 20,
  },
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
