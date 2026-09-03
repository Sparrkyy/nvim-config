local H = require("helpers")

describe("follow.interrupt", function()
  local follow, stub

  before_each(function()
    H.reset_buffers()
    follow = H.reload("claude.follow")
  end)

  after_each(function()
    H.unmock_claudecode()
  end)

  it("warns when Claude is not running", function()
    stub = H.mock_claudecode({ running = false })
    local seen = H.capture_notify(function()
      follow.interrupt()
    end)
    assert.is_truthy(seen[1].msg:match("not running"))
  end)
end)
