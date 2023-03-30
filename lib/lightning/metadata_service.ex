defmodule Lightning.MetadataService do
  @moduledoc """
  Retrieves metadata for a given credential and adaptor using the OpenFn CLI.
  """

  defmodule Error do
    @type t :: %__MODULE__{type: String.t()}

    defexception [:type]

    def new(type) do
      %__MODULE__{type: type}
    end

    def message(%{type: type}) do
      "Got #{type}."
    end
  end

  @adaptor_service :adaptor_service
  @cli_task_worker :cli_task_worker

  alias Lightning.AdaptorService
  alias Lightning.Credentials.Credential
  alias Lightning.CLI

  @doc """
  Retrieve metadata for a given adaptor and credential.

  The adaptor must be an npm specification.
  """
  @spec fetch(adaptor :: String.t(), Credential.t()) ::
          {:ok, %{optional(binary) => binary}} | {:error, Error.t()}
  def fetch(adaptor, credential) do
    Lightning.TaskWorker.start_task(@cli_task_worker, fn ->
      :telemetry.span(
        [:lightning, :fetch_metadata],
        %{adaptor: adaptor},
        fn ->
          {do_fetch(adaptor, credential), %{adaptor: adaptor}}
        end
      )
    end)
    |> case do
      {:error, e} when is_atom(e) -> {:error, Error.new(e)}
      any -> any
    end
  end

  defp do_fetch(adaptor, credential) do
    with {:ok, {adaptor, state}} <- assemble_args(adaptor, credential),
         {:ok, adaptor_path} <- get_adaptor_path(adaptor),
         res <- CLI.metadata(state, adaptor_path),
         {:ok, path} <- get_output_path(res) do
      path
      |> File.read()
      |> case do
        {:ok, body} -> parse_body(body)
        e -> e
      end
    end
  end

  defp assemble_args(adaptor, credential) do
    case {adaptor, credential} do
      {nil, _} ->
        {:error, Error.new("no_adaptor")}

      {_, nil} ->
        {:error, Error.new("no_credential")}

      {adaptor_path, %Credential{body: credential_body}} ->
        {:ok, {adaptor_path, %{"configuration" => credential_body}}}
    end
  end

  defp parse_body(body) do
    Jason.decode(body)
    |> case do
      {:error, _error} -> {:error, Error.new("invalid_json")}
      res -> res
    end
  end

  defp get_adaptor_path(adaptor) do
    case AdaptorService.find_adaptor(@adaptor_service, adaptor) do
      nil -> {:error, Error.new("no_matching_adaptor")}
      %{path: path} -> {:ok, path}
    end
  end

  defp get_output_path(result) do
    path =
      result
      |> CLI.Result.get_messages()
      |> List.first()

    if path do
      {:ok, path}
    else
      {:error, Error.new("no_metadata_result")}
    end
  end
end