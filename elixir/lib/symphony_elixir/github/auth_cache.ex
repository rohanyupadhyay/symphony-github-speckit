defmodule SymphonyElixir.GitHub.AuthCache do
  @moduledoc false

  use GenServer

  @type cache_key :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))

  @spec fetch(cache_key(), integer(), (-> {:ok, term(), integer()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def fetch(key, minimum_expiry, refresh_fun) when is_function(refresh_fun, 0) do
    GenServer.call(__MODULE__, {:fetch, key, minimum_expiry, refresh_fun}, 35_000)
  end

  @spec invalidate(cache_key()) :: :ok
  def invalidate(key), do: GenServer.call(__MODULE__, {:invalidate, key})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:fetch, key, minimum_expiry, refresh_fun}, _from, state) do
    case Map.get(state, key) do
      {value, expires_at} when expires_at > minimum_expiry ->
        {:reply, {:ok, value}, state}

      _ ->
        case refresh_fun.() do
          {:ok, value, expires_at} -> {:reply, {:ok, value}, Map.put(state, key, {value, expires_at})}
          {:error, _reason} = error -> {:reply, error, Map.delete(state, key)}
        end
    end
  end

  def handle_call({:invalidate, key}, _from, state), do: {:reply, :ok, Map.delete(state, key)}
end
