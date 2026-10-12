---Key handling inside Claude terminal buffers.
---
---Claude Code is a full TUI with its own shortcuts (double Escape to rewind,
---Ctrl-_ to undo, Ctrl-R history search, ...). Global or plugin terminal-mode
---mappings that use the same keys would swallow them, so every Claude key is
---mapped buffer-locally to itself (`nowait`), which beats any global mapping
---and any longer mapping starting with that key.
---
---Claude prints its transcript into the terminal's scrollback, so scrolling the
---chat means leaving terminal mode. The scroll keys do that and then run the
---user's own normal-mode key (so smooth-scroll plugins apply); scrolling back
---down to the bottom returns to typing.
---@module 'claudecode.terminal_keys'
local M = {}

---Keys Claude Code handles itself. Not listed on purpose: <C-u> and <PageUp>
---(scroll), <C-z> (suspend is ignored), <C-\> (Neovim's terminal escape prefix)
---and <C-x> (commonly the user's own "leave terminal mode" key; add it to
---`passthrough` to get Claude's Ctrl-X chords back).
M.CLAUDE_KEYS = {
  "<Esc>",
  "<S-Tab>",
  "<C-_>",
  "<C-/>",
  "<C-a>",
  "<C-b>",
  "<C-c>",
  "<C-d>",
  "<C-e>",
  "<C-f>",
  "<C-g>",
  "<C-j>",
  "<C-k>",
  "<C-l>",
  "<C-n>",
  "<C-o>",
  "<C-p>",
  "<C-r>",
  "<C-s>",
  "<C-t>",
  "<C-v>",
  "<C-w>",
  "<C-y>",
  "<M-b>",
  "<M-d>",
  "<M-f>",
  "<M-m>",
  "<M-o>",
  "<M-p>",
  "<M-t>",
  "<M-v>",
  "<M-y>",
}

M.defaults = {
  passthrough = true, -- true = M.CLAUDE_KEYS, false = none, or a list of keys
  scroll_up = { "<C-u>", "<PageUp>" }, -- false or {} = no scroll keys
  resume_at_bottom = true, -- back to typing when scrolling reaches the bottom
}

---Resolve `terminal.keys` (false disables everything).
---@param keys table|boolean|nil
---@return table|nil
function M.resolve(keys)
  if keys == false then
    return nil
  end
  local opts = {}
  for k, v in pairs(M.defaults) do
    opts[k] = v
  end
  if type(keys) == "table" then
    for k, v in pairs(keys) do
      opts[k] = v
    end
  end
  return opts
end

---@return table|nil
local function configured()
  local term = package.loaded["claudecode.terminal"]
  return M.resolve(term and term.defaults and term.defaults.keys)
end

---@param opts table
---@return string[]
local function passthrough_list(opts)
  if opts.passthrough == true or opts.passthrough == nil then
    return M.CLAUDE_KEYS
  end
  return type(opts.passthrough) == "table" and opts.passthrough or {}
end

---Whether the double-Escape "leave terminal mode" of the Snacks terminal must be
---turned off so both Escapes reach Claude.
---@return boolean
function M.claims_escape()
  local opts = configured()
  if not opts then
    return false
  end
  for _, key in ipairs(passthrough_list(opts)) do
    if key:lower() == "<esc>" then
      return true
    end
  end
  return false
end

local watch_ns = nil
local watching = nil ---@type integer|nil buffer being scrolled
local generation = 0

local function stop_watch()
  if watching and watch_ns then
    vim.on_key(nil, watch_ns)
  end
  watching = nil
  generation = generation + 1
end

---Wait until the view stops moving (smooth-scroll plugins animate and mute
---CursorMoved/WinScrolled), then return to terminal mode if this key scrolled
---down and the end of the transcript is in view again.
local function settle(buf, gen, top_at_key, last_top, tries)
  if gen ~= generation or watching ~= buf then
    return
  end
  local mode = vim.api.nvim_get_mode().mode
  if vim.api.nvim_get_current_buf() ~= buf or (mode ~= "nt" and mode ~= "n") then
    return -- "nt" = normal mode in a terminal buffer
  end
  local top = vim.fn.line("w0")
  if top ~= last_top and tries < 40 then
    vim.defer_fn(function()
      settle(buf, gen, top_at_key, top, tries + 1)
    end, 50)
    return
  end
  if top > top_at_key and vim.fn.line("w$") >= vim.fn.line("$") then
    stop_watch()
    vim.cmd("startinsert")
  end
end

---While the user scrolls `buf` in normal mode, check after every key whether
---they are back at the bottom. Only active between a scroll key and the next
---return to terminal mode, so it costs nothing otherwise.
---@param buf integer
local function watch(buf)
  if watching == buf or not vim.on_key then
    return
  end
  stop_watch()
  watching = buf
  watch_ns = watch_ns or vim.api.nvim_create_namespace("claudecode_terminal_scroll")
  vim.on_key(function()
    if watching ~= buf then
      return
    end
    if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_get_current_buf() ~= buf then
      vim.schedule(stop_watch)
      return
    end
    generation = generation + 1
    local gen, top = generation, vim.fn.line("w0")
    vim.defer_fn(function()
      settle(buf, gen, top, -1, 0)
    end, 80)
  end, watch_ns)
end

---Leave terminal mode and scroll with the user's normal-mode `key`.
---@param buf integer
---@param key string
---@param resume boolean Return to typing once scrolled back to the bottom
local function start_scroll(buf, key, resume)
  vim.cmd("stopinsert")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "m", false)
  if resume then
    vim.schedule(function()
      watch(buf)
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Fullscreen Claude (alternate screen): Neovim has no scrollback, Claude owns
-- the transcript and scrolls it on PageUp/PageDown and mouse-wheel input.
-- ---------------------------------------------------------------------------

local PAGE_UP, PAGE_DOWN = "\27[5~", "\27[6~"
local WHEEL_UP, WHEEL_DOWN = "\27[<64;1;1M", "\27[<65;1;1M"

---Keys that keep scrolling once a scroll key was pressed ("scroll mode").
---Outside scroll mode they go to Claude untouched.
M.SCROLL_MODE_KEYS = {
  { "<C-d>", PAGE_DOWN },
  { "<C-f>", PAGE_DOWN },
  { "<PageDown>", PAGE_DOWN },
  { "<C-b>", PAGE_UP },
  { "<C-y>", WHEEL_UP },
  { "<C-e>", WHEEL_DOWN },
}

local claude_scrolling = nil ---@type integer|nil buffer in scroll mode
local scroll_ns = nil

---@param buf integer
---@param bytes string
local last_wheel = nil ---@type string|nil

local function send(buf, bytes)
  local chan = vim.b[buf].terminal_job_id
  if not chan or chan <= 0 then
    return
  end
  if bytes == WHEEL_UP or bytes == WHEEL_DOWN then
    -- Claude drops the first wheel step after the wheel changes direction.
    if last_wheel and last_wheel ~= bytes then
      pcall(vim.api.nvim_chan_send, chan, bytes)
    end
    last_wheel = bytes
  end
  pcall(vim.api.nvim_chan_send, chan, bytes)
end

---Claude is on the alternate screen when the terminal buffer holds no more
---lines than its window shows.
---@param buf integer
---@return boolean
function M.is_fullscreen(buf)
  local win = vim.fn.bufwinid(buf)
  return win ~= -1 and vim.api.nvim_buf_line_count(buf) <= vim.api.nvim_win_get_height(win)
end

local function end_claude_scroll()
  claude_scrolling = nil
  if scroll_ns then
    vim.on_key(nil, scroll_ns)
  end
end

---Enter scroll mode: it lasts until any key that is not a scroll key is typed.
---@param buf integer
---@param keyset table<string, boolean> lower-case key names that keep it alive
local function begin_claude_scroll(buf, keyset)
  if claude_scrolling == buf or not vim.on_key then
    return
  end
  claude_scrolling = buf
  scroll_ns = scroll_ns or vim.api.nvim_create_namespace("claudecode_terminal_scroll_mode")
  vim.on_key(function(key, typed)
    local k = (typed ~= nil and typed ~= "") and typed or key
    if not k or k == "" or claude_scrolling ~= buf then
      return
    end
    if not keyset[vim.fn.keytrans(k):lower()] then
      claude_scrolling = nil
      vim.schedule(function()
        if not claude_scrolling then
          end_claude_scroll()
        end
      end)
    end
  end, scroll_ns)
end

---Install the buffer-local key handling on Claude terminal buffer `buf`.
---@param buf integer
function M.attach(buf)
  local opts = configured()
  if not opts or not (vim.keymap and vim.keymap.set) then
    return
  end
  local resume = opts.resume_at_bottom ~= false

  -- Lower-case names of every key that scrolls (kept out of the passthrough).
  local scroll = {}
  local scroll_up = type(opts.scroll_up) == "table" and opts.scroll_up or {}
  if #scroll_up > 0 then
    for _, key in ipairs(scroll_up) do
      scroll[key:lower()] = true
    end
    for _, spec in ipairs(M.SCROLL_MODE_KEYS) do
      scroll[spec[1]:lower()] = true
    end
    scroll["<scrollwheelup>"] = true
    scroll["<scrollwheeldown>"] = true

    for _, key in ipairs(scroll_up) do
      vim.keymap.set("t", key, function()
        if M.is_fullscreen(buf) then
          send(buf, PAGE_UP)
          begin_claude_scroll(buf, scroll)
        else
          start_scroll(buf, key, resume)
        end
      end, { buffer = buf, nowait = true, desc = "Claude: scroll the chat up" })
    end

    for _, spec in ipairs(M.SCROLL_MODE_KEYS) do
      local key, bytes = spec[1], spec[2]
      local is_scroll_up = false
      for _, up in ipairs(scroll_up) do
        is_scroll_up = is_scroll_up or up:lower() == key:lower()
      end
      if not is_scroll_up then
        vim.keymap.set("t", key, function()
          if claude_scrolling == buf then
            send(buf, bytes)
            return ""
          end
          return key
        end, {
          buffer = buf,
          nowait = true,
          expr = true,
          desc = "Claude: " .. key .. " (scrolls in scroll mode)",
        })
      end
    end
  end

  for _, key in ipairs(passthrough_list(opts)) do
    if not scroll[key:lower()] then
      vim.keymap.set("t", key, key, { buffer = buf, nowait = true, desc = "Claude: " .. key })
    end
  end

  if #scroll_up > 0 and vim.api.nvim_create_autocmd then
    vim.api.nvim_create_autocmd({ "TermEnter", "TermLeave", "BufLeave" }, {
      buffer = buf,
      callback = function(args)
        if watching == buf and args.event ~= "TermLeave" then
          stop_watch()
        end
        if claude_scrolling == buf and args.event ~= "TermEnter" then
          end_claude_scroll()
        end
      end,
    })
  end
end

return M
