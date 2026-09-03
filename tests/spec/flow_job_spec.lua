-- The headless Claude engine. No test here starts the real CLI.

local H = require("helpers")

describe("flow.job", function()
  local job

  before_each(function()
    require("claude.sessions").reset()
    job = H.reload("flow.job")
    require("claude.hud").close_all()
  end)

  after_each(function()
    require("claude.hud").close_all()
    require("claude.sessions").reset()
  end)

  --- The command ------------------------------------------------------------

  local function flags(cmd)
    local out = {}
    for i, arg in ipairs(cmd) do
      out[arg] = cmd[i + 1]
    end
    return out
  end

  it("runs claude in print mode with a parsable stream", function()
    local cmd = job.command({ prompt = "hello" })
    assert.equals("claude", cmd[1])
    assert.is_true(vim.tbl_contains(cmd, "-p"))
    assert.equals("stream-json", flags(cmd)["--output-format"])
  end)

  it("inherits the configured Claude model", function()
    assert.is_false(vim.tbl_contains(job.command({ prompt = "x" }), "--model"))
  end)

  it("never lets a background job ask a question", function()
    assert.equals("AskUserQuestion", flags(job.command({ prompt = "x" }))["--disallowedTools"])
  end)

  it("plans by default, so no job edits a file by accident", function()
    assert.equals("plan", flags(job.command({ prompt = "x" }))["--permission-mode"])
    assert.equals("Read,Grep,Glob", flags(job.command({ prompt = "x" }))["--tools"])
  end)

  it("keeps a resumable session and accepts live guidance", function()
    local cmd = job.command({ prompt = "x", title = "Plan it", session_id = "session-1" })
    assert.equals("stream-json", flags(cmd)["--input-format"])
    assert.equals("session-1", flags(cmd)["--session-id"])
    assert.equals("Plan it", flags(cmd)["--name"])
    assert.is_false(vim.tbl_contains(cmd, "--no-session-persistence"))
  end)

  it("passes a JSON schema through as JSON", function()
    local cmd = job.command({ prompt = "x", json_schema = { type = "object" } })
    assert.equals('{"type":"object"}', flags(cmd)["--json-schema"])
  end)

  it("omits the optional flags when nothing asks for them", function()
    local cmd = job.command({ prompt = "x" })
    assert.is_false(vim.tbl_contains(cmd, "--json-schema"))
    assert.is_false(vim.tbl_contains(cmd, "--max-turns"))
    assert.is_false(vim.tbl_contains(cmd, "--append-system-prompt"))
  end)

  --- Reading a reply --------------------------------------------------------

  it("decodes bare JSON", function()
    assert.same({ a = 1 }, job.decode_result('{"a":1}'))
  end)

  it("decodes JSON the model wrapped in a fence", function()
    assert.same({ a = 1 }, job.decode_result('```json\n{"a":1}\n```'))
    assert.same({ a = 1 }, job.decode_result('```\n{"a":1}\n```'))
  end)

  it("returns nil rather than throwing on text that is not JSON", function()
    assert.is_nil(job.decode_result("sorry, I cannot"))
    assert.is_nil(job.decode_result(nil))
  end)

  it("unwraps a fenced document and trims it", function()
    assert.equals("# Title", job.decode_markdown("```markdown\n# Title\n```"))
    assert.equals("# Title", job.decode_markdown("  # Title  \n"))
    assert.equals("", job.decode_markdown(nil))
  end)

  it("leaves a fence that is inside the document alone", function()
    local doc = "# Title\n\n```lua\nlocal x = 1\n```\n\n## End"
    assert.equals(doc, job.decode_markdown(doc))
  end)

  --- Running ----------------------------------------------------------------

  it("refuses an empty prompt", function()
    H.capture_notify(function()
      assert.is_nil(job.run({ prompt = "" }))
      assert.is_nil(job.run({}))
    end)
  end)

  it("hands the result text to the caller", function()
    H.stub_flow_spawn(job, "the answer")
    local got
    job.run({
      prompt = "x",
      on_done = function(ok, text)
        got = { ok = ok, text = text }
      end,
    })
    H.settle()
    assert.is_true(got.ok)
    assert.equals("the answer", got.text)
  end)

  it("hands back the session id it saw in the stream", function()
    H.stub_flow_spawn(job, "hi", { session_id = "abc-123" })
    local info
    job.run({
      prompt = "x",
      on_done = function(_, _, i)
        info = i
      end,
    })
    H.settle()
    assert.equals("abc-123", info.session_id)
  end)

  it("fails when the process exits badly", function()
    H.stub_flow_spawn(job, "hi", { code = 1 })
    local ok
    H.capture_notify(function()
      job.run({
        prompt = "x",
        on_done = function(o)
          ok = o
        end,
      })
      H.settle()
    end)
    assert.is_false(ok)
  end)

  it("fails when the stream says it is an error", function()
    H.stub_flow_spawn(job, "hi", { error = true })
    local ok
    H.capture_notify(function()
      job.run({
        prompt = "x",
        on_done = function(o)
          ok = o
        end,
      })
      H.settle()
    end)
    assert.is_false(ok)
  end)

  it("forgets a job once it is finished", function()
    H.stub_flow_spawn(job, "hi")
    job.run({ prompt = "x" })
    H.settle()
    assert.equals(0, job.count())
    assert.is_false(job.is_running())
  end)

  it("refuses to start more jobs than the limit", function()
    job.spawn = function()
      return { kill = function() end }
    end
    for _ = 1, job.opts.max_concurrent do
      job.run({ prompt = "x" })
    end
    local seen = H.capture_notify(function()
      assert.is_nil(job.run({ prompt = "x" }))
    end)
    assert.is_truthy(seen[1].msg:match("already running"))
  end)

  it("shows the job in the window while it runs", function()
    job.spawn = function()
      return { kill = function() end }
    end
    job.run({ prompt = "x", title = "Plan the thing" })
    assert.is_true(require("claude.hud").is_open())
    assert.is_truthy(table.concat(require("claude.hud").lines(), "\n"):match("Plan the thing"))
  end)

  it("keeps the follow hook from driving the editor", function()
    local seen
    job.spawn = function(_, opts)
      seen = opts.env
      return { kill = function() end }
    end
    job.run({ prompt = "x" })
    assert.equals("1", seen.CLAUDE_NVIM_FOLLOW_DISABLE)
  end)

  it("writes the first prompt and live guidance to the same process", function()
    local writes = {}
    job.spawn = function()
      return {
        write = function(_, value)
          table.insert(writes, value)
        end,
        kill = function() end,
      }
    end
    local id = job.run({ prompt = "Make the plan", title = "Planning" })
    assert.is_true(require("claude.sessions").send(id, "Keep the API stable"))

    assert.equals(2, #writes)
    assert.equals("Make the plan", vim.json.decode(writes[1]).message.content[1].text)
    assert.equals("Keep the API stable", vim.json.decode(writes[2]).message.content[1].text)
    job.stop_all()
  end)

  it("survives a line of stream JSON it cannot parse", function()
    job.spawn = function(_, opts, on_exit)
      opts.stdout(nil, "not json at all\n")
      opts.stdout(nil, vim.json.encode({ type = "result", result = "fine" }) .. "\n")
      on_exit({ code = 0 })
      return { kill = function() end }
    end
    local text
    job.run({
      prompt = "x",
      on_done = function(_, t)
        text = t
      end,
    })
    H.settle()
    assert.equals("fine", text)
  end)

  it("reads an event split across two chunks", function()
    local event = vim.json.encode({ type = "result", result = "whole" }) .. "\n"
    job.spawn = function(_, opts, on_exit)
      opts.stdout(nil, event:sub(1, 12))
      opts.stdout(nil, event:sub(13))
      on_exit({ code = 0 })
      return { kill = function() end }
    end
    local text
    job.run({
      prompt = "x",
      on_done = function(_, t)
        text = t
      end,
    })
    H.settle()
    assert.equals("whole", text)
  end)

  it("reads a final event that arrives with no trailing newline", function()
    job.spawn = function(_, opts, on_exit)
      opts.stdout(nil, vim.json.encode({ type = "result", result = "last" }))
      on_exit({ code = 0 })
      return { kill = function() end }
    end
    local text
    job.run({
      prompt = "x",
      on_done = function(_, t)
        text = t
      end,
    })
    H.settle()
    assert.equals("last", text)
  end)

  it("stops every job in flight, so none outlives Neovim", function()
    local killed = 0
    job.spawn = function()
      return {
        kill = function()
          killed = killed + 1
        end,
      }
    end
    job.run({ prompt = "one" })
    job.run({ prompt = "two" })
    assert.equals(2, job.count())

    job.stop_all()
    assert.equals(2, killed)
    assert.equals(0, job.count())
  end)
end)
