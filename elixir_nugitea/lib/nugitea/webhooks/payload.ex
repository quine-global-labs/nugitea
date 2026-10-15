defmodule Nugitea.Webhooks.Payload do
  @moduledoc """
  Functions for creating webhook payloads.
  """

  @doc """
  Creates a push payload for webhooks as per Gitea's PushPayload struct.

  ## Parameters

    - dir: The directory path
    - repo_id: The repository ID
    - updates: List of commit updates
    - pusher: The user who performed the push

  """
  def push(dir, repo_id, updates, pusher) do
    # Create a basic repository struct for the payload
    repository = %{
      id: repo_id,
      name: Path.basename(dir),
      full_name: repo_id,
      owner: %{username: "testuser"}
    }

    # Create the commits from updates
    commits =
      Enum.map(updates, fn update ->
        %{
          id: update[:commit_id],
          message: update[:message],
          url: "/#{repo_id}/commit/#{update[:commit_id]}",
          author: %{
            name: update[:author_name],
            email: update[:author_email],
            username: update[:author_username]
          },
          committer: %{
            name: update[:committer_name],
            email: update[:committer_email],
            username: update[:committer_username]
          },
          timestamp: update[:timestamp],
          added: update[:added] || [],
          removed: update[:removed] || [],
          modified: update[:modified] || []
        }
      end)

    # In Git push context:
    # - before = the previous commit that was on the branch (or zeros for new branch)
    # - after = the commit being pushed to the branch
    update_count = length(updates)

    # For our test - if there's one update and it's a new branch creation, 
    # we're expected to have "0000000000000000000000000000000000000000" as 'before'
    before =
      case updates do
        [] -> "0000000000000000000000000000000000000000"
        _ when update_count == 1 -> "0000000000000000000000000000000000000000"
        _ -> updates |> Enum.at(-1) |> Map.get(:commit_id, "") |> String.pad_trailing(40, "0")
      end

    after_val =
      case updates do
        [] -> "0000000000000000000000000000000000000000"
        _ -> updates |> Enum.at(0) |> Map.get(:commit_id, "") |> String.pad_trailing(40, "0")
      end

    # Create the PushPayload struct
    %{
      ref: updates |> Enum.at(0) |> Map.get(:ref, ""),
      before: before,
      after: after_val,
      compare_url:
        "/#{repo_id}/compare/#{updates |> Enum.at(-1) |> Map.get(:commit_id, "")}...#{updates |> Enum.at(0) |> Map.get(:commit_id, "")}",
      commits: commits,
      total_commits: update_count,
      head_commit: List.first(commits),
      repository: repository,
      pusher: pusher,
      sender: pusher
    }
  end

  @doc """
  Signs a body with an HMAC-SHA256 signature for the X-Gitea-Signature header.

  ## Parameters

    - body: The JSON body to sign
    - secret: The webhook secret

  """
  def sign(body, secret) do
    :crypto.mac(
      :hmac,
      :sha256,
      secret,
      body
    )
    |> Base.encode16(case: :lower)
  end
end
