defmodule Lightning.Credentials do
  @moduledoc """
  The Credentials context.
  """

  import Ecto.Query, warn: false
  import Lightning.Helpers, only: [coerce_json_field: 2]
  alias Lightning.Repo

  alias Lightning.Credentials.Credential
  alias Lightning.Projects.Project
  alias Lightning.Accounts.User

  @doc """
  Returns the list of credentials.

  ## Examples

      iex> list_credentials()
      [%Credential{}, ...]

  """
  def list_credentials do
    Repo.all(Credential)
  end

  def list_credentials(%Project{} = project) do
    Ecto.assoc(project, :credentials)
    |> Repo.all()
  end

  @doc """
  Returns the list of credentials for a given user.

  ## Examples

      iex> list_credentials_for_user(123)
      [%Credential{user_id: 123}, %Credential{user_id: 123},...]

  """
  def list_credentials_for_user(user_id) do
    from(c in Credential, where: c.user_id == ^user_id)
    |> Repo.all()
  end

  @doc """
  Gets a single credential.

  Raises `Ecto.NoResultsError` if the Credential does not exist.

  ## Examples

      iex> get_credential!(123)
      %Credential{}

      iex> get_credential!(456)
      ** (Ecto.NoResultsError)

  """
  def get_credential!(id), do: Repo.get!(Credential, id)

  @doc """
  Creates a credential.

  ## Examples

      iex> create_credential(%{field: value})
      {:ok, %Credential{}}

      iex> create_credential(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_credential(attrs \\ %{}) do
    %Credential{}
    |> Credential.changeset(attrs |> coerce_json_field("body"))
    |> Repo.insert()
  end

  @doc """
  Updates a credential.

  ## Examples

      iex> update_credential(credential, %{field: new_value})
      {:ok, %Credential{}}

      iex> update_credential(credential, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_credential(%Credential{} = credential, attrs) do
    credential
    |> Credential.changeset(attrs |> coerce_json_field("body"))
    |> Repo.update()
  end

  @doc """
  Deletes a credential.

  ## Examples

      iex> delete_credential(credential)
      {:ok, %Credential{}}

      iex> delete_credential(credential)
      {:error, %Ecto.Changeset{}}

  """
  def delete_credential(%Credential{} = credential) do
    Repo.delete(credential)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking credential changes.

  ## Examples

      iex> change_credential(credential)
      %Ecto.Changeset{data: %Credential{}}

  """
  def change_credential(%Credential{} = credential, attrs \\ %{}) do
    Credential.changeset(
      credential,
      attrs |> coerce_json_field("body")
    )
  end

  def can_credential_be_shared_to_user(credential_id, user_id) do
    from(pu in Lightning.Projects.ProjectUser,
      join: pc in Lightning.Projects.ProjectCredential,
      on: pu.project_id == pc.project_id,
      where: pu.user_id == ^user_id and pc.credential_id == ^credential_id,
      select: count(pu.id)
    )
    |> Repo.one()
  end
end
