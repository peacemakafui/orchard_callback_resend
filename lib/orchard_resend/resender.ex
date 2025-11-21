# defmodule OrchardResend.Resender do
#   @moduledoc """
#   Module for resending failed callbacks from callback_req table.

#   Automatically skips callbacks that already have responses in service_callback_push_resp.
#   Stores successful responses in service_callback_push_resp for tracking.
#   """

#   require Logger
#   import Ecto.Query
#   alias OrchardResend.Repo
#   alias OrchardResend.Schema.{ServiceCallbackPushReq, ServiceCallbackPushResp}

#   @default_concurrency 10
#   @default_timeout 30_000
#   @http_headers [{"Content-Type", "application/json"}]

#   def resend_callbacks(entity_service_id, exttrids \\ nil, opts \\ []) do
#     concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
#     timeout = Keyword.get(opts, :timeout, @default_timeout)
#     batch_size = Keyword.get(opts, :batch_size, 20)
#     batch_delay = Keyword.get(opts, :batch_delay, 10_000)
#     from_date = parse_date(Keyword.get(opts, :from_date))
#     to_date = parse_date(Keyword.get(opts, :to_date))

#     Logger.info("Starting callback resend for entity_service_id: #{entity_service_id}")
#     Logger.info("Batch size: #{batch_size}, Batch delay: #{batch_delay}ms")
#     if from_date, do: Logger.info("From date: #{DateTime.to_iso8601(from_date)}")
#     if to_date, do: Logger.info("To date: #{DateTime.to_iso8601(to_date)}")

#     case fetch_pending_callbacks(entity_service_id, exttrids, from_date, to_date) do
#       [] ->
#         Logger.warn("No pending callbacks found for entity_service_id: #{entity_service_id}")
#         {:ok, %{success: 0, failed: 0, results: []}}

#       callbacks ->
#         total_callbacks = length(callbacks)
#         total_batches = div(total_callbacks + batch_size - 1, batch_size)
#         Logger.info("Found #{total_callbacks} pending callbacks to resend in #{total_batches} batches")

#         # Process in batches with delays
#         all_results = callbacks
#         |> Enum.chunk_every(batch_size)
#         |> Enum.with_index(1)
#         |> Enum.flat_map(fn {batch, batch_num} ->
#           Logger.info("Processing batch #{batch_num}/#{total_batches} (#{length(batch)} callbacks)")

#           batch_results = batch
#           |> Task.async_stream(
#             fn callback -> resend_single_callback(callback, timeout) end,
#             max_concurrency: concurrency,
#             timeout: timeout + 5_000,
#             on_timeout: :kill_task
#           )
#           |> Enum.map(fn
#             {:ok, result} -> result
#             {:exit, reason} ->
#               Logger.error("Task exited: #{inspect(reason)}")
#               {:error, "Task timeout or crash"}
#           end)

#           if batch_num < total_batches do
#             Logger.info("Waiting #{batch_delay}ms before next batch...")
#             Process.sleep(batch_delay)
#           end

#           batch_results
#         end)

#         summary = summarize_results(all_results)
#         Logger.info("Resend completed: #{inspect(summary)}")

#         {:ok, summary}
#     end
#   rescue
#     e ->
#       Logger.error("Error in resend_callbacks: #{inspect(e)}")
#       {:error, Exception.message(e)}
#   end

#   @doc """
#   Fetch callbacks that don't have responses yet (LEFT JOIN excludes those with responses).
#   """
#   defp fetch_pending_callbacks(entity_service_id, exttrids, from_date, to_date) do
#     query = from c in ServiceCallbackPushReq,
#       left_join: r in ServiceCallbackPushResp,
#       on: c.exttrid == r.exttrid and c.entity_service_id == r.entity_service_id,
#       where: is_nil(r.id)

#     # Apply entity_service_id filter if provided
#     query = if entity_service_id do
#       from c in query, where: c.entity_service_id == ^entity_service_id
#     else
#       query
#     end

#     # Apply exttrids filter if provided
#     query = if exttrids && is_list(exttrids) && length(exttrids) > 0 do
#       from c in query, where: c.exttrid in ^exttrids
#     else
#       query
#     end

#     # Apply date range filters
#     query = if from_date do
#       from c in query, where: c.created_at >= ^from_date
#     else
#       query
#     end

#     query = if to_date do
#       from c in query, where: c.created_at <= ^to_date
#     else
#       query
#     end

#     query = from c in query, order_by: [asc: c.id]

