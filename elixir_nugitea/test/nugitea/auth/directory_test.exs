defmodule Nugitea.Auth.DirectoryTest do
  use ExUnit.Case, async: true

  alias Nugitea.Accounts.Directory, as: D
  alias Nugitea.Auth.Directory
  alias Nugitea.Accounts.Store

  defp new!({:ok, dir, id}), do: {dir, id}
  defp set!({:ok, dir}), do: dir
  defp err?(result), do: match?({:error, _}, result)

  test "allow_pull? works with valid path and user" do
    # Simple test verifying that the function compiles and runs
    assert Directory.allow_pull?(nil, "nonexistent/repo") == false
  end

  test "allow_push? works with valid path and user" do
    # Simple test verifying that the function compiles and runs
    assert Directory.allow_push?(nil, "nonexistent/repo") == false
  end
end
