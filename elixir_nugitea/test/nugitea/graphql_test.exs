defmodule Nugitea.GraphQLTest do
  # Ported from rust_nugitea's graphql tests. A schema over a real
  # accounts.json in a temp dir; no repos on disk, so only owner-side fields
  # are queried.
  use ExUnit.Case

  alias Nugitea.Accounts.Directory, as: D

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.fetch_env!(:nugitea, :state_dir)
    Application.put_env(:nugitea, :state_dir, tmp)
    on_exit(fn -> Application.put_env(:nugitea, :state_dir, previous) end)

    # These tests are about the schema's shape, so they see every repo; the
    # last one checks visibility under the default authorizer.
    Application.put_env(:nugitea, :authorizer, Nugitea.Auth.AllowAll)
    on_exit(fn -> Application.delete_env(:nugitea, :authorizer) end)

    :ok =
      Nugitea.Accounts.Store.update(tmp, fn d ->
        {:ok, d, _} = D.add_user(d, "alice")
        {:ok, d, _} = D.add_repo_at(d, "alice/dotfiles", :private)
        {:ok, d, _} = D.add_org_at(d, "acme", :public)
        {:ok, d, _} = D.add_org_at(d, "acme/platform", :public)
        {:ok, d, _} = D.add_repo_at(d, "acme/site", :public)
        {:ok, d, _} = D.add_repo_at(d, "acme/platform/api", :internal)
        {:ok, d}
      end)
  end

  defp run(query) do
    {:ok, result} = Absinthe.run(query, Nugitea.GraphQL.Schema)
    refute Map.has_key?(result, :errors), inspect(result[:errors])
    result.data
  end

  test "repository by owner and name" do
    v =
      run("""
      { repository(owner: "ACME/platform", name: "api") {
          name nameWithOwner resourcePath visibility isPrivate
          owner { __typename login ... on Organization { parentOrganization { login } } }
      } }
      """)

    assert v["repository"] == %{
             "name" => "api",
             "nameWithOwner" => "acme/platform/api",
             "resourcePath" => "/acme/platform/api",
             "visibility" => "INTERNAL",
             "isPrivate" => false,
             "owner" => %{
               "__typename" => "Organization",
               "login" => "acme/platform",
               "parentOrganization" => %{"login" => "acme"}
             }
           }

    assert run(~s|{ repository(owner: "acme", name: "api") { name } }|)["repository"] == nil
  end

  test "owners and connections" do
    v =
      run("""
      {
        user(login: "alice") { login repositories(first: 10) { totalCount nodes { name } } }
        notAnOrg: organization(login: "alice") { login }
        organization(login: "acme") {
          repositories { nodes { nameWithOwner } }
          subOrganizations { totalCount nodes { login } }
        }
        repositoryOwner(login: "acme/platform") { __typename resourcePath }
        repositories(first: 2) { totalCount nodes { nameWithOwner } }
      }
      """)

    assert v["user"]["repositories"] == %{"totalCount" => 1, "nodes" => [%{"name" => "dotfiles"}]}
    assert v["notAnOrg"] == nil
    assert v["organization"]["repositories"]["nodes"] == [%{"nameWithOwner" => "acme/site"}]
    assert v["organization"]["subOrganizations"]["nodes"] == [%{"login" => "acme/platform"}]

    assert v["repositoryOwner"] == %{
             "__typename" => "Organization",
             "resourcePath" => "/acme/platform"
           }

    assert v["repositories"]["totalCount"] == 3
    assert length(v["repositories"]["nodes"]) == 2
  end

  test "resource by url" do
    cases = [
      {"/acme", {"Organization", "/acme"}},
      {"https://example.com/acme/platform", {"Organization", "/acme/platform"}},
      {"/acme/platform/api", {"Repository", "/acme/platform/api"}},
      {"/acme/platform/api/tree/main/src?x=1", {"Repository", "/acme/platform/api"}},
      {"/Alice/dotfiles/blob/main/.vimrc", {"Repository", "/alice/dotfiles"}},
      {"/alice", {"User", "/alice"}},
      {"/acme/nope", nil},
      {"/", nil}
    ]

    for {url, want} <- cases do
      got = run(~s|{ resource(url: "#{url}") { __typename resourcePath } }|)["resource"]

      case want do
        {type, path} -> assert got == %{"__typename" => type, "resourcePath" => path}, url
        nil -> assert got == nil, url
      end
    end
  end

  # The schema is imported from priv/schema.graphql, a copy of the Nuxt
  # frontend's, so it can't drift from the copy, but the copy can drift
  # from the frontend.
  test "schema matches the frontend's" do
    frontend = Path.expand("../../../rust_nugitea/web/schema.graphql", __DIR__)

    if File.exists?(frontend) do
      assert File.read!(frontend) == File.read!(Path.expand("../../priv/schema.graphql", __DIR__))
    end
  end

  test "over HTTP, a JSON POST like the web frontend sends" do
    body =
      Jason.encode!(%{
        query: "query ($l: String!) { repositoryOwner(login: $l) { login } }",
        variables: %{l: "acme"}
      })

    conn =
      Plug.Test.conn(:post, "/graphql", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Nugitea.Router.call([])

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "data" => %{"repositoryOwner" => %{"login" => "acme"}}
           }
  end

  test "the default authorizer hides private and internal repos from anonymous callers" do
    Application.delete_env(:nugitea, :authorizer)

    v = run("{ repositories { nodes { nameWithOwner } } }")
    assert v["repositories"]["nodes"] == [%{"nameWithOwner" => "acme/site"}]
    assert run(~s|{ repository(owner: "alice", name: "dotfiles") { name } }|)["repository"] == nil
  end
end
