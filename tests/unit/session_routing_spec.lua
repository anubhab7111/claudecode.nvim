require("tests.busted_setup")

describe("multi-session routing", function()
  local server, tcp
  local sent

  before_each(function()
    package.loaded["claudecode.server.init"] = nil
    server = require("claudecode.server.init")
    tcp = require("claudecode.server.tcp")
    sent = {}
    server.state.server = {
      clients = {
        main = { id = "main", kind = "ide", handshake_complete = true },
        a = { id = "a", kind = "ide", session_id = "tab1", handshake_complete = true },
        b = { id = "b", kind = "ide", session_id = "tab2", handshake_complete = false },
        t = { id = "t", kind = "tools", session_id = "tab1", handshake_complete = true },
      },
    }
    tcp._orig_send = tcp.send_to_client
    tcp.send_to_client = function(_, id)
      sent[#sent + 1] = id
    end
  end)

  after_each(function()
    tcp.send_to_client = tcp._orig_send
    server.session_router = nil
    server.state.server = nil
  end)

  it("sends IDE notifications only to the routed session's IDE clients", function()
    server.session_router = function()
      return "tab1"
    end
    server.broadcast("selection_changed", {})
    assert.are.same({ "a" }, sent)
  end)

  it("routes to main-listener clients when the current tab has no session", function()
    server.session_router = function()
      return nil
    end
    server.broadcast("at_mentioned", {})
    assert.are.same({ "main" }, sent)
  end)

  it("reports per-session connection state", function()
    assert.is_true(server.has_ide_client("tab1"))
    assert.is_false(server.has_ide_client("tab2")) -- handshake not complete
    assert.is_true(server.has_ide_client(nil))
    assert.is_false(server.has_ide_client("tab9"))
  end)
end)

describe("per-session status", function()
  it("keeps separate lines per session and leaves the main session alone", function()
    package.loaded["claudecode.status"] = nil
    local status = require("claudecode.status")
    status.update({ hook_event_name = "SessionStart" }, "tab1")
    status.update({ hook_event_name = "UserPromptSubmit" }, "tab2")
    assert.are.equal("claude: idle", status.statusline("tab1"))
    assert.are.equal("claude: working", status.statusline("tab2"))
    assert.are.equal("", status.statusline())
    status.drop("tab2")
    assert.are.equal("", status.statusline("tab2"))
  end)
end)
