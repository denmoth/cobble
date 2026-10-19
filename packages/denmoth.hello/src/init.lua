-- EXAMPLE: a minimal CubeOS app in plain Lua, a window that says Hello.
-- Entry point: the module returns a table with main(sys, ctx).
local cdk = import("cdk")

local M = {}

function M.main(sys, ctx)
  local ui = cdk.open(sys, ctx, { title = "Hello", w = 120, h = 90 })
  ui:set_root(cdk.label("Hello"))
  ui:run()
end

return M
