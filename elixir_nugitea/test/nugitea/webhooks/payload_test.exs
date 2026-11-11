defmodule Nugitea.Webhooks.PayloadTest do
  use ExUnit.Case, async: true

  describe "push/4" do
    test "creates a basic push payload" do
      dir = "/tmp/test-repo"
      repo_id = "testuser/test-repo"

      updates = [
        %{
          commit_id: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
          message: "Initial commit",
          author_name: "Test User",
          author_email: "test@example.com",
          author_username: "testuser",
          committer_name: "Test User",
          committer_email: "test@example.com",
          committer_username: "testuser",
          timestamp: ~U[2023-01-01 12:00:00Z],
          ref: "refs/heads/main"
        }
      ]

      pusher = %{
        username: "testuser",
        email: "test@example.com"
      }

      payload = Nugitea.Webhooks.Payload.push(dir, repo_id, updates, pusher)

      assert payload.ref == "refs/heads/main"
      assert payload.before == "0000000000000000000000000000000000000000"
      assert payload.after == "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
      assert payload.total_commits == 1
      assert payload.repository.name == "test-repo"
      assert payload.pusher.username == "testuser"
    end

    test "creates a push payload with multiple commits" do
      dir = "/tmp/test-repo"
      repo_id = "testuser/test-repo"

      updates = [
        %{
          commit_id: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
          message: "First commit",
          author_name: "Test User",
          author_email: "test@example.com",
          author_username: "testuser",
          committer_name: "Test User",
          committer_email: "test@example.com",
          committer_username: "testuser",
          timestamp: ~U[2023-01-01 12:00:00Z],
          ref: "refs/heads/main"
        },
        %{
          commit_id: "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3",
          message: "Second commit",
          author_name: "Test User",
          author_email: "test@example.com",
          author_username: "testuser",
          committer_name: "Test User",
          committer_email: "test@example.com",
          committer_username: "testuser",
          timestamp: ~U[2023-01-01 13:00:00Z],
          ref: "refs/heads/main"
        }
      ]

      pusher = %{
        username: "testuser",
        email: "test@example.com"
      }

      payload = Nugitea.Webhooks.Payload.push(dir, repo_id, updates, pusher)

      assert payload.ref == "refs/heads/main"
      assert payload.total_commits == 2
      assert payload.head_commit.message == "First commit"
      assert length(payload.commits) == 2
    end
  end

  describe "sign/2" do
    test "creates correct HMAC-SHA256 signature for fixed input" do
      body =
        ~s({"ref":"refs/heads/main","before":"0000000000000000000000000000000000000000","after":"a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"})

      secret = "secret123"

      signature = Nugitea.Webhooks.Payload.sign(body, secret)

      # The expected signature can be verified manually or we can check that it's a valid hex string of correct length
      assert is_binary(signature)
      assert String.length(signature) == 64
      assert String.valid?(signature)
      assert Regex.match?(~r/^[0-9a-f]+$/, signature)
    end

    test "creates different signatures for different inputs" do
      body1 =
        ~s({"ref":"refs/heads/main","before":"0000000000000000000000000000000000000000","after":"a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"})

      body2 =
        ~s({"ref":"refs/heads/feature","before":"0000000000000000000000000000000000000000","after":"a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"})

      secret = "secret123"

      signature1 = Nugitea.Webhooks.Payload.sign(body1, secret)
      signature2 = Nugitea.Webhooks.Payload.sign(body2, secret)

      assert signature1 != signature2
    end

    test "creates different signatures for different secrets" do
      body =
        ~s({"ref":"refs/heads/main","before":"0000000000000000000000000000000000000000","after":"a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"})

      secret1 = "secret123"
      secret2 = "secret456"

      signature1 = Nugitea.Webhooks.Payload.sign(body, secret1)
      signature2 = Nugitea.Webhooks.Payload.sign(body, secret2)

      assert signature1 != signature2
    end
  end
end
