defmodule Chatterhead.ChatBroadcastTest do
  # async: false on purpose. send_message/2 broadcasts on one global PubSub
  # topic, so under async: true a concurrent test's broadcast would land in this
  # test's mailbox and break the refute_receive below. `async` is module-level in
  # ExUnit, so the broadcasting tests get their own file. (Plan CHAT-3 commit 4
  # specified async: true; the refute_receive is why this deviates.)
  use Chatterhead.DataCase, async: false

  alias Chatterhead.Accounts
  alias Chatterhead.Accounts.Scope
  alias Chatterhead.Accounts.User
  alias Chatterhead.Chat
  alias Chatterhead.Chat.Message

  setup do
    {:ok, user} = Accounts.join("broadcaster")
    %{scope: Scope.for_user(user)}
  end

  describe "send_message/2" do
    test "persists the message and broadcasts it to subscribers", %{scope: scope} do
      :ok = Chat.subscribe()

      assert {:ok, %Message{id: id, body: "hello"}} = Chat.send_message(scope, %{body: "hello"})

      assert_receive {:new_message, %Message{id: ^id, body: "hello"}}

      persisted = Repo.get(Message, id)
      assert persisted
      # :utc_datetime_usec, not the generator's second-truncating default -- this
      # is what keeps two messages in the same second from tying on reload.
      assert {_microseconds, 6} = persisted.inserted_at.microsecond
    end

    test "the broadcast payload has user preloaded", %{scope: scope} do
      :ok = Chat.subscribe()

      {:ok, _} = Chat.send_message(scope, %{body: "hi"})

      assert_receive {:new_message, %Message{user: %User{name: "broadcaster"}}}
    end

    test "an invalid body inserts nothing and broadcasts nothing", %{scope: scope} do
      :ok = Chat.subscribe()

      assert {:error, %Ecto.Changeset{}} = Chat.send_message(scope, %{body: "   "})

      refute_receive {:new_message, _}
      assert Repo.aggregate(Message, :count) == 0
    end
  end

  describe "change_message/2" do
    test "returns a changeset over a Message" do
      assert %Ecto.Changeset{data: %Message{}} = Chat.change_message()
    end
  end
end
