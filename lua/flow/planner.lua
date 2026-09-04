-- Stage one and stage two: write the design doc, then revise it.
--
-- Both run in one persistent Claude Code terminal. A first plan gets your
-- context. A revision sends the current document and browser comments back to
-- the same conversation.
--
-- When a revision lands, this fires the `FlowPlanReady` User autocmd with the
-- plan id in `data`. flow.init listens and opens the browser. Nothing here
-- knows the server exists.

local M = {}

local job = require("flow.job")
local store = require("flow.store")
local sessions = require("claude.sessions")

M.opts = {
  command = "claude",
  tools = "Read,Grep,Glob,AskUserQuestion",
}

--- The output contract ------------------------------------------------------

-- This rides on --append-system-prompt. It is the only thing that keeps the
-- document machine-readable, so change it and change flow.web/app.html too.
M.DOC_CONTRACT = table.concat({
  "You are writing a design document that a person reads in a browser and",
  "comments on. Obey these rules exactly.",
  "",
  "LANGUAGE. Write in ASD-STE100 Simplified Technical English:",
  "- Write short sentences. Twenty words is the limit for an instruction.",
  "- Write one idea in each sentence.",
  "- Use the active voice. Do not use the passive voice.",
  "- Use the simple present tense when you can.",
  "- Give each word one meaning. Use the same word for the same idea.",
  "- Do not use slang, idioms, or metaphors.",
  "- Start an instruction with the verb.",
  "- Use a list for steps and for a set of items.",
  "",
  "NARRATION. The browser reads one section aloud at a time:",
  "- Write for a listener who cannot scan ahead.",
  "- Use a technical term only when it is necessary.",
  "- Define each technical term in plain language when you first use it.",
  "- Spell out an uncommon acronym when you first use it.",
  "- Put commands, paths, symbols, and long identifiers in snippets.",
  "- Explain the purpose of each snippet in ordinary prose.",
  "- Introduce each diagram with a short explanation of its reading order.",
  "",
  "OUTPUT. Return the document as markdown and nothing else. Do not wrap it in",
  "a code fence. Do not add a preface or a closing remark.",
  "",
  "STRUCTURE. Use these headings, in this order. Omit a heading only when it",
  "has no content:",
  "  # <title>",
  "  ## Context      why this change is necessary, and what it must achieve",
  "  ## Approach     the design, in prose and lists",
  "  ## Diagrams     the code flow, as diagrams",
  "  ## Changes      one `### <path>` subsection per file, with the intent",
  "                  of the change and short illustrative snippets",
  "  ## Verification targeted tests and commands that prove the change works",
  "  ## Risks        what can go wrong, and what you are unsure about",
  "",
  "CODE CHANGES. Use a ```diff fence for each behavior-changing snippet.",
  "Show only the smallest useful before-and-after lines. Mark removed lines",
  "with `-` and added lines with `+`. The review page animates these changes.",
  "Use a language-specific fence only when no existing code changes.",
  "",
  "DIAGRAMS. Draw every code flow in a ```mermaid fence. Prefer `flowchart TD`",
  "and `sequenceDiagram`. Give at least one diagram whenever control passes",
  "between more than two places. Keep node labels to a few words. Do not put",
  "parentheses, quotes, or semicolons inside a node label, because they break",
  "the renderer. Use Mermaid 11 syntax. Before you return, inspect every",
  "diagram for renderer-safe syntax. A diagram is complete only when Mermaid",
  "can render it as SVG. Simplify any diagram whose syntax is uncertain.",
  "The review page renders every diagram and blocks approval if any render",
  "fails. Treat a renderer failure as a failed plan that requires revision.",
  "",
  "SUBSTANCE. Read the repository first. Name real files and real functions.",
  "Point at code that already exists and can be reused. Do not invent an API.",
  "",
  "VERIFICATION. Make the implementation gate explicit:",
  "- Name each new test that proves the requested behavior.",
  "- Name existing tests that cover the changed hot path.",
  "- Give the exact command for each targeted test group.",
  "- Explain why each existing test is relevant.",
  "- Do not require the full suite unless targeted tests cannot prove safety.",
}, "\n")

--- Helpers ------------------------------------------------------------------

--- The title of a document: its first level-one heading.
function M.title_of(markdown)
  local title = tostring(markdown or ""):match("^%s*#%s+([^\n]+)")
  if title then
    return vim.trim(title)
  end
  return "Untitled plan"
end

local function fire(event, plan_id)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = event,
    data = { plan_id = plan_id },
  })
end

function M.session_key(plan_id)
  return "flow-plan-" .. tostring(plan_id)
end

function M.result_path(plan_id, cwd)
  return store.plan_dir(plan_id, cwd) .. "/terminal-result.json"
end

