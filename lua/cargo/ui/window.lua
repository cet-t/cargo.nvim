local M = {}
local runner  = require("cargo.runner")
local Spinner = require("cargo.ui.spinner")
local ns      = vim.api.nvim_create_namespace("cargo_nvim")

-- ──────────────────────────────────────────────────────────────
-- ハイライト
-- ──────────────────────────────────────────────────────────────
local function setup_hl()
  local h = vim.api.nvim_set_hl
  h(0, "CargoCategoryTitle", { bold = true, link = "Label" })
  h(0, "CargoSelected",      { bold = true, link = "PmenuSel" })
  h(0, "CargoNormal",        { link = "Normal" })
  h(0, "CargoSeparator",     { link = "Comment" })
  h(0, "CargoMuted",         { link = "Comment" })
  h(0, "CargoSuccess",       { fg = "#98c379", bold = true })
  h(0, "CargoError",         { fg = "#e06c75", bold = true })
  h(0, "CargoTabActive",     { bold = true, link = "TabLineSel" })
  h(0, "CargoTabInactive",   { link = "TabLine" })
end

-- ──────────────────────────────────────────────────────────────
-- タブ定義（3つ）
-- ──────────────────────────────────────────────────────────────
local TABS = {
  { label = "Build / Run", key = "1" },
  { label = "Package",     key = "2" },
  { label = "Test",        key = "3" },
}

-- ──────────────────────────────────────────────────────────────
-- ユーティリティ
-- ──────────────────────────────────────────────────────────────
local function pad(s, w)
  s = tostring(s or "")
  local len = vim.fn.strdisplaywidth(s)
  if len >= w then
    -- 表示幅 w に切り詰め
    local result = ""
    local cur = 0
    for _, cp in utf8.codes(s) do
      local cw = vim.fn.strdisplaywidth(utf8.char(cp))
      if cur + cw > w then break end
      result = result .. utf8.char(cp)
      cur = cur + cw
    end
    return result .. string.rep(" ", w - cur)
  end
  return s .. string.rep(" ", w - len)
end

local function hline(lw, rw)
  return string.rep("─", lw) .. "┼" .. string.rep("─", rw)
end

local function merge_row(ltext, rtext, lw)
  return pad(ltext, lw) .. "│" .. (rtext or "")
end

-- ──────────────────────────────────────────────────────────────
-- State
-- ──────────────────────────────────────────────────────────────
local State = {}
State.__index = State

function State.new(root)
  local ws = require("cargo.workspace")
  return setmetatable({
    root           = root,
    pkg_name       = ws.get_package_name(root),
    -- タブ
    active_tab     = 1,
    sel            = { 1, 1, 1 },   -- タブごとの選択行
    -- 出力
    output         = {},
    last_args      = nil,
    test_results   = {},
    -- Package タブ
    pkg_section    = 1,             -- 1=installed, 2=search
    pkg_sel_inst   = 1,
    pkg_sel_search = 1,
    pkg_deps       = ws.get_dependencies(root),
    pkg_query      = "",
    pkg_results    = {},
    pkg_loading    = false,
    pkg_detail_inst  = nil,         -- 選択中インストール済みの詳細
    pkg_detail_srch  = nil,         -- 選択中検索結果の詳細
    -- UI
    buf            = nil,
    win            = nil,
    spinner        = nil,
    lw             = 0,
    rw             = 0,
    total_h        = 0,
    inst_h         = 0,
    srch_h         = 0,
  }, State)
end

-- ──────────────────────────────────────────────────────────────
-- バッファ書き込み
-- ──────────────────────────────────────────────────────────────
local function buf_write(buf, lines, hls)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.bo[buf].modifiable = false
  for _, h in ipairs(hls or {}) do
    -- h = { lnum, col_s, col_e, group }
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, h[4], h[1], h[2], h[3])
  end
end

-- ──────────────────────────────────────────────────────────────
-- タブバー行を生成
-- ──────────────────────────────────────────────────────────────
local function tabbar_line(active)
  local parts = {}
  for i, t in ipairs(TABS) do
    local label = string.format(" %s [%s] ", t.label, t.key)
    table.insert(parts, i == active and ("*" .. label .. "*") or label)
  end
  return table.concat(parts, "│")
