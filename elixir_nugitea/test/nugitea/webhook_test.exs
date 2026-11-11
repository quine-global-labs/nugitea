defmodule Nugitea.WebhookTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Nugitea.Webhooks.Store

  describe "webhook store" do
    setup %{tmp_dir: tmp} do
      # Set up temporary state directory  
      state_dir = Path.join(tmp, "state")
      Application.put_env(:nugitea, :state_dir, state_dir)
      :ok
    end

    test "can load empty webhooks", %{tmp_dir: tmp} do
      state_dir = Path.join(tmp, "state")

      assert {:ok, %{}} = Store.load(state_dir)
    end

    test "can add and list a webhook", %{tmp_dir: tmp} do
      state_dir = Path.join(tmp, "state")

      # Add a webhook
      assert {:ok, _} =
               Store.update(
                 state_dir,
                 &Map.put(&1, "owner/repo", %{
                   url: "https://example.com/webhook",
                   secret: "secret123"
                 })
               )

      # Load and verify
      assert {:ok, webhooks} = Store.load(state_dir)
      assert webhooks["owner/repo"] == %{url: "https://example.com/webhook", secret: "secret123"}
    end

    test "can update an existing webhook", %{tmp_dir: tmp} do
      state_dir = Path.join(tmp, "state")

      # Add a webhook
      assert {:ok, _} =
               Store.update(
                 state_dir,
                 &Map.put(&1, "owner/repo", %{
                   url: "https://example.com/webhook",
                   secret: "secret123"
                 })
               )

      # Update the same webhook with new data
      assert {:ok, _} =
               Store.update(
                 state_dir,
                 &Map.put(&1, "owner/repo", %{
                   url: "https://example.com/updated-webhook",
                   secret: nil
                 })
               )

      # Load and verify
      assert {:ok, webhooks} = Store.load(state_dir)
      assert webhooks["owner/repo"] == %{url: "https://example.com/updated-webhook", secret: nil}
    end

    test "can add multiple webhooks", %{tmp_dir: tmp} do
      state_dir = Path.join(tmp, "state")

      # Add multiple webhooks
      assert {:ok, _} =
               Store.update(
                 state_dir,
                 &Map.put(&1, "owner/repo1", %{
                   url: "https://example.com/webhook1",
                   secret: "secret1"
                 })
               )

      assert {:ok, _} =
               Store.update(
                 state_dir,
                 &Map.put(&1, "owner/repo2", %{
                   url: "https://example.com/webhook2",
                   secret: "secret2"
                 })
               )

      # Load and verify
      assert {:ok, webhooks} = Store.load(state_dir)
      assert webhooks["owner/repo1"] == %{url: "https://example.com/webhook1", secret: "secret1"}
      assert webhooks["owner/repo2"] == %{url: "https://example.com/webhook2", secret: "secret2"}
    end
  end

  describe "CLI webhook commands" do
    setup %{tmp_dir: tmp} do
      # Set up temporary state directory  
      state_dir = Path.join(tmp, "state")
      Application.put_env(:nugitea, :state_dir, state_dir)
      :ok
    end

    test "add webhook command works", %{tmp_dir: tmp} do
      # Test adding a webhook via CLI
      assert :ok =
               Nugitea.CLI.main(["webhook", "add", "owner/repo", "https://example.com/webhook"])

      # Verify that the webhook was saved by loading it directly through the store
      assert {:ok, webhooks} =
               Nugitea.Webhooks.Store.load(Application.get_env(:nugitea, :state_dir))

      assert webhooks["owner/repo"] == %{url: "https://example.com/webhook", secret: nil}
    end

    test "add webhook with secret works", %{tmp_dir: tmp} do
      # Test adding a webhook with secret via CLI
      assert :ok =
               Nugitea.CLI.main([
                 "webhook",
                 "add",
                 "owner/repo",
                 "https://example.com/webhook",
                 "--secret",
                 "my-secret"
               ])

      # Verify that the webhook was saved by loading it directly through the store
      assert {:ok, webhooks} =
               Nugitea.Webhooks.Store.load(Application.get_env(:nugitea, :state_dir))

      assert webhooks["owner/repo"] == %{url: "https://example.com/webhook", secret: "my-secret"}
    end

    test "list webhook command works", %{tmp_dir: tmp} do
      # Add a webhook first
      assert {:ok, _} =
               Nugitea.Webhooks.Store.update(
                 Application.get_env(:nugitea, :state_dir),
                 &Map.put(&1, "owner/repo", %{
                   url: "https://example.com/webhook",
                   secret: "secret123"
                 })
               )

      # Test listing webhooks
      assert :ok = Nugitea.CLI.main(["webhook", "list"])
    end
  end
end
