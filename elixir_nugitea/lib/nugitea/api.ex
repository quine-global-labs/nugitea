defmodule Nugitea.API do
  @moduledoc """
  The REST API, mounted at /api/v1 by `Nugitea.Router`, in the shape of
  Gitea's (JSON field names from its modules/structs, a subset of them).
  The router has already authenticated the caller: `conn.assigns.user_id`
  is their user id, or nil.

  Each route is a `with` chain that ends in `{status, body}` and fails with
  `{:error, status, message}`; `reply/2` sends either, errors as Gitea's
  `{"message": ...}`. A repo the caller can't see is 404, not 403, so a
  private repo's existence doesn't leak.
  """
  use Plug.Router

  import Plug.Conn

  alias Nugitea.Accounts
  alias Nugitea.Accounts.Directory, as: D
  alias Nugitea.Storage.Client

  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
  plug :match
  plug :dispatch

  # ---- server and users -------------------------------------------------

  get "/version" do
    reply({200, %{version: to_string(Application.spec(:nugitea, :vsn))}}, conn)
  end

  get "/user" do
    with {:ok, user} <- signed_in(conn) do
      {200, user_json(D.account(dir(), user))}
    end
    |> reply(conn)
  end

  get "/user/blocks" do
    with {:ok, user} <- signed_in(conn) do
      dir = dir()
      {200, for({^user, blocked} <- dir.blocks, do: user_json(D.account(dir, blocked)))}
    end
    |> reply(conn)
  end

  put "/user/blocks/:username" do
    with {:ok, user} <- signed_in(conn),
         {:ok, target} <- account(dir(), username, :user),
         {:ok, _} <- change(&D.block(&1, user, target.id)) do
      {204, nil}
    end
    |> reply(conn)
  end

  delete "/user/blocks/:username" do
    with {:ok, user} <- signed_in(conn),
         {:ok, target} <- account(dir(), username, :user),
         {:ok, _} <- change(&{:ok, D.unblock(&1, user, target.id)}) do
      {204, nil}
    end
    |> reply(conn)
  end

  get "/users/:username" do
    with {:ok, user} <- account(dir(), username, :user) do
      {200, user_json(user)}
    end
    |> reply(conn)
  end

  get "/users/:username/repos" do
    dir = dir()

    with {:ok, user} <- account(dir, username, :user) do
      {200, repos_json(dir, visible(conn, dir, D.repos_owned_by(dir, user.id)))}
    end
    |> reply(conn)
  end

  # There are no stars yet. As Gitea shows only you your own, this shows
  # you every repo you can see, and is 404 for anyone else's.
  get "/users/:username/starred" do
    dir = dir()

    with {:ok, user} <- account(dir, username, :user),
         :ok <- if(user_id(conn) in [nil, user.id], do: :ok, else: not_found()) do
      {200, repos_json(dir, visible(conn, dir, D.repos(dir)))}
    end
    |> reply(conn)
  end

  # ---- orgs and teams -----------------------------------------------------

  get "/orgs/:org" do
    with {:ok, org} <- account(dir(), org, :org) do
      {200, %{id: org.id, name: org.slug, visibility: org.visibility}}
    end
    |> reply(conn)
  end

  get "/orgs/:org/repos" do
    dir = dir()

    with {:ok, org} <- account(dir, org, :org) do
      {200, repos_json(dir, visible(conn, dir, D.repos_owned_by(dir, org.id)))}
    end
    |> reply(conn)
  end

  get "/orgs/:org/members" do
    dir = dir()

    with {:ok, org} <- account(dir, org, :org) do
      {200, users_json(dir, Map.keys(Map.get(dir.org_members, org.id, %{})))}
    end
    |> reply(conn)
  end

  get "/orgs/:org/teams" do
    dir = dir()

    with {:ok, org} <- account(dir, org, :org) do
      teams = for t <- Map.values(dir.teams), t.org == org.id, do: %{id: t.id, name: t.slug}
      {200, Enum.sort_by(teams, & &1.name)}
    end
    |> reply(conn)
  end

  get "/teams/:id" do
    dir = dir()

    with {:ok, team} <- team(conn, dir, id) do
      org = D.account(dir, team.org)

      {200,
       %{
         id: team.id,
         name: team.slug,
         description: "",
         organization: %{id: org.id, name: org.slug},
         permission: "read",
         includes_all_repositories: false,
         can_create_org_repo: false
       }}
    end
    |> reply(conn)
  end

  get "/teams/:id/members" do
    dir = dir()

    with {:ok, team} <- team(conn, dir, id) do
      {200, users_json(dir, Map.keys(team.members))}
    end
    |> reply(conn)
  end

  put "/teams/:id/members/:username" do
    set_team_member(conn, id, username, :member)
  end

  delete "/teams/:id/members/:username" do
    set_team_member(conn, id, username, nil)
  end

  # ---- repos --------------------------------------------------------------

  get "/repos/search" do
    dir = dir()
    params = conn.query_params
    q = String.downcase(params["q"] || "")
    limit = params |> int("limit", 30) |> min(50) |> max(1)
    page = params |> int("page", 1) |> max(1)

    # `uid`: repos that user owns (`exclusive`) or can see.
    owned? =
      case {int(params, "uid", nil), params["exclusive"] == "true"} do
        {nil, _} -> fn _ -> true end
        {uid, true} -> &(&1.data.owner == uid)
        {uid, false} -> &(D.effective_role(dir, uid, &1.id) != nil)
      end

    matches? = fn %{data: r} ->
      fields =
        cond do
          params["topic"] == "true" -> r.topics
          params["includeDesc"] == "true" -> [r.slug, r.description]
          true -> [r.slug]
        end

      q == "" or Enum.any?(fields, &String.contains?(String.downcase(&1), q))
    end

    found =
      visible(conn, dir, D.repos(dir))
      |> Enum.filter(&(matches?.(&1) and owned?.(&1)))
      |> Enum.sort_by(& &1.data.slug, if(params["order"] == "desc", do: :desc, else: :asc))
      |> Enum.slice((page - 1) * limit, limit)

    reply({200, %{ok: true, data: Enum.map(found, &repo_json(dir, &1))}}, conn)
  end

  get "/repos/:owner/:repo" do
    dir = dir()

    with {:ok, r} <- repo(conn, dir, owner, repo) do
      {200, repo_json(dir, r, git_details(r))}
    end
    |> reply(conn)
  end

  patch "/repos/:owner/:repo" do
    p = conn.body_params
    visibility = if is_boolean(p["private"]), do: if(p["private"], do: :private, else: :public)

    with {:ok, r} <- repo(conn, dir(), owner, repo),
         :ok <- require_role(r, :admin),
         {:ok, dir} <-
           change(&D.update_repo(&1, r.id, p["description"], visibility, p["website"])),
         {:ok, r} <- repo(conn, dir, owner, repo) do
      {200, repo_json(dir, r, git_details(r))}
    end
    |> reply(conn)
  end

  delete "/repos/:owner/:repo" do
    with {:ok, r} <- repo(conn, dir(), owner, repo),
         :ok <- require_role(r, :admin),
         {:ok, _} <- change(&D.delete_repo(&1, r.id)) do
      # As Gitea, the repo is gone once the directory forgets it, even if
      # removing its git data fails.
      Client.delete(r.path)
      {204, nil}
    end
    |> reply(conn)
  end

  get "/repos/:owner/:repo/permissions" do
    with {:ok, r} <- repo(conn, dir(), owner, repo) do
      permission =
        case r.role do
          role when role in [:read, :triage] -> "read"
          role when role in [:write, :maintain] -> "write"
          :admin -> "admin"
        end

      {200, %{permission: permission}}
    end
    |> reply(conn)
  end

  get "/repos/:owner/:repo/topics" do
    with {:ok, r} <- repo(conn, dir(), owner, repo) do
      {200, r.data.topics}
    end
    |> reply(conn)
  end

  put "/repos/:owner/:repo/topics" do
    # `{"topics": [...]}` as Gitea takes it, or a bare array.
    topics = conn.body_params["topics"] || conn.body_params["_json"]

    with {:ok, r} <- repo(conn, dir(), owner, repo),
         :ok <- require_role(r, :admin),
         :ok <-
           valid(is_list(topics) and Enum.all?(topics, &is_binary/1), "topics must be strings"),
         {:ok, _} <- change(&D.set_repo_topics(&1, r.id, topics)) do
      {200, %{topics: topics}}
    end
    |> reply(conn)
  end

  delete "/repos/:owner/:repo/topics" do
    with {:ok, r} <- repo(conn, dir(), owner, repo),
         :ok <- require_role(r, :admin),
         {:ok, _} <- change(&D.set_repo_topics(&1, r.id, [])) do
      {204, nil}
    end
    |> reply(conn)
  end

  post "/repos/:owner/:repo/mirror-sync" do
    with {:ok, r} <- repo(conn, dir(), owner, repo),
         :ok <- require_role(r, :write),
         %{} = mirror <- pull_mirror(r.path) || not_found(),
         :ok <- Nugitea.Mirror.sync(mirror) |> or_status(502) do
      {200, %{}}
    end
    |> reply(conn)
  end

  # ---- forks ----------------------------------------------------------------

  # Into the caller's account, or an org they own (`organization`), under
  # the source's name or `name`. 202, as Gitea answers.
  post "/repos/:owner/:repo/forks" do
    dir = dir()
    p = conn.body_params

    with {:ok, user} <- signed_in(conn),
         {:ok, src} <- repo(conn, dir, owner, repo),
         {:ok, fork_owner} <- fork_owner(dir, user, p["organization"]),
         name = p["name"] || src.data.slug,
         :ok <- free(dir, "#{D.path(dir, fork_owner)}/#{name}"),
         # Validate against the directory before touching storage, and record
         # the fork only once its git data exists (as `repo create` does).
         {:ok, dry_run, id} <- fork_repo(dir, fork_owner, name, src) |> or_status(422),
         :ok <- Client.fork(src.path, D.repo_path(dry_run, id)) |> or_status(500),
         {:ok, dir, id} <- change(&fork_repo(&1, fork_owner, name, src)) do
      {202,
       repo_json(dir, %{id: id, path: D.repo_path(dir, id), role: :admin, data: D.repo(dir, id)})}
    end
    |> reply(conn)
  end

  get "/repos/:owner/:repo/forks" do
    dir = dir()

    with {:ok, src} <- repo(conn, dir, owner, repo) do
      forks = for r <- D.repos(dir), r.fork_of == src.id, do: r
      {200, repos_json(dir, visible(conn, dir, forks))}
    end
    |> reply(conn)
  end

  # ---- pull requests, issues, milestones -----------------------------------

  get "/repos/:owner/:repo/pulls" do
    dir = dir()
    state = conn.query_params["state"] || "all"

    with {:ok, r} <- repo(conn, dir, owner, repo) do
      {200, Enum.map(D.list_pull_requests_with_state(dir, r.id, state), &pr_json(dir, r, &1))}
    end
    |> reply(conn)
  end

  post "/repos/:owner/:repo/pulls" do
    p = conn.body_params

    with {:ok, user} <- signed_in(conn),
         {:ok, r} <- repo(conn, dir(), owner, repo),
         :ok <-
           valid(
             Enum.all?(~w(title head base), &is_binary(p[&1])),
             "title, head and base are required"
           ),
         {:ok, dir, pr_id} <-
           change(
             &D.create_pull_request(
               &1,
               r.id,
               p["title"],
               p["body"] || "",
               p["head"],
               p["base"],
               user
             )
           ) do
      {201, pr_json(dir, r, D.get_pull_request(dir, r.id, pr_id))}
    end
    |> reply(conn)
  end

  get "/repos/:owner/:repo/pulls/:index" do
    dir = dir()

    with {:ok, r} <- repo(conn, dir, owner, repo),
         {:ok, pr} <- pull_request(dir, r, index) do
      {200, pr_json(dir, r, pr)}
    end
    |> reply(conn)
  end

  patch "/repos/:owner/:repo/pulls/:index" do
    dir = dir()

    with {:ok, r} <- repo(conn, dir, owner, repo),
         :ok <- require_role(r, :write),
         {:ok, pr} <- pull_request(dir, r, index),
         {:ok, dir} <- change(&D.update_pull_request(&1, r.id, pr.id, conn.body_params)) do
      {200, pr_json(dir, r, D.get_pull_request(dir, r.id, pr.id))}
    end
    |> reply(conn)
  end

  # As in Gitea, issues and pull requests share this endpoint.
  patch "/repos/:owner/:repo/issues/:index" do
    dir = dir()

    with {:ok, r} <- repo(conn, dir, owner, repo),
         :ok <- require_role(r, :write) do
      case {D.get_issue(dir, r.id, index), pull_request(dir, r, index)} do
        {nil, {:ok, pr}} ->
          with {:ok, dir} <- change(&D.update_pull_request(&1, r.id, pr.id, conn.body_params)),
               do: {200, pr_json(dir, r, D.get_pull_request(dir, r.id, pr.id))}

        {nil, _} ->
          not_found()

        {issue, _} ->
          with {:ok, params} <- issue_params(conn.body_params),
               {:ok, dir} <- change(&D.update_issue(&1, r.id, issue.id, params)),
               do: {200, issue_json(dir, D.get_issue(dir, r.id, issue.id))}
      end
    end
    |> reply(conn)
  end

  get "/repos/:owner/:repo/milestones/:id" do
    dir = dir()

    with {:ok, r} <- repo(conn, dir, owner, repo),
         %{} = m <- D.get_milestone(dir, r.id, id) || not_found() do
      {200,
       %{
         id: m.id,
         title: m.title,
         description: m.description,
         state: to_string(m.state),
         open_issues: 0,
         closed_issues: 0,
         created_at: m.created_at,
         updated_at: m.updated_at,
         closed_at: if(m.state == :closed, do: m.updated_at),
         due_on: m.due_date
       }}
    end
    |> reply(conn)
  end

  # ---- git data -------------------------------------------------------------

  get "/repos/:owner/:repo/branches" do
    with {:ok, r} <- repo(conn, dir(), owner, repo),
         {:ok, tips} <- Client.branch_tips(r.path) |> or_status(404) do
      branches =
        for tip <- tips do
          [ref, sha, subject] = String.split(tip, " ", parts: 3)

          %{
            name: String.replace_prefix(ref, "refs/heads/", ""),
            commit: %{id: sha, message: subject}
          }
        end

      {200, branches}
    end
    |> reply(conn)
  end

  get "/repos/:owner/:repo/branches/:branch" do
    with {:ok, r} <- repo(conn, dir(), owner, repo),
         {:ok, b} <- Client.branch(r.path, branch) |> or_status(404) do
      {200, b}
    end
    |> reply(conn)
  end

  # `SHA.diff` or `SHA.patch`.
  get "/repos/:owner/:repo/git/commits/:file" do
    show =
      case Path.extname(file) do
        ".diff" -> &Client.commit_diff/2
        ".patch" -> &Client.commit_patch/2
        _ -> nil
      end

    with {:ok, r} <- repo(conn, dir(), owner, repo),
         true <- show != nil || not_found(),
         {:ok, text} <- show.(r.path, Path.rootname(file)) |> or_status(404) do
      {200, "text/plain; charset=utf-8", text}
    end
    |> reply(conn)
  end

  get "/repos/:owner/:repo/compare/:basehead" do
    with {:ok, r} <- repo(conn, dir(), owner, repo),
         {:ok, base, head} <- base_head(basehead),
         {:ok, commits} <- Client.commits(r.path, "#{base}..#{head}", []) |> or_status(404),
         {:ok, files} <- Client.changed_files(r.path, base, head) |> or_status(404) do
      {200,
       %{
         commits: Enum.map(commits, &Map.new/1),
         total_commits: length(commits),
         files: Enum.map(files, &%{filename: &1, status: "modified"})
       }}
    end
    |> reply(conn)
  end

  # `REF.zip` or `REF.tar.gz`; the ref may contain dots and slashes.
  get "/repos/:owner/:repo/archive/*archive" do
    {ref, format, type} =
      case Enum.join(archive, "/") do
        name when byte_size(name) > 7 and binary_part(name, byte_size(name), -7) == ".tar.gz" ->
          {binary_part(name, 0, byte_size(name) - 7), "tar.gz", "application/gzip"}

        name when byte_size(name) > 4 and binary_part(name, byte_size(name), -4) == ".zip" ->
          {binary_part(name, 0, byte_size(name) - 4), "zip", "application/zip"}

        _ ->
          {nil, nil, nil}
      end

    with {:ok, r} <- repo(conn, dir(), owner, repo),
         true <- format != nil || not_found(),
         {:ok, data} <- Client.archive(r.path, ref, format) |> or_status(404) do
      {200, type, data}
    end
    |> reply(conn)
  end

  # A file's bytes at `?ref=` (default HEAD): text/plain when it's UTF-8 text.
  get "/repos/:owner/:repo/raw/*path" do
    ref = conn.query_params["ref"] || "HEAD"

    with {:ok, r} <- repo(conn, dir(), owner, repo),
         {:ok, %{content: content}} <-
           Client.blob(r.path, ref, Enum.join(path, "/")) |> or_status(404) do
      type =
        if content != "" and String.valid?(content),
          do: "text/plain; charset=utf-8",
          else: "application/octet-stream"

      {200, type, content}
    end
    |> reply(conn)
  end

  match _ do
    reply(not_found(), conn)
  end

  # ---- replies --------------------------------------------------------------

  defp reply({:error, status, message}, conn), do: reply({status, %{message: message}}, conn)
  defp reply({204, nil}, conn), do: send_resp(conn, 204, "")

  defp reply({status, type, body}, conn),
    do: conn |> put_resp_content_type(type, nil) |> send_resp(status, body)

  defp reply({status, body}, conn),
    do: reply({status, "application/json", Jason.encode!(body)}, conn)

  defp not_found, do: {:error, 404, "not found"}

  defp valid(true, _message), do: :ok
  defp valid(false, message), do: {:error, 422, message}

  # A storage call's `{:error, reason}` as an HTTP error.
  defp or_status({:error, reason}, status), do: {:error, status, to_string_safe(reason)}
  defp or_status(ok, _status), do: ok

  defp base_head(basehead) do
    case String.split(basehead, "...", parts: 2) do
      [base, head] when base != "" and head != "" -> {:ok, base, head}
      _ -> {:error, 400, "expected BASE...HEAD"}
    end
  end

  defp to_string_safe(reason) when is_binary(reason), do: reason
  defp to_string_safe(reason), do: inspect(reason)

  # ---- lookups --------------------------------------------------------------

  defp dir do
    {:ok, dir} = Accounts.Store.load(Accounts.state_dir())
    dir
  end

  defp user_id(conn), do: conn.assigns.user_id

  defp signed_in(conn) do
    if user = user_id(conn), do: {:ok, user}, else: {:error, 401, "unauthorized"}
  end

  # The account `login` names, if it's a `kind` (:user or :org).
  defp account(dir, login, kind) do
    case D.account(dir, D.resolve(dir, login)) do
      %{kind: ^kind} = account -> {:ok, account}
      _ -> not_found()
    end
  end

  # The repo at `owner/name` (any case) as the caller sees it:
  # `%{id, path, role, data}`, or 404.
  defp repo(conn, dir, owner, name) do
    with id when id != nil <- D.resolve_repo(dir, "#{owner}/#{name}"),
         [r] <- visible(conn, dir, [D.repo(dir, id)]),
         true <- Client.exists?(r.path) do
      {:ok, r}
    else
      _ -> not_found()
    end
  end

  # The repos the caller can see, each as `%{id, path, role, data}`.
  defp visible(conn, dir, repos) do
    for r <- repos,
        role = D.effective_role(dir, user_id(conn), r.id),
        role != nil,
        do: %{id: r.id, path: D.repo_path(dir, r.id), role: role, data: r}
  end

  # read < triage < write < maintain < admin
  defp require_role(%{role: role}, min) do
    rank = &Enum.find_index(D.roles(), fn r -> r == &1 end)
    if rank.(role) >= rank.(min), do: :ok, else: {:error, 403, "forbidden"}
  end

  # A team the caller can see: they must be in its org.
  defp team(conn, dir, id) do
    with {n, ""} <- Integer.parse(id),
         %{} = team <- D.team(dir, n),
         true <- D.org_member?(dir, team.org, user_id(conn)) do
      {:ok, team}
    else
      _ -> not_found()
    end
  end

  # Only the org's owners manage its teams.
  defp set_team_member(conn, id, username, role) do
    dir = dir()

    with {:ok, team} <- team(conn, dir, id),
         :ok <- valid_owner(dir, team.org, user_id(conn)),
         {:ok, user} <- account(dir, username, :user),
         {:ok, _} <- change(&D.set_team_member(&1, team.id, user.id, role)) do
      {204, nil}
    end
    |> reply(conn)
  end

  defp valid_owner(dir, org, user),
    do: if(D.org_role(dir, org, user) == :owner, do: :ok, else: {:error, 403, "forbidden"})

  defp fork_owner(_dir, user, nil), do: {:ok, user}

  defp fork_owner(dir, user, org_login) do
    with {:ok, org} <- account(dir, org_login, :org),
         :ok <- valid_owner(dir, org.id, user),
         do: {:ok, org.id}
  end

  defp fork_repo(dir, owner, name, src) do
    with {:ok, dir, id} <- D.add_repo(dir, owner, name, src.data.visibility),
         do: {:ok, put_in(dir.repos[id].fork_of, src.id), id}
  end

  defp free(dir, path) do
    if D.resolve_repo(dir, path), do: {:error, 409, "repository already exists"}, else: :ok
  end

  defp pull_mirror(path),
    do: Enum.find(Nugitea.Mirror.Store.all(), &(&1.repo == path and &1.direction == :pull))

  # Pull requests are numbered by when they were opened: `REPO-NUMBER` ids.
  defp pull_request(dir, r, number) do
    case D.get_pull_request(dir, r.id, "#{r.id}-#{number}") do
      nil -> not_found()
      pr -> {:ok, pr}
    end
  end

  defp issue_params(%{"state" => state} = params) when state not in ["open", "closed"],
    do: {:error, 422, "state must be open or closed: #{inspect(params["state"])}"}

  defp issue_params(params) do
    {:ok,
     Map.new(params, fn {k, v} ->
       {k, if(k == "state", do: String.to_existing_atom(v), else: v)}
     end)}
  end

  # Applies a `Directory` change and saves it: `{:ok, dir}` or
  # `{:ok, dir, value}` with the saved directory, or 422.
  defp change(fun) do
    case Accounts.Store.update(Accounts.state_dir(), fun) do
      :ok -> {:ok, dir()}
      {:ok, value} -> {:ok, dir(), value}
      {:error, reason} -> {:error, 422, reason}
    end
  end

  defp int(params, key, default) do
    case Integer.parse(params[key] || "") do
      {n, ""} -> n
      _ -> default
    end
  end

  # ---- JSON -----------------------------------------------------------------

  defp user_json(nil), do: nil
  defp user_json(account), do: %{id: account.id, login: account.slug}

  defp users_json(dir, ids),
    do: ids |> Enum.map(&user_json(D.account(dir, &1))) |> Enum.sort_by(& &1.login)

  defp repos_json(dir, repos),
    do: repos |> Enum.sort_by(& &1.path) |> Enum.map(&repo_json(dir, &1))

  # What only a single-repo response looks up: its git data and mirror.
  defp git_details(r) do
    branches = ok_or(Client.branches(r.path), [])
    mirror = pull_mirror(r.path)

    %{
      empty: branches == [],
      branch_count: length(branches),
      size: ok_or(Client.size(r.path), 0),
      commit_count: ok_or(Client.commit_count(r.path), 0),
      default_branch: ok_or(Client.default_branch(r.path), "main"),
      mirror: mirror != nil,
      original_url: if(mirror, do: mirror.remote_url, else: "")
    }
  end

  defp ok_or({:ok, value}, _default), do: value
  defp ok_or(_error, default), do: default

  # Gitea Repository fields nugitea has no notion of yet.
  @repo_defaults %{
    template: false,
    language: nil,
    languages_url: "",
    html_url: "",
    url: "",
    ssh_url: "",
    clone_url: "",
    stars_count: 0,
    watchers_count: 0,
    release_counter: 0,
    has_code: true,
    has_issues: true,
    has_wiki: false,
    has_pull_requests: true,
    has_projects: false,
    has_releases: false,
    has_packages: false,
    has_actions: false,
    allow_merge_commits: true,
    allow_rebase: true,
    allow_squash_merge: true,
    default_merge_style: "merge",
    object_format_name: "sha1",
    mirror_interval: "",
    licenses: []
  }

  # A repo as Gitea's Repository (modules/structs/repo.go). `extra` adds
  # what only some routes look up (`git_details/1`).
  defp repo_json(dir, %{id: id, path: path, role: role, data: r}, extra \\ %{}) do
    parent = r.fork_of && D.repo(dir, r.fork_of)

    %{
      id: id,
      name: r.slug,
      full_name: path,
      description: r.description,
      website: r.website,
      private: r.visibility == :private,
      internal: r.visibility == :internal,
      fork: parent != nil,
      parent:
        parent && %{id: parent.id, name: parent.slug, full_name: D.repo_path(dir, parent.id)},
      topics: r.topics,
      forks_count: Enum.count(D.repos(dir), &(&1.fork_of == id)),
      open_issues_count: Enum.count(D.list_issues(dir, id), &(&1.state == :open)),
      open_pr_counter: length(D.list_pull_requests_with_state(dir, id, "open")),
      permissions: %{
        admin: role == :admin,
        push: role in [:write, :maintain, :admin],
        pull: true
      },
      empty: false,
      size: 0,
      branch_count: 0,
      default_branch: "main",
      mirror: false,
      original_url: ""
    }
    |> Map.merge(@repo_defaults)
    |> Map.merge(extra)
  end

  defp pr_json(dir, r, pr) do
    tip = fn branch ->
      case Client.branch(r.path, branch) do
        {:ok, b} -> %{ref: branch, sha: b.commit.id}
        _ -> %{ref: branch, sha: nil}
      end
    end

    %{
      number: pr.id |> String.split("-") |> List.last() |> String.to_integer(),
      title: pr.title,
      body: pr.description,
      state: to_string(pr.state),
      user: pr.author && user_json(D.account(dir, pr.author)),
      head: tip.(pr.head_branch),
      base: tip.(pr.base_branch),
      merged: false,
      created_at: pr.created_at,
      updated_at: pr.updated_at
    }
  end

  defp issue_json(dir, issue) do
    %{
      id: issue.id,
      title: issue.title,
      body: issue.body,
      state: to_string(issue.state),
      user: issue.author && user_json(D.account(dir, issue.author)),
      created_at: issue.created_at,
      updated_at: issue.updated_at,
      closed_at: issue.closed_at
    }
  end
end
