-- Keep this configuration in step with its GitHub repository.
--
-- The config lives on more than one machine. A commit made on one machine is
-- invisible on the other until someone pulls it. This module does the noticing:
--   1. Startup runs a background `git fetch`. Nothing blocks and nothing moves.
--   2. If the tracked branch is ahead, a notification says by how much.
--   3. `:ConfigUpdate` fast-forwards, when you ask for it.
--
-- The pull is never automatic. A broken commit from the other machine would
-- break the editor you are sitting in, so the moment to take it is yours.
--
-- Every failure is quiet. No repository, no remote, and no network each leave
-- you with a working editor and no message. Only `:ConfigCheck` speaks up.

local M = {}

M.dir = vim.fn.stdpath("config")

-- Wait this long after startup before the fetch touches the network.
M.delay_ms = 2000

-- The number of commits the remote held at the last check. Nil means the
-- check has not run, or it could not answer.
M.behind = nil

--- Run git in the config directory. This is the seam the tests replace.
--- It never throws, and `done` always runs on the main loop.
---@param args string[] the git arguments
---@param done fun(ok: boolean, out: string)
function M.git(args, done)
  local cmd = vim.list_extend({ "git", "-C", M.dir }, args)
  local ok, err = pcall(vim.system, cmd, { text = true }, function(res)
    local out = vim.trim((res.stdout or "") .. (res.stderr or ""))
    vim.schedule(function()
      done(res.code == 0, out)
    end)
  end)
  -- git is missing, or the spawn failed.
  if not ok then
    vim.schedule(function()
      done(false, tostring(err))
    end)
  end
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Config" })
end

--- Look for commits on the tracked branch that HEAD does not have.
--- Fetch first, because the remote-tracking ref is otherwise stale.
---@param opts table|nil { loud = boolean } loud reports "up to date" and errors
function M.check(opts)
  opts = opts or {}

  M.git({ "fetch", "--quiet" }, function(fetched, ferr)
    if not fetched then
      M.behind = nil
      if opts.loud then
        notify("Could not reach GitHub: " .. ferr, vim.log.levels.ERROR)
      end
      return
    end

    M.git({ "rev-list", "--count", "HEAD..@{upstream}" }, function(ok, out)
      local count = ok and tonumber(out) or nil
      M.behind = count

      if not count then
        -- No upstream branch, or this is not a repository at all.
        if opts.loud then
          notify("Could not compare with the remote: " .. out, vim.log.levels.ERROR)
        end
        return
      end

      if count == 0 then
        if opts.loud then
          notify("The configuration is up to date.")
        end
        return
      end

      notify(string.format(
        "%d new %s on GitHub. Run :ConfigUpdate to take %s.",
        count,
        count == 1 and "commit" or "commits",
        count == 1 and "it" or "them"
      ), vim.log.levels.WARN)
    end)
  end)
end

--- Fast-forward the configuration to the tracked branch.
--- A merge or a rebase never happens here. Diverged history is yours to sort.
function M.update()
  M.git({ "status", "--porcelain" }, function(ok, out)
    if ok and out ~= "" then
      notify("You have uncommitted changes. Commit or stash them, then run :ConfigUpdate again.",
        vim.log.levels.ERROR)
      return
    end

    M.git({ "pull", "--ff-only", "--quiet" }, function(pulled, perr)
      if not pulled then
        notify("Could not update: " .. (perr ~= "" and perr or "git pull failed"),
          vim.log.levels.ERROR)
        return
      end

      M.behind = 0
      notify("The configuration is updated. Run :Reload for the module changes, "
        .. "or restart for the plugin changes.")
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("ConfigUpdate", function()
    M.update()
  end, { desc = "Pull the configuration from GitHub" })

  vim.api.nvim_create_user_command("ConfigCheck", function()
    M.check({ loud = true })
  end, { desc = "Ask GitHub whether the configuration changed" })

  vim.keymap.set("n", "<leader>u", M.update, { desc = "Update config from GitHub" })

  -- Check once per session, after startup has finished drawing.
  vim.api.nvim_create_autocmd("VimEnter", {
    group = vim.api.nvim_create_augroup("EthanConfigUpdate", { clear = true }),
    once = true,
    callback = function()
      vim.defer_fn(function()
        M.check()
      end, M.delay_ms)
    end,
  })
end

return M
