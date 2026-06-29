if vim.g.loaded_cargo_nvim then return end
vim.g.loaded_cargo_nvim = true

vim.api.nvim_create_user_command("Cargo", function()
  require("cargo").open()
end, { desc = "cargo.nvim を開く" })
