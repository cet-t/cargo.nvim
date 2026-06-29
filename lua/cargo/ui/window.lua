local M = {}
local runner  = require("cargo.runner")
local Spinner = require("cargo.ui.spinner")

-- ハイライトグループを定義
local function setup_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "CargoTitle",         { bold = true, link = "Title" })
  hl(0, "CargoCategoryTitle", { bold = true, link = "Label" })
  hl(0, "CargoSelected",      { bold = true, link = "PmenuSel" })
  hl(0, "CargoNormal",        { link = "Normal" })
  hl(0, "CargoSeparator",     { link = "Comment" })
  hl(0, "CargoMuted",         { link = "Comment" })
  hl(0, "CargoSuccess",       { fg = "#98c379", bold = true })
  hl(0, "CargoError",         { fg = "#e06c75", bold = true })
  hl(0, "CargoRunning",       { fg = "#e5c07b" })
  hl(0, "CargoTabActive",     { bold = true, link = "TabLineSel" })
  hl(0, "CargoTabInactive",   { link = "TabLine" })
end

-- バッファに行を書き込み、ハイライトを適用
local function set_lines(buf, lines, hl_map, offset)
  offset = offset or 0
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, offset, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  if hl_map then
    local ns = vim.api.nvim_create_namespace("cargo_nvim")
    vim.api.nvim_buf_clear_namespace(buf, ns, offset, -1)
    for lnum, hl in pairs(hl_map) do
      vim.api.nvim_buf_add_highlight(buf, ns, hl, offset + lnum - 1, 0, -1)
    end
  end
end

-- タブバーの文字列を組み立てる
local TABS = {
  { id = "build",    label = " Build/Run " },
  { id = "test",     label = " Test " },
  { id = "packages", label = " Packages " },
  { id = "tools",    label = " Tools " },
}

local function render_tabbar(active_tab)
  local parts = {}
  for i, t in ipairs(TABS) do
    if i == active_tab then
      table.insert(parts, "%#CargoTabActive#" .. t.label .. "%#CargoTabInactive#")
    else
      table.insert(parts, t.label)
    end
  end
  return table.concat(parts, "│")
end

-- ウィンドウ状態
local State = {}
State.__index = State

function State.new(root)
  local ws = require("cargo.workspace")
  return setmetatable({
    root         = root,
    pkg_name     = ws.get_package_name(root),
    active_tab   = 1,   -- 1=build, 2=test, 3=packages, 4=tools
    active_panel = 1,   -- 左=1, 右=2
    selected     = { 1, 1, 1, 1 },  -- タブごとの選択行
    output_lines = {},
    last_args    = nil,
    test_results = {},
    -- packages タブ
    pkg_filter   = "",
    pkg_deps     = ws.get_dependencies(root),
    pkg_results  = {},
    pkg_loading  = false,
    pkg_sel_left = 1,
    pkg_sel_right= 1,
    -- ウィンドウ/バッファ
    main_win     = nil,
    left_buf     = nil,
    right_buf    = nil,
    status_buf   = nil,
    input_buf    = nil,
    spinner      = nil,
  }, State)
end

-- コマンド取得
local function get_tab_module(tab)
  local mods = {
    require("cargo.ui.tabs.build_run"),
    require("cargo.ui.tabs.test"),
    require("cargo.ui.tabs.packages"),
    require("cargo.ui.tabs.tools"),
  }
  return mods[tab]
end

-- 左パネルを再描画
local function redraw_left(state)
  if not state.left_buf or not vim.api.nvim_buf_is_valid(state.left_buf) then return end
  local tab = state.active_tab
  local lines, hl_map

  if tab == 3 then  -- Packages
    local pkg = require("cargo.ui.tabs.packages")
    lines, hl_map = pkg.render_installed(
      state.pkg_deps, state.pkg_sel_left, state.pkg_filter)
  else
    local mod = get_tab_module(tab)
    local sel = state.selected[tab]
    if tab == 1 then
      lines, hl_map = mod.render_lines(sel)
    elseif tab == 2 then
      lines, hl_map = mod.render_lines(sel, state.test_results)
    else
      lines, hl_map = mod.render_lines(sel)
    end
  end

  set_lines(state.left_buf, lines, hl_map, 0)
