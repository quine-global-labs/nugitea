defmodule Nugitea.SessionTest do
  # Web sign-in: passwords, sessions, the /-/session routes, and GraphQL
  # answering as the signed-in user.
  use ExUnit.Case, async: false

  alias Nugitea.Accounts.Directory, as: D
  alias Nugitea.Accounts.{JsonFile, Passwords, Sessions}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.fetch_env!(:nugitea, :state_dir)
    Application.put_env(:nugitea, :state_dir, tmp)
    on_exit(fn -> Application.put_env(:nugitea, :state_dir, previous) end)

    :ok =
      Nugitea.Accounts.Store.update(tmp, fn d ->
        {:ok, d, _} = D.add_user(d, "alice")
        {:ok, d, _} = D.add_user(d, "bob")
        {:ok, d, _} = D.add_org_at(d, "acme", :public)
        {:ok, d, _} = D.add_repo_at(d, "alice/secret", :private)
        {:ok, d}
      end)

    {:ok, dir} = Nugitea.Accounts.Store.load(tmp)
    :ok = Passwords.set(tmp, D.resolve(dir, "alice"), "correct horse")
    %{dir: dir}
  end

  defp sign_in(login, password) do
    Plug.Test.conn(:post, "/-/session", Jason.encode!(%{login: login, password: password}))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Nugitea.Router.call([])
  end

  defp session_cookie(conn), do: conn.resp_cookies["nugitea_session"]

  defp graphql(cookie) do
    query = ~s|{ viewer { login } repository(owner: "alice", name: "secret") { name } }|

    conn =
      Plug.Test.conn(:post, "/graphql", Jason.encode!(%{query: query}))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = if cookie, do: Plug.Test.put_req_cookie(conn, "nugitea_session", cookie), else: conn
    Jason.decode!(Nugitea.Router.call(conn, []).resp_body)["data"]
  end

  test "signing in with the right password sets an HttpOnly, SameSite=Lax session cookie" do
    conn = sign_in("alice", "correct horse")

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"login" => "alice"}
    cookie = session_cookie(conn)
    assert cookie.http_only
    assert cookie.same_site == "Lax"
    assert cookie.max_age == Sessions.ttl()
    refute cookie[:secure]
  end

  test "the cookie is Secure when the browser used HTTPS (behind nginx)" do
    conn =
      Plug.Test.conn(
        :post,
        "/-/session",
        Jason.encode!(%{login: "alice", password: "correct horse"})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> Nugitea.Router.call([])

    assert session_cookie(conn).secure
  end

  test "a wrong password, an unknown login, an org or an account without a password are all 401" do
    for {login, password} <- [
          {"alice", "wrong"},
          {"nobody", "correct horse"},
          {"acme", "correct horse"},
          {"bob", "correct horse"}
        ] do
      conn = sign_in(login, password)
      assert conn.status == 401, login
      assert Jason.decode!(conn.resp_body) == %{"message" => "wrong login or password"}
      assert session_cookie(conn) == nil
    end
  end

  test "GraphQL answers as the signed-in user: the viewer, and repos only they can see" do
    assert graphql(nil) == %{"viewer" => nil, "repository" => nil}

    cookie = session_cookie(sign_in("alice", "correct horse")).value

    assert graphql(cookie) == %{
             "viewer" => %{"login" => "alice"},
             "repository" => %{"name" => "secret"}
           }
  end

  test "signing out ends the session, and the cookie stops working", %{tmp_dir: tmp} do
    cookie = session_cookie(sign_in("alice", "correct horse")).value

    conn =
      Plug.Test.conn(:delete, "/-/session")
      |> Plug.Test.put_req_cookie("nugitea_session", cookie)
      |> Nugitea.Router.call([])

    assert conn.status == 204
    assert session_cookie(conn).max_age == 0
    assert Sessions.lookup(tmp, cookie) == nil
    assert graphql(cookie)["viewer"] == nil
  end

  test "an unknown or garbled cookie is anonymous, not an error" do
    assert graphql("not-a-session") == %{"viewer" => nil, "repository" => nil}
  end

  test "sessions expire, and only their hashes are stored", %{tmp_dir: tmp, dir: dir} do
    alice = D.resolve(dir, "alice")
    token = Sessions.create(tmp, alice)
    assert Sessions.lookup(tmp, token) == alice
    refute File.read!(Path.join(tmp, "sessions.json")) =~ token

    JsonFile.update(tmp, "sessions.json", fn s ->
      Map.new(s, fn {k, v} -> {k, %{v | "expires" => 0}} end)
    end)

    assert Sessions.lookup(tmp, token) == nil
  end

  test "passwords are stored salted and hashed, and checked", %{tmp_dir: tmp, dir: dir} do
    alice = D.resolve(dir, "alice")
    stored = File.read!(Path.join(tmp, "passwords.json"))
    assert stored =~ "pbkdf2-sha256$600000$"
    refute stored =~ "correct horse"
    assert Passwords.verify(tmp, alice, "correct horse")
    refute Passwords.verify(tmp, alice, "Correct horse")
    refute Passwords.verify(tmp, nil, "correct horse")
  end
end
