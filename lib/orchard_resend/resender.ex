# defmodule OrchardResend.Resender do
#   @moduledoc """
#   Module for resending failed callbacks from callback_req table.

#   Usage:
#     # Resend all callbacks for a service_id
#     OrchardResend.Resender.resend_callbacks("service123")

#     # Resend specific processing_ids for a service
#     OrchardResend.Resender.resend_callbacks("service123", ["proc1", "proc2", "proc3"])

#     # With custom concurrency (default is 10)
#     OrchardResend.Resender.resend_callbacks("service123", ["proc1", "proc2"], concurrency: 20)

#     # With date range filter (ISO8601 format)
#     OrchardResend.Resender.resend_callbacks("service123", nil,
#       from_date: "2025-11-01T00:00:00Z",
#       to_date: "2025-11-20T23:59:59Z"
#     )

#     # Combine all filters
#     OrchardResend.Resender.resend_callbacks("service123", ["proc1", "proc2"],
#       from_date: "2025-11-15T00:00:00Z",
#       to_date: "2025-11-20T23:59:59Z",
#       concurrency: 25,
#       timeout: 60_000
#     )
#   """

#   require Logger
#   import Ecto.Query
#   alias OrchardResend.Repo
#   alias OrchardResend.Schema.{ServiceCallbackPushReq, ServiceCallbackPushResp, ResendCallback}

#   @default_concurrency 10
#   @default_timeout 30_000
#   @http_headers [{"Content-Type", "application/json"}]

#   @doc """
#   Resend callbacks for a given service_id, optionally filtered by processing_ids and date range.

#   ## Parameters
#     - service_id: The service identifier to filter callbacks
#     - processing_ids: (optional) List of processing IDs to filter. If nil, all callbacks for service are resent
#     - opts: Keyword list with options:
#       - :concurrency - Number of concurrent HTTP requests (default: 10)
#       - :timeout - HTTP request timeout in milliseconds (default: 30000)
#       - :batch_size - Number of callbacks to process per batch (default: 20)
#       - :batch_delay - Delay in milliseconds between batches (default: 10000)
#       - :from_date - Start date for filtering callbacks (DateTime or ISO8601 string, e.g., "2025-11-01T00:00:00Z")
#       - :to_date - End date for filtering callbacks (DateTime or ISO8601 string, e.g., "2025-11-20T23:59:59Z")
#       - :skip_sent - Skip callbacks that already exist in service_callback_push_resp (default: true)

#   ## Returns
#     {:ok, %{success: count, failed: count, skipped: count, results: [...]}} | {:error, reason}
#   """
#   def resend_callbacks(entity_service_id, exttrids \\ nil, opts \\ []) do
#     concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
#     timeout = Keyword.get(opts, :timeout, @default_timeout)
#     batch_size = Keyword.get(opts, :batch_size, 20)
#     batch_delay = Keyword.get(opts, :batch_delay, 10_000)
#     skip_sent = Keyword.get(opts, :skip_sent, true)
#     from_date = parse_date(Keyword.get(opts, :from_date))
#     to_date = parse_date(Keyword.get(opts, :to_date))

#     Logger.info("Starting callback resend for entity_service_id: #{entity_service_id}")
#     Logger.info("Batch size: #{batch_size}, Batch delay: #{batch_delay}ms, Skip sent: #{skip_sent}")
#     if from_date, do: Logger.info("From date: #{DateTime.to_iso8601(from_date)}")
#     if to_date, do: Logger.info("To date: #{DateTime.to_iso8601(to_date)}")

#     case fetch_callbacks(entity_service_id, exttrids, from_date, to_date, skip_sent) do
#       [] ->
#         Logger.warn("No callbacks found for entity_service_id: #{entity_service_id}")
#         {:ok, %{success: 0, failed: 0, skipped: 0, results: []}}

