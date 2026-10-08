require("tests.busted_setup")

describe("selection privacy options", function()
  local selection

  before_each(function()
    package.loaded["claudecode.selection"] = nil
    selection = require("claudecode.selection")
  end)

  after_each(function()
    selection.configure(require("claudecode.config").defaults.selection)
  end)

  it("excludes secret files by default", function()
    assert.is_true(selection.is_excluded("/home/u/proj/.env"))
    assert.is_true(selection.is_excluded("/home/u/proj/.env.local"))
    assert.is_true(selection.is_excluded("/home/u/.ssh/id_ed25519"))
    assert.is_true(selection.is_excluded("/srv/tls/server.pem"))
    assert.is_false(selection.is_excluded("/home/u/proj/main.lua"))
    assert.is_false(selection.is_excluded("/home/u/proj/environment.lua"))
  end)

  it("converts globs into anchored patterns with escaped magic characters", function()
    local pat = selection._glob_to_pattern("*.p12")
    assert.is_truthy(("cert.p12"):match(pat))
    assert.is_falsy(("certxp12"):match(pat))
    assert.is_falsy(("dir/cert.p12.bak"):match(pat))
  end)

  it("redacts text but keeps path and range", function()
    local sel = {
      text = "SECRET=1",
      filePath = "/p/.env",
      fileUrl = "file:///p/.env",
      selection = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 8 }, isEmpty = false },
    }
    local out = selection.redact(sel)
    assert.are.equal("", out.text)
    assert.are.equal("/p/.env", out.filePath)
    assert.are.equal(8, out.selection["end"].character)
    assert.are.equal("SECRET=1", sel.text, "input must not be mutated")
  end)

  it("honours a user-supplied exclude list", function()
    selection.configure({ exclude = { "*.secret" } })
    assert.is_true(selection.is_excluded("/p/db.secret"))
    assert.is_false(selection.is_excluded("/p/.env"))
  end)

  it("redacts what get_latest_selection returns", function()
    selection.state.latest_selection = { text = "k", filePath = "/p/server.key", selection = { isEmpty = false } }
    assert.are.equal("", selection.get_latest_selection().text)
    selection.state.latest_selection = nil
  end)

  it("drops empty (cursor-only) updates when send_file_context is false", function()
    local sent = {}
    selection.server = {
      broadcast = function(method, params)
        sent[#sent + 1] = params
      end,
    }
    selection.configure({ send_file_context = false })
    selection.send_selection_update({ text = "", filePath = "/p/a.lua", selection = { isEmpty = true } })
    assert.are.equal(0, #sent)
    selection.send_selection_update({ text = "x", filePath = "/p/a.lua", selection = { isEmpty = false } })
    assert.are.equal(1, #sent)
    selection.configure({ send_file_context = true })
    selection.server = nil
  end)
end)

describe("config selection options", function()
  it("replaces the default exclude list instead of merging by index", function()
    local config = require("claudecode.config")
    local c = config.apply({ selection = { exclude = { "*.secret" } } })
    assert.are.same({ "*.secret" }, c.selection.exclude)
    assert.is_true(c.selection.send_file_context)
  end)

  it("validates server_host", function()
    local config = require("claudecode.config")
    assert.has_error(function()
      config.apply({ server_host = "" })
    end)
    assert.are.equal("127.0.0.1", config.apply({}).server_host)
  end)
end)

describe("MCP protocol version negotiation", function()
  it("echoes known versions and falls back otherwise", function()
    local server = require("claudecode.server.init")
    assert.are.equal("2025-06-18", server.negotiate_protocol_version("2025-06-18"))
    assert.are.equal("2025-03-26", server.negotiate_protocol_version("2025-03-26"))
    assert.are.equal("2024-11-05", server.negotiate_protocol_version("1999-01-01"))
    assert.are.equal("2024-11-05", server.negotiate_protocol_version(nil))
  end)
end)
