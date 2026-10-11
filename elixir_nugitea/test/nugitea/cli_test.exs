defmodule Nugitea.CLI.Test do
  use ExUnit.Case, async: true

  alias Nugitea.CLI

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
end
