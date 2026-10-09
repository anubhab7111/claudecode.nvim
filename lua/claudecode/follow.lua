---Keep buffers in sync with files Claude changes on disk.
---
---Neovim only re-reads a changed file on FocusGained, `:checktime` or when the
---buffer is re-entered with `:edit`, so a file open in a window goes stale while
---Claude works in the terminal next to it. This module reloads unmodified file
---buffers (regardless of 'autoread') when:
---  * a PostToolUse hook reports an edit tool on that file (plus one re-check
---    shortly after, for formatters run by the user's own hooks),
---  * a Bash tool call or a turn/subagent finishes (every loaded file buffer),
---  * the user leaves the Claude terminal or enters a buffer (fallback that also
---    works without hooks).
---Each check is one stat() per buffer; nothing polls.
---@module 'claudecode.follow'
local M = {}

local RECHECK_MS = 500

---Whether `b` is a normal, loaded file buffer.
---@param b integer
---@return boolean
local function is_file_buffer(b)
  if not vim.api.nvim_buf_is_loaded(b) then
    return false
  end
  if vim.api.nvim_buf_get_option(b, "buftype") ~= "" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(b)
  return name ~= "" and not name:match("^%a[%w+.-]*://")
end

---Re-read buffer `b` from disk if the file changed and the buffer has no
---unsaved edits. Forces 'autoread' for this check so users with `noautoread`
---get a reload instead of a W11 prompt.
---@param b integer
---@return boolean checked False when skipped (invalid or modified)
function M.reload(b)
  if not is_file_buffer(b) or vim.api.nvim_buf_get_option(b, "modified") then
    return false
  end
  pcall(vim.api.nvim_buf_call, b, function()
    vim.cmd("setlocal autoread")
    pcall(vim.cmd, "silent! checktime " .. b)
    if vim.api.nvim_buf_is_valid(b) then
      vim.cmd("setlocal autoread<")
    end
  end)
  return true
end

---Check every loaded file buffer.
function M.check_all()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    M.reload(b)
  end
end

---Check the buffers shown in windows of the current tabpage.
function M.check_visible()
  local seen = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if not seen[b] then
      seen[b] = true
      M.reload(b)
    end
  end
end

local warned = {}

---Claude changed `b`'s file but the buffer has unsaved edits: say so once per
---change instead of silently showing stale text.
---@param b integer
local function warn_conflict(b)
  local name = vim.api.nvim_buf_get_name(b)
  local uv = vim.uv or vim.loop
  local stat = uv and uv.fs_stat and uv.fs_stat(name)
  local key = name
    .. ":"
    .. tostring(stat and stat.mtime and stat.mtime.sec)
    .. ":"
    .. tostring(stat and stat.mtime and stat.mtime.nsec)
  if warned[key] then
    return
  end
  warned[key] = true
  vim.notify(
    ("Claude changed %s, but the buffer has unsaved edits. :e! loads Claude's version, :w keeps yours."):format(
      vim.fn.fnamemodify(name, ":~:.")
    ),
    vim.log.levels.WARN,
    { title = "Claude Code" }
  )
end

---Claude edited the file shown in buffer `b`: reload it now and once more
---shortly after.
---@param b integer
function M.file_changed(b)
  if vim.api.nvim_buf_get_option(b, "modified") then
    warn_conflict(b)
    return
  end
  M.reload(b)
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(b) then
      M.reload(b)
    end
  end, RECHECK_MS)
end

---Install the fallback autocmds (leaving the Claude terminal, entering a buffer).
function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("ClaudeCodeFollow", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = function(args)
      M.reload(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "TermLeave", "BufLeave" }, {
    group = group,
    callback = function(args)
      if vim.b[args.buf] and vim.b[args.buf].claudecode_terminal then
        vim.schedule(M.check_visible)
      end
    end,
  })
end

return M