end

local function tabbar_hls(line_str, active)
  local hls = {}
  local col = 0
  for i, t in ipairs(TABS) do
    local label = string.format(" %s [%s] ", t.label, t.key)
    local w = #label
    table.insert(hls, { 0, col, col + w, i == active and "CargoTabActive" or "CargoTabInactive" })
    col = col + w + 1  -- +1 for │
  end
  return hls
end

-- ──────────────────────────────────────────────────────────────
-- Package タブ詳細を非同期取得
-- ──────────────────────────────────────────────────────────────
local function fetch_detail(state, item, is_search, redraw_fn)
  if not item then return end
  require("cargo.crates").get_detail(item.name, item.version, function(detail)
    if is_search then
      state.pkg_detail_srch = detail
    else
      state.pkg_detail_inst = detail
    end
    redraw_fn(state)
  end)
end

-- ──────────────────────────────────────────────────────────────
-- 各タブの左列行リスト
-- ──────────────────────────────────────────────────────────────
local function build_run_left(state)
  return require("cargo.ui.tabs.build_run").render_rows(state.sel[1])
end

local function test_left(state)
  return require("cargo.ui.tabs.test").render_rows(state.sel[3], state.test_results)
end

-- ──────────────────────────────────────────────────────────────
-- 右列: 出力パネル
-- ──────────────────────────────────────────────────────────────
local function output_rows(state)
  local rows = {}
  local cfg = require("cargo.config").options
  if runner.is_running() then
    local f = state.spinner and state.spinner:frame() or cfg.icons.running
    table.insert(rows, { text = "  " .. f .. " 実行中…", hl = "CargoMuted" })
  end
  for _, line in ipairs(state.output) do
    local hl = "CargoNormal"
    if line:match("^error") then hl = "CargoError"
    elseif line:match("^warning") then hl = "DiagnosticWarn"
    elseif line:match("Finished") or line:match("✓") then hl = "CargoSuccess"
    end
    table.insert(rows, { text = line, hl = hl })
  end
  return rows
end

-- ──────────────────────────────────────────────────────────────
-- 行リストを total_h 行に切り詰め/パディング
-- ──────────────────────────────────────────────────────────────
local function clamp_rows(rows, h)
  local out = {}
  for i = 1, h do
    out[i] = rows[i] or { text = "", hl = "CargoNormal" }
  end
  return out
end

