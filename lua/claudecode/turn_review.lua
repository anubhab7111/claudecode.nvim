---Review everything Claude changed in its last turn, even in auto-accept mode.
---
---Right before Claude's first edit to a file in a turn (PreToolUse hook) we keep
---that file's content in memory; the snapshots are dropped when you send the
---next prompt. Nothing else is tracked, so the cost is one file read per file
---Claude touches.
---
---  :ClaudeCodeReview         quickfix list of every changed hunk
---  :ClaudeCodeReviewDiff     side-by-side diff of the current file vs. its
---                            snapshot (use ]c / do / dp / u as usual)
---  :ClaudeCodeReviewRevert   restore the snapshot for the hunk under the cursor
---@module 'claudecode.turn_review'
local M = {}

local logger = require("claudecode.logger")

M.MAX_FILE_BYTES = 2 * 1024 * 1024

---@type table<string, {text: string, existed: boolean}>
M.snapshots = {}
---@type string[] Files in first-touched order
M.order = {}

local EDIT_TOOLS = { Edit = true, Write = true, MultiEdit = true, NotebookEdit = true }

local function get_diff_fn()
  return (vim.text and vim.text.diff) or vim.diff
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local size = f:seek("end")
  if size and size > M.MAX_FILE_BYTES then
    f:close()
    return false
  end
  f:seek("set")
  local text = f:read("*a")
  f:close()
  return text
end

local function split(text)
  if text == nil or text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

---Forget the previous turn (called on UserPromptSubmit).
function M.reset()
  M.snapshots = {}
  M.order = {}
end

---PreToolUse listener: snapshot a file the first time Claude edits it this turn.
---@param payload table
function M.snapshot(payload)
  if not EDIT_TOOLS[payload.tool_name] or type(payload.tool_input) ~= "table" then
    return
  end
  local path = payload.tool_input.file_path or payload.tool_input.notebook_path
  if type(path) ~= "string" or path == "" or M.snapshots[path] then
    return
  end
  local text = read_file(path)
  if text == false then
    logger.debug("turn_review", "skipping large file " .. path)
    return
  end
  M.snapshots[path] = { text = text or "", existed = text ~= nil }
  M.order[#M.order + 1] = path
end

---Hunks between a snapshot and the given current text.
---@param before string
---@param after string
---@return integer[][] hunks {start_a, count_a, start_b, count_b}
function M.hunks(before, after)
  local fn = get_diff_fn()
  if not fn then
    return {}
  end
  return fn(before, after, { result_type = "indices" }) or {}
end

---Build quickfix items for every hunk Claude changed this turn.
---@return table[] items
function M.items()
  local items = {}
  for _, path in ipairs(M.order) do
    local snap = M.snapshots[path]
    local now = read_file(path)
    if now == nil and snap.existed then
      items[#items + 1] = { filename = path, lnum = 1, col = 1, text = "Claude deleted this file" }
    elseif now and not snap.existed then
      items[#items + 1] = {
        filename = path,
        lnum = 1,
        col = 1,
        text = string.format("Claude created this file (%d line(s))", #split(now)),
      }
    elseif now and now ~= snap.text then
      local after_lines = split(now)
      for _, h in ipairs(M.hunks(snap.text, now)) do
        local start_b, count_b, count_a = h[3], h[4], h[2]
        local lnum = math.max(1, count_b > 0 and start_b or start_b + 1)
        local kind = (count_a == 0 and "added") or (count_b == 0 and "removed") or "changed"
        local first = after_lines[lnum] or ""
        items[#items + 1] = {
          filename = path,
          lnum = math.min(lnum, math.max(1, #after_lines)),
          col = 1,
          text = string.format(
            "Claude %s %d→%d line(s)%s",
            kind,
            count_a,
            count_b,
            first ~= "" and (": " .. first) or ""
          ),
          user_data = { claudecode_turn = true },
        }
      end
    end
  end
  return items
end

---Populate and open the quickfix list.
---@return integer count
function M.open_quickfix()
  local items = M.items()
  if #items == 0 then
    vim.notify("Claude made no file changes in its last turn", vim.log.levels.INFO)
    return 0
  end
  vim.fn.setqflist({}, " ", { title = "Claude turn (" .. #M.order .. " file(s))", items = items })
  vim.cmd("copen")
  return #items
end

---Current buffer's snapshot, if Claude edited this file in the last turn.
---@return string|nil path, table|nil snapshot
local function current_snapshot()
  local path = vim.api.nvim_buf_get_name(0)
  local snap = M.snapshots[path]
  if not snap then
    vim.notify("Claude did not change this file in its last turn", vim.log.levels.WARN)
    return nil, nil
  end
  return path, snap
end

---Restore the snapshot lines for the hunk under the cursor (an ordinary,
---undoable buffer edit; save to keep it).
---@return boolean reverted
function M.revert_hunk_at_cursor()
  local _, snap = current_snapshot()
  if not snap then
    return false
  end
  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local now = table.concat(buf_lines, "\n") .. "\n"
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local chosen
  for _, h in ipairs(M.hunks(snap.text, now)) do
    local s = h[4] > 0 and h[3] or h[3] + 1
    local e = h[4] > 0 and (h[3] + h[4] - 1) or s
    if lnum >= s and lnum <= e then
      chosen = h
      break
    end
    if s <= lnum then
      chosen = h -- nearest hunk above, like Vim's do/dp
    end
  end
  if not chosen then
    vim.notify("No Claude change at the cursor", vim.log.levels.INFO)
    return false
  end
  local before = split(snap.text)
  local old = {}
  for i = chosen[1], chosen[1] + chosen[2] - 1 do
    old[#old + 1] = before[i]
  end
  local from = chosen[4] > 0 and (chosen[3] - 1) or chosen[3]
  vim.api.nvim_buf_set_lines(0, from, from + chosen[4], false, old)
  return true
end

---Open a native side-by-side diff of the current file against its snapshot.
---@return boolean opened
function M.open_diff()
  local path, snap = current_snapshot()
  if not snap then
    return false
  end
  local file_win = vim.api.nvim_get_current_win()
  local ft = vim.api.nvim_buf_get_option(0, "filetype")
  vim.cmd("leftabove vsplit")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, split(snap.text))
  pcall(vim.api.nvim_buf_set_name, buf, "claudecode://before/" .. vim.fn.fnamemodify(path, ":t"))
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  if ft and ft ~= "" then
    vim.api.nvim_buf_set_option(buf, "filetype", ft)
  end
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(file_win)
  vim.cmd("diffthis")
  return true
end

return M
