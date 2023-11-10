defmodule LightningWeb.AttemptChannel do
  @moduledoc """
  Phoenix channel to interact with Attempts.
  """
  use LightningWeb, :channel

  alias Lightning.Attempts
  alias Lightning.Credentials
  alias Lightning.Repo
  alias Lightning.Workers
  alias LightningWeb.AttemptJson

  require Logger

  @impl true
  def join(
        "attempt:" <> id,
        %{"token" => token},
        %{assigns: %{token: worker_token}} = socket
      ) do
    IO.inspect("attempt:#{id} - join")

    with {:ok, _} <- Workers.verify_worker_token(worker_token),
         {:ok, claims} <- Workers.verify_attempt_token(token, %{id: id}),
         attempt when is_map(attempt) <- get_attempt(id) || {:error, :not_found},
         project_id when is_binary(project_id) <-
           Attempts.get_project_id_for_attempt(attempt) do
      {:ok,
       socket
       |> assign(%{
         claims: claims,
         id: id,
         attempt: attempt,
         project_id: project_id
       })}
    else
      {:error, :not_found} ->
        {:error, %{reason: "not_found"}}

      _ ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  def join("attempt:" <> _, _payload, _socket) do
    {:error, %{reason: "unauthorized"}}
  end

  @impl true
  def handle_in("fetch:attempt", _, socket) do
    IO.inspect("fetch:attempt")
    IO.inspect(socket.assigns.attempt)
    {:reply, {:ok, AttemptJson.render(socket.assigns.attempt)}, socket}
  end

  def handle_in("attempt:start", _, socket) do
    IO.inspect("attempt:start")

    socket.assigns.attempt
    |> Attempts.start_attempt()
    |> IO.inspect()
    |> case do
      {:ok, attempt} ->
        {:reply, {:ok, nil}, socket |> assign(attempt: attempt)}

      {:error, changeset} ->
        {:reply, {:error, LightningWeb.ChangesetJSON.error(changeset)}, socket}
    end
  end

  def handle_in("attempt:complete", payload, socket) do
    IO.inspect("attempt:complete")

    socket.assigns.attempt
    |> IO.inspect()
    |> Attempts.complete_attempt(map_rtm_reason_state(payload))
    |> case do
      {:ok, attempt} ->
        # TODO: Turn FailureAlerter into an Oban worker and process async
        # instead of blocking the channel.
        attempt
        |> Repo.preload([:log_lines, work_order: [:workflow]])
        |> Lightning.FailureAlerter.alert_on_failure()

        {:reply, {:ok, nil}, socket |> assign(attempt: attempt)}

      {:error, changeset} ->
        {:reply, {:error, LightningWeb.ChangesetJSON.error(changeset)}, socket}
    end
  end

  def handle_in("fetch:credential", %{"id" => id}, socket) do
    IO.inspect("fetch:credential")

    Attempts.get_credential(socket.assigns.attempt, id)
    |> Credentials.maybe_refresh_token()
    |> case do
      {:ok, nil} ->
        {:reply, {:error, %{errors: %{id: ["Credential not found!"]}}}, socket}

      {:ok, credential} ->
        {:reply, {:ok, credential.body}, socket}

      e ->
        Logger.error(fn ->
          """
          Something went wrong when fetching or refreshing a credential.

          #{inspect(e)}
          """
        end)

        {:reply,
         {:error,
          %{errors: "Something went wrong when retrieving the credential"}},
         socket}
    end
  end

  def handle_in("fetch:credential", _, socket) do
    IO.inspect("fetch:credential blank")
    {:reply, {:error, %{errors: %{id: ["This field can't be blank."]}}}, socket}
  end

  def handle_in("fetch:dataclip", _, socket) do
    IO.inspect("fetch:dataclip")

    body =
      Attempts.get_dataclip_body(socket.assigns.attempt)
      |> IO.inspect(label: :dataclip)
      |> Jason.Fragment.new()
      |> Phoenix.json_library().encode_to_iodata!()

    {:reply, {:ok, {:binary, body}}, socket}
  end

  def handle_in("run:start", payload, socket) do
    IO.inspect("run:start")

    Map.get(payload, "job_id", :missing_job_id)
    |> case do
      job_id when is_binary(job_id) ->
        %{"attempt_id" => socket.assigns.attempt.id}
        |> Enum.into(payload)
        |> Attempts.start_run()
        |> case do
          {:error, changeset} ->
            {:reply, {:error, LightningWeb.ChangesetJSON.error(changeset)},
             socket}

          {:ok, run} ->
            {:reply, {:ok, %{run_id: run.id}}, socket}
        end

      :missing_job_id ->
        {:reply, {:error, %{errors: %{job_id: ["This field can't be blank."]}}},
         socket}

      nil ->
        {:reply, {:error, %{errors: %{job_id: ["Job not found!"]}}}, socket}
    end
  end

  def handle_in("run:complete", payload, socket) do
    IO.inspect("run:complete")

    %{
      "attempt_id" => socket.assigns.attempt.id,
      "project_id" => socket.assigns.project_id
    }
    |> Enum.into(payload)
    |> Attempts.complete_run()
    |> IO.inspect()
    |> case do
      {:error, changeset} ->
        {:reply, {:error, LightningWeb.ChangesetJSON.error(changeset)}, socket}

      {:ok, run} ->
        {:reply, {:ok, %{run_id: run.id}}, socket}
    end
  end

  def handle_in("attempt:log", payload, socket) do
    Attempts.append_attempt_log(socket.assigns.attempt, payload)
    |> case do
      {:error, changeset} ->
        {:reply, {:error, LightningWeb.ChangesetJSON.error(changeset)}, socket}

      {:ok, log_line} ->
        {:reply, {:ok, %{log_line_id: log_line.id}}, socket}
    end
  end

  defp get_attempt(id) do
    Attempts.get(id,
      include: [workflow: [:triggers, :edges, jobs: [:credential]]]
    )
  end

  defp map_rtm_reason_state(%{"reason" => reason}) do
    case reason do
      "ok" -> :success
      "cancel" -> :cancelled
      "fail" -> :failed
      "kill" -> :killed
      "crash" -> :crashed
      unknown -> unknown
    end
  end

  defp map_rtm_reason_state(_payload), do: nil
end
