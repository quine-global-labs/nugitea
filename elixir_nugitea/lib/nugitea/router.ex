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

  get "/api/v1/user" do
    # For now, we'll use a basic implementation to return user information
    # In a full implementation with proper auth, this would check authentication
    # This would be set based on authentication
    user = nil

    {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

    if user != nil do
      # Find the user - in real implementation we would fetch by ID or slug
      case D.account(dir, user) do
        nil ->
          send_resp(conn, 401, "unauthorized")

        %{kind: :user, id: user_id, slug: user_slug} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{id: user_id, login: user_slug}))

        _ ->
          # Not a user account
          send_resp(conn, 401, "unauthorized")
      end
    else
      # Anonymous - return 401
      send_resp(conn, 401, "unauthorized")
    end
  end

  get "/api/v1/users/:username" do
    username = conn.params["username"]

    if username != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      # Find account by username (slug) using the resolve function for case-insensitive lookup
      account_id = D.resolve(dir, username)

      case D.account(dir, account_id) do
        nil ->
          send_resp(conn, 404, "not found")

        %{kind: :user, id: user_id, slug: user_slug} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{id: user_id, login: user_slug}))

        _ ->
          # If it's not a user (e.g., an org), return 404
          send_resp(conn, 404, "not found")
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/api/v1/users/:username/repos" do
    username = conn.params["username"]

    if username != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      # Find user account by username 
      account_id = D.resolve(dir, username)

      case D.account(dir, account_id) do
        nil ->
          send_resp(conn, 404, "not found")

        %{kind: :user, id: user_id} ->
          # Get repos owned by this user that the current caller can see
          # For anonymous access (no specific user), we treat as a user with ID:nil
          caller_id = Map.get(conn.assigns, :user_id, nil)

          # Get all repos owned by the user 
          user_repos = D.repos_owned_by(dir, user_id)

          # Filter repos based on visibility and access permissions
          accessible_repos =
            Enum.filter(user_repos, fn repo ->
              # Get effective role for the caller to determine if they can see this repo
              role = D.effective_role(dir, caller_id, repo.id)

              # If role is nil or if anonymous user doesn't have permission, then it's not accessible
              role != nil
            end)

          response_data =
            Enum.map(accessible_repos, fn repo ->
              %{
                id: repo.id,
                name: repo.slug,
                full_name: "#{username}/#{repo.slug}",
                description: Map.get(repo, :description, ""),
                empty: false,
                private: repo.visibility == :private,
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
                branch_count: 0,
                open_issues_count: length(dir.pull_requests[repo.id] || []),
                open_pr_counter: length(dir.pull_requests[repo.id] || []),
                release_counter: 0,
                default_branch: "main",
                created_at: DateTime.utc_now(),
                updated_at: DateTime.utc_now(),
                permissions: %{
                  # For now we'll set this conservatively
                  admin: false,
                  push: false,
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
                topics: repo.topics || [],
                licenses: []
              }
            end)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(response_data))

        _ ->
          # If it's not a user (e.g., an org), return 404
          send_resp(conn, 404, "not found")
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/api/v1/orgs/:org" do
    org_slug = conn.params["org"]

    if org_slug != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      # Find organization by slug
      account_id = D.resolve(dir, org_slug)

      case D.account(dir, account_id) do
        nil ->
          send_resp(conn, 404, "not found")

        %{kind: :org, id: org_id, slug: org_slug, visibility: visibility} ->
          # Create the response with only the required fields: id, name, and visibility
          response_data = %{
            id: org_id,
            name: org_slug,
            visibility: visibility
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(response_data))

        _ ->
          # If it's not an org account, return 404
          send_resp(conn, 404, "not found")
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/api/v1/orgs/:org/repos" do
    org_slug = conn.params["org"]

    if org_slug != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      # Find organization by slug
      account_id = D.resolve(dir, org_slug)

      case D.account(dir, account_id) do
        nil ->
          send_resp(conn, 404, "not found")

        %{kind: :org, id: org_id} ->
          # Get all repos for this organization that the current caller can see
          caller_id = Map.get(conn.assigns, :user_id, nil)

          # Get all repos in the directory (we will filter them based on organization)
          all_repos = D.repos(dir)

          # Filter repos by organization and visibility/access
          accessible_repos =
            Enum.filter(all_repos, fn repo ->
              # Check if the repo belongs to this org
              # Check if the caller can see it (effective role != nil means access)
              repo.owner == org_id &&
                D.effective_role(dir, caller_id, repo.id) != nil
            end)

          response_data =
            Enum.map(accessible_repos, fn repo ->
              %{
                id: repo.id,
                name: repo.slug,
                full_name: "#{org_slug}/#{repo.slug}",
                description: Map.get(repo, :description, ""),
                empty: false,
                private: repo.visibility == :private,
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
                branch_count: 0,
                open_issues_count: length(dir.pull_requests[repo.id] || []),
                open_pr_counter: length(dir.pull_requests[repo.id] || []),
                release_counter: 0,
                default_branch: "main",
                created_at: DateTime.utc_now(),
                updated_at: DateTime.utc_now(),
                permissions: %{
                  # For now we'll set this conservatively
                  admin: false,
                  push: false,
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
                topics: repo.topics || [],
                licenses: []
              }
            end)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(response_data))

        _ ->
          # If it's not an org account, return 404
          send_resp(conn, 404, "not found")
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/api/v1/orgs/:org/members" do
    org_slug = conn.params["org"]

    if org_slug != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      # Find organization by slug
      account_id = D.resolve(dir, org_slug)

      case D.account(dir, account_id) do
        nil ->
          send_resp(conn, 404, "not found")

        %{kind: :org, id: org_id} ->
          # Get all members of this organization
          members = Map.get(dir.org_members, org_id, %{})

          # Create response with id and login for each member
          response_data =
            Enum.map(members, fn {user_id, _role} ->
              case D.account(dir, user_id) do
                %{kind: :user, slug: user_slug} ->
                  %{id: user_id, login: user_slug}

                _ ->
                  # Skip non-user accounts
                  nil
              end
            end)
            |> Enum.reject(&is_nil/1)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(response_data))

        _ ->
          # If it's not an org account, return 404
          send_resp(conn, 404, "not found")
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/api/v1/orgs/:org/teams" do
    org_slug = conn.params["org"]

    if org_slug != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      # Find organization by slug
      account_id = D.resolve(dir, org_slug)

      case D.account(dir, account_id) do
        nil ->
          send_resp(conn, 404, "not found")

        %{kind: :org, id: org_id} ->
          # Get all teams for this organization
          teams =
            Enum.filter(Map.values(dir.teams), fn team -> team.org == org_id end)

          # Create response with id and name for each team
          response_data =
            Enum.map(teams, fn team ->
              %{id: team.id, name: team.slug}
            end)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(response_data))

        _ ->
          # If it's not an org account, return 404
          send_resp(conn, 404, "not found")
      end
    else
      send_resp(conn, 404, "not found")
    end
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
          user = conn.assigns.user_id

          # Determine effective role using Directory.effective_role/3
          role = Nugitea.Accounts.Directory.effective_role(dir, user, repo_id)

          # If role is nil (private repo the caller can't see), return 404
          case role do
            nil ->
              send_resp(conn, 404, "not found")

            _ ->
              # Map the role to permission level
              permission =
                case role do
                  :read -> "read"
                  :write -> "write"
                  :admin -> "admin"
                end

              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, Jason.encode!(%{permission: permission}))
          end
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
            user = conn.assigns.user_id

            # Determine effective role using Directory.effective_role/3
            role = Nugitea.Accounts.Directory.effective_role(dir, user, repo_id)

            # If role is nil (private repo the caller can't see), return 404
            if role == nil do
              send_resp(conn, 404, "not found")
            else
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

              # Determine if repository is empty (has no branches)
              empty = branch_count == 0

              # Get the repository size using Storage.size
              size =
                case Client.size(repo_path) do
                  {:ok, size_in_kib} ->
                    size_in_kib

                  {:error, _} ->
                    0
                end

              response_data = %{
                id: repo_id,
                name: repo_info.slug,
                full_name: "#{owner}/#{repo}",
                description: repo_info.description || "",
                empty: empty,
                private: repo_info.visibility == :private,
                fork: false,
                template: false,
                parent: nil,
                mirror: false,
                size: size,
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

  delete "/api/v1/repos/:owner/:repo" do
    owner = conn.params["owner"]
    repo = conn.params["repo"]

    if owner != nil and repo != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      case Client.resolve(dir, "#{owner}/#{repo}") do
        nil ->
          send_resp(conn, 404, "not found")

        repo_id ->
          # Check permissions - this is an admin operation only
          user = conn.assigns.user_id

          # Need to determine if the user has admin role in this repo
          case D.effective_role(dir, user, repo_id) do
            :admin ->
              # Proceed with deleting the repository 
              case Accounts.Store.update(
                     Accounts.state_dir(),
                     &D.delete_repo(&1, repo_id)
                   ) do
                {:ok, updated_dir} ->
                  # Now delete the actual git repository directory on disk
                  canonical_path = D.repo_path(updated_dir, repo_id)

                  case Client.delete(canonical_path) do
                    :ok ->
                      conn
                      |> put_resp_content_type("application/json")
                      |> send_resp(204, "")

                    {:error, _reason} ->
                      # If storage delete fails, we still return 204 but the repo may be in a partial state,
                      # which is acceptable as this behavior mirrors Gitea's implementation that doesn't 
                      # rollback on disk deletion failure  
                      conn
                      |> put_resp_content_type("application/json")
                      |> send_resp(204, "")
                  end

                {:error, reason} ->
                  conn
                  |> put_resp_content_type("application/json")
                  |> send_resp(
                    500,
                    Jason.encode!(%{
                      error: "Failed to delete repository from directory: #{reason}"
                    })
                  )
              end

            _ ->
              # User doesn't have admin access
              send_resp(conn, 403, "forbidden")
          end
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/api/v1/repos/:owner/:repo/git/commits/:sha.diff" do
    owner = conn.params["owner"]
    repo = conn.params["repo"]
    sha = conn.params["sha"]

    if owner != nil and repo != nil and sha != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      case Client.resolve(dir, "#{owner}/#{repo}") do
        nil ->
          send_resp(conn, 404, "not found")

        _ ->
          # Get repository path for storage access  
          repo_path = "#{owner}/#{repo}"

          case Client.commit_diff(repo_path, sha) do
            {:ok, diff} ->
              conn
              |> put_resp_content_type("text/plain")
              |> send_resp(200, diff)

            {:error, _} ->
              # If we couldn't get the diff (e.g., commit doesn't exist), return 404
              send_resp(conn, 404, "not found")
          end
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/api/v1/repos/:owner/:repo/git/commits/:sha.patch" do
    owner = conn.params["owner"]
    repo = conn.params["repo"]
    sha = conn.params["sha"]

    if owner != nil and repo != nil and sha != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      case Client.resolve(dir, "#{owner}/#{repo}") do
        nil ->
          send_resp(conn, 404, "not found")

        _ ->
          # Get repository path for storage access  
          repo_path = "#{owner}/#{repo}"

          case Client.commit_patch(repo_path, sha) do
            {:ok, patch} ->
              conn
              |> put_resp_content_type("text/plain")
              |> send_resp(200, patch)

            {:error, _} ->
              # If we couldn't get the patch (e.g., commit doesn't exist), return 404
              send_resp(conn, 404, "not found")
          end
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/api/v1/repos/:owner/:repo/compare/:basehead" do
    owner = conn.params["owner"]
    repo = conn.params["repo"]
    basehead = conn.params["basehead"]

    if owner != nil and repo != nil and basehead != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      case Client.resolve(dir, "#{owner}/#{repo}") do
        nil ->
          send_resp(conn, 404, "not found")

        _repo_id ->
          # Get repository path for storage access  
          repo_path = "#{owner}/#{repo}"

          # Parse basehead to separate base and head  
          [base, head] = String.split(basehead, "...", parts: 2)

          # Validate parts
          if base == "" or head == "" do
            send_resp(conn, 400, "Invalid basehead format")
          else
            # Get commits in the range (base..head)
            case Client.commits(repo_path, "#{base}..#{head}", []) do
              {:ok, commits} ->
                # Calculate total commit count
                total_commits = length(commits)

                # Get changed files from git diff --name-only 
                case Client.run_git(repo_path, ["diff", "--name-only", "#{base}...#{head}"]) do
                  :ok ->
                    # Since run_git returns command result in a different format than expected,
                    # let's use our own approach to get changed files
                    case System.cmd(
                           "git",
                           ["-C", repo_path, "diff", "--name-only", "#{base}...#{head}"],
                           stderr_to_stdout: false
                         ) do
                      {files, 0} ->
                        # Parse the file names into a proper response structure 
                        changed_files =
                          String.split(files, "\n", trim: true)
                          |> Enum.filter(fn f -> f != "" end)
                          |> Enum.map(&%{filename: &1, status: "modified"})

                        # Construct the response with commits, total count and files 
                        response_data = %{
                          commits: commits,
                          total_commits: total_commits,
                          files: changed_files
                        }

                        conn
                        |> put_resp_content_type("application/json")
                        |> send_resp(200, Jason.encode!(response_data))

                      _ ->
                        # If we failed to get file names 
                        send_resp(conn, 500, "Failed to retrieve changed files")
                    end

                  _ ->
                    # If git command for diff fails (e.g., invalid base/commit), return 404
                    send_resp(conn, 404, "not found")
                end

              {:error, _} ->
                # If we couldn't get commits, it's likely a repo or commit reference error
                send_resp(conn, 404, "not found")
            end
          end
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  # List all branches in a repository  
  get "/api/v1/repos/:owner/:repo/branches" do
    owner = conn.params["owner"]
    repo = conn.params["repo"]

    if owner != nil and repo != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      case Client.resolve(dir, "#{owner}/#{repo}") do
        nil ->
          send_resp(conn, 404, "not found")

        _repo_id ->
          # Get repository path for storage access  
          repo_path = "#{owner}/#{repo}"

          case Client.branch_tips(repo_path) do
            {:ok, tips} ->
              branches =
                for tip <- tips do
                  [refname, commit_hash, subject] = String.split(tip, " ", parts: 3)

                  # Extract just the branch name from refname (refs/heads/branch-name -> branch-name)
                  branch_name = String.replace_prefix(refname, "refs/heads/", "")

                  %{
                    name: branch_name,
                    commit: %{
                      id: commit_hash,
                      message: subject
                    }
                  }
                end

              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, Jason.encode!(branches))

            {:error, _} ->
              send_resp(conn, 404, "not found")
          end
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  # Get a specific branch from a repository  
  get "/api/v1/repos/:owner/:repo/branches/:branch" do
    owner = conn.params["owner"]
    repo = conn.params["repo"]
    branch_name = conn.params["branch"]

    if owner != nil and repo != nil and branch_name != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      case Client.resolve(dir, "#{owner}/#{repo}") do
        nil ->
          send_resp(conn, 404, "not found")

        _repo_id ->
          # Get repository path for storage access  
          repo_path = "#{owner}/#{repo}"

          case Client.branch(repo_path, branch_name) do
            {:ok, branch_data} ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, Jason.encode!(branch_data))

            {:error, :not_found} ->
              send_resp(conn, 404, "not found")

            {:error, _} ->
              send_resp(conn, 404, "not found")
          end
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/api/v1/repos/:owner/:repo/archive/*archive" do
    owner = conn.params["owner"]
    repo = conn.params["repo"]
    archive_path = conn.params["archive"]

    if owner != nil and repo != nil and archive_path != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      case Client.resolve(dir, "#{owner}/#{repo}") do
        nil ->
          send_resp(conn, 404, "not found")

        _ ->
          # Extract ref and format from archive path (e.g. "main.zip" or "v1.0.tar.gz")
          [ref, format] =
            archive_path
            |> String.split(".")
            |> Enum.take(-2)

          # Validate format
          case format do
            "zip" ->
              # Get repository path for storage access  
              repo_path = "#{owner}/#{repo}"

              case Client.archive(repo_path, ref, "zip") do
                {:ok, archive_data} ->
                  conn
                  |> put_resp_content_type("application/zip")
                  |> send_resp(200, archive_data)

                {:error, _} ->
                  send_resp(conn, 404, "not found")
              end

            "tar.gz" ->
              # Get repository path for storage access  
              repo_path = "#{owner}/#{repo}"

              case Client.archive(repo_path, ref, "tar") do
                {:ok, archive_data} ->
                  conn
                  |> put_resp_content_type("application/gzip")
                  |> send_resp(200, archive_data)

                {:error, _} ->
                  send_resp(conn, 404, "not found")
              end

            _ ->
              send_resp(conn, 404, "not found")
          end
      end
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/api/v1/repos/:owner/:repo/raw/*path" do
    owner = conn.params["owner"]
    repo = conn.params["repo"]
    path = conn.params["path"]
    ref = conn.query_params["ref"]

    if owner != nil and repo != nil and path != nil do
      {:ok, dir} = Accounts.Store.load(Accounts.state_dir())

      case Client.resolve(dir, "#{owner}/#{repo}") do
        nil ->
          send_resp(conn, 404, "not found")

        _ ->
          # Get repository path for storage access  
          repo_path = "#{owner}/#{repo}"

          # Determine reference - default to HEAD if not provided
          resolved_ref = if ref != nil and ref != "", do: ref, else: "HEAD"

          case Client.blob(repo_path, resolved_ref, path) do
            {:ok, %{content: content}} ->
              # Determine content type based on whether the content is valid UTF-8
              content_type =
                if String.valid?(content) and String.length(content) > 0,
                  do: "text/plain; charset=utf-8",
                  else: "application/octet-stream"

              conn
              |> put_resp_content_type(content_type)
              |> send_resp(200, content)

            {:error, _} ->
              send_resp(conn, 404, "not found")
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