#     Repo.all(query)
#   end

#   defp parse_date(nil), do: nil
#   defp parse_date(%DateTime{} = dt), do: dt
#   defp parse_date(date_string) when is_binary(date_string) do
#     case DateTime.from_iso8601(date_string) do
#       {:ok, dt, _offset} -> dt
#       {:error, _} ->
#         Logger.warn("Invalid date format: #{date_string}, ignoring date filter")
#         nil
#     end
#   end
#   defp parse_date(_), do: nil

#   # defp resend_single_callback(%ServiceCallbackPushReq{} = callback, timeout) do
#   #   Logger.debug("Resending callback_req_id: #{callback.id}, exttrid: #{callback.exttrid}")

#   #   start_time = System.monotonic_time(:millisecond)

#   #   result = case send_http_request(callback.callback_url, callback.payload, timeout) do
#   #     {:ok, status, body} ->
#   #       duration = System.monotonic_time(:millisecond) - start_time
#   #       Logger.info("Callback #{callback.id} succeeded in #{duration}ms - Status: #{status}")

#   #       # Store in service_callback_push_resp
#   #       case store_response(%{
#   #         entity_service_id: callback.entity_service_id,
#   #         exttrid: callback.exttrid,
#   #         response_msg: truncate_response(body, 1000)
#   #       }) do
#   #         {:ok, _resp} ->
#   #           Logger.debug("Response stored successfully for exttrid: #{callback.exttrid}")
#   #           {:ok, callback.id, status}

#   #         {:error, %Ecto.Changeset{} = changeset} ->
#   #           errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
#   #           Logger.error("Failed to store response for callback #{callback.id}: #{inspect(errors)}")
#   #           {:ok, callback.id, status}  # Still return success since HTTP call succeeded

#   #         {:error, reason} ->
#   #           Logger.error("Failed to store response for callback #{callback.id}: #{inspect(reason)}")
#   #           {:ok, callback.id, status}  # Still return success since HTTP call succeeded
#   #       end

#   #     {:error, reason} ->
#   #       duration = System.monotonic_time(:millisecond) - start_time
#   #       Logger.error("Callback #{callback.id} failed in #{duration}ms - Reason: #{inspect(reason)}")
#   #       {:error, callback.id, reason}
#   #   end

#   #   result
#   # end
#   defp resend_single_callback(%ServiceCallbackPushReq{} = callback, timeout) do
#     Logger.debug("Resending callback_req_id: #{callback.id}, exttrid: #{callback.exttrid}")

#     start_time = System.monotonic_time(:millisecond)

#     result = case send_http_request(callback.callback_url, callback.payload, timeout) do
#       {:ok, status, body} ->
#         duration = System.monotonic_time(:millisecond) - start_time
#         Logger.info("Callback #{callback.id} succeeded in #{duration}ms - Status: #{status}")

#         # Prepare response_msg - use placeholder if empty
#         response_msg = if body == nil || String.trim(body) == "" do
#           "(empty response)"
#         else
#           truncate_response(body, 1000)
#         end

#         # Store in service_callback_push_resp
#         case store_response(%{
#           entity_service_id: callback.entity_service_id,
#           exttrid: callback.exttrid,
#           response_msg: response_msg
#         }) do
#           {:ok, _resp} ->
#             Logger.debug("Response stored successfully for exttrid: #{callback.exttrid}")
#             {:ok, callback.id, status}

#           {:error, %Ecto.Changeset{} = changeset} ->
#             errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
#             Logger.error("Failed to store response for callback #{callback.id}: #{inspect(errors)}")
#             {:ok, callback.id, status}  # Still return success since HTTP call succeeded

#           {:error, reason} ->
#             Logger.error("Failed to store response for callback #{callback.id}: #{inspect(reason)}")
#             {:ok, callback.id, status}  # Still return success since HTTP call succeeded
#         end

#       {:error, reason} ->
#         duration = System.monotonic_time(:millisecond) - start_time
#         Logger.error("Callback #{callback.id} failed in #{duration}ms - Reason: #{inspect(reason)}")
#         {:error, callback.id, reason}
#     end

#     result
#   end
#   # defp send_http_request(url, payload, timeout) do
#   #   body = case Jason.decode(payload) do
#   #     {:ok, decoded_payload} -> Jason.encode!(decoded_payload)
#   #     {:error, _} -> if is_binary(payload), do: payload, else: Jason.encode!(payload)
#   #   end

