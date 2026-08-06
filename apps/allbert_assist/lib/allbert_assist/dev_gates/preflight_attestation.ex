defmodule AllbertAssist.DevGates.PreflightAttestation do
  @moduledoc """
  Exact-repository-state evidence for the developer preflight gate.

  This is a plain development-tooling module: it hashes Git-visible repository
  state and writes an ignored JSON artifact. It grants no runtime authority.
  """

  alias AllbertAssist.Objectives.CanonicalJSON

  @schema_version 2
  @relative_path ".test_metrics/preflight-attestation.json"
  @compared_fields ~w[
    schema_version
    canonical_repo_root
    head_sha
    clean
    worktree_content_digest
    mix_lock_digest
    gate_definition_digest
    elixir_version
    otp_release
    otp_version
  ]

  def relative_path, do: @relative_path

  def invalidate!(root, opts \\ []) do
    root
    |> path(opts)
    |> File.rm()
    |> case do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "remove", path: path(root, opts)
    end
  end

  def write!(root, gate_definition_digest, attrs, opts \\ []) when is_map(attrs) do
    current = capture_state!(root, gate_definition_digest, opts)

    artifact =
      current
      |> Map.merge(%{
        "checks" => Map.fetch!(attrs, :checks),
        "total_wall_ms" => Map.fetch!(attrs, :total_wall_ms),
        "completed_at" => Map.get_lazy(attrs, :completed_at, &now_iso8601/0),
        "status" => Map.get(attrs, :status, "passed")
      })

    destination = path(root, opts)
    File.mkdir_p!(Path.dirname(destination))

    temporary =
      destination <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    File.write!(temporary, Jason.encode!(artifact, pretty: true) <> "\n", [:binary])
    File.rename!(temporary, destination)
    artifact
  end

  def verify!(root, gate_definition_digest, opts \\ []) do
    artifact = read!(root, opts)

    current =
      Keyword.get_lazy(opts, :current_state, fn ->
        capture_state!(root, gate_definition_digest, opts)
      end)

    case validate(artifact, current, opts) do
      :ok ->
        artifact

      {:error, reasons} ->
        Mix.raise("preflight attestation refused: " <> Enum.join(reasons, "; "))
    end
  end

  def validate(artifact, current, opts \\ []) when is_map(artifact) and is_map(current) do
    reasons =
      @compared_fields
      |> Enum.reduce([], fn field, errors ->
        if Map.get(artifact, field) == Map.get(current, field) do
          errors
        else
          errors ++ ["#{field} changed"]
        end
      end)
      |> maybe_add(artifact["status"] != "passed", "last preflight did not pass")
      |> maybe_add(
        Keyword.get(opts, :clean_required?, false) and current["clean"] != true,
        "release evidence requires a clean worktree"
      )

    if reasons == [], do: :ok, else: {:error, reasons}
  end

  def capture_state!(root, gate_definition_digest, opts \\ []) do
    root = canonical_root!(root)
    git = Keyword.get(opts, :git_runner, &git!/3)
    head_sha = git.(root, ["rev-parse", "HEAD"], opts) |> String.trim()
    status = git.(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], opts)
    otp_release = to_string(:erlang.system_info(:otp_release))

    %{
      "schema_version" => @schema_version,
      "canonical_repo_root" => root,
      "head_sha" => head_sha,
      "clean" => status == "",
      "worktree_content_digest" => worktree_digest!(root, git, opts),
      "mix_lock_digest" => file_digest(Path.join(root, "mix.lock")),
      "gate_definition_digest" => gate_definition_digest,
      "elixir_version" => System.version(),
      "otp_release" => otp_release,
      "otp_version" => otp_version!(otp_release)
    }
  end

  def digest_term(term) do
    term
    |> CanonicalJSON.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp read!(root, opts) do
    artifact_path = path(root, opts)

    with {:ok, body} <- File.read(artifact_path),
         {:ok, artifact} when is_map(artifact) <- Jason.decode(body) do
      artifact
    else
      {:error, :enoent} ->
        Mix.raise("preflight attestation refused: missing #{artifact_path}")

      {:error, reason} ->
        Mix.raise(
          "preflight attestation refused: unreadable #{artifact_path}: #{inspect(reason)}"
        )

      _other ->
        Mix.raise("preflight attestation refused: invalid JSON object in #{artifact_path}")
    end
  end

  defp worktree_digest!(root, git, opts) do
    head_tree = git.(root, ["rev-parse", "HEAD^{tree}"], opts)
    staged = git.(root, ["diff", "--cached", "--binary", "--no-ext-diff", "--full-index"], opts)
    unstaged = git.(root, ["diff", "--binary", "--no-ext-diff", "--full-index"], opts)

    untracked =
      root
      |> untracked_paths(git, opts)
      |> Enum.map(fn relative ->
        absolute = Path.join(root, relative)

        content =
          case File.lstat!(absolute) do
            %File.Stat{type: :symlink} ->
              ["symlink:", File.read_link!(absolute)]

            %File.Stat{type: :regular} ->
              ["regular:", File.read!(absolute)]

            %File.Stat{type: type} ->
              Mix.raise("unsupported untracked file type #{type}: #{relative}")
          end

        framed([relative, content])
      end)

    [
      framed(["head_tree", head_tree]),
      framed(["staged", staged]),
      framed(["unstaged", unstaged]),
      framed(["untracked", untracked])
    ]
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp untracked_paths(root, git, opts) do
    root
    |> git.(["ls-files", "--others", "--exclude-standard", "-z"], opts)
    |> String.split(<<0>>, trim: true)
    |> Enum.sort()
  end

  defp framed(parts) when is_list(parts) do
    Enum.map(parts, fn part ->
      part = IO.iodata_to_binary(part)
      [Integer.to_string(byte_size(part)), ":", part, ";"]
    end)
  end

  defp file_digest(path) do
    if File.regular?(path) do
      path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    end
  end

  defp otp_version!(otp_release) do
    path = Path.join([to_string(:code.root_dir()), "releases", otp_release, "OTP_VERSION"])

    case File.read(path) do
      {:ok, version} ->
        case String.trim(version) do
          "" -> Mix.raise("OTP_VERSION is empty: #{path}")
          version -> version
        end

      {:error, reason} ->
        Mix.raise("unable to read full OTP version from #{path}: #{reason}")
    end
  end

  defp canonical_root!(root) do
    root = Path.expand(root)

    case System.cmd("pwd", ["-P"], cd: root, stderr_to_stdout: true) do
      {real, 0} ->
        String.trim(real)

      {output, status} ->
        Mix.raise("unable to resolve repository root (#{status}): #{String.trim(output)}")
    end
  end

  defp git!(root, args, _opts) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, status} ->
        Mix.raise("git #{Enum.join(args, " ")} failed (#{status}): #{String.trim(output)}")
    end
  end

  defp path(root, opts) do
    Keyword.get(opts, :path) ||
      Application.get_env(:allbert_assist, :preflight_attestation_path) ||
      Path.join(root, @relative_path)
  end

  defp maybe_add(errors, true, reason), do: errors ++ [reason]
  defp maybe_add(errors, false, _reason), do: errors

  defp now_iso8601,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
