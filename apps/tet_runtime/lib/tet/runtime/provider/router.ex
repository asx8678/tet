defmodule Tet.Runtime.Provider.Router do
  @moduledoc """
  Deterministic provider router with retry, fallback, audit events, and telemetry.

  The router is opt-in and implements `Tet.Provider`, so direct provider behavior
  stays boring and untouched. Candidate order is deterministic: explicit
  `:routing_key`, then `:session_id`, then `:request_id`, otherwise candidate 0.
  No randomness, no hidden GenServer state, no spooky action at a distance.
  """

  @behaviour Tet.Provider

  alias Tet.Runtime.{Ids, Telemetry}
  alias Tet.Runtime.Provider.Error
  alias Tet.Runtime.Provider.Router.Candidates

  @route_decision_event [:tet, :provider, :router, :decision]
  @route_attempt_start_event [:tet, :provider, :router, :attempt, :start]
  @route_attempt_stop_event [:tet, :provider, :router, :attempt, :stop]
  @route_attempt_error_event [:tet, :provider, :router, :attempt, :error]
  @route_retry_event [:tet, :provider, :router, :retry]
  @route_fallback_event [:tet, :provider, :router, :fallback]
  @route_stop_event [:tet, :provider, :router, :stop]
  @route_error_event [:tet, :provider, :router, :error]

  @impl true
  def stream_chat(messages, opts, emit)
      when is_list(messages) and is_list(opts) and is_function(emit, 1) do
    order_opts = opts
    opts = Keyword.put_new(opts, :request_id, Ids.request_id())

    case route_order(Keyword.get(opts, :candidates, []), order_opts) do
      {:ok, []} ->
        fail_before_attempt(:no_provider_candidates, opts, emit)

      {:ok, ordered_candidates} ->
        route_started_at = System.monotonic_time()
        emit_decision(ordered_candidates, order_opts, opts, emit)

        {skipped_candidates, viable_candidates} =
          split_config_error_candidates(ordered_candidates)

        with_usage_collector(fn collector ->
          wrapped_emit = fn event ->
            collect_provider_event(collector, event)
            emit.(event)
          end

          emit_config_error_skips(
            skipped_candidates,
            List.first(viable_candidates),
            opts,
            wrapped_emit
          )

          case viable_candidates do
            [] ->
              fail_before_attempt(
                no_viable_candidates_reason(skipped_candidates),
                opts,
                wrapped_emit
              )

            candidates ->
              route_candidates(messages, candidates, opts, wrapped_emit, collector, %{
                route_attempt: 0,
                route_started_at: route_started_at
              })
          end
        end)

      {:error, reason} ->
        fail_before_attempt(reason, opts, emit)
    end
  end

  @doc "Returns candidates rotated by the deterministic routing offset."
  defdelegate route_order(candidates, opts \\ []), to: Candidates

  @doc "Returns the deterministic start index for a candidate count and routing opts."
  defdelegate start_index(candidate_count, opts \\ []), to: Candidates

  defp split_config_error_candidates(candidates) do
    Enum.split_with(candidates, &config_error_candidate?/1)
  end

  defp config_error_candidate?(%{config_error: config_error}), do: not is_nil(config_error)
  defp config_error_candidate?(_candidate), do: false

  defp emit_config_error_skips([], _next_candidate, _opts, _emit), do: :ok

  defp emit_config_error_skips(skipped_candidates, next_candidate, opts, emit) do
    Enum.each(skipped_candidates, fn candidate ->
      reason = {:provider_candidate_config, candidate.config_error}

      context =
        candidate
        |> skip_context(opts)
        |> Map.merge(%{
          terminal?: false,
          will_retry?: false,
          will_fallback?: not is_nil(next_candidate),
          exhausted?: false
        })

      error = Map.merge(context, error_payload(reason, Error.kind(reason), false))

      emit_route_event(:provider_route_error, error, opts, emit)
      Telemetry.execute(@route_attempt_error_event, %{}, error, opts)

      if next_candidate do
        fallback = fallback_payload(context, next_candidate, reason, false)

        emit_route_event(:provider_route_fallback, fallback, opts, emit)
        Telemetry.execute(@route_fallback_event, %{}, fallback, opts)
      end
    end)
  end

  defp no_viable_candidates_reason(skipped_candidates) do
    {:provider_candidate_config,
     {:no_viable_candidates, Enum.map(skipped_candidates, &config_error_summary/1)}}
  end

  defp config_error_summary(candidate) do
    %{
      candidate_index: candidate.index,
      id: candidate.id,
      provider: candidate.provider,
      model: candidate.model,
      detail: Error.detail({:provider_candidate_config, candidate.config_error})
    }
    |> compact_map()
  end

  defp route_candidates(messages, [candidate | rest], opts, emit, collector, state) do
    has_next? = rest != []

    case attempt_candidate(candidate, messages, opts, emit, collector, state, 1, has_next?) do
      {:ok, response, state, context} ->
        response = routed_response(response, candidate)
        route_duration = elapsed_since(state.route_started_at)
        payload = route_done_payload(context, response, route_duration)

        emit_route_event(:provider_route_done, payload, opts, emit)
        emit_route_stop_telemetry(payload, route_duration, opts)

        {:ok, response}

      {:error, reason, state, %{retryable?: true} = context} when has_next? ->
        next_candidate = List.first(rest)
        payload = fallback_payload(context, next_candidate, reason)

        emit_route_event(:provider_route_fallback, payload, opts, emit)
        Telemetry.execute(@route_fallback_event, %{}, payload, opts)

        route_candidates(messages, rest, opts, emit, collector, state)

      {:error, reason, state, context} ->
        route_duration = elapsed_since(state.route_started_at)
        payload = final_error_payload(context, reason, route_duration)

        Telemetry.execute(
          @route_error_event,
          duration_measurements(route_duration),
          payload,
          opts
        )

        {:error, reason}
    end
  end

  defp attempt_candidate(candidate, messages, opts, emit, collector, state, attempt, has_next?) do
    route_attempt = state.route_attempt + 1
    state = %{state | route_attempt: route_attempt}
    context = attempt_context(candidate, opts, attempt, route_attempt)

    emit_route_event(:provider_route_attempt, context, opts, emit)

    Telemetry.execute(
      @route_attempt_start_event,
      %{system_time: System.system_time()},
      context,
      opts
    )

    reset_usage(collector)
    started_at = System.monotonic_time()
    result = invoke_candidate(candidate, messages, opts, emit)
    duration = elapsed_since(started_at)
    usage = usage(collector)

    context =
      context
      |> Map.merge(usage_payload(candidate, usage))
      |> Map.put(:duration_ms, duration_ms(duration))

    case result do
      {:ok, response} ->
        Telemetry.execute(
          @route_attempt_stop_event,
          attempt_measurements(duration, usage, candidate),
          context,
          opts
        )

        {:ok, response, state, context}

      {:error, reason} ->
        kind = Error.kind(reason)
        retryable? = Error.retryable?(kind, reason)
        will_retry? = retryable? and attempt <= max_retries(opts)
        will_fallback? = retryable? and not will_retry? and has_next?

        error_payload =
          context
          |> Map.merge(error_payload(reason, kind, retryable?))
          |> Map.merge(%{
            terminal?: not will_retry? and not will_fallback?,
            will_retry?: will_retry?,
            will_fallback?: will_fallback?,
            exhausted?: retryable? and not will_retry? and not will_fallback?
          })

        emit_route_event(:provider_route_error, error_payload, opts, emit)

        Telemetry.execute(
          @route_attempt_error_event,
          attempt_measurements(duration, usage, candidate),
          error_payload,
          opts
        )

        if will_retry? do
          retry_payload = Map.merge(error_payload, %{next_attempt: attempt + 1})
          emit_route_event(:provider_route_retry, retry_payload, opts, emit)
          Telemetry.execute(@route_retry_event, %{}, retry_payload, opts)
          sleep_retry_delay(opts)

          attempt_candidate(
            candidate,
            messages,
            opts,
            emit,
            collector,
            state,
            attempt + 1,
            has_next?
          )
        else
          {:error, reason, state, error_payload}
        end
    end
  end

  defp invoke_candidate(%{config_error: config_error}, _messages, _opts, _emit)
       when not is_nil(config_error) do
    {:error, {:provider_candidate_config, config_error}}
  end

  defp invoke_candidate(%{adapter: adapter} = candidate, messages, opts, emit) do
    provider_opts = provider_opts(candidate, opts)
    adapter.stream_chat(messages, provider_opts, emit)
  rescue
    exception -> {:error, {:provider_adapter_exception, Exception.message(exception)}}
  catch
    kind, value -> {:error, {:provider_adapter_exit, kind, value}}
  end

  defp provider_opts(candidate, opts) do
    shared_opts = Keyword.take(opts, [:request_id, :session_id])
    Keyword.merge(candidate.opts, shared_opts)
  end

  defp emit_decision(ordered_candidates, order_opts, opts, emit) do
    seed = Candidates.routing_seed(order_opts)

    payload = %{
      request_id: Keyword.get(opts, :request_id),
      candidate_count: length(ordered_candidates),
      viable_candidate_count: Enum.count(ordered_candidates, &(not config_error_candidate?(&1))),
      config_error_count: Enum.count(ordered_candidates, &config_error_candidate?/1),
      start_index: start_index(length(ordered_candidates), order_opts),
      routing_key_source: Candidates.seed_source(seed),
      routing_key_hash: Candidates.seed_hash(seed),
      candidates: Enum.map(ordered_candidates, &candidate_summary/1),
      reason: Candidates.seed_source(seed) || :first_candidate
    }

    emit_route_event(:provider_route_decision, payload, opts, emit)
    Telemetry.execute(@route_decision_event, %{system_time: System.system_time()}, payload, opts)
  end

  defp fail_before_attempt(reason, opts, emit) do
    kind = Error.kind(reason)

    payload =
      %{
        request_id: Keyword.get(opts, :request_id),
        kind: kind,
        detail: Error.detail(reason),
        retryable?: false,
        terminal?: true,
        will_retry?: false,
        will_fallback?: false,
        exhausted?: false
      }
      |> compact_map()

    emit_route_event(:provider_route_error, payload, opts, emit)
    Telemetry.execute(@route_error_event, %{}, payload, opts)

    {:error, reason}
  end

  defp candidate_summary(candidate) do
    %{
      candidate_index: candidate.index,
      id: candidate.id,
      provider: candidate.provider,
      model: candidate.model,
      config_error?: not is_nil(candidate.config_error)
    }
    |> compact_map()
  end

  defp attempt_context(candidate, opts, attempt, route_attempt) do
    candidate_summary(candidate)
    |> Map.merge(%{
      attempt: attempt,
      route_attempt: route_attempt,
      request_id: Keyword.get(opts, :request_id),
      retry?: attempt > 1,
      fallback?: route_attempt > attempt
    })
    |> compact_map()
  end

  defp skip_context(candidate, opts) do
    candidate_summary(candidate)
    |> Map.merge(%{
      request_id: Keyword.get(opts, :request_id),
      skipped?: true,
      skip_reason: :candidate_config_error
    })
    |> compact_map()
  end

  defp error_payload(reason, kind, retryable?) do
    %{
      kind: kind,
      detail: Error.detail(reason),
      retryable?: retryable?
    }
  end

  defp fallback_payload(context, next_candidate, reason, retryable? \\ true) do
    context
    |> Map.merge(error_payload(reason, Error.kind(reason), retryable?))
    |> Map.merge(%{
      terminal?: false,
      will_retry?: false,
      will_fallback?: true,
      next_candidate_index: next_candidate.index,
      next_provider: next_candidate.provider,
      next_model: next_candidate.model
    })
    |> compact_map()
  end

  defp route_done_payload(context, response, route_duration) do
    context
    |> Map.merge(%{
      terminal?: true,
      content_bytes: byte_size(Map.get(response, :content, "")),
      route_duration_ms: duration_ms(route_duration)
    })
    |> compact_map()
  end

  defp final_error_payload(context, reason, route_duration) do
    context
    |> Map.merge(error_payload(reason, Error.kind(reason), Error.retryable?(reason)))
    |> Map.merge(%{
      terminal?: true,
      route_duration_ms: duration_ms(route_duration)
    })
    |> compact_map()
  end

  defp routed_response(response, candidate) when is_map(response) do
    response
    |> Map.put(:provider, Map.get(response, :provider, candidate.provider))
    |> Map.put_new(:model, candidate.model)
  end

  defp routed_response(response, candidate) do
    %{
      content: to_string(response),
      provider: candidate.provider,
      model: candidate.model,
      metadata: %{}
    }
  end

  defp with_usage_collector(fun) do
    {:ok, collector} = Agent.start_link(fn -> %{} end)

    try do
      fun.(collector)
    after
      Agent.stop(collector)
    end
  end

  defp collect_provider_event(collector, %Tet.Event{type: :provider_usage, payload: payload}) do
    Agent.update(collector, fn _usage -> extract_usage(payload) end)
  end

  defp collect_provider_event(_collector, _event), do: :ok

  defp reset_usage(collector), do: Agent.update(collector, fn _usage -> %{} end)
  defp usage(collector), do: Agent.get(collector, & &1)

  defp extract_usage(payload) when is_map(payload) do
    %{}
    |> put_usage(:input_tokens, payload)
    |> put_usage(:output_tokens, payload)
    |> put_usage(:total_tokens, payload)
    |> put_usage(:cost, payload)
  end

  defp put_usage(acc, key, payload) do
    case Map.get(payload, key, Map.get(payload, Atom.to_string(key))) do
      value when is_integer(value) and value >= 0 -> Map.put(acc, key, value)
      value when is_float(value) and value >= 0 -> Map.put(acc, key, value)
      _value -> acc
    end
  end

  defp usage_payload(candidate, usage) do
    cost = estimated_cost(candidate, usage)

    %{
      usage: usage,
      estimated_cost: cost
    }
    |> compact_map()
  end

  defp attempt_measurements(duration, usage, candidate) do
    usage_payload = usage_payload(candidate, usage)

    %{
      duration: duration,
      duration_ms: duration_ms(duration),
      input_tokens: Map.get(usage, :input_tokens),
      output_tokens: Map.get(usage, :output_tokens),
      total_tokens: Map.get(usage, :total_tokens),
      estimated_cost: Map.get(usage_payload, :estimated_cost)
    }
  end

  defp emit_route_stop_telemetry(payload, route_duration, opts) do
    measurements =
      payload
      |> Map.get(:usage, %{})
      |> Map.take([:input_tokens, :output_tokens, :total_tokens])
      |> Map.merge(duration_measurements(route_duration))
      |> Map.put(:estimated_cost, Map.get(payload, :estimated_cost))

    Telemetry.execute(@route_stop_event, measurements, payload, opts)
  end

  defp estimated_cost(_candidate, %{cost: cost}) when is_number(cost), do: cost

  defp estimated_cost(candidate, usage) do
    input = Map.get(usage, :input_tokens)
    output = Map.get(usage, :output_tokens)
    input_rate = cost_rate(candidate.opts, [:input_cost_per_token, :cost_per_input_token])
    output_rate = cost_rate(candidate.opts, [:output_cost_per_token, :cost_per_output_token])

    cond do
      is_number(input) and is_number(output) and is_number(input_rate) and is_number(output_rate) ->
        input * input_rate + output * output_rate

      is_number(input) and is_number(input_rate) ->
        input * input_rate

      is_number(output) and is_number(output_rate) ->
        output * output_rate

      true ->
        nil
    end
  end

  defp cost_rate(opts, keys) do
    Enum.find_value(keys, fn key ->
      case Keyword.get(opts, key) do
        value when is_integer(value) or is_float(value) -> value
        _value -> nil
      end
    end)
  end

  defp duration_measurements(duration) do
    %{duration: duration, duration_ms: duration_ms(duration)}
  end

  defp elapsed_since(started_at), do: System.monotonic_time() - started_at
  defp duration_ms(duration), do: System.convert_time_unit(duration, :native, :millisecond)

  defp max_retries(opts) do
    case Keyword.get(opts, :max_retries, Keyword.get(opts, :retries, 1)) do
      retries when is_integer(retries) and retries >= 0 -> retries
      _other -> 1
    end
  end

  defp sleep_retry_delay(opts) do
    case Keyword.get(opts, :retry_delay_ms, 0) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _delay -> :ok
    end
  end

  defp emit_route_event(type, payload, opts, emit) do
    emit.(%Tet.Event{
      type: type,
      session_id: Keyword.get(opts, :session_id),
      payload: payload |> Tet.Redactor.redact() |> compact_map()
    })
  end

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
