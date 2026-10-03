local config = require("leaf.config")
local resolve = require("leaf.resolve")

---Real files on disk: explicit-path decisions go through filereadable().
local current_file ---@type string
local other_file ---@type string

---Build a context with everything pure and overridable.
local function ctx(overrides)
  return vim.tbl_extend("force", {
    arg = nil,
    bang = false,
    bufnr = 1,
    ft = "markdown",
    bufname = current_file,
  }, overrides or {})
end

describe("leaf.resolve", function()
  before_each(function()
    config.setup({})
    current_file = vim.fn.tempname() .. ".md"
    other_file = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ "# current" }, current_file)
    vim.fn.writefile({ "# other" }, other_file)
  end)

  after_each(function()
    vim.fn.delete(current_file)
    vim.fn.delete(other_file)
  end)

  describe("binary guard", function()
    it("fails with missing_binary when leaf is not resolvable", function()
      config.setup({ leaf_path = "/nonexistent/leaf" })
      local decision = resolve.decide(ctx())
      assert.are.same("error", decision.kind)
      assert.are.same("missing_binary", decision.err)
      assert.truthy(resolve.error_message(decision):find("RivoLink/leaf"))
    end)
  end)

  describe("mode", function()
    -- leaf CLI exists on this machine (verified in checkhealth); these tests
    -- only run meaningfully when the guard passes.
    it("defaults to static", function()
      assert.are.same("static", resolve.decide(ctx()).request.mode)
    end)

    it("flips to interactive on bang", function()
      assert.are.same("interactive", resolve.decide(ctx({ bang = true })).request.mode)
    end)

    it("flips interactive default back to static on bang", function()
      config.setup({ interactive = true })
      assert.are.same("static", resolve.decide(ctx({ bang = true })).request.mode)
    end)

    it("keeps interactive as the configured default without bang", function()
      config.setup({ interactive = true })
      assert.are.same("interactive", resolve.decide(ctx()).request.mode)
    end)
  end)

  describe("placement", function()
    it("auto-splits when previewing the focused markdown buffer", function()
      assert.are.same("split", resolve.decide(ctx()).request.placement)
    end)

    it("floats for an explicit path to another file", function()
      local decision = resolve.decide(ctx({ arg = other_file }))
      assert.are.same("float", decision.request.placement)
      assert.are.same("file", decision.request.source.kind)
      assert.are.same(other_file, decision.request.source.path)
    end)

    it("keeps split + buffer source when the explicit path IS the current buffer", function()
      local decision = resolve.decide(ctx({ arg = current_file }))
      assert.are.same("buffer", decision.request.source.kind)
      assert.are.same("split", decision.request.placement)
    end)

    it("respects a forced float position", function()
      config.setup({ position = "float" })
      assert.are.same("float", resolve.decide(ctx()).request.placement)
    end)

    it("respects a forced split position for explicit paths", function()
      config.setup({ position = "split" })
      assert.are.same("split", resolve.decide(ctx({ arg = other_file })).request.placement)
    end)
  end)

  describe("source semantics", function()
    it("uses buffer content for the current markdown buffer", function()
      local source = resolve.decide(ctx()).request.source
      assert.are.same("buffer", source.kind)
      assert.are.same(1, source.bufnr)
      assert.are.same(current_file, source.path)
    end)

    it("unnamed buffer interactive fails with need_saved_file", function()
      local decision = resolve.decide(ctx({ bang = true, bufname = "" }))
      assert.are.same("error", decision.kind)
      assert.are.same("need_saved_file", decision.err)
      assert.truthy(resolve.error_message(decision):find("saved file"))
    end)

    it("unnamed buffer static renders the buffer without a path", function()
      local source = resolve.decide(ctx({ bufname = "" })).request.source
      assert.are.same("buffer", source.kind)
      assert.is_nil(source.path)
    end)
  end)

  describe("picker fallback", function()
    it("non-markdown buffer without args yields the picker", function()
      assert.are.same("picker", resolve.decide(ctx({ ft = "lua" })).kind)
    end)
  end)

  describe("file argument validation", function()
    it("unreadable explicit path fails with not_a_file", function()
      local decision = resolve.decide(ctx({ arg = "/definitely/not/there.md" }))
      assert.are.same("error", decision.kind)
      assert.are.same("not_a_file", decision.err)
      assert.truthy(resolve.error_message(decision):find("not/there"))
    end)
  end)
end)
