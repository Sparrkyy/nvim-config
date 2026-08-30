-- Create files and their parent directories.
--
-- Neovim opens a buffer for any path, but `:w` fails if a parent directory
-- is missing. Two pieces fix that:
--   1. `:New` and <leader>n make the directories, then open the file.
--   2. A BufWritePre autocmd makes the directories for a plain `:e` + `:w`.
--
-- Relative paths resolve against the cwd. This matches `:e` and file
-- completion. The prompt pre-fills the current buffer directory, so the
-- common case still needs no typing.

local M = {}

local uv = vim.uv or vim.loop

-- The pre-filled prompt text. Empty when the buffer holds no real file.
local function default_input()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then return "" end
  local dir = vim.fn.fnamemodify(name, ":.:h")
  if dir == "." then return "" end
  return dir .. "/"
end

-- Create the path. A trailing "/" means a directory only.
-- Otherwise create an empty file and open it.
function M.create(input)
  if not input or input == "" then return end

  local is_dir = input:sub(-1) == "/"
  local path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(input), ":p"))
  local dir = is_dir and path or vim.fs.dirname(path)

  local ok, err = pcall(vim.fn.mkdir, dir, "p")
  if not ok then
    return vim.notify(tostring(err), vim.log.levels.ERROR)
  end

  if is_dir then
    return vim.notify("Created " .. vim.fn.fnamemodify(dir, ":~:."))
  end

  -- Touch the file. An empty file appears at once in telescope and in git.
  if not uv.fs_stat(path) then
    local fd, oerr = uv.fs_open(path, "w", 420) -- 0644
    if not fd then
      return vim.notify(tostring(oerr), vim.log.levels.ERROR)
    end
    uv.fs_close(fd)
  end

  vim.cmd.edit(vim.fn.fnameescape(path))
end

-- Ask for a path, then create it.
function M.prompt()
  vim.ui.input({
    prompt = "New file: ",
    default = default_input(),
    completion = "file",
  }, function(input)
    if input then M.create(input) end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("New", function(opts)
    if opts.args == "" then
      M.prompt()
    else
      M.create(opts.args)
    end
  end, {
    nargs = "?",
    complete = "file",
    desc = "Create a file and its parent directories",
  })

  -- Make the parents on write. This covers `:e deep/new/file.ts` + `:w`.
  -- Skip the virtual paths of plugins such as fugitive and oil.
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = vim.api.nvim_create_augroup("EthanNewFile", { clear = true }),
    callback = function(ev)
      if ev.match:match("^%w%w+://") then return end
      vim.fn.mkdir(vim.fn.fnamemodify(ev.match, ":p:h"), "p")
    end,
  })

  vim.keymap.set("n", "<leader>n", M.prompt, { desc = "New file" })
end

return M