#       callbacks ->
#         total_callbacks = length(callbacks)
#         total_batches = div(total_callbacks + batch_size - 1, batch_size)
#         Logger.info("Found #{total_callbacks} callbacks to resend in #{total_batches} batches")

#         # Process in batches with delays
#         all_results = callbacks
#         |> Enum.chunk_every(batch_size)
#         |> Enum.with_index(1)
#         |> Enum.flat_map(fn {batch, batch_num} ->
#           Logger.info("Processing batch #{batch_num}/#{total_batches} (#{length(batch)} callbacks)")

#           # Process current batch concurrently
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

#           # Add delay before next batch (except for the last batch)
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
#   Fetch callbacks from database based on filters including date range.
#   Excludes callbacks that already exist in service_callback_push_resp if skip_sent is true.
#   """
#   defp fetch_callbacks(entity_service_id, exttrids, from_date, to_date, skip_sent) do
#     # First, get the callbacks that need to be sent
#     query = from c in ServiceCallbackPushReq,
#       where: c.entity_service_id == ^entity_service_id

#     # Apply exttrids filter if provided
#     query = if exttrids && is_list(exttrids) && length(exttrids) > 0 do
#       from c in query, where: c.exttrid in ^exttrids
#     else
#       query
#     end

#     # Apply date range filters if provided
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

#     # Skip callbacks that already have responses if skip_sent is true
#     query = if skip_sent do
#       from c in query,
#         left_join: r in ServiceCallbackPushResp,
#         on: c.exttrid == r.exttrid and c.entity_service_id == r.entity_service_id,
#         where: is_nil(r.id)
#     else
#       query
#     end

#     query = from c in query, order_by: [asc: c.id]

#     callbacks = Repo.all(query)

#     if skip_sent do
#       Logger.info("Filtered out already-sent callbacks. Remaining: #{length(callbacks)}")
#     end

#     callbacks
#   end

#   @doc """
#   Parse date input to DateTime. Accepts DateTime, ISO8601 string, or nil.
#   Examples:
#     - "2025-11-01T00:00:00Z"
#     - "2025-11-20T23:59:59+00:00"
#     - DateTime struct
#   """
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

#   @doc """
#   Resend a single callback and store the result.
#   """
#   defp resend_single_callback(%ServiceCallbackPushReq{} = callback, timeout) do
#     Logger.debug("Resending callback_req_id: #{callback.id}, exttrid: #{callback.exttrid}")

#     start_time = System.monotonic_time(:millisecond)

#     result = case send_http_request(callback.callback_url, callback.payload, timeout) do
#       {:ok, status, body} ->
#         duration = System.monotonic_time(:millisecond) - start_time
#         Logger.info("Callback #{callback.id} succeeded in #{duration}ms - Status: #{status}")

#         store_result(%{
#           callback_req_id: callback.id,
#           entity_service_id: callback.entity_service_id,
#           exttrid: callback.exttrid,
#           response: truncate_response(body),
#           status: "success",
#           http_status: status
#         })

#         {:ok, callback.id, status}

#       {:error, reason} ->
#         duration = System.monotonic_time(:millisecond) - start_time
#         Logger.error("Callback #{callback.id} failed in #{duration}ms - Reason: #{inspect(reason)}")

#         store_result(%{
#           callback_req_id: callback.id,
#           entity_service_id: callback.entity_service_id,
#           exttrid: callback.exttrid,
#           response: truncate_response(inspect(reason)),
#           status: "failed",
#           http_status: nil
#         })

#         {:error, callback.id, reason}
#     end

#     result
#   end

#   @doc """
#   Send HTTP POST request to callback URL.
#   """
#   defp send_http_request(url, payload, timeout) do
#     # Payload from database is a JSON string, decode it first to ensure clean JSON
#     body = case Jason.decode(payload) do
#       {:ok, decoded_payload} ->
#         # Successfully decoded, re-encode it cleanly
#         Jason.encode!(decoded_payload)
#       {:error, _} ->
#         # If decode fails, payload might already be a map or valid JSON string
#         if is_binary(payload), do: payload, else: Jason.encode!(payload)
#     end

