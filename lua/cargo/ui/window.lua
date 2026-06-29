local M = {}
local runner  = require("cargo.runner")
local Spinner = require("cargo.ui.spinner")

local ns = vim.api.nvim_create_namespace("cargo_nvim")

local function setup_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "CargoCategoryTitle", { bold = true, link = "Label" })
  hl(0, "CargoSelected",      { bold = true, link = "PmenuSel" })
  hl(0, "CargoNormal",        { link = "Normal" })
  hl(0, "CargoSeparator",     { link = "Comment" })
  hl(0, "CargoMuted",         { link = "Comment" })
  hl(0, "CargoSuccess",       { fg = "#98c379", bold = true })
  hl(0, "CargoError",         { fg = "#e06c75", bold = true })
  hl(0, "CargoTabActive",     { bold = true, link = "TabLineSel" })
  hl(0, "CargoTabInactive",   { link = "TabLine" })
  hl(0, "CargoBorder",        { link = "FloatBorder" })
end

local TABS = {
  { id = "build",    label = "Build/Run" },
  { id = "test",     label = "Test" },
  { id = "packages", label = "Packages" },
  { id = "tools",    label = "Tools" },
}

-- 文字列を幅 w に右パディング（マルチバイト考慮なし）
local function pad(s, w)
  s = tostring(s or "")
  local len = vim.fn.strdisplaywidth(s)
  if len >= w then return s:sub(1, w) end
  return s .. string.rep(" ", w - len)
end

