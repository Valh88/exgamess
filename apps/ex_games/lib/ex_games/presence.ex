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

  @doc """
  Помечает пользователя онлайн (ad-hoc: ключ = user_id, держатель — вызвавший
  процесс). Комнатам следует использовать `track_room_user/3`.
  """
  @spec track_user(String.t(), meta()) :: :ok
  def track_user(user_id, meta \\ %{}) when is_binary(user_id) do
    Phoenix.Tracker.track(__MODULE__, self(), @topic, user_id, meta)
    :ok
  end

  @doc """
  Трекает присутствие пользователя **в конкретной комнате**. Внутренний ключ
  трекера — `{user_id, room_id}`, поэтому держателей у юзера несколько (по
  одному на комнату): уход из одной комнаты оставляет онлайн, пока юзер в
  другой; смерть комнаты снимает её записи сама (держатель — процесс комнаты).
  """
  @spec track_room_user(String.t(), String.t(), meta()) :: :ok
  def track_room_user(user_id, room_id, meta \\ %{})
      when is_binary(user_id) and is_binary(room_id) do
    meta =
      meta
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"room_id" => room_id, "user_id" => user_id})

    Phoenix.Tracker.track(__MODULE__, self(), @topic, {user_id, room_id}, meta)
    :ok
  end

  @doc "Снимает трек текущего процесса с пользователя."
  @spec untrack_user(String.t()) :: :ok
  def untrack_user(user_id) when is_binary(user_id) do
    Phoenix.Tracker.untrack(__MODULE__, self(), @topic, user_id)
    :ok
  end

  @doc "Снимает трек пользователя конкретной комнатой (см. `track_room_user/3`)."
  @spec untrack_room_user(String.t(), String.t()) :: :ok
  def untrack_room_user(user_id, room_id) when is_binary(user_id) and is_binary(room_id) do
    Phoenix.Tracker.untrack(__MODULE__, self(), @topic, {user_id, room_id})
    :ok
  end

  @doc """
  Список онлайн-пользователей: `%{user_id => meta}` — по записи на юзера
  (при нескольких комнатах метаданные одной из них; см. `list_online_entries/0`).
  """
  @spec list_online() :: %{String.t() => meta()}
  def list_online do
    Enum.reduce(entries(), %{}, fn
      {key, meta}, acc -> Map.put_new(acc, identity_user(key), meta)
    end)
  end

  @doc "Сырые записи по парам юзер×комната: `%{{user_id, room_id} => meta}`."
  @spec list_online_entries() :: %{{String.t(), String.t()} => meta()}
  def list_online_entries do
    Enum.reduce(entries(), %{}, fn
      {key, meta}, acc when is_tuple(key) -> Map.put(acc, key, meta)
      {_key, _meta}, acc -> acc
    end)
  end

  @doc "Онлайн ли пользователь (хотя бы в одной комнате)."
  @spec online?(String.t()) :: boolean()
  def online?(user_id), do: Enum.any?(entries(), fn {key, _} -> identity_user(key) == user_id end)

  defp entries, do: Phoenix.Tracker.list(__MODULE__, @topic)

  defp identity_user({user_id, _room_id}), do: user_id
  defp identity_user(user_id) when is_binary(user_id), do: user_id

  @doc "Подписка на события presence (см. `event`)."
  @spec subscribe() :: :ok
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end
end
