-- Stage three: the accepted plan, as a stack of small changes.
--
-- Accepting a plan runs one job that breaks it into ordered steps. The steps
-- appear at once, so the panel is useful before any diff exists. A worker then
-- keeps ten diffs generated ahead of where you stand.
--
-- Every diff carries the generation of the file it was built against. Applying,
-- undoing, or revising a step raises that file's generation. A diff behind the
-- generation is stale, and the worker builds it again. That is what lets Flow
-- generate far ahead without ever applying a diff to a file it has not seen.
--
-- All of the state lives on disk, so :Reload and a restart both keep your
-- place.

local M = {}

local job = require("flow.job")
local store = require("flow.store")
local ui = require("flow.ui")

M.opts = {
  lookahead = 10,
  max_concurrent = 3,
  max_retries = 2,
  tools = "Read,Grep,Glob",
}

-- Step ids being generated right now. Not on disk: a restart just rebuilds.
local generating = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Flow" })
end

local function current_plan()
  return require("flow").current()
end

--- Schemas ------------------------------------------------------------------

M.STEP_SCHEMA = {
  type = "object",
  properties = {
    steps = {
      type = "array",
      items = {
        type = "object",
        properties = {
          id = { type = "string" },
          title = { type = "string" },
          file = { type = "string" },
          kind = { type = "string", enum = { "create", "edit", "delete" } },
          hint = { type = "string" },
        },
        required = { "id", "title", "file", "kind", "hint" },
      },
    },
  },
  required = { "steps" },
}

M.DIFF_SCHEMA = {
  type = "object",
  properties = {
    edits = {
      type = "array",
      items = {
        type = "object",
        properties = {
          old_string = { type = "string" },
          new_string = { type = "string" },
        },
        required = { "old_string", "new_string" },
      },
    },
    rationale = { type = "string" },
  },
  required = { "edits", "rationale" },
}

--- Generations --------------------------------------------------------------

local function generation(meta, file)
  local map = meta and meta.file_generations or {}
  return tonumber(map[file]) or 0
end

local function bump(plan_id, file, cwd)
  local meta = store.meta(plan_id, cwd)
  if not meta then
    return
  end
  local map = meta.file_generations or {}
  map[file] = generation(meta, file) + 1
  store.set_meta(plan_id, { file_generations = map }, cwd)
end

--- Reading the stack --------------------------------------------------------

--- Is this step's diff usable, out of date, or absent?
---@return string "fresh"|"stale"|"missing"
function M.diff_state(plan_id, step, meta, cwd)
  local diff = store.diff(plan_id, step.id, cwd)
  if not diff or type(diff.edits) ~= "table" then
    return "missing"
  end
  if (tonumber(diff.file_generation) or 0) ~= generation(meta, step.file) then
    return "stale"
  end
  return "fresh"
end

--- The full path of a step's file.
function M.path(step, cwd)
  local file = step.file or ""
  if vim.startswith(file, "/") then
    return file
  end
  return (cwd or vim.fn.getcwd()) .. "/" .. file
end

--- Does this diff still match the file on disk?
--- The generation counter only knows what Flow applied. Anything else that
--- touched the file shows up here: you, a formatter, or an earlier step whose
--- diff was built at the same time as this one.
function M.fits(step, diff, cwd)
  if not diff or type(diff.edits) ~= "table" then
    return false
  end
  local file = M.path(step, cwd)
  local lines = {}
  if vim.fn.filereadable(file) == 1 then
    local ok, read = pcall(vim.fn.readfile, file)
    if ok then
      lines = read
    end
  end
  for _, hit in ipairs(ui.locate(lines, diff.edits)) do
    if not hit.ok then
      return false
    end
  end
  return true
end

--- True when an earlier step changes the same file and has not landed yet.
--- Its diff would be built against a file that is about to change, so the model
--- would write code the earlier step already writes. Generation waits.
function M.blocked(steps, index)
  local file = steps[index] and steps[index].file
  if not file then
    return false
  end
  for i = 1, index - 1 do
    local earlier = steps[i]
    if earlier.file == file and earlier.status ~= "done" and earlier.status ~= "skipped" then
      return true
    end
  end
  return false
