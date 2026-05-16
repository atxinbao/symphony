defmodule SymphonyElixir.HostHandoffFallback do
  @moduledoc """
  Performs a narrow host-side PR handoff when child Codex cannot write git or the
  local symphony-issue marker.
  """

  require Logger

  @marker_path ".codex/symphony-issue-handoff.json"
  @main_branches MapSet.new(["main", "master"])

  @spec run(map()) :: {:ready, map()} | {:continue, term()}
  def run(running_entry) when is_map(running_entry) do
    with {:ok, workspace} <- workspace_path(running_entry),
         :ok <- ensure_git_repo(workspace),
         {:ok, current_branch} <- current_branch(workspace),
         {:ok, changed?} <- workspace_changed?(workspace),
         :ok <- ensure_handoff_work(current_branch, changed?),
         {:ok, branch} <- ensure_issue_branch(workspace, running_entry, current_branch),
         {:ok, committed?} <- commit_if_needed(workspace, running_entry, changed?),
         :ok <- ensure_push_if_needed(workspace, branch, committed?),
         {:ok, pr_url} <- ensure_pr(workspace, branch, running_entry),
         :ok <- enable_auto_merge(workspace, pr_url),
         {:ok, marker} <- write_marker(workspace, running_entry, pr_url) do
      Logger.info("Host-side handoff fallback completed for issue=#{issue_identifier(running_entry)} pr_url=#{pr_url}")
      {:ready, marker}
    else
      {:skip, reason} ->
        {:continue, {:host_handoff_fallback_skipped, reason}}

      {:error, reason} ->
        {:continue, {:host_handoff_fallback_failed, reason}}
    end
  end

  def run(_running_entry), do: {:continue, {:host_handoff_fallback_skipped, :missing_running_entry}}

  defp workspace_path(%{workspace_path: workspace}) when is_binary(workspace) and workspace != "", do: {:ok, workspace}
  defp workspace_path(_running_entry), do: {:skip, :missing_workspace_path}

  defp ensure_git_repo(workspace) do
    case command("git", ["rev-parse", "--is-inside-work-tree"], cd: workspace) do
      {:ok, output} ->
        if String.trim(output) == "true" do
          :ok
        else
          {:skip, :not_git_repo}
        end

      {:error, reason} ->
        {:skip, {:git_repo_check_failed, reason}}
    end
  end

  defp ensure_handoff_work(current_branch, false) when current_branch == "" or current_branch in ["main", "master"] do
    {:skip, :no_host_handoff_work}
  end

  defp ensure_handoff_work(_current_branch, _changed?), do: :ok

  defp ensure_issue_branch(workspace, running_entry, current_branch) do
    if MapSet.member?(@main_branches, current_branch) or current_branch == "" do
      branch = issue_branch(running_entry)

      case command("git", ["checkout", "-B", branch], cd: workspace) do
        {:ok, _output} -> {:ok, branch}
        {:error, reason} -> {:error, {:branch_create_failed, reason}}
      end
    else
      {:ok, current_branch}
    end
  end

  defp current_branch(workspace) do
    case command("git", ["branch", "--show-current"], cd: workspace) do
      {:ok, branch} -> {:ok, String.trim(branch)}
      {:error, reason} -> {:error, {:branch_lookup_failed, reason}}
    end
  end

  defp commit_if_needed(workspace, running_entry, changed?) do
    if changed? do
      with {:ok, _} <- command("git", ["add", "-A"], cd: workspace),
           {:ok, _} <- command("git", ["commit", "-m", commit_message(running_entry)], cd: workspace) do
        {:ok, true}
      else
        {:error, reason} -> {:error, {:commit_failed, reason}}
      end
    else
      {:ok, false}
    end
  end

  defp workspace_changed?(workspace) do
    case command("git", ["status", "--porcelain", "--untracked-files=all"], cd: workspace) do
      {:ok, output} -> {:ok, String.trim(output) != ""}
      {:error, reason} -> {:error, {:status_failed, reason}}
    end
  end

  defp ensure_push_if_needed(workspace, branch, changed?) do
    case command("git", ["push", "--set-upstream", "origin", branch], cd: workspace) do
      {:ok, _output} ->
        :ok

      {:error, reason} when changed? == false ->
        {:skip, {:push_failed_without_local_changes, reason}}

      {:error, reason} ->
        {:error, {:push_failed, reason}}
    end
  end

  defp ensure_pr(workspace, branch, running_entry) do
    case command("gh", ["pr", "view", "--json", "url", "--jq", ".url"], cd: workspace) do
      {:ok, url} ->
        url = String.trim(url)
        if url == "", do: create_pr(workspace, branch, running_entry), else: {:ok, url}

      {:error, _reason} ->
        create_pr(workspace, branch, running_entry)
    end
  end

  defp create_pr(workspace, branch, running_entry) do
    body = host_fallback_pr_body(running_entry)

    case command("gh", ["pr", "create", "--title", pr_title(running_entry), "--body", body, "--base", "main", "--head", branch], cd: workspace) do
      {:ok, output} ->
        output
        |> String.split(~r/\R/, trim: true)
        |> Enum.find(&String.starts_with?(&1, "http"))
        |> case do
          nil -> {:error, {:pr_create_missing_url, output}}
          url -> {:ok, String.trim(url)}
        end

      {:error, reason} ->
        {:error, {:pr_create_failed, reason}}
    end
  end

  defp enable_auto_merge(workspace, pr_url) do
    case command("gh", ["pr", "merge", pr_url, "--auto", "--squash"], cd: workspace) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:auto_merge_failed, reason}}
    end
  end

  defp write_marker(workspace, running_entry, pr_url) do
    marker = %{
      "issue" => issue_identifier(running_entry),
      "pr_url" => pr_url,
      "ready_for_review" => true,
      "auto_merge_enabled" => true,
      "handoff_source" => "host-side handoff fallback",
      "fallback_reason" => "child Codex did not provide a valid symphony-issue handoff marker"
    }

    marker_file = Path.join(workspace, @marker_path)

    with :ok <- File.mkdir_p(Path.dirname(marker_file)),
         :ok <- File.write(marker_file, Jason.encode!(marker, pretty: true)) do
      {:ok, marker}
    else
      {:error, reason} -> {:error, {:marker_write_failed, reason}}
    end
  end

  defp command(binary, args, opts) when is_binary(binary) and is_list(args) and is_list(opts) do
    runner = Application.get_env(:symphony_elixir, :host_handoff_command_runner, &System.cmd/3)
    opts = Keyword.put(opts, :stderr_to_stdout, true)

    case runner.(binary, args, opts) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, %{command: binary, args: args, status: status, output: output}}
    end
  rescue
    error -> {:error, %{command: binary, args: args, error: Exception.message(error)}}
  end

  defp issue_branch(running_entry) do
    "symphony-issue/" <> slug(issue_identifier(running_entry))
  end

  defp commit_message(running_entry), do: pr_title(running_entry)

  defp pr_title(running_entry) do
    identifier = issue_identifier(running_entry)
    title = running_entry |> issue_value(:title) |> clean_one_line()

    if title == "" do
      identifier
    else
      "#{identifier}: #{title}"
    end
  end

  defp host_fallback_pr_body(running_entry) do
    """
    Host-side handoff fallback PR for #{issue_identifier(running_entry)}.

    This PR was prepared by Symphony host fallback after child Codex completed normally but did not provide a valid `.codex/symphony-issue-handoff.json` marker.

    Boundary:
    - No Linear status was modified by Codex.
    - `.codex/*` must not be included in this PR.
    - `graphify-out/*` must not be included in this PR.
    """
  end

  defp issue_identifier(running_entry), do: issue_value(running_entry, :identifier) || "issue"

  defp issue_value(%{issue: issue}, key) when is_map(issue), do: Map.get(issue, key)
  defp issue_value(_running_entry, _key), do: nil

  defp clean_one_line(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp clean_one_line(_value), do: ""

  defp slug(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "issue"
      slug -> slug
    end
  end
end
