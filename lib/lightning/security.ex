defmodule Lightning.Security do
  @moduledoc """
  Security helpers.
  """
  alias Ecto.Changeset

  @spec redact_password(Changeset.t(), atom()) :: Changeset.t()
  def redact_password(
        %Changeset{
          valid?: true,
          changes: changes
        } = changeset,
        field
      ) do
    redacted =
      changes
      |> Map.get(field)
      |> String.replace(
        ~r/\"password\":\"\w+\"/,
        "\\1\"password\":\"\*\*\*\""
      )

    Changeset.put_change(changeset, field, redacted)
  end

  def redact_password(changeset), do: changeset
end