end

-- 右パネルを再描画
local function redraw_right(state)
  if not state.right_buf or not vim.api.nvim_buf_is_valid(state.right_buf) then return end

  if state.active_tab == 3 then
    local pkg = require("cargo.ui.tabs.packages")
    local lines, hl_map = pkg.render_search(
      state.pkg_results, state.pkg_sel_right, state.pkg_loading)
    set_lines(state.right_buf, lines, hl_map, 0)
  else
    local cfg = require("cargo.config").options
    local icon = runner.is_running() and (state.spinner and state.spinner:frame() or cfg.icons.running)
                  or ""
    local header = icon ~= "" and { "  " .. icon .. " 実行中…" } or {}
    local all = vim.list_extend(header, state.output_lines)
    set_lines(state.right_buf, all, nil, 0)
    -- 末尾にスクロール
    local win = vim.fn.bufwinid(state.right_buf)
    if win ~= -1 then
      local lc = vim.api.nvim_buf_line_count(state.right_buf)
      vim.api.nvim_win_set_cursor(win, { lc, 0 })
    end
  end
end

-- コマンドを実行する
local function run_command(state, args)
  state.output_lines = { "$ cargo " .. table.concat(args, " ") }
  state.last_args = args
  redraw_right(state)

  -- スピナー開始
  state.spinner = Spinner.new({
    on_frame = function(_)
      redraw_right(state)
    end,
  })
  state.spinner:start()

  runner.run({
    args = args,
    cwd  = state.root,
    on_line = function(line)
      table.insert(state.output_lines, line)
      -- テスト結果パース
      if state.active_tab == 2 then
        local ok_name = line:match("^test (.+) %.%.%. ok$")
        local fail_name = line:match("^test (.+) %.%.%. FAILED$")
        if ok_name then
          table.insert(state.test_results, { name = ok_name, ok = true })
          redraw_left(state)
        elseif fail_name then
          table.insert(state.test_results, { name = fail_name, ok = false })
          redraw_left(state)
        end
      end
      redraw_right(state)
    end,
    on_exit = function(code)
      if state.spinner then state.spinner:stop() end
      local cfg = require("cargo.config").options
      local icon = code == 0 and cfg.icons.success or cfg.icons.error
      table.insert(state.output_lines, "")
      table.insert(state.output_lines, string.format("  %s 終了コード: %d", icon, code))
      redraw_right(state)
    end,
  })
end