end

--- What the panel should show for one step.
function M.status_of(plan_id, step, index, meta, cwd, steps)
  if step.status == "done" then
    return "done"
  end
  if step.status == "skipped" then
    return "skipped"
  end
  if step.error then
    return "failed"
  end
  if generating[step.id] then
    return "generating"
  end
  local state = M.diff_state(plan_id, step, meta, cwd)
  if state ~= "fresh" and steps and M.blocked(steps, index) then
    return "waiting"
  end
  if index == (meta.step_cursor or 1) then
    return state == "fresh" and "current" or "generating"
  end
  if state == "fresh" then
    return "ready"
  end
  if state == "stale" then
    return "stale"
  end
  return "generating"
end

--- Everything the panel needs.
function M.view(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta then
    return {
      title = "Flow — no plan",
      steps = {},
      cursor = 0,
      status_of = function()
        return "ready"
      end,
    }
  end
  local steps = store.steps(plan_id, meta.cwd)
  return {
    title = meta.title or "Flow",
    steps = steps,
    cursor = meta.step_cursor or 1,
    status_of = function(step, index)
      return M.status_of(plan_id, step, index, meta, meta.cwd, steps)
    end,
  }
end

local function refresh_panel()
  ui.render_panel(M.view())
  pcall(vim.cmd, "redrawstatus")
end

--- The statusline fragment. Empty unless a stack is in play.
function M.statusline(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta or meta.status ~= "applying" then
    return ""
  end
  local steps = store.steps(plan_id, meta.cwd)
  if #steps == 0 then
    return ""
  end
  local done = 0
  for _, s in ipairs(steps) do
    if s.status == "done" or s.status == "skipped" then
      done = done + 1
    end
  end
  return string.format("󰐅 flow %d/%d", done, #steps)
end

--- Decomposing --------------------------------------------------------------

function M.decompose_prompt(markdown)
  return table.concat({
    "Break this accepted design document into an ordered list of small changes.",
    "Do not change any file. Return the list only.",
    "",
    "<document>",
    markdown,
    "</document>",
    "",
    "Rules:",
    "- One idea in each step. Several separate ideas in one file become several steps.",
    "- Order the steps so each one leaves the repository in a state a person can read.",
    "- `id` is short, lowercase, and unique. Use letters, digits, and hyphens only.",
    "- `file` is one path. Write it relative to the repository root.",
    "- `title` is one sentence in ASD-STE100 Simplified Technical English. Start with a verb.",
    "- `hint` tells the next agent what to change and where. Name the function or the section.",
    "- Read the repository first. Use paths that exist, or say `create` for a new file.",
  }, "\n")
end

--- Turn an accepted plan into a stack. This is what the browser Accept calls.
function M.begin(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta then
    notify("No plan to accept.", vim.log.levels.WARN)
    return
  end
  local revision = store.revision(plan_id, nil, meta.cwd)
  if not revision or not revision.plan_md then
    notify("That plan has no document yet.", vim.log.levels.WARN)
    return
  end

  store.clear_diffs(plan_id, meta.cwd)
  store.set_meta(plan_id, { status = "accepted", step_cursor = 1, file_generations = {} }, meta.cwd)

  job.run({
    prompt = M.decompose_prompt(revision.plan_md),
    title = "Stack: " .. (meta.title or "plan"),
    cwd = meta.cwd,
    tools = M.opts.tools,
    permission_mode = "plan",
    json_schema = M.STEP_SCHEMA,
    on_done = function(ok, text)
      if not ok then
        store.set_meta(plan_id, { status = "review" }, meta.cwd)
        return
      end
      local data = job.decode_result(text)
      local steps = data and data.steps
      if type(steps) ~= "table" or #steps == 0 then
        notify("Flow could not break the plan into steps.", vim.log.levels.ERROR)
        store.set_meta(plan_id, { status = "review" }, meta.cwd)
        return
      end

      local seen = {}
      for i, step in ipairs(steps) do
        -- Two steps with one id would share a diff file.
        local id = tostring(step.id or ("step-" .. i)):gsub("[^%w%-]", "-")
        while seen[id] do
          id = id .. "-" .. i
        end
        seen[id] = true
        step.id = id
        step.status = "pending"
      end

      store.set_steps(plan_id, steps, meta.cwd)
      store.set_meta(plan_id, { status = "applying", step_cursor = 1 }, meta.cwd)
      notify(string.format("%d changes queued. Press <leader>dj to start.", #steps))
      if not ui.panel_is_open() then
        ui.toggle_panel(M.view(plan_id))
      end
      refresh_panel()
      M.pump(plan_id)
    end,
  })
end

--- Generating diffs ---------------------------------------------------------

function M.diff_prompt(markdown, step, feedback)
  local parts = {
    "Produce the exact edits for one step of an accepted plan.",
    "Do not change any file. Return the edits only.",
    "",
    "<plan>",
    markdown,
    "</plan>",
    "",
    "<step>",
    "title: " .. tostring(step.title),
    "file: " .. tostring(step.file),
    "kind: " .. tostring(step.kind),
    "hint: " .. tostring(step.hint),
    "</step>",
    "",
    "Rules:",
    "- Read the file first. Every `old_string` must match the file on disk",
    "  exactly, including every space of indentation. An `old_string` that is",
    "  not in the file is the one failure this task can have. Copy it, do not",
    "  type it from memory.",
    "- Keep `old_string` short, but long enough to appear once in the file.",
    "- Never write code the file already has. If the step looks done, say so in",
    "  `rationale` and return no edits.",
    "- Set `old_string` to an empty string ONLY when the file does not exist at",
    "  all. An empty `old_string` means `new_string` is the whole file, so on a",
    "  file with any content it would add a second copy of everything.",
    "- To add code to the end of a file that exists, put the last two or three",
    "  real lines of that file in `old_string`, and repeat them at the start of",
    "  `new_string`.",
    "- To delete lines, set `new_string` to an empty string.",
    "- Do only what this step asks. Another step does the rest of the plan.",
    "- Match the style of the code around the change.",
    "- `rationale` is one or two sentences in ASD-STE100 Simplified Technical",
    "  English. Say what the change does.",
  }
  if feedback and vim.trim(feedback) ~= "" then
    vim.list_extend(parts, {
      "",
      "The last attempt was wrong. Fix it:",
      "",
      "<feedback>",
      vim.trim(feedback),
      "</feedback>",
    })
  end
  return table.concat(parts, "\n")
end

--- Build the diff for one step.
--- Building again after a diff would not fit is a `retry`. Every path that can
--- feed its own result back into another build must set it, or a model that
--- keeps giving the same wrong answer costs money in a loop.
---@param opts table|nil { feedback: string, retry: boolean, on_done: function }
function M.generate(plan_id, step, opts)
  opts = opts or {}
  if generating[step.id] then
    return false
  end

  if opts.retry then
    local attempts = (tonumber(step.attempts) or 0) + 1
    if attempts > M.opts.max_retries then
      M.mark(plan_id, step.id, { error = "Flow could not fit this change to the file." })
      refresh_panel()
      notify(
        string.format("Flow built this change %d times and it still does not fit.\n", attempts - 1)
          .. "Press <leader>dr to say what it should do.",
        vim.log.levels.ERROR
      )
      return false
    end
    M.mark(plan_id, step.id, { attempts = attempts })
    step.attempts = attempts
  end

  local meta = store.meta(plan_id)
  local revision = meta and store.revision(plan_id, nil, meta.cwd)
  if not revision then
    return false
  end

  generating[step.id] = true
  refresh_panel()

  local gen = generation(meta, step.file)
  job.run({
    prompt = M.diff_prompt(revision.plan_md, step, opts.feedback),
    title = "Diff: " .. tostring(step.title):sub(1, 42),
    cwd = meta.cwd,
    tools = M.opts.tools,
    permission_mode = "plan",
    json_schema = M.DIFF_SCHEMA,
    on_done = function(ok, text, info)
      generating[step.id] = nil
      local data = ok and job.decode_result(text) or nil
      if not data or type(data.edits) ~= "table" then
        M.mark(plan_id, step.id, { error = "Flow could not build this change." })
        refresh_panel()
        if opts.on_done then
          opts.on_done(false)
        end
        return
      end
      store.set_diff(plan_id, step.id, {
        edits = data.edits,
        rationale = data.rationale,
        file_generation = gen,
        generated_at = os.time(),
        session_id = info and info.session_id,
      }, meta.cwd)
      M.mark(plan_id, step.id, { error = vim.NIL })
      refresh_panel()
      if opts.on_done then
        opts.on_done(true)
      end
    end,
  })
  return true
end

--- Keep `lookahead` diffs ready in front of the cursor.
function M.pump(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta or meta.status ~= "applying" then
    return
  end
  local steps = store.steps(plan_id, meta.cwd)
  local budget = M.opts.max_concurrent - vim.tbl_count(generating)
  if budget <= 0 then
    return
  end

  local from = meta.step_cursor or 1
  for i = from, math.min(#steps, from + M.opts.lookahead - 1) do
    if budget <= 0 then
      return
    end
    local step = steps[i]
    local pending = step.status ~= "done" and step.status ~= "skipped"
    if pending and not generating[step.id] and not step.error and not M.blocked(steps, i) then
      if M.diff_state(plan_id, step, meta, meta.cwd) ~= "fresh" then
        if M.generate(plan_id, step) then
          budget = budget - 1
        end
      end
    end
  end
end

--- Change one step on disk.
function M.mark(plan_id, step_id, patch)
  local meta = store.meta(plan_id)
  if not meta then
    return
  end
  local steps = store.steps(plan_id, meta.cwd)
  for _, step in ipairs(steps) do
    if step.id == step_id then
      for k, v in pairs(patch) do
        step[k] = (v ~= vim.NIL) and v or nil
      end
    end
  end
  store.set_steps(plan_id, steps, meta.cwd)
end

--- Moving through the stack -------------------------------------------------

--- The index of the next step that still needs you, from `from`.
local function next_pending(steps, from)
  for i = math.max(1, from), #steps do
    local s = steps[i]
    if s.status ~= "done" and s.status ~= "skipped" then
      return i
    end
  end
  return nil
end

--- Show the step at `index`, generating its diff first when necessary.
function M.show(index, plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta then
    notify("No plan is running.", vim.log.levels.WARN)
    return
  end
  local steps = store.steps(plan_id, meta.cwd)
  local step = steps[index]
  if not step then
    notify("Every change is applied. Press <leader>dR to plan the next one.")
    store.set_meta(plan_id, { status = "done" }, meta.cwd)
    refresh_panel()
    return
  end

  store.set_meta(plan_id, { step_cursor = index }, meta.cwd)
  refresh_panel()

  if step.error then
    notify(step.error .. "\nPress <leader>dr to say what it should do.", vim.log.levels.ERROR)
    return
  end

  -- A diff built while an earlier step in this file was still pending read a
  -- file that has since changed. The generation counter cannot see that, so
  -- check the diff against the file itself before trusting it.
  local state = M.diff_state(plan_id, step, meta, meta.cwd)
  local fits = state == "fresh" and M.fits(step, store.diff(plan_id, step.id, meta.cwd), meta.cwd)
  if state == "fresh" and not fits then
    state = "stale"
  end
  if state ~= "fresh" then
    local started = M.generate(plan_id, step, {
      -- A diff that does not fit is a retry. A diff that is simply missing or
      -- out of date is the ordinary case, and does not count against the cap.
      retry = not fits,
      feedback = not fits
          and "The last edits did not match the file. Read it again.\nDo not write code the file already has."
        or nil,
      on_done = function(ok)
        if ok then
          M.show(index, plan_id)
        end
      end,
    })
    if started then
      notify("Building this change...")
    end
    M.pump(plan_id)
    return
  end

  local diff = store.diff(plan_id, step.id, meta.cwd)
  local file = M.path(step, meta.cwd)

  ui.preview({
    file = file,
    edits = diff.edits,
    rationale = diff.rationale,
    title = step.title,
    index = index,
    total = #steps,
    on_apply = function()
      M.apply(index, plan_id)
    end,
    on_revise = function()
      M.revise_step(index, plan_id)
    end,
    on_skip = function()
      M.mark(plan_id, step.id, { status = "skipped" })
      M.next(plan_id)
    end,
  })
  M.pump(plan_id)
end

--- Apply the next change.
function M.next(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta then
    notify("No plan is running. Press <leader>dn to start one.", vim.log.levels.WARN)
    return
  end
  if meta.status ~= "applying" then
    notify("This plan is not accepted yet. Press <leader>dp to review it.", vim.log.levels.WARN)
    return
  end
  local steps = store.steps(plan_id, meta.cwd)
  local index = next_pending(steps, meta.step_cursor or 1)
  if not index then
    store.set_meta(plan_id, { status = "done" }, meta.cwd)
    refresh_panel()
    notify("Every change is applied.")
    return
  end
  M.show(index, plan_id)
end

--- Look at the change before this one, applied or not.
function M.prev(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta then
    return
  end
  local index = (meta.step_cursor or 1) - 1
  if index < 1 then
    notify("This is the first change.", vim.log.levels.WARN)
    return
  end
  M.show(index, plan_id)
end

--- Writing ------------------------------------------------------------------

--- Put a step's edits into the file.
---@return boolean ok
---@return table|nil before the file exactly as it was
---@return boolean existed
---@return string|nil problem why it would not fit
function M.write(file, edits)
  local existed = vim.fn.filereadable(file) == 1
  if not existed then
    vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  end

  local ok = pcall(vim.cmd.edit, vim.fn.fnameescape(file))
  if not ok then
    return false, nil, existed
  end
  local buf = vim.api.nvim_get_current_buf()
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local hits = ui.locate(before, edits)
  for _, hit in ipairs(hits) do
    if not hit.ok then
      local why = hit.reason == "empty"
          and "old_string was empty, but the file already has content. An empty " .. "old_string replaces the whole file, so it must only be used on a " .. "file that does not exist yet."
        or ("old_string does not appear in the file. It was:\n" .. table.concat(hit.old, "\n"))
      return false, before, existed, why
    end
  end

  -- Apply from the bottom up, so an earlier edit never moves a later one.
  table.sort(hits, function(a, b)
    return a.start > b.start
  end)
  for _, hit in ipairs(hits) do
    if hit.whole then
      -- A brand new file: the new text is the whole file.
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, hit.new)
    else
      vim.api.nvim_buf_set_lines(buf, hit.start, hit.start + #hit.old, false, hit.new)
    end
  end

  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent write")
  end)
  return true, before, existed
end

--- Apply the step at `index`, then open the next one.
---@param opts table|nil { advance = boolean } advance = false stays put
function M.apply(index, plan_id, opts)
  opts = opts or {}
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta then
    return
  end
  local steps = store.steps(plan_id, meta.cwd)
  local step = steps[index]
  local diff = step and store.diff(plan_id, step.id, meta.cwd)
  if not diff then
    return
  end

  local file = M.path(step, meta.cwd)
  local ok, before, existed, problem = M.write(file, diff.edits)
  if not ok then
    bump(plan_id, step.file, meta.cwd)
    local started = M.generate(plan_id, step, {
      retry = true,
      feedback = "The edits did not apply. "
        .. tostring(problem)
        .. "\nRead the file again before you answer. Do not write code the file already has.",
      on_done = function(built)
        if built then
          M.show(index, plan_id)
        end
      end,
    })
    if started then
      notify("This change no longer fits the file. Building it again.", vim.log.levels.WARN)
    end
    return
  end

  store.push_applied(plan_id, {
    step_id = step.id,
    index = index,
    file = file,
    before = before,
    existed = existed,
  }, meta.cwd)
  M.mark(plan_id, step.id, { status = "done", attempts = vim.NIL })
  bump(plan_id, step.file, meta.cwd)

  -- Show it as an edit like any other, using follow mode's marks.
  pcall(function()
    require("claude.follow").mark(file, { table.concat(ui.split(diff.edits[1].new_string), "\n") })
  end)

  refresh_panel()
  M.pump(plan_id)
  notify(string.format("%d/%d  %s", index, #steps, step.title or ""))

  -- Go straight to the next change, so one key walks the whole stack.
  if opts.advance ~= false then
    M.next(plan_id)
  end
end

--- Put the file back the way it was before the last applied change.
function M.undo(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta then
    return
  end
  local entry = store.pop_applied(plan_id, meta.cwd)
  if not entry then
    notify("Nothing to undo.", vim.log.levels.WARN)
    return
  end

  if entry.existed == false then
    pcall(vim.fn.delete, entry.file)
    local buf = vim.fn.bufnr(entry.file)
    if buf > 0 then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  else
    pcall(vim.cmd.edit, vim.fn.fnameescape(entry.file))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, entry.before or {})
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
  end

  M.mark(plan_id, entry.step_id, { status = "pending" })
  local steps = store.steps(plan_id, meta.cwd)
  for i, step in ipairs(steps) do
    if step.id == entry.step_id then
      bump(plan_id, step.file, meta.cwd)
      store.set_meta(plan_id, { step_cursor = i, status = "applying" }, meta.cwd)
      break
    end
  end

  ui.clear()
  refresh_panel()
  M.pump(plan_id)
  notify("Change undone.")
end

--- Revising -----------------------------------------------------------------

--- Ask for a tweak to the change in front of you, and build it again.
function M.revise_step(index, plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta then
    return
  end
  index = index or meta.step_cursor or 1
  local step = store.steps(plan_id, meta.cwd)[index]
  if not step then
    return
  end

  require("claude.input").open({ title = "Flow — what is wrong with this change?" }, function(text)
    if not text then
      return
    end
    M.mark(plan_id, step.id, { error = vim.NIL, attempts = vim.NIL })
    M.generate(plan_id, step, {
      feedback = text,
      on_done = function(ok)
        if ok then
          M.show(index, plan_id)
        end
      end,
    })
  end)
end

--- Go back to the design document. The applied changes stay on disk, and the
--- next revision is told about them.
function M.revise_plan(plan_id)
  plan_id = plan_id or current_plan()
  local meta = plan_id and store.meta(plan_id)
  if not meta then
    notify("No plan is running.", vim.log.levels.WARN)
    return
  end

  local steps = store.steps(plan_id, meta.cwd)
  local applied = {}
  for _, step in ipairs(steps) do
    if step.status == "done" then
      table.insert(applied, string.format("- %s (%s)", step.title, step.file))
    end
  end

  require("claude.input").open({ title = "Flow — how should the plan change?" }, function(text)
    if not text then
      return
    end
    local body = text
    if #applied > 0 then
      body = text
        .. "\n\nThese changes are already applied to the repository. Keep them, and"
        .. "\nplan from the state they leave behind:\n"
        .. table.concat(applied, "\n")
    end

    store.add_comment(plan_id, {
      anchor = "the-plan",
      quote = "",
      body = body,
      revision = meta.current_revision,
    }, meta.cwd)

    ui.clear()
    store.set_meta(plan_id, { status = "review" }, meta.cwd)
    require("flow.planner").replan(plan_id, { cwd = meta.cwd })
  end)
end

--- The panel ----------------------------------------------------------------

function M.toggle_panel()
  ui.toggle_panel(M.view())
end

--- Which steps are being built. For the tests.
function M.generating()
  return vim.tbl_keys(generating)
end

function M.reset()
  generating = {}
end

return M
