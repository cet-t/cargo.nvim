local M = {}
local runner  = require("cargo.runner")
local Spinner = require("cargo.ui.spinner")
local ns      = vim.api.nvim_create_namespace("cargo_nvim")

-- ──────────────────────────────────────────────────────────────
-- ハイライト定義
-- ──────────────────────────────────────────────────────────────
local function setup_hl()
  local h = vim.api.nvim_set_hl
  h(0, "CargoCategoryTitle", { bold = true,  link = "Label"      })
  h(0, "CargoSelected",      { bold = true,  link = "PmenuSel"   })
  h(0, "CargoNormal",        {               link = "Normal"      })
  h(0, "CargoSeparator",     {               link = "Comment"     })
  h(0, "CargoMuted",         {               link = "Comment"     })
  h(0, "CargoSuccess",       { bold = true,  fg   = "#98c379"     })
  h(0, "CargoError",         { bold = true,  fg   = "#e06c75"     })
  h(0, "CargoTabActive",     { bold = true,  link = "TabLineSel"  })
  h(0, "CargoTabInactive",   {               link = "TabLine"     })
  h(0, "CargoTabKey",        {               link = "Comment"     })
end

-- ──────────────────────────────────────────────────────────────
-- タブ定義
-- ──────────────────────────────────────────────────────────────
local TABS = {
  { label = "Build / Run", key = "1" },
  { label = "Package",     key = "2" },
  { label = "Test",        key = "3" },
}

-- ──────────────────────────────────────────────────────────────
-- 文字列ユーティリティ
-- ──────────────────────────────────────────────────────────────
-- 表示幅 w に右パディング（ASCII 前提、CJK は strdisplaywidth で対応）
local function rpad(s, w)
  s = tostring(s or "")
  local dw = vim.fn.strdisplaywidth(s)
  if dw >= w then
    -- 表示幅で切り詰め（超過しないよう）
    local result, cur = "", 0
    for _, byte in utf8.codes(s) do
      local ch  = utf8.char(byte)
      local cw  = vim.fn.strdisplaywidth(ch)
      if cur + cw > w then break end
      result, cur = result .. ch, cur + cw
    end
    return result .. string.rep(" ", w - cur)
  end
  return s .. string.rep(" ", w - dw)
end

local function hline(lw, rw)
  return string.rep("─", lw) .. "┼" .. string.rep("─", rw)
end

local function merged(ltext, rtext, lw)
  return rpad(ltext, lw) .. "│" .. (rtext or "")
end

