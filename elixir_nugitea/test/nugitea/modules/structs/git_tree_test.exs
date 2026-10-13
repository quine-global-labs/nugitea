defmodule Nugitea.Modules.Structs.GitTreeResponseTest do
  use ExUnit.Case, async: true

  alias Nugitea.Modules.Structs.GitTreeResponse

  describe "GitTreeResponse" do
    test "can be created with new/4" do
      tree = [
        %{path: "README.md", mode: "100644", type: "blob", sha: "a1b2c3d4e5f6", size: 100},
        %{path: "src", mode: "040000", type: "tree", sha: "f6e5d4c3b2a1", size: nil}
      ]

      response = GitTreeResponse.new("abc123def456", "https://api.example.com/tree", tree, false)

      assert response.sha == "abc123def456"
      assert response.url == "https://api.example.com/tree"
      assert response.tree == tree
      assert response.truncated == false
    end

    test "has correct struct definition" do
      assert %{sha: nil, url: nil, tree: nil, truncated: nil} = %GitTreeResponse{}
    end
  end
end