#   #   case HTTPoison.post(url, body, @http_headers, timeout: timeout, recv_timeout: timeout) do
#   #     {:ok, %HTTPoison.Response{status_code: status, body: response_body}}
#   #       when status >= 200 and status < 300 ->
#   #       {:ok, status, response_body}

#   #     {:ok, %HTTPoison.Response{status_code: status, body: response_body}} ->
#   #       # Truncate error response to prevent massive logs
#   #       truncated_body = truncate_response(response_body, 200)
#   #       {:error, "HTTP #{status}: #{truncated_body}"}

#   #     {:error, %HTTPoison.Error{reason: reason}} ->
#   #       {:error, reason}
#   #   end
#   # rescue
#   #   e ->
#   #     {:error, Exception.message(e)}
#   # end
#   defp send_http_request(url, payload, timeout) do
#     body = case Jason.decode(payload) do
#       {:ok, decoded_payload} -> Jason.encode!(decoded_payload)
#       {:error, _} -> if is_binary(payload), do: payload, else: Jason.encode!(payload)
#     end

#     # Add hackney options for better HTTP/HTTPS handling
#     options = [
#       timeout: timeout,
#       recv_timeout: timeout,
#       hackney: [
#         pool: false,  # Don't use connection pooling to avoid issues
#         follow_redirect: false,  # Don't follow redirects
#         max_connections: 50
#       ]
#     ]

#     Logger.debug("Sending request to: #{url} (timeout: #{timeout}ms)")

#     case HTTPoison.post(url, body, @http_headers, options) do
#       {:ok, %HTTPoison.Response{status_code: status, body: response_body}}
#         when status >= 200 and status < 300 ->
#         {:ok, status, response_body}

#       {:ok, %HTTPoison.Response{status_code: status, body: response_body}} ->
#         # Truncate error response to prevent massive logs
#         truncated_body = truncate_response(response_body, 200)
#         {:error, "HTTP #{status}: #{truncated_body}"}

#       {:error, %HTTPoison.Error{reason: reason}} ->
#         Logger.debug("HTTPoison error for #{url}: #{inspect(reason)}")
#         {:error, reason}
#     end
#   rescue
#     e ->
#       Logger.error("Exception in send_http_request for #{url}: #{inspect(e)}")
#       {:error, Exception.message(e)}
#   end

#   @doc """
#   Store successful callback response in service_callback_push_resp table.
#   """
#   defp store_response(attrs) do
#     %ServiceCallbackPushResp{}
#     |> ServiceCallbackPushResp.changeset(attrs)
#     |> Repo.insert()
#   end

#   defp truncate_response(response, max_length \\ 1000) do
#     if String.length(response) > max_length do
#       String.slice(response, 0, max_length) <> "... [truncated]"
#     else
#       response
#     end
#   end

#   defp summarize_results(results) do
#     success = Enum.count(results, fn
#       {:ok, _, _} -> true
#       _ -> false
#     end)

#     failed = length(results) - success

#     %{
#       total: length(results),
#       success: success,
#       failed: failed,
#       results: results
#     }
#   end

#   @doc """
#   Get count of pending callbacks (no response yet).
#   """
#   def get_pending_count(entity_service_id) do
#     query = from c in ServiceCallbackPushReq,
#       where: c.entity_service_id == ^entity_service_id,
#       left_join: r in ServiceCallbackPushResp,
#       on: c.exttrid == r.exttrid and c.entity_service_id == r.entity_service_id,
#       where: is_nil(r.id),
#       select: count(c.id)

#     Repo.one(query) || 0
#   end
# end

