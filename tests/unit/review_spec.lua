require("tests.busted_setup")

describe("plan_review decisions", function()
  local pr, replies
  local orig_get_lines, orig_is_valid

  before_each(function()
    package.loaded["claudecode.plan_review"] = nil
    pr = require("claudecode.plan_review")
    replies = {}
    orig_get_lines = vim.api.nvim_buf_get_lines
    orig_is_valid = vim.api.nvim_buf_is_valid
    vim.api.nvim_buf_is_valid = function()
      return false -- skip UI teardown
    end
    pr.pending = {
      bufnr = 5,
      original = { "1. a", "2. b" },
      replied = false,
      reply = function(d)
        replies[#replies + 1] = d
      end,
    }
  end)

  after_each(function()
    vim.api.nvim_buf_get_lines = orig_get_lines
    vim.api.nvim_buf_is_valid = orig_is_valid
  end)

  local function lines(tbl)
    vim.api.nvim_buf_get_lines = function()
      return tbl
    end
  end

  it("approves when :w is used without changes", function()
    lines({ "1. a", "2. b" })
    pr.submit()
    assert.are.equal("allow", replies[1].hookSpecificOutput.decision.behavior)
    assert.is_nil(pr.pending)
  end)

  it("denies with the revised plan when edited", function()
    lines({ "1. a", "2. b", "> add tests" })
    pr.submit()
    local d = replies[1].hookSpecificOutput.decision
    assert.are.equal("deny", d.behavior)
    assert.truthy(d.message:find("> add tests", 1, true))
  end)

  it("defers with an empty decision and replies only once", function()
    pr.defer()
    pr.approve()
    assert.are.equal(1, #replies)
    assert.are.same({}, replies[1])
  end)
end)

describe("turn_review", function()
  local tr
  local path = os.tmpname()

  before_each(function()
    package.loaded["claudecode.turn_review"] = nil
    tr = require("claudecode.turn_review")
    local f = io.open(path, "w")
    f:write("alpha\nbeta\ngamma\n")
    f:close()
  end)

  after_each(function()
    os.remove(path)
  end)

  it("snapshots only edit tools, once per file per turn", function()
    tr.snapshot({ tool_name = "Read", tool_input = { file_path = path } })
    assert.is_nil(tr.snapshots[path])
    tr.snapshot({ tool_name = "Edit", tool_input = { file_path = path } })
    assert.are.equal("alpha\nbeta\ngamma\n", tr.snapshots[path].text)

    local f = io.open(path, "w")
    f:write("changed\n")
    f:close()
    tr.snapshot({ tool_name = "Write", tool_input = { file_path = path } })
    assert.are.equal("alpha\nbeta\ngamma\n", tr.snapshots[path].text, "first snapshot wins")
    assert.are.equal(1, #tr.order)

    tr.reset()
    assert.are.same({}, tr.snapshots)
  end)

  it("reports created files and no items for unchanged ones", function()
    local new_path = path .. ".new"
    tr.snapshot({ tool_name = "Write", tool_input = { file_path = new_path } })
    assert.is_false(tr.snapshots[new_path].existed)
    local f = io.open(new_path, "w")
    f:write("x\ny\n")
    f:close()
    tr.snapshot({ tool_name = "Edit", tool_input = { file_path = path } })
    local items = tr.items()
    os.remove(new_path)
    assert.are.equal(1, #items)
    assert.truthy(items[1].text:find("created", 1, true))
  end)
end)