-- ──────────────────────────────────────────────────────────────
-- redraw
-- ──────────────────────────────────────────────────────────────
local function redraw(state)
  local buf = state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  local lw = state.lw
  local rw = state.rw
  local lines = {}
  local hls   = {}

  local function push(line, lnum_hl, col_s, col_e, hl_group)
    table.insert(lines, line)
    if hl_group then
      table.insert(hls, { #lines - 1, col_s or 0, col_e or -1, hl_group })
    end
    if lnum_hl then
      for _, h in ipairs(lnum_hl) do
        table.insert(hls, { #lines - 1, h[1], h[2], h[3] })
      end
    end
  end

  -- タブバー
  local tb = tabbar_line(state.active_tab)
  push(tb, tabbar_hls(tb, state.active_tab))
  push(hline(lw, rw))

  -- ── Package タブ ──────────────────────────────────────────
  if state.active_tab == 2 then
    local pkg = require("cargo.ui.tabs.packages")

    -- 上段: インストール済み
    local inst_rows = clamp_rows(
      pkg.installed_rows(state.pkg_deps, state.pkg_sel_inst, ""),
      state.inst_h)
    local det_inst  = clamp_rows(
      pkg.detail_rows(state.pkg_detail_inst),
      state.inst_h)

    for i = 1, state.inst_h do
      local lr = inst_rows[i]
      local rr = det_inst[i]
      local line = merge_row(lr.text, rr.text, lw)
      local row_hls = {}
      if lr.hl ~= "CargoNormal" then table.insert(row_hls, { 0, lw, lr.hl }) end
      if rr.hl and rr.hl ~= "CargoNormal" then
        table.insert(row_hls, { lw + 1, lw + 1 + #(rr.text or ""), rr.hl })
      end
      push(line, row_hls)
    end

    -- 中段セパレータ
    push(hline(lw, rw))

    -- 下段: 検索
    local srch_rows = clamp_rows(
      pkg.search_rows(state),
      state.srch_h)
    local det_srch  = clamp_rows(
      pkg.detail_rows(state.pkg_detail_srch),
      state.srch_h)

    for i = 1, state.srch_h do
      local lr = srch_rows[i]
      local rr = det_srch[i]
      local line = merge_row(lr.text, rr.text, lw)
      local row_hls = {}
      -- 検索セクションにフォーカスがある行は左列を強調
      if state.pkg_section == 2 and lr.hl ~= "CargoNormal" then
        table.insert(row_hls, { 0, lw, lr.hl })
      elseif state.pkg_section == 1 and lr.hl ~= "CargoNormal" then
        table.insert(row_hls, { 0, lw, "CargoMuted" })
      end
      if rr.hl and rr.hl ~= "CargoNormal" then
        table.insert(row_hls, { lw + 1, lw + 1 + #(rr.text or ""), rr.hl })
      end
      push(line, row_hls)
    end

  -- ── Build/Run タブ ────────────────────────────────────────
  elseif state.active_tab == 1 then
    local lrows = clamp_rows(build_run_left(state), state.total_h)
    local rrows = clamp_rows(output_rows(state),    state.total_h)
    for i = 1, state.total_h do
      local lr = lrows[i]
      local rr = rrows[i]
      local line = merge_row(lr.text, rr.text, lw)
      local row_hls = {}
      if lr.hl ~= "CargoNormal" then table.insert(row_hls, { 0, lw, lr.hl }) end
      if rr.hl and rr.hl ~= "CargoNormal" then
        table.insert(row_hls, { lw + 1, lw + 1 + #(rr.text or ""), rr.hl })
      end
      push(line, row_hls)
    end

  -- ── Test タブ ─────────────────────────────────────────────
  else
    local lrows = clamp_rows(test_left(state),   state.total_h)
    local rrows = clamp_rows(output_rows(state), state.total_h)
    for i = 1, state.total_h do
      local lr = lrows[i]
      local rr = rrows[i]
      local line = merge_row(lr.text, rr.text, lw)
      local row_hls = {}
      if lr.hl ~= "CargoNormal" then table.insert(row_hls, { 0, lw, lr.hl }) end
      if rr.hl and rr.hl ~= "CargoNormal" then
        table.insert(row_hls, { lw + 1, lw + 1 + #(rr.text or ""), rr.hl })
      end
      push(line, row_hls)
    end
  end

  -- ステータスバー
  push(hline(lw, rw))
  local cfg = require("cargo.config").options
  local km  = cfg.keymaps
  local status
  if state.active_tab == 2 then
    status = string.format("  Search [s]  Add [%s]  Remove [%s]  Nav [jk]  Tab [%s/%s]  Quit [%s]",
      km.pkg_add, km.pkg_remove, km.tab_prev, km.tab_next, km.close)
  else
    status = string.format("  Run [%s]  Args [%s]  Re-run [%s]  Kill [%s]  Tab [%s/%s]  Quit [%s]",
      km.run, km.args, km.rerun, km.kill, km.tab_prev, km.tab_next, km.close)
  end
  push(status)

  buf_write(buf, lines, hls)
end

-- ──────────────────────────────────────────────────────────────
-- cargo 実行
-- ──────────────────────────────────────────────────────────────
local function run_cmd(state, args)
  state.output    = { "$ cargo " .. table.concat(args, " ") }
  state.last_args = args
  if state.spinner then state.spinner:stop() end
  state.spinner = Spinner.new({ on_frame = function() redraw(state) end })
  state.spinner:start()

  runner.run({
    args    = args,
    cwd     = state.root,
    on_line = function(line)
      table.insert(state.output, line)
      if state.active_tab == 3 then
        local ok_n   = line:match("^test (.+) %.%.%. ok$")
        local fail_n = line:match("^test (.+) %.%.%. FAILED$")
        if ok_n   then table.insert(state.test_results, { name = ok_n,   ok = true })  end
        if fail_n then table.insert(state.test_results, { name = fail_n, ok = false }) end
      end
      redraw(state)
    end,
    on_exit = function(code)
      if state.spinner then state.spinner:stop() end
      local cfg = require("cargo.config").options
      table.insert(state.output, "")
      table.insert(state.output,
        string.format("  %s 終了コード: %d",
          code == 0 and cfg.icons.success or cfg.icons.error, code))
      redraw(state)
    end,
  })
end

-- ──────────────────────────────────────────────────────────────
-- キーマップ
-- ──────────────────────────────────────────────────────────────
local function setup_keys(state)
  local cfg = require("cargo.config").options
  local km  = cfg.keymaps
  local buf = state.buf
  local o   = { noremap = true, silent = true, buffer = buf }
  local function map(key, fn) vim.keymap.set("n", key, fn, o) end

  local function close()
    if state.spinner then state.spinner:stop() end
    runner.kill()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_close(state.win, true)
    end
  end

  local function switch_tab(n)
    state.active_tab   = n
    state.output       = {}
    state.test_results = {}
    redraw(state)
  end

  -- 現在のタブ・セクションのコマンドを実行
  local function do_run()
    if state.active_tab == 2 then
      -- Package タブ: 検索セクションで Enter = add
      if state.pkg_section == 2 then
        local r = state.pkg_results[state.pkg_sel_search]
        if r then
          run_cmd(state, { "add", r.name })
          vim.defer_fn(function()
            state.pkg_deps = require("cargo.workspace").get_dependencies(state.root)
            redraw(state)
          end, 800)
        end
      end
      return
    end
    local mods = {
      require("cargo.ui.tabs.build_run"),
      nil,
      require("cargo.ui.tabs.test"),
    }
    local mod = mods[state.active_tab]
    if not mod then return end
    local cmd = mod.commands[state.sel[state.active_tab]]
    if not cmd then return end
    if cmd.prompt then
      vim.ui.input({ prompt = cmd.prompt .. ": " }, function(input)
        if input then
          run_cmd(state, vim.list_extend(vim.deepcopy(cmd.args), { input }))
        end
      end)
    else
      run_cmd(state, vim.deepcopy(cmd.args))
    end
  end

  -- j/k 移動
  local function move(d)
    if state.active_tab == 2 then
      if state.pkg_section == 1 then
        local n = math.max(1, #state.pkg_deps)
        local prev = state.pkg_sel_inst
        state.pkg_sel_inst = math.max(1, math.min(n, state.pkg_sel_inst + d))
        if state.pkg_sel_inst ~= prev then
          state.pkg_detail_inst = nil
          redraw(state)
          local dep = state.pkg_deps[state.pkg_sel_inst]
          if dep then fetch_detail(state, dep, false, redraw) end
        end
      else
        local n = math.max(1, #state.pkg_results)
        local prev = state.pkg_sel_search
        state.pkg_sel_search = math.max(1, math.min(n, state.pkg_sel_search + d))
        if state.pkg_sel_search ~= prev then
          state.pkg_detail_srch = nil
          redraw(state)
          local r = state.pkg_results[state.pkg_sel_search]
          if r then fetch_detail(state, r, true, redraw) end
        end
      end
      return
    end
    local mods = {
      require("cargo.ui.tabs.build_run"),
      nil,
      require("cargo.ui.tabs.test"),
    }
    local mod = mods[state.active_tab]
    if not mod then return end
    local n = #(mod.commands or {})
    state.sel[state.active_tab] = math.max(1, math.min(n, state.sel[state.active_tab] + d))
    redraw(state)
  end

  map(km.close,      close)
  map("<Esc>",       close)
  map("j",           function() move(1) end)
  map("k",           function() move(-1) end)
  map(km.run,        do_run)
  map(km.pkg_add,    do_run)
  map(km.rerun,      function()
    if state.last_args then run_cmd(state, state.last_args) end
  end)
  map(km.kill,       function()
    runner.kill()
    if state.spinner then state.spinner:stop() end
    table.insert(state.output, "  [中断]")
    redraw(state)
  end)
  map(km.args,       function()
    if state.active_tab == 2 then return end
    vim.ui.input({ prompt = "追加引数: " }, function(input)
      if input and input ~= "" and state.last_args then
        run_cmd(state, vim.list_extend(vim.deepcopy(state.last_args), vim.split(input, " ")))
      end
    end)
  end)
  map(km.tab_next,   function() switch_tab(math.min(#TABS, state.active_tab + 1)) end)
  map(km.tab_prev,   function() switch_tab(math.max(1,     state.active_tab - 1)) end)
  map(km.tab_build,  function() switch_tab(1) end)
  map(km.tab_pkgs,   function() switch_tab(2) end)
  map(km.tab_test,   function() switch_tab(3) end)

  -- Package: Tab でセクション切り替え
  map(km.panel_next, function()
    if state.active_tab ~= 2 then return end
    state.pkg_section = state.pkg_section == 1 and 2 or 1
    redraw(state)
  end)
  map(km.panel_prev, function()
    if state.active_tab ~= 2 then return end
    state.pkg_section = state.pkg_section == 1 and 2 or 1
    redraw(state)
  end)

  -- Package: s = 検索
  map("s", function()
    if state.active_tab ~= 2 then return end
    vim.ui.input({ prompt = "crates.io: ", default = state.pkg_query }, function(input)
      if input == nil then return end
      state.pkg_query      = input
      state.pkg_loading    = true
      state.pkg_section    = 2
      state.pkg_sel_search = 1
      state.pkg_detail_srch = nil
      redraw(state)
      require("cargo.crates").search(input, function(results)
        state.pkg_results = results
        state.pkg_loading = false
        redraw(state)
        if results[1] then fetch_detail(state, results[1], true, redraw) end
      end)
    end)
  end)

  -- Package: d = remove
  map(km.pkg_remove, function()
    if state.active_tab ~= 2 or state.pkg_section ~= 1 then return end
    local dep = state.pkg_deps[state.pkg_sel_inst]
    if not dep then return end
    vim.ui.select({ "はい", "いいえ" }, { prompt = dep.name .. " を削除？" }, function(choice)
      if choice == "はい" then
        run_cmd(state, { "remove", dep.name })
        vim.defer_fn(function()
          state.pkg_deps    = require("cargo.workspace").get_dependencies(state.root)
          state.pkg_sel_inst = math.max(1, math.min(#state.pkg_deps, state.pkg_sel_inst))
          redraw(state)
        end, 800)
      end
    end)
  end)
end

-- ──────────────────────────────────────────────────────────────
-- open
-- ──────────────────────────────────────────────────────────────
function M.open(root)
  setup_hl()

  local cfg   = require("cargo.config").options
  local state = State.new(root)

  local vw = vim.o.columns
  local vh = vim.o.lines
  local W  = math.floor(vw * cfg.window.width)
  local H  = math.floor(vh * cfg.window.height)

  -- 内側サイズ (border 除く)
  local iw = W - 2
  local ih = H - 2

  state.lw      = math.floor(iw * 0.40)
  state.rw      = iw - state.lw - 1
  -- total_h: タブバー(1) + sep(1) + content + sep(1) + status(1) = 4 fixed
  state.total_h = ih - 4
  -- Package タブ: content を上段 40% + mid_sep(1) + 下段 に分割
  state.inst_h  = math.floor((state.total_h - 1) * 0.40)
  state.srch_h  = state.total_h - state.inst_h - 1

  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = iw,
    height    = ih,
    row       = math.floor((vh - H) / 2),
    col       = math.floor((vw - W) / 2),
    style     = "minimal",
    border    = cfg.window.border,
    title     = string.format("  cargo.nvim — %s ", state.pkg_name),
    title_pos = "center",
  })
  state.win = win
  vim.wo[win].wrap       = false
  vim.wo[win].number     = false
  vim.wo[win].cursorline = false

  setup_keys(state)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true,
    callback = function()
      if state.spinner then state.spinner:stop() end
      runner.kill()
    end,
  })

  -- 初期詳細を取得（インストール済み先頭）
  if state.pkg_deps[1] then
    fetch_detail(state, state.pkg_deps[1], false, redraw)
  end

  redraw(state)
end

return M
