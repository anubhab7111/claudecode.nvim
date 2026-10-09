---Dispatcher for Claude Code HTTP hooks (POST /hook on the IDE port).
---
---Every request is answered quickly: fire-and-forget events get `{}` straight
---away, PreToolUse runs its (cheap) work before replying, and only plan
---review holds a reply while the user reads the plan. Feature modules are
---required on first use, so an idle session costs nothing.
---
---Events are re-emitted as `User ClaudeCodeHook` autocmds (`data` = the hook
---payload) so user configs can react to anything Claude does.
---@module 'claudecode.hooks'
local M = {}

local logger = require("claudecode.logger")

---@type table<string, fun(payload: table)[]>
local listeners = {}

---Subscribe to a hook event (e.g. "PreToolUse"). Listeners run synchronously
---before the reply for PreToolUse, and after it for every other event.
---@param event string
---@param fn fun(payload: table)
function M.on(event, fn)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], fn)
end

---Remove all listeners (tests).
function M._reset()
  listeners = {}
end

local function config()
  local main = package.loaded["claudecode"]
  return (main and main.state and main.state.config) or {}
end

local function run_listeners(event, payload)
  for _, fn in ipairs(listeners[event] or {}) do
    local ok, err = pcall(fn, payload)
    if not ok then
      logger.debug("hooks", "listener for " .. event .. " failed: " .. tostring(err))
    end
  end
end

---Resolve the loaded buffer showing `path`, if any.
---@param path string|nil
---@return integer|nil bufnr
function M.find_buffer(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local full = vim.fn.fnamemodify(path, ":p")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name == path or name == full then
        return b
      end
    end
  end
  return nil
end

local function tool_file(payload)
  local input = payload.tool_input
  if type(input) ~= "table" then
    return nil
  end
  return input.file_path or input.notebook_path
end

---Write a modified buffer before Claude reads or edits its file, so Claude never
---works from stale disk content (VS Code's `autosave`). Uses `noautocmd` so slow
---format-on-save hooks cannot stall Claude.
---@param payload table
function M.autosave(payload)
  local b = M.find_buffer(tool_file(payload))
  if not b then
    return
  end
  if not vim.api.nvim_buf_get_option(b, "modified") or vim.api.nvim_buf_get_option(b, "buftype") ~= "" then
    return
  end
  local ok, err = pcall(vim.api.nvim_buf_call, b, function()
    vim.cmd("silent noautocmd update")
  end)
  if ok then
    logger.debug("hooks", "autosaved " .. vim.api.nvim_buf_get_name(b) .. " before " .. tostring(payload.tool_name))
  else
    logger.warn("hooks", "autosave failed: " .. tostring(err))
  end
end

local flash_ns = nil

---Reload the buffer of a file Claude just changed, and optionally flash it.
---@param payload table
function M.follow(payload)
  local follow = config().follow or {}
  if follow.checktime == false then
    return
  end
  local b = M.find_buffer(tool_file(payload))
  if not b or vim.api.nvim_buf_get_option(b, "modified") then
    return -- never clobber unsaved edits; autosave normally prevents this
  end
  pcall(vim.cmd, "checktime " .. b)

  if follow.flash then
    flash_ns = flash_ns or vim.api.nvim_create_namespace("claudecode_follow")
    local hl = (vim.hl and vim.hl.range) or (vim.highlight and vim.highlight.range)
    if hl then
      vim.api.nvim_buf_clear_namespace(b, flash_ns, 0, -1)
      local last = vim.api.nvim_buf_line_count(b) - 1
      pcall(hl, b, flash_ns, "IncSearch", { 0, 0 }, { last, -1 }, {})
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(b) then
          vim.api.nvim_buf_clear_namespace(b, flash_ns, 0, -1)
        end
      end, 250)
    end
  end
end

local ALERT_TYPES = {
  permission_prompt = "Claude needs your permission",
  agent_needs_input = "Claude needs your input",
  elicitation_dialog = "Claude is asking a question",
  elicitation_url_dialog = "Claude is asking you to open a link",
}

---Notify when Claude needs attention while its terminal is hidden.
---@param payload table
function M.alert(payload)
  local alerts = config().alerts or {}
  if alerts.enabled == false then
    return
  end
  local msg
  if payload.hook_event_name == "Notification" then
    msg = ALERT_TYPES[payload.notification_type]
    if msg and type(payload.message) == "string" and payload.message ~= "" then
      msg = msg .. ": " .. payload.message
    end
  elseif payload.hook_event_name == "Stop" then
    msg = "Claude finished"
  end
  if not msg then
    return
  end
  if alerts.only_when_hidden ~= false then
    local sid = payload._claudecode_session
    local session = sid and package.loaded["claudecode.session"]
    if session then
      if session.is_visible(sid) then
        return
      end
    else
      local ok, terminal = pcall(require, "claudecode.terminal")
      if ok and terminal.is_visible and terminal.is_visible() then
        return
      end
    end
  end
  vim.notify(msg, vim.log.levels.INFO, { title = "Claude Code" })
end

local function fire_user_event(payload)
  if not (vim.api and vim.api.nvim_exec_autocmds) then
    return
  end
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "ClaudeCodeHook", data = payload, modeline = false })
end

