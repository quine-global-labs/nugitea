defmodule Nugitea.Accounts.DirectoryTest do
  use ExUnit.Case, async: true

  alias Nugitea.Accounts.Directory, as: D

  # Ported from rust_nugitea's accounts tests, one for one.

  defp new!({:ok, dir, id}), do: {dir, id}
  defp set!({:ok, dir}), do: dir
  defp err?(result), do: match?({:error, _}, result)

  # enterprise acme-corp (unmanaged)
  #   acme (org, internal)
  #     platform (sub-org, private)
  #       api (repo, private)
  #     site (repo, internal)
  # alice, bob, carol (users); alice owns acme, bob is a member;
  # team acme/devs = [bob]
  defp fixture do
    {d, ent} = new!(D.add_enterprise(%D{}, "acme-corp"))
    {d, acme} = new!(D.add_org(d, "acme", nil, :internal))
    d = set!(D.set_org_enterprise(d, acme, ent))
    {d, platform} = new!(D.add_org(d, "platform", acme, :private))
    {d, api} = new!(D.add_repo(d, platform, "api", :private))
    {d, site} = new!(D.add_repo(d, acme, "site", :internal))
    {d, alice} = new!(D.add_user(d, "alice"))
    {d, bob} = new!(D.add_user(d, "bob"))
    {d, carol} = new!(D.add_user(d, "carol"))
    d = set!(D.set_org_member(d, acme, alice, :owner))
    d = set!(D.set_org_member(d, acme, bob, :member))
    {d, devs} = new!(D.add_team(d, acme, "devs", nil, :visible))
    d = set!(D.set_team_member(d, devs, bob, :member))

    %{d: d, ent: ent, acme: acme, platform: platform, api: api, site: site}
    |> Map.merge(%{alice: alice, bob: bob, carol: carol, devs: devs})
  end

  test "users and top-level orgs share a case-insensitive namespace" do
    f = fixture()
    assert err?(D.add_user(f.d, "ACME"))
    assert err?(D.add_org(f.d, "Alice", nil, :public))
    # but a sub-org is scoped to its parent
    assert {:ok, _, _} = D.add_org(f.d, "alice", f.acme, :private)
  end

  test "sub-orgs and repos share a path space" do
    f = fixture()
    assert err?(D.add_repo(f.d, f.acme, "platform", :private))
    assert err?(D.add_org(f.d, "site", f.acme, :private))
  end

  test "rejects reserved and malformed slugs" do
    for slug <- ["repos", "foo.git", "-foo", "a/b"], do: assert(err?(D.add_user(%D{}, slug)))
  end

  test "structural invariants" do
    f = fixture()
    # users can't parent orgs
    assert err?(D.add_org(f.d, "x", f.alice, :private))
    # children can't be more visible than parents
    assert err?(D.add_org(f.d, "x", f.platform, :public))
    assert err?(D.add_repo(f.d, f.platform, "x", :internal))
    # only top-level orgs join an enterprise; sub-orgs inherit
    assert err?(D.set_org_enterprise(f.d, f.platform, f.ent))
    assert D.enterprise_of(f.d, f.platform) == f.ent
    assert D.enterprise_of(f.d, f.alice) == nil
  end

  test "paths round trip" do
    f = fixture()
    assert D.path(f.d, f.platform) == "acme/platform"
    assert D.repo_path(f.d, f.api) == "acme/platform/api"
    assert D.resolve(f.d, "ACME/Platform") == f.platform
    assert D.resolve_repo(f.d, "acme/platform/api") == f.api
    assert D.resolve_repo(f.d, "acme/api") == nil
  end

  test "internal means enterprise members inside an enterprise" do
    f = fixture()
    assert D.effective_role(f.d, nil, f.site) == nil
    assert D.effective_role(f.d, f.carol, f.site) == nil
    assert D.effective_role(f.d, f.bob, f.site) == :read
    assert D.effective_role(f.d, f.bob, f.api) == nil
    # a member of a sibling org in the same enterprise counts too
    {d, other} = new!(D.add_org(f.d, "other", nil, :public))
    d = set!(D.set_org_enterprise(d, other, f.ent))
    d = set!(D.set_org_member(d, other, f.carol, :member))
    assert D.effective_role(d, f.carol, f.site) == :read
  end

  test "internal means any signed-in user outside an enterprise" do
    f = fixture()
    {d, gl} = new!(D.add_org(f.d, "gl", nil, :internal))
    {d, repo} = new!(D.add_repo(d, gl, "x", :internal))
    assert D.effective_role(d, nil, repo) == nil
    assert D.effective_role(d, f.carol, repo) == :read
  end

  test "org owners are admin everywhere beneath" do
    f = fixture()
    assert D.effective_role(f.d, f.alice, f.api) == :admin
    assert D.org_role(f.d, f.platform, f.alice) == :owner
  end

  test "base role applies to members only" do
    f = fixture()
    d = set!(D.set_base_role(f.d, f.acme, :write))
    d = set!(D.set_org_member(d, f.acme, f.carol, :billing_manager))
    assert D.effective_role(d, f.bob, f.api) == :write
    assert D.effective_role(d, f.carol, f.api) == nil
    refute D.enterprise_member?(d, f.ent, f.carol)
  end

  test "grants inherit down the tree and take the max" do
    f = fixture()
    d = set!(D.grant(f.d, {:user, f.bob}, {:org, f.acme}, :triage))
    d = set!(D.grant(d, {:user, f.bob}, {:org, f.platform}, :maintain))
    d = set!(D.grant(d, {:team, f.devs}, {:repo, f.api}, :write))
    assert D.effective_role(d, f.bob, f.api) == :maintain
    assert D.effective_role(d, f.bob, f.site) == :triage
    # re-granting replaces rather than stacks
    d = set!(D.grant(d, {:user, f.bob}, {:org, f.platform}, :read))
    assert D.effective_role(d, f.bob, f.api) == :write
    d = D.revoke(d, {:team, f.devs}, {:repo, f.api})
    # still has acme's
    assert D.effective_role(d, f.bob, f.api) == :triage
  end

  test "outside collaborators get repo grants but not org grants" do
    f = fixture()
    assert err?(D.grant(f.d, {:user, f.carol}, {:org, f.acme}, :read))
    d = set!(D.grant(f.d, {:user, f.carol}, {:repo, f.api}, :write))
    assert D.effective_role(d, f.carol, f.api) == :write
    refute D.org_member?(d, f.acme, f.carol)
  end

  test "nested teams inherit parent access" do
    f = fixture()
    {d, backend} = new!(D.add_team(f.d, f.acme, "backend", f.devs, :visible))
    d = set!(D.set_org_member(d, f.acme, f.carol, :member))
    d = set!(D.set_team_member(d, backend, f.carol, :maintainer))
    d = set!(D.grant(d, {:team, f.devs}, {:repo, f.api}, :write))
    assert D.effective_role(d, f.carol, f.api) == :write
    # but not the other way round
    d = set!(D.grant(d, {:team, backend}, {:repo, f.api}, :admin))
    assert D.effective_role(d, f.bob, f.api) == :write
  end

  test "team rules" do
    f = fixture()
    {d, secret} = new!(D.add_team(f.d, f.acme, "secret", nil, :secret))
    assert err?(D.add_team(d, f.acme, "x", secret, :visible))
    assert err?(D.add_team(d, f.acme, "y", f.devs, :secret))
    assert err?(D.set_team_member(d, f.devs, f.carol, :member))
    {d, other} = new!(D.add_org(d, "other", nil, :public))
    {d, theirs} = new!(D.add_repo(d, other, "x", :public))
    assert err?(D.grant(d, {:team, f.devs}, {:repo, theirs}, :read))
  end

  test "removing a member prunes their access" do
    f = fixture()
    d = set!(D.grant(f.d, {:user, f.bob}, {:repo, f.api}, :write))
    d = set!(D.grant(d, {:team, f.devs}, {:org, f.acme}, :read))
    d = set!(D.set_org_member(d, f.acme, f.bob, nil))
    refute Map.has_key?(D.team(d, f.devs).members, f.bob)
    assert D.effective_role(d, f.bob, f.api) == nil
    # an inherited membership from above survives removal below
    d = set!(D.set_org_member(d, f.acme, f.carol, :member))
    d = set!(D.set_org_member(d, f.platform, f.carol, :member))
    d = set!(D.set_org_member(d, f.platform, f.carol, nil))
    assert D.org_member?(d, f.platform, f.carol)
  end

  test "last owner can't leave" do
    f = fixture()
    assert err?(D.set_org_member(f.d, f.acme, f.alice, nil))
    assert err?(D.set_org_member(f.d, f.acme, f.alice, :member))
    d = set!(D.set_org_member(f.d, f.acme, f.bob, :owner))
    assert {:ok, _} = D.set_org_member(d, f.acme, f.alice, nil)
  end

  test "custom roles add permissions on a base" do
    f = fixture()
    {d, hooks} = new!(D.add_custom_role(f.d, f.acme, "hook-admin", :read, ["manage_webhooks"]))
    assert err?(D.add_custom_role(d, f.acme, "Write", :write, []))
    d = set!(D.grant(d, {:team, f.devs}, {:repo, f.api}, {:custom, hooks}))
    access = D.effective_access(d, f.bob, f.api)
    assert access.role == :read
    assert "manage_webhooks" in access.permissions
    # only usable beneath the defining org
    {d, other} = new!(D.add_org(d, "other", nil, :public))
    {d, theirs} = new!(D.add_repo(d, other, "x", :public))
    assert err?(D.grant(d, {:user, f.carol}, {:repo, theirs}, {:custom, hooks}))
  end

  test "enterprise roles grant no repo access" do
    f = fixture()
    d = set!(D.set_enterprise_role(f.d, f.ent, f.carol, :owner))
    assert D.enterprise_role(d, f.ent, f.carol) == :owner
    assert D.effective_role(d, f.carol, f.api) == nil
  end

  test "managed users are confined to their enterprise" do
    f = fixture()
    {d, emu} = new!(D.add_enterprise(f.d, "globex", "gx"))
    {d, gx} = new!(D.add_org(d, "globex", nil, :public))
    d = set!(D.set_org_enterprise(d, gx, emu))
    {d, hank} = new!(D.add_managed_user(d, emu, "hank"))
    assert D.account(d, hank).slug == "hank_gx"
    # unmanaged enterprise
    assert err?(D.add_managed_user(d, f.ent, "x"))

    d = set!(D.set_org_member(d, gx, hank, :owner))
    # outsiders can't get in, and hank can't get out
    assert err?(D.set_org_member(d, gx, f.carol, :member))
    {d, gx_repo} = new!(D.add_repo(d, gx, "x", :private))
    assert err?(D.grant(d, {:user, f.carol}, {:repo, gx_repo}, :read))
    assert err?(D.set_org_member(d, f.acme, hank, :member))
    {d, public} = new!(D.add_repo(d, f.carol, "pub", :public))
    assert err?(D.grant(d, {:user, hank}, {:repo, public}, :write))
    assert D.effective_role(d, hank, public) == :read
    # no public repos of their own
    assert err?(D.add_repo(d, hank, "p", :public))
    assert {:ok, _, _} = D.add_repo(d, hank, "p", :private)
    # an org with outside members can't move into a managed enterprise
    assert err?(D.set_org_enterprise(d, f.acme, emu))
    assert D.enterprise_of(d, f.acme) == f.ent
  end

  test "blocks" do
    f = fixture()
    {d, gl} = new!(D.add_org(f.d, "gl", nil, :public))
    {d, open} = new!(D.add_repo(d, gl, "open", :public))
    d = set!(D.grant(d, {:user, f.carol}, {:repo, open}, :write))
    d = set!(D.block(d, gl, f.carol))
    assert D.effective_role(d, f.carol, open) == :read
    assert err?(D.grant(d, {:user, f.carol}, {:repo, open}, :write))
    # still a member
    assert err?(D.block(d, f.acme, f.bob))
    d = D.unblock(d, gl, f.carol)
    assert {:ok, _} = D.grant(d, {:user, f.carol}, {:repo, open}, :write)
  end

  test "users own their repos" do
    f = fixture()
    {d, dots} = new!(D.add_repo(f.d, f.alice, "dotfiles", :private))
    assert D.effective_role(d, f.alice, dots) == :admin
    assert D.effective_role(d, f.bob, dots) == nil
    assert D.repo_path(d, dots) == "alice/dotfiles"
  end

  test "role mappings" do
    assert D.role_from_github("push") == :write
    # guest
    assert D.role_from_gitlab(10) == nil
    assert D.role_from_gitlab(20) == :read
    assert D.role_from_gitlab(50) == :admin
    assert D.role_from_gitea(4) == :admin
    assert D.role_from_gitea(0) == nil
  end

  test "add by path" do
    f = fixture()
    {d, tools} = new!(D.add_org_at(f.d, "acme/platform/tools", :private))
    {d, cli} = new!(D.add_repo_at(d, "ACME/platform/tools/cli", :private))
    assert D.parent(D.account(d, tools)) == f.platform
    assert D.repo_path(d, cli) == "acme/platform/tools/cli"
    assert err?(D.add_repo_at(d, "nobody/x", :public))
    assert err?(D.add_repo_at(d, "flat", :public))
    assert err?(D.add_org_at(d, "nobody/x", :public))
  end

  test "JSON round trip" do
    f = fixture()
    {d, hooks} = new!(D.add_custom_role(f.d, f.acme, "hook-admin", :read, ["manage_webhooks"]))
    d = set!(D.grant(d, {:team, f.devs}, {:repo, f.api}, {:custom, hooks}))
    d = set!(D.grant(d, {:user, f.bob}, {:repo, f.site}, :write))
    d = set!(D.block(d, f.alice, f.carol))
    back = d |> Nugitea.Accounts.Store.encode() |> Nugitea.Accounts.Store.decode()
    assert back == d
    assert D.effective_access(back, f.bob, f.api) == D.effective_access(d, f.bob, f.api)
  end

  test "delete repo removes grants and pull requests" do
    f = fixture()

    # Create a new repo with grants and some pull requests for testing
    {d, test_repo} = new!(D.add_repo(f.d, f.acme, "test", :private))

    # Add grants to this repo
    d = set!(D.grant(d, {:user, f.bob}, {:repo, test_repo}, :write))
    d = set!(D.grant(d, {:team, f.devs}, {:repo, test_repo}, :read))

    # Create some pull requests for the repo 
    {d, _pr1_id} =
      new!(D.create_pull_request(d, test_repo, "PR 1", "desc 1", "feature", "main", f.alice))

    {d, _pr2_id} =
      new!(D.create_pull_request(d, test_repo, "PR 2", "desc 2", "bugfix", "main", f.bob))

    # Verify the repo and pull requests exist  
    assert D.repo(d, test_repo) != nil
    assert length(D.list_pull_requests(d, test_repo)) == 2

    # Verify grants exist 
    grant_count_before = length(d.grants)
    assert Enum.any?(d.grants, fn g -> g.resource == {:repo, test_repo} end)

    # Delete the repo - this is our new function
    result = D.delete_repo(d, test_repo)
    assert {:ok, deleted_dir} = result

    # Verify the repo is gone
    assert D.repo(deleted_dir, test_repo) == nil

    # Verify pull requests are gone for this repo  
    assert Map.get(deleted_dir.pull_requests, test_repo) == nil

    # Verify grants for this repo are gone
    assert not Enum.any?(deleted_dir.grants, fn g -> g.resource == {:repo, test_repo} end)

    # Verify total grant count decreased (there were 2 grants for the deleted repo plus 1 from fixture)
    assert length(deleted_dir.grants) < grant_count_before

    # Verify other repos and data remain untouched
    assert D.repo(deleted_dir, f.api) != nil
    assert D.repo(deleted_dir, f.site) != nil
    assert length(D.list_pull_requests(deleted_dir, f.api)) == 0
    assert length(D.list_pull_requests(deleted_dir, f.site)) == 0
    assert length(D.list_pull_requests(deleted_dir, test_repo)) == 0
  end
end
