-- Мини-арена на Lua для ArenaExample.LuaArenaRoom.
-- Демонстрирует контракт моста ExGames.Room.Logics.Lua:
--   M.init(args) -> state
--   M.call(fn, args, state) -> {effects, state} | state
--   M.tick(dt, state) -> {effects, state} | state
-- Эффекты (whitelist моста): broadcast / send_to / kick / lock / unlock /
-- set_metadata. Состояние — msgpack-совместимый документ (уходит в
-- set_state -> дельты клиентам).
M = {}

M.schema = {
  messages = { "move", "hit" },
  state = {
    players = { map = { x = "number", y = "number", hp = "number" } },
    scores = { map = "number" },
  },
}

function M.init(_args)
  return { players = {}, scores = {} }
end

function M.call(fn, args, state)
  if fn == "join" then
    local sid = args[1]
    state.players[sid] = { x = 0, y = 0, hp = 100 }
    state.scores[sid] = 0
    return { { "broadcast", "player_joined", { sid = sid } } }, state
  elseif fn == "leave" then
    local sid = args[1]
    state.players[sid] = nil
    state.scores[sid] = nil
    return state
  elseif fn == "message" then
    local msg, sid, payload = args[1], args[2], args[3]
    local player = state.players[sid]

    if msg == "move" and player then
      player.x = player.x + (payload.x or 0)
      player.y = player.y + (payload.y or 0)
      return {
        { "broadcast", "moved", { sid = sid, x = payload.x or 0, y = payload.y or 0 } },
      }, state
    elseif msg == "hit" then
      local target = payload.target
      if state.players[target] then
        state.scores[sid] = (state.scores[sid] or 0) + 1
        return {
          { "broadcast", "hit", { by = sid, target = target, total = state.scores[sid] } },
        }, state
      end
    end
  end

  return state
end

function M.tick(dt, state)
  -- правила, не физика: hp медленно восстанавливается (100 за ~10 сек)
  for _, player in pairs(state.players) do
    if player.hp < 100 then
      player.hp = math.min(100, player.hp + dt / 100)
    end
  end

  return state
end

return M
