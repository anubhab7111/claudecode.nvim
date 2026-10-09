-- Tool implementation for Claude Code Neovim integration
local M = {}

M.ERROR_CODES = {
  PARSE_ERROR = -32700,
  INVALID_REQUEST = -32600,
  METHOD_NOT_FOUND = -32601,
  INVALID_PARAMS = -32602,
  INTERNAL_ERROR = -32000, -- Default for tool execution if not more specific
  -- Custom / server specific: -32000 to -32099
}

M.tools = {}

---Loaders for public tools registered on first use of the `nvim` MCP server
---(so their code is not loaded at startup).
---@type function[]
M.lazy_public = {}

---Run pending lazy public-tool loaders.
function M.load_lazy()
  local loaders = M.lazy_public
  if #loaders == 0 then
    return
  end
  M.lazy_public = {}
  for _, load in ipairs(loaders) do
    local ok, err = pcall(load)
    if not ok then
      require("claudecode.logger").warn("tools", "failed to load tools: " .. tostring(err))
    end
  end
end

---Setup the tools module
function M.setup(server)
  M.server = server

  M.register_all()
end

---Tool scope served to a connection kind: the hidden IDE socket gets the
---`ide` tools, the model-visible `nvim` MCP socket (GET /mcp) gets `public` ones.
---@param kind string|nil client.kind
---@return "ide"|"public"
function M.scope_for_kind(kind)
  return kind == "tools" and "public" or "ide"
end

---Whether any model-visible (`public`) tool is registered.
---@return boolean
function M.has_public_tools()
  if #M.lazy_public > 0 then
    return true
  end
  for _, tool_data in pairs(M.tools) do
    if tool_data.scope == "public" and tool_data.schema then
      return true
    end
  end
  return false
end

---Get the complete tool list for MCP tools/list handler
---@param kind string|nil Connection kind (see server/client.lua); nil = IDE socket
function M.get_tool_list(kind)
  local tool_list = {}
  local scope = M.scope_for_kind(kind)
  if scope == "public" then
    M.load_lazy()
  end

  for name, tool_data in pairs(M.tools) do
    -- Only include tools that have schemas (are meant to be exposed via MCP)
    -- and that belong to the requesting connection's scope.
    if tool_data.schema and (tool_data.scope or "ide") == scope then
      local tool_def = {
        name = name,
        description = tool_data.schema.description,
        inputSchema = tool_data.schema.inputSchema,
      }
      table.insert(tool_list, tool_def)
    end
  end

  return tool_list
end

