defmodule Chatterhead.Chat.MessageTest do
  use Chatterhead.DataCase, async: true

  alias Chatterhead.Chat.Message

  describe "changeset/2" do
    test "trims the body" do
      changeset = Message.changeset(%Message{}, %{body: "  hello  "})

      assert changeset.valid?
      assert get_change(changeset, :body) == "hello"
    end

    test "rejects a whitespace-only body" do
      changeset = Message.changeset(%Message{}, %{body: "  \t  "})

      refute changeset.valid?
      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires a body" do
      changeset = Message.changeset(%Message{}, %{})

      refute changeset.valid?
      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts a body at the 2000-character boundary" do
      assert Message.changeset(%Message{}, %{body: String.duplicate("a", 2000)}).valid?
    end

    test "rejects a body one character past the boundary" do
      changeset = Message.changeset(%Message{}, %{body: String.duplicate("a", 2001)})

      refute changeset.valid?
      assert %{body: ["should be at most 2000 character(s)"]} = errors_on(changeset)
    end

    test "does not cast user_id" do
      changeset = Message.changeset(%Message{}, %{body: "hi", user_id: 999})

      assert get_change(changeset, :user_id) == nil
    end
  end
end
