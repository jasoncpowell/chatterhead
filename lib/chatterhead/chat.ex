defmodule Chatterhead.Chat do
  @moduledoc """
  Messages, history, and fan-out for the single global room.

  History is windowed: `list_recent/1` returns the most recent page, and
  `list_before/2` walks backwards from a keyset cursor. Both return their page
  oldest-first so call sites cannot confuse them.
  """

  import Ecto.Query

  alias Chatterhead.Accounts.Scope
  alias Chatterhead.Chat.Message
  alias Chatterhead.Repo

  @page_size 50
  @topic "chat:room"

  @doc """
  The most recent page of history, oldest-first, each message with `user`
  preloaded. The boolean is `true` when older messages exist beyond this page.
  """
  @spec list_recent(pos_integer()) :: {[Message.t()], boolean()}
  def list_recent(limit \\ @page_size) do
    Message
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^(limit + 1))
    |> preload(:user)
    |> Repo.all()
    |> finish_page(limit)
  end

  @doc """
  The page of history immediately before `cursor`, oldest-first, `user`
  preloaded. `cursor` is `{inserted_at, id}` from `cursor/1`; the row at the
  cursor is excluded.
  """
  @spec list_before({DateTime.t(), integer()}, pos_integer()) :: {[Message.t()], boolean()}
  def list_before({inserted_at, id}, limit \\ @page_size) do
    Message
    |> where(
      [m],
      fragment("(?, ?) < (?, ?)", m.inserted_at, m.id, type(^inserted_at, m.inserted_at), ^id)
    )
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^(limit + 1))
    |> preload(:user)
    |> Repo.all()
    |> finish_page(limit)
  end

  @doc "The keyset cursor for a message: `{inserted_at, id}`."
  @spec cursor(Message.t()) :: {DateTime.t(), integer()}
  def cursor(%Message{inserted_at: inserted_at, id: id}), do: {inserted_at, id}

  @doc "The history page size."
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @doc "The PubSub topic new messages are broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the calling process to `{:new_message, message}` broadcasts."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Chatterhead.PubSub, @topic)
  end

  @doc """
  Persists a message and broadcasts it to every subscriber.

  Broadcasting from the context, not the LiveView, means an IEx session or a
  future HTTP caller also fans out. The payload carries a fully-loaded
  `%Message{user: %User{}}` so no subscriber re-queries, and there is no local
  echo -- the sender receives their own message through the broadcast like
  everyone else, for one code path and identical ordering everywhere.
  """
  @spec send_message(Scope.t(), map()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def send_message(%Scope{user: user}, attrs) do
    %Message{user_id: user.id}
    |> Message.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, message} ->
        message = %{message | user: user}
        Phoenix.PubSub.broadcast(Chatterhead.PubSub, @topic, {:new_message, message})
        {:ok, message}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "A changeset for the compose form."
  @spec change_message(Message.t(), map()) :: Ecto.Changeset.t()
  def change_message(message \\ %Message{}, attrs \\ %{})

  def change_message(%Message{} = message, attrs) do
    Message.changeset(message, attrs)
  end

  # Both queries fetch newest-first with one extra row: the extra row is the
  # "more?" signal. Drop it, then reverse to oldest-first.
  defp finish_page(rows, limit) do
    more? = length(rows) > limit
    page = rows |> Enum.take(limit) |> Enum.reverse()
    {page, more?}
  end
end
