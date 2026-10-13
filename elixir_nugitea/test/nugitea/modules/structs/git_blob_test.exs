defmodule Nugitea.Modules.Structs.GitBlobResponseTest do
  use ExUnit.Case, async: true

  alias Nugitea.Modules.Structs.GitBlobResponse

  describe "GitBlobResponse" do
    test "can be created with new/3" do
      content = "Hello, world!"

      response = GitBlobResponse.new("abc123def456", 13, content)

      assert response.sha == "abc123def456"
      assert response.size == 13
      assert response.encoding == "base64"
      assert response.content == content
    end

    test "has correct struct definition" do
      assert %{sha: nil, size: nil, encoding: nil, content: nil} = %GitBlobResponse{}
    end
  end
end
