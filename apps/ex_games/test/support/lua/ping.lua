-- Фикстура мульти-Lua: модуль "physics" с типом "ping".
M = {}

M.schema = {
  messages = { "ping" },
}

function M.init(_args)
  return { pings = 0 }
end

function M.call(fn, args, state)
  if fn == "message" and args[1] == "ping" then
    state.pings = state.pings + 1
    return { { "broadcast", "pong", { total = state.pings } } }, state
  end

  return state
end

function M.tick(_dt, state)
  return state
end
