defmodule Nugitea.StorageTest do
  use ExUnit.Case

  alias Nugitea.Storage

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.fetch_env!(:nugitea, :repo_root)
    Application.put_env(:nugitea, :repo_root, tmp)
    on_exit(fn -> Application.put_env(:nugitea, :repo_root, previous) end)
  end

  test "nested layout", %{tmp_dir: root} do
    assert Storage.dir("acme/platform/api") == {:ok, Path.join(root, "acme/platform/api.git")}
    assert {:error, _} = Storage.dir("../x")

    for d <- ["acme/platform/api.git", "alice/dotfiles.git", "legacy.git"],
        do: File.mkdir_p!(Path.join(root, d))

    assert Storage.list() == ["acme/platform/api", "alice/dotfiles"]
    assert Storage.exists?("acme/platform/api")
  end

  test "init_bare installs hooks and refuses to overwrite", %{tmp_dir: root} do
    assert Storage.init_bare("alice/dotfiles") == :ok
    assert File.exists?(Path.join(root, "alice/dotfiles.git/HEAD"))

    assert File.stat!(Path.join(root, "alice/dotfiles.git/hooks/pre-receive")).mode
           |> Bitwise.band(0o111) != 0

    assert {:error, _} = Storage.init_bare("alice/dotfiles")
  end

  test "delete removes repository directory", %{tmp_dir: _root} do
    # Create a repo
    assert Storage.init_bare("alice/test") == :ok

    # Verify it exists 
    assert Storage.exists?("alice/test")

    # Delete it
    assert Storage.delete("alice/test") == :ok

    # Verify it no longer exists
    refute Storage.exists?("alice/test")

    # Try to delete non-existent repo
    assert {:error, :not_found} = Storage.delete("alice/does-not-exist")
  end

  test "delete refuses paths outside repo root", %{tmp_dir: _root} do
    # Try to delete a path that's not under the repo root  
    assert {:error, _} = Storage.delete("../outside")
    assert {:error, _} = Storage.delete("/tmp/somefile")

    # Test with a valid nested repo path but try to go out of bounds 
    assert {:error, _} = Storage.delete("../../../etc/passwd")
  end

  test "branches/1, tree/3, blob/3, and files/2 with a commit", %{tmp_dir: root} do
    # Set up a bare repository
    assert Storage.init_bare("alice/demo") == :ok

    # Create a temporary directory for git operations in tmp directory to avoid conflict
    tmp_git_dir = Path.join(root, "tmp_git")
    File.mkdir_p!(tmp_git_dir)

    # Initialize a git repo in the temp directory and add some content
    System.cmd("git", ["init", "--quiet", "."], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_git_dir)

    # Create a test file
    File.write!(tmp_git_dir <> "/test.txt", "Hello, world!")

    # Add and commit the file
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: tmp_git_dir)

    # Create a nested directory and file  
    File.mkdir_p!(tmp_git_dir <> "/subdir")
    File.write!(tmp_git_dir <> "/subdir/nested.txt", "Nested content")

    # Add and commit the nested file
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Add nested file"], cd: tmp_git_dir)

    # Push to the bare repo using a different approach  
    bare_path = Path.join(root, "alice/demo.git")
    System.cmd("git", ["remote", "add", "origin", bare_path], cd: tmp_git_dir)
    System.cmd("git", ["push", "origin", "main"], cd: tmp_git_dir)

    # Test branches/1 - should return the branch name
    assert {:ok, branches} = Storage.branches("alice/demo")
    assert "main" in branches

    # Test files/2 - should list all files recursively 
    assert {:ok, files} = Storage.files("alice/demo", "main")
    assert "test.txt" in files
    assert "subdir/nested.txt" in files

    # Test tree/3 - should return the tree structure at root
    assert {:ok, tree_entries} = Storage.tree("alice/demo", "main", "")
    # Check that we have entries for both files
    tree_names = Enum.map(tree_entries, & &1.name)
    assert "test.txt" in tree_names
    assert "subdir" in tree_names

    # Test blob/3 - should return content of a specific file
    assert {:ok, %{content: content}} = Storage.blob("alice/demo", "main", "test.txt")
    assert content == "Hello, world!"

    # Test tree/3 for nested directory
    assert {:ok, subdir_entries} = Storage.tree("alice/demo", "main", "subdir")
    assert length(subdir_entries) == 1
    assert subdir_entries |> hd() |> Map.get(:name) == "nested.txt"

    # Test blob/3 for nested file
    assert {:ok, %{content: nested_content}} =
             Storage.blob("alice/demo", "main", "subdir/nested.txt")

    assert nested_content == "Nested content"
  end

  test "default_branch/1 and set_default_branch/2", %{tmp_dir: root} do
    # Create a bare repository
    assert Storage.init_bare("alice/demo") == :ok

    # Initially, default branch should be "main"
    assert {:ok, "main"} = Storage.default_branch("alice/demo")

    # Add another branch  
    tmp_git_dir = Path.join(root, "tmp_git")
    File.mkdir_p!(tmp_git_dir)

    System.cmd("git", ["init", "--quiet", "."], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_git_dir)

    File.write!(tmp_git_dir <> "/test.txt", "Hello, world!")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: tmp_git_dir)
    System.cmd("git", ["checkout", "-b", "feature-branch"], cd: tmp_git_dir)

    File.write!(tmp_git_dir <> "/feature.txt", "Feature content")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Add feature file"], cd: tmp_git_dir)

    # Push to the bare repo
    bare_path = Path.join(root, "alice/demo.git")
    System.cmd("git", ["remote", "add", "origin", bare_path], cd: tmp_git_dir)
    System.cmd("git", ["push", "origin", "main"], cd: tmp_git_dir)
    System.cmd("git", ["push", "origin", "feature-branch"], cd: tmp_git_dir)

    # Set default branch to feature-branch
    assert Storage.set_default_branch("alice/demo", "feature-branch") == :ok
    assert {:ok, "feature-branch"} = Storage.default_branch("alice/demo")

    # Try setting to non-existent branch - should error
    assert {:error, _} = Storage.set_default_branch("alice/demo", "non-existent")
  end

  test "size/1 returns repository size in KiB", %{tmp_dir: root} do
    # Create a bare repository
    assert Storage.init_bare("alice/test-size") == :ok

    # Test with an empty repository (should have at least some size from git objects)
    assert {:ok, size} = Storage.size("alice/test-size")
    assert is_integer(size)
    assert size >= 0

    # Create a repo with content to verify size calculation works
    tmp_git_dir = Path.join(root, "tmp_git")
    File.mkdir_p!(tmp_git_dir)

    System.cmd("git", ["init", "--quiet", "."], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_git_dir)

    # Add a test file
    File.write!(tmp_git_dir <> "/test.txt", "Hello, world!")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: tmp_git_dir)

    # Add a larger file to make size difference more obvious
    File.write!(tmp_git_dir <> "/large.txt", String.duplicate("x", 1024))
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Add large file"], cd: tmp_git_dir)

    # Push to the bare repo
    bare_path = Path.join(root, "alice/test-size.git")
    System.cmd("git", ["remote", "add", "origin", bare_path], cd: tmp_git_dir)
    System.cmd("git", ["push", "origin", "main"], cd: tmp_git_dir)

    # Check that size is now larger
    assert {:ok, size_after} = Storage.size("alice/test-size")
    assert is_integer(size_after)
    assert size_after > size
  end
end
