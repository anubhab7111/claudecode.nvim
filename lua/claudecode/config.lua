---@brief [[
--- Manages configuration for the Claude Code Neovim integration.
--- Provides default settings, validation, and application of user-defined configurations.
---@brief ]]
---@module 'claudecode.config'

local M = {}

---@type ClaudeCodeConfig
M.defaults = {
  port_range = { min = 10000, max = 65535 },
  -- Address the IDE server binds to. Keep loopback unless Claude runs somewhere
  -- that cannot reach 127.0.0.1 (e.g. WSL2 NAT); a non-loopback host exposes the
  -- (token-protected, unencrypted) port to the network.
  server_host = "127.0.0.1",
  auto_start = true,
  terminal_cmd = nil,
  env = {}, -- Custom environment variables for Claude terminal
  log_level = "info",
  track_selection = true,
  selection = {
    -- Send the cursor file's path to Claude even when nothing is selected
    -- (VS Code's "Attach Open File"). false = only real selections are sent.
    send_file_context = true,
    -- Glob patterns (matched against the file name and full path) whose
    -- selected text is never sent to Claude; only the path is shared.
    -- A user-supplied list replaces this default entirely.
    exclude = { ".env", ".env.*", "*.pem", "*.key", "id_rsa*", "id_ed25519*", "id_ecdsa*", "*.p12", "*.pfx", ".netrc" },
  },
  -- Lines of scrollback sent by :ClaudeCodeSendTerm
  terminal_context_lines = 200,
  -- Claude Code HTTP hooks posted back to this Neovim (status, alerts,
  -- autosave, follow, plan review). Injected per session with
  -- `claude --settings <file>`; merged with your own hooks, never replacing them.
  hooks = {
    enabled = true,
    sync_timeout = 5, -- seconds Claude waits for the PreToolUse reply
  },
  -- Write a modified buffer before Claude reads/edits its file (needs hooks).
  autosave = true,
  -- vim.notify when Claude needs input or finishes (needs hooks).
  alerts = {
    enabled = true,
    only_when_hidden = true, -- stay quiet while the Claude terminal is visible
  },
  -- React to files Claude changed (needs hooks).
  follow = {
    checktime = true, -- reload that buffer right away
    flash = false, -- briefly highlight the reloaded buffer
  },
  -- Statusline text formatter: function(state) -> string (nil = built-in)
  status = { format = nil },
  -- Review Claude's plan in a Markdown buffer when it leaves plan mode
  -- (ga approve · edit + :w send revisions · q use the terminal dialog).
  plan_review = {
    enabled = true,
    layout = "tab", -- "tab" | "split"
    approve_key = "ga",
    timeout = 3600, -- seconds before falling back to the terminal dialog
  },
  -- Keep a pre-edit snapshot of files Claude touches in a turn, for
  -- :ClaudeCodeReview / :ClaudeCodeReviewDiff / :ClaudeCodeReviewRevert.
  turn_review = { enabled = true },
  -- Read-only LSP tools for Claude (lspDefinition, lspReferences, lspHover,
  -- lspDocumentSymbols, lspWorkspaceSymbols), served by the `nvim` MCP server
  -- and backed by the language servers already running in Neovim.
  lsp_tools = {
    enabled = true,
    max_results = 100,
    timeout_ms = 5000,
  },
  -- When true, focus Claude terminal after a successful send while connected
  focus_after_send = false,
  visual_demotion_delay_ms = 50, -- Milliseconds to wait before demoting a visual selection
  connection_wait_delay = 600, -- Milliseconds to wait after connection before sending queued @ mentions
  connection_timeout = 10000, -- Maximum time to wait for Claude Code to connect (milliseconds)
  queue_timeout = 5000, -- Maximum time to keep @ mentions in queue (milliseconds)
  diff_opts = {
    layout = "vertical",
    open_in_new_tab = false, -- Open diff in a new tab (false = use current tab)
    keep_terminal_focus = false, -- If true, moves focus back to terminal after diff opens (including floating terminals)
    hide_terminal_in_new_tab = false, -- If true and opening in a new tab, do not show Claude terminal there
    on_new_file_reject = "keep_empty", -- "keep_empty" leaves an empty buffer; "close_window" closes the placeholder split
    auto_resize_terminal = true, -- Let the plugin manage Claude terminal width across the diff lifecycle; false = own it via ClaudeCodeDiffOpened/Closed
  },
  -- `value` is passed verbatim to `claude --model`. These short aliases resolve
  -- to the latest model on the Anthropic API, so labels stay version-free to
  -- avoid going stale on every release.
  models = {
    { name = "Claude Opus (Latest)", value = "opus" },
    { name = "Claude Opus (Latest, 1M context)", value = "opus[1m]" },
    { name = "Claude Sonnet (Latest)", value = "sonnet" },
    { name = "Claude Sonnet (Latest, 1M context)", value = "sonnet[1m]" },
    { name = "Claude Haiku (Latest)", value = "haiku" },
    { name = "Default (account recommended)", value = "default" },
  },
  -- Keep a minimal terminal config here instead of requiring claudecode.terminal
  -- during config.apply(). Loading the terminal module pulls in the server/main
  -- module graph and makes coverage-enabled config validation unexpectedly slow.
  terminal = {
    provider = "auto",
    provider_opts = {
      external_terminal_cmd = nil,
    },
  },
}

---Validates the provided configuration table.
---Throws an error if any validation fails.
---@param config table The configuration table to validate.
---@return boolean true if the configuration is valid.
function M.validate(config)
  assert(
    type(config.port_range) == "table"
      and type(config.port_range.min) == "number"
      and type(config.port_range.max) == "number"
      and config.port_range.min > 0
      and config.port_range.max <= 65535
      and config.port_range.min <= config.port_range.max,
    "Invalid port range"
  )

  assert(type(config.auto_start) == "boolean", "auto_start must be a boolean")

  if config.server_host ~= nil then
    assert(type(config.server_host) == "string" and config.server_host ~= "", "server_host must be a non-empty string")
  end

  if config.selection ~= nil then
    assert(type(config.selection) == "table", "selection must be a table")
    if config.selection.send_file_context ~= nil then
      assert(type(config.selection.send_file_context) == "boolean", "selection.send_file_context must be a boolean")
    end
    if config.selection.exclude ~= nil then
      assert(type(config.selection.exclude) == "table", "selection.exclude must be a list of glob strings")
      for i, pat in ipairs(config.selection.exclude) do
        assert(type(pat) == "string" and pat ~= "", "selection.exclude[" .. i .. "] must be a non-empty string")
      end
    end
  end

  if config.hooks ~= nil then
    assert(type(config.hooks) == "table", "hooks must be a table")
    if config.hooks.enabled ~= nil then
      assert(type(config.hooks.enabled) == "boolean", "hooks.enabled must be a boolean")
    end
    if config.hooks.sync_timeout ~= nil then
      assert(
        type(config.hooks.sync_timeout) == "number" and config.hooks.sync_timeout > 0,
        "hooks.sync_timeout must be a positive number"
      )
    end
  end
  if config.autosave ~= nil then
    assert(type(config.autosave) == "boolean", "autosave must be a boolean")
  end
  for _, key in ipairs({ "alerts", "follow" }) do
    if config[key] ~= nil then
      assert(type(config[key]) == "table", key .. " must be a table")
      for k, v in pairs(config[key]) do
        assert(type(v) == "boolean", key .. "." .. tostring(k) .. " must be a boolean")
      end
    end
  end
  if config.plan_review ~= nil then
    local pr = config.plan_review
    assert(type(pr) == "table" or type(pr) == "boolean", "plan_review must be a table or boolean")
    if type(pr) == "table" then
      if pr.enabled ~= nil then
        assert(type(pr.enabled) == "boolean", "plan_review.enabled must be a boolean")
      end
      if pr.layout ~= nil then
        assert(pr.layout == "tab" or pr.layout == "split", "plan_review.layout must be 'tab' or 'split'")
      end
      if pr.approve_key ~= nil then
        assert(
          pr.approve_key == false or (type(pr.approve_key) == "string" and pr.approve_key ~= ""),
          "plan_review.approve_key must be a key string or false"
        )
      end
      if pr.timeout ~= nil then
        assert(type(pr.timeout) == "number" and pr.timeout >= 30, "plan_review.timeout must be a number >= 30")
      end
    end
  end
  if config.turn_review ~= nil then
    local tr = config.turn_review
    assert(type(tr) == "table" or type(tr) == "boolean", "turn_review must be a table or boolean")
    if type(tr) == "table" and tr.enabled ~= nil then
      assert(type(tr.enabled) == "boolean", "turn_review.enabled must be a boolean")
    end
  end

  if config.lsp_tools ~= nil then
    local lt = config.lsp_tools
    assert(type(lt) == "table" or type(lt) == "boolean", "lsp_tools must be a table or boolean")
    if type(lt) == "table" then
      if lt.enabled ~= nil then
        assert(type(lt.enabled) == "boolean", "lsp_tools.enabled must be a boolean")
      end
      for _, k in ipairs({ "max_results", "timeout_ms" }) do
        if lt[k] ~= nil then
          assert(type(lt[k]) == "number" and lt[k] > 0, "lsp_tools." .. k .. " must be a positive number")
        end
      end
    end
  end

  if config.status ~= nil then
    assert(type(config.status) == "table", "status must be a table")
    assert(config.status.format == nil or type(config.status.format) == "function", "status.format must be a function")
  end

  if config.terminal_context_lines ~= nil then
    assert(
      type(config.terminal_context_lines) == "number" and config.terminal_context_lines > 0,
      "terminal_context_lines must be a positive number"
    )
  end

  assert(config.terminal_cmd == nil or type(config.terminal_cmd) == "string", "terminal_cmd must be nil or a string")

  -- Validate terminal config
  assert(type(config.terminal) == "table", "terminal must be a table")

  -- Validate provider_opts if present
  if config.terminal.provider_opts then
    assert(type(config.terminal.provider_opts) == "table", "terminal.provider_opts must be a table")

    -- Validate external_terminal_cmd in provider_opts
    if config.terminal.provider_opts.external_terminal_cmd then
      local cmd_type = type(config.terminal.provider_opts.external_terminal_cmd)
      assert(
        cmd_type == "string" or cmd_type == "function",
        "terminal.provider_opts.external_terminal_cmd must be a string or function"
      )
      -- Only validate %s placeholder for strings
      if cmd_type == "string" and config.terminal.provider_opts.external_terminal_cmd ~= "" then
        assert(
          config.terminal.provider_opts.external_terminal_cmd:find("%%s"),
          "terminal.provider_opts.external_terminal_cmd must contain '%s' placeholder for the Claude command"
        )
      end
    end
  end

  local valid_log_levels = { "trace", "debug", "info", "warn", "error" }
  local is_valid_log_level = false
  for _, level in ipairs(valid_log_levels) do
    if config.log_level == level then
      is_valid_log_level = true
      break
    end
  end
  assert(is_valid_log_level, "log_level must be one of: " .. table.concat(valid_log_levels, ", "))

  assert(type(config.track_selection) == "boolean", "track_selection must be a boolean")
  -- Allow absence in direct validate() calls; apply() supplies default
  if config.focus_after_send ~= nil then
    assert(type(config.focus_after_send) == "boolean", "focus_after_send must be a boolean")
  end

  assert(
    type(config.visual_demotion_delay_ms) == "number" and config.visual_demotion_delay_ms >= 0,
    "visual_demotion_delay_ms must be a non-negative number"
  )

  assert(
    type(config.connection_wait_delay) == "number" and config.connection_wait_delay >= 0,
    "connection_wait_delay must be a non-negative number"
  )

  assert(
    type(config.connection_timeout) == "number" and config.connection_timeout > 0,
    "connection_timeout must be a positive number"
  )

  assert(type(config.queue_timeout) == "number" and config.queue_timeout > 0, "queue_timeout must be a positive number")

  assert(type(config.diff_opts) == "table", "diff_opts must be a table")
  -- New diff options (optional validation to allow backward compatibility)
  if config.diff_opts.layout ~= nil then
    assert(
      config.diff_opts.layout == "vertical"
        or config.diff_opts.layout == "horizontal"
        or config.diff_opts.layout == "unified",
      "diff_opts.layout must be 'vertical', 'horizontal', or 'unified'"
    )
  end
  if config.diff_opts.open_in_new_tab ~= nil then
    assert(type(config.diff_opts.open_in_new_tab) == "boolean", "diff_opts.open_in_new_tab must be a boolean")
  end
  if config.diff_opts.keep_terminal_focus ~= nil then
    assert(type(config.diff_opts.keep_terminal_focus) == "boolean", "diff_opts.keep_terminal_focus must be a boolean")
  end
  if config.diff_opts.hide_terminal_in_new_tab ~= nil then
    assert(
      type(config.diff_opts.hide_terminal_in_new_tab) == "boolean",
      "diff_opts.hide_terminal_in_new_tab must be a boolean"
    )
  end
  if config.diff_opts.on_new_file_reject ~= nil then
    assert(
      type(config.diff_opts.on_new_file_reject) == "string"
        and (
          config.diff_opts.on_new_file_reject == "keep_empty" or config.diff_opts.on_new_file_reject == "close_window"
        ),
      "diff_opts.on_new_file_reject must be 'keep_empty' or 'close_window'"
    )
  end
  if config.diff_opts.keys ~= nil then
    local keys = config.diff_opts.keys
    assert(keys == false or type(keys) == "table", "diff_opts.keys must be a table or false")
    if type(keys) == "table" then
      for action, lhs in pairs(keys) do
        assert(
          lhs == false or (type(lhs) == "string" and lhs ~= ""),
          "diff_opts.keys." .. tostring(action) .. " must be a key string or false"
        )
      end
    end
  end
  if config.diff_opts.auto_resize_terminal ~= nil then
    assert(type(config.diff_opts.auto_resize_terminal) == "boolean", "diff_opts.auto_resize_terminal must be a boolean")
  end

  -- Legacy diff options (accept if present to avoid breaking old configs)
  if config.diff_opts.auto_close_on_accept ~= nil then
    assert(type(config.diff_opts.auto_close_on_accept) == "boolean", "diff_opts.auto_close_on_accept must be a boolean")
  end
  if config.diff_opts.show_diff_stats ~= nil then
    assert(type(config.diff_opts.show_diff_stats) == "boolean", "diff_opts.show_diff_stats must be a boolean")
  end
  if config.diff_opts.vertical_split ~= nil then
    assert(type(config.diff_opts.vertical_split) == "boolean", "diff_opts.vertical_split must be a boolean")
  end
  if config.diff_opts.open_in_current_tab ~= nil then
    assert(type(config.diff_opts.open_in_current_tab) == "boolean", "diff_opts.open_in_current_tab must be a boolean")
  end

  -- Validate env
  assert(type(config.env) == "table", "env must be a table")
  for key, value in pairs(config.env) do
    assert(type(key) == "string", "env keys must be strings")
    assert(type(value) == "string", "env values must be strings")
  end

  -- Validate models
  assert(type(config.models) == "table", "models must be a table")
  assert(#config.models > 0, "models must not be empty")

  for i, model in ipairs(config.models) do
    assert(type(model) == "table", "models[" .. i .. "] must be a table")
    assert(type(model.name) == "string" and model.name ~= "", "models[" .. i .. "].name must be a non-empty string")
    assert(type(model.value) == "string" and model.value ~= "", "models[" .. i .. "].value must be a non-empty string")
  end

  return true
end

---Applies user configuration on top of default settings and validates the result.
---@param user_config table|nil The user-provided configuration table.
---@return ClaudeCodeConfig config The final, validated configuration table.
function M.apply(user_config)
  local config = vim.deepcopy(M.defaults)

  if user_config then
    -- Use vim.tbl_deep_extend if available, otherwise simple merge
    if vim.tbl_deep_extend then
      config = vim.tbl_deep_extend("force", config, user_config)
    else
      -- Simple fallback for testing environment
      for k, v in pairs(user_config) do
        config[k] = v
      end
    end
  end

  -- List-valued options replace the default instead of merging by index.
  if user_config and type(user_config.selection) == "table" and user_config.selection.exclude ~= nil then
    config.selection.exclude = vim.deepcopy(user_config.selection.exclude)
  end

  -- Backward compatibility: map legacy diff options to new fields if provided
  if config.diff_opts then
    local d = config.diff_opts
    -- Map vertical_split -> layout (legacy option takes precedence)
    if type(d.vertical_split) == "boolean" then
      d.layout = d.vertical_split and "vertical" or "horizontal"
    end
    -- Map open_in_current_tab -> open_in_new_tab (legacy option takes precedence)
    if type(d.open_in_current_tab) == "boolean" then
      d.open_in_new_tab = not d.open_in_current_tab
    end
  end

  M.validate(config)

  return config
end

return M
