defmodule Mix.Tasks.Workspace.PostIssueLedger do
  use Mix.Task

  @shortdoc "Write a structured post-issue ledger summary"

  @moduledoc """
  Writes a structured post-issue ledger summary for a completed issue workspace.

  This task is intended for use from the `before_remove` workspace hook after
  GitHub PR Automation and Linear terminal-state detection.

  Usage:

      mix workspace.post_issue_ledger --repo-path /path/to/repo
      mix workspace.post_issue_ledger --repo-path /path/to/repo --issue MTP-10
      mix workspace.post_issue_ledger --repo-path /path/to/repo --output /path/to/latest.json

  The task never authorizes the next issue. It only records local facts for a
  parent Codex / human supervisor to read later.
  """

  @default_git_timeout_ms 20_000
  @default_graphify_timeout_ms 120_000

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          help: :boolean,
          repo_path: :string,
          output: :string,
          issue: :string,
          workspace: :string,
          skip_git_pull: :boolean,
          skip_graphify: :boolean,
          git_timeout_ms: :integer,
          graphify_timeout_ms: :integer
        ],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        write_ledger(opts)
    end
  end

  defp write_ledger(opts) do
    repo_path = Path.expand(required_repo_path!(opts))
    issue = opts[:issue] || System.get_env("SYMPHONY_ISSUE_IDENTIFIER") || Path.basename(File.cwd!())
    workspace = opts[:workspace] || System.get_env("SYMPHONY_WORKSPACE") || File.cwd!()
    output = opts[:output] || Path.join(repo_path, ".codex/post-issue-ledger/latest.json")

    git_operation =
      if opts[:skip_git_pull] do
        skipped_operation("git_pull_ff_only", "disabled by --skip-git-pull")
      else
        git_pull_operation(repo_path, timeout_ms(opts[:git_timeout_ms], @default_git_timeout_ms))
      end

    graphify_operation =
      if opts[:skip_graphify] do
        skipped_operation("graphify_update", "disabled by --skip-graphify")
      else
        graphify_operation(repo_path, timeout_ms(opts[:graphify_timeout_ms], @default_graphify_timeout_ms))
      end

    ledger = %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "issue" => issue,
      "workspace" => workspace,
      "repo_path" => repo_path,
      "operations" => [git_operation, graphify_operation],
      "graphify" => %{
        "mode" => "resource relationship graph",
        "output_path" => "graphify-out/",
        "submitted_to_git" => false
      },
      "next_step_hints" => %{
        "authorization" => "read_only",
        "notes" => [
          "Parent Codex may read this ledger for queue preview.",
          "This ledger does not authorize the next issue."
        ]
      },
      "boundaries" => [
        "does_not_authorize_next_issue",
        "does_not_create_linear_issue",
        "does_not_modify_roadmap",
        "does_not_submit_codex_scratchpad",
        "does_not_submit_graphify_out"
      ]
    }

    with :ok <- File.mkdir_p(Path.dirname(output)),
         :ok <- File.write(output, Jason.encode!(ledger, pretty: true)) do
      Mix.shell().info("Wrote post-issue ledger: #{output}")
    else
      {:error, reason} ->
        Mix.shell().error("Failed to write post-issue ledger: #{inspect(reason)}")
    end
  end

  defp required_repo_path!(opts) do
    case opts[:repo_path] do
      nil -> Mix.raise("--repo-path is required")
      "" -> Mix.raise("--repo-path is required")
      repo_path -> repo_path
    end
  end

  defp git_pull_operation(repo_path, timeout_ms) do
    if File.dir?(Path.join(repo_path, ".git")) do
      run_operation("git_pull_ff_only", "git", ["pull", "--ff-only", "origin", "main"], repo_path, timeout_ms)
    else
      skipped_operation("git_pull_ff_only", "repo path is not a git repository")
    end
  end

  defp graphify_operation(repo_path, timeout_ms) do
    cond do
      !File.dir?(repo_path) ->
        skipped_operation("graphify_update", "repo path is unavailable")

      is_nil(System.find_executable("graphify")) ->
        skipped_operation("graphify_update", "graphify command is unavailable")

      true ->
        run_operation("graphify_update", "graphify", ["update", "."], repo_path, timeout_ms)
    end
  end

  defp run_operation(name, command, args, cwd, timeout_ms) do
    task =
      Task.async(fn ->
        case System.find_executable(command) do
          nil -> {:skipped, "command is unavailable"}
          path -> System.cmd(path, args, cd: cwd, stderr_to_stdout: true)
        end
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:skipped, reason}} ->
        skipped_operation(name, reason)

      {:ok, {output, 0}} ->
        operation(name, command, args, cwd, "passed", output)

      {:ok, {output, status}} ->
        operation(name, command, args, cwd, "failed", output, status)

      nil ->
        Task.shutdown(task, :brutal_kill)
        operation(name, command, args, cwd, "timeout", "timed out after #{timeout_ms}ms")
    end
  end

  defp operation(name, command, args, cwd, status, output, exit_status \\ nil) do
    %{
      "name" => name,
      "command" => Enum.join([command | args], " "),
      "cwd" => cwd,
      "status" => status,
      "exit_status" => exit_status,
      "output" => truncate_output(output)
    }
  end

  defp skipped_operation(name, reason) do
    %{
      "name" => name,
      "status" => "skipped",
      "reason" => reason
    }
  end

  defp truncate_output(output, max_bytes \\ 4_000) when is_binary(output) do
    if byte_size(output) <= max_bytes do
      output
    else
      binary_part(output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp timeout_ms(value, _default) when is_integer(value) and value > 0, do: value
  defp timeout_ms(_value, default), do: default
end
