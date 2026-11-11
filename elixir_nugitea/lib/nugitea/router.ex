defmodule Nugitea.Router do
  @moduledoc """
  The app tier's HTTP side:

    * `/api/v1`: the REST API, `Nugitea.API`;
    * `/graphql`: for the web frontend;
    * git's smart-HTTP protocol for everything else, as Gitea's
      routers/web/repo/githttp.go serves it:

          GET  /<owner path>/<repo>.git/info/refs?service=git-upload-pack|git-receive-pack
          POST /<owner path>/<repo>.git/git-upload-pack
          POST /<owner path>/<repo>.git/git-receive-pack

  Every request is authenticated here first (`authenticate/2`). It runs no
  git itself: it resolves the repo against the accounts directory, asks
  `Nugitea.Auth`, and hands the exchange to the storage tier.
  """
  use Plug.Router

  import Plug.Conn

  alias Nugitea.Accounts
  alias Nugitea.Accounts.Tokens
  alias Nugitea.Storage.Client

  plug :cors
  plug :fetch_query_params
  plug :parse_graphql_body
  plug :authenticate
  plug :match
  plug :dispatch

  get "/healthz" do
    send_resp(conn, 200, "ok")
  end

  forward "/api/v1", to: Nugitea.API

  forward "/graphql",
    to: Absinthe.Plug.GraphiQL,
    init_opts: [schema: Nugitea.GraphQL.Schema, interface: :simple, json_codec: Jason]

  get "/*glob" do
    conn = fetch_query_params(conn)

    with {:ok, repo_git} <- strip_suffix(glob, "info/refs"),
         {:ok, service} <- service(conn.query_params["service"]),
         {:ok, repo} <- resolve(repo_git),
         :ok <- allow(service, conn.assigns.user_id, repo) do
      case Client.info_refs(repo, service, List.first(get_req_header(conn, "git-protocol"))) do
        {:ok, body} ->
          conn
          |> put_resp_content_type("application/x-git-#{service}-advertisement", nil)
          |> put_resp_header("cache-control", "no-cache")
          |> send_resp(200, body)
      end
    else
      {:error, status, msg} -> git_error(conn, status, msg)
    end
  end

  post "/*glob" do
    with {:ok, repo_git, service} <- rpc_path(glob),
         {:ok, repo} <- resolve(repo_git),
         :ok <- allow(service, conn.assigns.user_id, repo) do
      rpc(conn, repo, service)
    else
      {:error, status, msg} -> git_error(conn, status, msg)
    end
  end

  defp rpc(conn, repo, service) do
    exchange =
      Client.start_exchange(repo, service,
        stateless: true,
        protocol: List.first(get_req_header(conn, "git-protocol")),
        gzip: get_req_header(conn, "content-encoding") == ["gzip"]
      )

    conn = stream_request(conn, exchange)

    conn =
      conn
      |> put_resp_content_type("application/x-git-#{service}-result", nil)
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    Enum.reduce_while(Client.output(exchange), conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  defp stream_request(conn, exchange) do
    {status, data, conn} = read_body(conn, length: 1_000_000)
    if data != "", do: Client.input(exchange, data)
    if status == :more, do: stream_request(conn, exchange), else: conn
  end

  defp strip_suffix(glob, suffix) do
    case Enum.split(glob, -length(String.split(suffix, "/"))) do
      {repo, tail} when repo != [] ->
        if(Enum.join(tail, "/") == suffix, do: {:ok, Enum.join(repo, "/")}, else: not_found())

      _ ->
        not_found()
    end
  end

  defp rpc_path(glob) do
    case Enum.split(glob, -1) do
      {repo, ["git-" <> service]} when repo != [] ->
        with {:ok, service} <- service("git-" <> service),
             do: {:ok, Enum.join(repo, "/"), service}

      _ ->
        not_found()
    end
  end

  defp service("git-upload-pack"), do: {:ok, "upload-pack"}
  defp service("git-receive-pack"), do: {:ok, "receive-pack"}

  defp service(_),
    do: {:error, 400, "smart HTTP only: service must be git-upload-pack or git-receive-pack"}

  defp resolve(repo_git) do
    {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

    case Client.resolve(dir, repo_git) do
      nil -> not_found()
      repo -> {:ok, repo}
    end
  end

  # Denied and anonymous is 401, so git asks for credentials and retries;
  # denied with credentials is 403.
  defp allow(service, user, repo) do
    cond do
      Nugitea.Auth.allow?(service, user, repo) -> :ok
      user == nil -> {:error, 401, "authentication required"}
      true -> {:error, 403, "forbidden"}
    end
  end

  defp git_error(conn, 401, msg) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="nugitea"))
    |> send_resp(401, msg)
  end

  defp git_error(conn, status, msg), do: send_resp(conn, status, msg)

  # Who's calling, as Gitea accepts it: `Authorization: token T`, `Bearer T`,
  # or basic auth with the token as the password. No header is anonymous
  # (nil); a token we don't know is 401, with a challenge so git asks again.
  defp authenticate(conn, _opts) do
    with [header | _] <- get_req_header(conn, "authorization"),
         token when token != nil <- bearer_token(header),
         user when user != nil <- Tokens.lookup_token(Accounts.state_dir(), token) do
      assign(conn, :user_id, user)
    else
      [] ->
        assign(conn, :user_id, nil)

      nil ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="nugitea"))
        |> send_resp(401, "unauthorized")
        |> halt()
    end
  end

  defp bearer_token("token " <> token), do: token
  defp bearer_token("Bearer " <> token), do: token

  defp bearer_token("Basic " <> encoded) do
    with {:ok, credentials} <- Base.decode64(encoded),
         [_user, token] <- String.split(credentials, ":", parts: 2) do
      token
    else
      _ -> nil
    end
  end

  defp bearer_token(_), do: nil

  defp not_found, do: {:error, 404, "not found"}

  # The Nuxt frontend calls /graphql from its own origin; like
  # rust_nugitea's CorsLayer::permissive, allow anything.
  defp cors(%{request_path: "/graphql"} = conn, _opts) do
    conn =
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-methods", "*")
      |> put_resp_header("access-control-allow-headers", "*")

    if conn.method == "OPTIONS", do: conn |> send_resp(200, "") |> halt(), else: conn
  end

  defp cors(conn, _opts), do: conn

  # Absinthe reads the query from parsed body params, and clients (the Nuxt
  # frontend included) POST `{"query": ..., "variables": ...}` as JSON.
  # Only for /graphql: the git routes stream their bodies, and the API
  # routes read theirs themselves.
  @graphql_parsers Plug.Parsers.init(
                     parsers: [:json, Absinthe.Plug.Parser],
                     pass: ["*/*"],
                     json_decoder: Jason
                   )

  defp parse_graphql_body(%{request_path: "/graphql"} = conn, _opts),
    do: Plug.Parsers.call(conn, @graphql_parsers)

  defp parse_graphql_body(conn, _opts), do: conn
end
