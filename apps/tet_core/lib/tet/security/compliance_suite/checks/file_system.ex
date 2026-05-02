defmodule Tet.Security.ComplianceSuite.Checks.FileSystem do
  @moduledoc """
  Filesystem-related compliance checks — BD-0070.

  Path traversal prevention and sandbox boundary enforcement.
  """

  alias Tet.Security.PathFuzzer
  alias Tet.SecurityPolicy.Evaluator
  alias Tet.SecurityPolicy.Profile

  @doc "Checks that path traversal attacks are blocked after URL-decode normalization."
  @spec check_path_traversal() :: Tet.Security.ComplianceSuite.check_result()
  def check_path_traversal do
    workspace = "/workspace"

    profile =
      Profile.new!(%{
        approval_mode: :auto_approve,
        sandbox_profile: :workspace_only,
        allow_paths: ["#{workspace}/**"],
        deny_globs: []
      })

    attacks = PathFuzzer.generate_traversal_attempts()

    failures =
      attacks
      |> Enum.filter(fn attack ->
        normalized = PathFuzzer.normalize_encoded_path(attack)
        context = %{path: normalized, workspace_root: workspace}
        sandbox_result = Evaluator.check_sandbox(:read, context, profile)

        case sandbox_result do
          {:denied, _} -> false
          :allowed -> not path_under_workspace?(resolve_path(normalized, workspace), workspace)
        end
      end)
      |> Enum.map(fn attack ->
        normalized = PathFuzzer.normalize_encoded_path(attack)
        %{attack: attack, normalized: normalized, reason: :escaped_containment}
      end)

    encoded_failures = check_encoded_vectors(workspace, profile)
    nul_failures = check_nul_byte_vectors(workspace, profile)

    all_failures = failures ++ encoded_failures ++ nul_failures

    Tet.Security.ComplianceSuite.Checks.Helpers.build_result(:path_traversal, all_failures, %{
      total_attacks: length(attacks),
      encoded_vectors_tested: 3,
      nul_byte_payloads_present:
        Enum.any?(PathFuzzer.generate_traversal_attempts(), &String.contains?(&1, <<0>>))
    })
  end

  @doc "Checks that sandbox profiles correctly constrain filesystem and network access."
  @spec check_sandbox_boundary() :: Tet.Security.ComplianceSuite.check_result()
  def check_sandbox_boundary do
    workspace = "/workspace"

    tests = [
      {:locked_down_read,
       fn ->
         locked = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :locked_down})

         Evaluator.check_sandbox(:read, %{workspace_root: workspace}, locked) ==
           {:denied, :sandbox_locked_down}
       end},
      {:read_only_write,
       fn ->
         read_only = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :read_only})

         Evaluator.check_sandbox(
           :write,
           %{workspace_root: workspace, path: "#{workspace}/f.ex"},
           read_only
         ) == {:denied, :sandbox_read_only}
       end},
      {:no_network_network_action,
       fn ->
         no_net = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :no_network})

         Evaluator.check_sandbox(:network, %{workspace_root: workspace}, no_net) ==
           {:denied, :sandbox_no_network}
       end},
      {:workspace_only_external_path,
       fn ->
         ws_only = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :workspace_only})

         Evaluator.check_sandbox(
           :read,
           %{path: "/etc/passwd", workspace_root: workspace},
           ws_only
         ) == {:denied, :sandbox_workspace_only}
       end},
      {:unrestricted_allows,
       fn ->
         unrestricted =
           Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :unrestricted})

         Evaluator.check_sandbox(
           :read,
           %{path: "/etc/passwd", workspace_root: workspace},
           unrestricted
         ) == :allowed
       end}
    ]

    failures = Tet.Security.ComplianceSuite.Checks.Helpers.run_assertions(tests)

    Tet.Security.ComplianceSuite.Checks.Helpers.build_result(:sandbox_boundary, failures, %{
      profiles_tested: length(tests)
    })
  end

  # --- Private helpers ---

  defp check_encoded_vectors(workspace, profile) do
    encoded_vectors = [
      {"..%2f..%2f..%2fetc%2fpasswd", "../../etc/passwd"},
      {"%2e%2e%2f%2e%2e%2f%2e%2e%2fetc%2fpasswd", "../../etc/passwd"},
      {"..%252f..%252fetc%252fpasswd", "../../etc/passwd"}
    ]

    encoded_vectors
    |> Enum.filter(fn {raw, _decoded} ->
      normalized = PathFuzzer.normalize_encoded_path(raw)
      context = %{path: normalized, workspace_root: workspace}
      sandbox_result = Evaluator.check_sandbox(:read, context, profile)

      case sandbox_result do
        {:denied, _} -> false
        :allowed -> not path_under_workspace?(resolve_path(normalized, workspace), workspace)
      end
    end)
    |> Enum.map(fn {raw, decoded} ->
      %{attack: raw, decoded_to: decoded, reason: :encoded_traversal_not_blocked}
    end)
  end

  defp check_nul_byte_vectors(workspace, profile) do
    if Enum.any?(PathFuzzer.generate_traversal_attempts(), &String.contains?(&1, <<0>>)) do
      PathFuzzer.generate_traversal_attempts()
      |> Enum.filter(&String.contains?(&1, <<0>>))
      |> Enum.filter(fn attack ->
        normalized = PathFuzzer.normalize_encoded_path(attack)
        context = %{path: normalized, workspace_root: workspace}
        sandbox_result = Evaluator.check_sandbox(:read, context, profile)

        case sandbox_result do
          {:denied, _} -> false
          :allowed -> true
        end
      end)
      |> Enum.map(fn attack ->
        %{attack: inspect(attack), reason: :null_byte_not_blocked}
      end)
    else
      [%{reason: :no_nul_byte_payloads_generated}]
    end
  end

  defp resolve_path(path, workspace) do
    normalised = String.replace(path, "\\", "/")

    if String.starts_with?(normalised, "/") do
      canonicalise_segments(normalised, true)
    else
      canonicalise_segments(workspace <> "/" <> normalised, true)
    end
  end

  defp canonicalise_segments(path, absolute?) do
    segments = String.split(path, "/")

    resolved =
      Enum.reduce(segments, [], fn
        "", acc -> acc
        ".", acc -> acc
        "..", [] when absolute? -> []
        "..", [] -> [".."]
        "..", [".." | _] = acc when not absolute? -> [".." | acc]
        "..", [_ | rest] -> rest
        segment, acc -> [segment | acc]
      end)
      |> Enum.reverse()
      |> Enum.join("/")

    if absolute? and resolved == "",
      do: "/",
      else: if(absolute?, do: "/" <> resolved, else: resolved)
  end

  defp path_under_workspace?(resolved, workspace) do
    resolved == workspace or String.starts_with?(resolved, workspace <> "/")
  end
end
