local M = {}

local store = require("flow.store")
local worktree = require("flow.worktree")

M.opts = {
  command = "claude",
  permission_mode = "auto",
  terminal_width = 0.38,
}

M.sessions = {}

local ACTIVE = {
  provisioning = true,
  implementing = true,
  implementation_failed = true,
  revising = true,
  review_ready = true,
  reviewing = true,
  merge_ready = true,
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Flow" })
end

local function present(value)
  return value ~= nil and value ~= vim.NIL and value ~= ""
end

local function fire(event, plan_id)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = event,
    data = { plan_id = plan_id },
  })
end

local function uuid(plan_id)
  local seed = vim.fn.sha256(tostring(plan_id) .. ":" .. tostring(os.time()) .. ":" .. tostring(math.random()))
  return table.concat({
    seed:sub(1, 8),
    seed:sub(9, 12),
    "4" .. seed:sub(14, 16),
    "8" .. seed:sub(18, 20),
    seed:sub(21, 32),
  }, "-")
end

function M.prompt(markdown)
  return table.concat({
    "Implement this approved plan in this worktree.",
    "Work autonomously until the implementation is complete and verified.",
    "Use the repository's real tools. Read, edit, run commands, diagnose failures, and iterate.",
    "Do not wait for a person to approve individual edits.",
    "Stay inside this worktree for every repository change.",
    "",
    "Git rules:",
    "- Commit each coherent implementation step.",
    "- Commit tests with the behavior they verify when practical.",
    "- Commit every correction that follows a failed test.",
    "- Keep the commits small enough that a review instruction can be reversed.",
    "- Do not rewrite, squash, or discard earlier commits.",
    "- Do not stop with an uncommitted or untracked file.",
    "",
    "Verification rules:",
    "- Implement the new tests named by the plan.",
    "- Run those new tests.",
    "- Run the existing targeted tests that cover the changed hot path.",
    "- Do not run the full test suite unless the plan requires it.",
    "- Do not stop until every required targeted test passes.",
    "- Run the required verification again after the final code change.",
    "- If you change Mermaid content, render every changed diagram and confirm it produces SVG.",
    "- In the final response, list every verification command and its result.",
    "",
    "<approved-plan>",
    markdown,
    "</approved-plan>",
  }, "\n")
end

function M.feedback_prompt(text, context)
  local parts = {
    "Apply this feedback from the final implementation review.",
    "Treat it as a repository-wide instruction, not only as a change to the visible hunk.",
    "Inspect the plan, implementation, tests, and related files before you decide what must change.",
    "If the requested change would break a necessary behavior, explain why and keep the correct behavior.",
    "Commit each coherent revision. Do not rewrite or discard the existing commits.",
    "Run the affected new tests and targeted hot-path tests after the final change.",
    "Do not stop until those tests pass and the worktree is clean.",
    "",
    "<review-feedback>",
    vim.trim(text),
    "</review-feedback>",
  }
  if context and vim.trim(context) ~= "" then
    vim.list_extend(parts, {
      "",
      "<review-location>",
      context,
      "</review-location>",
    })
  end
  return table.concat(parts, "\n")
end

function M.command(meta, prompt, resume)
  local cmd = {
    M.opts.command,
    "--permission-mode",
    M.opts.permission_mode,
    "--name",
    "Flow: " .. tostring(meta.title or "implementation"),
  }
  if resume then
    vim.list_extend(cmd, { "--resume", meta.session_id })
  else
    vim.list_extend(cmd, { "--session-id", meta.session_id })
  end
  if prompt and vim.trim(prompt) ~= "" then
    table.insert(cmd, prompt)
  end
  return cmd
end

function M.spawn_terminal(cmd, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  local channel
  vim.api.nvim_buf_call(buf, function()
    channel = vim.fn.termopen(cmd, {
      cwd = opts.cwd,
      env = opts.env,
      on_exit = function(_, code)
        vim.schedule(function()
          opts.on_exit(code)
        end)
      end,
    })
  end)
  if channel <= 0 then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil, "Claude Code did not start."
  end
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "flow-claude"
  vim.b[buf].flow_plan_id = opts.plan_id
  return { buf = buf, channel = channel }, nil
end

function M.send_terminal(session, text)
  if not session or not session.channel or session.channel <= 0 then
    return false
  end
  local pasted = "\27[200~" .. text .. "\27[201~\r"
  return pcall(vim.fn.chansend, session.channel, pasted)
end

local function running_session(plan_id)
  local session = M.sessions[plan_id]
  if session and session.buf and vim.api.nvim_buf_is_valid(session.buf) then
    return session
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].flow_plan_id == plan_id then
      local channel = vim.b[buf].terminal_job_id or vim.bo[buf].channel
      session = { buf = buf, channel = channel }
      M.sessions[plan_id] = session
      return session
    end
  end
  return nil
