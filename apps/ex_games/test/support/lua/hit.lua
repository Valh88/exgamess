-- Фикстура мульти-Lua: модуль "economy" с типом "hit" (свой срез состояния).
M = {}

M.schema = {
  messages = { "hit" },
  state = {
    hits = "number",
  },
}

function M.init(_args)
  return { hits = 0 }
end

function M.call(fn, args, state)
  if fn == "message" and args[1] == "hit" then
    state.hits = state.hits + 1
    return { { "broadcast", "hit_seen", { total = state.hits } } }, state
  end

  return state
end

function M.tick(_dt, state)
  return state
end
