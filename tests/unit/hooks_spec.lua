require("tests.busted_setup")

describe("hooks_settings", function()
  local hs

  before_each(function()
    package.loaded["claudecode.hooks_settings"] = nil
    hs = require("claudecode.hooks_settings")
  end)

  it("points every hook at the IDE port with an env-expanded token header", function()
    local s = hs.build(4242, {})
    local h = s.hooks.Stop[1].hooks[1]
    assert.are.equal("http", h.type)
    assert.are.equal("http://127.0.0.1:4242/hook", h.url)
    assert.are.equal("${CLAUDECODE_TOKEN}", h.headers["x-claude-code-ide-authorization"])
    assert.are.same({ "CLAUDECODE_TOKEN" }, h.allowedEnvVars)
    assert.is_true(h.async)
  end)

  it("only adds synchronous hooks for features that need them", function()
    local s = hs.build(1, {})
    assert.is_nil(s.hooks.PreToolUse)
    assert.is_nil(s.hooks.PermissionRequest)

    s = hs.build(1, { need_pre_tool = true, sync_timeout = 3, plan_review = true })
    local pre = s.hooks.PreToolUse[1]
    assert.are.equal(hs.FILE_TOOLS, pre.matcher)
    assert.is_nil(pre.hooks[1].async)
    assert.are.equal(3, pre.hooks[1].timeout)
    assert.are.equal("ExitPlanMode", s.hooks.PermissionRequest[1].matcher)
  end)

  it("handles IPv6 loopback and a custom host", function()
    assert.are.equal("http://[::1]:5/hook", hs.hook_url(5, "::1"))
    assert.are.equal("http://127.0.0.1:5/hook", hs.hook_url(5, "0.0.0.0"))
    assert.are.equal("http://172.20.0.1:5/hook", hs.hook_url(5, "172.20.0.1"))
  end)
end)

describe("status", function()
  local status

  before_each(function()
    package.loaded["claudecode.status"] = nil
    status = require("claudecode.status")
  end)

  it("is empty while offline and tracks the session lifecycle", function()
    assert.are.equal("", status.statusline())
    status.update({ hook_event_name = "SessionStart", permission_mode = "default", model = "opus" })
    assert.are.equal("claude: idle · manual", status.statusline())
    status.update({ hook_event_name = "UserPromptSubmit", permission_mode = "plan" })
    assert.are.equal("claude: working · plan", status.statusline())
    status.update({ hook_event_name = "Notification", notification_type = "permission_prompt", message = "Bash" })
    assert.are.equal("needs_input", status.state.status)
    assert.are.equal("Bash", status.state.message)
    status.update({ hook_event_name = "Stop" })
    assert.are.equal("claude: done · plan", status.statusline())
    status.update({ hook_event_name = "SessionEnd" })
    assert.are.equal("", status.statusline())
  end)

  it("counts subagents and todo progress", function()
    status.update({ hook_event_name = "SessionStart" })
    status.update({ hook_event_name = "SubagentStart" })
    status.update({ hook_event_name = "SubagentStart" })
    status.update({ hook_event_name = "SubagentStop" })
    status.update({
      hook_event_name = "PostToolUse",
      tool_name = "TodoWrite",
      tool_input = { todos = { { status = "completed" }, { status = "in_progress" }, { status = "pending" } } },
    })
    assert.are.equal("claude: working · 1 agent · 1/3", status.statusline())
  end)

  it("reports whether the visible line changed and supports a custom formatter", function()
    assert.is_true(status.update({ hook_event_name = "SessionStart" }))
    assert.is_false(status.update({ hook_event_name = "SessionStart" }))
    status.formatter = function(s)
      return "C:" .. s.status
    end
    status.update({ hook_event_name = "Stop" })
    assert.are.equal("C:done", status.statusline())
  end)
end)

describe("hooks.handle_http", function()
  local hooks, responses, notified
  local orig = {}

  local function call(payload)
    responses = {}
    hooks.handle_http({}, { body = vim.json.encode(payload) }, function(code, body)
      responses[#responses + 1] = { code = code, body = body }
    end)
  end

  before_each(function()
    package.loaded["claudecode.hooks"] = nil
    package.loaded["claudecode.status"] = nil
    package.loaded["claudecode"] = { state = { config = { autosave = true, alerts = { enabled = true } } } }
    package.loaded["claudecode.terminal"] = {
      is_visible = function()
        return false
      end,
    }
    package.loaded["claudecode.plan_review"] = {
      handle = function()
        return false
      end,
    }
    hooks = require("claudecode.hooks")
    notified = {}
    orig.notify = vim.notify
    orig.decode, orig.encode = vim.json.decode, vim.json.encode
    vim.json.decode = function(str)
      return _G.json_decode(str)
    end
    vim.json.encode = function(data)
      return _G.json_encode(data)
    end
    vim.notify = function(msg)
      notified[#notified + 1] = msg
    end
  end)

  after_each(function()
    vim.notify = orig.notify
    vim.json.decode, vim.json.encode = orig.decode, orig.encode
    package.loaded["claudecode"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.plan_review"] = nil
  end)

  it("rejects invalid JSON", function()
    responses = {}
    hooks.handle_http({}, { body = "not json" }, function(code)
      responses[#responses + 1] = { code = code }
    end)
    assert.are.equal(400, responses[1].code)
  end)

  it("autosaves before replying to PreToolUse and runs listeners", function()
    local order = {}
    hooks.autosave = function()
      order[#order + 1] = "autosave"
    end
    hooks.on("PreToolUse", function()
      order[#order + 1] = "listener"
    end)
    responses = {}
    hooks.handle_http({}, { body = vim.json.encode({ hook_event_name = "PreToolUse", tool_name = "Edit" }) }, function()
      order[#order + 1] = "reply"
    end)
    assert.are.same({ "autosave", "listener", "reply" }, order)
  end)

  it("replies immediately and alerts on needs-input notifications while hidden", function()
    call({ hook_event_name = "Notification", notification_type = "permission_prompt", message = "Bash: rm" })
    assert.are.equal(200, responses[1].code)
    assert.are.equal(1, #notified)
    assert.truthy(notified[1]:find("permission", 1, true))
  end)

  it("stays quiet while the terminal is visible", function()
    package.loaded["claudecode.terminal"].is_visible = function()
      return true
    end
    call({ hook_event_name = "Stop" })
    assert.are.equal(0, #notified)
  end)

  it("lets plan review hold the reply, and falls back to {} when it declines", function()
    local held
    package.loaded["claudecode.plan_review"].handle = function(_, reply)
      held = reply
      return true
    end
    call({ hook_event_name = "PermissionRequest", tool_name = "ExitPlanMode", tool_input = { plan = "x" } })
    assert.are.equal(0, #responses)
    held({ hookSpecificOutput = { hookEventName = "PermissionRequest", decision = { behavior = "allow" } } })
    assert.are.equal(1, #responses)
    assert.truthy(responses[1].body:find("allow", 1, true))

    package.loaded["claudecode.plan_review"].handle = function()
      return false
    end
    call({ hook_event_name = "PermissionRequest", tool_name = "ExitPlanMode" })
    assert.are.equal("{}", responses[1].body)
  end)
end)