defmodule OrchardResend.Resender do
  @moduledoc """
  Module for resending failed callbacks from callback_req table.
  """

  require Logger
  import Ecto.Query
  alias OrchardResend.Repo
  alias OrchardResend.Schema.{ServiceCallbackPushReq, ServiceCallbackPushResp}

  @default_concurrency 20
  @default_timeout 60_000
  @http_headers [{"Content-Type", "application/json"}]

  @doc """
  Resend callbacks for a specific date.
  """
  def resend_for_date(date_string, opts \\ []) do
    with {:ok, date, _} <- DateTime.from_iso8601("#{date_string}T00:00:00Z") do
      from_date = date
      to_date = DateTime.add(date, 86400 - 1, :second)

      Logger.info("Processing callbacks for date: #{date_string}")

      resend_callbacks(nil, nil,
        opts
        |> Keyword.put(:from_date, DateTime.to_iso8601(from_date))
        |> Keyword.put(:to_date, DateTime.to_iso8601(to_date))
      )
    else
      _ -> {:error, "Invalid date format. Use YYYY-MM-DD"}
    end
  end

  def resend_callbacks(entity_service_id \\ nil, exttrids \\ nil, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    batch_size = Keyword.get(opts, :batch_size, 1000)
    batch_delay = Keyword.get(opts, :batch_delay, 1_000)
    from_date = parse_date(Keyword.get(opts, :from_date))
    to_date = parse_date(Keyword.get(opts, :to_date))

    log_params(entity_service_id, exttrids, batch_size, batch_delay, from_date, to_date)

    case fetch_pending_callbacks(entity_service_id, exttrids, from_date, to_date) do
      [] ->
        Logger.warn("No pending callbacks found")
        {:ok, %{success: 0, failed: 0, total: 0, results: []}}

      callbacks ->
        total_callbacks = length(callbacks)
        total_batches = div(total_callbacks + batch_size - 1, batch_size)
        Logger.info("Found #{total_callbacks} pending callbacks to resend in #{total_batches} batches")

        all_results = callbacks
        |> Enum.chunk_every(batch_size)
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {batch, batch_num} ->
          Logger.info("Processing batch #{batch_num}/#{total_batches} (#{length(batch)} callbacks)")

          batch_results = batch
          |> Task.async_stream(
            fn callback -> resend_single_callback(callback, timeout) end,
            max_concurrency: concurrency,
            timeout: timeout + 5_000,
            on_timeout: :kill_task
          )
          |> Enum.map(fn
            {:ok, result} -> result
            {:exit, reason} ->
              Logger.error("Task exited: #{inspect(reason)}")
              {:error, "Task timeout or crash"}
          end)

          if batch_num < total_batches do
            Logger.info("Waiting #{batch_delay}ms before next batch...")
            Process.sleep(batch_delay)
          end

          batch_results
        end)

        summary = summarize_results(all_results)
        Logger.info("Resend completed: #{inspect(summary)}")

        {:ok, summary}
    end
  rescue
    e ->
      Logger.error("Error in resend_callbacks: #{inspect(e)}")
      {:error, Exception.message(e)}
  end

  defp log_params(entity_service_id, exttrids, batch_size, batch_delay, from_date, to_date) do
    Logger.info("Starting callback resend")
    if entity_service_id, do: Logger.info("Entity service ID: #{entity_service_id}")
    if exttrids && length(exttrids) > 0, do: Logger.info("Exttrids filter: #{length(exttrids)} items")
    Logger.info("Batch size: #{batch_size}, Batch delay: #{batch_delay}ms")
    if from_date, do: Logger.info("From date: #{DateTime.to_iso8601(from_date)}")
    if to_date, do: Logger.info("To date: #{DateTime.to_iso8601(to_date)}")
  end

  defp fetch_pending_callbacks(entity_service_id, exttrids, from_date, to_date) do
    query = from c in ServiceCallbackPushReq,
      left_join: r in ServiceCallbackPushResp,
      on: c.exttrid == r.exttrid and c.entity_service_id == r.entity_service_id,
      where: is_nil(r.id)

    query = if entity_service_id do
      from c in query, where: c.entity_service_id == ^entity_service_id
    else
      query
    end

    query = if exttrids && is_list(exttrids) && length(exttrids) > 0 do
      from c in query, where: c.exttrid in ^exttrids
    else
      query
    end

    query = if from_date do
      from c in query, where: c.created_at >= ^from_date
    else
      query
    end

    query = if to_date do
      from c in query, where: c.created_at <= ^to_date
    else
      query
    end

    query = from c in query, order_by: [asc: c.id]

    Repo.all(query)
  end

  defp parse_date(nil), do: nil
  defp parse_date(%DateTime{} = dt), do: dt
  defp parse_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _offset} -> dt
      {:error, _} ->
        Logger.warn("Invalid date format: #{date_string}, ignoring date filter")
        nil
    end
  end
  defp parse_date(_), do: nil

  defp resend_single_callback(%ServiceCallbackPushReq{} = callback, timeout) do
    Logger.debug("Resending callback_req_id: #{callback.id}, exttrid: #{callback.exttrid}")

    start_time = System.monotonic_time(:millisecond)

    result = case send_http_request(callback.callback_url, callback.payload, timeout) do
      {:ok, status, body} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.info("Callback #{callback.id} succeeded in #{duration}ms - Status: #{status}")

        response_msg = if body == nil || String.trim(body) == "" do
          "(empty response)"
        else
          truncate_response(body, 1000)
        end

        case store_response_safe(%{
          entity_service_id: callback.entity_service_id,
          exttrid: callback.exttrid,
          response_msg: response_msg
        }) do
          {:ok, _resp} ->
            Logger.debug("Response stored successfully for exttrid: #{callback.exttrid}")
            {:ok, callback.id, status}

          {:duplicate, _} ->
            Logger.debug("Response already exists for exttrid: #{callback.exttrid}, skipping")
            {:ok, callback.id, status}

          {:error, reason} ->
            Logger.error("Failed to store response for callback #{callback.id}: #{inspect(reason)}")
            {:ok, callback.id, status}
        end

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.error("Callback #{callback.id} failed in #{duration}ms - Reason: #{inspect(reason)}")
        {:error, callback.id, reason}
    end

    result
  end

  defp send_http_request(url, payload, timeout) do
    body = case Jason.decode(payload) do
      {:ok, decoded_payload} -> Jason.encode!(decoded_payload)
      {:error, _} -> if is_binary(payload), do: payload, else: Jason.encode!(payload)
    end

    options = [
      timeout: timeout,
      recv_timeout: timeout,
      hackney: [
        pool: false,
        follow_redirect: false,
        max_connections: 50
      ]
    ]

    Logger.debug("Sending request to: #{url} (timeout: #{timeout}ms)")

    case HTTPoison.post(url, body, @http_headers, options) do
      {:ok, %HTTPoison.Response{status_code: status, body: response_body}}
        when status >= 200 and status < 300 ->
        {:ok, status, response_body}

      {:ok, %HTTPoison.Response{status_code: status, body: response_body}} ->
        truncated_body = truncate_response(response_body, 200)
        {:error, "HTTP #{status}: #{truncated_body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.debug("HTTPoison error for #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("Exception in send_http_request for #{url}: #{inspect(e)}")
      {:error, Exception.message(e)}
  end

  defp store_response_safe(attrs) do
    existing = from(r in ServiceCallbackPushResp,
      where: r.entity_service_id == ^attrs.entity_service_id and r.exttrid == ^attrs.exttrid,
      limit: 1
    ) |> Repo.one()

    case existing do
      nil ->
        %ServiceCallbackPushResp{}
        |> ServiceCallbackPushResp.changeset(attrs)
        |> Repo.insert()

      resp ->
        {:duplicate, resp}
    end
  rescue
    e ->
      Logger.error("Exception in store_response_safe: #{inspect(e)}")
      {:error, e}
  end

  defp truncate_response(response, max_length \\ 1000) do
    if String.length(response) > max_length do
      String.slice(response, 0, max_length) <> "... [truncated]"
    else
      response
    end
  end

  defp summarize_results(results) do
    success = Enum.count(results, fn
      {:ok, _, _} -> true
      _ -> false
    end)

    failed = length(results) - success

    %{
      total: length(results),
      success: success,
      failed: failed,
      results: results
    }
  end

  def get_pending_count(entity_service_id \\ nil, exttrids \\ nil, opts \\ []) do
    from_date = parse_date(Keyword.get(opts, :from_date))
    to_date = parse_date(Keyword.get(opts, :to_date))

    query = from c in ServiceCallbackPushReq,
      left_join: r in ServiceCallbackPushResp,
      on: c.exttrid == r.exttrid and c.entity_service_id == r.entity_service_id,
      where: is_nil(r.id)

    query = if entity_service_id do
      from c in query, where: c.entity_service_id == ^entity_service_id
    else
      query
    end

    query = if exttrids && is_list(exttrids) && length(exttrids) > 0 do
      from c in query, where: c.exttrid in ^exttrids
    else
      query
    end

    query = if from_date do
      from c in query, where: c.created_at >= ^from_date
    else
      query
    end

    query = if to_date do
      from c in query, where: c.created_at <= ^to_date
    else
      query
    end

    query = from c in query, select: count(c.id)

    Repo.one(query) || 0
  end

  def get_pending_count_for_date(date_string) do
    with {:ok, date, _} <- DateTime.from_iso8601("#{date_string}T00:00:00Z") do
      from_date = date
      to_date = DateTime.add(date, 86400 - 1, :second)

      get_pending_count(nil, nil,
        from_date: DateTime.to_iso8601(from_date),
        to_date: DateTime.to_iso8601(to_date)
      )
    else
      _ -> 0
    end
  end
end
