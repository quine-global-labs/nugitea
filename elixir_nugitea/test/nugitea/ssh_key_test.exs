defmodule Nugitea.SSHKeyTest do
  use ExUnit.Case, async: true

  alias Nugitea.Accounts.Directory

  test "SSH key storage works" do
    # Start with an empty directory
    dir = %Directory{}

    # Add a user
    {:ok, dir_with_user, user_id} = Directory.add_user(dir, "testuser")

    # Add an SSH key to the user
    key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4sVh7b6HqJyjK7dG0gU9tP1vXm8cDpF3rY2uLx7aMn"

    {:ok, dir_with_key} = Directory.add_user_key(dir_with_user, user_id, key)

    # Check that the key was stored
    keys = Directory.get_user_keys(dir_with_key, user_id)
    assert length(keys) == 1
    assert keys |> hd() |> Map.get(:key) == key

    # Try adding the same key again (should not duplicate)
    {:ok, dir_after_duplicate} = Directory.add_user_key(dir_with_key, user_id, key)
    keys_after_duplicate = Directory.get_user_keys(dir_after_duplicate, user_id)
    assert length(keys_after_duplicate) == 1
  end
end
