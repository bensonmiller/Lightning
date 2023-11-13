defmodule Lightning.Attempts do
  defmodule Adaptor do
    @moduledoc """
    Behaviour for implementing an adaptor for the Lightning.Attempts module.
    """

    @callback enqueue(
                attempt ::
                  Lightning.Attempt.t() | Ecto.Changeset.t(Lightning.Attempt.t())
              ) ::
                {:ok, Lightning.Attempt.t()}
                | {:error, Ecto.Changeset.t(Lightning.Attempt.t())}

    @callback claim(demand :: non_neg_integer()) ::
                {:ok, [Lightning.Attempt.t()]}

    @callback dequeue(attempt :: Lightning.Attempt.t()) ::
                {:ok, Lightning.Attempt.t()}
  end

  alias Lightning.Attempt
  alias Lightning.Attempts.Events
  alias Lightning.Attempts.Handlers

  alias Lightning.Repo

  import Ecto.Query

  @behaviour Adaptor

  @doc """
  Enqueue an attempt to be processed.
  """
  @impl true
  def enqueue(attempt) do
    adaptor().enqueue(attempt)
  end

  # @doc """
  # Claim an available attempt.
  #
  # The `demand` parameter is used to request more than a since attempt,
  # all implementation should default to 1.
  # """
  @impl true
  def claim(demand \\ 1) do
    adaptor().claim(demand)
  end

  # @doc """
  # Removes an attempt from the queue.
  # """
  @impl true
  def dequeue(attempt) do
    adaptor().dequeue(attempt)
  end

  @doc """
  Get an Attempt by id.

  Optionally preload associations by passing a list of atoms to `:include`.

      Lightning.Attempts.get(id, include: [:workflow])
  """
  @spec get(Ecto.UUID.t(), [{:include, term()}]) ::
          Attempt.t() | nil
  def get(id, opts \\ []) do
    preloads = opts |> Keyword.get(:include, [])

    from(a in Attempt,
      where: a.id == ^id,
      preload: ^preloads
    )
    |> Repo.one()
  end

  @doc """
  Returns only the dataclip body as a string
  """
  def get_dataclip_body(%Attempt{} = attempt) do
    from(d in Ecto.assoc(attempt, :dataclip),
      select: type(d.body, :string)
    )
    |> Repo.one()
  end

  @doc """
  Returns a tuple with {type, string} so that initial state can be created for
  the worker. See LightingWeb.AttemptChannel.handle_in("fetch:dataclip", _, _)
  for more details.
  """
  def get_dataclip_for_worker(%Attempt{} = attempt) do
    from(d in Ecto.assoc(attempt, :dataclip),
      select: {d.type, type(d.body, :string)}
    )
    |> Repo.one()
  end

  def get_credential(%Attempt{} = attempt, id) do
    from(c in Ecto.assoc(attempt, [:workflow, :jobs, :credential]),
      where: c.id == ^id
    )
    |> Repo.one()
  end

  def start_attempt(%Attempt{} = attempt) do
    Attempt.start(attempt)
    |> update_attempt()
  end

  def complete_attempt(attempt, {new_state, error_type, error_message}) do
    Attempt.complete(attempt, {new_state, error_type, error_message})
    |> case do
      %{valid?: false} = changeset ->
        {:error, changeset}

      changeset ->
        changeset |> update_attempt()
    end
  end

  # TODO - Implement this in https://github.com/OpenFn/Lightning/issues/1348
  # def mark_unfinished_runs_lost(attempt) do
  # for each run in this attempt call `complete_run` with exit_reason: "lost"
  # end

  def update_attempt(%Ecto.Changeset{data: %Attempt{}} = changeset) do
    attempt_id = Ecto.Changeset.get_field(changeset, :id)

    attempt_query =
      from(a in Attempt,
        where: a.id == ^attempt_id,
        lock: "FOR UPDATE"
      )

    update_query =
      Attempt
      |> with_cte("subset", as: ^attempt_query)
      |> join(:inner, [a], s in fragment(~s("subset")), on: a.id == s.id)
      |> select([a, _], a)

    update_attempts(update_query, changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{attempts: {1, [attempt]}}} ->
        {:ok, attempt}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_attempts(update_query, updates) do
    updates =
      case updates do
        %Ecto.Changeset{changes: changes} -> [set: changes |> Enum.into([])]
        updates when is_list(updates) -> updates
      end

    Ecto.Multi.new()
    |> Ecto.Multi.update_all(:attempts, update_query, updates)
    |> Ecto.Multi.run(:post, fn _, %{attempts: {_, attempts}} ->
      Enum.each(attempts, fn attempt ->
        {:ok, _} = Lightning.WorkOrders.update_state(attempt)

        Events.attempt_updated(attempt)
      end)

      {:ok, nil}
    end)
  end

  def append_attempt_log(attempt, params) do
    alias Lightning.Invocation.LogLine
    import Ecto.Changeset

    LogLine.new(attempt, params)
    |> validate_change(:run_id, fn _, run_id ->
      if is_nil(run_id) do
        []
      else
        where(Lightning.AttemptRun, run_id: ^run_id, attempt_id: ^attempt.id)
        |> Repo.exists?()
        |> if do
          []
        else
          [{:run_id, "must be associated with the attempt"}]
        end
      end
    end)
    |> Repo.insert()
    |> case do
      {:ok, log_line} ->
        Events.log_appended(log_line)
        {:ok, log_line}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Creates a Run for a given attempt and job.

  The Run is created with and marked as started at the current time.
  """
  @spec start_run(%{required(binary()) => Ecto.UUID.t()}) ::
          {:ok, Lightning.Invocation.Run.t()} | {:error, Ecto.Changeset.t()}
  def start_run(params) do
    Handlers.StartRun.call(params)
  end

  @spec complete_run(%{required(binary()) => binary()}) ::
          {:ok, Lightning.Invocation.Run.t()} | {:error, Ecto.Changeset.t()}
  def complete_run(params) do
    Handlers.CompleteRun.call(params)
  end

  defdelegate subscribe(attempt), to: Events

  def get_project_id_for_attempt(attempt) do
    Ecto.assoc(attempt, [:work_order, :workflow, :project])
    |> select([p], p.id)
    |> Repo.one()
  end

  def get_log_lines(attempt) do
    Ecto.assoc(attempt, :log_lines)
    |> order_by([l], asc: l.timestamp)
    |> Repo.stream()
  end

  defp adaptor do
    Lightning.Config.attempts_adaptor()
  end

  def mark_unfinished_runs_lost(%Attempt{id: attempt_id}) do
    # Fetch all runs associated with the attempt
    runs =
      Repo.all(
        from ar in Lightning.AttemptRun,
          where: ar.attempt_id == ^attempt_id,
          preload: [:run]
      )

    # Iterate over each run and mark it as lost if not finished
    Enum.each(runs, fn %{run: run} ->
      if run_not_finished?(run) do
        mark_run_as_lost(run)
      end
    end)
  end

  defp run_not_finished?(%{finished_at: nil, exit_reason: nil}), do: true

  defp run_not_finished?(_), do: false

  defp mark_run_as_lost(run) do
    updated_run = Ecto.Changeset.change(run, exit_reason: "lost")
    Repo.update!(updated_run)
  end
end