---Register all tools
function M.register_all()
  -- Register MCP-exposed tools with schemas
  M.register(require("claudecode.tools.open_file"))
  M.register(require("claudecode.tools.get_current_selection"))
  M.register(require("claudecode.tools.get_open_editors"))
  M.register(require("claudecode.tools.open_diff"))
  M.register(require("claudecode.tools.get_latest_selection"))
  M.register(require("claudecode.tools.close_all_diff_tabs"))
  M.register(require("claudecode.tools.get_diagnostics"))
  M.register(require("claudecode.tools.get_workspace_folders"))
  M.register(require("claudecode.tools.check_document_dirty"))
  M.register(require("claudecode.tools.save_document"))

  -- Register internal tools without schemas (not exposed via MCP)
  M.register(require("claudecode.tools.close_tab"))

  -- Model-visible tools on the `nvim` MCP socket (GET /mcp).
  local main = package.loaded["claudecode"]
  local cfg = main and main.state and main.state.config or {}
  local lsp_cfg = cfg.lsp_tools
  if lsp_cfg == nil or lsp_cfg == true or (type(lsp_cfg) == "table" and lsp_cfg.enabled ~= false) then
    M.lazy_public[#M.lazy_public + 1] = function()
      for _, tool in ipairs(require("claudecode.tools.lsp").tools()) do
        M.register(tool)
      end
    end
  end
end

---Register a tool
function M.register(tool_module)
  if not tool_module or not tool_module.name or not tool_module.handler then
    local name = "unknown"
    if type(tool_module) == "table" and type(tool_module.name) == "string" then
      name = tool_module.name
    elseif type(tool_module) == "string" then -- if require failed, it might be the path string
      name = tool_module
    end
    vim.notify(
      "Error registering tool: Invalid tool module structure for " .. name,
      vim.log.levels.ERROR,
      { title = "ClaudeCode Tool Registration" }
    )
    return
  end

  M.tools[tool_module.name] = {
    handler = tool_module.handler,
    schema = tool_module.schema, -- Will be nil if not defined in the module
    requires_coroutine = tool_module.requires_coroutine, -- Will be nil if not defined in the module
    scope = tool_module.scope or "ide",
  }
end

---Suspend a coroutine tool until `start(done)` calls `done(...)` or the timeout
---expires (then returns nil, "timeout"). Use inside a `requires_coroutine` tool
---handler; when the handler finishes after resuming, its return value is sent
---as the deferred MCP response.
---@param start fun(done: fun(...))
---@param timeout_ms integer|nil Default 5000
---@return any ...
function M.await(start, timeout_ms)
  local co = coroutine.running()
  assert(co, "tools.await must be called from a coroutine tool (requires_coroutine = true)")
  local finished = false
  local timer

  local function done(...)
    if finished then
      return
    end
    finished = true
    if timer then
      pcall(function()
        timer:stop()
        timer:close()
      end)
    end
    local args = { n = select("#", ...), ... }
    vim.schedule(function()
      local ok, ret, ret2 = coroutine.resume(co, unpack(args, 1, args.n))
      if coroutine.status(co) ~= "dead" then
        return -- awaiting again
      end
      local key = tostring(co)
      local sender = _G.claude_deferred_responses and _G.claude_deferred_responses[key]
      if not sender then
        return
      end
      _G.claude_deferred_responses[key] = nil
      sender(M.normalize_result(ok, ret, ret2))
    end)
  end

  local uv = vim.uv or vim.loop
  timer = uv.new_timer()
  if timer then
    timer:start(timeout_ms or 5000, 0, function()
      done(nil, "timeout")
    end)
  end
  local ok, err = pcall(start, done)
  if not ok then
    done(nil, tostring(err))
  end
  return coroutine.yield()
end

---Turn a coroutine tool's outcome into the `{content=...}` / `{error=...}`
---shape the deferred-response sender expects.
---@param ok boolean coroutine.resume success
---@param ret any First return value (or the error)
---@param ret2 any Second return value
---@return table
function M.normalize_result(ok, ret, ret2)
  local function as_error(e, fallback)
    if type(e) == "table" and e.code and e.message then
      return { error = { code = e.code, message = e.message, data = e.data } }
    end
    return { error = { code = M.ERROR_CODES.INTERNAL_ERROR, message = fallback, data = tostring(e) } }
  end
  if not ok then
    return as_error(ret, "Tool execution failed")
  end
  if ret == false then
    return as_error(ret2, type(ret2) == "string" and ret2 or "Tool reported an error")
  end
  if type(ret) == "table" and ret.content then
    return ret
  end
  return as_error(ret, "Tool returned an unexpected value")
end

---Handle an invocation of a tool
function M.handle_invoke(client, params) -- client needed for blocking tools
  local tool_name = params.name
  local input = params.arguments

  if client and client.kind == "tools" then
    M.load_lazy()
  end
  local tool_data = tool_name and M.tools[tool_name]
  -- A tool is only callable from the connection kind that lists it.
  if tool_data and (tool_data.scope or "ide") ~= M.scope_for_kind(client and client.kind) then
    tool_data = nil
  end
  if not tool_data then
    return {
      error = {
        code = -32601, -- JSON-RPC Method not found
        message = "Tool not found: " .. tostring(tool_name),
      },
    }
  end
  -- Tool handlers are now expected to:
  -- 1. Raise an error (e.g., error({code=..., message=...}) or error("string"))
  -- 2. Return (false, "error message string" or {code=..., message=...}) for pcall-style errors
  -- 3. Return the result directly for success.
  -- Check if this tool requires coroutine context for blocking behavior
  local pcall_results
  if tool_data.requires_coroutine then
    -- Wrap in coroutine for blocking behavior
    require("claudecode.logger").debug("tools", "Wrapping " .. tool_name .. " in coroutine for blocking behavior")
    local co = coroutine.create(function()
      return tool_data.handler(input, client)
    end)

    require("claudecode.logger").debug("tools", "About to resume coroutine for " .. tool_name)
    local success, result = coroutine.resume(co)
    require("claudecode.logger").debug(
      "tools",
      "Coroutine resume returned - success:",
      success,
      "status:",
      coroutine.status(co)
    )

    if coroutine.status(co) == "suspended" then
      require("claudecode.logger").debug("tools", "Coroutine is suspended - tool is blocking, will respond later")
      -- The coroutine yielded, which means the tool is blocking
      -- Return a special marker to indicate this is a deferred response
      return { _deferred = true, coroutine = co, client = client, params = params }
    end

    require("claudecode.logger").debug(
      "tools",
      "Coroutine completed for " .. tool_name .. ", success: " .. tostring(success)
    )
    pcall_results = { success, result }
  else
    pcall_results = { pcall(tool_data.handler, input, client) }
  end
  local pcall_success = pcall_results[1]
  local handler_return_val1 = pcall_results[2]
  local handler_return_val2 = pcall_results[3]

  if not pcall_success then
    -- Case 1: Handler itself raised a Lua error (e.g. error("foo") or error({...}))
    -- handler_return_val1 contains the error object/string from the pcall
    local err_code = M.ERROR_CODES.INTERNAL_ERROR
    local err_msg = "Tool execution failed via error()"
    local err_data_payload = tostring(handler_return_val1)

    if type(handler_return_val1) == "table" and handler_return_val1.code and handler_return_val1.message then
      err_code = handler_return_val1.code
      err_msg = handler_return_val1.message
      err_data_payload = handler_return_val1.data
    elseif type(handler_return_val1) == "string" then
      err_msg = handler_return_val1
    end
    return { error = { code = err_code, message = err_msg, data = err_data_payload } }
  end

  -- pcall succeeded, now check the handler's actual return values
  -- Case 2: Handler returned (false, "error message" or {error_obj})
  if handler_return_val1 == false then
    local err_val_from_handler = handler_return_val2 -- This is the actual error string or table
    local err_code = M.ERROR_CODES.INTERNAL_ERROR
    local err_msg = "Tool reported an error"
    local err_data_payload = tostring(err_val_from_handler)

    if type(err_val_from_handler) == "table" and err_val_from_handler.code and err_val_from_handler.message then
      err_code = err_val_from_handler.code
      err_msg = err_val_from_handler.message
      err_data_payload = err_val_from_handler.data
    elseif type(err_val_from_handler) == "string" then
      err_msg = err_val_from_handler
    end
    return { error = { code = err_code, message = err_msg, data = err_data_payload } }
  end

  -- Case 3: Handler succeeded and returned the result directly
  -- handler_return_val1 is the actual result
  return { result = handler_return_val1 }
end

return M
