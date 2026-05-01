defmodule Tet.ShellPolicy.Artifact do
  @moduledoc """
  Structured artifact for captured shell/git/test execution output — BD-0029.

  Every verifier or shell execution result is captured as an artifact with
  the command vector, risk level, exit status, output streams, timing, and
  correlation metadata. This enables the runtime to persist execution
  results for audit, replay, and verifier feedback.

  This module is pure data and pure functions. It does not execute commands,
  touch the filesystem, shell out, or persist events.
  """

  @enforce_keys [:command, :risk, :exit_code, :stdout, :cwd, :duration_ms, :tool_call_id]
  defstruct [
    :command,
    :risk,
    :exit_code,
    :stdout,
    :stderr,
    :cwd,
    :duration_ms,
    :tool_call_id,
    id: nil,
    session_id: nil,
    task_id: nil,
    successful: false,
    metadata: %{}
  ]

  @type risk :: :read | :low | :medium | :high
  @type t :: %__MODULE__{
          command: [String.t()],
          risk: risk(),
          exit_code: non_neg_integer(),
          stdout: String.t(),
          stderr: String.t(),
          cwd: String.t(),
          duration_ms: non_neg_integer(),
          tool_call_id: String.t(),
          id: String.t() | nil,
          session_id: String.t() | nil,
          task_id: String.t() | nil,
          successful: boolean(),
          metadata: map()
        }

  @doc """
  Builds a validated artifact from attributes.

  Required fields: `:command`, `:risk`, `:exit_code`, `:stdout`,
  `:cwd`, `:duration_ms`, `:tool_call_id`.

  > Note: `stderr` is always set to `""` by the runner since stderr is
  > merged into stdout via `stderr_to_stdout: true`. It is retained in
  > the struct for schema compatibility but is not required at creation.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, command} <- fetch_command(attrs),
         {:ok, risk} <- fetch_risk(attrs),
         {:ok, exit_code} <- fetch_exit_code(attrs),
         {:ok, stdout} <- fetch_string(attrs, :stdout, ""),
         {:ok, stderr} <- fetch_string(attrs, :stderr, ""),
         {:ok, cwd} <- fetch_string(attrs, :cwd),
         {:ok, duration_ms} <- fetch_duration(attrs),
         {:ok, tool_call_id} <- fetch_string(attrs, :tool_call_id),
         {:ok, id} <- fetch_optional_string(attrs, :id),
         {:ok, session_id} <- fetch_optional_string(attrs, :session_id),
         {:ok, task_id} <- fetch_optional_string(attrs, :task_id),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}) do
      successful = exit_code == 0
      id = id || tool_call_id

      {:ok,
       %__MODULE__{
         command: command,
         risk: risk,
         exit_code: exit_code,
         stdout: stdout,
         stderr: stderr,
         cwd: cwd,
         duration_ms: duration_ms,
         tool_call_id: tool_call_id,
         id: id,
         session_id: session_id,
         task_id: task_id,
         successful: successful,
         metadata: metadata
       }}
    end
  end

  @doc "Builds an artifact or raises."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, artifact} -> artifact
      {:error, reason} -> raise ArgumentError, "invalid shell policy artifact: #{inspect(reason)}"
    end
  end

  @doc "Converts an artifact to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = artifact) do
    %{
      id: artifact.id,
      command: artifact.command,
      risk: Atom.to_string(artifact.risk),
      exit_code: artifact.exit_code,
      stdout: artifact.stdout,
      stderr: artifact.stderr,
      cwd: artifact.cwd,
      duration_ms: artifact.duration_ms,
      tool_call_id: artifact.tool_call_id,
      task_id: artifact.task_id,
      session_id: artifact.session_id,
      successful: artifact.successful,
      metadata: artifact.metadata
    }
  end

  # -- Validators --

  defp fetch_command(attrs) do
    command = Map.get(attrs, :command, Map.get(attrs, "command"))

    cond do
      is_list(command) and length(command) > 0 and Enum.all?(command, &is_binary/1) ->
        {:ok, command}

      true ->
        {:error, {:invalid_artifact_field, :command}}
    end
  end

  defp fetch_risk(attrs) do
    risk = Map.get(attrs, :risk, Map.get(attrs, "risk"))
    risk = if is_binary(risk), do: String.to_existing_atom(risk), else: risk

    if risk in [:read, :low, :medium, :high] do
      {:ok, risk}
    else
      {:error, {:invalid_artifact_field, :risk}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_artifact_field, :risk}}
  end

  defp fetch_exit_code(attrs) do
    exit_code = Map.get(attrs, :exit_code, Map.get(attrs, "exit_code"))

    if is_integer(exit_code) and exit_code >= 0 do
      {:ok, exit_code}
    else
      {:error, {:invalid_artifact_field, :exit_code}}
    end
  end

  defp fetch_string(attrs, key, default \\ nil) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

    cond do
      is_nil(value) and not is_nil(default) -> {:ok, value}
      is_binary(value) -> {:ok, value}
      is_nil(value) -> {:error, {:invalid_artifact_field, key}}
      true -> {:ok, to_string(value)}
    end
  end

  defp fetch_optional_string(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    cond do
      is_nil(value) -> {:ok, nil}
      is_binary(value) and value == "" -> {:ok, nil}
      is_binary(value) -> {:ok, value}
      true -> {:ok, to_string(value)}
    end
  end

  defp fetch_duration(attrs) do
    duration = Map.get(attrs, :duration_ms, Map.get(attrs, "duration_ms"))

    if is_integer(duration) and duration >= 0 do
      {:ok, duration}
    else
      {:error, {:invalid_artifact_field, :duration_ms}}
    end
  end

  defp fetch_map(attrs, key, default) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

    if is_map(value) do
      {:ok, value}
    else
      {:error, {:invalid_artifact_field, key}}
    end
  end
end
