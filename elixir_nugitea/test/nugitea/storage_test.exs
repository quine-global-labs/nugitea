defmodule Nugitea.StorageTest do
  use ExUnit.Case

  alias Nugitea.Storage

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.fetch_env!(:nugitea, :repo_root)
    Application.put_env(:nugitea, :repo_root, tmp)
    on_exit(fn -> Application.put_env(:nugitea, :repo_root, previous) end)
  end

  test "nested layout", %{tmp_dir: root} do
    assert Storage.dir("acme/platform/api") == {:ok, Path.join(root, "acme/platform/api.git")}
    assert {:error, _} = Storage.dir("../x")

    for d <- ["acme/platform/api.git", "alice/dotfiles.git", "legacy.git"],
        do: File.mkdir_p!(Path.join(root, d))

    assert Storage.list() == ["acme/platform/api", "alice/dotfiles"]
    assert Storage.exists?("acme/platform/api")
  end

  test "init_bare installs hooks and refuses to overwrite", %{tmp_dir: root} do
    assert Storage.init_bare("alice/dotfiles") == :ok
    assert File.exists?(Path.join(root, "alice/dotfiles.git/HEAD"))

    assert File.stat!(Path.join(root, "alice/dotfiles.git/hooks/pre-receive")).mode
           |> Bitwise.band(0o111) != 0

    assert {:error, _} = Storage.init_bare("alice/dotfiles")
  end
end
