defmodule Nugitea.Router do
  @moduledoc """
  The app tier's HTTP side: `/graphql` for the web frontend, and git's
  smart-HTTP protocol for everything else, as Gitea's
  routers/web/repo/githttp.go serves it:

      GET  /<owner path>/<repo>.git/info/refs?service=git-upload-pack|git-receive-pack
      POST /<owner path>/<repo>.git/git-upload-pack
      POST /<owner path>/<repo>.git/git-receive-pack

  It runs no git itself: it resolves the repo against the accounts
  directory, asks `Nugitea.Auth`, and hands the exchange to the storage tier.
  """
  use Plug.Router

  import Plug.Conn

  alias Nugitea.Accounts
  alias Nugitea.Accounts.Directory, as: D
  alias Nugitea.Storage.Client

  plug :cors
  plug :match
  plug :dispatch

  get "/healthz" do
    send_resp(conn, 200, "ok")
  end

  get "/api/v1/version" do
    version = Application.spec(:nugitea, :vsn) |> to_string()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{version: version}))
  end

  forward "/graphql",
    to: Absinthe.Plug.GraphiQL,
    init_opts: [schema: Nugitea.GraphQL.Schema, interface: :simple, json_codec: Jason]

  get "/repos/:owner/:repo/permissions" do
    # Build repo path from params like the existing routes do
    owner = conn.params["owner"]
    repo = conn.params["repo"]

    if owner != nil and repo != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      case Client.resolve(dir, "#{owner}/#{repo}") do
        nil ->
          send_resp(conn, 404, "not found")

        repo_id ->
          # Get the current user (nil for anonymous)
          user = nil

          # Determine effective role using Directory.effective_role/3
          role = Nugitea.Accounts.Directory.effective_role(dir, user, repo_id)

          # Map the role to permission level
          permission =
            case role do
              :read -> "read"
              :write -> "write"
              :admin -> "admin"
              nil -> "none"
            end

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{permission: permission}))
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/repos/:owner/:repo" do
    owner = conn.params["owner"]
    repo = conn.params["repo"]

    if owner != nil and repo != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      case Client.resolve(dir, "#{owner}/#{repo}") do
        nil ->
          send_resp(conn, 404, "not found")

        repo_id ->
          # Get repository information from accounts directory
          repo_info = dir.repos[repo_id]

          if repo_info == nil do
            send_resp(conn, 404, "not found")
          else
            # Get the current user (nil for anonymous)
            user = nil

            # Determine effective role using Directory.effective_role/3
            role = Nugitea.Accounts.Directory.effective_role(dir, user, repo_id)

            # Get repository path for storage access
            repo_path = "#{owner}/#{repo}"

            # Get branch count using existing branches command
            branch_count =
              case Client.branches(repo_path) do
                {:ok, branches} ->
                  length(branches)

                {:error, _} ->
                  0
              end

            response_data = %{
              id: repo_id,
              name: repo_info.slug,
              full_name: "#{owner}/#{repo}",
              description: repo_info.description || "",
              empty: false,
              private: repo_info.visibility == :private,
              fork: false,
              template: false,
              parent: nil,
              mirror: false,
              size: 0,
              language: nil,
              languages_url: "",
              html_url: "",
              url: "",
              ssh_url: "",
              clone_url: "",
              original_url: "",
              website: "",
              stars_count: 0,
              forks_count: 0,
              watchers_count: 0,
              branch_count: branch_count,
              open_issues_count: length(dir.pull_requests[repo_id] || []),
              open_pr_counter: length(dir.pull_requests[repo_id] || []),
              release_counter: 0,
              default_branch: "main",
              created_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now(),
              permissions: %{
                admin: role == :admin,
                push: role == :admin || role == :write,
                pull: true
              },
              has_code: true,
              has_issues: false,
              internal_tracker: nil,
              external_tracker: nil,
              has_wiki: false,
              external_wiki: nil,
              has_pull_requests: true,
              has_projects: false,
              projects_mode: "repo",
              has_releases: false,
              has_packages: false,
              has_actions: false,
              ignore_whitespace_conflicts: false,
              allow_merge_commits: true,
              allow_rebase: true,
              allow_rebase_explicit: true,
              allow_squash_merge: true,
              allow_fast_forward_only_merge: false,
              allow_merge_update: false,
              allow_rebase_update: false,
              allow_manual_merge: true,
              autodetect_manual_merge: false,
              default_delete_branch_after_merge: false,
              default_merge_style: "merge",
              default_update_style: "merge",
              default_allow_maintainer_edit: false,
              avatar_url: "",
              internal: false,
              mirror_interval: "",
              object_format_name: "sha1",
              mirror_updated: DateTime.utc_now(),
              mirror_last_sync_at: DateTime.utc_now(),
              topics: repo_info.topics || [],
              licenses: []
            }

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(response_data))
          end
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/repos/:owner/:repo/topics" do
    owner = conn.params["owner"]
    repo = conn.params["repo"]

    if owner != nil and repo != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      case Client.resolve(dir, "#{owner}/#{repo}") do
        nil ->
          send_resp(conn, 404, "not found")

        repo_id ->
          # Get repository information from accounts directory
          repo_info = dir.repos[repo_id]

          if repo_info == nil do
            send_resp(conn, 404, "not found")
          else
            # Return the topics as a JSON array of strings
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(repo_info.topics))
          end
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  post "/repos/:owner/:repo/pulls" do
    owner = conn.params["owner"]
    repo = conn.params["repo"]

    if owner != nil and repo != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      case Client.resolve(dir, "#{owner}/#{repo}") do
        nil ->
          send_resp(conn, 404, "not found")

        repo_id ->
          # Parse request body for PR data
          case Plug.Conn.read_body(conn) do
            {:ok, body, _conn} ->
              case Jason.decode(body) do
                {:ok, params} ->
                  # Extract required fields from the JSON parameters
                  title = Map.get(params, "title")
                  description = Map.get(params, "description")
                  head = Map.get(params, "head")
                  base = Map.get(params, "base")
                  # Would come from authentication system in real implementation
                  author = nil

                  # Validate required fields
                  if title == nil or head == nil or base == nil do
                    conn
                    |> put_resp_content_type("application/json")
                    |> send_resp(
                      400,
                      Jason.encode!(%{error: "Missing required fields: title, head, and base"})
                    )
                  else
                    # Create the pull request
                    case Accounts.Store.update(
                           Accounts.state_dir(),
                           &D.create_pull_request(
                             &1,
                             repo_id,
                             title,
                             description || "",
                             head,
                             base,
                             author
                           )
                         ) do
                      {:ok, _} ->
                        response = %{
                          id: "pr-#{DateTime.utc_now() |> DateTime.to_unix()}",
                          title: title,
                          description: description,
                          head: %{ref: head},
                          base: %{ref: base},
                          user: %{login: "anonymous"},
                          state: "open",
                          created_at: DateTime.to_iso8601(DateTime.utc_now())
                        }

                        conn
                        |> put_resp_content_type("application/json")
                        |> send_resp(201, Jason.encode!(response))

                      {:error, reason} ->
                        conn
                        |> put_resp_content_type("application/json")
                        |> send_resp(
                          500,
                          Jason.encode!(%{error: "Failed to create pull request: #{reason}"})
                        )
                    end
                  end

                {:error, _reason} ->
                  conn
                  |> put_resp_content_type("application/json")
                  |> send_resp(400, Jason.encode!(%{error: "Invalid JSON in request body"}))
              end

            {:error, reason} ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(500, Jason.encode!(%{error: "Failed to read request body: #{reason}"}))
          end
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  patch "/repos/:owner/:repo" do
    owner = conn.params["owner"]
    repo = conn.params["repo"]

    if owner != nil and repo != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      case Client.resolve(dir, "#{owner}/#{repo}") do
        nil ->
          send_resp(conn, 404, "not found")

        repo_id ->
          # Parse request body for update data
          case Plug.Conn.read_body(conn) do
            {:ok, body, _conn} ->
              case Jason.decode(body) do
                {:ok, params} ->
                  # Extract fields to be updated
                  description = Map.get(params, "description")
                  website = Map.get(params, "website")
                  private = Map.get(params, "private")

                  # Determine visibility based on the private flag
                  visibility =
                    if private != nil do
                      if private, do: :private, else: :public
                    else
                      nil
                    end

                  # Update repository properties in the directory
                  case Accounts.Store.update(
                         Accounts.state_dir(),
                         &D.update_repo(&1, repo_id, description, visibility, website)
                       ) do
                    {:ok, updated_dir} ->
                      # Get the updated repository information
                      repo_info = updated_dir.repos[repo_id]

                      # Return success with updated repository data
                      response_data = %{
                        id: repo_id,
                        name: repo_info.slug,
                        full_name: "#{owner}/#{repo}",
                        description: repo_info.description || "",
                        empty: false,
                        private: repo_info.visibility == :private,
                        fork: false,
                        template: false,
                        parent: nil,
                        mirror: false,
                        size: 0,
                        language: nil,
                        languages_url: "",
                        html_url: "",
                        url: "",
                        ssh_url: "",
                        clone_url: "",
                        original_url: "",
                        website: repo_info.website || "",
                        stars_count: 0,
                        forks_count: 0,
                        watchers_count: 0,
                        # Default, would need to be computed
                        branch_count: 0,
                        open_issues_count: length(updated_dir.pull_requests[repo_id] || []),
                        open_pr_counter: length(updated_dir.pull_requests[repo_id] || []),
                        release_counter: 0,
                        default_branch: "main",
                        created_at: DateTime.utc_now(),
                        updated_at: DateTime.utc_now(),
                        permissions: %{
                          admin: true,
                          push: true,
                          pull: true
                        },
                        has_code: true,
                        has_issues: false,
                        internal_tracker: nil,
                        external_tracker: nil,
                        has_wiki: false,
                        external_wiki: nil,
                        has_pull_requests: true,
                        has_projects: false,
                        projects_mode: "repo",
                        has_releases: false,
                        has_packages: false,
                        has_actions: false,
                        ignore_whitespace_conflicts: false,
                        allow_merge_commits: true,
                        allow_rebase: true,
                        allow_rebase_explicit: true,
                        allow_squash_merge: true,
                        allow_fast_forward_only_merge: false,
                        allow_merge_update: false,
                        allow_rebase_update: false,
                        allow_manual_merge: true,
                        autodetect_manual_merge: false,
                        default_delete_branch_after_merge: false,
                        default_merge_style: "merge",
                        default_update_style: "merge",
                        default_allow_maintainer_edit: false,
                        avatar_url: "",
                        internal: false,
                        mirror_interval: "",
                        object_format_name: "sha1",
                        mirror_updated: DateTime.utc_now(),
                        mirror_last_sync_at: DateTime.utc_now(),
                        topics: repo_info.topics || [],
                        licenses: []
                      }

                      conn
                      |> put_resp_content_type("application/json")
                      |> send_resp(200, Jason.encode!(response_data))

                    {:error, reason} ->
                      conn
                      |> put_resp_content_type("application/json")
                      |> send_resp(
                        500,
                        Jason.encode!(%{error: "Failed to update repository: #{reason}"})
                      )
                  end

                {:error, _reason} ->
                  conn
                  |> put_resp_content_type("application/json")
                  |> send_resp(400, Jason.encode!(%{error: "Invalid JSON in request body"}))
              end

            {:error, reason} ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(500, Jason.encode!(%{error: "Failed to read request body: #{reason}"}))
          end
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/*glob" do
    conn = fetch_query_params(conn)

    with {:ok, repo_git} <- strip_suffix(glob, "info/refs"),
         {:ok, service} <- service(conn.query_params["service"]),
         {:ok, repo} <- resolve(repo_git),
         :ok <- allow(service, repo) do
      case Client.info_refs(repo, service, List.first(get_req_header(conn, "git-protocol"))) do
        {:ok, body} ->
          conn
          |> put_resp_content_type("application/x-git-#{service}-advertisement", nil)
          |> put_resp_header("cache-control", "no-cache")
          |> send_resp(200, body)
      end
    else
      {:error, status, msg} -> send_resp(conn, status, msg)
    end
  end

  post "/*glob" do
    with {:ok, repo_git, service} <- rpc_path(glob),
         {:ok, repo} <- resolve(repo_git),
         :ok <- allow(service, repo) do
      rpc(conn, repo, service)
    else
      {:error, status, msg} -> send_resp(conn, status, msg)
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

  defp allow(service, repo),
    do: if(Nugitea.Auth.allow?(service, repo), do: :ok, else: {:error, 403, "forbidden"})

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
end