end

local function start_terminal(plan_id, prompt, resume)
  local meta = store.meta(plan_id)
  if not meta or not present(meta.worktree) or not present(meta.session_id) then
    return nil, "This plan has no implementation session."
  end
  require("claude.follow").register(meta.worktree)
  local env = vim.tbl_extend("force", {}, (vim.uv or vim.loop).os_environ())
  env.CLAUDE_NVIM_FLOW_ID = plan_id
  local session, err = M.spawn_terminal(M.command(meta, prompt, resume), {
    cwd = meta.worktree,
    env = env,
    plan_id = plan_id,
    on_exit = function(code)
      local current = M.sessions[plan_id]
      if current then
        current.exited = code
      end
    end,
  })
  if not session then
    return nil, err
  end
  M.sessions[plan_id] = session
  store.set_meta(plan_id, { session_started = true }, meta.cwd)
  return session, nil
end

local function terminal_window(session)
  if not session or not session.buf then
    return -1
  end
  return vim.fn.bufwinid(session.buf)
end

local function show_terminal(session, focus)
  local win = terminal_window(session)
  if win ~= -1 then
    if focus then
      vim.api.nvim_set_current_win(win)
      vim.cmd("startinsert")
    end
    return
  end
  local previous = vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  vim.api.nvim_win_set_buf(0, session.buf)
  vim.api.nvim_win_set_width(0, math.max(44, math.floor(vim.o.columns * M.opts.terminal_width)))
  if focus then
    vim.cmd("startinsert")
  elseif vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
end

function M.open(plan_id, opts)
  opts = opts or {}
  plan_id = plan_id or require("flow").current()
  local meta = plan_id and store.meta(plan_id)
  if not meta or not present(meta.worktree) then
    notify("This plan has no implementation session.", vim.log.levels.WARN)
    return false
  end
  local session = running_session(plan_id)
  if not session or session.exited then
    local resume = meta.session_started == true
    local prompt = nil
    if not resume then
      local revision = store.revision(plan_id, nil, meta.cwd)
      prompt = revision and revision.plan_md and M.prompt(revision.plan_md) or nil
    end
    local started, err = start_terminal(plan_id, prompt, resume)
    if not started then
      notify(err, vim.log.levels.ERROR)
      return false
    end
    session = started
  end
  show_terminal(session, opts.focus ~= false)
  return true
end

function M.toggle(plan_id)
  plan_id = plan_id or require("flow").current()
  local session = plan_id and running_session(plan_id)
  local win = terminal_window(session)
  if win ~= -1 then
    pcall(vim.api.nvim_win_close, win, false)
    return false
  end
  return M.open(plan_id, { focus = true })
end

function M.begin(plan_id)
  plan_id = plan_id or require("flow").current()
  local meta = plan_id and store.meta(plan_id)
  if not meta then
    notify("No plan to implement.", vim.log.levels.WARN)
    return false
  end
  local revision = store.revision(plan_id, nil, meta.cwd)
  if not revision or not revision.plan_md then
    notify("That plan has no approved document.", vim.log.levels.WARN)
    return false
  end
  if present(meta.worktree) and ACTIVE[meta.status] then
    M.open(plan_id)
    return true
  end

  store.set_meta(plan_id, { status = "provisioning", error = vim.NIL }, meta.cwd)
  local prepared, err = worktree.prepare(meta.cwd, plan_id)
  if not prepared then
    store.set_meta(plan_id, { status = "review", error = err }, meta.cwd)
    notify(err, vim.log.levels.ERROR)
    return false
  end

  local session_id = uuid(plan_id)
  local patch = vim.tbl_extend("force", prepared, {
    status = "implementing",
    session_id = session_id,
    verified_head = vim.NIL,
    review_cursor = 1,
    accepted_revision = meta.current_revision,
    error = vim.NIL,
  })
  meta = store.set_meta(plan_id, patch, meta.cwd)
  require("claude.follow").register(meta.worktree)

  local session, start_err = start_terminal(plan_id, M.prompt(revision.plan_md), false)
  if not session then
    store.set_meta(plan_id, { status = "implementation_failed", error = start_err }, meta.cwd)
    notify(start_err, vim.log.levels.ERROR)
    return false
  end
  show_terminal(session, false)
  notify("Claude is implementing the approved plan in " .. meta.worktree)
  fire("FlowImplementationStarted", plan_id)
  return true
end

