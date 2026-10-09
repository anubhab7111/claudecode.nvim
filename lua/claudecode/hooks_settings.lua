---Generates the per-session Claude Code settings file that wires Claude's
---HTTP hooks back to this Neovim's IDE port (POST /hook).
---
---The file is passed to the CLI with `--settings <file>`. Claude Code merges
---list-valued settings across sources, so these hooks are added alongside the
---user's own hooks rather than replacing them. The auth token is never written
---to disk: the header references `${CLAUDECODE_TOKEN}`, which Claude expands
---from the terminal environment (listed in `allowedEnvVars`).
---@module 'claudecode.hooks_settings'
local M = {}

M.TOKEN_ENV = "CLAUDECODE_TOKEN"

---Tools whose PreToolUse/PostToolUse we care about (file reads/edits).
M.EDIT_TOOLS = "Edit|Write|MultiEdit|NotebookEdit"
M.FILE_TOOLS = "Read|" .. M.EDIT_TOOLS

---@param port integer
---@param host string|nil server_host
---@return string url
function M.hook_url(port, host)
  local h = "127.0.0.1"
  if host == "::1" then
    h = "[::1]"
  elseif host and host ~= "" and host ~= "localhost" and host ~= "127.0.0.1" and host ~= "0.0.0.0" then
    h = host
  end
  return "http://" .. h .. ":" .. port .. "/hook"
end

---Build the settings table.
---@param port integer
---@param opts {host: string|nil, sync_timeout: number|nil, need_pre_tool: boolean|nil, plan_review: boolean|nil, plan_timeout: number|nil}
---@return table settings
function M.build(port, opts)
  opts = opts or {}
  local url = M.hook_url(port, opts.host)
  local function handler(sync, timeout)
    local h = {
      type = "http",
      url = url,
      headers = { ["x-claude-code-ide-authorization"] = "${" .. M.TOKEN_ENV .. "}" },
      allowedEnvVars = { M.TOKEN_ENV },
      timeout = timeout or 5,
    }
    if not sync then
      h.async = true
    end
    return h
  end
  local function group(matcher, sync, timeout)
    local g = { hooks = { handler(sync, timeout) } }
    if matcher then
      g.matcher = matcher
    end
    return { g }
  end

  local hooks = {
    -- Fire-and-forget: Claude never waits on Neovim for these.
    PostToolUse = group(M.EDIT_TOOLS .. "|TodoWrite", false),
    UserPromptSubmit = group(nil, false),
    Stop = group(nil, false),
    Notification = group(nil, false),
    SessionStart = group(nil, false),
    SessionEnd = group(nil, false),
    SubagentStart = group(nil, false),
    SubagentStop = group(nil, false),
  }
  -- Synchronous, short timeout: only registered when a feature needs to act
  -- before the tool runs (autosave, turn-review snapshots).
  if opts.need_pre_tool then
    hooks.PreToolUse = group(M.FILE_TOOLS, true, opts.sync_timeout or 5)
  end
  -- Plan review holds the reply while the user reads the plan in a buffer.
  if opts.plan_review then
    hooks.PermissionRequest = group("ExitPlanMode", true, opts.plan_timeout or 3600)
  end
  return { hooks = hooks }
end

---Directory holding the generated files.
---@return string
function M.dir()
  return vim.fn.stdpath("state") .. "/claudecode"
end

---@param port integer
---@return string
function M.path_for(port)
  return M.dir() .. "/settings-" .. port .. ".json"
end

---Write the settings file (mode 0600) and return its path.
---@param port integer
---@param opts table See M.build
---@return string|nil path, string|nil err
function M.write(port, opts)
  local dir = M.dir()
  pcall(vim.fn.mkdir, dir, "p", 448) -- 0700
  local path = M.path_for(port)
  local ok, encoded = pcall(vim.json.encode, M.build(port, opts))
  if not ok then
    return nil, "encode failed: " .. tostring(encoded)
  end
  local uv = vim.uv or vim.loop
  local fd, err = uv.fs_open(path, "w", 384) -- 0600
  if not fd then
    return nil, err
  end
  uv.fs_write(fd, encoded, 0)
  uv.fs_close(fd)
  pcall(uv.fs_chmod, path, 384)
  return path, nil
end

---Build the `--mcp-config` table registering the model-visible `nvim` MCP
---server (WebSocket on the IDE port, path /mcp).
---@param port integer
---@param host string|nil
---@return table
function M.build_mcp(port, host)
  local url = M.hook_url(port, host):gsub("^http://", "ws://"):gsub("/hook$", "/mcp")
  return {
    mcpServers = {
      nvim = {
        type = "ws",
        url = url,
        headers = { ["x-claude-code-ide-authorization"] = "${" .. M.TOKEN_ENV .. "}" },
      },
    },
  }
end

---Write the MCP config file (mode 0600).
---@param port integer
---@param host string|nil
---@return string|nil path, string|nil err
function M.write_mcp(port, host)
  local dir = M.dir()
  pcall(vim.fn.mkdir, dir, "p", 448)
  local path = dir .. "/mcp-" .. port .. ".json"
  local ok, encoded = pcall(vim.json.encode, M.build_mcp(port, host))
  if not ok then
    return nil, tostring(encoded)
  end
  local uv = vim.uv or vim.loop
  local fd, err = uv.fs_open(path, "w", 384)
  if not fd then
    return nil, err
  end
  uv.fs_write(fd, encoded, 0)
  uv.fs_close(fd)
  return path, nil
end

---Remove the settings file for a port (ignores errors).
---@param port integer|nil
function M.remove(port)
  if not port then
    return
  end
  pcall(os.remove, M.path_for(port))
end

return M
