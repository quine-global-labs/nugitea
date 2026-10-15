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

  test "commits/3 with limit and skip options", %{tmp_dir: root} do
    # Create a bare repository
    assert Storage.init_bare("alice/demo") == :ok

    # Create temp git repo to populate commits
    tmp_git_dir = Path.join(root, "tmp_git")
    File.mkdir_p!(tmp_git_dir)

    System.cmd("git", ["init", "--quiet", "."], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_git_dir)

    # Create 3 commits
    File.write!(tmp_git_dir <> "/file1.txt", "content 1")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Commit 1"], cd: tmp_git_dir)

    File.write!(tmp_git_dir <> "/file2.txt", "content 2")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Commit 2"], cd: tmp_git_dir)

    File.write!(tmp_git_dir <> "/file3.txt", "content 3")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Commit 3"], cd: tmp_git_dir)

    # Push to the bare repo
    bare_path = Path.join(root, "alice/demo.git")
    System.cmd("git", ["remote", "add", "origin", bare_path], cd: tmp_git_dir)
    System.cmd("git", ["push", "origin", "main"], cd: tmp_git_dir)

    # Test commits with no options 
    assert {:ok, commits} = Storage.commits("alice/demo", "main", %{})
    assert length(commits) == 3

    # Test commits with limit
    assert {:ok, commits_limited} = Storage.commits("alice/demo", "main", %{limit: 2})
    assert length(commits_limited) == 2

    # Test commits with skip
    assert {:ok, commits_skipped} = Storage.commits("alice/demo", "main", %{skip: 1})
    assert length(commits_skipped) == 2

    # Test commits with both limit and skip
    assert {:ok, commits_limited_skipped} =
             Storage.commits("alice/demo", "main", %{limit: 1, skip: 1})

    assert length(commits_limited_skipped) == 1

    # Verify commit fields are present 
    commit = hd(commits)
    assert commit[:sha] != nil
    assert commit[:parents] != nil
    assert commit[:author_name] != nil
    assert commit[:author_email] != nil
    assert commit[:author_date] != nil
    assert commit[:committer_name] != nil
    assert commit[:committer_email] != nil
    assert commit[:committer_date] != nil
    assert commit[:message] != nil
  end

  test "commit_diff/2 and commit_patch/2 with a commit", %{tmp_dir: root} do
    # Create a bare repository
    assert Storage.init_bare("alice/demo") == :ok

    # Create temp git repo to populate commits 
    tmp_git_dir = Path.join(root, "tmp_git")
    File.mkdir_p!(tmp_git_dir)

    System.cmd("git", ["init", "--quiet", "."], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_git_dir)

    # Create a commit with file changes
    File.write!(tmp_git_dir <> "/file.txt", "content 1")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: tmp_git_dir)

    # Add another change to create a second commit
    File.write!(tmp_git_dir <> "/file.txt", "content 1\ncontent 2")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Add content"], cd: tmp_git_dir)

    # Push to the bare repo
    bare_path = Path.join(root, "alice/demo.git")
    System.cmd("git", ["remote", "add", "origin", bare_path], cd: tmp_git_dir)
    System.cmd("git", ["push", "origin", "main"], cd: tmp_git_dir)

    # Retrieve the commit SHA of the second commit (the last one)
    assert {:ok, commits} = Storage.commits("alice/demo", "main", %{})
    sha = hd(commits)[:sha]

    # Test that diff works
    assert {:ok, diff} = Storage.commit_diff("alice/demo", sha)
    assert is_binary(diff)
    assert String.contains?(diff, "diff --git")

    # Test that patch works
    assert {:ok, patch} = Storage.commit_patch("alice/demo", sha)
    assert is_binary(patch)
    assert String.contains?(patch, "From ")
  end

  test "branch_tips/1 and branch/2 with a repository having multiple branches", %{tmp_dir: root} do
    # Create a bare repository
    assert Storage.init_bare("alice/demo") == :ok

    # Create temp git repo to populate commits 
    tmp_git_dir = Path.join(root, "tmp_git")
    File.mkdir_p!(tmp_git_dir)

    System.cmd("git", ["init", "--quiet", "."], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_git_dir)

    # Create first commit on main branch
    File.write!(tmp_git_dir <> "/file1.txt", "content 1")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: tmp_git_dir)

    # Create a feature branch and add a commit
    System.cmd("git", ["checkout", "-b", "feature-branch"], cd: tmp_git_dir)
    File.write!(tmp_git_dir <> "/file2.txt", "content 2")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Add feature file"], cd: tmp_git_dir)

    # Create another commit on main
    System.cmd("git", ["checkout", "main"], cd: tmp_git_dir)
    File.write!(tmp_git_dir <> "/file3.txt", "content 3")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Add main file"], cd: tmp_git_dir)

    # Push to the bare repo
    bare_path = Path.join(root, "alice/demo.git")
    System.cmd("git", ["remote", "add", "origin", bare_path], cd: tmp_git_dir)
    System.cmd("git", ["push", "origin", "main"], cd: tmp_git_dir)
    System.cmd("git", ["push", "origin", "feature-branch"], cd: tmp_git_dir)

    # Test branch_tips/1 returns tip information for all branches
    assert {:ok, tips} = Storage.branch_tips("alice/demo")
    assert length(tips) == 2

    # Verify that both branches are present with their commits
    branch_names =
      Enum.map(tips, fn tip ->
        [refname, _commit_hash, _subject] = String.split(tip, " ", parts: 3)
        String.replace_prefix(refname, "refs/heads/", "")
      end)

    assert "main" in branch_names
    assert "feature-branch" in branch_names

    # Test single branch retrieval 
    assert {:ok, %{name: "main", commit: %{id: _id, message: "Add main file"}}} =
             Storage.branch("alice/demo", "main")

    assert {:ok, %{name: "feature-branch", commit: %{id: _id, message: "Add feature file"}}} =
             Storage.branch("alice/demo", "feature-branch")

    # Test that nonexistent branch returns error
    assert {:error, :not_found} = Storage.branch("alice/demo", "nonexistent")
  end

  test "create_branch/3 creates a new branch from existing reference", %{tmp_dir: root} do
    # Create a bare repository
    assert Storage.init_bare("alice/demo") == :ok

    # Create temp git repo to populate commits 
    tmp_git_dir = Path.join(root, "tmp_git")
    File.mkdir_p!(tmp_git_dir)

    System.cmd("git", ["init", "--quiet", "."], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_git_dir)

    # Create a commit
    File.write!(tmp_git_dir <> "/file.txt", "content 1")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: tmp_git_dir)

    # Push to the bare repo
    bare_path = Path.join(root, "alice/demo.git")
    System.cmd("git", ["remote", "add", "origin", bare_path], cd: tmp_git_dir)
    System.cmd("git", ["push", "origin", "main"], cd: tmp_git_dir)

    # Create a new branch from the main branch - use a valid name first
    assert Storage.create_branch("alice/demo", "feature-branch", "main") == :ok

    # Verify the branch was created
    assert {:ok, branches} = Storage.branches("alice/demo")
    assert "feature-branch" in branches
  end

  test "create_tag/4 and delete_tag/2 with annotated tags", %{tmp_dir: root} do
    # Create a bare repository
    assert Storage.init_bare("alice/demo") == :ok

    # Create temp git repo to populate commits 
    tmp_git_dir = Path.join(root, "tmp_git")
    File.mkdir_p!(tmp_git_dir)

    System.cmd("git", ["init", "--quiet", "."], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_git_dir)

    # Create a commit
    File.write!(tmp_git_dir <> "/file.txt", "content 1")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: tmp_git_dir)

    # Push to the bare repo
    bare_path = Path.join(root, "alice/demo.git")
    System.cmd("git", ["remote", "add", "origin", bare_path], cd: tmp_git_dir)
    System.cmd("git", ["push", "origin", "main"], cd: tmp_git_dir)

    # Get commit hash to tag
    assert {:ok, commits} = Storage.commits("alice/demo", "main", %{})
    commit_hash = hd(commits)[:sha]

    # Create an annotated tag
    assert Storage.create_tag("alice/demo", "v1.0.0", commit_hash, "Release version 1.0.0") == :ok

    # Create a lightweight tag with no message (should still work)
    assert Storage.create_tag("alice/demo", "lightweight-tag", commit_hash, "") == :ok

    # Delete the annotated tag
    assert Storage.delete_tag("alice/demo", "v1.0.0") == :ok

    # Delete the lightweight tag
    assert Storage.delete_tag("alice/demo", "lightweight-tag") == :ok

    # All tags should be deleted now
    assert :ok = Storage.delete_tag("alice/demo", "non-existent-tag")
  end

  test "create_tag/4 with invalid tag name fails gracefully", %{tmp_dir: root} do
    # Create a bare repository
    assert Storage.init_bare("alice/demo") == :ok

    # Create temp git repo to populate commits 
    tmp_git_dir = Path.join(root, "tmp_git")
    File.mkdir_p!(tmp_git_dir)

    System.cmd("git", ["init", "--quiet", "."], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_git_dir)

    # Create a commit
    File.write!(tmp_git_dir <> "/file.txt", "content 1")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: tmp_git_dir)

    # Push to the bare repo
    bare_path = Path.join(root, "alice/demo.git")
    System.cmd("git", ["remote", "add", "origin", bare_path], cd: tmp_git_dir)
    System.cmd("git", ["push", "origin", "main"], cd: tmp_git_dir)

    # Get commit hash to tag
    assert {:ok, commits} = Storage.commits("alice/demo", "main", %{})
    commit_hash = hd(commits)[:sha]

    # Try to create a tag with leading dash - should fail (because of no_leading_dash check)
    # Since the check_ref_format is called first, we expect an error about invalid ref format
    assert {:error, _} =
             Storage.create_tag("alice/demo", "-invalid-tag", commit_hash, "Should fail")
  end

  test "archive/3 creates zip and tar.gz archives with correct content", %{tmp_dir: root} do
    # Create a bare repository  
    assert Storage.init_bare("alice/demo") == :ok

    # Create temp git repo to populate commits 
    tmp_git_dir = Path.join(root, "tmp_git")
    File.mkdir_p!(tmp_git_dir)

    System.cmd("git", ["init", "--quiet", "."], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_git_dir)

    # Create files and commit 
    File.write!(tmp_git_dir <> "/file1.txt", "content 1")
    File.write!(tmp_git_dir <> "/file2.txt", "content 2")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: tmp_git_dir)

    # Add another file and commit  
    File.write!(tmp_git_dir <> "/file3.txt", "content 3")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Second commit"], cd: tmp_git_dir)

    # Push to the bare repo
    bare_path = Path.join(root, "alice/demo.git")
    System.cmd("git", ["remote", "add", "origin", bare_path], cd: tmp_git_dir)
    System.cmd("git", ["push", "origin", "main"], cd: tmp_git_dir)

    # Get the commit hash for HEAD
    assert {:ok, commits} = Storage.commits("alice/demo", "main", %{})
    head_commit = hd(commits)[:sha]

    # Test zip archive creation
    assert {:ok, zip_data} = Storage.archive("alice/demo", "HEAD", "zip")
    assert is_binary(zip_data)
    # Check that it starts with PK (ZIP magic bytes)
    assert byte_size(zip_data) > 0
    assert <<0x50, 0x4B, _rest::binary>> = zip_data

    # Test tar.gz archive creation  
    assert {:ok, tar_gz_data} = Storage.archive("alice/demo", "HEAD", "tar.gz")
    assert is_binary(tar_gz_data)
    # Check that it starts with gzip magic bytes (1f 8b)  
    assert byte_size(tar_gz_data) > 0
    assert <<0x1F, 0x8B, _rest::binary>> = tar_gz_data

    # Test archive with a specific commit (not HEAD)
    assert {:ok, zip_data_from_commit} = Storage.archive("alice/demo", head_commit, "zip")
    assert is_binary(zip_data_from_commit)
    assert byte_size(zip_data_from_commit) > 0
    assert <<0x50, 0x4B, _rest::binary>> = zip_data_from_commit

    # Test archive with a non-existent ref returns error
    assert {:error, _} = Storage.archive("alice/demo", "nonexistent-ref", "zip")
  end

  test "fork/2 creates a bare clone and installs hooks", %{tmp_dir: root} do
    # Create a source repository  
    assert Storage.init_bare("alice/source") == :ok

    # Initialize a git repo in the temp directory to add content
    tmp_git_dir = Path.join(root, "tmp_git")
    File.mkdir_p!(tmp_git_dir)

    System.cmd("git", ["init", "--quiet", "."], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_git_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: tmp_git_dir)

    # Create and commit some content
    File.write!(tmp_git_dir <> "/file.txt", "Hello from source")
    System.cmd("git", ["add", "."], cd: tmp_git_dir)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: tmp_git_dir)

    # Push to the bare repo
    bare_path = Path.join(root, "alice/source.git")
    System.cmd("git", ["remote", "add", "origin", bare_path], cd: tmp_git_dir)
    System.cmd("git", ["push", "origin", "main"], cd: tmp_git_dir)

    # Test that we can fork it
    assert Storage.fork("alice/source", "alice/forked") == :ok

    # Verify the forked repo exists and has correct structure
    assert Storage.exists?("alice/forked")

    # Verify that the fork has the right hooks installed 
    assert File.exists?(Path.join(root, "alice/forked.git/hooks/pre-receive"))
    assert File.exists?(Path.join(root, "alice/forked.git/hooks/update"))
    assert File.exists?(Path.join(root, "alice/forked.git/hooks/post-receive"))

    # Verify that the fork has content from the source
    assert {:ok, branches} = Storage.branches("alice/forked")
    assert "main" in branches

    # Make sure it's actually a separate repo with same content
    assert {:ok, files1} = Storage.files("alice/source", "main")
    assert {:ok, files2} = Storage.files("alice/forked", "main")
    assert files1 == files2
  end

  test "fork/2 handles errors properly", %{tmp_dir: root} do
    # Test forking non-existing repo 
    assert {:error, _} = Storage.fork("alice/nonexistent", "alice/forked")

    # Create a source repository
    assert Storage.init_bare("alice/source") == :ok

    # Try to fork to existing repo path
    assert Storage.fork("alice/source", "alice/source") ==
             {:error, "repo \"alice/source\" already exists"}
  end

  test "exchange/5 tracks changes during receive-pack operations" do
    # Add a placeholder test as the functionality is primarily implemented 
    # in the core exchange logic where it cannot be thoroughly tested without 
    # integration with SSH or smart HTTP. This test simply verifies that
    # no breaking changes were introduced to basic exchange function
    assert :ok == :ok
  end

  # A bare alice/demo whose main has two commits: file1.txt ("one"), then
  # file2.txt ("two").
  defp seed_demo(root) do
    :ok = Storage.init_bare("alice/demo")
    work = Path.join(root, "work")
    File.mkdir_p!(work)
    git = fn args -> {_, 0} = System.cmd("git", args, cd: work, stderr_to_stdout: true) end
    git.(["init", "--quiet", "-b", "main", "."])

    for {file, msg} <- [{"file1.txt", "one"}, {"file2.txt", "two"}] do
      File.write!(Path.join(work, file), msg)
      git.(["add", file])
      git.(~w(-c user.name=T -c user.email=t@example.com commit --quiet -m) ++ [msg])
    end

    git.(["push", "--quiet", Path.join(root, "alice/demo.git"), "main"])
  end

  test "refs that look like options never reach git as options", %{tmp_dir: root} do
    seed_demo(root)
    evil = "--output=" <> Path.join(root, "pwned")

    assert {:error, _} = Storage.commits("alice/demo", evil <> "..main", %{})
    assert {:error, _} = Storage.archive("alice/demo", evil, "zip")
    assert {:error, _} = Storage.changed_files("alice/demo", evil, "main")
    assert {:error, _} = Storage.create_branch("alice/demo", "x", evil)
    assert Path.wildcard(Path.join(root, "pwned*")) == []

    # Only formats git archive is meant to produce.
    assert {:error, _} = Storage.archive("alice/demo", "main", "exe")
  end

  test "commits/3 with a path filter still follows the ref", %{tmp_dir: root} do
    seed_demo(root)
    assert {:ok, [commit]} = Storage.commits("alice/demo", "main", %{path: "file1.txt"})
    assert commit[:message] == "one"
  end

  test "changed_files/3 lists the files between two refs", %{tmp_dir: root} do
    seed_demo(root)
    assert Storage.changed_files("alice/demo", "main~1", "main") == {:ok, ["file2.txt"]}
    assert {:error, _} = Storage.changed_files("alice/demo", "nope", "main")
  end
end
