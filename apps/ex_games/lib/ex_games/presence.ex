defmodule ExGames.Presence do
  @moduledoc """
  Presence на `Phoenix.Tracker`: онлайн-статусы юзеров и комнат.

  Трекинг:

      ExGames.Presence.track_user(user_id, %{"room_id" => rid, "username" => "ann"})
      ExGames.Presence.untrack_user(user_id)

  Чтение:

      ExGames.Presence.list_online()
      ExGames.Presence.online?(user_id)

  Подписчики (чат, лобби, админка) слушают PubSub-топик `"presence"` —
  получают `%PresenceState{event: :join | :leave, user_id, meta}`.
  При смерти трекирующего процесса Phoenix.Tracker чистит записи сам.
  """

  use Phoenix.Tracker

  require Logger

  @pubsub ExGames.PubSub
  @topic "presence"

  @typedoc "Метаданные онлайн-пользователя."
  @type meta :: map()

  @typedoc "Событие presence для подписчиков."
  @type event :: %{event: :join | :leave, user_id: String.t(), meta: meta()}

  @doc false
  def start_link(opts \\ []) do
    opts = Keyword.merge([name: __MODULE__, pubsub_server: @pubsub], opts)
    Phoenix.Tracker.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init([]) do
    {:ok, %{pubsub_server: @pubsub, topic: @topic}}
  end

  @impl true
  def handle_diff(diff, state) do
    # Phoenix.Tracker вызывает diff только для своей шарды; события шлём в PubSub.
    for {topic, {joins, leaves}} <- diff, topic == state.topic do
      for {user_id, meta} <- joins do
        msg = %{event: :join, user_id: user_id, meta: meta}
        Phoenix.PubSub.broadcast(state.pubsub_server, state.topic, {__MODULE__, msg})
      end

      for {user_id, meta} <- leaves do
        msg = %{event: :leave, user_id: user_id, meta: meta}
        Phoenix.PubSub.broadcast(state.pubsub_server, state.topic, {__MODULE__, msg})
      end
    end

    {:ok, state}
  end

  # -------------------------------------------------------------------------
  # API
  # -------------------------------------------------------------------------

  @doc "Помечает пользователя онлайн; метаданные — произвольная map (string-ключи)."
  @spec track_user(String.t(), meta()) :: :ok
  def track_user(user_id, meta \\ %{}) when is_binary(user_id) do
    Phoenix.Tracker.track(__MODULE__, self(), @topic, user_id, meta)
    :ok
  end

  @doc "Убирает пользователя из онлайн (обычно не нужен: чистится при смерти процесса)."
  @spec untrack_user(String.t()) :: :ok
  def untrack_user(user_id) when is_binary(user_id) do
    Phoenix.Tracker.untrack(__MODULE__, self(), @topic, user_id)
    :ok
  end

  @doc "Список онлайн-пользователей: %{user_id => meta}."
  @spec list_online() :: %{String.t() => meta()}
  def list_online do
    Phoenix.Tracker.list(__MODULE__, @topic)
    |> Map.new()
  end

  @doc "Онлайн ли пользователь."
  @spec online?(String.t()) :: boolean()
  def online?(user_id), do: Map.has_key?(list_online(), user_id)

  @doc "Подписка на события presence (см. `event`)."
  @spec subscribe() :: :ok
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end
end
