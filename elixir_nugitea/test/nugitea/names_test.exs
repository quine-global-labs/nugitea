defmodule Nugitea.NamesTest do
  use ExUnit.Case, async: true

  alias Nugitea.Names

  test "repo paths" do
    assert Names.validate_repo_path("alice/dotfiles") == :ok
    assert Names.validate_repo_path("acme/platform/api") == :ok

    for bad <- ["flat", "acme//api", "acme/../api", "/acme/api", "x.git/api"] do
      assert {:error, _} = Names.validate_repo_path(bad), bad
    end
  end

  test "wire forms" do
    assert Names.from_wire_form("/acme/platform/api.git") == "acme/platform/api"
    assert Names.from_wire_form("acme/api.git") == "acme/api"
    assert Names.from_wire_form("acme/api") == nil
    assert Names.from_wire_form("api.git") == nil
    assert Names.from_wire_form("//acme/api.git") == nil
  end
end
