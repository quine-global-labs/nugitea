defmodule Nugitea.Router do
  @moduledoc """
  The app tier's HTTP side: git's smart-HTTP protocol (what `git clone
  http://...` speaks), plus a repo-creation endpoint and a bare index page.
  It runs no git itself; everything goes through `Nugitea.Storage.Client`.

  Smart HTTP, as Gitea's routers/web/repo/githttp.go serves it:
    GET  /<repo>.git/info/refs?service=git-upload-pack|git-receive-pack
    POST /<repo>.git/git-upload-pack
    POST /<repo>.git/git-receive-pack
  """
  use Plug.Router

  alias Nugitea.Storage
  alias Nugitea.Storage.Client

  plug :match
  plug :dispatch

  get "/" do
    items =
      Enum.map_join(Client.list(), fn repo ->
        url = Plug.HTML.html_escape("#{base_url(conn)}/#{repo}.git")
        "<li><code>git clone #{url}</code></li>"
      end)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, "<!doctype html><title>nugitea</title><h1>nugitea</h1><ul>#{items}</ul>")
  end

  # curl -d path=owner/name http://host:3080/api/repos
  post "/api/repos" do
    {:ok, body, conn} = read_body(conn)

    case Client.create(URI.decode_query(body)["path"] || "") do
      :ok -> send_resp(conn, 201, "created\n")
      {:error, :exists} -> send_resp(conn, 409, "already exists\n")
      {:error, :bad_path} -> send_resp(conn, 400, "bad repo path\n")
    end
  end

  get "/*glob" do
    conn = fetch_query_params(conn)
    service = conn.query_params["service"]

    with {:ok, repo, ["info", "refs"]} <- split_repo(glob),
         true <- service in Storage.services(),
         {:ok, refs} <- Client.advertise_refs(repo, service) do
      conn
      |> put_resp_content_type("application/x-#{service}-advertisement", nil)
      |> put_resp_header("cache-control", "no-cache")
      |> send_resp(200, [pkt_line("# service=#{service}\n"), "0000", refs])
    else
      _ -> send_resp(conn, 404, "not found\n")
    end
  end

  post "/*glob" do
    with {:ok, repo, [service]} <- split_repo(glob),
         true <- service in Storage.services(),
         true <- Client.exists?(repo) do
      rpc(conn, repo, service)
    else
      _ -> send_resp(conn, 404, "not found\n")
    end
  end

  defp rpc(conn, repo, service) do
    exchange = Client.start_serve(repo, service)
    # Clients gzip big upload-pack requests.
    gzipped? = get_req_header(conn, "content-encoding") == ["gzip"]
    conn = stream_body(conn, exchange, gzipped? && inflater())

    conn =
      conn
      |> put_resp_content_type("application/x-#{service}-result", nil)
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    Enum.reduce_while(Client.response(exchange), conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  defp stream_body(conn, exchange, inflater) do
    {status, data, conn} = read_body(conn, length: 1_000_000)
    data = if inflater, do: IO.iodata_to_binary(:zlib.inflate(inflater, data)), else: data
    if data != "", do: Client.send_body(exchange, data)

    case status do
      :more ->
        stream_body(conn, exchange, inflater)

      :ok ->
        if inflater, do: :zlib.close(inflater)
        conn
    end
  end

  defp inflater do
    z = :zlib.open()
    # 31 = gzip header + max window
    :ok = :zlib.inflateInit(z, 31)
    z
  end

  # ["org", "team", "app.git", "info", "refs"] -> {:ok, "org/team/app", ["info", "refs"]}
  defp split_repo(glob) do
    case Enum.find_index(glob, &String.ends_with?(&1, ".git")) do
      nil ->
        :error

      i ->
        {repo, [last | rest]} = Enum.split(glob, i)
        {:ok, Enum.join(repo ++ [String.trim_trailing(last, ".git")], "/"), rest}
    end
  end

  defp pkt_line(data) do
    size = byte_size(data) + 4

    String.pad_leading(Integer.to_string(size, 16), 4, "0")
    |> String.downcase()
    |> Kernel.<>(data)
  end

  defp base_url(conn), do: "#{conn.scheme}://#{conn.host}:#{conn.port}"
end
