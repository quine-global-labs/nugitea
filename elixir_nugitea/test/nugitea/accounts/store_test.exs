defmodule Nugitea.Accounts.StoreTest do
  use ExUnit.Case, async: true

  alias Nugitea.Accounts.Directory, as: D
  alias Nugitea.Accounts.Store

  @moduletag :tmp_dir

  test "everything a change can add survives a save and a load", %{tmp_dir: tmp} do
    {:ok, ids} =
      Store.update(tmp, fn d ->
        {:ok, d, alice} = D.add_user(d, "alice")
        {:ok, d, repo} = D.add_repo_at(d, "alice/site", :public)
        {:ok, d} = D.update_repo(d, repo, "My site", nil, "https://example.com")
        {:ok, d} = D.add_user_key(d, alice, "ssh-ed25519 AAAA alice")
        {:ok, d, pr} = D.create_pull_request(d, repo, "Fix", "Body", "fix", "main", alice)
        {:ok, d, issue} = D.create_issue(d, repo, "Bug", "Broken", alice)
        {:ok, d, milestone} = D.create_milestone(d, repo, "v1", "First", nil, nil)
        {:ok, d} = D.update_issue(d, repo, issue, %{"state" => :closed})
        {:ok, d, %{alice: alice, repo: repo, pr: pr, issue: issue, milestone: milestone}}
      end)

    {:ok, dir} = Store.load(tmp)

    assert %{description: "My site", website: "https://example.com"} = D.repo(dir, ids.repo)
    assert [%{key: "ssh-ed25519 AAAA alice"}] = D.get_user_keys(dir, ids.alice)

    assert %{title: "Fix", state: :open, author: alice, created_at: %DateTime{}} =
             D.get_pull_request(dir, ids.repo, ids.pr)

    assert alice == ids.alice
    assert %{state: :closed, closed_at: %DateTime{}} = D.get_issue(dir, ids.repo, ids.issue)
    assert %{title: "v1", state: :open} = D.get_milestone(dir, ids.repo, ids.milestone)
  end

  test "a file without the newer fields still loads", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "accounts.json"), ~s({"next_id": 1, "accounts": {}, "repos": {}}))
    assert {:ok, %D{pull_requests: %{}, user_keys: %{}}} = Store.load(tmp)
  end
end
