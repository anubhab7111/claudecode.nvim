---Multi-session mode: one Claude per tabpage (`multi_session = true`).
---
---Each tab's session gets its own listener on the IDE server (so the CLI
---started in that tab connects through its own `CLAUDE_CODE_SSE_PORT`), its own
---lock file and hooks/MCP files, and its own terminal split. Tools, handlers and
---the diff registry stay shared. Selection updates and @-mentions are routed to
---the current tab's session only.
---
---A session is created the first time you open Claude in a tab and stopped
---when that tab closes. Tabs that never open Claude cost nothing.
---@module 'claudecode.session'
local M = {}

local logger = require("claudecode.logger")

---@class ClaudeCodeSession
---@field id string
---@field tab integer
---@field port integer
---@field buf integer|nil
---@field win integer|nil
---@field job integer|nil
---@field args string Extra CLI args (hooks/MCP files)
---@field files string[] Generated files to delete on stop

---@type table<integer, ClaudeCodeSession> keyed by tabpage handle
M.sessions = {}
local providers = {} -- tab -> provider table (cheap, created on demand)
M.enabled = false

local function main()
  return package.loaded["claudecode"]
end

local function session_id_for(tab)
  return "tab" .. tab
end

---@param id string|nil
---@return ClaudeCodeSession|nil
function M.by_id(id)
  for _, s in pairs(M.sessions) do
    if s.id == id then
      return s
    end
  end
  return nil
end

---Session id for the current tab (nil when the tab has no session).
---@return string|nil
function M.current_id()
  local s = M.sessions[vim.api.nvim_get_current_tabpage()]
  return s and s.id or nil
end

