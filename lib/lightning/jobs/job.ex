defmodule Lightning.Jobs.Job do
  @moduledoc """
  Ecto model for Jobs.

  A Job contains the fields for defining a job.

  * `body`
    The expression/javascript code
  * `name`
    A plain text identifier
  * `adaptor`
    An NPM style string that contains both the module name and it's version.
    E.g. `@openfn/language-http@v1.2.3` or `@openfn/language-foo@latest`.
    While the version suffix isn't enforced here as it's not strictly necessary
    in this context, the front end will ensure a version is stated (`@latest`
    being the default).
  * `trigger`
    Association to it's trigger, a job _must_ have a trigger.
    See `Lightning.Jobs.Trigger`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Lightning.Jobs.Trigger
  alias Lightning.Jobs
  alias Lightning.Credentials.Credential
  alias Lightning.Workflows.Workflow
  alias Lightning.Workflows
  alias Lightning.Projects.{Project, ProjectCredential}

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          body: String.t() | nil,
          enabled: boolean(),
          name: String.t() | nil,
          adaptor: String.t() | nil,
          trigger: nil | Trigger.t() | Ecto.Association.NotLoaded.t(),
          credential: nil | Credential.t() | Ecto.Association.NotLoaded.t(),
          project: nil | Project.t() | Ecto.Association.NotLoaded.t(),
          workflow: nil | Workflow.t() | Ecto.Association.NotLoaded.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "jobs" do
    field :body, :string
    field :enabled, :boolean, default: false
    field :name, :string
    field :adaptor, :string

    has_one :trigger, Trigger
    has_many :events, Lightning.Invocation.Event

    # belongs_to :credential, Credential
    belongs_to :project_credential, ProjectCredential
    has_one :credential, through: [:project_credential, :credential]
    belongs_to :project, Project
    belongs_to :workflow, Workflow

    timestamps()
  end

  @doc false
  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :name,
      :body,
      :enabled,
      :adaptor,
      :project_credential_id,
      :project_id,
      :workflow_id
    ])
    |> cast_assoc(:trigger, with: &Trigger.changeset/2, required: true)
    |> validate_required([
      :name,
      :body,
      :enabled,
      :adaptor,
      :project_id
    ])
    |> validate_length(:name, max: 100)
    |> validate_format(:name, ~r/^[a-zA-Z0-9_\- ]*$/)
  end


  def change_job_credential(job, project_credential) do
    job
    |> cast(%{"project_credential_id" => project_credential.id}, [:project_credential_id])
    |> put_assoc(:project_credential, project_credential)
  end


  @spec add_to_workflow(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  @doc """
  When a job is saved (created or updated) its workflow must be set. (All jobs
  belong to a workflow.)

  If the job's trigger is of type `:on_job_success` or
  `:on_job_failure`, this function will set the `workflow_id` to that of its
  upstream job.

  If the job's trigger is of type `:cron` or `:webhook`, it _is_ the most
  upstream job in a workflow and this function will ensure that the job is in
  its _own_ workflow—either creating a new one or leaving it unchanged.
  """
  def add_to_workflow(%Ecto.Changeset{valid?: false} = changeset),
    do: changeset

  def add_to_workflow(%Ecto.Changeset{valid?: true} = changeset) do
    {
      changeset.data.trigger |> Map.get(:type),
      get_field(changeset, :workflow_id),
      with %Ecto.Changeset{} = trigger_changeset <-
             get_change(changeset, :trigger),
           trigger_type <- trigger_changeset |> get_field(:type) do
        trigger_type
      else
        _ -> nil
      end
    }
    |> case do
      # case: having a brand new cron or webhook job should always put assoc a workflow to a job
      {nil, nil, current_trigger_type}
      when current_trigger_type in [:cron, :webhook] ->
        changeset
        |> put_assoc(
          :workflow,
          Workflow.changeset(
            %Workflow{
              project_id: get_field(changeset, :project_id)
            },
            %{}
          )
        )

      # case: creating a brand new flow job, or changing a flow jobs type should always assign the downstream job's workflow to it's parent workflow
      {_initial_trigger_type, _workflow_id, current_trigger_type}
      when current_trigger_type in [:on_job_success, :on_job_failure] ->
        upstream_job =
          get_change(changeset, :trigger)
          |> get_field(:upstream_job_id)
          |> Jobs.get_job()

        changeset |> put_change(:workflow_id, upstream_job.workflow_id)

      # case: converting a downstream job to a webhook or cron job, should always create a new workflow and assign that to it
      {initial_trigger_type, _, current_trigger_type}
      when initial_trigger_type in [:on_job_success, :on_job_failure] and
             current_trigger_type in [:cron, :webhook] ->
        {:ok, %Workflow{id: id}} =
          Workflows.create_workflow(%{
            project_id: get_field(changeset, :project_id)
          })

        changeset
        |> put_change(
          :workflow_id,
          id
        )

      {_, _, _} ->
        changeset
    end
  end
end
