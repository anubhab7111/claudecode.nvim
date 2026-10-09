---Claude session status, fed by hook events.
---
---`require("claudecode").statusline()` returns a string that is rebuilt only
---when a hook event arrives, so calling it from a statusline on every redraw is
---a table lookup.
---@module 'claudecode.status'
local M = {}

---@class ClaudeCodeStatusState
---@field status "idle"|"working"|"needs_input"|"done"|"offline"
---@field permission_mode string|nil
---@field model string|nil
---@field subagents integer Running subagents
---@field todos_done integer
---@field todos_total integer
---@field session_id string|nil
---@field message string|nil Last notification text
M.state = {
  status = "offline",
  permission_mode = nil,
  model = nil,
  subagents = 0,
  todos_done = 0,
  todos_total = 0,
  session_id = nil,
  message = nil,
}

M._line = ""

---Per-session states in multi-session mode (keyed by our session id).
---@type table<string, {state: ClaudeCodeStatusState, line: string}>
M.sessions = {}

local function new_state()
  return { status = "offline", subagents = 0, todos_done = 0, todos_total = 0 }
end

local MODE_LABEL = {
  default = "manual",
  acceptEdits = "edits",
  plan = "plan",
  auto = "auto",
  dontAsk = "dontAsk",
  bypassPermissions = "bypass",
}

local NEEDS_INPUT = {
  permission_prompt = true,
  agent_needs_input = true,
  elicitation_dialog = true,
  elicitation_url_dialog = true,
}

---Default formatter. Override with config `status.format = function(state) ... end`.
---@param s ClaudeCodeStatusState
---@return string
function M.format(s)
  if s.status == "offline" then
    return ""
  end
  local parts = { "claude: " .. (s.status == "needs_input" and "needs input" or s.status) }
  local mode = s.permission_mode and (MODE_LABEL[s.permission_mode] or s.permission_mode)
  if mode then
    parts[#parts + 1] = mode
  end
  if s.subagents > 0 then
    parts[#parts + 1] = s.subagents .. (s.subagents == 1 and " agent" or " agents")
  end
  if s.todos_total > 0 then
    parts[#parts + 1] = s.todos_done .. "/" .. s.todos_total
  end
  return table.concat(parts, " · ")
end

M.formatter = nil -- user override

local function render(state)
  local fmt = M.formatter or M.format
  local ok, line = pcall(fmt, state)
  return (ok and type(line) == "string") and line or ""
end

local function rebuild()
  M._line = render(M.state)
end

---Apply a hook payload. Returns true when the visible state changed.
---@param p table Hook input JSON
---@param session_id string|nil Our session id (multi-session); nil = main session
---@return boolean changed
function M.update(p, session_id)
  if type(p) ~= "table" then
    return false
  end
  if session_id then
    local entry = M.sessions[session_id]
    if not entry then
      entry = { state = new_state(), line = "" }
      M.sessions[session_id] = entry
    end
    local main_state, main_line = M.state, M._line
    M.state = entry.state
    local changed = M.update(p, nil)
    entry.line = M._line
    M.state, M._line = main_state, main_line
    return changed
  end
  local s = M.state
  local before = M._line
  local ev = p.hook_event_name

  if type(p.permission_mode) == "string" then
    s.permission_mode = p.permission_mode
  end
  if type(p.session_id) == "string" then
    s.session_id = p.session_id
  end

  if ev == "SessionStart" then
    s.status = "idle"
    s.subagents = 0
    if type(p.model) == "string" then
      s.model = p.model
    end
  elseif ev == "SessionEnd" then
    s.status = "offline"
    s.subagents = 0
  elseif ev == "UserPromptSubmit" or ev == "PreToolUse" or ev == "PostToolUse" then
    s.status = "working"
    s.message = nil
  elseif ev == "PermissionRequest" then
    s.status = "needs_input"
  elseif ev == "Notification" then
    if NEEDS_INPUT[p.notification_type] then
      s.status = "needs_input"
      s.message = type(p.message) == "string" and p.message or nil
    end
  elseif ev == "Stop" then
    s.status = "done"
    s.subagents = 0
  elseif ev == "SubagentStart" then
    s.subagents = s.subagents + 1
  elseif ev == "SubagentStop" then
    s.subagents = math.max(0, s.subagents - 1)
  elseif ev == "PostModelSwitch" and type(p.model) == "string" then
    s.model = p.model
  end

  if ev == "PostToolUse" and p.tool_name == "TodoWrite" and type(p.tool_input) == "table" then
    local todos = p.tool_input.todos
    if type(todos) == "table" then
      local done = 0
      for _, t in ipairs(todos) do
        if type(t) == "table" and t.status == "completed" then
          done = done + 1
        end
      end
      s.todos_done, s.todos_total = done, #todos
    end
  end

  rebuild()
  return M._line ~= before
end

---Mark the session offline (server stopped).
function M.reset()
  M.state.status = "offline"
  M.state.subagents = 0
  M.state.todos_done, M.state.todos_total = 0, 0
  M.state.message = nil
  rebuild()
end

---Forget a session's state.
---@param session_id string
function M.drop(session_id)
  M.sessions[session_id] = nil
end

---Statusline text for a session (default: the current tab's session in
---multi-session mode, else the main session).
---@param session_id string|nil
---@return string
function M.statusline(session_id)
  if not session_id then
    local server = package.loaded["claudecode.server.init"]
    if server and server.session_router then
      session_id = server.session_router()
      if not session_id then
        return ""
      end
    end
  end
  if session_id then
    local entry = M.sessions[session_id]
    return entry and entry.line or ""
  end
  return M._line
end

return M