-- ──────────────────────────────────────────────────────────────
-- タブバー：テキストとハイライト位置を返す
-- ──────────────────────────────────────────────────────────────
local function tabbar(active)
  -- "  Label [n]  │  Label [n]  │ ..."
  -- ハイライト: ラベル部のみ TabActive/Inactive, [n] は CargoTabKey
  local text  = ""
  local hls   = {}   -- { col_s, col_e, group }

  for i, t in ipairs(TABS) do
    if i > 1 then
      text = text .. "  │  "
    else
      text = text .. " "
    end
    local label_start = #text
    text = text .. t.label
    table.insert(hls, { label_start, #text, i == active and "CargoTabActive" or "CargoTabInactive" })

    text = text .. " "
    local key_start = #text
    text = text .. "[" .. t.key .. "]"
    table.insert(hls, { key_start, #text, "CargoTabKey" })
    text = text .. " "
  end

  return text, hls
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
    sel            = { 1, 1, 1 },
    -- 出力
    output         = {},
    last_args      = nil,
    test_results   = {},
    -- Package タブ
    pkg_section    = 1,          -- 1=installed, 2=search
    pkg_sel_inst   = 1,
    pkg_sel_search = 1,
    pkg_deps       = ws.get_dependencies(root),
    pkg_query      = "",
    pkg_results    = {},
    pkg_loading    = false,
    pkg_search_mode = false,     -- インライン検索入力中か
    pkg_detail_inst = nil,
    pkg_detail_srch = nil,
    -- UI
    buf            = nil,
    win            = nil,
    spinner        = nil,
    lw             = 0,
    rw             = 0,
    total_h        = 0,
    inst_h         = 0,
    srch_h         = 0,
    -- ウィンドウ絶対位置（デバウンス検索用）
    _debounce      = nil,
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
    -- h = { lnum(0-based), col_s, col_e, group }
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, h[4], h[1], h[2], h[3])
  end
end

-- ──────────────────────────────────────────────────────────────
-- 行リストを h 行に切り詰め / パディング
-- ──────────────────────────────────────────────────────────────
local function clamp(rows, h)
  local out = {}
  for i = 1, h do
    out[i] = rows[i] or { text = "", hl = "CargoNormal" }
  end
  return out
end

-- ──────────────────────────────────────────────────────────────
-- 出力パネル行リスト
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
    if     line:match("^error")    then hl = "CargoError"
    elseif line:match("^warning")  then hl = "DiagnosticWarn"
    elseif line:match("Finished")  then hl = "CargoSuccess"
    end
    table.insert(rows, { text = line, hl = hl })
  end
  return rows
end

-- ──────────────────────────────────────────────────────────────
-- 左列行リスト（Build/Run, Test）
-- ──────────────────────────────────────────────────────────────
local function left_rows(state)
  if state.active_tab == 1 then
    return require("cargo.ui.tabs.build_run").render_rows(state.sel[1])
  elseif state.active_tab == 3 then
    return require("cargo.ui.tabs.test").render_rows(state.sel[3], state.test_results)
  end
  return {}
end

-- ──────────────────────────────────────────────────────────────
-- ハイライト収集（左右列をマージした 1 行分）
-- ──────────────────────────────────────────────────────────────
local function collect_hl(lnum, lr, rr, lw)
  local hls = {}
  if lr and lr.hl and lr.hl ~= "CargoNormal" then
    table.insert(hls, { lnum, 0, lw, lr.hl })
  end
  if rr and rr.hl and rr.hl ~= "CargoNormal" then
    local rs = lw + 1
    local re = rs + vim.fn.strdisplaywidth(rr.text or "")
    table.insert(hls, { lnum, rs, re, rr.hl })
  end
  return hls
end

-- ──────────────────────────────────────────────────────────────
-- redraw（シングルバッファ全描画）
-- ──────────────────────────────────────────────────────────────
local function redraw(state)
  local buf = state.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end

  local lw     = state.lw
  local rw     = state.rw
  local lines  = {}
  local hls    = {}

  local function push(line, row_hls)
    table.insert(lines, line)
    local lnum = #lines - 1  -- 0-indexed
    for _, h in ipairs(row_hls or {}) do
      table.insert(hls, { lnum, h[1], h[2], h[3] })
    end
  end

  -- ─── タブバー ────────────────────────────────────────────
  local tb_text, tb_hls = tabbar(state.active_tab)
  push(tb_text, tb_hls)
  push(hline(lw, rw))

  -- ─── Package タブ ────────────────────────────────────────
  if state.active_tab == 2 then
    local pkg = require("cargo.ui.tabs.packages")

    -- 上段: インストール済み | 詳細
    local inst = clamp(pkg.installed_rows(state.pkg_deps, state.pkg_sel_inst), state.inst_h)
    local det1 = clamp(pkg.detail_rows(state.pkg_detail_inst, rw), state.inst_h)
    for i = 1, state.inst_h do
      local lr, rr = inst[i], det1[i]
      push(merged(lr.text, rr.text, lw), collect_hl(0, lr, rr, lw))
    end

    -- 中段セパレータ
    push(hline(lw, rw))

    -- 下段: 検索 | 詳細
    local srch = clamp(
      pkg.search_rows(state.pkg_query, state.pkg_results,
                      state.pkg_loading, state.pkg_search_mode, lw),
      state.srch_h)
    local det2 = clamp(pkg.detail_rows(state.pkg_detail_srch, rw), state.srch_h)
    for i = 1, state.srch_h do
      local lr, rr = srch[i], det2[i]
      push(merged(lr.text, rr.text, lw), collect_hl(0, lr, rr, lw))
    end

  -- ─── Build/Run・Test タブ ────────────────────────────────
  else
    local lrows = clamp(left_rows(state),    state.total_h)
    local rrows = clamp(output_rows(state),  state.total_h)
    for i = 1, state.total_h do
      local lr, rr = lrows[i], rrows[i]
      push(merged(lr.text, rr.text, lw), collect_hl(0, lr, rr, lw))
    end
  end

  -- ─── ステータスバー ──────────────────────────────────────
  push(hline(lw, rw))
  local cfg = require("cargo.config").options
  local km  = cfg.keymaps
  local status
  if state.active_tab == 2 then
    if state.pkg_search_mode then
      status = "  Search: 入力中  [Enter/Esc] 確定/キャンセル  [BS] 削除"
    else
      status = string.format(
        "  [s] Search  [%s] Add  [%s] Remove  [jk] Nav  [Tab] Switch  [%s] Quit",
        km.pkg_add, km.pkg_remove, km.close)
    end
  else
    status = string.format(
      "  [Enter] Run  [%s] Args  [%s] Re-run  [%s] Kill  []/[] Tab  [%s] Quit",
      km.args, km.rerun, km.kill, km.close)
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
        if ok_n   then table.insert(state.test_results, { name = ok_n,   ok = true  }) end
        if fail_n then table.insert(state.test_results, { name = fail_n, ok = false }) end
      end
      redraw(state)
    end,
    on_exit = function(code)
      if state.spinner then state.spinner:stop() end
      local icon = code == 0 and require("cargo.config").options.icons.success
                              or require("cargo.config").options.icons.error
      table.insert(state.output, "")
      table.insert(state.output, string.format("  %s 終了コード: %d", icon, code))
      redraw(state)
    end,
  })
end

-- ──────────────────────────────────────────────────────────────
-- crates.io 詳細を非同期取得
-- ──────────────────────────────────────────────────────────────
local function fetch_detail(state, item, is_search)
  if not item then return end
  require("cargo.crates").get_detail(item.name, item.version, function(detail)
    if is_search then
      state.pkg_detail_srch = detail
    else
      state.pkg_detail_inst = detail
    end
    redraw(state)
  end)
end

-- ──────────────────────────────────────────────────────────────
-- インライン検索モード
-- ──────────────────────────────────────────────────────────────
local function trigger_search(state)
  if state._debounce then
    state._debounce:stop()
    state._debounce:close()
    state._debounce = nil
  end
  if state.pkg_query == "" then
    state.pkg_results   = {}
    state.pkg_loading   = false
    state.pkg_detail_srch = nil
    redraw(state)
    return
  end
  state.pkg_loading = true
  redraw(state)
  local cfg = require("cargo.config").options
  state._debounce = vim.uv.new_timer()
  state._debounce:start(cfg.search.debounce_ms, 0, vim.schedule_wrap(function()
    state._debounce = nil
    require("cargo.crates").search(state.pkg_query, function(results)
      state.pkg_results   = results
      state.pkg_loading   = false
      state.pkg_sel_search = 1
      state.pkg_detail_srch = nil
      redraw(state)
      if results[1] then fetch_detail(state, results[1], true) end
    end)
  end))
end

local function enter_search_mode(state, setup_keys_fn)
  state.pkg_search_mode = true
  state.pkg_section     = 2
  redraw(state)

  local buf = state.buf

  -- 既存のキーマップを一時的に上書き
  local function char_map(ch)
    vim.keymap.set("n", ch, function()
      state.pkg_query = state.pkg_query .. ch
      trigger_search(state)
      redraw(state)
    end, { buffer = buf, noremap = true, silent = true })
  end

  -- 印字可能 ASCII（スペース〜チルダ）
  for c = 32, 126 do
    char_map(string.char(c))
  end

  vim.keymap.set("n", "<BS>", function()
    if #state.pkg_query > 0 then
      state.pkg_query = state.pkg_query:sub(1, -2)
      trigger_search(state)
      redraw(state)
    end
  end, { buffer = buf, noremap = true, silent = true })

  local function exit_search()
    state.pkg_search_mode = false
    setup_keys_fn()   -- 通常キーマップに戻す
    redraw(state)
  end
  vim.keymap.set("n", "<CR>",  exit_search, { buffer = buf, noremap = true, silent = true })
  vim.keymap.set("n", "<Esc>", exit_search, { buffer = buf, noremap = true, silent = true })
end

-- ──────────────────────────────────────────────────────────────
-- 通常キーマップ設定
-- ──────────────────────────────────────────────────────────────
local function setup_keys(state)
  local cfg = require("cargo.config").options
  local km  = cfg.keymaps
  local buf = state.buf
  local o   = { noremap = true, silent = true, buffer = buf }
  local function map(key, fn) vim.keymap.set("n", key, fn, o) end

  -- 印字可能文字を全クリア（検索モード後の復元）
  for c = 32, 126 do
    pcall(vim.keymap.del, "n", string.char(c), { buffer = buf })
  end
  pcall(vim.keymap.del, "n", "<BS>",  { buffer = buf })
  pcall(vim.keymap.del, "n", "<CR>",  { buffer = buf })
  pcall(vim.keymap.del, "n", "<Esc>", { buffer = buf })

  local function close()
    if state.spinner then state.spinner:stop() end
    runner.kill()
    if state._debounce then
      state._debounce:stop(); state._debounce:close(); state._debounce = nil
    end
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_close(state.win, true)
    end
  end

  local function switch_tab(n)
    state.active_tab   = n
    state.output       = {}
    state.test_results = {}
    setup_keys(state)
    redraw(state)
  end

  local function do_run()
    if state.active_tab == 2 then
      -- Package: 検索セクションで Enter = add
      if state.pkg_section == 2 then
        local r = state.pkg_results[state.pkg_sel_search]
        if r then
          run_cmd(state, { "add", r.name })
          vim.defer_fn(function()
            state.pkg_deps = require("cargo.workspace").get_dependencies(state.root)
            redraw(state)
          end, 900)
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

  local function move(d)
    if state.active_tab == 2 then
      if state.pkg_section == 1 then
        local n    = math.max(1, #state.pkg_deps)
        local prev = state.pkg_sel_inst
        state.pkg_sel_inst = math.max(1, math.min(n, state.pkg_sel_inst + d))
        if state.pkg_sel_inst ~= prev then
          state.pkg_detail_inst = nil
          redraw(state)
          fetch_detail(state, state.pkg_deps[state.pkg_sel_inst], false)
        end
      else
        local n    = math.max(1, #state.pkg_results)
        local prev = state.pkg_sel_search
        state.pkg_sel_search = math.max(1, math.min(n, state.pkg_sel_search + d))
        if state.pkg_sel_search ~= prev then
          state.pkg_detail_srch = nil
          redraw(state)
          fetch_detail(state, state.pkg_results[state.pkg_sel_search], true)
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

  map(km.close,  close)
  map("<Esc>",   close)
  map("j",       function() move(1)  end)
  map("k",       function() move(-1) end)
  map("<CR>",    do_run)
  map(km.rerun,  function()
    if state.last_args then run_cmd(state, state.last_args) end
  end)
  map(km.kill,   function()
    runner.kill()
    if state.spinner then state.spinner:stop() end
    table.insert(state.output, "  [中断]")
    redraw(state)
  end)
  map(km.args,   function()
    if state.active_tab == 2 then return end
    vim.ui.input({ prompt = "追加引数: " }, function(input)
      if input and input ~= "" and state.last_args then
        run_cmd(state, vim.list_extend(vim.deepcopy(state.last_args), vim.split(input, " ")))
      end
    end)
  end)

  -- タブ切り替え
  map(km.tab_next,  function() switch_tab(math.min(#TABS, state.active_tab + 1)) end)
  map(km.tab_prev,  function() switch_tab(math.max(1,     state.active_tab - 1)) end)
  map(km.tab_build, function() switch_tab(1) end)
  map(km.tab_pkgs,  function() switch_tab(2) end)
  map(km.tab_test,  function() switch_tab(3) end)

  -- Package タブ専用
  map("<Tab>", function()
    if state.active_tab ~= 2 then return end
    state.pkg_section = state.pkg_section == 1 and 2 or 1
    redraw(state)
  end)

  -- s = インライン検索モード開始
  map("s", function()
    if state.active_tab ~= 2 then return end
    enter_search_mode(state, function() setup_keys(state) end)
  end)

  -- d = remove（インストール済みセクション）
  map(km.pkg_remove, function()
    if state.active_tab ~= 2 or state.pkg_section ~= 1 then return end
    local dep = state.pkg_deps[state.pkg_sel_inst]
    if not dep then return end
    vim.ui.select({ "はい", "いいえ" }, { prompt = dep.name .. " を削除？" }, function(choice)
      if choice ~= "はい" then return end
      run_cmd(state, { "remove", dep.name })
      vim.defer_fn(function()
        state.pkg_deps     = require("cargo.workspace").get_dependencies(state.root)
        state.pkg_sel_inst = math.max(1, math.min(#state.pkg_deps, state.pkg_sel_inst))
        redraw(state)
      end, 900)
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
  local iw = W - 2  -- border 除く内側幅
  local ih = H - 2  -- border 除く内側高さ

  state.lw      = math.floor(iw * 0.42)
  state.rw      = iw - state.lw - 1   -- "│" 分
  -- ih - tabbar(1) - sep(1) - bottom_sep(1) - status(1) = コンテンツ行数
  state.total_h = ih - 4
  -- Package タブ: 上段 38% / 中段セパレータ / 下段
  state.inst_h  = math.floor((state.total_h - 1) * 0.38)
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

  -- カーソルを非表示にする（Cursor hl を透明化、ウィンドウ閉時に復元）
  local saved_cursor_hl = vim.api.nvim_get_hl(0, { name = "Cursor" })
  vim.api.nvim_set_hl(0, "Cursor", { blend = 100, fg = "bg", bg = "bg" })

  -- カーソル位置を常に左上に固定
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer   = buf,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
      end
    end,
  })

  setup_keys(state)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(win),
    once     = true,
    callback = function()
      if state.spinner then state.spinner:stop() end
      if state._debounce then
        state._debounce:stop(); state._debounce:close()
      end
      runner.kill()
      -- カーソルハイライトを復元
      vim.api.nvim_set_hl(0, "Cursor", saved_cursor_hl)
    end,
  })

  -- 初期詳細ロード
  if state.pkg_deps[1] then
    fetch_detail(state, state.pkg_deps[1], false)
  end

  redraw(state)
end

return M