-- バッファへの書き込みヘルパー
local function buf_set(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.bo[buf].modifiable = false
end

local function buf_hl(buf, lnum, col_s, col_e, hl_group)
  vim.api.nvim_buf_add_highlight(buf, ns, hl_group, lnum, col_s, col_e)
end

-- ============================================================
-- State
-- ============================================================
local State = {}
State.__index = State

function State.new(root)
  local ws = require("cargo.workspace")
  return setmetatable({
    root          = root,
    pkg_name      = ws.get_package_name(root),
    active_tab    = 1,
    active_panel  = 1,
    selected      = { 1, 1, 1, 1 },
    output_lines  = {},
    last_args     = nil,
    test_results  = {},
    pkg_filter    = "",
    pkg_deps      = ws.get_dependencies(root),
    pkg_results   = {},
    pkg_loading   = false,
    pkg_sel_left  = 1,
    pkg_sel_right = 1,
    buf           = nil,
    win           = nil,
    spinner       = nil,
    left_w        = 0,
    right_w       = 0,
    panel_h       = 0,
  }, State)
end

-- ============================================================
-- タブモジュール取得
-- ============================================================
local function tab_mod(tab)
  return ({
    require("cargo.ui.tabs.build_run"),
    require("cargo.ui.tabs.test"),
    require("cargo.ui.tabs.packages"),
    require("cargo.ui.tabs.tools"),
  })[tab]
end

-- ============================================================
-- 左パネルの行リストを返す
-- { text, hl, is_cmd, cmd_index }
-- ============================================================
local function left_lines(state)
  local tab = state.active_tab
  local rows = {}
  local function add(text, hl, cmd_i)
    table.insert(rows, { text = text, hl = hl or "CargoNormal", cmd_i = cmd_i })
  end

  if tab == 3 then
    -- Packages: installed list
    add("  INSTALLED", "CargoCategoryTitle")
    local filtered = {}
    for i, dep in ipairs(state.pkg_deps) do
      local f = state.pkg_filter
      if f == "" or dep.name:lower():find(f:lower(), 1, true) then
        table.insert(filtered, { dep = dep, orig_i = i })
      end
    end
    for fi, entry in ipairs(filtered) do
      local sel = fi == state.pkg_sel_left
      local prefix = sel and " ▶ " or "   "
      add(string.format("%s%-18s %s", prefix, entry.dep.name, entry.dep.version or ""),
          sel and "CargoSelected" or "CargoNormal", entry.orig_i)
    end
    if #filtered == 0 then add("   (なし)", "CargoMuted") end
  else
    local mod = tab_mod(tab)
    if not mod then return rows end
    local cmds = mod.commands or {}

    -- カテゴリ付き描画
    if tab == 1 then
      add("  BUILD", "CargoCategoryTitle")
      for i = 1, 3 do
        local c = cmds[i]
        local sel = i == state.selected[tab]
        add((sel and " ▶ " or "   ") .. c.label,
            sel and "CargoSelected" or "CargoNormal", i)
      end
      add("  ─────────────────────", "CargoSeparator")
      add("  RUN", "CargoCategoryTitle")
      for i = 4, #cmds do
        local c = cmds[i]
        local sel = i == state.selected[tab]
        add((sel and " ▶ " or "   ") .. c.label,
            sel and "CargoSelected" or "CargoNormal", i)
      end
    else
      if tab == 2 then add("  COMMANDS", "CargoCategoryTitle") end
      if tab == 4 then add("  TOOLS", "CargoCategoryTitle") end
      for i, c in ipairs(cmds) do
        local sel = i == state.selected[tab]
        add((sel and " ▶ " or "   ") .. c.label,
            sel and "CargoSelected" or "CargoNormal", i)
      end
      -- test results
      if tab == 2 and #state.test_results > 0 then
        add("  ─────────────────────", "CargoSeparator")
        add("  RESULTS", "CargoCategoryTitle")
        for _, r in ipairs(state.test_results) do
          add("  " .. (r.ok and "✓" or "✗") .. " " .. r.name,
              r.ok and "CargoSuccess" or "CargoError")
        end
      end
    end
  end
  return rows
end

-- ============================================================
-- 右パネルの行リストを返す
-- ============================================================
local function right_lines(state)
  local rows = {}
  local function add(text, hl)
    table.insert(rows, { text = text, hl = hl or "CargoNormal" })
  end

  if state.active_tab == 3 then
    -- Packages: search results
    add("  SEARCH RESULTS", "CargoCategoryTitle")
    if state.pkg_loading then
      add("   検索中…", "CargoMuted")
    elseif #state.pkg_results == 0 then
      add("   (s キーで crates.io 検索)", "CargoMuted")
    else
      for i, r in ipairs(state.pkg_results) do
        local sel = i == state.pkg_sel_right
        local dl = require("cargo.crates").format_downloads(r.downloads)
        add(string.format("%s%-18s %-10s ↓%s",
            sel and " ▶ " or "   ", r.name, r.version, dl),
            sel and "CargoSelected" or "CargoNormal")
      end
      -- 選択中クレートの詳細
      local r = state.pkg_results[state.pkg_sel_right]
      if r and r.description and r.description ~= "" then
        add("  ─────────────────────", "CargoSeparator")
        local desc = r.description:gsub("\n", " ")
        add("  " .. desc, "CargoMuted")
      end
    end
  else
    -- Output
    local cfg = require("cargo.config").options
    if runner.is_running() then
      local spin = state.spinner and state.spinner:frame() or cfg.icons.running
      add("  " .. spin .. " 実行中…", "CargoMuted")
    end
    for _, line in ipairs(state.output_lines) do
      -- エラー行の着色
      local hl = "CargoNormal"
      if line:match("^error") then hl = "CargoError"
      elseif line:match("^warning") then hl = "DiagnosticWarn"
      elseif line:match("Finished") then hl = "CargoSuccess"
      end
      add(line, hl)
    end
  end
  return rows
end

-- ============================================================
-- バッファ全体を再描画
-- ============================================================
local function redraw(state)
  local buf = state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  local lw = state.left_w
  local rw = state.right_w
  local ph = state.panel_h

  -- タブバー行を組み立て
  local tab_parts = {}
  for i, t in ipairs(TABS) do
    table.insert(tab_parts, (i == state.active_tab and ("*" .. t.label .. "*") or t.label))
  end
  local tabbar = "  " .. table.concat(tab_parts, "  │  ") .. "  "
  local sep_h  = string.rep("─", lw) .. "┼" .. string.rep("─", rw)

  -- 各行を合成: left | right
  local lrows = left_lines(state)
  local rrows = right_lines(state)

  local lines = { tabbar, sep_h }
  local hls   = {}  -- { lnum, col_s, col_e, group }

  -- タブバーのハイライト
  local col = 2
  for i, t in ipairs(TABS) do
    local label = t.label
    local group = (i == state.active_tab) and "CargoTabActive" or "CargoTabInactive"
    table.insert(hls, { 0, col, col + #label, group })
    col = col + #label + 5  -- "  │  "
  end

  for row = 1, ph do
    local lr = lrows[row]
    local rr = rrows[row]
    local lt = lr and lr.text or ""
    local rt = rr and rr.text or ""
    local merged = pad(lt, lw) .. "│" .. rt

    table.insert(lines, merged)
    local lnum = row + 1  -- 0-indexed: tabbar=0, sep=1, content starts at 2

    -- 左パネルハイライト
    if lr and lr.hl and lr.hl ~= "CargoNormal" then
      table.insert(hls, { lnum, 0, lw, lr.hl })
    end
    -- 右パネルハイライト
    if rr and rr.hl and rr.hl ~= "CargoNormal" then
      table.insert(hls, { lnum, lw + 1, lw + 1 + #(rr.text or ""), rr.hl })
    end
  end

  -- ステータスバー
  local cfg = require("cargo.config").options
  local km = cfg.keymaps
  local status
  if state.active_tab == 3 then
    status = string.format(
      "  [%s] add  [%s] remove  [s] search  [Tab] panel  [%s] close",
      km.pkg_add, km.pkg_remove, km.close)
  else
    status = string.format(
      "  [%s] run  [%s] args  [%s] re-run  [%s] kill  [%s/%s] tab  [%s] close",
      km.run, km.args, km.rerun, km.kill, km.tab_prev, km.tab_next, km.close)
  end
  table.insert(lines, string.rep("─", lw + rw + 1))
  table.insert(lines, status)

  buf_set(buf, lines)

  for _, h in ipairs(hls) do
    buf_hl(buf, h[1], h[2], h[3], h[4])
  end
end

-- ============================================================
-- コマンド実行
-- ============================================================
local function run_command(state, args)
  state.output_lines = { "$ cargo " .. table.concat(args, " ") }
  state.last_args = args

  if state.spinner then state.spinner:stop() end
  state.spinner = Spinner.new({
    on_frame = function(_) redraw(state) end,
  })
  state.spinner:start()

  runner.run({
    args = args,
    cwd  = state.root,
    on_line = function(line)
      table.insert(state.output_lines, line)
      if state.active_tab == 2 then
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
      local icon = code == 0 and cfg.icons.success or cfg.icons.error
      table.insert(state.output_lines, "")
      table.insert(state.output_lines, string.format("  %s 終了コード: %d", icon, code))
      redraw(state)
    end,
  })
end

-- ============================================================
-- キーマップ設定
-- ============================================================
local function setup_keymaps(state)
  local cfg = require("cargo.config").options
  local km = cfg.keymaps
  local buf = state.buf
  local o = { noremap = true, silent = true, buffer = buf }

  local function map(key, fn) vim.keymap.set("n", key, fn, o) end

  local function close()
    if state.spinner then state.spinner:stop() end
    runner.kill()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_close(state.win, true)
    end
  end

  local function switch_tab(n)
    state.active_tab    = n
    state.output_lines  = {}
    state.test_results  = {}
    state.active_panel  = 1
    redraw(state)
  end

  local function do_run()
    if state.active_tab == 3 then return end
    local mod = tab_mod(state.active_tab)
    if not mod or not mod.commands then return end
    local cmd = mod.commands[state.selected[state.active_tab]]
    if not cmd then return end
    if cmd.prompt then
      vim.ui.input({ prompt = cmd.prompt .. ": " }, function(input)
        if input then
          run_command(state, vim.list_extend(vim.deepcopy(cmd.args), { input }))
        end
      end)
    else
      run_command(state, vim.deepcopy(cmd.args))
    end
  end

  local function move(delta)
    local tab = state.active_tab
    if tab == 3 then
      if state.active_panel == 1 then
        local n = math.max(1, #state.pkg_deps)
        state.pkg_sel_left = math.max(1, math.min(n, state.pkg_sel_left + delta))
      else
        local n = math.max(1, #state.pkg_results)
        state.pkg_sel_right = math.max(1, math.min(n, state.pkg_sel_right + delta))
      end
    else
      local mod = tab_mod(tab)
      local n = mod and #(mod.commands or {}) or 1
      state.selected[tab] = math.max(1, math.min(n, state.selected[tab] + delta))
    end
    redraw(state)
  end

  map(km.close,      close)
  map("<Esc>",       close)
  map("j",           function() move(1) end)
  map("k",           function() move(-1) end)
  map(km.run,        do_run)
  map(km.rerun,      function()
    if state.last_args then run_command(state, state.last_args) end
  end)
  map(km.kill,       function()
    runner.kill()
    if state.spinner then state.spinner:stop() end
    table.insert(state.output_lines, "  [中断]")
    redraw(state)
  end)
  map(km.args,       function()
    if state.active_tab == 3 then return end
    vim.ui.input({ prompt = "追加引数: " }, function(input)
      if input and input ~= "" then
        local base = state.last_args or (tab_mod(state.active_tab).commands[state.selected[state.active_tab]].args)
        run_command(state, vim.list_extend(vim.deepcopy(base), vim.split(input, " ")))
      end
    end)
  end)
  map(km.tab_next,   function() switch_tab(math.min(4, state.active_tab + 1)) end)
  map(km.tab_prev,   function() switch_tab(math.max(1, state.active_tab - 1)) end)
  map(km.tab_build,  function() switch_tab(1) end)
  map(km.tab_test,   function() switch_tab(2) end)
  map(km.tab_pkgs,   function() switch_tab(3) end)
  map(km.tab_tools,  function() switch_tab(4) end)
  map(km.panel_next, function()
    state.active_panel = state.active_panel == 1 and 2 or 1
    redraw(state)
  end)
  map(km.panel_prev, function()
    state.active_panel = state.active_panel == 1 and 2 or 1
    redraw(state)
  end)

  -- Packages: s=search, d=remove, Enter=add
  map("s", function()
    if state.active_tab ~= 3 then return end
    vim.ui.input({ prompt = "crates.io 検索: ", default = state.pkg_filter }, function(input)
      if input == nil then return end
      state.pkg_filter   = input
      state.pkg_loading  = true
      state.pkg_sel_right = 1
      redraw(state)
      require("cargo.crates").search(input, function(results)
        state.pkg_results = results
        state.pkg_loading = false
        redraw(state)
      end)
    end)
  end)
  map(km.pkg_remove, function()
    if state.active_tab ~= 3 or state.active_panel ~= 1 then return end
    local dep = state.pkg_deps[state.pkg_sel_left]
    if not dep then return end
    vim.ui.select({ "はい", "いいえ" }, { prompt = dep.name .. " を削除？" }, function(choice)
      if choice == "はい" then
        run_command(state, { "remove", dep.name })
        vim.defer_fn(function()
          state.pkg_deps     = require("cargo.workspace").get_dependencies(state.root)
          state.pkg_sel_left = math.max(1, math.min(#state.pkg_deps, state.pkg_sel_left))
          redraw(state)
        end, 600)
      end
    end)
  end)
  -- Packages タブで Enter = add（右パネルフォーカス時）
  map(km.pkg_add, function()
    if state.active_tab ~= 3 or state.active_panel ~= 2 then
      do_run()  -- 他タブでは通常実行
      return
    end
    local r = state.pkg_results[state.pkg_sel_right]
    if not r then return end
    run_command(state, { "add", r.name })
    vim.defer_fn(function()
      state.pkg_deps = require("cargo.workspace").get_dependencies(state.root)
      redraw(state)
    end, 600)
  end)
end

-- ============================================================
-- メインウィンドウを開く
-- ============================================================
function M.open(root)
  setup_highlights()

  local cfg  = require("cargo.config").options
  local state = State.new(root)

  local vim_w = vim.o.columns
  local vim_h = vim.o.lines
  local width  = math.floor(vim_w * cfg.window.width)
  local height = math.floor(vim_h * cfg.window.height)
  local row    = math.floor((vim_h - height) / 2)
  local col    = math.floor((vim_w - width) / 2)

  -- 内側サイズ（border 分を除く）
  local inner_w = width - 2
  local inner_h = height - 2
  -- panel_h = 全体高 - タブバー(1) - セパレータ(1) - ステータスセパレータ(1) - ステータス(1)
  local panel_h = inner_h - 4

  state.left_w  = math.floor(inner_w * 0.38)
  state.right_w = inner_w - state.left_w - 1  -- 1 は "│"
  state.panel_h = panel_h

  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = inner_w,
    height    = inner_h,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = cfg.window.border,
    title     = string.format(" ⚙ cargo.nvim — %s ", state.pkg_name),
    title_pos = "center",
  })
  state.win = win

  -- カーソル非表示
  vim.wo[win].cursorline = false
  vim.wo[win].number     = false
  vim.wo[win].wrap       = false

  setup_keymaps(state)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(win),
    once     = true,
    callback = function()
      if state.spinner then state.spinner:stop() end
      runner.kill()
    end,
  })

  redraw(state)
end

return M
