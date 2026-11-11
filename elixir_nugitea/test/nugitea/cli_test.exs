defmodule Nugitea.CLI.Test do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Nugitea.CLI
  alias Nugitea.Accounts.Directory, as: D

  describe "parse_duration/1" do
    test "parses seconds correctly" do
      assert CLI.parse_duration("30s") == {:ok, 30}
      assert CLI.parse_duration("5m") == {:ok, 300}
      assert CLI.parse_duration("2h") == {:ok, 7200}
    end

    test "handles invalid inputs" do
      assert CLI.parse_duration("") ==
               {:error, "invalid duration \"\": expected a number with s, m, or h"}

      assert CLI.parse_duration("5") ==
               {:error, "invalid duration \"5\": expected a number with s, m, or h"}

      assert CLI.parse_duration("5x") ==
               {:error, "invalid duration \"5x\": expected a number with s, m, or h"}

      assert CLI.parse_duration("-1m") ==
               {:error, "invalid duration \"-1m\": expected a number with s, m, or h"}
    end
  end

  describe "role/1" do
    test "accepts valid roles" do
      assert CLI.role(%{role: "member"}) == {:ok, :member}
      assert CLI.role(%{role: "owner"}) == {:ok, :owner}
      assert CLI.role(%{role: "billing_manager"}) == {:ok, :billing_manager}
    end

    test "rejects invalid roles" do
      assert CLI.role(%{role: "admin"}) ==
               {:error, "invalid role \"admin\": expected member, owner, or billing_manager"}

      assert CLI.role(%{role: "invalid"}) ==
               {:error, "invalid role \"invalid\": expected member, owner, or billing_manager"}
    end

    test "defaults to member" do
      assert CLI.role(%{}) == {:ok, :member}
    end
  end

  describe "token command" do
    setup %{tmp_dir: tmp} do
      # Set up temporary state directory  
      state_dir = Path.join(tmp, "state")
      Application.put_env(:nugitea, :state_dir, state_dir)
      :ok
    end

    test "creates a token for a user" do
      # Create a user first 
      assert CLI.main(["user", "create", "testuser"]) == :ok

      # Create token
      result = CLI.main(["token", "create", "testuser"])

      # Should return a valid token (not an error)  
      assert result == :ok
    end
  end

  describe "seed command" do
    setup %{tmp_dir: tmp} do
      for {key, dir} <- [state_dir: "state", repo_root: "repos"] do
        previous = Application.fetch_env!(:nugitea, key)
        Application.put_env(:nugitea, key, Path.join(tmp, dir))
        on_exit(fn -> Application.put_env(:nugitea, key, previous) end)
      end

      :ok
    end

    defp seed!(tmp, spec) do
      file = Path.join(tmp, "seed.json")
      File.write!(file, Jason.encode!(spec))
      ExUnit.CaptureIO.capture_io(fn -> send(self(), {:result, CLI.main(["seed", file])}) end)
    end

    test "creates users, orgs, members, repos and tokens", %{tmp_dir: tmp} do
      out =
        seed!(tmp, %{
          users: ["alice", "bob"],
          orgs: [
            %{path: "acme", members: %{alice: "owner", bob: "member"}},
            %{path: "acme/platform", visibility: "internal"}
          ],
          repos: [%{path: "acme/platform/api", visibility: "private"}, %{path: "bob/notes"}],
          tokens: ["alice"]
        })

      assert_received {:result, :ok}
      {:ok, dir} = Nugitea.Accounts.Store.load(Nugitea.Accounts.state_dir())
      [alice, bob, acme] = Enum.map(~w(alice bob acme), &D.resolve(dir, &1))
      assert D.org_role(dir, acme, alice) == :owner
      assert D.org_role(dir, acme, bob) == :member
      api = D.resolve_repo(dir, "acme/platform/api")
      assert D.repo(dir, api).visibility == :private
      assert D.repo(dir, D.resolve_repo(dir, "bob/notes")).visibility == :public
      assert Nugitea.Storage.Client.exists?("acme/platform/api")

      %{"tokens" => %{"alice" => token}} = Jason.decode!(out)
      assert Nugitea.Accounts.Tokens.lookup_token(Nugitea.Accounts.state_dir(), token) == alice
    end

    test "stops at the first error and saves nothing", %{tmp_dir: tmp} do
      assert_raise Mix.Error, ~r/no user or org "nobody"/, fn ->
        seed!(tmp, %{users: ["alice"], repos: [%{path: "nobody/repo"}]})
      end

      {:ok, dir} = Nugitea.Accounts.Store.load(Nugitea.Accounts.state_dir())
      assert D.resolve(dir, "alice") == nil
    end
  end
end