local function encode(tbl)
  -- An empty Lua table would encode as `[]`; hook replies must be objects.
  if type(tbl) ~= "table" or next(tbl) == nil then
    return "{}"
  end
  local ok, s = pcall(vim.json.encode, tbl)
  return ok and s or "{}"
end

---HTTP route handler for POST /hook.
---@param client table|nil HTTP client (its session_id identifies the session in multi-session mode)
---@param req {body: string}
---@param respond fun(status: integer, body: string|nil)
function M.handle_http(client, req, respond)
  local ok, payload = pcall(vim.json.decode, req.body or "")
  if not ok or type(payload) ~= "table" then
    respond(400, '{"error":"invalid json"}')
    return
  end
  local ev = payload.hook_event_name
  local cfg = config()

  local status = require("claudecode.status")
  local session_id = client and client.session_id or nil
  payload._claudecode_session = session_id
  if status.update(payload, session_id) and vim.api and vim.api.nvim_exec_autocmds then
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "ClaudeCodeStatus", modeline = false })
  end

  if ev == "PreToolUse" then
    -- Synchronous: act before Claude touches the file, then reply.
    if cfg.autosave ~= false then
      pcall(M.autosave, payload)
    end
    -- Snapshot after autosave so the baseline is what the user had on screen.
    local tr = cfg.turn_review
    if tr == nil or tr == true or (type(tr) == "table" and tr.enabled ~= false) then
      pcall(function()
        require("claudecode.turn_review").snapshot(payload)
      end)
    end
    run_listeners(ev, payload)
    respond(200, "{}")
    fire_user_event(payload)
    return
  end

  if ev == "PermissionRequest" and payload.tool_name == "ExitPlanMode" then
    local pr = cfg.plan_review
    if pr == nil or pr == true or (type(pr) == "table" and pr.enabled ~= false) then
      local handled = false
      local okp, plan_review = pcall(require, "claudecode.plan_review")
      if okp and plan_review.handle then
        handled = plan_review.handle(payload, function(decision)
          respond(200, encode(decision))
        end)
      end
      if handled then
        fire_user_event(payload)
        return
      end
    end
  end

  -- Everything else is fire-and-forget: reply first, then do the work.
  respond(200, "{}")
  if ev == "UserPromptSubmit" then
    local tr = package.loaded["claudecode.turn_review"]
    if tr then
      tr.reset()
    end
  elseif ev == "PostToolUse" then
    pcall(M.follow, payload)
  elseif ev == "Notification" or ev == "Stop" then
    pcall(M.alert, payload)
  end
  run_listeners(ev, payload)
  fire_user_event(payload)
end

return M
