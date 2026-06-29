local M = {}

-- 現在実行中のジョブ
local current_job = nil

-- cargo コマンドを非同期実行
-- opts:
--   args     : string[] — cargo に渡す引数 (例: {"build", "--release"})
--   cwd      : string  — 作業ディレクトリ
--   on_line  : function(line: string) — 出力行ごとのコールバック
--   on_exit  : function(code: number) — 終了コールバック
function M.run(opts)
  if current_job then
    M.kill()
  end

  local cmd = vim.list_extend({ "cargo" }, opts.args or {})

  current_job = vim.system(cmd, {
    cwd   = opts.cwd,
    stdout = function(_, data)
      if not data then return end
      for _, line in ipairs(vim.split(data, "\n", { plain = true })) do
        if line ~= "" then
          vim.schedule(function()
            if opts.on_line then opts.on_line(line) end
          end)
        end
      end
    end,
    stderr = function(_, data)
      if not data then return end
      for _, line in ipairs(vim.split(data, "\n", { plain = true })) do
        if line ~= "" then
          vim.schedule(function()
            if opts.on_line then opts.on_line(line) end
          end)
        end
      end
    end,
  }, function(result)
    current_job = nil
    vim.schedule(function()
      if opts.on_exit then opts.on_exit(result.code) end
    end)
  end)
end

function M.kill()
  if current_job then
    current_job:kill(9)
    current_job = nil
  end
end

function M.is_running()
  return current_job ~= nil
end

return M