-- キーマップをバッファに設定
local function setup_keymaps(state, bufs)
  local cfg = require("cargo.config").options
  local km = cfg.keymaps
  local opts = { noremap = true, silent = true }

  local function map(buf, key, fn)
    vim.keymap.set("n", key, fn, vim.tbl_extend("force", opts, { buffer = buf }))
  end

  local function close()
    if state.spinner then state.spinner:stop() end
    runner.kill()
    for _, buf in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    if state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
      vim.api.nvim_win_close(state.main_win, true)
    end
  end

  local function switch_tab(n)
    state.active_tab = n
    state.output_lines = {}
    state.test_results = {}
    redraw_left(state)
    redraw_right(state)
  end

  local function do_run()
    local tab = state.active_tab
    if tab == 3 then return end  -- Packages は別処理
    local mod = get_tab_module(tab)
    if not mod or not mod.commands then return end
    local cmd = mod.commands[state.selected[tab]]
    if not cmd then return end

    if cmd.prompt then
      vim.ui.input({ prompt = cmd.prompt .. ": " }, function(input)
        if input then
          local args = vim.list_extend(vim.deepcopy(cmd.args), { input })
          run_command(state, args)
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
        local count = #state.pkg_deps
        if count == 0 then return end
        state.pkg_sel_left = math.max(1, math.min(count, state.pkg_sel_left + delta))
      else
        local count = #state.pkg_results
        if count == 0 then return end
        state.pkg_sel_right = math.max(1, math.min(count, state.pkg_sel_right + delta))
      end
    else
      local mod = get_tab_module(tab)
      if not mod or not mod.commands then return end
      local count = #mod.commands
      state.selected[tab] = math.max(1, math.min(count, state.selected[tab] + delta))
    end
    redraw_left(state)
    redraw_right(state)
  end

  for _, buf in ipairs(bufs) do
    map(buf, km.close,      close)
    map(buf, "<Esc>",       close)
    map(buf, km.tab_build,  function() switch_tab(1) end)
    map(buf, km.tab_test,   function() switch_tab(2) end)
    map(buf, km.tab_pkgs,   function() switch_tab(3) end)
    map(buf, km.tab_tools,  function() switch_tab(4) end)
    map(buf, km.tab_next,   function() switch_tab(math.min(4, state.active_tab + 1)) end)
    map(buf, km.tab_prev,   function() switch_tab(math.max(1, state.active_tab - 1)) end)
    map(buf, "j",           function() move(1) end)
    map(buf, "k",           function() move(-1) end)
    map(buf, km.run,        do_run)
    map(buf, km.rerun,      function()
      if state.last_args then run_command(state, state.last_args) end
    end)
    map(buf, km.kill,       function()
      runner.kill()
      if state.spinner then state.spinner:stop() end
      table.insert(state.output_lines, "  [中断]")
      redraw_right(state)
    end)
    map(buf, km.panel_next, function()
      state.active_panel = state.active_panel == 1 and 2 or 1
    end)

    -- Packages: d で削除、Enter で追加
    if state.active_tab == 3 then
      map(buf, km.pkg_remove, function()
        if state.active_panel ~= 1 then return end
        local dep = state.pkg_deps[state.pkg_sel_left]
        if not dep then return end
        vim.ui.select({ "はい", "いいえ" }, {
          prompt = dep.name .. " を削除しますか？",
        }, function(choice)
          if choice == "はい" then
            state.output_lines = {}
            run_command(state, { "remove", dep.name })
            -- Cargo.toml を再パース
            vim.defer_fn(function()
              state.pkg_deps = require("cargo.workspace").get_dependencies(state.root)
              state.pkg_sel_left = math.max(1, math.min(#state.pkg_deps, state.pkg_sel_left))
              redraw_left(state)
            end, 500)
          end
        end)
      end)
      map(buf, km.pkg_add, function()
        if state.active_panel ~= 2 then return end
        local r = state.pkg_results[state.pkg_sel_right]
        if not r then return end
        state.output_lines = {}
        run_command(state, { "add", r.name })
        vim.defer_fn(function()
          state.pkg_deps = require("cargo.workspace").get_dependencies(state.root)
          redraw_left(state)
        end, 500)
      end)
    end
  end
end

-- メインウィンドウを開く
function M.open(root)
  setup_highlights()

  local cfg = require("cargo.config").options
  local state = State.new(root)

  -- ウィンドウサイズ計算
  local vim_w = vim.o.columns
  local vim_h = vim.o.lines
  local width  = math.floor(vim_w * cfg.window.width)
  local height = math.floor(vim_h * cfg.window.height)
  local row    = math.floor((vim_h - height) / 2)
  local col    = math.floor((vim_w - width) / 2)

  -- パネル幅
  local left_w  = math.floor(width * 0.38)
  local right_w = width - left_w - 1  -- 1 は区切り線
  local panel_h = height - 4  -- タイトル行 + タブ行 + ステータス行

  -- メインフローティングウィンドウ（枠のみ）
  local main_buf = vim.api.nvim_create_buf(false, true)
  state.main_win = vim.api.nvim_open_win(main_buf, true, {
    relative = "editor",
    width    = width,
    height   = height,
    row      = row,
    col      = col,
    style    = "minimal",
    border   = cfg.window.border,
    title    = string.format(" cargo.nvim — %s ", state.pkg_name),
    title_pos = "center",
  })

  -- 左パネルバッファ
  local left_buf = vim.api.nvim_create_buf(false, true)
  state.left_buf = left_buf
  local left_win = vim.api.nvim_open_win(left_buf, false, {
    relative = "win",
    win      = state.main_win,
    width    = left_w,
    height   = panel_h,
    row      = 2,
    col      = 1,
    style    = "minimal",
  })

  -- 右パネルバッファ
  local right_buf = vim.api.nvim_create_buf(false, true)
  state.right_buf = right_buf
  local right_win = vim.api.nvim_open_win(right_buf, false, {
    relative = "win",
    win      = state.main_win,
    width    = right_w,
    height   = panel_h,
    row      = 2,
    col      = left_w + 2,
    style    = "minimal",
  })

  -- バッファオプション
  for _, buf in ipairs({ main_buf, left_buf, right_buf }) do
    vim.api.nvim_buf_set_option(buf, "buftype",    "nofile")
    vim.api.nvim_buf_set_option(buf, "bufhidden",  "wipe")
    vim.api.nvim_buf_set_option(buf, "swapfile",   false)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
  end

  -- タブバーをメインバッファ 1行目に描画
  vim.api.nvim_buf_set_option(main_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(main_buf, 0, -1, false, {
    "  " .. table.concat(vim.tbl_map(function(t) return t.label end, TABS), " │ "),
    string.rep("─", width - 2),
  })
  vim.api.nvim_buf_set_option(main_buf, "modifiable", false)

  -- Packages タブ用の検索入力ウィンドウ（常に非表示→タブ切り替えで表示）
  local input_buf = vim.api.nvim_create_buf(false, true)
  state.input_buf = input_buf

  -- キーマップ設定
  setup_keymaps(state, { main_buf, left_buf, right_buf })

  -- Packages タブ向けの検索ロジック
  -- 入力監視は vim.ui.input の代わりに左パネルで 's' キーで起動
  local km = cfg.keymaps
  for _, buf in ipairs({ main_buf, left_buf, right_buf }) do
    vim.keymap.set("n", "s", function()
      if state.active_tab ~= 3 then return end
      vim.ui.input({ prompt = "Search crates.io: ", default = state.pkg_filter }, function(input)
        if input == nil then return end
        state.pkg_filter  = input
        state.pkg_loading = true
        state.pkg_sel_right = 1
        redraw_right(state)
        require("cargo.crates").search(input, function(results)
          state.pkg_results  = results
          state.pkg_loading  = false
          redraw_right(state)
        end)
        redraw_left(state)
      end)
    end, { buffer = buf, noremap = true, silent = true })

    -- args 上書き
    vim.keymap.set("n", km.args, function()
      if state.active_tab == 3 then return end
      vim.ui.input({ prompt = "追加引数: " }, function(input)
        if input and state.last_args then
          local args = vim.list_extend(vim.deepcopy(state.last_args), vim.split(input, " "))
          run_command(state, args)
        end
      end)
    end, { buffer = buf, noremap = true, silent = true })
  end

  -- ウィンドウ閉時にクリーンアップ
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(state.main_win),
    once     = true,
    callback = function()
      if state.spinner then state.spinner:stop() end
      runner.kill()
    end,
  })

  -- 初期描画
  redraw_left(state)
  redraw_right(state)

  -- main_win にフォーカスを戻す
  vim.api.nvim_set_current_win(state.main_win)

  _ = left_win
  _ = right_win
end

return M
