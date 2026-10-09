require("tests.busted_setup")

describe("follow", function()
  local follow, hooks
  local saved = {}
  local bufs, cmds, notes, deferred

  local function stub(tbl, key, value)
    saved[#saved + 1] = { tbl, key, tbl[key] }
    tbl[key] = value
  end

  before_each(function()
    package.loaded["claudecode.follow"] = nil
    package.loaded["claudecode.hooks"] = nil
    bufs = {
      [1] = { name = "/proj/a.lua", modified = false, buftype = "" },
      [2] = { name = "/proj/b.lua", modified = true, buftype = "" },
      [3] = { name = "", modified = false, buftype = "terminal" },
      [4] = { name = "diffview:///x", modified = false, buftype = "" },
    }
    cmds, notes, deferred = {}, {}, {}
    local current = nil
    stub(vim.api, "nvim_list_bufs", function()
      return { 1, 2, 3, 4 }
    end)
    stub(vim.api, "nvim_buf_is_loaded", function(b)
      return bufs[b] ~= nil
    end)
    stub(vim.api, "nvim_buf_is_valid", function(b)
      return bufs[b] ~= nil
    end)
    stub(vim.api, "nvim_buf_get_name", function(b)
      return bufs[b].name
    end)
    stub(vim.api, "nvim_buf_get_option", function(b, opt)
      return bufs[b][opt]
    end)
    stub(vim.api, "nvim_buf_call", function(b, fn)
      current = b
      fn()
      current = nil
    end)
    stub(vim, "cmd", function(c)
      cmds[#cmds + 1] = (current and (current .. ":") or "") .. c
    end)
    stub(vim, "defer_fn", function(fn, ms)
      deferred[#deferred + 1] = { fn = fn, ms = ms }
    end)
    stub(vim, "notify", function(msg)
      notes[#notes + 1] = msg
    end)
    follow = require("claudecode.follow")
    hooks = require("claudecode.hooks")
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      local s = saved[i]
      s[1][s[2]] = s[3]
    end
    saved = {}
    package.loaded["claudecode.follow"] = nil
    package.loaded["claudecode.hooks"] = nil
  end)

  it("reloads with 'autoread' forced locally and restored", function()
    assert.is_true(follow.reload(1))
    assert.are.same({ "1:setlocal autoread", "1:silent! checktime 1", "1:setlocal autoread<" }, cmds)
  end)

  it("never reloads modified, special or URI buffers", function()
    assert.is_false(follow.reload(2))
    assert.is_false(follow.reload(3))
    assert.is_false(follow.reload(4))
    assert.are.same({}, cmds)
  end)

  it("check_all only touches unmodified file buffers", function()
    follow.check_all()
    assert.are.same({ "1:setlocal autoread", "1:silent! checktime 1", "1:setlocal autoread<" }, cmds)
  end)

  it("re-checks an edited file shortly after the first reload", function()
    follow.file_changed(1)
    assert.are.equal(3, #cmds)
    assert.are.equal(1, #deferred)
    deferred[1].fn()
    assert.are.equal(6, #cmds)
  end)

  it("warns once instead of clobbering unsaved edits", function()
    follow.file_changed(2)
    follow.file_changed(2)
    assert.are.same({}, cmds)
    assert.are.equal(1, #notes)
    assert.is_truthy(notes[1]:find("unsaved edits", 1, true))
  end)

  it("PostToolUse for an edit tool reloads that file's buffer", function()
    hooks.follow({ hook_event_name = "PostToolUse", tool_name = "Edit", tool_input = { file_path = "/proj/a.lua" } })
    assert.are.equal("1:silent! checktime 1", cmds[2])
  end)

  it("PostToolUse for Bash re-checks every loaded buffer", function()
    hooks.follow({ hook_event_name = "PostToolUse", tool_name = "Bash", tool_input = { command = "sed -i x a.lua" } })
    assert.are.same({ "1:setlocal autoread", "1:silent! checktime 1", "1:setlocal autoread<" }, cmds)
  end)

  it("the PostToolUse hook matcher includes Bash", function()
    package.loaded["claudecode.hooks_settings"] = nil
    local hs = require("claudecode.hooks_settings")
    local matcher = hs.build(1, {}).hooks.PostToolUse[1].matcher
    assert.is_truthy(("|" .. matcher .. "|"):find("|Bash|", 1, true))
  end)
end)
