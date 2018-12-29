defmodule Rill.MessageStore.Ecto.Postgres.Database do
  defmodule Defaults do
    @spec position() :: 0
    def position, do: 0
    @spec batch_size() :: 1000
    def batch_size, do: 1000
  end

  @behaviour Rill.MessageStore.Database

  use Rill.MessageStore.Ecto.Postgres.Kernel
  alias Rill.Session
  alias Rill.MessageStore.StreamName
  alias Rill.MessageStore.MessageData.Write
  alias Rill.MessageStore.MessageData.Read
  alias Rill.MessageStore.Ecto.Postgres.Database.Serialize
  alias Rill.MessageStore.Ecto.Postgres.Database.Deserialize
  alias Rill.Identifier.UUID.Random, as: Identifier
  alias Rill.MessageStore.ExpectedVersion
  alias Rill.Messaging.Message.Transform

  @scribble tag: :message_store

  @type row :: list()
  @type row_map :: %{
          id: String.t(),
          stream_name: StreamName.t(),
          type: String.t(),
          position: non_neg_integer(),
          global_position: pos_integer(),
          data: map(),
          metadata: map(),
          time: String.t()
        }

  @wrong_version "Wrong expected version:"
  @sql_get_params "$1::varchar, $2::bigint, $3::bigint, $4::varchar"
  @sql_put "SELECT write_message(
    $1::varchar,
    $2::varchar,
    $3::varchar,
    $4::jsonb,
    $5::jsonb,
    $6::bigint
  )"

  @impl Rill.MessageStore.Database
  def get(%Session{} = session, stream_name, opts \\ [])
      when is_binary(stream_name) and is_list(opts) do
    Log.trace tag: :get do
      "Getting (Stream Name: #{stream_name})"
    end

    repo = Session.get_config(session, :repo)
    condition = constrain_condition(opts[:condition])
    position = opts[:position] || Defaults.position()
    batch_size = opts[:batch_size] || Defaults.batch_size()
    sql = sql_get(stream_name)
    params = [stream_name, position, batch_size, condition]

    messages =
      repo
      |> Ecto.Adapters.SQL.query!(sql, params)
      |> Map.fetch!(:rows)
      |> convert()

    Log.debug tag: :get do
      count = length(messages)

      "Finished Getting Messages (Stream Name: #{stream_name}, Count: #{count}, Position: #{
        inspect(position)
      }, Batch Size: #{inspect(batch_size)}, Condition: #{condition || "(none)"})"
    end

    Log.info tag: :get do
      "Get Completed (Stream Name: #{stream_name})"
    end

    messages
  end

  @impl Rill.MessageStore.Database
  def get_last(%Session{} = session, stream_name)
      when is_binary(stream_name) do
    Log.trace tags: [:get, :get_last] do
      "Getting Last (Stream Name: #{stream_name})"
    end

    repo = Session.get_config(session, :repo)
    sql = sql_get_last(stream_name)
    params = [stream_name]

    last_message =
      repo
      |> Ecto.Adapters.SQL.query!(sql, params)
      |> Map.fetch!(:rows)
      |> List.last()
      |> convert_row()

    Log.debug tags: [:get, :get_last, :data] do
      inspect(last_message, pretty: true)
    end

    Log.info tags: [:get, :get_last] do
      "Get Last Completed (Stream Name: #{stream_name})"
    end

    last_message
  end

  @impl Rill.MessageStore.Database
  def put(%Session{} = session, %Write{} = msg, stream_name, opts \\ [])
      when is_binary(stream_name) and is_list(opts) do
    repo = Session.get_config(session, :repo)
    identifier_get = Keyword.get(opts, :identifier_get) || (&Identifier.get/0)

    expected_version =
      opts
      |> Keyword.get(:expected_version)
      |> ExpectedVersion.canonize()

    Log.trace tag: :put do
      "Putting (Stream Name: #{stream_name}, Expected Version: #{
        inspect(expected_version)
      })"
    end

    Log.debug tags: [:put, :data] do
      inspect(msg, pretty: true)
    end

    %{id: id, type: type, data: data, metadata: metadata} = msg
    id = id || identifier_get.()
    data = Serialize.data(data)
    metadata = Serialize.metadata(metadata)

    params = [id, stream_name, type, data, metadata, expected_version]

    position =
      repo
      |> execute(@sql_put, params)
      |> Map.fetch!(:rows)
      |> convert_position()

    Log.info tag: :put do
      "Put Completed (Stream Name: #{stream_name}, Position: #{position})"
    end

    position
  end

  @spec constrain_condition(condition :: String.t() | nil) :: String.t() | nil
  def constrain_condition(nil), do: nil

  def constrain_condition(condition) when is_binary(condition) do
    "(#{condition})"
  end

  @spec sql_get(stream_name :: StreamName.t()) :: String.t()
  def sql_get(stream_name) when is_binary(stream_name) do
    if StreamName.category?(stream_name) do
      "SELECT * FROM get_category_messages(#{@sql_get_params});"
    else
      "SELECT * FROM get_stream_messages(#{@sql_get_params});"
    end
  end

  @spec sql_get_last(stream_name :: StreamName.t()) :: String.t()
  def sql_get_last(stream_name) when is_binary(stream_name) do
    "SELECT * FROM get_last_message($1::varchar)"
  end

  @spec convert(rows :: [row()]) :: [row_map()]
  def convert(rows) do
    Enum.map(rows, &convert_row/1)
  end

  @spec convert_position(rows :: nil | [] | [[non_neg_integer()]]) ::
          non_neg_integer()
  def convert_position(nil), do: nil
  def convert_position([]), do: nil
  def convert_position([[position]]), do: position

  @spec convert_row(row :: nil | row()) :: row_map()
  def convert_row(nil), do: nil

  def convert_row(row) do
    [id, stream_name, type, position, global_position, data, metadata, time] =
      row

    data = Deserialize.data(data)
    metadata = Deserialize.metadata(metadata)

    record = %{
      id: id,
      stream_name: stream_name,
      type: type,
      position: position,
      global_position: global_position,
      data: data,
      metadata: metadata,
      time: time
    }

    record
    |> Transform.read()
    |> Read.build()
  end

  @spec raise_known_error(error :: %Postgrex.Error{}) :: no_return()
  def raise_known_error(error) do
    message = to_string(error.postgres.message)

    if String.starts_with?(message, @wrong_version) do
      raise ExpectedVersion.Error, message: message
    else
      raise(error)
    end
  end

  @spec execute(repo :: atom(), sql :: String.t(), params :: list()) ::
          non_neg_integer()
  def execute(repo, sql, params) do
    Ecto.Adapters.SQL.query!(repo, sql, params)
  rescue
    error in Postgrex.Error -> raise_known_error(error)
    error -> raise error
  end
end
