defmodule AllbertAssist.Jobs.Schedule do
  @moduledoc """
  Normalization and next-due calculation for local scheduled jobs.
  """

  @timezone_database Tzdata.TimeZoneDatabase
  @max_cron_scan_minutes 366 * 24 * 60

  @weekdays %{
    "monday" => 1,
    "tuesday" => 2,
    "wednesday" => 3,
    "thursday" => 4,
    "friday" => 5,
    "saturday" => 6,
    "sunday" => 7
  }

  @weekdays_by_number Map.new(@weekdays, fn {name, number} -> {number, name} end)

  @doc "Normalize a supported job schedule into a string-keyed map."
  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  def normalize(schedule) when is_map(schedule) do
    schedule = string_key_map(schedule)

    schedule
    |> Map.get("kind")
    |> normalize_kind()
    |> normalize_kind_schedule(schedule)
  end

  def normalize(_schedule), do: {:error, {:invalid_schedule, :not_a_map}}

  @doc "Validate a time zone name against the configured time-zone database."
  @spec validate_timezone(String.t()) :: :ok | {:error, term()}
  def validate_timezone(timezone) when is_binary(timezone) do
    timezone = String.trim(timezone)

    case DateTime.now(database_timezone(timezone), @timezone_database) do
      {:ok, _datetime} -> :ok
      {:error, reason} -> {:error, {:invalid_timezone, reason}}
    end
  rescue
    _error -> {:error, :invalid_timezone}
  end

  def validate_timezone(_timezone), do: {:error, :invalid_timezone}

  @doc "Return the next UTC due time for a normalized schedule."
  @spec next_due(map(), String.t(), DateTime.t()) :: {:ok, DateTime.t() | nil} | {:error, term()}
  def next_due(schedule, timezone, now \\ utc_now())

  def next_due(schedule, timezone, %DateTime{} = now) do
    with {:ok, normalized} <- normalize(schedule),
         :ok <- validate_timezone(timezone) do
      next_due_for(normalized, timezone, DateTime.truncate(now, :second))
    end
  end

  def next_due(_schedule, _timezone, _now), do: {:error, :invalid_now}

  defp normalize_kind_schedule("manual", _schedule), do: {:ok, %{"kind" => "manual"}}

  defp normalize_kind_schedule("daily", schedule) do
    with {:ok, at} <- normalize_time(Map.get(schedule, "at")) do
      {:ok, %{"kind" => "daily", "at" => at}}
    end
  end

  defp normalize_kind_schedule("weekly", schedule) do
    with {:ok, weekday} <- normalize_weekday(Map.get(schedule, "weekday")),
         {:ok, at} <- normalize_time(Map.get(schedule, "at")) do
      {:ok, %{"kind" => "weekly", "weekday" => weekday, "at" => at}}
    end
  end

  defp normalize_kind_schedule("cron", schedule) do
    expression = schedule |> Map.get("expression") |> normalize_string()

    with {:ok, _fields} <- parse_cron_expression(expression) do
      {:ok, %{"kind" => "cron", "expression" => expression}}
    end
  end

  defp normalize_kind_schedule(kind, _schedule), do: {:error, {:unsupported_schedule_kind, kind}}

  defp next_due_for(%{"kind" => "manual"}, _timezone, _now), do: {:ok, nil}

  defp next_due_for(%{"kind" => "daily", "at" => at}, timezone, now) do
    with {:ok, local_now} <- shift_to_zone(now, timezone),
         {:ok, time} <- time_from_string(at),
         {:ok, due} <- next_daily_due(local_now, timezone, time, now) do
      {:ok, due}
    end
  end

  defp next_due_for(%{"kind" => "weekly", "weekday" => weekday, "at" => at}, timezone, now) do
    with {:ok, local_now} <- shift_to_zone(now, timezone),
         {:ok, time} <- time_from_string(at),
         target_day <- Map.fetch!(@weekdays, weekday),
         {:ok, due} <- next_weekly_due(local_now, timezone, target_day, time, now) do
      {:ok, due}
    end
  end

  defp next_due_for(%{"kind" => "cron", "expression" => expression}, timezone, now) do
    with {:ok, fields} <- parse_cron_expression(expression),
         {:ok, local_now} <- shift_to_zone(now, timezone),
         {:ok, due} <- next_cron_due(fields, timezone, local_now) do
      {:ok, due}
    end
  end

  defp next_daily_due(local_now, timezone, time, now) do
    today = DateTime.to_date(local_now)

    with {:ok, candidate} <- local_to_utc(today, time, timezone) do
      if DateTime.compare(candidate, now) == :gt do
        {:ok, candidate}
      else
        today
        |> Date.add(1)
        |> local_to_utc(time, timezone)
      end
    end
  end

  defp next_weekly_due(local_now, timezone, target_day, time, now) do
    today = DateTime.to_date(local_now)
    current_day = Date.day_of_week(today)
    offset = rem(target_day - current_day + 7, 7)
    date = Date.add(today, offset)

    with {:ok, candidate} <- local_to_utc(date, time, timezone) do
      if offset > 0 or DateTime.compare(candidate, now) == :gt do
        {:ok, candidate}
      else
        today
        |> Date.add(7)
        |> local_to_utc(time, timezone)
      end
    end
  end

  defp next_cron_due(fields, timezone, local_now) do
    candidate = next_minute(local_now)

    Enum.reduce_while(1..@max_cron_scan_minutes, candidate, fn _minute, datetime ->
      if cron_match?(datetime, fields) do
        case shift_to_utc(datetime) do
          {:ok, due} -> {:halt, {:ok, due}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, DateTime.add(datetime, 60, :second, @timezone_database)}
      end
    end)
    |> case do
      {:ok, due} -> {:ok, due}
      {:error, reason} -> {:error, reason}
      %DateTime{} -> {:error, {:cron_next_due_not_found, timezone}}
    end
  end

  defp cron_match?(%DateTime{} = datetime, fields) do
    date = DateTime.to_date(datetime)
    weekday = rem(Date.day_of_week(date), 7)

    datetime.minute in fields.minutes and
      datetime.hour in fields.hours and
      date.day in fields.days and
      date.month in fields.months and
      weekday in fields.weekdays
  end

  defp parse_cron_expression(expression) when is_binary(expression) do
    case String.split(expression, ~r/\s+/, trim: true) do
      [minutes, hours, days, months, weekdays] ->
        with {:ok, minutes} <- parse_cron_field(minutes, 0, 59),
             {:ok, hours} <- parse_cron_field(hours, 0, 23),
             {:ok, days} <- parse_cron_field(days, 1, 31),
             {:ok, months} <- parse_cron_field(months, 1, 12),
             {:ok, weekdays} <- parse_cron_field(weekdays, 0, 7, weekday?: true) do
          {:ok,
           %{
             minutes: minutes,
             hours: hours,
             days: days,
             months: months,
             weekdays: weekdays
           }}
        end

      _other ->
        {:error, :invalid_cron_expression}
    end
  end

  defp parse_cron_expression(_expression), do: {:error, :invalid_cron_expression}

  defp parse_cron_field(value, min, max, opts \\ []) do
    case String.split(value, ",", trim: true) do
      [] ->
        {:error, :invalid_cron_field}

      tokens ->
        Enum.reduce_while(tokens, {:ok, MapSet.new()}, fn token, {:ok, acc} ->
          case parse_cron_token(token, min, max, opts) do
            {:ok, values} -> {:cont, {:ok, MapSet.union(acc, values)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  rescue
    _error -> {:error, :invalid_cron_field}
  end

  defp parse_cron_token("*", min, max, opts), do: {:ok, cron_range(min, max, opts)}

  defp parse_cron_token(token, min, max, opts) do
    cond do
      String.contains?(token, "/") ->
        {:error, {:unsupported_cron_syntax, token}}

      String.contains?(token, "-") ->
        parse_cron_range(token, min, max, opts)

      true ->
        parse_cron_value(token, min, max, opts)
    end
  end

  defp parse_cron_range(token, min, max, opts) do
    case String.split(token, "-", parts: 2) do
      [first, last] ->
        with {:ok, first} <- parse_integer(first, min, max),
             {:ok, last} <- parse_integer(last, min, max),
             true <- first <= last do
          {:ok, cron_range(first, last, opts)}
        else
          false -> {:error, {:invalid_cron_range, token}}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, {:invalid_cron_range, token}}
    end
  end

  defp parse_cron_value(token, min, max, opts) do
    with {:ok, value} <- parse_integer(token, min, max) do
      {:ok, MapSet.new([normalize_cron_value(value, opts)])}
    end
  end

  defp cron_range(min, max, opts) do
    min..max
    |> Enum.map(&normalize_cron_value(&1, opts))
    |> MapSet.new()
  end

  defp normalize_cron_value(7, weekday?: true), do: 0
  defp normalize_cron_value(value, _opts), do: value

  defp parse_integer(value, min, max) do
    case Integer.parse(value) do
      {integer, ""} when integer >= min and integer <= max -> {:ok, integer}
      _other -> {:error, {:invalid_cron_value, value}}
    end
  end

  defp normalize_time(value) do
    value = normalize_string(value)

    case Regex.run(~r/^(\d{1,2}):(\d{2})$/, value) do
      [_match, hour, minute] ->
        with {:ok, hour} <- parse_time_part(hour, 0, 23),
             {:ok, minute} <- parse_time_part(minute, 0, 59) do
          {:ok, "#{pad2(hour)}:#{pad2(minute)}"}
        else
          _error -> {:error, {:invalid_time, value}}
        end

      _other ->
        {:error, {:invalid_time, value}}
    end
  end

  defp time_from_string(value) do
    with {:ok, at} <- normalize_time(value),
         [hour, minute] <- String.split(at, ":", parts: 2),
         {:ok, hour} <- parse_time_part(hour, 0, 23),
         {:ok, minute} <- parse_time_part(minute, 0, 59) do
      Time.new(hour, minute, 0)
    else
      _other -> {:error, {:invalid_time, value}}
    end
  end

  defp parse_time_part(value, min, max) do
    case Integer.parse(value) do
      {integer, ""} when integer >= min and integer <= max -> {:ok, integer}
      _other -> {:error, {:invalid_time_part, value}}
    end
  end

  defp normalize_weekday(value) when is_integer(value) and value in 1..7 do
    {:ok, Map.fetch!(@weekdays_by_number, value)}
  end

  defp normalize_weekday(value) do
    weekday =
      value
      |> normalize_string()
      |> String.downcase()

    if Map.has_key?(@weekdays, weekday) do
      {:ok, weekday}
    else
      {:error, {:invalid_weekday, value}}
    end
  end

  defp shift_to_zone(datetime, timezone) do
    DateTime.shift_zone(datetime, database_timezone(timezone), @timezone_database)
  end

  defp shift_to_utc(datetime) do
    DateTime.shift_zone(datetime, "Etc/UTC", @timezone_database)
  end

  defp local_to_utc(date, time, timezone) do
    case DateTime.new(date, time, database_timezone(timezone), @timezone_database) do
      {:ok, datetime} -> shift_to_utc(datetime)
      {:ambiguous, first, _second} -> shift_to_utc(first)
      {:gap, _before, after_gap} -> shift_to_utc(after_gap)
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_minute(%DateTime{} = datetime) do
    datetime
    |> DateTime.add(60 - datetime.second, :second, @timezone_database)
    |> Map.put(:second, 0)
    |> Map.put(:microsecond, {0, 0})
  end

  defp database_timezone("UTC"), do: "Etc/UTC"
  defp database_timezone(timezone), do: timezone

  defp normalize_kind(value) do
    value
    |> normalize_string()
    |> String.downcase()
  end

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(value) when is_atom(value), do: value |> Atom.to_string() |> String.trim()
  defp normalize_string(value), do: value |> to_string() |> String.trim()

  defp string_key_map(map) do
    Map.new(map, fn {key, value} -> {normalize_string(key), value} end)
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
