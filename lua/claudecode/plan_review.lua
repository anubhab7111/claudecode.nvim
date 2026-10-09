---Review Claude's plan in a Neovim buffer.
---
---When Claude finishes planning it calls ExitPlanMode, which raises a
---PermissionRequest hook. We hold the hook's reply, open the plan as a
---Markdown buffer, and answer from there:
---
---  ga        approve the plan (Claude starts working)
---  :w        edited? send your revised plan back (Claude keeps planning);
---            unchanged? approve
---  q / close fall back to the normal approval dialog in the Claude terminal
---
---If nothing happens before the hook times out, we answer `{}` so the
---terminal dialog appears. Only one plan is reviewed at a time.
---@module 'claudecode.plan_review'
local M = {}

local logger = require("claudecode.logger")

---@class ClaudeCodePlanReviewPending
---@field bufnr integer
---@field original string[]
---@field reply fun(decision: table)
---@field replied boolean
---@field timer table|nil
---@field return_tab integer|nil
---@field own_tab integer|nil

---@type ClaudeCodePlanReviewPending|nil
M.pending = nil

local function options()
  local main = package.loaded["claudecode"]
  local cfg = main and main.state and main.state.config or {}
  local pr = cfg.plan_review
  if type(pr) ~= "table" then
    pr = {}
  end
  return {
    layout = pr.layout or "tab",
    timeout_ms = ((pr.timeout or 3600) - 10) * 1000,
    approve_key = pr.approve_key == nil and "ga" or pr.approve_key,
  }
end

local function allow()
  return { hookSpecificOutput = { hookEventName = "PermissionRequest", decision = { behavior = "allow" } } }
end

local function deny(message)
  return {
    hookSpecificOutput = {
      hookEventName = "PermissionRequest",
      decision = { behavior = "deny", message = message },
    },
  }
end

local function close_ui(p)
  if p.timer then
    pcall(function()
      p.timer:stop()
      p.timer:close()
    end)
    p.timer = nil
  end
  if p.own_tab and vim.api.nvim_tabpage_is_valid(p.own_tab) then
    local wins = vim.api.nvim_tabpage_list_wins(p.own_tab)
    if #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.api.nvim_set_current_tabpage, p.own_tab)
      pcall(vim.cmd, "tabclose")
    else
      for _, w in ipairs(wins) do
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end
  if vim.api.nvim_buf_is_valid(p.bufnr) then
    pcall(vim.api.nvim_buf_delete, p.bufnr, { force = true })
  end
  if p.return_tab and vim.api.nvim_tabpage_is_valid(p.return_tab) then
    pcall(vim.api.nvim_set_current_tabpage, p.return_tab)
  end
end

---Send the decision once and tear down the review UI.
---@param decision table
function M.finish(decision)
  local p = M.pending
  if not p or p.replied then
    return
  end
  p.replied = true
  M.pending = nil
  local ok, err = pcall(p.reply, decision)
  if not ok then
    logger.warn("plan_review", "failed to answer Claude: " .. tostring(err))
  end
  close_ui(p)
end

---Approve the plan under review.
function M.approve()
  M.finish(allow())
end

---Fall back to the terminal's approval dialog.
function M.defer()
  M.finish({})
end

---`:w` in the plan buffer: send edits back as feedback, or approve if unchanged.
function M.submit()
  local p = M.pending
  if not p then
    return
  end
  local current = vim.api.nvim_buf_get_lines(p.bufnr, 0, -1, false)
  if table.concat(current, "\n") == table.concat(p.original, "\n") then
    M.approve()
    return
  end
  M.finish(
    deny(
      "The user reviewed your plan in their editor and revised it. "
        .. "Do not start implementing yet: update your plan to follow this revised version "
        .. "(it may contain inline comments addressed to you), then present it again.\n\n"
        .. table.concat(current, "\n")
    )
  )
end

---Handle a PermissionRequest for ExitPlanMode.
---@param payload table Hook payload (tool_input.plan holds the Markdown plan)
---@param reply fun(decision: table) Sends the HTTP reply
---@return boolean handled false when there is no plan text to show
function M.handle(payload, reply)
  local plan = type(payload.tool_input) == "table" and payload.tool_input.plan or nil
  if type(plan) ~= "string" or plan == "" then
    return false
  end

  -- One review at a time: hand an older pending plan back to the terminal.
  if M.pending then
    M.defer()
  end

  local opts = options()
  local lines = vim.split(plan, "\n", { plain = true })
  local return_tab = vim.api.nvim_get_current_tabpage()

  local bufnr = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, bufnr, "claudecode://plan")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, "buftype", "acwrite")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "modified", false)
  pcall(vim.api.nvim_buf_set_option, bufnr, "filetype", "markdown")

  local own_tab
  if opts.layout == "split" then
    vim.cmd("botright vsplit")
  else
    vim.cmd("tabnew")
    own_tab = vim.api.nvim_get_current_tabpage()
  end
  local scratch = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(0, bufnr)
  if scratch ~= bufnr and vim.api.nvim_buf_is_valid(scratch) and vim.api.nvim_buf_get_name(scratch) == "" then
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  end

  M.pending = {
    bufnr = bufnr,
    original = lines,
    reply = reply,
    replied = false,
    return_tab = return_tab,
    own_tab = own_tab,
  }

  local group = vim.api.nvim_create_augroup("ClaudeCodePlanReview", { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.submit()
      return true
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      if M.pending and M.pending.bufnr == bufnr then
        M.defer()
      end
    end,
  })

  if vim.keymap and vim.keymap.set then
    if opts.approve_key then
      vim.keymap.set("n", opts.approve_key, M.approve, { buffer = bufnr, nowait = true, desc = "Claude: approve plan" })
    end
    vim.keymap.set("n", "q", M.defer, { buffer = bufnr, nowait = true, desc = "Claude: review plan in terminal" })
  end

  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()
  if timer then
    timer:start(math.max(opts.timeout_ms, 1000), 0, vim.schedule_wrap(M.defer))
    M.pending.timer = timer
  end

  vim.notify(
    "Claude's plan is ready: " .. (opts.approve_key or "?") .. " approve · edit + :w send changes · q use terminal",
    vim.log.levels.INFO,
    { title = "Claude Code" }
  )
  return true
end

return M
