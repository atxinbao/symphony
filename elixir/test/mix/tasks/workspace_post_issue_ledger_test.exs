defmodule Mix.Tasks.Workspace.PostIssueLedgerTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Workspace.PostIssueLedger

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("workspace.post_issue_ledger")
    :ok
  end

  test "prints help" do
    output =
      capture_io(fn ->
        PostIssueLedger.run(["--help"])
      end)

    assert output =~ "mix workspace.post_issue_ledger"
  end

  test "requires repo path" do
    assert_raise Mix.Error, ~r/--repo-path is required/, fn ->
      PostIssueLedger.run([])
    end
  end

  test "writes structured ledger and runs git pull plus graphify update" do
    with_fake_binaries(
      %{
        "git" => """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$LEDGER_COMMAND_LOG"
        if [ "$1" = "pull" ]; then
          printf 'Already up to date.\\n'
          exit 0
        fi
        exit 99
        """,
        "graphify" => """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$LEDGER_COMMAND_LOG"
        if [ "$1" = "update" ]; then
          printf 'graph updated\\n'
          exit 0
        fi
        exit 99
        """
      },
      fn root, log_path ->
        repo_path = Path.join(root, "repo")
        output_path = Path.join(root, "ledger/latest.json")
        File.mkdir_p!(Path.join(repo_path, ".git"))

        output =
          capture_io(fn ->
            PostIssueLedger.run([
              "--repo-path",
              repo_path,
              "--output",
              output_path,
              "--issue",
              "MTP-10",
              "--workspace",
              "/tmp/MTP-10"
            ])
          end)

        assert output =~ "Wrote post-issue ledger"

        ledger =
          output_path
          |> File.read!()
          |> Jason.decode!()

        assert ledger["schema_version"] == 1
        assert ledger["issue"] == "MTP-10"
        assert ledger["workspace"] == "/tmp/MTP-10"
        assert ledger["repo_path"] == repo_path
        assert ledger["graphify"]["mode"] == "resource relationship graph"
        assert ledger["graphify"]["submitted_to_git"] == false
        assert ledger["next_step_hints"]["authorization"] == "read_only"
        assert "does_not_authorize_next_issue" in ledger["boundaries"]

        operations = Map.new(ledger["operations"], &{&1["name"], &1})
        assert operations["git_pull_ff_only"]["status"] == "passed"
        assert operations["graphify_update"]["status"] == "passed"

        command_log = File.read!(log_path)
        assert command_log =~ "pull --ff-only origin main"
        assert command_log =~ "update ."
      end
    )
  end

  test "writes skipped operations when repo and graphify are unavailable" do
    with_path([], fn ->
      root = Path.join(System.tmp_dir!(), "post-issue-ledger-skip-#{System.unique_integer([:positive])}")
      output_path = Path.join(root, "latest.json")

      try do
        output =
          capture_io(fn ->
            PostIssueLedger.run([
              "--repo-path",
              Path.join(root, "missing-repo"),
              "--output",
              output_path,
              "--issue",
              "MTP-11"
            ])
          end)

        assert output =~ "Wrote post-issue ledger"

        ledger =
          output_path
          |> File.read!()
          |> Jason.decode!()

        operations = Map.new(ledger["operations"], &{&1["name"], &1})
        assert operations["git_pull_ff_only"]["status"] == "skipped"
        assert operations["graphify_update"]["status"] == "skipped"
      after
        File.rm_rf!(root)
      end
    end)
  end

  defp with_fake_binaries(scripts, fun) do
    root = Path.join(System.tmp_dir!(), "post-issue-ledger-test-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(root, "bin")
    log_path = Path.join(root, "commands.log")

    try do
      File.rm_rf!(root)
      File.mkdir_p!(bin_dir)
      File.write!(log_path, "")

      Enum.each(scripts, fn {name, script} ->
        path = Path.join(bin_dir, name)
        File.write!(path, script)
        File.chmod!(path, 0o755)
      end)

      with_env(
        %{
          "PATH" => Enum.join([bin_dir, System.get_env("PATH") || ""], ":"),
          "LEDGER_COMMAND_LOG" => log_path
        },
        fn -> fun.(root, log_path) end
      )
    after
      File.rm_rf!(root)
    end
  end

  defp with_path(paths, fun) do
    with_env(%{"PATH" => Enum.join(paths, ":")}, fun)
  end

  defp with_env(overrides, fun) do
    keys = Map.keys(overrides)
    previous = Map.new(keys, fn key -> {key, System.get_env(key)} end)

    try do
      Enum.each(overrides, fn {key, value} -> System.put_env(key, value) end)
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