#     case HTTPoison.post(url, body, @http_headers, timeout: timeout, recv_timeout: timeout) do
#       {:ok, %HTTPoison.Response{status_code: status, body: response_body}}
#         when status >= 200 and status < 300 ->
#         {:ok, status, response_body}

#       {:ok, %HTTPoison.Response{status_code: status, body: response_body}} ->
#         {:error, "HTTP #{status}: #{response_body}"}

#       {:error, %HTTPoison.Error{reason: reason}} ->
#         {:error, reason}
#     end
#   rescue
#     e ->
#       {:error, Exception.message(e)}
#   end

#   @doc """
#   Store resend result in database.
#   """
#   defp store_result(attrs) do
#     %ResendCallback{}
#     |> ResendCallback.changeset(attrs)
#     |> Repo.insert()
#   rescue
#     e ->
#       Logger.error("Failed to store result: #{inspect(e)}")
#       {:error, e}
#   end

#   @doc """
#   Truncate response to prevent storing huge payloads.
#   """
#   defp truncate_response(response, max_length \\ 5000) do
#     if String.length(response) > max_length do
#       String.slice(response, 0, max_length) <> "... [truncated]"
#     else
#       response
#     end
#   end

#   @doc """
#   Summarize results from resend operation.
#   """
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
#   Get resend history for a specific callback_req_id.
#   """
#   def get_resend_history(callback_req_id) do
#     query = from r in ResendCallback,
#       where: r.callback_req_id == ^callback_req_id,
#       order_by: [desc: r.inserted_at]

#     Repo.all(query)
#   end

#   @doc """
#   Get resend statistics for a service_id.
#   """
#   def get_resend_stats(entity_service_id) do
#     query = from r in ResendCallback,
#       where: r.entity_service_id == ^entity_service_id,
#       select: %{
#         total: count(r.id),
#         success: filter(count(r.id), r.status == "success"),
#         failed: filter(count(r.id), r.status == "failed")
#       }

#     Repo.one(query) || %{total: 0, success: 0, failed: 0}
#   end
# end
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
#   # defp fetch_pending_callbacks(entity_service_id, exttrids, from_date, to_date) do
#   #   query = from c in ServiceCallbackPushReq,
#   #     where: c.entity_service_id == ^entity_service_id,
#   #     left_join: r in ServiceCallbackPushResp,
#   #     on: c.exttrid == r.exttrid and c.entity_service_id == r.entity_service_id,
#   #     where: is_nil(r.id)

#   #   # Apply exttrids filter if provided
#   #   query = if exttrids && is_list(exttrids) && length(exttrids) > 0 do
#   #     from c in query, where: c.exttrid in ^exttrids
#   #   else
#   #     query
#   #   end

#   #   # Apply date range filters
#   #   query = if from_date do
#   #     from c in query, where: c.created_at >= ^from_date
#   #   else
#   #     query
#   #   end

#   #   query = if to_date do
#   #     from c in query, where: c.created_at <= ^to_date
#   #   else
#   #     query
#   #   end

#   #   query = from c in query, order_by: [asc: c.id]

#   #   Repo.all(query)
#   # end

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

#   defp resend_single_callback(%ServiceCallbackPushReq{} = callback, timeout) do
#     Logger.debug("Resending callback_req_id: #{callback.id}, exttrid: #{callback.exttrid}")

#     start_time = System.monotonic_time(:millisecond)

#     result = case send_http_request(callback.callback_url, callback.payload, timeout) do
#       {:ok, status, body} ->
#         duration = System.monotonic_time(:millisecond) - start_time
#         Logger.info("Callback #{callback.id} succeeded in #{duration}ms - Status: #{status}")

#         # Store in service_callback_push_resp
#         store_response(%{
#           entity_service_id: callback.entity_service_id,
#           exttrid: callback.exttrid,
#           response_msg: truncate_response(body, 1000)
#         })

