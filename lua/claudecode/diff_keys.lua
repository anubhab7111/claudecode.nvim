---Buffer-local review keys for Claude's proposed edits.
---
---The keys mirror Vim's own diff verbs so there is nothing new to learn:
---
---| key  | two-pane layout                         | unified layout                 |
---|------|-----------------------------------------|--------------------------------|
---| `]c` | native: next change                     | next hunk                      |
---| `[c` | native: previous change                 | previous hunk                  |
---| `do` | native `:diffget`: reject this hunk     | reject this hunk               |
---| `dp` | keep this hunk and jump to the next     | keep this hunk, jump to next   |
---| `u`  | native undo                             | undo the last hunk decision    |
---| `:w` | accept the file with your hunk choices  | same                           |
---| `:q` | reject the whole file                   | same                           |
---| `<C-g>` | accept the file, jump to the next pending diff | same               |
---
---In the two-pane layout `]c`, `[c`, `do` and `u` are Vim's built-ins and are
---left unmapped. `dp` is remapped on the *proposed* buffer only, because
---native `:diffput` would modify your real file. Maps exist only on diff
---buffers and vanish with them, so there is no global cost.
---@module 'claudecode.diff_keys'
local M = {}

M.defaults = {
  next = "]c",
  prev = "[c",
  reject_hunk = "do",
  keep_hunk = "dp",
  undo = "u",
  accept_next = "<C-g>",
}

---Resolve the effective key table from config (`diff_opts.keys`); a key set to
---`false` is disabled.
---@param config table|nil Plugin config
---@return table keys
function M.resolve_keys(config)
  local user = config and config.diff_opts and config.diff_opts.keys
  if user == false then
    return {}
  end
  local keys = {}
  for action, lhs in pairs(M.defaults) do
    local v = lhs
    if type(user) == "table" and user[action] ~= nil then
      v = user[action]
    end
    if v then
      keys[action] = v
    end
  end
  return keys
end

local function cursor_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function goto_line(lnum)
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
  end
end

---Two-pane: jump to the next change without an error at the last one.
local function native_next_change()
  pcall(vim.cmd, "normal! ]c")
end

---Accept this diff and move to the next pending one.
---@param tab_name string
local function accept_and_next(tab_name)
  require("claudecode.diff").accept_and_next(tab_name)
end

local function map(bufnr, lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, { buffer = bufnr, nowait = true, silent = true, desc = "Claude diff: " .. desc })
end

---Attach review keys to a diff's proposed buffer.
---@param tab_name string
---@param bufnr integer The proposed (two-pane) or unified diff buffer
---@param layout "unified"|"split"
---@param config table|nil Plugin config
function M.attach(tab_name, bufnr, layout, config)
  if not (vim.keymap and vim.keymap.set) or not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local keys = M.resolve_keys(config)

  if layout == "unified" then
    local inline = require("claudecode.diff_inline")
    if keys.next then
      map(bufnr, keys.next, function()
        goto_line(inline.adjacent_hunk_line(tab_name, cursor_line(), 1))
      end, "next hunk")
    end
    if keys.prev then
      map(bufnr, keys.prev, function()
        goto_line(inline.adjacent_hunk_line(tab_name, cursor_line(), -1))
      end, "previous hunk")
    end
    if keys.reject_hunk then
      map(bufnr, keys.reject_hunk, function()
        inline.set_hunk_decision(tab_name, cursor_line(), "rejected")
      end, "reject hunk")
    end
    if keys.keep_hunk then
      map(bufnr, keys.keep_hunk, function()
        local lnum = cursor_line()
        inline.set_hunk_decision(tab_name, lnum, "kept")
        goto_line(inline.adjacent_hunk_line(tab_name, lnum, 1))
      end, "keep hunk, next")
    end
    if keys.undo then
      map(bufnr, keys.undo, function()
        goto_line(inline.undo_hunk_decision(tab_name))
      end, "undo hunk decision")
    end
  else
    -- Two-pane: ]c/[c/do/u are native. Only dp needs a safe replacement.
    if keys.keep_hunk then
      map(bufnr, keys.keep_hunk, native_next_change, "keep hunk, next")
    end
    -- Remapped navigation/reject keys (non-default lhs) still need wiring.
    if keys.next and keys.next ~= "]c" then
      map(bufnr, keys.next, native_next_change, "next change")
    end
    if keys.prev and keys.prev ~= "[c" then
      map(bufnr, keys.prev, function()
        pcall(vim.cmd, "normal! [c")
      end, "previous change")
    end
    if keys.reject_hunk and keys.reject_hunk ~= "do" then
      map(bufnr, keys.reject_hunk, function()
        pcall(vim.cmd, "diffget")
      end, "reject hunk")
    end
  end

  if keys.accept_next then
    map(bufnr, keys.accept_next, function()
      accept_and_next(tab_name)
    end, "accept file, next diff")
  end
end

return M
