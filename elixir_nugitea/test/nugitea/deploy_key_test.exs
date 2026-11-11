defmodule Nugitea.DeployKeyTest do
  use ExUnit.Case, async: true

  alias Nugitea.Accounts.Directory

  test "deploy keys can be added to repositories" do
    # Start with an empty directory
    dir = %Directory{}

    # Add a user 
    {:ok, dir_with_user, user_id} = Directory.add_user(dir, "testuser")

    # Add a repo
    {:ok, dir_with_repo, repo_id} =
      Directory.add_repo(dir_with_user, user_id, "testrepo", :public)

    # Add an SSH deploy key to the repo
    key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4sVh7b6HqJyjK7dG0gU9tP1vXm8cDpF3rY2uLx7aMn"

    {:ok, dir_with_key} = Directory.add_deploy_key(dir_with_repo, repo_id, key, true)

    # Check that the key was stored
    keys = Directory.get_deploy_keys(dir_with_key, repo_id)
    assert length(keys) == 1
    assert keys |> hd() |> Map.get(:key) == key
    assert keys |> hd() |> Map.get(:read_only) == true

    # Try adding the same key again (should not duplicate)
    {:ok, dir_after_duplicate} = Directory.add_deploy_key(dir_with_key, repo_id, key, true)
    keys_after_duplicate = Directory.get_deploy_keys(dir_after_duplicate, repo_id)
    assert length(keys_after_duplicate) == 1
  end

  test "deploy keys are different from user keys" do
    # Start with an empty directory
    dir = %Directory{}

    # Add a user 
    {:ok, dir_with_user, user_id} = Directory.add_user(dir, "testuser")

    # Add a repo
    {:ok, dir_with_repo, repo_id} =
      Directory.add_repo(dir_with_user, user_id, "testrepo", :public)

    # Add an SSH deploy key to the repo
    key1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4sVh7b6HqJyjK7dG0gU9tP1vXm8cDpF3rY2uLx7aMn"
    {:ok, dir_with_key} = Directory.add_deploy_key(dir_with_repo, repo_id, key1, true)

    # Add an SSH user key to the same user
    key2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHz9qXpL0v4mV1sJyT0gY7wQ8rS9dP0aT1zBx3cD4eF5"
    {:ok, dir_with_user_key} = Directory.add_user_key(dir_with_key, user_id, key2)

    # Check both keys are stored separately
    deploy_keys = Directory.get_deploy_keys(dir_with_user_key, repo_id)
    user_keys = Directory.get_user_keys(dir_with_user_key, user_id)

    assert length(deploy_keys) == 1
    assert length(user_keys) == 1

    assert deploy_keys |> hd() |> Map.get(:key) == key1
    assert user_keys |> hd() |> Map.get(:key) == key2
  end

  test "deploy keys can be read only or read-write" do
    # Start with an empty directory
    dir = %Directory{}

    # Add a user 
    {:ok, dir_with_user, user_id} = Directory.add_user(dir, "testuser")

    # Add a repo
    {:ok, dir_with_repo, repo_id} =
      Directory.add_repo(dir_with_user, user_id, "testrepo", :public)

    # Add an SSH deploy key to the repo (read-only)
    key1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4sVh7b6HqJyjK7dG0gU9tP1vXm8cDpF3rY2uLx7aMn"
    {:ok, dir_with_key1} = Directory.add_deploy_key(dir_with_repo, repo_id, key1, true)

    # Add an SSH deploy key to the repo (read-write)
    key2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDK0zQ8v4uT9eV7cY6fW5tB3yR2iZ4mN7pL1kA9bC6dE"
    {:ok, dir_with_key2} = Directory.add_deploy_key(dir_with_key1, repo_id, key2, false)

    # Check that both keys were stored
    deploy_keys = Directory.get_deploy_keys(dir_with_key2, repo_id)
    assert length(deploy_keys) == 2

    # Check key properties
    [key_info1, key_info2] = deploy_keys
    assert key_info1.key == key1
    assert key_info1.read_only == true
    assert key_info2.key == key2
    assert key_info2.read_only == false
  end
end