---Start the session (listener, lock file, hooks/MCP files) for a tab.
---@param tab integer
---@return ClaudeCodeSession|nil session, string|nil err
function M.start(tab)
  if M.sessions[tab] then
    return M.sessions[tab]
  end
  local m = main()
  if not (m and m.state and m.state.server) then
    return nil, "Claude Code integration is not running"
  end
  local server = require("claudecode.server.init")
  local id = session_id_for(tab)
  local port, err = server.add_session_listener(id)
  if not port then
    return nil, "could not open a session listener: " .. tostring(err)
  end

  local lockfile = require("claudecode.lockfile")
  local ok_lock, lock_err = lockfile.create(port, m.state.auth_token)
  if not ok_lock then
    server.remove_session_listener(id)
    return nil, "could not write lock file: " .. tostring(lock_err)
  end

  local session = { id = id, tab = tab, port = port, args = "", files = {} }
  local cfg = m.state.config
  local hs = require("claudecode.hooks_settings")
  local args = {}
  if cfg.hooks and cfg.hooks.enabled and m.state.hooks_settings_path then
    local path = hs.write(port, {
      host = cfg.server_host,
      sync_timeout = cfg.hooks.sync_timeout,
      need_pre_tool = cfg.autosave ~= false or m._feature_enabled(cfg.turn_review, true),
      plan_review = m._feature_enabled(cfg.plan_review, true),
      plan_timeout = type(cfg.plan_review) == "table" and cfg.plan_review.timeout or nil,
    })
    if path then
      args[#args + 1] = "--settings '" .. path .. "'"
      session.files[#session.files + 1] = path
    end
  end
  if m.state.mcp_config_path then
    local path = hs.write_mcp(port, cfg.server_host)
    if path then
      args[#args + 1] = "--mcp-config='" .. path .. "'"
      session.files[#session.files + 1] = path
    end
  end
  session.args = table.concat(args, " ")
  M.sessions[tab] = session
  logger.debug("session", "started " .. id .. " on port " .. port)
  return session
end

---Stop a tab's session: terminate Claude, close its listener and files.
---@param tab integer
function M.stop(tab)
  local s = M.sessions[tab]
  if not s then
    return
  end
  M.sessions[tab] = nil
  providers[tab] = nil
  if s.job then
    pcall(vim.fn.jobstop, s.job)
  end
  if s.win and vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_close, s.win, true)
  end
  if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
    pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
  end
  local server = package.loaded["claudecode.server.init"]
  if server and server.remove_session_listener then
    server.remove_session_listener(s.id)
  end
  pcall(function()
    require("claudecode.lockfile").remove(s.port)
  end)
  for _, f in ipairs(s.files) do
    pcall(os.remove, f)
  end
  local status = package.loaded["claudecode.status"]
  if status and status.drop then
    status.drop(s.id)
  end
end

---Stop every session.
function M.stop_all()
  for tab in pairs(M.sessions) do
    M.stop(tab)
  end
end

local function is_visible(s)
  return s and s.win and vim.api.nvim_win_is_valid(s.win) and s.buf and vim.api.nvim_win_get_buf(s.win) == s.buf
end

---Whether a session's terminal is shown.
---@param id string
---@return boolean
function M.is_visible(id)
  return is_visible(M.by_id(id)) == true
end

---Switch to the tab that owns a session (used before showing its diffs).
---@param id string|nil
function M.focus_tab(id)
  local s = M.by_id(id)
  if s and vim.api.nvim_tabpage_is_valid(s.tab) and s.tab ~= vim.api.nvim_get_current_tabpage() then
    pcall(vim.api.nvim_set_current_tabpage, s.tab)
  end
end

local function show(s, cfg, focus)
  local original = vim.api.nvim_get_current_win()
  local width = math.floor(vim.o.columns * (cfg.split_width_percentage or 0.30))
  vim.cmd((cfg.split_side == "left" and "topleft " or "botright ") .. width .. "vsplit")
  s.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(s.win, s.buf)
  if focus ~= false then
    if cfg.auto_insert ~= false then
      vim.cmd("startinsert")
    end
  else
    vim.api.nvim_set_current_win(original)
  end
end

local function hide(s)
  if is_visible(s) then
    pcall(vim.api.nvim_win_close, s.win, true)
  end
  s.win = nil
end

local function spawn(s, cmd, env, cfg, focus)
  local original = vim.api.nvim_get_current_win()
  local width = math.floor(vim.o.columns * (cfg.split_width_percentage or 0.30))
  vim.cmd((cfg.split_side == "left" and "topleft " or "botright ") .. width .. "vsplit")
  s.win = vim.api.nvim_get_current_win()
  vim.cmd("enew")
  local argv = require("claudecode.utils").parse_command(cmd)
  local job = vim.fn.termopen(argv, {
    env = env,
    cwd = cfg.cwd,
    on_exit = function(job_id)
      vim.schedule(function()
        if s.job == job_id then
          s.job = nil
          if cfg.auto_close ~= false and s.win and vim.api.nvim_win_is_valid(s.win) then
            pcall(vim.api.nvim_win_close, s.win, true)
          end
          s.win = nil
          if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
            pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
          end
          s.buf = nil
        end
      end)
    end,
  })
  if not job or job <= 0 then
    vim.notify("Failed to start Claude in this tab", vim.log.levels.ERROR)
    pcall(vim.api.nvim_win_close, s.win, true)
    s.win = nil
    return
  end
  s.job = job
  s.buf = vim.api.nvim_get_current_buf()
  vim.bo[s.buf].bufhidden = "hide"
  pcall(function()
    vim.b[s.buf].claudecode_terminal = true
    vim.b[s.buf].claudecode_session = s.id
    vim.bo[s.buf].filetype = "claudecode"
  end)
  if focus ~= false then
    if cfg.auto_insert ~= false then
      vim.cmd("startinsert")
    end
  else
    vim.api.nvim_set_current_win(original)
  end
end

---Provider for a tab (implements the terminal provider interface).
---@param tab integer
---@return table
local function provider_for(tab)
  if providers[tab] then
    return providers[tab]
  end
  local p = {}
  local function session()
    return M.sessions[tab]
  end
  function p.open(cmd, env, cfg, focus)
    local s = session() or M.start(tab)
    if not s then
      return false
    end
    if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
      if is_visible(s) then
        if focus ~= false then
          vim.api.nvim_set_current_win(s.win)
          if cfg.auto_insert ~= false then
            vim.cmd("startinsert")
          end
        end
      else
        show(s, cfg, focus)
      end
      return true
    end
    spawn(s, cmd, env, cfg, focus)
    return true
  end
  function p.close()
    M.stop(tab)
  end
  function p.simple_toggle(cmd, env, cfg)
    local s = session()
    if s and is_visible(s) then
      hide(s)
    else
      p.open(cmd, env, cfg, true)
    end
  end
  function p.focus_toggle(cmd, env, cfg)
    local s = session()
    if s and is_visible(s) then
      if vim.api.nvim_get_current_win() == s.win then
        hide(s)
      else
        vim.api.nvim_set_current_win(s.win)
        if cfg.auto_insert ~= false then
          vim.cmd("startinsert")
        end
      end
    else
      p.open(cmd, env, cfg, true)
    end
  end
  function p.toggle(cmd, env, cfg)
    p.simple_toggle(cmd, env, cfg)
  end
  function p.get_active_bufnr()
    local s = session()
    if s and s.buf and vim.api.nvim_buf_is_valid(s.buf) then
      return s.buf
    end
    return nil
  end
  function p.is_available()
    return true
  end
  function p.setup() end
  providers[tab] = p
  return p
end

---Turn multi-session mode on (called from setup when `multi_session = true`).
function M.enable()
  if M.enabled then
    return
  end
  M.enabled = true
  local terminal = require("claudecode.terminal")
  terminal.set_session_hooks({
    provider = function()
      return provider_for(vim.api.nvim_get_current_tabpage())
    end,
    launch = function()
      local s, err = M.start(vim.api.nvim_get_current_tabpage())
      if not s then
        error(err)
      end
      return s.port, s.args
    end,
  })
  local server = require("claudecode.server.init")
  server.session_router = M.current_id

  local group = vim.api.nvim_create_augroup("ClaudeCodeSessions", { clear = true })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      for tab in pairs(M.sessions) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
          M.stop(tab)
        end
      end
      for tab in pairs(providers) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
          providers[tab] = nil
        end
      end
    end,
  })
end

---Turn multi-session mode off (stops all sessions).
function M.disable()
  if not M.enabled then
    return
  end
  M.stop_all()
  M.enabled = false
  pcall(function()
    require("claudecode.terminal").set_session_hooks(nil)
  end)
  local server = package.loaded["claudecode.server.init"]
  if server then
    server.session_router = nil
  end
  pcall(vim.api.nvim_del_augroup_by_name, "ClaudeCodeSessions")
end

---List sessions (for :ClaudeCodeSessions).
---@return {id: string, tab: integer, port: integer, running: boolean}[]
function M.list()
  local out = {}
  for _, s in pairs(M.sessions) do
    out[#out + 1] = { id = s.id, tab = s.tab, port = s.port, running = s.job ~= nil }
  end
  table.sort(out, function(a, b)
    return a.tab < b.tab
  end)
  return out
end

return M