#         {:ok, callback.id, status}

#       {:error, reason} ->
#         duration = System.monotonic_time(:millisecond) - start_time
#         Logger.error("Callback #{callback.id} failed in #{duration}ms - Reason: #{inspect(reason)}")
#         {:error, callback.id, reason}
#     end

#     result
#   end

#   defp send_http_request(url, payload, timeout) do
#     body = case Jason.decode(payload) do
#       {:ok, decoded_payload} -> Jason.encode!(decoded_payload)
#       {:error, _} -> if is_binary(payload), do: payload, else: Jason.encode!(payload)
#     end

#     case HTTPoison.post(url, body, @http_headers, timeout: timeout, recv_timeout: timeout) do
#       {:ok, %HTTPoison.Response{status_code: status, body: response_body}}
#         when status >= 200 and status < 300 ->
#         {:ok, status, response_body}

#       {:ok, %HTTPoison.Response{status_code: status, body: response_body}} ->
#         {:error, "HTTP #{status}: #{response_body}"}

#       {:error, %HTTPoison.Error{reason: reason}} ->
#         {:error, reason}
#     end
#   rescue
#     e ->
#       {:error, Exception.message(e)}
#   end

#   @doc """
#   Store successful callback response in service_callback_push_resp table.
#   """
#   defp store_response(attrs) do
#     %ServiceCallbackPushResp{}
#     |> ServiceCallbackPushResp.changeset(attrs)
#     |> Repo.insert()
#   rescue
#     e ->
#       Logger.error("Failed to store response: #{inspect(e)}")
#       {:error, e}
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

#   @doc """
#   Resend callbacks, optionally filtered by entity_service_id and/or exttrids.

#   ## Parameters
#     - entity_service_id: (optional) The service identifier to filter callbacks. Can be nil.
#     - exttrids: (optional) List of exttrids to filter. If nil, all callbacks (for service) are resent
#     - opts: Keyword list with options:
#       - :concurrency - Number of concurrent HTTP requests (default: 10)
#       - :timeout - HTTP request timeout in milliseconds (default: 30000)
#       - :batch_size - Number of callbacks to process per batch (default: 20)
#       - :batch_delay - Delay in milliseconds between batches (default: 10000)
#       - :http_method - HTTP method to use: :post, :put, :patch (default: :post)
#       - :from_date - Start date for filtering callbacks (DateTime or ISO8601 string)
#       - :to_date - End date for filtering callbacks (DateTime or ISO8601 string)

#   ## Examples
#       # Filter by service_id only
#       resend_callbacks(195, nil)

#       # Filter by exttrids only (no service_id)
#       resend_callbacks(nil, ["TXN001", "TXN002"])

#       # Filter by both
#       resend_callbacks(195, ["TXN001", "TXN002"])

#       # Filter by exttrids with date range
#       resend_callbacks(nil, ["TXN001"], from_date: "2025-11-01T00:00:00Z")

#   ## Returns
#     {:ok, %{success: count, failed: count, results: [...]}} | {:error, reason}
#   """
#   def resend_callbacks(entity_service_id \\ nil, exttrids \\ nil, opts \\ []) do
#     # Validate that at least one filter is provided
#     if is_nil(entity_service_id) && (is_nil(exttrids) || exttrids == []) do
#       from_date = Keyword.get(opts, :from_date)
#       to_date = Keyword.get(opts, :to_date)

#       if is_nil(from_date) && is_nil(to_date) do
#         {:error, "Must provide at least one filter: entity_service_id, exttrids, or date range"}
#       else
#         do_resend_callbacks(entity_service_id, exttrids, opts)
#       end
#     else
#       do_resend_callbacks(entity_service_id, exttrids, opts)
#     end
#   end

