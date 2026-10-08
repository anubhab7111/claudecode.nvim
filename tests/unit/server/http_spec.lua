require("tests.busted_setup")

local client_manager = require("claudecode.server.client")
local http = require("claudecode.server.http")

local TOKEN = "0123456789abcdef0123456789abcdef"

local function fake_handle()
  local h = { writes = {}, closed = false }
  function h:write(data, cb)
    self.writes[#self.writes + 1] = data
    if cb then
      cb()
    end
  end
  function h:is_closing()
    return self.closed
  end
  function h:close()
    self.closed = true
  end
  return h
end

local function post(path, body, headers)
  local lines = { "POST " .. path .. " HTTP/1.1", "Host: 127.0.0.1" }
  for k, v in pairs(headers or {}) do
    lines[#lines + 1] = k .. ": " .. v
  end
  if body then
    lines[#lines + 1] = "Content-Length: " .. #body
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or "")
end

local function status_of(handle)
  local resp = handle.writes[1] or ""
  return tonumber(resp:match("^HTTP/1%.1 (%d+)"))
end

describe("server http routing", function()
  local handle, client, seen

  local function feed(data)
    client_manager.process_data(client, data, function() end, function() end, function() end, TOKEN, {
      on_http = function(cl, req, respond)
        seen = req
        respond(200, '{"ok":true}')
      end,
    })
  end

  before_each(function()
    handle = fake_handle()
    client = client_manager.create_client(handle)
    seen = nil
  end)

  it("dispatches an authorized POST with its body and closes the socket", function()
    feed(post("/hook", '{"hook_event_name":"Stop"}', { ["x-claude-code-ide-authorization"] = TOKEN }))
    assert.are.equal("http", client.kind)
    assert.is_not_nil(seen)
    assert.are.equal("/hook", seen.path)
    assert.are.equal('{"hook_event_name":"Stop"}', seen.body)
    assert.are.equal(200, status_of(handle))
    assert.truthy(handle.writes[1]:find("Connection: close", 1, true))
    assert.is_true(handle.closed)
  end)

  it("waits for a body split across TCP reads", function()
    local body = '{"hook_event_name":"PostToolUse","x":"' .. string.rep("a", 50) .. '"}'
    local full = post("/hook", body, { ["x-claude-code-ide-authorization"] = TOKEN })
    feed(full:sub(1, #full - 20))
    assert.is_nil(seen)
    feed(full:sub(#full - 19))
    assert.are.equal(body, seen.body)
  end)

  it("rejects a missing or wrong token with 401 and never dispatches", function()
    feed(post("/hook", "{}", { ["x-claude-code-ide-authorization"] = "wrong-token-value" }))
    assert.are.equal(401, status_of(handle))
    assert.is_nil(seen)

    handle = fake_handle()
    client = client_manager.create_client(handle)
    feed(post("/hook", "{}", {}))
    assert.are.equal(401, status_of(handle))
  end)

  it("rejects oversized bodies with 413", function()
    feed(
      "POST /hook HTTP/1.1\r\nx-claude-code-ide-authorization: "
        .. TOKEN
        .. "\r\nContent-Length: "
        .. (http.MAX_BODY + 1)
        .. "\r\n\r\n"
    )
    assert.are.equal(413, status_of(handle))
    assert.is_nil(seen)
  end)

  it("requires Content-Length", function()
    feed("POST /hook HTTP/1.1\r\nx-claude-code-ide-authorization: " .. TOKEN .. "\r\n\r\n")
    assert.are.equal(411, status_of(handle))
  end)

  it("answers 404 when no HTTP handler is registered", function()
    client_manager.process_data(
      client,
      post("/hook", "{}", { ["x-claude-code-ide-authorization"] = TOKEN }),
      function() end,
      function() end,
      function() end,
      TOKEN,
      nil
    )
    assert.are.equal(404, status_of(handle))
  end)

  it("tags WebSocket upgrades on /mcp as tools clients and others as ide", function()
    local upgrade = function(path)
      return "GET "
        .. path
        .. " HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        .. "x-claude-code-ide-authorization: "
        .. TOKEN
        .. "\r\n\r\n"
    end
    local handshaken = {}
    local function connect(path)
      local h = fake_handle()
      local c = client_manager.create_client(h)
      client_manager.process_data(c, upgrade(path), function() end, function() end, function() end, TOKEN, {
        on_handshake = function(cl)
          handshaken[#handshaken + 1] = cl.kind
        end,
      })
      return c
    end

    local tools_client = connect("/mcp")
    local ide_client = connect("/")
    assert.are.equal("tools", tools_client.kind)
    assert.are.equal("ide", ide_client.kind)
    assert.is_true(tools_client.handshake_complete)
    assert.are.same({ "tools", "ide" }, handshaken)
  end)
end)

describe("tcp broadcast", function()
  it("skips tools clients", function()
    local tcp = require("claudecode.server.tcp")
    local sent = {}
    local original = client_manager.send_message
    client_manager.send_message = function(cl, msg)
      sent[#sent + 1] = cl.id
    end
    local server = {
      clients = {
        a = { id = "a", kind = "ide" },
        b = { id = "b", kind = "tools" },
        c = { id = "c" },
      },
    }
    tcp.broadcast(server, "{}")
    client_manager.send_message = original
    table.sort(sent)
    assert.are.same({ "a", "c" }, sent)
  end)
end)
