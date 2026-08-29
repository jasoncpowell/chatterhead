defmodule ChatterheadWeb.RoomLive do
  @moduledoc """
  The one shared room: the most recent page of history streamed on mount, and
  live fan-out of every new message to every connected client (the sender
  included — no local echo). CHAT-10 adds "load older"; CHAT-11 adds presence
  tracking and the roster.
  """
  use ChatterheadWeb, :live_view

  alias Chatterhead.Chat
  alias Chatterhead.Chat.Message

  @impl true
  def mount(_params, _session, socket) do
    {messages, more_history?} = Chat.list_recent()

    if connected?(socket), do: Chat.subscribe()

    {:ok,
     socket
     |> assign(:more_history?, more_history?)
     |> assign(:oldest_cursor, oldest_cursor(messages))
     |> assign(:form, to_form(Chat.change_message()))
     |> stream(:messages, messages)}
  end

  @impl true
  def handle_event("validate", %{"message" => params}, socket) do
    changeset = Chat.change_message(%Message{}, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("load_older", _params, socket) do
    case socket.assigns.oldest_cursor do
      nil ->
        {:noreply, socket}

      cursor ->
        {older, more_history?} = Chat.list_before(cursor)

        # list_before/2 returns oldest-first; stream/4 at: 0 displays a batch in
        # reverse, so feed it newest-first and the oldest lands on top. One
        # stream/4 call, the documented idiom.
        {:noreply,
         socket
         |> stream(:messages, Enum.reverse(older), at: 0)
         |> assign(:more_history?, more_history?)
         |> assign(:oldest_cursor, oldest_cursor(older) || socket.assigns.oldest_cursor)}
    end
  end

  def handle_event("send", %{"message" => params}, socket) do
    case Chat.send_message(socket.assigns.current_scope, params) do
      {:ok, _message} ->
        # No stream_insert here -- the message arrives via the PubSub
        # subscription like everyone else's. One code path, one ordering.
        {:noreply, assign(socket, :form, to_form(Chat.change_message()))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
    end
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto flex w-full min-h-0 max-w-3xl flex-1 flex-col">
        <div :if={@more_history?} class="border-b border-base-300 p-2 text-center">
          <button
            id="load-older"
            type="button"
            phx-click="load_older"
            phx-disable-with="Loading…"
            class="text-xs font-medium text-base-content/60 hover:text-base-content"
          >
            Load older messages
          </button>
        </div>

        <div
          id="messages"
          phx-update="stream"
          phx-hook=".MessageList"
          class="min-h-0 flex-1 overflow-y-auto p-4"
        >
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

        <div class="border-t border-base-300 p-4">
          <.form
            for={@form}
            id="message-form"
            phx-submit="send"
            phx-change="validate"
            class="flex items-start gap-2"
          >
            <div class="flex-1">
              <.input
                field={@form[:body]}
                type="text"
                placeholder="Message the room"
                autocomplete="off"
              />
            </div>
            <.button>Send</.button>
          </.form>
        </div>
      </div>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".MessageList">
      export default {
        mounted() {
          this.pinToBottom()
        },
        beforeUpdate() {
          const el = this.el
          // within ~2 lines of the bottom counts as "reading the newest"
          this.wasAtBottom = el.scrollHeight - el.clientHeight - el.scrollTop < 48
        },
        updated() {
          if (this.wasAtBottom) this.pinToBottom()
        },
        pinToBottom() {
          this.el.scrollTop = this.el.scrollHeight
        }
      }
    </script>
    """
  end

  defp oldest_cursor([]), do: nil
  defp oldest_cursor([oldest | _]), do: Chat.cursor(oldest)
end
