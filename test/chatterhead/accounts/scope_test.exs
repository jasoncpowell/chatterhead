defmodule Chatterhead.Accounts.ScopeTest do
  use ExUnit.Case, async: true

  alias Chatterhead.Accounts.Scope
  alias Chatterhead.Accounts.User

  describe "for_user/1" do
    test "wraps a user" do
      user = %User{id: 1, name: "alice"}

      assert Scope.for_user(user) == %Scope{user: user}
    end

    test "maps nil to nil" do
      assert Scope.for_user(nil) == nil
    end
  end
end
