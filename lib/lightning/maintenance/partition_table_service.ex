defmodule Lightning.PartitionTableService do
  @moduledoc """
  Service to keep the partition tables up to date.
  """

  use Oban.Worker,
    queue: :background,
    max_attempts: 1

  import Ecto.Query

  alias Lightning.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"add_headroom" => [%{"weeks" => weeks}]}})
      when is_integer(weeks) do
    add_headroom(:all, weeks)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"drop_older_than" => shift_options}})
      when is_list(shift_options) do
    shift_options =
      for {key, val} <- shift_options, into: [], do: {String.to_atom(key), val}

    upper_bound = Timex.shift(DateTime.utc_now(), shift_options)

    remove_empty("work_orders", upper_bound)
  end

  def add_headroom(:all, weeks) when is_integer(weeks) do
    add_headroom(:work_orders, weeks) |> log_partition_creation()
  end

  def add_headroom(:work_orders, weeks) when is_integer(weeks) do
    proposed_tables = tables_to_add("work_orders", weeks)

    :ok =
      Enum.each(proposed_tables, fn {partition_name, from, to} ->
        {
          Repo.query(create_query(partition_name, "work_orders", from, to))
        }
      end)

    proposed_tables
  end

  def tables_to_add(table, weeks) do
    today = Date.utc_today()

    existing_tables = get_partitions(table)

    Lightning.AdminTools.generate_iso_weeks(today, today |> Date.add(weeks * 7))
    |> Enum.map(&to_partition_details(table, &1))
    |> Enum.reject(fn {name, _from, _to} ->
      Enum.find(existing_tables, &String.equivalent?(name, &1))
    end)
  end

  def get_partitions(parent) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        ~S[
          SELECT CAST(inhrelid::regclass AS text) AS child
          FROM   pg_catalog.pg_inherits
          WHERE  inhparent = $1::text::regclass;
        ],
        [parent]
      )

    rows |> List.flatten()
  end

  @doc """
  Drops empty partition tables that have an upper partition bound less than the
  date given.

  This bound is the `TO` part of the partition:

  ```
  FOR VALUES FROM ('2020-12-28 00:00:00') TO ('2021-01-04 00:00:00')
  ```
  """
  def remove_empty(parent, upper_bound) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        ~S[
        WITH partitions AS (
        SELECT
          partition_name,
          split_part(partition_expression, '''', 4)::timestamp AS TO
        FROM
          (
          SELECT
            pt.relname AS partition_name,
            pg_get_expr(pt.relpartbound,
            pt.oid,
            TRUE) AS partition_expression
          FROM
            pg_class base_tb
          JOIN pg_inherits i ON
            i.inhparent = base_tb.oid
          JOIN pg_class pt ON
            pt.oid = i.inhrelid
          WHERE
            base_tb.oid = $1::text::regclass ) t)
        SELECT
          partition_name
        FROM
          partitions p
        WHERE
          p.to < $2::timestamp;
      ],
        [parent, upper_bound]
      )

    rows
    |> List.flatten()
    |> Enum.filter(fn partition ->
      from(r in partition, select: count())
      |> Repo.one!() == 0
    end)
    |> Enum.each(fn partition ->
      Logger.info("Detaching #{partition} from #{parent}")
      Repo.query!("ALTER TABLE #{parent} DETACH PARTITION #{partition};")
      Logger.info("Dropping #{partition}")
      Repo.query!("DROP TABLE #{partition};")
    end)
  end

  defp create_query(partition, parent, from, to) do
    """
    CREATE TABLE #{partition}
      PARTITION OF #{parent}
        FOR VALUES FROM ('#{from}') TO ('#{to}');
    """
  end

  defp to_partition_details(table, {year, week, from, to}) do
    {"#{table}_#{year}_#{week}", from, to}
  end

  defp log_partition_creation(partitions) when length(partitions) > 0 do
    partitions
    |> Enum.map(fn {partition_name, from, to} ->
      "Created #{partition_name} for #{from} -> #{to}"
    end)
    |> Enum.join("\n")
    |> Logger.info()
  end

  defp log_partition_creation(partitions) when partitions == [] do
    Logger.info("No extra partitions were needed.")
  end
end
