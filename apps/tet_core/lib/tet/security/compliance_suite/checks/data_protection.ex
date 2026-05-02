defmodule Tet.Security.ComplianceSuite.Checks.DataProtection do
  @moduledoc """
  Data protection compliance checks — BD-0070.

  Secret redaction completeness and redacted-region patch rejection.
  """

  alias Tet.Security.SecretFuzzer
  alias Tet.SecurityPolicy
  alias Tet.SecurityPolicy.Evaluator
  alias Tet.SecurityPolicy.Profile
  alias Tet.Redactor
  alias Tet.Redactor.Inbound
  alias Tet.Secrets
  alias Tet.Patch
  alias Tet.Repair.PatchWorkflow
  alias Tet.Repair.PatchWorkflow.Gate, as: PatchGate
  alias Tet.Security.ComplianceSuite.Checks.Helpers

  @doc "Checks that all known secret patterns are detected and redacted."
  @spec check_secret_redaction() :: Tet.Security.ComplianceSuite.check_result()
  def check_secret_redaction do
    secret_variations = SecretFuzzer.generate_secret_variations()

    detection_failures =
      secret_variations
      |> Enum.reject(fn {value, _expected_type} -> Secrets.contains_secret?(value) end)
      |> Enum.map(fn {value, expected_type} ->
        %{
          value_preview: Helpers.preview(value),
          expected_type: expected_type,
          reason: :not_detected
        }
      end)

    redaction_failures =
      secret_variations
      |> Enum.filter(fn {value, _expected_type} ->
        redacted = Inbound.redact_for_provider(%{content: value})
        String.contains?(redacted.content, value)
      end)
      |> Enum.map(fn {value, expected_type} ->
        %{
          value_preview: Helpers.preview(value),
          expected_type: expected_type,
          reason: :not_redacted
        }
      end)

    clean_values = ["hello world", "the weather is nice", "user@example.com", "version 1.0.0"]

    false_positive_failures =
      clean_values
      |> Enum.filter(&Secrets.contains_secret?/1)
      |> Enum.map(fn value -> %{value: value, reason: :false_positive} end)

    sensitive_keys = [:api_key, :password, :secret_token, :authorization, "credential"]

    key_failures =
      sensitive_keys
      |> Enum.reject(&Redactor.sensitive_key?/1)
      |> Enum.map(fn key -> %{key: key, reason: :key_not_detected} end)

    partial_leak_failures = check_partial_leaks(secret_variations)

    all_failures =
      detection_failures ++
        redaction_failures ++
        false_positive_failures ++
        key_failures ++ partial_leak_failures

    Helpers.build_result(:secret_redaction, all_failures, %{
      secrets_tested: length(secret_variations),
      clean_tested: length(clean_values),
      keys_tested: length(sensitive_keys)
    })
  end

  @doc "Checks that patches involving redacted/secret content are gated."
  @spec check_redacted_region_patch() :: Tet.Security.ComplianceSuite.check_result()
  def check_redacted_region_patch do
    tests = [
      {:patch_always_deny,
       fn ->
         locked = Profile.new!(%{approval_mode: :always_deny, sandbox_profile: :locked_down})
         match?({:denied, _}, SecurityPolicy.check(:patch, %{repair_strategy: :patch}, locked))
       end},
      {:patch_needs_approval,
       fn ->
         default = Profile.default()

         match?(
           {:needs_approval, _},
           SecurityPolicy.check(:patch, %{repair_strategy: :patch}, default)
         )
       end},
      {:human_always_deny,
       fn ->
         default = Profile.default()
         match?({:denied, _}, SecurityPolicy.check(:repair, %{repair_strategy: :human}, default))
       end},
      {:sandbox_read_only_blocks_patch,
       fn ->
         read_only = Profile.new!(%{approval_mode: :auto_approve, sandbox_profile: :read_only})

         Evaluator.check_sandbox(
           :patch,
           %{path: "/workspace/file.ex", workspace_root: "/workspace"},
           read_only
         ) == {:denied, :sandbox_read_only}
       end},
      {:deny_glob_blocks_patch,
       fn ->
         deny_profile =
           Profile.new!(%{
             approval_mode: :auto_approve,
             sandbox_profile: :workspace_only,
             deny_globs: ["**/secrets/**"],
             allow_paths: ["**"]
           })

         match?(
           {:denied, :denied_by_glob},
           SecurityPolicy.check(
             :patch,
             %{path: "/workspace/secrets/credentials.yml", workspace_root: "/workspace"},
             deny_profile
           )
         )
       end},
      {:unapproved_workflow_cannot_patch,
       fn ->
         plan = %{description: "test", files: [], changes: []}

         pending_wf = %PatchWorkflow{
           id: "wf-1",
           repair_id: "rep-1",
           plan: plan,
           status: :pending_approval,
           checkpoint_id: nil,
           approval_id: nil
         }

         not PatchGate.can_patch?(pending_wf)
       end},
      redacted_patch_test(
        :redacted_old_str_rejected,
        :modify,
        %{old_str: "api_key=[REDACTED]", new_str: "api_key=sk-new"},
        {:error, {:invalid_operation, :redacted_region_in_old_str}}
      ),
      redacted_patch_test(
        :redacted_content_rejected,
        :modify,
        %{content: "api_key=[REDACTED]\nport=443"},
        {:error, {:invalid_operation, :redacted_region_in_content}}
      ),
      redacted_patch_test(
        :redacted_replacement_rejected,
        :modify,
        %{replacements: [%{old_str: "db_pass=[REDACTED]", new_str: "db_pass=newpass"}]},
        {:error, {:invalid_operation, :redacted_region_in_replacements}}
      ),
      redacted_patch_test(
        :lowercase_redacted_rejected,
        :modify,
        %{old_str: "secret=[redacted]", new_str: "secret=dev"},
        {:error, {:invalid_operation, :redacted_region_in_old_str}}
      ),
      {:clean_patch_allowed,
       fn ->
         match?(
           {:ok, _},
           Patch.propose(%{
             workspace_path: "/workspace",
             operations: [
               %{
                 kind: :modify,
                 file_path: "lib/app.ex",
                 old_str: "defmodule App",
                 new_str: "defmodule MyApp"
               }
             ]
           })
         )
       end}
    ]

    failures = Helpers.run_assertions(tests)
    Helpers.build_result(:redacted_region_patch, failures, %{tests_run: length(tests)})
  end

  # --- Private helpers ---

  defp check_partial_leaks(secret_variations) do
    secret_prefixes = [
      "sk-",
      "AKIA",
      "ghp_",
      "gho_",
      "ghs_",
      "xoxb-",
      "xoxa-",
      "xoxp-",
      "Bearer ",
      "-----BEGIN",
      "postgresql://",
      "postgres://",
      "mongodb://",
      "mysql://",
      "redis://",
      "amqp://",
      "mssql://"
    ]

    is_standalone_secret = fn value ->
      Enum.any?(secret_prefixes, &String.starts_with?(value, &1))
    end

    secret_variations
    |> Enum.filter(fn {value, expected_type} ->
      expected_type in [:api_key, :token, :connection_string, :private_key, :password] and
        Secrets.contains_secret?(value) and String.length(value) >= 20 and
        is_standalone_secret.(value)
    end)
    |> Enum.filter(fn {value, _expected_type} ->
      redacted = Inbound.redact_for_provider(%{content: value})
      prefix = String.slice(value, 0, 8)
      suffix = String.slice(value, -8, 8)
      String.contains?(redacted.content, prefix) and String.contains?(redacted.content, suffix)
    end)
    |> Enum.map(fn {value, expected_type} ->
      %{
        value_preview: Helpers.preview(value),
        expected_type: expected_type,
        reason: :partial_leak
      }
    end)
  end

  # Helper to build redacted patch test tuples
  defp redacted_patch_test(name, kind, extra_attrs, expected_error) do
    {name,
     fn ->
       attrs = Map.merge(%{kind: kind, file_path: "config/prod.exs"}, extra_attrs)

       match?(
         ^expected_error,
         Patch.propose(%{workspace_path: "/workspace", operations: [attrs]})
       )
     end}
  end
end
