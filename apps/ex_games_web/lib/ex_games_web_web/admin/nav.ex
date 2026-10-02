defmodule ExGamesWebWeb.Admin.Nav do
  @moduledoc """
  Реестр разделов админ-панели — единственное место, где описана навигация.

  Точка расширения: новая страница = модуль LiveView + роут + строка здесь.
  """

  @items [
    %{label: "Обзор", path: "/admin", icon: "hero-squares-2x2"},
    %{label: "Пользователи", path: "/admin/users", icon: "hero-users"},
    %{label: "Комнаты", path: "/admin/rooms", icon: "hero-server-stack"},
    %{label: "Онлайн", path: "/admin/online", icon: "hero-signal"},
    %{label: "Метрики", path: "/admin/metrics", icon: "hero-chart-bar"}
  ]

  @spec items() :: [%{label: String.t(), path: String.t(), icon: String.t()}]
  def items, do: @items
end
