defmodule Nugitea.MirrorTest do
  use ExUnit.Case

  alias Nugitea.Mirror.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.fetch_env!(:nugitea, :state_dir)
    Application.put_env(:nugitea, :state_dir, tmp)
    on_exit(fn -> Application.put_env(:nugitea, :state_dir, previous) end)
  end

  test "add/1 replaces an entry with the same repo and direction" do
    # First add a mirror entry
    entry1 = %{
      repo: "test/repo",
      remote_url: "https://example.com/test/repo.git",
      direction: :pull,
      interval_seconds: 300,
      last_sync_unix: 0
    }

    Store.add(entry1)

    # Add another entry with the same repo and direction (should replace the first)
    entry2 = %{
      repo: "test/repo",
      remote_url: "https://example.com/test/repo.git",
      direction: :pull,
      # Different interval to verify replacement
      interval_seconds: 600,
      last_sync_unix: 0
    }

    Store.add(entry2)

    # Verify that only the second entry exists (first was replaced)
    entries = Store.all()
    assert length(entries) == 1
    assert entries |> hd |> Map.get(:interval_seconds) == 600
  end

  test "touch/2 updates only the matching entry's last_sync_unix" do
    # Add two mirror entries with different repos
    entry1 = %{
      repo: "test/repo1",
      remote_url: "https://example.com/test/repo1.git",
      direction: :pull,
      interval_seconds: 300,
      last_sync_unix: 0
    }

    entry2 = %{
      repo: "test/repo2",
      remote_url: "https://example.com/test/repo2.git",
      direction: :pull,
      interval_seconds: 300,
      last_sync_unix: 0
    }

    Store.add(entry1)
    Store.add(entry2)

    # Touch the first entry with a new timestamp
    new_timestamp = System.os_time(:second)
    Store.touch(entry1, new_timestamp)

    # Verify that only the first entry's timestamp was updated
    entries = Store.all()
    assert length(entries) == 2

    # Find the entries by repo
    entry1_result = Enum.find(entries, &(&1.repo == "test/repo1"))
    entry2_result = Enum.find(entries, &(&1.repo == "test/repo2"))

    assert entry1_result.last_sync_unix == new_timestamp
    # Should remain unchanged
    assert entry2_result.last_sync_unix == 0
  end
end
