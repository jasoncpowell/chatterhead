defmodule ChatterheadWeb.RoomLive do
  @moduledoc """
  The one shared room. Minimal for now — CHAT-9 adds the message pane and
  composer, CHAT-11 the live roster and presence tracking.
  """
  use ChatterheadWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex flex-1 items-center justify-center p-6 text-sm text-base-content/60">
        You're in the room as <span class="mx-1 font-medium text-base-content">{@current_scope.user.name}</span>.
      </div>
    </Layouts.app>
    """
  end
end
