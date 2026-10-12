defmodule Nugitea.CLI.Test do
  use ExUnit.Case, async: true

  alias Nugitea.CLI
  alias Nugitea.Accounts.Directory, as: D

  describe "parse_duration/1" do
    test "parses seconds correctly" do
      assert CLI.parse_duration("30s") == {:ok, 30}
      assert CLI.parse_duration("5m") == {:ok, 300}
      assert CLI.parse_duration("2h") == {:ok, 7200}
    end

    test "handles invalid inputs" do
      assert CLI.parse_duration("") ==
               {:error, "invalid duration \"\": expected a number with s, m, or h"}

      assert CLI.parse_duration("5") ==
               {:error, "invalid duration \"5\": expected a number with s, m, or h"}

      assert CLI.parse_duration("5x") ==
               {:error, "invalid duration \"5x\": expected a number with s, m, or h"}

      assert CLI.parse_duration("-1m") ==
               {:error, "invalid duration \"-1m\": expected a number with s, m, or h"}
    end
  end

  describe "role/1" do
    test "accepts valid roles" do
      assert CLI.role(%{role: "member"}) == {:ok, :member}
      assert CLI.role(%{role: "owner"}) == {:ok, :owner}
      assert CLI.role(%{role: "billing_manager"}) == {:ok, :billing_manager}
    end

    test "rejects invalid roles" do
      assert CLI.role(%{role: "admin"}) ==
               {:error, "invalid role \"admin\": expected member, owner, or billing_manager"}

      assert CLI.role(%{role: "invalid"}) ==
               {:error, "invalid role \"invalid\": expected member, owner, or billing_manager"}
    end

    test "defaults to member" do
      assert CLI.role(%{}) == {:ok, :member}
    end
  end
end