function M.feedback(plan_id, text)
  plan_id = plan_id or require("flow").current()
  if type(text) ~= "string" or vim.trim(text) == "" then
    return false
  end
  local meta = plan_id and store.meta(plan_id)
  if not meta or not present(meta.worktree) or not present(meta.verified_head) then
    notify("Finish implementation before sending review feedback.", vim.log.levels.WARN)
    return false
  end
  local clean, clean_err = worktree.is_clean(meta.worktree)
  local head, head_err = worktree.head(meta.worktree)
  if not clean or not head or head ~= meta.verified_head then
    notify(clean_err or head_err or "The worktree changed after verification.", vim.log.levels.ERROR)
    return false
  end

  local review_context = nil
  pcall(function()
    review_context = require("flow.review").context(plan_id)
  end)
  pcall(function()
    require("flow.review").close()
  end)
  local feedback_id = store.push_feedback(plan_id, {
    body = vim.trim(text),
    checkpoint = head,
    review_cursor = meta.review_cursor or 1,
  }, meta.cwd)
  if not feedback_id then
    notify("Flow could not save the review checkpoint.", vim.log.levels.ERROR)
    return false
  end
  store.set_meta(plan_id, {
    status = "revising",
    active_feedback = feedback_id,
    verified_head = vim.NIL,
  }, meta.cwd)

  local prompt = M.feedback_prompt(text, review_context)
  local session = running_session(plan_id)
  if session and not session.exited then
    if not M.send_terminal(session, prompt) then
      notify("Flow could not send the feedback to Claude.", vim.log.levels.ERROR)
      return false
    end
  else
    local started, err = start_terminal(plan_id, prompt, true)
    if not started then
      notify(err, vim.log.levels.ERROR)
      return false
    end
    session = started
  end
  show_terminal(session, false)
  notify("Claude is applying review feedback. Review resumes after verification.")
  return true
end

function M.sync(plan_id, source_head)
  plan_id = plan_id or require("flow").current()
  local meta = plan_id and store.meta(plan_id)
  if not meta or not present(meta.verified_head) or not present(source_head) then
    notify("The implementation is not ready to sync.", vim.log.levels.WARN)
    return false
  end
  local clean, clean_err = worktree.is_clean(meta.worktree)
  local head, head_err = worktree.head(meta.worktree)
  if not clean or not head or head ~= meta.verified_head then
    notify(clean_err or head_err or "The worktree changed after verification.", vim.log.levels.ERROR)
    return false
  end

  pcall(function()
    require("flow.review").close()
  end)
  store.set_meta(plan_id, {
    status = "revising",
    pending_base_head = source_head,
    verified_head = vim.NIL,
  }, meta.cwd)
  local prompt = table.concat({
    "The source branch advanced after this implementation started.",
    "Integrate source commit " .. source_head .. " into this implementation branch.",
    "Use a merge commit. Do not rebase or rewrite the existing implementation commits.",
    "Resolve every conflict in a way that preserves the approved plan and the newer source behavior.",
    "Run the affected new tests and targeted hot-path tests after the merge.",
    "Commit every resolution. Do not stop until the tests pass and the worktree is clean.",
  }, "\n")

  local session = running_session(plan_id)
  if session and not session.exited then
    if not M.send_terminal(session, prompt) then
      notify("Flow could not send the source update to Claude.", vim.log.levels.ERROR)
      return false
    end
  else
    local started, err = start_terminal(plan_id, prompt, true)
    if not started then
      notify(err, vim.log.levels.ERROR)
      return false
    end
    session = started
  end
  show_terminal(session, false)
  notify("The source branch advanced. Claude is integrating it before review continues.")
  return true
end

function M.interrupt(plan_id)
  plan_id = plan_id or require("flow").current()
  local session = plan_id and running_session(plan_id)
  if not session or not session.channel then
    notify("The Flow session is not running.", vim.log.levels.WARN)
    return false
  end
  pcall(vim.fn.chansend, session.channel, "\27")
  return true
end

function M.prompt_submitted(encoded)
  local ok, result = pcall(function()
    local data = vim.json.decode(vim.base64.decode(encoded))
    local plan_id = data.plan_id
    local text = type(data.prompt) == "string" and vim.trim(data.prompt) or ""
    if text == "" or vim.startswith(text, "/") then
      return "ignored"
    end
    local meta = plan_id and store.meta(plan_id)
    local review_state = meta and (
      meta.status == "review_ready" or meta.status == "reviewing" or meta.status == "merge_ready"
    )
    if not review_state or not present(meta.verified_head) then
      return "ignored"
    end
    if data.cwd and vim.fn.resolve(data.cwd) ~= vim.fn.resolve(meta.worktree) then
      return "ignored"
    end
    local clean = worktree.is_clean(meta.worktree)
    local head = worktree.head(meta.worktree)
    if not clean or head ~= meta.verified_head then
      return "ignored"
    end
    local feedback_id = store.push_feedback(plan_id, {
      body = text,
      checkpoint = head,
      review_cursor = meta.review_cursor or 1,
      source = "terminal",
    }, meta.cwd)
    if not feedback_id then
      return "ignored"
    end
    store.set_meta(plan_id, {
      status = "revising",
      active_feedback = feedback_id,
      verified_head = vim.NIL,
    }, meta.cwd)
    vim.schedule(function()
      pcall(function()
        require("flow.review").close()
      end)
    end)
    return "checkpointed"
  end)
  return ok and result or "ignored"
