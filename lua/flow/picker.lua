-- Every plan in this directory, past and present.
--
-- Telescope is already in the config, so use it. Without it, fall back to
-- vim.ui.select, which snacks.nvim draws as a float.

local M = {}

local store = require("flow.store")

local ICON = {
  planning = "󰔟",
  review = "󰈙",
  accepted = "󰄬",
  applying = "󰐅",
  provisioning = "󰔟",
  implementing = "󰐅",
  revising = "󰜺",
  review_ready = "󰈙",
  reviewing = "󰈙",
  merge_ready = "󰄬",
  merging = "󰆧",
  merged = "󰄲",
  implementation_failed = "󰅖",
  merge_failed = "󰅖",
  done = "󰄲",
  abandoned = "󰅖",
}

--- One line of the list.
function M.label(meta)
  local steps = store.steps(meta.id, meta.cwd)
  local done = 0
  for _, s in ipairs(steps) do
    if s.status == "done" then
      done = done + 1
    end
  end
  local progress = #steps > 0 and string.format("  %d/%d", done, #steps) or ""
  return string.format(
    "%s  %s  %s%s  %s",
    ICON[meta.status] or "󰋼",
    os.date("%d %b %H:%M", meta.created or 0),
    meta.status or "?",
    progress,
    meta.title or "Untitled"
  )
end

--- Act on the plan you picked.
local function choose(meta)
  require("flow").select(meta.id, meta.cwd)
  if meta.status == "implementing" or meta.status == "revising" or meta.status == "provisioning" then
    require("flow.implementation").open(meta.id)
  elseif meta.status == "review_ready" or meta.status == "reviewing" or meta.status == "merge_ready" then
    require("flow.review").open(meta.id)
  else
    require("flow").open(meta.id)
  end
end

function M.plans(cwd)
  local plans = store.plans(cwd)
  if #plans == 0 then
    vim.notify("No plans here yet. Press <leader>dn to start one.", vim.log.levels.INFO, { title = "Flow" })
    return
  end

  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    vim.ui.select(plans, { prompt = "Flow plans", format_item = M.label }, function(meta)
      if meta then
        choose(meta)
      end
    end)
    return
  end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "Flow plans",
      finder = finders.new_table({
        results = plans,
        entry_maker = function(meta)
          return { value = meta, display = M.label(meta), ordinal = meta.title or meta.id }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(bufnr)
          if entry then
            choose(entry.value)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
