describe("claude.tmux", function()
  local tmux

  before_each(function()
    tmux = require("claude.tmux")
    tmux.socket = "nvim-claude"
    tmux.prefix = "claude-"
  end)

  it("builds stable private tmux session names", function()
    assert.equals("claude-api-review-123", tmux.name("API review:123"))
  end)

  it("wraps Claude in an attached persistent tmux session", function()
    local cmd = tmux.create_command(
      "claude-session-1",
      "/tmp/my project",
      { ZETA = "last", ALPHA = "first" },
      { "claude", "--name", "Review API", "--ide" }
    )

    assert.same({
      "tmux",
      "-L",
      "nvim-claude",
      "new-session",
      "-A",
      "-s",
      "claude-session-1",
      "-c",
      "/tmp/my project",
      "-e",
      "ALPHA=first",
      "-e",
      "ZETA=last",
      "'claude' '--name' 'Review API' '--ide'",
    }, cmd)
  end)

  it("builds an attach command for the private server", function()
    assert.same({
      "tmux",
      "-L",
      "nvim-claude",
      "attach-session",
      "-t",
      "claude-session-1",
    }, tmux.attach_command("claude-session-1"))
  end)
end)
