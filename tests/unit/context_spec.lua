require("tests.busted_setup")

describe("claudecode.context", function()
  local context
  local sent
  local orig = {}

  before_each(function()
    package.loaded["claudecode.context"] = nil
    sent = {}
    package.loaded["claudecode.terminal"] = {
      send_to_terminal = function(text, opts)
        sent[#sent + 1] = { text = text, opts = opts }
        return true
      end,
      get_active_terminal_bufnr = function()
        return 99
      end,
    }
    package.loaded["claudecode"] = {
      _format_path_for_at_mention = function(p)
        return (p:gsub("^/proj/", ""))
      end,
      state = { config = { terminal_context_lines = 3 } },
    }
    orig.get_name = vim.api.nvim_buf_get_name
    orig.get_current_buf = vim.api.nvim_get_current_buf
    orig.get_option = vim.api.nvim_buf_get_option
    vim.api.nvim_buf_get_option = function()
      return ""
    end
    vim.api.nvim_buf_get_name = function()
      return "/proj/lua/foo.lua"
    end
    vim.api.nvim_get_current_buf = function()
      return 1
    end
    context = require("claudecode.context")
  end)

  after_each(function()
    vim.api.nvim_buf_get_name = orig.get_name
    vim.api.nvim_get_current_buf = orig.get_current_buf
    vim.api.nvim_buf_get_option = orig.get_option
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode"] = nil
  end)

  it("formats single-line, ranged, reversed and whole-file references", function()
    assert.are.equal("@lua/foo.lua#L7", context.reference_for(1, 7, 7))
    assert.are.equal("@lua/foo.lua#L5-10", context.reference_for(1, 5, 10))
    assert.are.equal("@lua/foo.lua#L5-10", context.reference_for(1, 10, 5))
    assert.are.equal("@lua/foo.lua", context.reference_for(1))
  end)

  it("inserts a reference without submitting", function()
    context.insert_reference({ range = 2, line1 = 2, line2 = 4 })
    assert.are.equal("@lua/foo.lua#L2-4 ", sent[1].text)
    assert.is_false(sent[1].opts.submit)
  end)

  it("sends an edit instruction and submits it", function()
    context.edit({ range = 2, line1 = 1, line2 = 3, args = "make it async" })
    assert.are.equal("Edit @lua/foo.lua#L1-3: make it async", sent[1].text)
    assert.is_true(sent[1].opts.submit)
  end)

  it("refuses an edit with no instruction", function()
    assert.is_false(context.edit({ range = 0, args = "" }))
    assert.are.equal(0, #sent)
  end)

  it("cycles mode by sending Shift+Tab", function()
    context.cycle_mode()
    assert.are.equal("\27[Z", sent[1].text)
    assert.is_false(sent[1].opts.submit)
  end)

  it("keeps only the last non-blank lines of a terminal", function()
    local orig_count, orig_lines = vim.api.nvim_buf_line_count, vim.api.nvim_buf_get_lines
    vim.api.nvim_buf_line_count = function()
      return 7
    end
    vim.api.nvim_buf_get_lines = function()
      return { "a", "b", "c", "d", "e", "", "  " }
    end
    local lines = context.tail_lines(5, 3)
    vim.api.nvim_buf_line_count, vim.api.nvim_buf_get_lines = orig_count, orig_lines
    assert.are.same({ "c", "d", "e" }, lines)
  end)
end)