end

function M.shutdown(plan_id)
  plan_id = plan_id or require("flow").current()
  local session = plan_id and running_session(plan_id)
  if not session then
    return
  end
  local win = terminal_window(session)
  if win ~= -1 then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if session.channel and session.channel > 0 then
    pcall(vim.fn.jobstop, session.channel)
  end
  if session.buf and vim.api.nvim_buf_is_valid(session.buf) then
    pcall(vim.api.nvim_buf_delete, session.buf, { force = true })
  end
  M.sessions[plan_id] = nil
end

local function continue_with(message)
  return "continue:" .. message:gsub("[\r\n]+", " ")
end

function M.stop(encoded)
  local ok, result = pcall(function()
    local data = vim.json.decode(vim.base64.decode(encoded))
    local plan_id = data.plan_id
    local meta = plan_id and store.meta(plan_id)
    if not meta or not present(meta.worktree) then
      return "ignore"
    end
    if data.cwd and vim.fn.resolve(data.cwd) ~= vim.fn.resolve(meta.worktree) then
      return "ignore"
    end
    if data.session_id and data.session_id ~= "" then
      store.set_meta(plan_id, { session_id = data.session_id }, meta.cwd)
      meta.session_id = data.session_id
    end

    local clean, clean_err = worktree.is_clean(meta.worktree)
    if not clean then
      store.set_meta(plan_id, { status = meta.status == "revising" and "revising" or "implementing" }, meta.cwd)
      return continue_with("Commit every tracked and untracked change before you stop. " .. tostring(clean_err or ""))
    end
    local head, head_err = worktree.head(meta.worktree)
    if not head then
      return continue_with("Git could not read the implementation HEAD. " .. tostring(head_err or ""))
    end
    if meta.status ~= "revising" and head == meta.base_head then
      return continue_with("The approved plan has no committed implementation yet. Implement it, verify it, and commit it.")
    end
    if meta.status ~= "revising" then
      local changed = worktree.git(meta.worktree, { "diff", "--quiet", meta.base_head .. ".." .. head })
      if changed.ok then
        return continue_with("The implementation commits do not change the repository yet. Implement the approved plan and verify it.")
      end
      if changed.code and changed.code ~= 1 then
        return continue_with("Git could not compare the implementation with its base commit.")
      end
    end

    local base_head = meta.base_head
    if present(meta.pending_base_head) then
      local ancestry = worktree.git(meta.worktree, {
        "merge-base", "--is-ancestor", meta.pending_base_head, head,
      })
      if not ancestry.ok then
        return continue_with("Merge source commit " .. meta.pending_base_head .. " into this branch before you stop.")
      end
      base_head = meta.pending_base_head
    end

    if present(meta.active_feedback) then
      store.update_feedback(plan_id, meta.active_feedback, {
        status = "verified",
        head = head,
        finished = os.time(),
      }, meta.cwd)
    end
    store.set_meta(plan_id, {
      status = "review_ready",
      verified_head = head,
      verified_at = os.time(),
      verification_summary = type(data.summary) == "string" and data.summary:sub(1, 20000) or "",
      active_feedback = vim.NIL,
      base_head = base_head,
      pending_base_head = vim.NIL,
      review_cursor = 1,
      error = vim.NIL,
    }, meta.cwd)
    notify("Implementation is committed and verified. Opening the finished diff.")
    fire("FlowReviewReady", plan_id)
    return "ready"
  end)
  if not ok then
    return continue_with("Flow could not inspect the worktree: " .. tostring(result))
  end
  return result
end

function M.recover(cwd)
  for _, meta in ipairs(store.plans(cwd or vim.fn.getcwd())) do
    if present(meta.worktree) and ACTIVE[meta.status] and vim.fn.isdirectory(meta.worktree) == 1 then
      require("claude.follow").register(meta.worktree)
    end
  end
end

function M.statusline(plan_id)
  plan_id = plan_id or require("flow").current()
  local meta = plan_id and store.meta(plan_id)
  if not meta or not ACTIVE[meta.status] then
    return ""
  end
  return "󰐅 flow " .. tostring(meta.status):gsub("_", " ")
end

return M
