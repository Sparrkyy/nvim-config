-- Buffer visit stack. J walks back through visited buffers. K walks forward.
--
-- The list works like alt-tab. A natural visit puts the buffer at index 1.
-- A J or K jump only moves the cursor `idx`. It does not reorder the list.
-- The next natural visit commits the cycle and resets `idx` to 1.

local M = {}

local MAX_DEPTH = 30

local stack = {} -- buffer numbers. Index 1 is the most recent buffer.
local idx = 1 -- the position in `stack`.
local cycling = false -- true while a J or K jump runs.

-- A buffer belongs in the list only if it holds a real file.
-- This rejects help, quickfix, terminal, and telescope buffers.
local function trackable(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted and vim.bo[buf].buftype == ""
end

-- Drop the dead buffers, then keep `idx` on the same buffer.
local function prune()
  local anchor = stack[idx]
  local kept = {}
  for _, buf in ipairs(stack) do
    if trackable(buf) then kept[#kept + 1] = buf end
  end
  stack = kept
  idx = 1
  for i, buf in ipairs(stack) do
    if buf == anchor then
      idx = i
      break
    end
  end
end

-- Move the buffer to index 1. Call this on a natural visit.
local function record(buf)
  if cycling or not trackable(buf) then return end
  for i, b in ipairs(stack) do
    if b == buf then
      table.remove(stack, i)
      break
    end
  end
  table.insert(stack, 1, buf)
  for i = #stack, MAX_DEPTH + 1, -1 do
    stack[i] = nil
  end
  idx = 1
end

-- Switch to `buf`. `nvim_set_current_buf` reads an unloaded buffer without
-- firing BufReadPre or FileType, so the LSP and treesitter never start on it.
-- `:buffer` runs the full read, so a restored file gets its filetype.
local function show(buf)
  if vim.api.nvim_buf_is_loaded(buf) then
    return pcall(vim.api.nvim_set_current_buf, buf)
  end
  return pcall(vim.cmd, "buffer " .. buf)
end

-- Step through the list. `step` is 1 for back, and -1 for forward.
local function go(step)
  prune()
  local target = idx + step
  if target < 1 or target > #stack then return end
  idx = target
  -- The switch fires BufEnter at once. The flag must wrap that call,
  -- so `record` skips the jump and the list keeps its order.
  cycling = true
  local ok, err = show(stack[idx])
  cycling = false
  if not ok then
    vim.notify("bufstack: " .. tostring(err), vim.log.levels.WARN)
  end
end

function M.back()
  go(1)
end

function M.forward()
  go(-1)
end

-- Return the list for a status line or for debugging.
function M.state()
  prune()
  return { stack = vim.deepcopy(stack), idx = idx }
end

-- The stack as file paths, newest first. A session file saves this.
-- Unnamed buffers hold no file, so they cannot survive a restart.
function M.files()
  prune()
  local files, pos = {}, 1
  for i, buf in ipairs(stack) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" then
      files[#files + 1] = name
      if i == idx then pos = #files end
    end
  end
  return { files = files, idx = pos }
end

-- Rebuild the stack from file paths. Returns true when a buffer opened.
-- A file that no longer exists drops out of the list.
function M.restore(files, want)
  local restored = {}
  for _, path in ipairs(files or {}) do
    if #restored < MAX_DEPTH and vim.fn.filereadable(path) == 1 then
      local ok, buf = pcall(vim.fn.bufadd, path)
      if ok then
        vim.bo[buf].buflisted = true
        restored[#restored + 1] = buf
      end
    end
  end
  if #restored == 0 then return false end

  stack = restored
  idx = math.max(1, math.min(tonumber(want) or 1, #stack))
  -- The jump fires BufEnter. The flag keeps `record` from reordering the list.
  cycling = true
  local ok = show(stack[idx])
  cycling = false
  return ok
end

function M.setup()
  local group = vim.api.nvim_create_augroup("EthanBufStack", { clear = true })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      record(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(ev)
      for i, buf in ipairs(stack) do
        if buf == ev.buf then
          table.remove(stack, i)
          if idx > i then idx = idx - 1 end
          break
        end
      end
      idx = math.max(1, math.min(idx, math.max(#stack, 1)))
    end,
  })

  vim.keymap.set("n", "J", M.back, { desc = "Buffer stack: back" })
  vim.keymap.set("n", "K", M.forward, { desc = "Buffer stack: forward" })
end

return M
