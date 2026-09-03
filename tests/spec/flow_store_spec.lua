-- Everything Flow keeps on disk. Nothing here may throw on a broken file.

local H = require("helpers")

describe("flow.store", function()
  local store, cwd

  before_each(function()
    store = H.reload("flow.store")
    H.flow_root(store)
    cwd = H.tmpdir()
  end)

  local function plan()
    return store.create({ title = "A plan", prompt = "do a thing", cwd = cwd })
  end

  it("gives two directories with the same tail their own state", function()
    local a = store.project_dir("/one/deep/path/project")
    local b = store.project_dir("/another/deep/path/project")
    assert.is_not.equal(a, b)
    assert.is_truthy(a:match("project_%x%x%x%x%x%x%x%x$"))
  end)

  it("keeps the working directory readable in the path", function()
    assert.is_truthy(store.project_dir("/home/me/beans"):match("home_me_beans"))
  end)

  it("never hands out the same plan id twice", function()
    local seen = {}
    for _ = 1, 50 do
      local id = store.new_id()
      assert.is_nil(seen[id])
      seen[id] = true
    end
  end)

  it("writes a new plan and reads it back", function()
    local id = plan()
    local meta = store.meta(id, cwd)
    assert.equals("A plan", meta.title)
    assert.equals("planning", meta.status)
    assert.equals(0, meta.current_revision)
  end)

  it("returns nil for a plan that is not there", function()
    assert.is_nil(store.meta("nope", cwd))
  end)

  it("returns nil for a file that is not JSON", function()
    local path = store.plan_dir("junk", cwd) .. "/meta.json"
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "this is not json {{{" }, path)
    assert.is_nil(store.read_json(path))
  end)

  it("skips a broken plan when it lists them", function()
    plan()
    local path = store.plan_dir("junk", cwd) .. "/meta.json"
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "not json" }, path)
    assert.equals(1, #store.plans(cwd))
  end)

  it("merges a patch into the meta, keeping the rest", function()
    local id = plan()
    store.set_meta(id, { status = "review" }, cwd)
    local meta = store.meta(id, cwd)
    assert.equals("review", meta.status)
    assert.equals("A plan", meta.title)
  end)

  it("numbers revisions from one and moves the current pointer", function()
    local id = plan()
    assert.equals(1, store.add_revision(id, { plan_md = "# One" }, cwd))
    assert.equals(2, store.add_revision(id, { plan_md = "# Two" }, cwd))
    assert.equals(2, store.meta(id, cwd).current_revision)
    assert.equals("# Two", store.revision(id, nil, cwd).plan_md)
    assert.equals("# One", store.revision(id, 1, cwd).plan_md)
  end)

  it("has no revision before the first job lands", function()
    assert.is_nil(store.revision(plan(), nil, cwd))
  end)

  it("keeps a comment and hands back its id", function()
    local id = plan()
    local cid = store.add_comment(id, { anchor = "approach#1", quote = "this", body = "wrong" }, cwd)
    local list = store.comments(id, cwd)
    assert.equals(1, #list)
    assert.equals(cid, list[1].id)
    assert.equals("wrong", list[1].body)
  end)

  it("counts every new comment as open", function()
    local id = plan()
    store.add_comment(id, { body = "one" }, cwd)
    store.add_comment(id, { body = "two" }, cwd)
    assert.equals(2, #store.open_comments(id, cwd))
  end)

  it("keeps an answered comment on disk instead of deleting it", function()
    local id = plan()
    local cid = store.add_comment(id, { body = "one" }, cwd)
    store.add_comment(id, { body = "two" }, cwd)
    store.address_comments(id, { cid }, 2, cwd)

    assert.equals(2, #store.comments(id, cwd))
    assert.equals(1, #store.open_comments(id, cwd))
    assert.equals(2, store.comments(id, cwd)[1].addressed_in)
  end)

  it("deletes only the comment you name", function()
    local id = plan()
    local cid = store.add_comment(id, { body = "one" }, cwd)
    store.add_comment(id, { body = "two" }, cwd)
    assert.is_true(store.remove_comment(id, cid, cwd))
    assert.is_false(store.remove_comment(id, cid, cwd))
    assert.equals(1, #store.comments(id, cwd))
  end)

  it("keeps anchored implementation review comments through their lifecycle", function()
    local id = plan()
    local cid = store.add_review_comment(id, {
      file = "lua/a.lua",
      start_line = 4,
      end_line = 6,
      quote = "old text",
      body = "Use the shared helper",
    }, cwd)
    assert.equals(1, #store.open_review_comments(id, cwd))
    store.update_review_comment(id, cid, { start_line = 5 }, cwd)
    assert.equals(5, store.review_comments(id, cwd)[1].start_line)
    store.set_review_comment_status(id, { cid }, "resolved", "head123", cwd)
    assert.equals(0, #store.open_review_comments(id, cwd))
    assert.equals("head123", store.review_comments(id, cwd)[1].head)
    store.set_review_comment_status(id, { cid }, "open", "head456", cwd)
    assert.equals(1, #store.open_review_comments(id, cwd))
    assert.is_true(store.remove_review_comment(id, cid, cwd))
    assert.same({}, store.review_comments(id, cwd))
  end)

  it("round-trips the steps", function()
    local id = plan()
    store.set_steps(id, { { id = "a", title = "Add a flag" } }, cwd)
    assert.equals("Add a flag", store.steps(id, cwd)[1].title)
  end)

  it("returns an empty list, not nil, when there are no steps", function()
    assert.same({}, store.steps(plan(), cwd))
    assert.same({}, store.comments(plan(), cwd))
    assert.same({}, store.review_comments(plan(), cwd))
    assert.same({}, store.feedback(plan(), cwd))
    assert.same({}, store.applied(plan(), cwd))
  end)

  it("keeps review feedback with its commit checkpoint", function()
    local id = plan()
    local fid = store.push_feedback(id, { body = "remove the flag", checkpoint = "abc" }, cwd)
    assert.equals(fid, store.last_feedback(id, cwd).id)
    assert.equals("abc", store.last_feedback(id, cwd).checkpoint)
    store.update_feedback(id, fid, { status = "verified", head = "def" }, cwd)
    assert.equals("verified", store.last_feedback(id, cwd).status)
    assert.equals("def", store.last_feedback(id, cwd).head)
  end)

  it("keeps a step id with a slash out of the file name", function()
    local id = plan()
    store.set_diff(id, "lua/flow/init", { edits = {} }, cwd)
    assert.is_table(store.diff(id, "lua/flow/init", cwd))
  end)

  it("drops every diff at once", function()
    local id = plan()
    store.set_diff(id, "one", { edits = {} }, cwd)
    store.clear_diffs(id, cwd)
    assert.is_nil(store.diff(id, "one", cwd))
  end)

  it("pops the undo journal newest first", function()
    local id = plan()
    store.push_applied(id, { step_id = "a", file = "/x" }, cwd)
    store.push_applied(id, { step_id = "b", file = "/y" }, cwd)
    assert.equals("b", store.pop_applied(id, cwd).step_id)
    assert.equals("a", store.pop_applied(id, cwd).step_id)
    assert.is_nil(store.pop_applied(id, cwd))
  end)

  it("lists the plans newest first", function()
    local a = store.create({ title = "old", cwd = cwd })
    store.set_meta(a, { created = 100 }, cwd)
    local b = store.create({ title = "new", cwd = cwd })
    store.set_meta(b, { created = 200 }, cwd)
    assert.equals("new", store.plans(cwd)[1].title)
  end)

  it("keeps two working directories apart", function()
    plan()
    assert.equals(0, #store.plans(H.tmpdir()))
  end)

  it("lists plans across every working directory", function()
    local first = store.create({ title = "first repo", cwd = cwd })
    store.set_meta(first, { created = 100 }, cwd)
    local other = H.tmpdir()
    local second = store.create({ title = "second repo", cwd = other })
    store.set_meta(second, { created = 200 }, other)

    local plans = store.all_plans()
    assert.equals(2, #plans)
    assert.equals("second repo", plans[1].title)
    assert.equals("first repo", plans[2].title)
  end)
end)