#   defp do_resend_callbacks(entity_service_id, exttrids, opts) do
#     concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
#     timeout = Keyword.get(opts, :timeout, @default_timeout)
#     batch_size = Keyword.get(opts, :batch_size, 20)
#     batch_delay = Keyword.get(opts, :batch_delay, 10_000)
#     http_method = Keyword.get(opts, :http_method, :post)
#     from_date = parse_date(Keyword.get(opts, :from_date))
#     to_date = parse_date(Keyword.get(opts, :to_date))

#     Logger.info("Starting callback resend")
#     if entity_service_id, do: Logger.info("Entity service ID: #{entity_service_id}")
#     if exttrids && length(exttrids) > 0, do: Logger.info("Exttrids: #{inspect(exttrids)}")
#     Logger.info("HTTP Method: #{http_method}, Batch size: #{batch_size}, Batch delay: #{batch_delay}ms")
#     if from_date, do: Logger.info("From date: #{DateTime.to_iso8601(from_date)}")
#     if to_date, do: Logger.info("To date: #{DateTime.to_iso8601(to_date)}")

#     case fetch_pending_callbacks(entity_service_id, exttrids, from_date, to_date) do
#       [] ->
#         Logger.warn("No pending callbacks found")
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
#             fn callback -> resend_single_callback(callback, timeout, http_method) end,
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
#   Now supports optional entity_service_id - can filter by exttrids only.
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

#   defp resend_single_callback(%ServiceCallbackPushReq{} = callback, timeout, http_method) do
#     Logger.debug("Resending callback_req_id: #{callback.id}, exttrid: #{callback.exttrid}, method: #{http_method}")

#     start_time = System.monotonic_time(:millisecond)

#     result = case send_http_request(callback.callback_url, callback.payload, timeout, http_method) do
#       {:ok, status, body} ->
#         duration = System.monotonic_time(:millisecond) - start_time
#         Logger.info("Callback #{callback.id} succeeded in #{duration}ms - Status: #{status}")

#         # Store in service_callback_push_resp
#         store_response(%{
#           entity_service_id: callback.entity_service_id,
#           exttrid: callback.exttrid,
#           response_msg: truncate_response(body, 1000)
#         })

#         {:ok, callback.id, status}

#       {:error, reason} ->
#         duration = System.monotonic_time(:millisecond) - start_time
#         Logger.error("Callback #{callback.id} failed in #{duration}ms - Reason: #{inspect(reason)}")
#         {:error, callback.id, reason}
#     end

#     result
#   end

#   @doc """
#   Send HTTP request to callback URL with configurable method.
#   """
#   defp send_http_request(url, payload, timeout, http_method) do
#     body = case Jason.decode(payload) do
#       {:ok, decoded_payload} -> Jason.encode!(decoded_payload)
#       {:error, _} -> if is_binary(payload), do: payload, else: Jason.encode!(payload)
#     end

#     # Select the appropriate HTTPoison function based on method
#     request_result = case http_method do
#       :post -> HTTPoison.post(url, body, @http_headers, timeout: timeout, recv_timeout: timeout)
#       :put -> HTTPoison.put(url, body, @http_headers, timeout: timeout, recv_timeout: timeout)
#       :patch -> HTTPoison.patch(url, body, @http_headers, timeout: timeout, recv_timeout: timeout)
#       _ -> {:error, "Unsupported HTTP method: #{http_method}"}
#     end

#     case request_result do
#       {:ok, %HTTPoison.Response{status_code: status, body: response_body}}
#         when status >= 200 and status < 300 ->
#         {:ok, status, response_body}

#       {:ok, %HTTPoison.Response{status_code: status, body: response_body}} ->
#         {:error, "HTTP #{status}: #{response_body}"}

#       {:error, %HTTPoison.Error{reason: reason}} ->
#         {:error, reason}

#       {:error, reason} ->
#         {:error, reason}
#     end
#   rescue
#     e ->
#       {:error, Exception.message(e)}
#   end