function M.command(meta, prompt, resume)
  local title = "Flow plan: " .. tostring(meta.title or "Planning")
  local cmd = {
    M.opts.command,
    "--permission-mode", "plan",
    "--name", title,
    "--tools", M.opts.tools,
    "--ide",
  }
  if resume then
    vim.list_extend(cmd, { "--resume", meta.planning_session_id })
  else
    vim.list_extend(cmd, {
      "--session-id", meta.planning_session_id,
      "--append-system-prompt", M.DOC_CONTRACT,
    })
  end
  table.insert(cmd, prompt)
  return cmd
end

function M.launch(spec)
  return sessions.new_terminal_session(spec)
end

function M.find_session(key)
  return sessions.find_by_key(key)
end

function M.send_session(id, prompt)
  return sessions.send(id, prompt)
end

function M.show_session(id)
  return sessions.show_manager({ selected_id = id })
end

local function clear_result(plan_id, cwd)
  pcall(vim.fn.delete, M.result_path(plan_id, cwd))
end

local function start_terminal(plan_id, prompt, opts)
  opts = opts or {}
  local meta = store.meta(plan_id, opts.cwd)
  if not meta then
    return nil, "Flow could not read the plan."
  end
  local cwd = opts.cwd or meta.cwd
  local key = M.session_key(plan_id)
  local session_id = meta.planning_session_id
  local resume = session_id ~= nil and session_id ~= vim.NIL and session_id ~= ""
  if not resume then
    session_id = sessions.uuid(key)
  end
  meta = store.set_meta(plan_id, {
    status = "planning",
    planning_session_id = session_id,
    planning_session_key = key,
    pending_prompt = prompt,
    pending_addressed_comments = opts.addressed or {},
    error = vim.NIL,
  }, cwd)
  if not meta then
    return nil, "Flow could not save the planning session."
  end

  clear_result(plan_id, cwd)
  require("claude.follow").register(cwd)

  local existing = M.find_session(key)
  if existing then
    if not M.send_session(existing.id, prompt) then
      return nil, "Claude Code did not accept the planning prompt."
    end
    M.show_session(existing.id)
    return existing.id
  end

  local title = opts.title or "Flow plan: " .. tostring(meta.title or "Planning")
  local resume_args = {
    "--permission-mode", "plan",
    "--tools", M.opts.tools,
  }
  local id = M.launch({
    key = key,
    title = title,
    kind = "Flow plan",
    prompt = prompt,
    cwd = cwd,
    session_id = session_id,
    cmd = M.command(meta, prompt, resume),
    resume_args = resume_args,
    persistent = true,
    pinned = true,
    env_overrides = {
      CLAUDE_NVIM_FLOW_PLAN_ID = plan_id,
      CLAUDE_NVIM_FLOW_PLAN_RESULT = M.result_path(plan_id, cwd),
    },
  })
  if not id then
    return nil, "Claude Code did not start."
  end
  store.set_meta(plan_id, { planning_registry_id = id }, cwd)
  return id
end

--- Stage one ----------------------------------------------------------------

--- The prompt for a first plan.
function M.first_prompt(context)
  return table.concat({
    "Plan a change to this repository. Write the design document only.",
    "Do not change any file.",
    "",
    "This is what I want:",
    "",
    "<request>",
    vim.trim(context),
    "</request>",
  }, "\n")
end

--- Start a new plan.
---@param context string what you typed in the composer
---@param opts table|nil { cwd: string|nil }
---@return string|nil plan_id
function M.start(context, opts)
  opts = opts or {}
  if type(context) ~= "string" or vim.trim(context) == "" then
    return nil
  end

  local cwd = opts.cwd or vim.fn.getcwd()
  local prompt = M.first_prompt(context)
  local plan_id = store.create({ title = "Planning...", prompt = context, cwd = cwd })
  if not plan_id then
    vim.notify("Flow could not write to its state directory.", vim.log.levels.ERROR, { title = "Flow" })
    return nil
  end

  local _, err = start_terminal(plan_id, prompt, {
    cwd = cwd,
    title = "Plan: " .. vim.trim(context):sub(1, 48),
  })
  if err then
    M.receive(plan_id, false, nil, { detail = err }, { prompt = prompt, cwd = cwd })
  end

  return plan_id
end

--- Stage two ----------------------------------------------------------------

--- The prompt for a revision.
---@param markdown string the current document
---@param comments table the comments to answer
function M.replan_prompt(markdown, comments)
  local parts = {
    "Revise this design document. Answer every comment.",
    "Do not change any file.",
    "",
    "<document>",
    markdown,
    "</document>",
    "",
    "<comments>",
  }
  for _, c in ipairs(comments) do
    table.insert(parts, string.format("[%s] on the section %q", c.id or "?", c.anchor or "the document"))
    if c.quote and vim.trim(c.quote) ~= "" then
      table.insert(parts, "  about this text: " .. vim.trim(c.quote))
    end
    table.insert(parts, "  says: " .. vim.trim(c.body or ""))
    table.insert(parts, "")
  end
  table.insert(parts, "</comments>")
  table.insert(parts, "")
  table.insert(parts, "Return the complete revised document. Do not return a diff or a summary")
  table.insert(parts, "of what you changed. Keep every part the comments do not touch.")
  return table.concat(parts, "\n")
