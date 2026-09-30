defmodule ExGames.GameLogic do
  @moduledoc """
  Мост к игровой логике — в Elixir или в нативном процессе (любой язык).

  Адаптер выбирается конфигурацией при старте логики:

      # in-process логика (модуль Elixir)
      ExGames.GameLogic.start_link(
        adapter: ExGames.GameLogic.Adapters.Elixir,
        module: MyGame.Rules,
        id: "arena_1"
      )

      # нативный бинарник через stdio (Port)
      ExGames.GameLogic.start_link(
        adapter: ExGames.GameLogic.Adapters.Port,
        command: {"priv/native/rules.exe", []},
        id: "arena_1"
      )

      # тот же бинарник по TCP (фрейминг идентичен stdio-варианту)
      ExGames.GameLogic.start_link(
        adapter: ExGames.GameLogic.Adapters.TCP,
        host: "127.0.0.1", port: 9100,
        id: "arena_1"
      )

  ## Протокол адаптеров

  Запросы и ответы — msgpack-документы с length-prefix u32
  (`{:packet, 4}` в Erlang; в Haxe/Rust/Go — собрать `size::u32` + payload):

      запрос:  {"op": "call" | "tick" | "init", "fn": "...", "args": [...], "state": ..., "dt": ms}
      ответ:   {"ok": true, "result": ..., "state": ...} | {"ok": false, "error": "..."}

  Нативная сторона stateless-переносима: состояние игры передаётся в каждом
  запросе и возвращается в ответе (владелец состояния — процесс комнаты).
  Так нативный краш не теряет игру: комната перезапускает адаптер и
  продолжает с последнего известного состояния.

  ## Добавление нового транспорта (например, NIF)

  Реализуйте behaviour `ExGames.GameLogic.Adapter` и укажите модуль в
  `:adapter` — ядро изменений не требует.
  """

  @typedoc "Состояние игры (непрозрачно для ядра, прозрачно для msgpack)."
  @type state :: term()

  @typedoc "Опции запуска адаптера."
  @type opts :: keyword()

  @doc "Запускает адаптер (процесс/ресурс). Возвращает дескриптор."
  @callback start_link(opts()) :: {:ok, handle :: term()} | {:error, term()}

  @doc "Вызов функции логики; вернёт {result, new_state}."
  @callback call(handle :: term(), fn_name :: String.t(), args :: [term()], state()) ::
              {:ok, result :: term(), state()} | {:error, term()}

  @doc "Тик логики; вернёт новое состояние (и факультативный результат: {:ok, result, state})."
  @callback tick(handle :: term(), dt_ms :: non_neg_integer(), state()) ::
              {:ok, state()} | {:ok, result :: term(), state()} | {:error, term()}

  @doc "Останавливает адаптер."
  @callback stop(handle :: term()) :: :ok

  @typedoc "Полное описание логики для старта."
  @type spec :: %{required(:adapter) => module(), optional(atom()) => term()}

  # Утилиты framing для потоковых адаптеров (Port/TCP).
  defmodule Framing do
    @moduledoc false

    @doc "Кодирует msgpack-документ с u32 length-prefix."
    def encode(term) do
      payload = Msgpax.pack!(term, iodata: true)
      [<<IO.iodata_length(payload)::unsigned-integer-size(32)>>, payload]
    end

    @doc "Извлекает документ из потока (накопитель — binary). Возвращает {doc, rest}."
    def decode(buffer) when is_binary(buffer) do
      with <<len::unsigned-integer-size(32), rest::binary>> <- buffer,
           true <- byte_size(rest) >= len do
        <<payload::binary-size(len), rest::binary>> = rest

        case Msgpax.unpack(payload) do
          {:ok, doc} -> {doc, rest}
          _ -> :error
        end
      else
        _ -> :incomplete
      end
    end
  end
end
