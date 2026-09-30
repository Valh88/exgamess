-- Фикстура request-потока моста (room_logics_lua_test): M.call("request",
-- [type, sid, payload]) возвращает {значение-ответ, state}; nil = «нет
-- обработчика» — мост отвечает ошибкой с request_id.
M = {}

M.schema = {
  messages = { "ping" },
}

function M.init(_args)
  return { pings = 0, answers = 0 }
end

function M.call(fn, args, state)
  if fn == "request" then
    local t, sid, payload = args[1], args[2], args[3]

    if t == "answer" then
      state.answers = state.answers + 1
      return { to = sid, q = payload.q, n = state.answers }, state
    end

    return nil, state
  end

  if fn == "message" and args[1] == "ping" then
    state.pings = state.pings + 1
    return { { "broadcast", "pong", { total = state.pings } } }, state
  end

  return state
end

function M.tick(_dt, state)
  return state
end
