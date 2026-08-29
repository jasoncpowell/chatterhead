defmodule ChatterheadWeb.RoomLive do
  @moduledoc """
  The one shared room: the most recent page of history streamed on mount, and
  live fan-out of every new message to every connected client (the sender
  included — no local echo). CHAT-10 adds "load older"; CHAT-11 adds presence
  tracking and the roster.
  """
  use ChatterheadWeb, :live_view

  alias Chatterhead.Chat

  @impl true
  def mount(_params, _session, socket) do
    {messages, more_history?} = Chat.list_recent()

    if connected?(socket), do: Chat.subscribe()

    {:ok,
     socket
     |> assign(:more_history?, more_history?)
     |> assign(:oldest_cursor, oldest_cursor(messages))
     |> stream(:messages, messages)}
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto flex w-full max-w-3xl flex-1 flex-col">
        <div id="messages" phx-update="stream" class="flex-1 overflow-y-auto p-4">
          <div
            id="messages-empty"
            class="hidden py-16 text-center text-sm text-base-content/50 only:block"
          >
            No messages yet. Say something.
          </div>
          <div :for={{dom_id, message} <- @streams.messages} id={dom_id}>
            <.message message={message} current_user_id={@current_scope.user.id} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp oldest_cursor([]), do: nil
  defp oldest_cursor([oldest | _]), do: Chat.cursor(oldest)
end
