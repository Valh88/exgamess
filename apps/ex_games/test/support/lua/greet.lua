-- Фикстура моста: greet/boom/kickme + schema (для room_logics_lua_test).
-- Контракт моста: M.call -> {effects, state} | state.
M = {}

M.schema = {
  messages = { "greet", "boom", "kickme", "corrupt" },
  state = {
    players = { map = "number" },
    greets = "number",
  },
}

function M.init(_args)
  return { players = {}, greets = 0 }
end

function M.call(fn, args, state)
  if fn == "join" then
    local sid = args[1]
    state.players[sid] = 0
    return { { "broadcast", "joined", { sid = sid } } }, state
  elseif fn == "leave" then
    state.players[args[1]] = nil
    return state
  elseif fn == "message" then
    local msg = args[1]
    local sid = args[2]

    if msg == "greet" then
      state.greets = state.greets + 1
      state.players[sid] = (state.players[sid] or 0) + 1
      return { { "broadcast", "greet", { from = sid, total = state.greets } } }, state
    elseif msg == "boom" then
      error("script explosion", 0)
    elseif msg == "corrupt" then
      -- ломает собственное состояние (players: map<number>): мост обязан
      -- НЕ публиковать его, но комнату не ронять (эффект — маркер того,
      -- что публикация уже решена)
      state.players[sid] = "bad"
      return { { "broadcast", "corrupted", {} } }, state
    elseif msg == "kickme" then
      return { { "kick", sid } }, state
    end
  end

  return state
end

function M.tick(_dt, state)
  return state
end
