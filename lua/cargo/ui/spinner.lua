local M = {}

local Spinner = {}
Spinner.__index = Spinner

function Spinner.new(opts)
  local cfg = require("cargo.config").options
  return setmetatable({
    frames   = (opts and opts.frames) or cfg.spinner.frames,
    interval = (opts and opts.interval) or cfg.spinner.interval,
    index    = 1,
    timer    = nil,
    on_frame = opts and opts.on_frame,
  }, Spinner)
end

function Spinner:start()
  if self.timer then return end
  self.timer = vim.loop.new_timer()
  self.timer:start(0, self.interval, vim.schedule_wrap(function()
    self.index = (self.index % #self.frames) + 1
    if self.on_frame then
      self.on_frame(self.frames[self.index])
    end
  end))
end

function Spinner:stop()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

function Spinner:frame()
  return self.frames[self.index]
end

M.new = Spinner.new

return M
