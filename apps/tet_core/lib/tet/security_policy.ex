defmodule Tet.SecurityPolicy do
  @moduledoc """
  Security policy matrix — BD-0067.

  Central policy matrix that defines and enforces the complete security
  posture across all dimensions: approval modes, sandbox profiles, deny/allow
  precedence, MCP trust, remote trust, and repair policy.

  ## Architecture

  This module is the **facade** — it delegates to:

    - `Tet.SecurityPolicy.Profile` — the policy configuration struct.
    - `Tet.SecurityPolicy.Evaluator` — the core deny-beats-allow logic.

  ## Approval modes

    - `:auto_approve` — all actions allowed unless explicitly denied.
    - `:suggest_approve` — most actions allowed but operator is prompted.
    - `:require_approve` — every action needs explicit approval.
    - `:always_deny` — nothing is allowed, full lockdown.

  ## Sandbox profiles

    - `:unrestricted` — no filesystem or network constraints.
    - `:workspace_only` — paths must be under workspace root.
    - `:read_only` — workspace-only plus no write operations.
    - `:no_network` — no network access, filesystem follows workspace_only.
    - `:locked_down` — all filesystem and network access denied.

  ## Deny/allow precedence

  **Deny always beats allow.** If a path matches any deny glob, it is denied
  even if it also matches an allow path. This is the single most important
  invariant of the policy matrix.

  ## MCP trust

  Maps to `Tet.Mcp.Classification` categories. The profile's `mcp_trust`
  field sets the maximum category allowed without explicit approval.

  ## Remote trust

  Maps to `Tet.Remote.TrustBoundary` levels. The profile's `remote_trust`
  field sets the minimum trust level required for remote operations.

  ## Repair policy

  Maps repair strategies (`:retry`, `:fallback`, `:patch`, `:human`) to
  required approval modes. More dangerous strategies require higher approval.

  This module is pure data and pure functions. No side effects, no IO,
  no GenServer.
  """

  alias Tet.SecurityPolicy.Profile
  alias Tet.SecurityPolicy.Evaluator

  # --- Delegates to Profile ---

  @doc "Returns all valid approval modes."
  @spec approval_modes() :: [Profile.approval_mode()]
  def approval_modes, do: Profile.approval_modes()

  @doc "Returns all valid sandbox profiles."
  @spec sandbox_profiles() :: [Profile.sandbox_profile()]
  def sandbox_profiles, do: Profile.sandbox_profiles()

  @doc "Delegates to `Profile.new/1`."
  defdelegate new_profile(attrs), to: Profile, as: :new

  @doc "Delegates to `Profile.new!/1`."
  defdelegate new_profile!(attrs), to: Profile, as: :new!

  @doc "Delegates to `Profile.default/0`."
  defdelegate default_profile, to: Profile, as: :default

  @doc "Delegates to `Profile.permissive/0`."
  defdelegate permissive_profile, to: Profile, as: :permissive

  @doc "Delegates to `Profile.locked_down/0`."
  defdelegate locked_down_profile, to: Profile, as: :locked_down

  @doc "Delegates to `Profile.merge/2`."
  defdelegate merge_profiles(base, override), to: Profile, as: :merge

  @doc "Delegates to `Profile.to_map/1`."
  defdelegate profile_to_map(profile), to: Profile, as: :to_map

  # --- Delegates to Evaluator ---

  @doc """
  Evaluates (action, context, profile) → allowed/denied/needs_approval.

  This is the **primary entry point** for all policy decisions.

  ## Examples

      iex> profile = Tet.SecurityPolicy.permissive_profile()
      iex> Tet.SecurityPolicy.check(:read, %{mcp_category: :read}, profile)
      :allowed

      iex> profile = Tet.SecurityPolicy.locked_down_profile()
      iex> Tet.SecurityPolicy.check(:read, %{}, profile)
      {:denied, :always_deny_mode}
  """
  defdelegate check(action, context, profile), to: Evaluator

  @doc "Batch-evaluates a list of actions."
  defdelegate check_all(actions_with_context, profile), to: Evaluator

  @doc "Checks whether a path is denied by any deny glob."
  defdelegate denied_by_glob?(path, deny_globs), to: Evaluator

  @doc "Checks whether a path is allowed by any allow path."
  defdelegate allowed_by_path?(path, allow_paths), to: Evaluator

  @doc "Checks MCP category against profile's MCP trust level."
  defdelegate check_mcp(category, profile), to: Evaluator

  @doc "Checks a remote operation against profile's remote trust level."
  defdelegate check_remote(operation, trust_level, profile), to: Evaluator

  @doc "Checks sandbox profile constraints for an action."
  defdelegate check_sandbox(action, context, profile), to: Evaluator

  @doc "Checks a repair strategy against profile's repair approval mapping."
  defdelegate check_repair(strategy, profile), to: Evaluator

  @doc "Checks the approval mode directly."
  defdelegate check_approval_mode(mode), to: Evaluator

  # --- Policy matrix overview ---

  @doc """
  Returns the complete policy matrix as a map for introspection.

  This is useful for logging, telemetry, and debugging. It shows the
  full decision matrix without revealing secrets.
  """
  @spec matrix(Profile.t()) :: map()
  def matrix(%Profile{} = profile) do
    %{
      approval_mode: %{
        mode: profile.approval_mode,
        ranking: Profile.approval_ranking(profile.approval_mode),
        description: approval_mode_description(profile.approval_mode)
      },
      sandbox: %{
        profile: profile.sandbox_profile,
        ranking: Profile.sandbox_ranking(profile.sandbox_profile),
        description: sandbox_description(profile.sandbox_profile)
      },
      deny_allow: %{
        deny_globs: profile.deny_globs,
        allow_paths: profile.allow_paths,
        rule: "deny always beats allow"
      },
      mcp_trust: %{
        max_category: profile.mcp_trust,
        risk_level: Tet.Mcp.Classification.risk_level(profile.mcp_trust)
      },
      remote_trust: %{
        min_level: profile.remote_trust,
        ranking: Tet.Remote.TrustBoundary.trust_ranking(profile.remote_trust)
      },
      repair_approval: profile.repair_approval
    }
  end

  @doc "Returns the preset profiles for common task categories."
  @spec task_presets() :: %{atom() => Profile.t()}
  def task_presets do
    %{
      researching:
        Profile.new!(%{
          approval_mode: :suggest_approve,
          sandbox_profile: :read_only,
          mcp_trust: :read,
          remote_trust: :untrusted_remote,
          repair_approval: %{
            retry: :suggest_approve,
            fallback: :require_approve,
            patch: :always_deny,
            human: :always_deny
          }
        }),
      planning:
        Profile.new!(%{
          approval_mode: :suggest_approve,
          sandbox_profile: :read_only,
          mcp_trust: :read,
          remote_trust: :untrusted_remote,
          repair_approval: %{
            retry: :suggest_approve,
            fallback: :require_approve,
            patch: :always_deny,
            human: :always_deny
          }
        }),
      acting:
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only,
          mcp_trust: :write,
          remote_trust: :trusted_remote,
          repair_approval: %{
            retry: :auto_approve,
            fallback: :suggest_approve,
            patch: :require_approve,
            human: :always_deny
          }
        }),
      verifying:
        Profile.new!(%{
          approval_mode: :suggest_approve,
          sandbox_profile: :read_only,
          mcp_trust: :read,
          remote_trust: :untrusted_remote,
          repair_approval: %{
            retry: :auto_approve,
            fallback: :suggest_approve,
            patch: :require_approve,
            human: :always_deny
          }
        }),
      debugging:
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only,
          mcp_trust: :write,
          remote_trust: :trusted_remote,
          repair_approval: %{
            retry: :auto_approve,
            fallback: :suggest_approve,
            patch: :require_approve,
            human: :always_deny
          }
        }),
      documenting:
        Profile.new!(%{
          approval_mode: :suggest_approve,
          sandbox_profile: :workspace_only,
          mcp_trust: :write,
          remote_trust: :untrusted_remote,
          repair_approval: %{
            retry: :auto_approve,
            fallback: :suggest_approve,
            patch: :require_approve,
            human: :always_deny
          }
        })
    }
  end

  # --- Private: descriptions ---

  defp approval_mode_description(:auto_approve),
    do: "All actions allowed unless explicitly denied"

  defp approval_mode_description(:suggest_approve),
    do: "Most actions allowed, operator prompted for confirmation"

  defp approval_mode_description(:require_approve),
    do: "Every action requires explicit approval"

  defp approval_mode_description(:always_deny),
    do: "Nothing is allowed, full lockdown"

  defp sandbox_description(:unrestricted), do: "No filesystem or network constraints"
  defp sandbox_description(:workspace_only), do: "Paths must be under workspace root"
  defp sandbox_description(:read_only), do: "Workspace-only, no write operations"
  defp sandbox_description(:no_network), do: "No network access, workspace-only filesystem"
  defp sandbox_description(:locked_down), do: "All filesystem and network access denied"
end