end

--- Revise a plan from its open comments.
---@return boolean started
function M.replan(plan_id, opts)
  opts = opts or {}
  local meta = store.meta(plan_id, opts.cwd)
  if not meta then
    return false
  end
  local revision = store.revision(plan_id, nil, opts.cwd)
  if not revision or not revision.plan_md then
    return false
  end

  local comments = store.open_comments(plan_id, opts.cwd)
  if #comments == 0 then
    vim.notify("No new comments to answer.", vim.log.levels.WARN, { title = "Flow" })
    return false
  end

  local ids = vim.tbl_map(function(c)
    return c.id
  end, comments)
  local prompt = M.replan_prompt(revision.plan_md, comments)
  local cwd = opts.cwd or meta.cwd

  local _, err = start_terminal(plan_id, prompt, {
    cwd = cwd,
    title = string.format("Replan: %s (%d comments)", meta.title, #comments),
    addressed = ids,
  })
  if err then
    M.receive(plan_id, false, nil, { detail = err }, { prompt = prompt, cwd = cwd, addressed = ids })
    return false
  end
  return true
end

--- Landing ------------------------------------------------------------------

--- Store a finished job as the next revision.
function M.receive(plan_id, ok, text, info, ctx)
  ctx = ctx or {}
  info = info or {}
  if not ok then
    store.set_meta(plan_id, {
      status = "review",
      error = tostring(info.detail or "the terminal session failed"),
      pending_prompt = vim.NIL,
      pending_addressed_comments = vim.NIL,
    }, ctx.cwd)
    fire("FlowPlanFailed", plan_id)
    return false
  end

  local markdown = job.decode_markdown(text)
  if vim.trim(markdown) == "" then
    store.set_meta(plan_id, {
      status = "review",
      error = "the terminal session returned an empty document",
      pending_prompt = vim.NIL,
      pending_addressed_comments = vim.NIL,
    }, ctx.cwd)
    fire("FlowPlanFailed", plan_id)
    return false
  end

  local n = store.add_revision(plan_id, {
    plan_md = markdown,
    prompt = ctx.prompt,
    session_id = info.session_id,
    cost = info.cost,
    addressed_comments = ctx.addressed or {},
  }, ctx.cwd)
  if not n then
    fire("FlowPlanFailed", plan_id)
    return false
  end

  if ctx.addressed and #ctx.addressed > 0 then
    store.address_comments(plan_id, ctx.addressed, n, ctx.cwd)
  end
  store.set_meta(plan_id, {
    title = M.title_of(markdown),
    status = "review",
    error = vim.NIL,
    planning_session_id = info.session_id,
    pending_prompt = vim.NIL,
    pending_addressed_comments = vim.NIL,
  }, ctx.cwd)

  local record = M.find_session(M.session_key(plan_id))
  if record then
    sessions.rename(record.id, "Flow plan: " .. M.title_of(markdown))
  end

  fire("FlowPlanReady", plan_id)
  return true
end

local function finish_terminal_result(plan_id, data, cwd)
  local meta = store.meta(plan_id, cwd)
  if not meta or meta.status ~= "planning" then
    return "ignore"
  end
  if data.cwd and data.cwd ~= "" and vim.fn.resolve(data.cwd) ~= vim.fn.resolve(meta.cwd) then
    return "ignore"
  end
  local session_id = data.session_id
  if session_id == nil or session_id == "" then
    session_id = meta.planning_session_id
  end
  local ok = M.receive(plan_id, true, data.summary, {
    session_id = session_id,
  }, {
    cwd = meta.cwd,
    prompt = meta.pending_prompt,
    addressed = type(meta.pending_addressed_comments) == "table" and meta.pending_addressed_comments or {},
  })
  clear_result(plan_id, meta.cwd)
  return ok and "ready" or "failed"
end

function M.stop(encoded)
  local ok, result = pcall(function()
    local data = vim.json.decode(vim.base64.decode(encoded))
    if type(data) ~= "table" or type(data.plan_id) ~= "string" then
      return "ignore"
    end
    return finish_terminal_result(data.plan_id, data)
  end)
  return ok and result or "failed"
end

function M.recover(cwd)
  local recovered = 0
  for _, meta in ipairs(store.plans(cwd or vim.fn.getcwd())) do
    if meta.status == "planning" then
      local data = store.read_json(M.result_path(meta.id, meta.cwd))
      if type(data) == "table" and type(data.summary) == "string" and vim.trim(data.summary) ~= "" then
        if finish_terminal_result(meta.id, data, meta.cwd) == "ready" then
          recovered = recovered + 1
        end
      end
    end
  end
  return recovered
end

return M
