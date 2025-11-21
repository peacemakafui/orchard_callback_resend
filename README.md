# Orchard Callback Resend Script

Elixir script for resending failed callbacks from the `callback_req` table with concurrent HTTP requests and result tracking.

## Features

- **High Performance**: Concurrent HTTP requests using `Task.async_stream`
- **Flexible Filtering**: Filter by `service_id` and optionally by `processing_id` array
- **Result Tracking**: Stores all resend attempts in `resend_callback` table
- **Error Handling**: Comprehensive error handling with retry support
- **Configurable**: Customizable concurrency and timeout settings

## Setup

### 1. Install Dependencies

```bash
cd /opt/makafui/extras/orchard_resend
mix deps.get
```

### 2. Configure Database

Create a `.env` file or export environment variables:

```bash
export ORCHARD_DB="your_database_name"
export ORCHARD_USER="your_db_user"
export ORCHARD_PASS="your_db_password"
export DB_HOST="localhost"
export DB_PORT="5432"
```

### 3. Create Database Table

Run the migration SQL script:

```bash
psql -U your_db_user -d your_database_name -f priv/repo/migrations/001_create_resend_callback.sql
```

Or manually create the table using the schema defined in the migration file.

## Usage

### Basic Usage

Start an IEx session:

```bash
iex -S mix
```

#### Resend all callbacks for a service:

```elixir
OrchardResend.Resender.resend_callbacks("service_id_123")
```

#### Resend specific processing IDs:

```elixir
OrchardResend.Resender.resend_callbacks("service_id_123", ["proc1", "proc2", "proc3"])
```

#### With custom concurrency:

```elixir
OrchardResend.Resender.resend_callbacks("service_id_123", ["proc1", "proc2"], concurrency: 20)
```

#### With custom timeout (milliseconds):

```elixir
OrchardResend.Resender.resend_callbacks("service_id_123", nil, timeout: 60_000)
```

#### Filter by date range:

```elixir
# Resend callbacks created between Nov 1-20, 2025
OrchardResend.Resender.resend_callbacks(
  "service_id_123",
  nil,
  from_date: "2025-11-01T00:00:00Z",
  to_date: "2025-11-20T23:59:59Z"
)
```

#### Combine all filters:

```elixir
# Resend specific processing IDs from the last week with high concurrency
OrchardResend.Resender.resend_callbacks(
  "service_id_123",
  ["proc1", "proc2", "proc3"],
  from_date: "2025-11-13T00:00:00Z",
  to_date: "2025-11-20T23:59:59Z",
  concurrency: 25,
  timeout: 60_000
)
```

### View Resend History

```elixir
# Get resend history for a specific callback_req_id
OrchardResend.Resender.get_resend_history(123)

# Get statistics for a service_id
OrchardResend.Resender.get_resend_stats("service_id_123")
```

## API Response Format

The `resend_callbacks/3` function returns:

```elixir
{:ok, %{
  total: 10,
  success: 8,
  failed: 2,
  results: [
    {:ok, callback_req_id, http_status},
    {:error, callback_req_id, reason},
    ...
  ]
}}
```

## Database Schema

### resend_callback table

| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL | Primary key |
| service_id | VARCHAR(255) | Service identifier |
| processing_id | VARCHAR(255) | Processing identifier |
| response | TEXT | HTTP response body or error message |
| status | VARCHAR(50) | "success" or "failed" |
| http_status | INTEGER | HTTP status code (if applicable) |
| callback_req_id | INTEGER | Foreign key to callback_req table |
| created_at | TIMESTAMP | Creation timestamp |
| updated_at | TIMESTAMP | Last update timestamp |

## Performance

- Default concurrency: 10 concurrent requests
- Default timeout: 30 seconds per request
- Supports thousands of callbacks efficiently
- Response truncation at 5000 characters to prevent database bloat

## Error Handling

- HTTP errors are caught and stored with status "failed"
- Task timeouts are handled gracefully
- Database errors are logged but don't crash the process
- All failures are recorded in the `resend_callback` table

## Examples

### Example 1: Resend failed payments

```elixir
# Resend all failed payments for a specific service
OrchardResend.Resender.resend_callbacks("payment_service_v2")
```

### Example 2: Resend specific transactions

```elixir
# Resend only specific processing IDs with high concurrency
processing_ids = ["TXN001", "TXN002", "TXN003", "TXN004", "TXN005"]
OrchardResend.Resender.resend_callbacks(
  "payment_service_v2",
  processing_ids,
  concurrency: 25,
  timeout: 45_000
)
```

### Example 3: Resend callbacks from a specific date range

```elixir
# Resend all callbacks from the first week of November 2025
OrchardResend.Resender.resend_callbacks(
  "payment_service_v2",
  nil,
  from_date: "2025-11-01T00:00:00Z",
  to_date: "2025-11-07T23:59:59Z"
)

# Or resend specific processing IDs from last 24 hours
yesterday = DateTime.utc_now() |> DateTime.add(-24, :hour)
OrchardResend.Resender.resend_callbacks(
  "payment_service_v2",
  ["TXN123", "TXN456"],
  from_date: yesterday
)
```

### Example 4: Check results

```elixir
# View statistics
stats = OrchardResend.Resender.get_resend_stats("payment_service_v2")
IO.inspect(stats)
# %{total: 100, success: 95, failed: 5}

# View detailed history for a specific callback
history = OrchardResend.Resender.get_resend_history(42)
Enum.each(history, fn record ->
  IO.puts("Status: #{record.status}, HTTP: #{record.http_status}")
end)
```

## Troubleshooting

### Issue: Database connection fails

**Solution**: Verify environment variables are set correctly:
```bash
echo $ORCHARD_DB
echo $ORCHARD_USER
```

### Issue: HTTP timeouts

**Solution**: Increase timeout value:
```elixir
OrchardResend.Resender.resend_callbacks("service_id", nil, timeout: 60_000)
```

### Issue: Too many concurrent connections

**Solution**: Reduce concurrency:
```elixir
OrchardResend.Resender.resend_callbacks("service_id", nil, concurrency: 5)
```

## Development

### Run tests (if added):
```bash
mix test
```

### Format code:
```bash
mix format
```

### Check for warnings:
```bash
mix compile --warnings-as-errors
```

## License

Internal use only - AppsNmobile Solutions

OrchardResend.Resender.resend_callbacks(
  2430,
  nil,
  from_date: "2025-11-19T11:27:00Z",
  to_date: "2025-11-20T23:59:59Z",
  batch_size: 30,
  batch_delay: 10_000,
  concurrency: 15
)