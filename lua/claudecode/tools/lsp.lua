---Read-only LSP tools exposed to Claude on the `nvim` MCP server.
---
---They reuse the language servers already running in Neovim, so Claude gets
---your exact LSP setup without spawning duplicate servers. A file that is not
---loaded is only loaded (hidden) when a running client already covers it;
---no new language server is ever started on Claude's behalf.
---@module 'claudecode.tools.lsp'
local M = {}

local tools_mod = function()
  return require("claudecode.tools.init")
end

M.MAX_CHARS = 20000

local function options()
  local main = package.loaded["claudecode"]
  local cfg = main and main.state and main.state.config or {}
  local o = type(cfg.lsp_tools) == "table" and cfg.lsp_tools or {}
  return {
    max_results = o.max_results or 100,
    timeout_ms = o.timeout_ms or 5000,
  }
end

local function get_clients(filter)
  if vim.lsp.get_clients then
    return vim.lsp.get_clients(filter)
  end
  return vim.lsp.get_active_clients(filter) ---@diagnostic disable-line: deprecated
end

local function invalid(msg)
  error({ code = -32602, message = msg })
end

local function relpath(path)
  local cwd = vim.fn.getcwd()
  if vim.fs and vim.fs.relpath then
    local rel = vim.fs.relpath(cwd, path)
    if rel then
      return rel
    end
  elseif path:sub(1, #cwd + 1) == cwd .. "/" then
    return path:sub(#cwd + 2)
  end
  return path
end

local function result_json(data)
  local text = vim.json.encode(data)
  if #text > M.MAX_CHARS then
    text = text:sub(1, M.MAX_CHARS) .. "…(truncated)"
  end
  return { content = { { type = "text", text = text } } }
end

---Find a loaded buffer for a path, or load it hidden when an already-running
---LSP client covers the file (its root contains the path and it handles the
---filetype). Returns bufnr and whether we loaded it.
---@param path string
---@return integer|nil bufnr, boolean loaded_by_us
function M.buffer_for(path)
  local full = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == full then
      return b, false
    end
  end
  if vim.fn.filereadable(full) ~= 1 then
    invalid("File not found: " .. path)
  end
  local ft = vim.filetype and vim.filetype.match({ filename = full }) or nil
  local covered = false
  for _, c in ipairs(get_clients()) do
    local root = c.config and c.config.root_dir
    local fts = c.config and c.config.filetypes
    local ft_ok = not fts or (ft and vim.tbl_contains(fts, ft))
    if root and full:sub(1, #root) == root and ft_ok then
      covered = true
      break
    end
  end
  if not covered then
    return nil, false
  end
  local b = vim.fn.bufadd(full)
  vim.fn.bufload(b)
  vim.api.nvim_buf_set_option(b, "buflisted", false)
  return b, true
end

---`client:supports_method(m)` on Neovim >= 0.11, `client.supports_method(m)` before.
local function supports(c, method)
  if not method or not c.supports_method then
    return true
  end
  local ok, r = pcall(function()
    return c:supports_method(method)
  end)
  if ok and type(r) == "boolean" then
    return r
  end
  ok, r = pcall(c.supports_method, method)
  return not ok or r == true
end

---Wait (inside the coroutine) until `bufnr` has an attached client supporting `method`.
local function wait_for_client(bufnr, method, timeout_ms)
  local function has_client()
    for _, c in ipairs(get_clients({ bufnr = bufnr })) do
      if supports(c, method) then
        return c
      end
    end
    return nil
  end
  local c = has_client()
  if c then
    return c
  end
  tools_mod().await(function(done)
    local uv = vim.uv or vim.loop
    local t = uv.new_timer()
    local tries = 0
    t:start(
      100,
      100,
      vim.schedule_wrap(function()
        tries = tries + 1
        if has_client() or tries * 100 >= timeout_ms then
          t:stop()
          t:close()
          done()
        end
      end)
    )
  end, timeout_ms + 500)
  return has_client()
end

---Resolve input → (bufnr, client, position params).
local function prepare(input, method, need_position)
  if type(input) ~= "table" or type(input.filePath) ~= "string" or input.filePath == "" then
    invalid("filePath is required")
  end
  local opts = options()
  local bufnr, loaded = M.buffer_for(input.filePath)
  if not bufnr then
    invalid(
      "No running language server covers "
        .. input.filePath
        .. ". Open a file of this project in Neovim first (Claude's tools never start new servers)."
    )
  end
  local client = wait_for_client(bufnr, method, opts.timeout_ms)
  if not client then
    invalid("No language server attached to " .. input.filePath .. " supports " .. method)
  end
  local enc = client.offset_encoding or "utf-16"
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
  if need_position then
    local line = tonumber(input.line)
    if not line or line < 1 then
      invalid("line (1-based) is required")
    end
    local row = line - 1
    local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
    if not text then
      invalid("line " .. line .. " is past the end of " .. input.filePath)
    end
    local col
    if type(input.symbol) == "string" and input.symbol ~= "" then
      local s = text:find(input.symbol, 1, true)
      if not s then
        invalid("symbol '" .. input.symbol .. "' not found on line " .. line)
      end
      col = s - 1
    elseif tonumber(input.character) then
      col = math.max(0, tonumber(input.character) - 1)
    else
      col = (text:find("%S") or 1) - 1
    end
    local ok, offset = pcall(vim.lsp.util.character_offset, bufnr, row, col, enc)
    params.position = { line = row, character = ok and offset or col }
  end
  return bufnr, client, params, enc, loaded, opts
end

local function request(bufnr, method, params, timeout_ms)
  local results, err = tools_mod().await(function(done)
    vim.lsp.buf_request_all(bufnr, method, params, function(res)
      done(res)
    end)
  end, timeout_ms)
  if not results then
    error({ code = -32000, message = "LSP request " .. method .. " failed: " .. tostring(err) })
  end
  local merged = {}
  for _, r in pairs(results) do
    local e = r.err or r.error
    if not e and r.result ~= nil and r.result ~= vim.NIL then
      merged[#merged + 1] = r.result
    end
  end
  return merged
end

local function cleanup(bufnr, loaded)
  if loaded and vim.api.nvim_buf_is_valid(bufnr) then
    vim.schedule(function()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end
end

local function items_out(items, max)
  local out = {}
  for i, it in ipairs(items) do
    if i > max then
      break
    end
    out[#out + 1] = {
      file = relpath(it.filename or ""),
      line = it.lnum,
      column = it.col,
      text = it.text and vim.trim(it.text) or nil,
    }
  end
  return out, #items
end

local function location_tool(name, method, description)
  return {
    name = name,
    scope = "public",
    requires_coroutine = true,
    schema = {
      description = description,
      inputSchema = {
        type = "object",
        properties = {
          filePath = { type = "string", description = "Path of the file (absolute or relative to the workspace)" },
          line = { type = "integer", description = "1-based line number of the symbol" },
          symbol = { type = "string", description = "The symbol text on that line (preferred over character)" },
          character = { type = "integer", description = "1-based column, if symbol is not given" },
        },
        required = { "filePath", "line" },
      },
    },
    handler = function(input)
      local bufnr, _, params, enc, loaded, opts = prepare(input, method, true)
      if method == "textDocument/references" then
        params.context = { includeDeclaration = input.includeDeclaration == true }
      end
      local merged = request(bufnr, method, params, opts.timeout_ms)
      cleanup(bufnr, loaded)
      local locations = {}
      for _, res in ipairs(merged) do
        if res.uri or res.targetUri then
          locations[#locations + 1] = res
        else
          vim.list_extend(locations, res)
        end
      end
      local items = vim.lsp.util.locations_to_items(locations, enc)
      local out, total = items_out(items, opts.max_results)
      return result_json({ results = out, total = total })
    end,
  }
end

local function hover_text(contents)
  if type(contents) == "string" then
    return contents
  end
  if type(contents) ~= "table" then
    return ""
  end
  if contents.value then
    return contents.value
  end
  local parts = {}
  for _, c in ipairs(contents) do
    parts[#parts + 1] = hover_text(c)
  end
  return table.concat(parts, "\n\n")
end

---@return table[] tool modules
function M.tools()
  return {
    location_tool(
      "lspDefinition",
      "textDocument/definition",
      "Find where a symbol is defined, using the language servers running in the user's Neovim."
    ),
    location_tool(
      "lspReferences",
      "textDocument/references",
      "Find all references to a symbol, using the language servers running in the user's Neovim."
    ),
    {
      name = "lspHover",
      scope = "public",
      requires_coroutine = true,
      schema = {
        description = "Get type information and documentation for a symbol (LSP hover) from the user's Neovim.",
        inputSchema = {
          type = "object",
          properties = {
            filePath = { type = "string" },
            line = { type = "integer", description = "1-based line" },
            symbol = { type = "string", description = "Symbol text on that line" },
            character = { type = "integer", description = "1-based column, if symbol is not given" },
          },
          required = { "filePath", "line" },
        },
      },
      handler = function(input)
        local bufnr, _, params, _, loaded, opts = prepare(input, "textDocument/hover", true)
        local merged = request(bufnr, "textDocument/hover", params, opts.timeout_ms)
        cleanup(bufnr, loaded)
        local texts = {}
        for _, res in ipairs(merged) do
          local t = vim.trim(hover_text(res.contents))
          if t ~= "" then
            texts[#texts + 1] = t
          end
        end
        return result_json({ hover = table.concat(texts, "\n\n---\n\n") })
      end,
    },
    {
      name = "lspDocumentSymbols",
      scope = "public",
      requires_coroutine = true,
      schema = {
        description = "List the symbols (functions, classes, variables) defined in a file, from the user's Neovim LSP.",
        inputSchema = {
          type = "object",
          properties = { filePath = { type = "string" } },
          required = { "filePath" },
        },
      },
      handler = function(input)
        local bufnr, _, params, enc, loaded, opts = prepare(input, "textDocument/documentSymbol", false)
        local merged = request(bufnr, "textDocument/documentSymbol", params, opts.timeout_ms)
        local symbols = {}
        for _, res in ipairs(merged) do
          vim.list_extend(symbols, res)
        end
        local items = vim.lsp.util.symbols_to_items(symbols, bufnr, enc)
        cleanup(bufnr, loaded)
        local out, total = items_out(items, opts.max_results)
        return result_json({ symbols = out, total = total })
      end,
    },
    {
      name = "lspWorkspaceSymbols",
      scope = "public",
      requires_coroutine = true,
      schema = {
        description = "Search symbols across the whole project by name, using the language servers running in the user's Neovim.",
        inputSchema = {
          type = "object",
          properties = {
            query = { type = "string", description = "Symbol name or prefix" },
            filePath = {
              type = "string",
              description = "Optional file whose language server to use (defaults to any attached server)",
            },
          },
          required = { "query" },
        },
      },
      handler = function(input)
        if type(input) ~= "table" or type(input.query) ~= "string" then
          invalid("query is required")
        end
        local opts = options()
        local bufnr, loaded
        if type(input.filePath) == "string" and input.filePath ~= "" then
          bufnr, loaded = M.buffer_for(input.filePath)
        else
          for _, c in ipairs(get_clients()) do
            bufnr = next(c.attached_buffers or {})
            if bufnr then
              break
            end
          end
        end
        if not bufnr then
          invalid("No language server is running in Neovim")
        end
        local client = wait_for_client(bufnr, "workspace/symbol", opts.timeout_ms)
        local enc = client and client.offset_encoding or "utf-16"
        local merged = request(bufnr, "workspace/symbol", { query = input.query }, opts.timeout_ms)
        local symbols = {}
        for _, res in ipairs(merged) do
          vim.list_extend(symbols, res)
        end
        local items = vim.lsp.util.symbols_to_items(symbols, bufnr, enc)
        cleanup(bufnr, loaded)
        local out, total = items_out(items, opts.max_results)
        return result_json({ symbols = out, total = total })
      end,
    },
  }
end

return M