#   @doc """
#   Store successful callback response in service_callback_push_resp table.
#   """
#   defp store_response(attrs) do
#     %ServiceCallbackPushResp{}
#     |> ServiceCallbackPushResp.changeset(attrs)
#     |> Repo.insert()
#   rescue
#     e ->
#       Logger.error("Failed to store response: #{inspect(e)}")
#       {:error, e}
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
#   Can filter by entity_service_id, exttrids, or both.
#   """
#   def get_pending_count(entity_service_id \\ nil, exttrids \\ nil) do
#     query = from c in ServiceCallbackPushReq,
#       left_join: r in ServiceCallbackPushResp,
#       on: c.exttrid == r.exttrid and c.entity_service_id == r.entity_service_id,
#       where: is_nil(r.id)

#     query = if entity_service_id do
#       from c in query, where: c.entity_service_id == ^entity_service_id
#     else
#       query
#     end

#     query = if exttrids && is_list(exttrids) && length(exttrids) > 0 do
#       from c in query, where: c.exttrid in ^exttrids
#     else
#       query
#     end

#     query = from c in query, select: count(c.id)

#     Repo.one(query) || 0
#   end
# end

defmodule OrchardResend.Resender do
  @moduledoc """
  Module for resending failed callbacks from callback_req table.

  Automatically skips callbacks that already have responses in service_callback_push_resp.
  Stores successful responses in service_callback_push_resp for tracking.
  """

  require Logger
  import Ecto.Query
  alias OrchardResend.Repo
  alias OrchardResend.Schema.{ServiceCallbackPushReq, ServiceCallbackPushResp}

  @default_concurrency 10
  @default_timeout 30_000
  @http_headers [{"Content-Type", "application/json"}]

  def resend_callbacks(entity_service_id, exttrids \\ nil, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    batch_size = Keyword.get(opts, :batch_size, 20)
    batch_delay = Keyword.get(opts, :batch_delay, 10_000)
    from_date = parse_date(Keyword.get(opts, :from_date))
    to_date = parse_date(Keyword.get(opts, :to_date))

    Logger.info("Starting callback resend for entity_service_id: #{entity_service_id}")
    Logger.info("Batch size: #{batch_size}, Batch delay: #{batch_delay}ms")
    if from_date, do: Logger.info("From date: #{DateTime.to_iso8601(from_date)}")
    if to_date, do: Logger.info("To date: #{DateTime.to_iso8601(to_date)}")

    case fetch_pending_callbacks(entity_service_id, exttrids, from_date, to_date) do
      [] ->
        Logger.warn("No pending callbacks found for entity_service_id: #{entity_service_id}")
        {:ok, %{success: 0, failed: 0, results: []}}

      callbacks ->
        total_callbacks = length(callbacks)
        total_batches = div(total_callbacks + batch_size - 1, batch_size)
        Logger.info("Found #{total_callbacks} pending callbacks to resend in #{total_batches} batches")

        # Process in batches with delays
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

  @doc """
  Fetch callbacks that don't have responses yet (LEFT JOIN excludes those with responses).
  """
  defp fetch_pending_callbacks(entity_service_id, exttrids, from_date, to_date) do
    query = from c in ServiceCallbackPushReq,
      left_join: r in ServiceCallbackPushResp,
      on: c.exttrid == r.exttrid and c.entity_service_id == r.entity_service_id,
      where: is_nil(r.id)

    # Apply entity_service_id filter if provided
    query = if entity_service_id do
      from c in query, where: c.entity_service_id == ^entity_service_id
    else
      query
    end

    # Apply exttrids filter if provided
    query = if exttrids && is_list(exttrids) && length(exttrids) > 0 do
      from c in query, where: c.exttrid in ^exttrids
    else
      query
    end

    # Apply date range filters
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

  # defp resend_single_callback(%ServiceCallbackPushReq{} = callback, timeout) do
  #   Logger.debug("Resending callback_req_id: #{callback.id}, exttrid: #{callback.exttrid}")

  #   start_time = System.monotonic_time(:millisecond)

  #   result = case send_http_request(callback.callback_url, callback.payload, timeout) do
  #     {:ok, status, body} ->
  #       duration = System.monotonic_time(:millisecond) - start_time
  #       Logger.info("Callback #{callback.id} succeeded in #{duration}ms - Status: #{status}")

  #       # Store in service_callback_push_resp
  #       case store_response(%{
  #         entity_service_id: callback.entity_service_id,
  #         exttrid: callback.exttrid,
  #         response_msg: truncate_response(body, 1000)
  #       }) do
  #         {:ok, _resp} ->
  #           Logger.debug("Response stored successfully for exttrid: #{callback.exttrid}")
  #           {:ok, callback.id, status}

  #         {:error, %Ecto.Changeset{} = changeset} ->
  #           errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  #           Logger.error("Failed to store response for callback #{callback.id}: #{inspect(errors)}")
  #           {:ok, callback.id, status}  # Still return success since HTTP call succeeded

  #         {:error, reason} ->
  #           Logger.error("Failed to store response for callback #{callback.id}: #{inspect(reason)}")
  #           {:ok, callback.id, status}  # Still return success since HTTP call succeeded
  #       end

  #     {:error, reason} ->
  #       duration = System.monotonic_time(:millisecond) - start_time
  #       Logger.error("Callback #{callback.id} failed in #{duration}ms - Reason: #{inspect(reason)}")
  #       {:error, callback.id, reason}
  #   end

  #   result
  # end
  defp resend_single_callback(%ServiceCallbackPushReq{} = callback, timeout) do
    Logger.debug("Resending callback_req_id: #{callback.id}, exttrid: #{callback.exttrid}")

    start_time = System.monotonic_time(:millisecond)

    result = case send_http_request(callback.callback_url, callback.payload, timeout) do
      {:ok, status, body} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.info("Callback #{callback.id} succeeded in #{duration}ms - Status: #{status}")

        # Prepare response_msg - use placeholder if empty
        response_msg = if body == nil || String.trim(body) == "" do
          "(empty response)"
        else
          truncate_response(body, 1000)
        end

        # Store in service_callback_push_resp
        case store_response(%{
          entity_service_id: callback.entity_service_id,
          exttrid: callback.exttrid,
          response_msg: response_msg
        }) do
          {:ok, _resp} ->
            Logger.debug("Response stored successfully for exttrid: #{callback.exttrid}")
            {:ok, callback.id, status}

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
            Logger.error("Failed to store response for callback #{callback.id}: #{inspect(errors)}")
            {:ok, callback.id, status}  # Still return success since HTTP call succeeded

          {:error, reason} ->
            Logger.error("Failed to store response for callback #{callback.id}: #{inspect(reason)}")
            {:ok, callback.id, status}  # Still return success since HTTP call succeeded
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

    case HTTPoison.post(url, body, @http_headers, timeout: timeout, recv_timeout: timeout) do
      {:ok, %HTTPoison.Response{status_code: status, body: response_body}}
        when status >= 200 and status < 300 ->
        {:ok, status, response_body}

      {:ok, %HTTPoison.Response{status_code: status, body: response_body}} ->
        # Truncate error response to prevent massive logs
        truncated_body = truncate_response(response_body, 200)
        {:error, "HTTP #{status}: #{truncated_body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  @doc """
  Store successful callback response in service_callback_push_resp table.
  """
  defp store_response(attrs) do
    %ServiceCallbackPushResp{}
    |> ServiceCallbackPushResp.changeset(attrs)
    |> Repo.insert()
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

  @doc """
  Get count of pending callbacks (no response yet).
  """
  def get_pending_count(entity_service_id) do
    query = from c in ServiceCallbackPushReq,
      where: c.entity_service_id == ^entity_service_id,
      left_join: r in ServiceCallbackPushResp,
      on: c.exttrid == r.exttrid and c.entity_service_id == r.entity_service_id,
      where: is_nil(r.id),
      select: count(c.id)

    Repo.one(query) || 0
  end
end
