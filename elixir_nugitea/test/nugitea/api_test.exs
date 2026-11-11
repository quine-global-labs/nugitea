defmodule Nugitea.APITest do
  # The REST API under /api/v1, route by route, against one fixture:
  #
  #   alice (token)  owns alice/hello (public; main + feature, tag v1.0)
  #                  and alice/secret (private)
  #   bob (token)    a member of acme; on its team `devs`
  #   carol          no memberships
  #   acme           org: alice owner, bob member; owns acme/api (topic elixir)
  use ExUnit.Case, async: false

  alias Nugitea.Accounts.{Store, Tokens}
  alias Nugitea.Accounts.Directory, as: D
  alias Nugitea.Storage.Client

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    for {key, value} <- [state_dir: tmp, repo_root: Path.join(tmp, "repos")] do
      previous = Application.fetch_env!(:nugitea, key)
      Application.put_env(:nugitea, key, value)
      on_exit(fn -> Application.put_env(:nugitea, key, previous) end)
    end

    {:ok, team} =
      Store.update(tmp, fn d ->
        {:ok, d, alice} = D.add_user(d, "alice")
        {:ok, d, bob} = D.add_user(d, "bob")
        {:ok, d, _} = D.add_user(d, "carol")
        {:ok, d, acme} = D.add_org(d, "acme", nil, :public)
        {:ok, d} = D.set_org_member(d, acme, alice, :owner)
        {:ok, d} = D.set_org_member(d, acme, bob, :member)
        {:ok, d, team} = D.add_team(d, acme, "devs", nil, :visible)
        {:ok, d} = D.set_team_member(d, team, bob, :member)
        {:ok, d, _} = D.add_repo_at(d, "alice/hello", :public)
        {:ok, d, _} = D.add_repo_at(d, "alice/secret", :private)
        {:ok, d, api} = D.add_repo_at(d, "acme/api", :public)
        {:ok, d} = D.set_repo_topics(d, api, ["elixir"])
        {:ok, d, team}
      end)

    for repo <- ~w(alice/hello alice/secret acme/api), do: :ok = Client.init_bare(repo)
    push_history(tmp)

    {:ok, dir} = Store.load(tmp)

    %{
      team: team,
      alice: Tokens.create_token(tmp, D.resolve(dir, "alice")),
      bob: Tokens.create_token(tmp, D.resolve(dir, "bob"))
    }
  end

  # alice/hello: main has README.md and src/main.txt (tagged v1.0); feature
  # adds feature.txt on top.
  defp push_history(tmp) do
    work = Path.join(tmp, "work")
    File.mkdir_p!(Path.join(work, "src"))
    git = fn args -> {_, 0} = System.cmd("git", args, cd: work, stderr_to_stdout: true) end

    commit = fn msg ->
      git.(~w(-c user.name=A -c user.email=a@example.com commit -q -m) ++ [msg])
    end

    git.(~w(init -q -b main .))
    File.write!(Path.join(work, "README.md"), "# Hello\n")
    File.write!(Path.join(work, "src/main.txt"), "hello\n")
    git.(~w(add .))
    commit.("First")
    git.(~w(tag v1.0))
    git.(~w(checkout -q -b feature))
    File.write!(Path.join(work, "feature.txt"), "new\n")
    git.(~w(add .))
    commit.("Add feature")
    git.(["push", "-q", Path.join(tmp, "repos/alice/hello.git"), "main", "feature", "v1.0"])
  end

  # A request as `token`'s user (nil = anonymous), with a JSON `body`.
  defp call(method, path, token \\ nil, body \\ nil) do
    conn =
      if body,
        do:
          Plug.Test.conn(method, "/api/v1" <> path, Jason.encode!(body))
          |> Plug.Conn.put_req_header("content-type", "application/json"),
        else: Plug.Test.conn(method, "/api/v1" <> path)

    conn =
      if token, do: Plug.Conn.put_req_header(conn, "authorization", "token " <> token), else: conn

    Nugitea.Router.call(conn, [])
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp status(conn), do: conn.status

  describe "basics" do
    test "version, and JSON 404s for unknown routes" do
      assert %{"version" => _} = json(call(:get, "/version"))
      conn = call(:get, "/nope")
      assert {404, %{"message" => "not found"}} == {status(conn), json(conn)}
    end

    test "GET /user", %{alice: alice} do
      assert status(call(:get, "/user")) == 401
      assert %{"login" => "alice", "id" => _} = json(call(:get, "/user", alice))
    end

    test "blocking a user", %{alice: alice} do
      assert status(call(:put, "/user/blocks/carol")) == 401
      assert status(call(:put, "/user/blocks/carol", alice)) == 204
      assert [%{"login" => "carol"}] = json(call(:get, "/user/blocks", alice))
      assert status(call(:put, "/user/blocks/alice", alice)) == 422
      assert status(call(:put, "/user/blocks/acme", alice)) == 404
      assert status(call(:delete, "/user/blocks/carol", alice)) == 204
      assert json(call(:get, "/user/blocks", alice)) == []
    end
  end

  describe "users and orgs" do
    test "GET /users/:username" do
      assert %{"login" => "alice"} = json(call(:get, "/users/ALICE"))
      assert status(call(:get, "/users/acme")) == 404
      assert status(call(:get, "/users/nobody")) == 404
    end

    test "a user's repos, as the caller can see them", %{alice: alice} do
      names = fn conn -> conn |> json() |> Enum.map(& &1["full_name"]) |> Enum.sort() end
      assert names.(call(:get, "/users/alice/repos")) == ["alice/hello"]
      assert names.(call(:get, "/users/alice/repos", alice)) == ["alice/hello", "alice/secret"]
      assert status(call(:get, "/users/acme/repos")) == 404
    end

    test "starred: the caller's visible repos for themselves, 404 for others", %{
      alice: alice,
      bob: bob
    } do
      names = fn conn -> conn |> json() |> Enum.map(& &1["full_name"]) |> Enum.sort() end
      assert names.(call(:get, "/users/alice/starred")) == ["acme/api", "alice/hello"]
      assert "alice/secret" in names.(call(:get, "/users/alice/starred", alice))
      assert status(call(:get, "/users/alice/starred", bob)) == 404
    end

    test "an org, its repos, members and teams" do
      assert %{"name" => "acme", "visibility" => "public"} = json(call(:get, "/orgs/acme"))
      assert status(call(:get, "/orgs/alice")) == 404
      assert [%{"full_name" => "acme/api"}] = json(call(:get, "/orgs/acme/repos"))
      logins = call(:get, "/orgs/acme/members") |> json() |> Enum.map(& &1["login"])
      assert Enum.sort(logins) == ["alice", "bob"]
      assert [%{"name" => "devs"}] = json(call(:get, "/orgs/acme/teams"))
    end
  end

  describe "teams" do
    test "visible to org members only", %{team: team, bob: bob} do
      assert status(call(:get, "/teams/#{team}")) == 404

      assert %{"name" => "devs", "organization" => %{"name" => "acme"}} =
               json(call(:get, "/teams/#{team}", bob))

      assert [%{"login" => "bob"}] = json(call(:get, "/teams/#{team}/members", bob))
      assert status(call(:get, "/teams/999", bob)) == 404
      assert status(call(:get, "/teams/x", bob)) == 404
    end

    test "only org owners change members", %{team: team, alice: alice, bob: bob} do
      assert status(call(:put, "/teams/#{team}/members/alice", bob)) == 403
      # carol isn't in the org.
      assert status(call(:put, "/teams/#{team}/members/carol", alice)) == 422
      assert status(call(:put, "/teams/#{team}/members/alice", alice)) == 204
      logins = call(:get, "/teams/#{team}/members", alice) |> json() |> Enum.map(& &1["login"])
      assert Enum.sort(logins) == ["alice", "bob"]
      assert status(call(:delete, "/teams/#{team}/members/bob", alice)) == 204
      assert [%{"login" => "alice"}] = json(call(:get, "/teams/#{team}/members", alice))
    end
  end

  describe "a repo" do
    test "GET, with the caller's permissions", %{alice: alice} do
      repo = json(call(:get, "/repos/Alice/Hello"))

      assert %{
               "name" => "hello",
               "full_name" => "alice/hello",
               "empty" => false,
               "private" => false,
               "default_branch" => "main",
               "branch_count" => 2,
               "permissions" => %{"admin" => false, "push" => false, "pull" => true}
             } = repo

      assert repo["size"] > 0

      assert %{"admin" => true, "push" => true} =
               json(call(:get, "/repos/alice/hello", alice))["permissions"]

      assert status(call(:get, "/repos/alice/secret")) == 404
    end

    test "permissions", %{alice: alice, bob: bob} do
      assert json(call(:get, "/repos/alice/hello/permissions")) == %{"permission" => "read"}

      assert json(call(:get, "/repos/alice/hello/permissions", alice)) == %{
               "permission" => "admin"
             }

      assert status(call(:get, "/repos/alice/secret/permissions", bob)) == 404
    end

    test "PATCH needs admin, and the change persists", %{alice: alice, bob: bob} do
      change = %{description: "Greetings", website: "https://example.com"}
      assert status(call(:patch, "/repos/alice/hello", bob, change)) == 403

      assert %{"description" => "Greetings"} =
               json(call(:patch, "/repos/alice/hello", alice, change))

      assert %{"description" => "Greetings", "website" => "https://example.com"} =
               json(call(:get, "/repos/alice/hello"))
    end

    test "topics", %{alice: alice, bob: bob} do
      assert json(call(:get, "/repos/acme/api/topics")) == ["elixir"]
      assert status(call(:put, "/repos/alice/hello/topics", bob, %{topics: ["x"]})) == 403
      assert status(call(:put, "/repos/alice/hello/topics", alice, %{topics: [1]})) == 422

      assert json(call(:put, "/repos/alice/hello/topics", alice, %{topics: ["git", "web"]})) ==
               %{"topics" => ["git", "web"]}

      assert json(call(:get, "/repos/alice/hello/topics")) == ["git", "web"]
      assert status(call(:delete, "/repos/alice/hello/topics", alice)) == 204
      assert json(call(:get, "/repos/alice/hello/topics")) == []
    end

    test "mirror-sync", %{alice: alice, bob: bob} do
      assert status(call(:post, "/repos/alice/hello/mirror-sync", bob)) == 403
      # Not a mirror.
      assert status(call(:post, "/repos/alice/hello/mirror-sync", alice)) == 404
    end
  end

  describe "pull requests and issues" do
    test "open, list, get, close", %{alice: alice, bob: bob} do
      assert status(call(:post, "/repos/alice/hello/pulls", bob, %{title: "x"})) == 422

      created =
        call(:post, "/repos/alice/hello/pulls", bob, %{
          title: "Add feature",
          body: "Please",
          head: "feature",
          base: "main"
        })

      assert status(created) == 201
      %{"number" => number, "state" => "open", "title" => "Add feature"} = json(created)

      assert [%{"number" => ^number}] = json(call(:get, "/repos/alice/hello/pulls"))

      assert %{"body" => "Please", "head" => %{"ref" => "feature"}} =
               json(call(:get, "/repos/alice/hello/pulls/#{number}"))

      assert status(call(:get, "/repos/alice/hello/pulls/1")) == 404

      assert status(call(:patch, "/repos/alice/hello/pulls/#{number}", bob, %{state: "closed"})) ==
               403

      assert %{"state" => "closed"} =
               json(call(:patch, "/repos/alice/hello/pulls/#{number}", alice, %{state: "closed"}))

      assert json(call(:get, "/repos/alice/hello/pulls?state=open")) == []
      assert [_] = json(call(:get, "/repos/alice/hello/pulls?state=closed"))
    end

    test "PATCH an issue", %{alice: alice, tmp_dir: tmp} do
      {:ok, dir} = Store.load(tmp)
      repo = D.resolve_repo(dir, "alice/hello")
      {:ok, id} = Store.update(tmp, &D.create_issue(&1, repo, "Bug", "Broken", nil))

      assert %{"title" => "Bug", "state" => "closed"} =
               json(call(:patch, "/repos/alice/hello/issues/#{id}", alice, %{state: "closed"}))

      assert status(call(:patch, "/repos/alice/hello/issues/nope", alice, %{state: "closed"})) ==
               404
    end

    test "GET a milestone", %{tmp_dir: tmp} do
      {:ok, dir} = Store.load(tmp)
      repo = D.resolve_repo(dir, "alice/hello")
      {:ok, id} = Store.update(tmp, &D.create_milestone(&1, repo, "v2", "Next", nil, nil))

      assert %{"title" => "v2", "state" => "open"} =
               json(call(:get, "/repos/alice/hello/milestones/#{id}"))

      assert status(call(:get, "/repos/alice/hello/milestones/nope")) == 404
    end
  end

  describe "forks" do
    test "fork into your own account", %{bob: bob} do
      assert status(call(:post, "/repos/alice/hello/forks")) == 401

      fork = call(:post, "/repos/alice/hello/forks", bob, %{})
      assert status(fork) == 202

      assert %{
               "full_name" => "bob/hello",
               "fork" => true,
               "parent" => %{"full_name" => "alice/hello"}
             } =
               json(fork)

      assert Client.exists?("bob/hello")
      assert [%{"full_name" => "bob/hello"}] = json(call(:get, "/repos/alice/hello/forks"))
      assert status(call(:post, "/repos/alice/hello/forks", bob, %{})) == 409
    end

    test "fork into an org needs org ownership", %{alice: alice, bob: bob} do
      assert status(call(:post, "/repos/alice/hello/forks", bob, %{organization: "acme"})) == 403

      assert %{"full_name" => "acme/hello2"} =
               json(
                 call(:post, "/repos/alice/hello/forks", alice, %{
                   organization: "acme",
                   name: "hello2"
                 })
               )
    end
  end

  describe "git data" do
    test "branches" do
      branches = json(call(:get, "/repos/alice/hello/branches"))
      assert Enum.map(branches, & &1["name"]) == ["feature", "main"]

      assert %{"name" => "main", "commit" => %{"message" => "First"}} =
               json(call(:get, "/repos/alice/hello/branches/main"))

      assert status(call(:get, "/repos/alice/hello/branches/nope")) == 404
    end

    test "a commit as a diff and a patch" do
      %{"commit" => %{"id" => sha}} = json(call(:get, "/repos/alice/hello/branches/feature"))

      diff = call(:get, "/repos/alice/hello/git/commits/#{sha}.diff")
      assert status(diff) == 200
      assert diff.resp_body =~ "+++ b/feature.txt"

      patch = call(:get, "/repos/alice/hello/git/commits/#{sha}.patch")
      assert patch.resp_body =~ "Subject: [PATCH] Add feature"
      assert status(call(:get, "/repos/alice/hello/git/commits/0000000.diff")) == 404
    end

    test "compare" do
      assert %{
               "total_commits" => 1,
               "files" => [%{"filename" => "feature.txt"}],
               "commits" => [c]
             } =
               json(call(:get, "/repos/alice/hello/compare/main...feature"))

      assert %{"message" => "Add feature", "sha" => _} = c
      assert status(call(:get, "/repos/alice/hello/compare/main")) == 400
      assert status(call(:get, "/repos/alice/hello/compare/main...nope")) == 404
    end

    test "raw files and archives" do
      assert call(:get, "/repos/alice/hello/raw/src/main.txt").resp_body == "hello\n"
      assert call(:get, "/repos/alice/hello/raw/feature.txt?ref=feature").resp_body == "new\n"
      assert status(call(:get, "/repos/alice/hello/raw/feature.txt")) == 404
      assert <<"PK", _::binary>> = call(:get, "/repos/alice/hello/archive/v1.0.zip").resp_body
      assert status(call(:get, "/repos/alice/hello/archive/main.rar")) == 404
    end
  end

  describe "search" do
    test "by name, topic and visibility, paged", %{alice: alice} do
      names = fn conn ->
        %{"ok" => true, "data" => data} = json(conn)
        Enum.map(data, & &1["full_name"])
      end

      assert names.(call(:get, "/repos/search?q=HEL")) == ["alice/hello"]
      assert names.(call(:get, "/repos/search?q=secret")) == []
      assert names.(call(:get, "/repos/search?q=secret", alice)) == ["alice/secret"]
      assert names.(call(:get, "/repos/search?q=elix&topic=true")) == ["acme/api"]
      assert names.(call(:get, "/repos/search")) == ["acme/api", "alice/hello"]

      assert names.(call(:get, "/repos/search?sort=name&order=desc")) == [
               "alice/hello",
               "acme/api"
             ]

      assert names.(call(:get, "/repos/search?limit=1&page=2")) == ["alice/hello"]
      assert names.(call(:get, "/repos/search?limit=nope")) == ["acme/api", "alice/hello"]
    end
  end
end
