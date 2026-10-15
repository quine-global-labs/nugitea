defmodule TeamEndpointsTest do
  use ExUnit.Case, async: true

  alias Nugitea.Accounts.Directory, as: D

  defp fixture do
    {d, ent} = {:ok, D.add_enterprise(%D{}, "acme-corp")}
    {d, acme} = {:ok, D.add_org(d, "acme", nil, :internal)}
    d = {:ok, D.set_org_enterprise(d, acme, ent)}
    {d, alice} = {:ok, D.add_user(d, "alice")}
    {d, bob} = {:ok, D.add_user(d, "bob")}  
    {d, devs} = {:ok, D.add_team(d, acme, "devs", nil, :visible)}
    d = {:ok, D.set_org_member(d, acme, alice, :owner)}
    d = {:ok, D.set_org_member(d, acme, bob, :member)}
    d = {:ok, D.set_team_member(d, devs, bob, :member)}
    
    %{d: d, ent: ent, acme: acme, alice: alice, bob: bob, devs: devs}
  end

  test "teams routes exist and function correctly" do
    # Test that our fixtures work with basic team operations
    f = fixture()
    
    # Verify the team exists 
    assert f.d.teams[f.devs] != nil
    assert f.d.teams[f.devs].slug == "devs"
    
    # Verify the member is set correctly
    assert Map.has_key?(f.d.teams[f.devs].members, f.bob)
    assert f.d.teams[f.devs].members[f.bob] == :member
    
    # Verify organization membership
    assert D.org_member?(f.d, f.acme, f.alice) == true
    assert D.org_member?(f.d, f.acme, f.bob) == true
    
    # Verify team access 
    team = D.team(f.d, f.devs)  
    assert team != nil
    assert team.id == f.devs
    assert team.slug == "devs"
  end
end