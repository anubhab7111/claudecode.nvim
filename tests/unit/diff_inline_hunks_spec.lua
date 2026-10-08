require("tests.busted_setup")

local original_buf_is_valid = vim.api.nvim_buf_is_valid
local original_keymap_set = vim.keymap.set

describe("diff_inline per-hunk review", function()
  local inline

  before_each(function()
    package.loaded["claudecode.diff_inline"] = nil
    inline = require("claudecode.diff_inline")
  end)

  -- old: a b c d e   new: a B c d E F
  local lines = { "a", "b", "B", "c", "d", "e", "E", "F" }
  local types = { "unchanged", "deleted", "added", "unchanged", "unchanged", "deleted", "added", "added" }

  it("groups consecutive changed lines into hunks", function()
    assert.are.same({ { s = 2, e = 3 }, { s = 6, e = 8 } }, inline.compute_hunks(types))
    assert.are.same({}, inline.compute_hunks({ "unchanged", "unchanged" }))
    assert.are.same({ { s = 1, e = 1 } }, inline.compute_hunks({ "added" }))
  end)

  it("finds the hunk at or above the cursor like Vim's do/dp", function()
    local hunks = inline.compute_hunks(types)
    assert.are.equal(1, inline.hunk_index_at(hunks, 1)) -- above all: first
    assert.are.equal(1, inline.hunk_index_at(hunks, 3))
    assert.are.equal(1, inline.hunk_index_at(hunks, 5)) -- between: the one above
    assert.are.equal(2, inline.hunk_index_at(hunks, 7))
  end)

  it("extracts all proposed content when nothing is rejected", function()
    assert.are.equal("a\nB\nc\nd\nE\nF", inline.extract_new_content(lines, types))
    assert.are.equal("a\nB\nc\nd\nE\nF", inline.extract_new_content(lines, types, {}))
  end)

  it("restores original lines for rejected hunks only", function()
    assert.are.equal("a\nb\nc\nd\nE\nF", inline.extract_new_content(lines, types, { [2] = true }))
    assert.are.equal("a\nB\nc\nd\ne", inline.extract_new_content(lines, types, { [6] = true }))
    assert.are.equal("a\nb\nc\nd\ne", inline.extract_new_content(lines, types, { [2] = true, [6] = true }))
  end)

  describe("decisions on a registered diff", function()
    local active, rendered

    before_each(function()
      active = {
        t = {
          layout = "unified",
          status = "pending",
          lines = lines,
          line_types = types,
          new_buffer = 42,
          new_file_contents = "a\nB\nc\nd\nE\nF\n",
        },
      }
      package.loaded["claudecode.diff"] = {
        _get_active_diffs = function()
          return active
        end,
      }
      rendered = {}
      inline.render_hunk = function(buf, _, hunk, rejected)
        rendered[#rendered + 1] = { s = hunk.s, rejected = rejected }
      end
      vim.api.nvim_buf_is_valid = function()
        return true
      end
    end)

    after_each(function()
      package.loaded["claudecode.diff"] = nil
      vim.api.nvim_buf_is_valid = original_buf_is_valid
    end)

    it("rejects, re-renders, and feeds the accepted content", function()
      inline.set_hunk_decision("t", 7, "rejected")
      assert.is_true(active.t.rejected[6])
      assert.are.same({ s = 6, rejected = true }, rendered[1])

      local result
      active.t.resolution_callback = function(r)
        result = r
      end
      inline.resolve_inline_as_saved("t", active.t)
      assert.are.equal("FILE_SAVED", result.content[1].text)
      assert.are.equal("a\nB\nc\nd\ne\n", result.content[2].text)
    end)

    it("undoes decisions in LIFO order", function()
      inline.set_hunk_decision("t", 2, "rejected")
      inline.set_hunk_decision("t", 6, "rejected")
      assert.are.equal(6, inline.undo_hunk_decision("t"))
      assert.is_nil(active.t.rejected[6])
      assert.is_true(active.t.rejected[2])
      assert.are.equal(2, inline.undo_hunk_decision("t"))
      assert.is_nil(active.t.rejected[2])
      assert.is_nil(inline.undo_hunk_decision("t"))
    end)

    it("ignores no-op decisions and resolved diffs", function()
      inline.set_hunk_decision("t", 2, "kept")
      assert.are.equal(0, #(active.t.decision_stack or {}))
      active.t.status = "saved"
      assert.is_nil(inline.set_hunk_decision("t", 2, "rejected"))
    end)

    it("navigates between hunk starts", function()
      assert.are.equal(2, inline.adjacent_hunk_line("t", 1, 1))
      assert.are.equal(6, inline.adjacent_hunk_line("t", 2, 1))
      assert.is_nil(inline.adjacent_hunk_line("t", 6, 1))
      assert.are.equal(2, inline.adjacent_hunk_line("t", 6, -1))
      assert.is_nil(inline.adjacent_hunk_line("t", 2, -1))
    end)
  end)
end)

describe("diff_keys", function()
  local diff_keys

  before_each(function()
    package.loaded["claudecode.diff_keys"] = nil
    diff_keys = require("claudecode.diff_keys")
  end)

  after_each(function()
    vim.api.nvim_buf_is_valid = original_buf_is_valid
    vim.keymap.set = original_keymap_set
  end)

  it("uses native-verb defaults and honours overrides/disables", function()
    local keys = diff_keys.resolve_keys(nil)
    assert.are.equal("do", keys.reject_hunk)
    assert.are.equal("dp", keys.keep_hunk)
    keys = diff_keys.resolve_keys({ diff_opts = { keys = { keep_hunk = false, accept_next = "<leader>an" } } })
    assert.is_nil(keys.keep_hunk)
    assert.are.equal("<leader>an", keys.accept_next)
    assert.are.same({}, diff_keys.resolve_keys({ diff_opts = { keys = false } }))
  end)

  local function capture_maps()
    local maps = {}
    vim.keymap.set = function(mode, lhs, rhs, opts)
      maps[lhs] = { mode = mode, opts = opts }
    end
    vim.api.nvim_buf_is_valid = function()
      return true
    end
    return maps
  end

  it("two-pane: leaves native verbs alone, remaps dp safely, buffer-local only", function()
    local orig = vim.keymap.set
    local maps = capture_maps()
    diff_keys.attach("t", 7, "split", nil)
    vim.keymap.set = orig
    assert.is_nil(maps["]c"])
    assert.is_nil(maps["do"])
    assert.is_not_nil(maps["dp"])
    assert.are.equal(7, maps["dp"].opts.buffer)
    assert.is_not_nil(maps["<C-g>"])
  end)

  it("unified: maps navigation, reject, keep and undo", function()
    local orig = vim.keymap.set
    local maps = capture_maps()
    diff_keys.attach("t", 9, "unified", nil)
    vim.keymap.set = orig
    for _, lhs in ipairs({ "]c", "[c", "do", "dp", "u", "<C-g>" }) do
      assert.is_not_nil(maps[lhs], lhs)
      assert.are.equal(9, maps[lhs].opts.buffer)
    end
  end)
end)
