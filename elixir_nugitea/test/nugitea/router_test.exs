defmodule Nugitea.RouterTest do
  use ExUnit.Case, async: true

  alias Nugitea.Accounts.Directory, as: D
  alias Nugitea.Storage.Client

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous_state = Application.fetch_env!(:nugitea, :state_dir)
    previous_repo = Application.fetch_env!(:nugitea, :repo_root)
    Application.put_env(:nugitea, :state_dir, tmp)
    Application.put_env(:nugitea, :repo_root, tmp)

    on_exit(fn ->
      Application.put_env(:nugitea, :state_dir, previous_state)
      Application.put_env(:nugitea, :repo_root, previous_repo)
    end)

    :ok =
      Nugitea.Accounts.Store.update(tmp, fn d ->
        {:ok, d, _} = D.add_user(d, "user")
        {:ok, d, _} = D.add_repo_at(d, "user/repo", :private)
        {:ok, d}
      end)

    # Initialize the actual git repo
    Client.init_bare("user/repo")

    :ok
  end

  test "info/refs with bad service is 400" do
    conn =
      :get
      |> Plug.Test.conn("/user/repo.git/info/refs?service=bad-service")

    result = Nugitea.Router.call(conn, [])

    assert result.status == 400

    assert result.resp_body ==
             "smart HTTP only: service must be git-upload-pack or git-receive-pack"
  end

  test "info/refs with unknown repo is 404" do
    conn =
      :get
      |> Plug.Test.conn("/unknown/repo.git/info/refs?service=git-upload-pack")

    result = Nugitea.Router.call(conn, [])

    assert result.status == 404
    assert result.resp_body == "not found"
  end

  test "info/refs with known repo is 200" do
    conn =
      :get
      |> Plug.Test.conn("/user/repo.git/info/refs?service=git-upload-pack")

    result = Nugitea.Router.call(conn, [])

    assert result.status == 200
  end
end
