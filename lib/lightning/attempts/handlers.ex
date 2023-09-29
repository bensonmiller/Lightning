defmodule Lightning.Attempts.Handlers do
  @moduledoc """
  Handler modules for working with attempts.
  """

  alias Lightning.{Attempt, AttemptRun, Repo}
  alias Lightning.Invocation.{Run, Dataclip}

  defmodule StartRun do
    use Ecto.Schema
    import Ecto.Changeset
    import Ecto.Query

    @primary_key false
    embedded_schema do
      field :attempt_id, Ecto.UUID
      field :run_id, Ecto.UUID
      field :job_id, Ecto.UUID
      field :input_dataclip_id, Ecto.UUID
      field :started_at, :utc_datetime_usec
    end

    def new(params) do
      cast(%__MODULE__{}, params, [
        :attempt_id,
        :run_id,
        :job_id,
        :input_dataclip_id
      ])
      |> put_change(:started_at, DateTime.utc_now())
      |> validate_required([
        :attempt_id,
        :run_id,
        :job_id,
        :input_dataclip_id,
        :started_at
      ])
      |> then(&validate_job_reachable/1)
    end

    def call(params) do
      with {:ok, attrs} <- new(params) |> apply_action(:validate),
           {:ok, run} <- insert(attrs) do
        {:ok, run}
      end
    end

    defp insert(attrs) do
      Repo.transact(fn ->
        with {:ok, run} <- attrs |> to_run() |> Repo.insert(),
             {:ok, _} <- attrs |> to_attempt_run() |> Repo.insert() do
          {:ok, run}
        end
      end)
    end

    defp to_run(%__MODULE__{} = start_run) do
      Map.from_struct(start_run)
      |> Enum.reduce(%{}, fn {k, v}, acc ->
        cond do
          k in [:input_dataclip_id, :job_id, :started_at] ->
            Map.put(acc, k, v)

          k == :run_id ->
            Map.put(acc, :id, v)

          true ->
            acc
        end
      end)
      |> Run.new()
    end

    defp to_attempt_run(%__MODULE__{run_id: run_id, attempt_id: attempt_id}) do
      AttemptRun.new(%{
        run_id: run_id,
        attempt_id: attempt_id
      })
    end

    defp validate_job_reachable(changeset) do
      case changeset do
        %{valid?: false} ->
          changeset

        _ ->
          job_id = get_field(changeset, :job_id)
          attempt_id = get_field(changeset, :attempt_id)

          # Verify that all of the required entities exist with a single query,
          # then reduce the results into a single changeset by adding errors for
          # any columns/ids that are null.
          from(a in Attempt,
            where: a.id == ^attempt_id,
            join: w in assoc(a, :workflow),
            left_join: j in assoc(w, :jobs),
            on: j.id == ^job_id,
            select: %{attempt_id: a.id, job_id: j.id}
          )
          |> Repo.one()
          |> Enum.reduce(changeset, fn {k, v}, changeset ->
            if is_nil(v) do
              add_error(changeset, k, "does not exist")
            else
              changeset
            end
          end)
      end
    end
  end

  defmodule CompleteRun do
    use Ecto.Schema
    import Ecto.Changeset
    import Ecto.Query

    @primary_key false
    embedded_schema do
      field :project_id, Ecto.UUID
      field :dataclip_id, Ecto.UUID
      field :attempt_id, Ecto.UUID
      field :output_dataclip, :string
      field :reason, :string
      field :run_id, Ecto.UUID
      field :finished_at, :utc_datetime_usec
    end

    def new(params) do
      cast(%__MODULE__{}, params, [
        :attempt_id,
        :dataclip_id,
        :output_dataclip,
        :project_id,
        :reason,
        :run_id
      ])
      |> put_change(:finished_at, DateTime.utc_now())
      |> validate_required([
        :attempt_id,
        :dataclip_id,
        :finished_at,
        :output_dataclip,
        :project_id,
        :reason,
        :run_id
      ])
    end

    def call(params) do
      with {:ok, complete_run} <- new(params) |> apply_action(:validate),
           {:ok, run} <- update(complete_run) do
        {:ok, run}
      end
    end

    defp update(complete_run) do
      Repo.transact(fn ->
        with run = %Run{} <-
               get_run(complete_run.run_id) || {:error, :not_found},
             {:ok, _} <- to_dataclip(complete_run) |> Repo.insert(),
             {:ok, run} <- update_run(run, complete_run) do
          {:ok, run}
        end
      end)
    end

    defp get_run(id) do
      from(r in Lightning.Invocation.Run, where: r.id == ^id)
      |> Repo.one()
    end

    defp to_dataclip(%__MODULE__{
           output_dataclip: output_dataclip,
           project_id: project_id,
           dataclip_id: dataclip_id
         }) do
      Dataclip.new(%{
        id: dataclip_id,
        project_id: project_id,
        body: output_dataclip |> Jason.decode!(),
        type: :run_result
      })
    end

    defp update_run(run, complete_run) do
      run
      |> Run.finished(complete_run.dataclip_id, complete_run.reason)
      |> Repo.update()
    end
  end
end