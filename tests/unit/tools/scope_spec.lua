require("tests.busted_setup")

describe("tool scopes", function()
  local tools

  before_each(function()
    package.loaded["claudecode.tools.init"] = nil
    tools = require("claudecode.tools.init")
    tools.tools = {}
    tools.register({
      name = "ideTool",
      schema = { description = "d", inputSchema = { type = "object" } },
      handler = function()
        return { content = { { type = "text", text = "ide" } } }
      end,
    })
    tools.register({
      name = "pubTool",
      scope = "public",
      schema = { description = "d", inputSchema = { type = "object" } },
      handler = function(input, client)
        return { content = { { type = "text", text = (client and client.kind or "?") } } }
      end,
    })
  end)

  local function names(list)
    local out = {}
    for _, t in ipairs(list) do
      out[#out + 1] = t.name
    end
    table.sort(out)
    return out
  end

  it("lists only the tools of the connection's scope", function()
    assert.are.same({ "ideTool" }, names(tools.get_tool_list()))
    assert.are.same({ "ideTool" }, names(tools.get_tool_list("ide")))
    assert.are.same({ "pubTool" }, names(tools.get_tool_list("tools")))
    assert.is_true(tools.has_public_tools())
  end)

  it("refuses cross-scope calls and passes the client to normal handlers", function()
    local r = tools.handle_invoke({ kind = "ide" }, { name = "pubTool", arguments = {} })
    assert.are.equal(-32601, r.error.code)
    r = tools.handle_invoke({ kind = "tools" }, { name = "ideTool", arguments = {} })
    assert.are.equal(-32601, r.error.code)
    r = tools.handle_invoke({ kind = "tools" }, { name = "pubTool", arguments = {} })
    assert.are.equal("tools", r.result.content[1].text)
  end)

  it("normalizes coroutine tool outcomes", function()
    assert.are.equal("x", tools.normalize_result(true, { content = { { text = "x" } } }).content[1].text)
    assert.are.equal(-32602, tools.normalize_result(false, { code = -32602, message = "bad" }).error.code)
    assert.are.equal("nope", tools.normalize_result(true, false, "nope").error.message)
    assert.is_not_nil(tools.normalize_result(true, 42).error)
  end)
end)

describe("register_tool", function()
  it("validates the spec and wraps string/table results", function()
    package.loaded["claudecode.tools.init"] = nil
    local tools = require("claudecode.tools.init")
    tools.tools = {}
    package.loaded["claudecode"] = nil
    local claudecode = require("claudecode")

    assert.has_error(function()
      claudecode.register_tool({ name = "bad name", description = "x", handler = function() end })
    end)

    claudecode.register_tool({
      name = "hello",
      description = "say hello",
      handler = function(input)
        return "hi " .. (input.who or "?")
      end,
    })
    local entry = tools.tools.hello
    assert.are.equal("public", entry.scope)
    local res = entry.handler({ who = "ann" })
    assert.are.equal("hi ann", res.content[1].text)
    package.loaded["claudecode"] = nil
  end)
end)
