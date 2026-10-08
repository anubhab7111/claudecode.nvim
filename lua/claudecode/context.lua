---Small, lazily-loaded helpers that type context into the Claude prompt.
---
---Everything here writes to the Claude terminal through
---`terminal.send_to_terminal`, so it works with the in-editor providers
---(native/snacks). Nothing is loaded until one of the commands runs.
---@module 'claudecode.context'
local M = {}

local logger = require("claudecode.logger")

---Format a buffer + line range as an @-reference the CLI understands
---(e.g. `@lua/foo.lua#L5-10`, `@lua/foo.lua#L7`, or `@lua/foo.lua`).
---@param bufnr integer
---@param line1 integer|nil 1-based first line
---@param line2 integer|nil 1-based last line
---@return string|nil reference, string|nil err
function M.reference_for(bufnr, line1, line2)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == "" then
    return nil, "Buffer has no file name"
  end
  if vim.api.nvim_buf_get_option(bufnr, "buftype") ~= "" then
    return nil, "Not a file buffer"
  end

  local path = name
  local ok, formatted = pcall(function()
    return require("claudecode")._format_path_for_at_mention(name)
  end)
  if ok and type(formatted) == "string" then
    path = formatted
  end

  local ref = "@" .. path
  if line1 and line2 then
    if line1 > line2 then
      line1, line2 = line2, line1
    end
    if line1 == line2 then
      ref = ref .. "#L" .. line1
    else
      ref = ref .. "#L" .. line1 .. "-" .. line2
    end
  end
  return ref, nil
end

---Insert an @-reference for the current buffer (and range) into the prompt
---without submitting it.
---@param opts {line1: integer, line2: integer, range: integer}|nil Command opts
---@return boolean ok
function M.insert_reference(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local line1, line2
  if opts and opts.range and opts.range > 0 then
    line1, line2 = opts.line1, opts.line2
  end
  local ref, err = M.reference_for(bufnr, line1, line2)
  if not ref then
    logger.warn("context", "Cannot insert reference: " .. tostring(err))
    return false
  end
  return require("claudecode.terminal").send_to_terminal(ref .. " ", { submit = false })
end

---Send an instruction about a range of the current buffer, e.g.
---`:'<,'>ClaudeCodeEdit make this function async`. Claude's edit comes back
---through the normal openDiff review.
---@param opts {line1: integer, line2: integer, range: integer, args: string}
---@return boolean ok
function M.edit(opts)
  local instruction = opts and opts.args or ""
  if instruction == "" then
    logger.warn("context", "ClaudeCodeEdit: provide an instruction, e.g. :'<,'>ClaudeCodeEdit add error handling")
    return false
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local line1, line2
  if opts.range and opts.range > 0 then
    line1, line2 = opts.line1, opts.line2
  end
  local ref, err = M.reference_for(bufnr, line1, line2)
  if not ref then
    logger.warn("context", "Cannot reference buffer: " .. tostring(err))
    return false
  end
  return require("claudecode.terminal").send_to_terminal("Edit " .. ref .. ": " .. instruction, { submit = true })
end

---List terminal buffers other than the Claude terminal(s).
---@return integer[] bufnrs
function M.other_terminal_buffers()
  local claude_buf = require("claudecode.terminal").get_active_terminal_bufnr()
  local result = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if
      b ~= claude_buf
      and vim.api.nvim_buf_is_loaded(b)
      and vim.api.nvim_buf_get_option(b, "buftype") == "terminal"
      and not vim.b[b].claudecode_terminal
    then
      result[#result + 1] = b
    end
  end
  return result
end

---Collect the last `max_lines` non-blank lines of a buffer.
---@param bufnr integer
---@param max_lines integer
---@return string[] lines
function M.tail_lines(bufnr, max_lines)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, math.max(0, count - max_lines * 2), count, false)
  -- Terminal buffers pad with empty rows below the prompt; drop trailing blanks.
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    lines[#lines] = nil
  end
  if #lines > max_lines then
    local tail = {}
    for i = #lines - max_lines + 1, #lines do
      tail[#tail + 1] = lines[i]
    end
    lines = tail
  end
  return lines
end

---Paste another terminal's recent output into the Claude prompt (not submitted).
---@param bufnr integer|nil Terminal buffer; prompts when nil and several exist
---@param max_lines integer|nil Defaults to config.terminal_context_lines (200)
function M.send_terminal_output(bufnr, max_lines)
  if not max_lines then
    local main = package.loaded["claudecode"]
    max_lines = (main and main.state and main.state.config and main.state.config.terminal_context_lines) or 200
  end

  local function send(b)
    if not (b and vim.api.nvim_buf_is_valid(b)) then
      logger.warn("context", "Invalid terminal buffer")
      return
    end
    local lines = M.tail_lines(b, max_lines)
    if #lines == 0 then
      logger.warn("context", "Terminal buffer is empty")
      return
    end
    local title = vim.b[b].term_title or vim.api.nvim_buf_get_name(b)
    local text = "Output of terminal `" .. title .. "`:\n```\n" .. table.concat(lines, "\n") .. "\n```\n"
    require("claudecode.terminal").send_to_terminal(text, { submit = false })
  end

  if bufnr then
    send(bufnr)
    return
  end

  local candidates = M.other_terminal_buffers()
  if #candidates == 0 then
    logger.warn("context", "No other terminal buffers found")
    return
  elseif #candidates == 1 then
    send(candidates[1])
    return
  end
  vim.ui.select(candidates, {
    prompt = "Send output of terminal:",
    format_item = function(b)
      return (vim.b[b].term_title or vim.api.nvim_buf_get_name(b)) .. " [" .. b .. "]"
    end,
  }, function(choice)
    if choice then
      send(choice)
    end
  end)
end

---Cycle Claude's permission mode (same as pressing Shift+Tab in the TUI).
---@return boolean ok
function M.cycle_mode()
  return require("claudecode.terminal").send_to_terminal("\27[Z", { submit = false })
end

return M
