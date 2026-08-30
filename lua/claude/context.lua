-- Editor state for Claude. A UserPromptSubmit hook calls gather() and injects
-- the result into every prompt, so Claude sees what you see.

local M = {}

local MAX_BUFFERS = 12
local MAX_DIAGNOSTICS = 15

local function git_branch()
  local ok, out = pcall(vim.fn.systemlist, { "git", "rev-parse", "--abbrev-ref", "HEAD" })
  if not ok or vim.v.shell_error ~= 0 or not out[1] then
    return nil
  end
  return vim.trim(out[1])
end

local function relative(path)
  if path == nil or path == "" then
    return nil
  end
  return vim.fn.fnamemodify(path, ":.")
end

--- The file and line you are on, plus what is on screen.
local function cursor_section(lines)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "" then
    -- You are in the terminal or a special buffer. Fall back to the last file.
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].buftype == "" and vim.api.nvim_buf_get_name(b) ~= "" then
        win, buf = w, b
        break
      end
    end
  end

  local name = relative(vim.api.nvim_buf_get_name(buf))
  if not name then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  table.insert(lines, string.format("Cursor: %s line %d", name, cursor[1]))

  local ok, info = pcall(vim.fn.getwininfo, win)
  if ok and info and info[1] then
    table.insert(lines, string.format("On screen: %s lines %d-%d", name, info[1].topline, info[1].botline))
  end
  return buf
end

local function buffers_section(lines)
  local open, modified = {}, {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted and vim.bo[buf].buftype == "" then
      local name = relative(vim.api.nvim_buf_get_name(buf))
      if name then
        table.insert(open, name)
        if vim.bo[buf].modified then
          table.insert(modified, name)
        end
      end
    end
  end
  if #open > 0 then
    local shown = vim.list_slice(open, 1, MAX_BUFFERS)
    local suffix = #open > MAX_BUFFERS and string.format(" (+%d more)", #open - MAX_BUFFERS) or ""
    table.insert(lines, "Open buffers: " .. table.concat(shown, ", ") .. suffix)
  end
  if #modified > 0 then
    table.insert(lines, "Unsaved changes in: " .. table.concat(modified, ", "))
  end
end

local function diagnostics_section(lines, buf)
  if not buf then
    return
  end
  local items = vim.diagnostic.get(buf, { severity = { min = vim.diagnostic.severity.WARN } })
  if #items == 0 then
    return
  end
  table.insert(lines, string.format("Diagnostics in the current file (%d):", #items))
  local names = { [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "HINT" }
  for i, d in ipairs(items) do
    if i > MAX_DIAGNOSTICS then
      table.insert(lines, string.format("  ... and %d more", #items - MAX_DIAGNOSTICS))
      break
    end
    local msg = (d.message or ""):gsub("%s+", " ")
    table.insert(lines, string.format("  line %d %s: %s", d.lnum + 1, names[d.severity] or "?", msg))
  end
end

--- Build the context block. Returns plain text, or "" when there is nothing useful.
function M.gather()
  local ok, result = pcall(function()
    local lines = {}
    local buf = cursor_section(lines)
    buffers_section(lines)
    diagnostics_section(lines, buf)

    local branch = git_branch()
    if branch then
      table.insert(lines, "Git branch: " .. branch)
    end

    if #lines == 0 then
      return ""
    end
    table.insert(lines, 1, "The user is working in Neovim. Their editor state right now:")
    return table.concat(lines, "\n")
  end)
  return ok and result or ""
end

--- Base64 wrapper, so the hook script never has to escape anything.
function M.gather_encoded()
  return vim.base64.encode(M.gather())
end

return M
