-- Stage one and stage two: write the design doc, then revise it.
--
-- Both run the same background job. The difference is the prompt. A first
-- plan gets your context. A revision gets the current document plus every
-- comment you left on it in the browser.
--
-- When a revision lands, this fires the `FlowPlanReady` User autocmd with the
-- plan id in `data`. flow.init listens and opens the browser. Nothing here
-- knows the server exists.

local M = {}

local job = require("flow.job")
local store = require("flow.store")

M.opts = {
  tools = "Read,Grep,Glob",
  max_turns = 40,
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

  job.run({
    prompt = prompt,
    title = "Plan: " .. vim.trim(context):sub(1, 48),
    cwd = cwd,
    tools = M.opts.tools,
    permission_mode = "plan",
    max_turns = M.opts.max_turns,
    append_system_prompt = M.DOC_CONTRACT,
    on_done = function(ok, text, info)
      M.receive(plan_id, ok, text, info, { prompt = prompt, cwd = cwd })
    end,
  })

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

  store.set_meta(plan_id, { status = "planning" }, cwd)
  job.run({
    prompt = prompt,
    title = string.format("Replan: %s (%d comments)", meta.title, #comments),
    cwd = cwd,
    tools = M.opts.tools,
    permission_mode = "plan",
    max_turns = M.opts.max_turns,
    append_system_prompt = M.DOC_CONTRACT,
    on_done = function(ok, text, info)
      M.receive(plan_id, ok, text, info, { prompt = prompt, cwd = cwd, addressed = ids })
    end,
  })
  return true
end

--- Landing ------------------------------------------------------------------

--- Store a finished job as the next revision.
function M.receive(plan_id, ok, text, info, ctx)
  ctx = ctx or {}
  info = info or {}
  if not ok then
    store.set_meta(plan_id, { status = "review", error = tostring(info.detail or "the job failed") }, ctx.cwd)
    fire("FlowPlanFailed", plan_id)
    return
  end

  local markdown = job.decode_markdown(text)
  if vim.trim(markdown) == "" then
    store.set_meta(plan_id, { status = "review", error = "the job returned an empty document" }, ctx.cwd)
    fire("FlowPlanFailed", plan_id)
    return
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
    return
  end

  if ctx.addressed and #ctx.addressed > 0 then
    store.address_comments(plan_id, ctx.addressed, n, ctx.cwd)
  end
  store.set_meta(plan_id, {
    title = M.title_of(markdown),
    status = "review",
    error = vim.NIL,
  }, ctx.cwd)

  fire("FlowPlanReady", plan_id)
end

return M
