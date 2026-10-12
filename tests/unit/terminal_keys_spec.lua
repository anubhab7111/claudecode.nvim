require("tests.busted_setup")

describe("terminal_keys", function()
  local keys
  local saved = {}
  local maps, sent, lines, height

  local function stub(tbl, key, value)
    saved[#saved + 1] = { tbl, key, tbl[key] }
    tbl[key] = value
  end

  local function set_config(value)
    package.loaded["claudecode.terminal"] = { defaults = { keys = value } }
  end

  before_each(function()
    package.loaded["claudecode.terminal_keys"] = nil
    maps, sent, lines, height = {}, {}, 10, 40
    stub(vim, "keymap", {
      set = function(mode, lhs, rhs, opts)
        maps[lhs] = { mode = mode, rhs = rhs, opts = opts }
      end,
    })
    stub(vim.api, "nvim_create_autocmd", function() end)
    stub(vim.api, "nvim_chan_send", function(_, bytes)
      sent[#sent + 1] = bytes
    end)
    stub(vim.api, "nvim_buf_line_count", function()
      return lines
    end)
    stub(vim.api, "nvim_win_get_height", function()
      return height
    end)
    stub(vim.api, "nvim_create_namespace", function()
      return 1
    end)
    stub(vim.fn, "bufwinid", function()
      return 1000
    end)
    stub(vim, "on_key", function() end)
    stub(
      vim,
      "b",
      setmetatable({}, {
        __index = function()
          return { terminal_job_id = 7 }
        end,
      })
    )
    set_config(nil)
    keys = require("claudecode.terminal_keys")
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      local s = saved[i]
      s[1][s[2]] = s[3]
    end
    saved = {}
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.terminal_keys"] = nil
  end)

  it("passes Claude's own keys through with buffer-local nowait maps", function()
    keys.attach(5)
    for _, lhs in ipairs({ "<Esc>", "<C-_>", "<C-/>", "<C-r>", "<S-Tab>" }) do
      assert.is_truthy(maps[lhs], lhs .. " not mapped")
      assert.are.equal("t", maps[lhs].mode)
      assert.are.equal(lhs, maps[lhs].rhs)
      assert.are.equal(5, maps[lhs].opts.buffer)
      assert.is_true(maps[lhs].opts.nowait)
    end
  end)

  it("leaves the user's exit key, Ctrl-Z and the terminal escape prefix alone", function()
    keys.attach(5)
    assert.is_nil(maps["<C-x>"])
    assert.is_nil(maps["<C-z>"])
    assert.is_nil(maps["<C-\\>"])
  end)

  it("scrolls fullscreen Claude with PageUp and keeps scrolling in scroll mode", function()
    keys.attach(5)
    assert.is_true(keys.is_fullscreen(5))
    -- Outside scroll mode Ctrl-D is Claude's own key.
    assert.are.equal("<C-d>", maps["<C-d>"].rhs())
    maps["<C-u>"].rhs()
    assert.are.same({ "\27[5~" }, sent)
    -- In scroll mode it pages down instead.
    assert.are.equal("", maps["<C-d>"].rhs())
    assert.are.equal("", maps["<C-b>"].rhs())
    assert.are.same({ "\27[5~", "\27[6~", "\27[5~" }, sent)
  end)

  it("repeats the first wheel step after a direction change", function()
    keys.attach(5)
    maps["<C-u>"].rhs()
    sent = {}
    maps["<C-y>"].rhs()
    maps["<C-y>"].rhs()
    maps["<C-e>"].rhs()
    assert.are.same({ "\27[<64;1;1M", "\27[<64;1;1M", "\27[<65;1;1M", "\27[<65;1;1M" }, sent)
  end)

  it("leaves terminal mode to scroll when Neovim owns the scrollback", function()
    lines = 500
    local cmds, fed = {}, {}
    stub(vim, "cmd", function(c)
      cmds[#cmds + 1] = c
    end)
    stub(vim.api, "nvim_replace_termcodes", function(k)
      return k
    end)
    stub(vim.api, "nvim_feedkeys", function(k, mode)
      fed[#fed + 1] = k .. ":" .. mode
    end)
    stub(vim, "schedule", function() end)
    keys.attach(5)
    assert.is_false(keys.is_fullscreen(5))
    maps["<C-u>"].rhs()
    assert.are.same({ "stopinsert" }, cmds)
    assert.are.same({ "<C-u>:m" }, fed)
    assert.are.same({}, sent)
  end)

  it("honours terminal.keys options", function()
    set_config(false)
    keys.attach(5)
    assert.are.same({}, maps)
    assert.is_false(keys.claims_escape())

    set_config({ passthrough = { "<C-x>" }, scroll_up = false })
    keys.attach(5)
    assert.is_truthy(maps["<C-x>"])
    assert.is_nil(maps["<C-u>"])
    assert.is_nil(maps["<Esc>"])
    assert.is_false(keys.claims_escape())

    set_config(nil)
    assert.is_true(keys.claims_escape())
  end)
end)
