defmodule SystemOne.Bundle.Lock do
  # Reads and writes system_one_models.lock, which records the external
  # manifest each model was installed from.
  @moduledoc false

  @spec get(String.t(), String.t()) :: {:ok, map()} | :error | {:error, term()}
  def get(path, model_name) do
    case File.read(path) do
      {:ok, contents} ->
        with {:ok, lock} when is_map(lock) <- Jason.decode(contents) do
          case Map.fetch(lock, model_name) do
            {:ok, entry} when is_map(entry) -> {:ok, entry}
            _ -> :error
          end
        else
          _ -> {:error, :invalid_lockfile}
        end

      {:error, :enoent} ->
        :error

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec put(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(path, model_name, entry) when is_map(entry) do
    with {:ok, lock} <- read(path) do
      contents = lock |> Map.put(model_name, entry) |> Jason.encode!(pretty: true)
      write_atomic(path, contents <> "\n")
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, lock} when is_map(lock) -> {:ok, lock}
          _ -> {:error, :invalid_lockfile}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_atomic(path, contents) do
    path = Path.expand(path)
    temporary = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    try do
      File.mkdir_p!(Path.dirname(path))
      File.write!(temporary, contents)
      File.rename!(temporary, path)
      :ok
    rescue
      exception -> {:error, Exception.message(exception)}
    after
      if File.exists?(temporary), do: File.rm(temporary)
    end
  end
end
