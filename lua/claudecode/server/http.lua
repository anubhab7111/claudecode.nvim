---@brief Minimal one-shot HTTP/1.1 request handling for the IDE server port.
---
--- Claude Code's HTTP hooks POST a JSON body to `http://127.0.0.1:<port>/hook`.
--- Rather than opening a second listener, the existing TCP server routes any
--- non-GET request here before the WebSocket handshake. Each connection carries
--- exactly one request: we always answer with `Connection: close` and close the
--- socket afterwards, so no keep-alive bookkeeping is needed.
local utils = require("claudecode.server.utils")

local M = {}

---Maximum accepted request body size in bytes (hook payloads are small JSON).
M.MAX_BODY = 1024 * 1024

local STATUS_TEXT = {
  [200] = "OK",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [411] = "Length Required",
  [413] = "Payload Too Large",
  [500] = "Internal Server Error",
}

---Build a complete HTTP response string.
---@param status number HTTP status code
---@param body string|nil Response body (JSON text)
---@return string response
function M.build_response(status, body)
  body = body or ""
  return table.concat({
    "HTTP/1.1 " .. status .. " " .. (STATUS_TEXT[status] or "Error"),
    "Content-Type: application/json",
    "Content-Length: " .. #body,
    "Connection: close",
    "",
    body,
  }, "\r\n")
end

---Check the auth header against the expected token.
---@param headers table<string,string> Lower-cased request headers
---@param expected string|nil Expected token; nil disables auth
---@return boolean ok
function M.is_authorized(headers, expected)
  if not expected then
    return true
  end
  local provided = headers["x-claude-code-ide-authorization"]
  if type(provided) ~= "string" or provided == "" or #provided > 500 then
    return false
  end
  return utils.constant_time_compare(provided, expected)
end

---Write a response and close the connection.
---@param client table The client whose tcp_handle receives the response
---@param status number HTTP status code
---@param body string|nil Response body
function M.respond(client, status, body)
  if client.http_responded then
    return
  end
  client.http_responded = true
  client.state = "closing"
  local handle = client.tcp_handle
  if handle:is_closing() then
    return
  end
  handle:write(M.build_response(status, body), function()
    client.state = "closed"
    if not handle:is_closing() then
      handle:close()
    end
  end)
end

---Begin handling an HTTP request whose headers have been fully received.
---The body may still be incomplete; `M.feed` is called with later data.
---@param client table The client (kind is set to "http")
---@param request string The request line + headers (terminated by CRLFCRLF)
---@param remaining string Bytes received after the headers
---@param auth_token string|nil Expected auth token
---@param on_request fun(client: table, req: table, respond: fun(status: number, body: string|nil))|nil
function M.begin(client, request, remaining, auth_token, on_request)
  client.kind = "http"
  local method, path = request:match("^(%S+)%s+(%S+)")
  local headers = utils.parse_http_headers(request)

  if method ~= "POST" then
    M.respond(client, 405, '{"error":"method not allowed"}')
    return
  end
  if not M.is_authorized(headers, auth_token) then
    M.respond(client, 401, '{"error":"unauthorized"}')
    return
  end

  local length = tonumber(headers["content-length"] or "")
  if not length or length < 0 then
    M.respond(client, 411, '{"error":"content-length required"}')
    return
  end
  if length > M.MAX_BODY then
    M.respond(client, 413, '{"error":"payload too large"}')
    return
  end

  client.http = {
    method = method,
    path = (path or "/"):gsub("%?.*$", ""),
    headers = headers,
    length = length,
    chunks = { remaining },
    received = #remaining,
    on_request = on_request,
  }
  client.buffer = ""
  M._maybe_dispatch(client)
end

---Feed more body bytes for an in-flight HTTP request.
---@param client table
---@param data string
function M.feed(client, data)
  local req = client.http
  if not req or client.http_responded then
    return
  end
  if #data > 0 then
    req.chunks[#req.chunks + 1] = data
    req.received = req.received + #data
  end
  M._maybe_dispatch(client)
end

---Dispatch once the full body has arrived.
---@param client table
function M._maybe_dispatch(client)
  local req = client.http
  if not req or req.dispatched or req.received < req.length then
    return
  end
  req.dispatched = true
  local body = table.concat(req.chunks):sub(1, req.length)
  req.chunks = nil

  local function respond(status, resp_body)
    -- May be called from any context; libuv writes are safe outside fast-event
    -- restrictions, but keep it on the main loop for consistent ordering.
    if vim.in_fast_event and vim.in_fast_event() then
      vim.schedule(function()
        M.respond(client, status, resp_body)
      end)
    else
      M.respond(client, status, resp_body)
    end
  end

  if not req.on_request then
    respond(404, '{"error":"not found"}')
    return
  end

  -- TCP read callbacks run in a fast-event context; hand off to the main loop.
  vim.schedule(function()
    local ok, err = pcall(req.on_request, client, {
      method = req.method,
      path = req.path,
      headers = req.headers,
      body = body,
    }, respond)
    if not ok then
      require("claudecode.logger").error("http", "Request handler failed: " .. tostring(err))
      respond(500, '{"error":"internal error"}')
    end
  end)
end

return M
