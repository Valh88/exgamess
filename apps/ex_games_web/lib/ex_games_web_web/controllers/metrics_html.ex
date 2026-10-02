defmodule ExGamesWebWeb.MetricsHTML do
  @moduledoc """
  Компоненты страницы `GET /metrics` (см. `ExGamesWebWeb.MetricsController`).
  """

  use ExGamesWebWeb, :html

  embed_templates "metrics_html/*"

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  def metric_card(assigns) do
    ~H"""
    <section class="overflow-hidden rounded-xl border border-zinc-800 bg-zinc-900/60 shadow-sm shadow-black/20">
      <header class="flex items-baseline justify-between gap-3 border-b border-zinc-800 px-5 py-3.5">
        <h2 class="text-sm font-semibold tracking-wider text-zinc-300 uppercase">{@title}</h2>
        <span class="text-xs text-zinc-500">{@subtitle}</span>
      </header>
      <dl class="px-3 py-2">
        {render_slot(@inner_block)}
      </dl>
    </section>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, required: true

  def metric_row(assigns) do
    ~H"""
    <div class="-mx-2 flex items-baseline justify-between gap-4 rounded px-2 py-2 transition-colors hover:bg-zinc-800/25">
      <dt class="truncate font-mono text-xs text-zinc-400" title={@name}>{@name}</dt>
      <dd class="shrink-0 font-mono text-sm text-emerald-400">{@value}</dd>
    </div>
    """
  end

  @doc "Память — человекочитаемо, целые как есть, вещественные с одним знаком."
  def format_value("node.memory_bytes", value), do: human_bytes(value)
  def format_value(_name, value) when is_integer(value), do: Integer.to_string(value)

  def format_value(_name, value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 1)

  def format_value(_name, value), do: to_string(value)

  defp human_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1024 * 1024 * 1024 -> unit(bytes / (1024 * 1024 * 1024), "ГБ")
      bytes >= 1024 * 1024 -> unit(bytes / (1024 * 1024), "МБ")
      bytes >= 1024 -> unit(bytes / 1024, "КБ")
      true -> Integer.to_string(bytes) <> " Б"
    end
  end

  defp unit(value, suffix), do: :erlang.float_to_binary(value, decimals: 1) <> " " <> suffix
end
