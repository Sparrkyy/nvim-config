local H = require("helpers")

describe("flow.review_ai", function()
  local ai, job, root, meta, files

  before_each(function()
    ai = H.reload("flow.review_ai")
    job = H.reload("flow.job")
    root = H.tmpdir()
    ai.cache_root = root .. "/cache"
    meta = {
      worktree = root,
      base_head = "base",
      title = "Change authentication",
    }
    files = {
      {
        file = "lua/auth.lua",
        status = "M",
        kind = "CORE",
        added = 1,
        deleted = 1,
        base_text = "return legacy",
        current_text = "return secure",
        hunks = {
          {
            old_start = 1,
            old_count = 1,
            new_start = 1,
            new_count = 1,
            deleted_lines = { "return legacy" },
          },
        },
      },
      {
        file = "tests/auth_spec.lua",
        status = "M",
        kind = "TESTS",
        added = 1,
        deleted = 0,
        base_text = "",
        current_text = "it('rejects expired tokens')",
        hunks = {
          {
            old_start = 1,
            old_count = 0,
            new_start = 1,
            new_count = 1,
            deleted_lines = {},
          },
        },
      },
    }
  end)

  local function response()
    return {
      summary = "Token validation now rejects expired credentials.",
      groups = {
        {
          title = "Verification gap",
          intent = "Review the new expiry coverage first.",
          risk = "HIGH",
          reason = "The test defines the expected boundary.",
          files = {
            {
              path = "tests/auth_spec.lua",
              summary = "Adds the expiry scenario.",
              reason = "Read the expected behavior before the implementation.",
              hunks = {
                {
                  index = 1,
                  briefing = "Adds an expired-token example.",
                  checks = { "Confirm the boundary timestamp." },
                },
              },
            },
          },
        },
      },
      test_map = {
        {
          behavior = "Reject expired tokens",
          status = "COVERED",
          evidence = "tests/auth_spec.lua:1",
        },
      },
    }
  end

  it("builds a bounded manifest with exact hunk indexes", function()
    local input = ai.review_input(meta, files)
    assert.is_truthy(input:match("FILE lua/auth.lua"))
    assert.is_truthy(input:match("HUNK 1"))
    assert.is_truthy(input:match("return legacy"))
    assert.is_truthy(input:match("return secure"))
  end)

  it("asks for a thematic evidence-backed review journey", function()
    local prompt = ai.prompt(meta, files, { intent = "Prevent expired sessions." })
    assert.is_truthy(prompt:match("Group related files by behavior"))
    assert.is_truthy(prompt:match("high%-impact or defect%-prone behavior early"))
    assert.is_truthy(prompt:match("Every changed file must appear exactly once"))
    assert.is_truthy(prompt:match("Prevent expired sessions"))
  end)

  it("uses a strict result schema", function()
    local schema = ai.schema()
    assert.is_false(schema.additionalProperties)
    assert.same({ "summary", "groups", "test_map" }, schema.required)
    assert.same({ "HIGH", "MEDIUM", "LOW" }, schema.properties.groups.items.properties.risk.enum)
  end)

  it("keeps valid AI order and appends omitted files deterministically", function()
    local analysis = assert(ai.normalize(response(), files))
    assert.same({ "tests/auth_spec.lua", "lua/auth.lua" }, analysis.order)
    assert.equals("Verification gap", analysis.group_by_file["tests/auth_spec.lua"].title)
    assert.equals("Other core changes", analysis.group_by_file["lua/auth.lua"].title)
    assert.equals("Adds an expired-token example.", analysis.hunk_insights["tests/auth_spec.lua"][1].briefing)
    assert.equals("COVERED", analysis.test_map[1].status)
  end)

  it("rejects an answer that anchors to no changed file", function()
    local data = response()
    data.groups[1].files[1].path = "lua/not_changed.lua"
    local analysis, err = ai.normalize(data, files)
    assert.is_nil(analysis)
    assert.is_truthy(err:match("did not reference"))
  end)

  it("caches a valid map by the exact review snapshot", function()
    local data = response()
    local key = ai.cache_key(meta, files)
    assert.is_true(ai.write_cache(key, data))
    local cached = assert(ai.read_cache(key, files))
    assert.equals("Token validation now rejects expired credentials.", cached.summary)
    files[1].current_text = "return changed_again"
    assert.is_not.equal(key, ai.cache_key(meta, files))
    files[1].current_text = "return secure"
    assert.is_not.equal(key, ai.cache_key(meta, files, "A revised plan"))
  end)

  it("runs a read-only structured AI job and returns normalized analysis", function()
    vim.g.flow_review_ai = true
    local captured
    job.run = function(spec)
      captured = spec
      spec.on_done(true, vim.json.encode(response()))
      return 7
    end
    local received
    local started = ai.start(meta, files, {
      on_done = function(analysis)
        received = analysis
      end,
    })
    assert.is_true(started)
    assert.equals("plan", captured.permission_mode)
    assert.equals("Read,Grep,Glob", captured.tools)
    assert.is_falsy(captured.tools:match("Edit"))
    assert.is_truthy(captured.json_schema)
    assert.same({ "tests/auth_spec.lua", "lua/auth.lua" }, received.order)
    vim.g.flow_review_ai = false
  end)
end)
