defmodule Backy.JobStore do
  use GenServer

  alias Backy.Job

  defmodule State do
    defstruct db: nil, table: nil
  end

  def start_link do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    config = Keyword.merge(Application.get_env(:backy, :db), [
      extensions: [{Postgrex.Extensions.JSON, library: Poison}]
    ])
    table_name = Application.get_env(:backy, :table_name)

    {:ok, pid} = Postgrex.start_link(config)
    {:ok, %State{db: pid, table: table_name}}
  end

  def persist(%Job{id: nil} = job) do
    GenServer.call(__MODULE__, {:persist, job})
  end
  def persist(%Job{}), do: raise "job already persisted"

  def handle_call({:persist, job}, _from, %State{} = state) do
    res = Postgrex.query!(state.db,
      "INSERT INTO #{state.table} \
      (worker, arguments, status, expires_at, enqueued_at) \
      VALUES \
      ($1, $2, 'reserved', now() + ($3 || ' milliseconds')::INTERVAL, now()) \
      RETURNING id", [
      Atom.to_string(job.worker),
      Enum.into(job.arguments, %{}),
      Integer.to_string((job.worker.requeue_delay + job.worker.max_runtime) |> trunc)
    ])

    job = %{job | id: res.rows |> List.first |> List.first}
    {:reply, job, state}
  end
  def handle_call({:mark_as_finished, job}, _from, %State{} = state) do
    Postgrex.query!(state.db,
      "UPDATE #{state.table} \
       SET finished_at = now(), status = 'finished' \
       WHERE id = $1::int", [job.id])
    {:reply, job, state}
  end
  def handle_call({:mark_as_failed, job, error}, _from, %State{} = state) do
    Postgrex.query!(state.db,
      "UPDATE #{state.table} \
       SET failed_at = now(), status = 'failed', error = $2 \
       WHERE id = $1::int", [job.id, inspect(error)])
    {:reply, job, state}
  end
  def handle_call({:touch, job}, _from, %State{} = state) do
    Postgrex.query!(state.db,
      "UPDATE #{state.table} \
       SET expires_at = now() + ($2 || ' milliseconds')::INTERVAL \
       WHERE id = $1::int", [job.id,
       Integer.to_string((job.worker.requeue_delay + job.worker.max_runtime) |> trunc)
    ])
    {:reply, job, state}
  end
  def handle_call(:reserve, _from, %State{} = state) do
    res = Postgrex.query!(state.db,
      "UPDATE #{state.table} \
       SET expires_at = now() + ('1 hour')::INTERVAL, status = 'reserved' \
       WHERE id IN ( \
         SELECT id FROM #{state.table} \
         WHERE status = 'new' OR \
         (status = 'reserved' AND expires_at < now()) \
         LIMIT 1
       ) \
       RETURNING id, worker, arguments",
    [])

    if res.num_rows > 0 do
      row = List.first(res.rows)
      job = try do
        args = Enum.at(row, 2) |> decode_args
        %Job{id: Enum.at(row, 0),
                      worker: String.to_existing_atom(Enum.at(row, 1)),
                      arguments: args}
      rescue
        ArgumentError -> nil
      end
      {:reply, job, state}
    else
      {:reply, nil, state}
    end
  end

  def touch(nil), do: nil
  def touch(%Job{id: nil}), do: raise "job not persisted"
  def touch(%Job{} = job) do
    GenServer.call(__MODULE__, {:touch, job})
  end

  def reserve do
    GenServer.call(__MODULE__, :reserve) |> touch
  end

  def mark_as_finished(%Job{id: nil}), do: raise "job not persisted"
  def mark_as_finished(%Job{} = job) do
    GenServer.call(__MODULE__, {:mark_as_finished, job})
  end

  def mark_as_failed(%Job{id: nil}, _error), do: raise "job not persisted"
  def mark_as_failed(%Job{} = job, error) do
    GenServer.call(__MODULE__, {:mark_as_failed, job, error})
  end

  defp decode_args(args) when is_list(args) do
    Enum.map(args, &decode_args/1)
  end
  defp decode_args(args) when is_map(args) do
    Enum.map(args, fn({key, value}) ->
      {String.to_atom(key), decode_args(value)}
    end)
  end
  defp decode_args(args), do: args


end