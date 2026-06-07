defmodule TricitiesEvents.Newsletter.Extractor do
  @moduledoc """
  Extracts calendar events from a chamber/community newsletter email using Groq
  (multimodal Llama 4 Scout). Chamber newsletters bury the actual dates in
  schedule *images*, so we send the email's subject + text + embedded image URLs
  and let the vision model read both.

  Reuses the proven pattern from contacts4us' card scanner: Groq's OpenAI-compatible
  /chat/completions endpoint, temperature 0, JSON-array output, tolerant parsing.

  Input email map:
      %{source: "Elizabethton Chamber", subject: "...", received_at: "2026-02-09T..Z",
        text: "...", image_urls: ["https://...", ...]}

  Returns {:ok, [%TricitiesEvents.Event{}]} | {:error, term}.
  """

  alias TricitiesEvents.Event

  @endpoint "https://api.groq.com/openai/v1/chat/completions"
  @model "meta-llama/llama-4-scout-17b-16e-instruct"
  # Llama 4 Scout on Groq accepts at most 5 images per request, so we batch.
  @batch 5
  @tz "America/New_York"

  @system """
  You extract calendar events from Chamber of Commerce / community newsletters.
  You receive an email's date, subject, text body, and embedded images (schedule
  graphics often hold the real dates). Combine text and images.

  Return ONLY a JSON array — no prose, no markdown fences. Each event:
  {"summary": string, "date": "YYYY-MM-DD", "time": "HH:MM" 24h or null,
   "location": string or null, "source_note": short string or null}

  Rules:
  - Resolve relative dates ("this Friday", "today") against the EMAIL DATE. Year 2026 unless stated.
  - Expand multi-date schedules into one object per date.
  - Only real, attendable events (meetings, breakfasts, ribbon cuttings, galas, mixers,
    classes). EXCLUDE office-closure notices, job postings, sales/discount promos,
    member spotlights, and generic marketing. If nothing qualifies, return [].
  """

  @doc "Full extraction: {:ok, [%Event{}]} | {:error, reason}."
  def extract(%{} = email) do
    with {:ok, items} <- extract_items(email) do
      {:ok, to_events(items, email)}
    end
  end

  @doc """
  The expensive half (Groq calls) — returns the raw deduped item maps so they can
  be cached per email. {:ok, [item_map]} on success (possibly empty), {:error, _}
  on failure (so callers don't cache a transient failure).
  """
  def extract_items(%{} = email) do
    case api_key() do
      {:ok, key} ->
        items =
          email
          |> image_batches()
          |> Enum.flat_map(&extract_batch(email, &1, key))
          |> dedupe_items()

        {:ok, items}

      err ->
        err
    end
  end

  @doc "The cheap, deterministic half — map cached/fresh items to %Event{} structs."
  def to_events(items, email) when is_list(items) do
    items
    |> Enum.map(&to_event(&1, email))
    |> Enum.reject(&is_nil/1)
  end

  # Chunk embedded images into ≤5-image batches (model limit); one text-only batch
  # when there are no images. Text is included in every batch so prose-only events
  # are caught regardless; dedupe_items/1 collapses the repeats.
  defp image_batches(email) do
    case Map.get(email, :image_urls, []) do
      [] -> [[]]
      urls -> Enum.chunk_every(urls, @batch)
    end
  end

  defp extract_batch(email, image_urls, key) do
    with {:ok, content} <- call_groq(email, image_urls, key),
         {:ok, items} <- parse(content) do
      items
    else
      _ -> []
    end
  end

  defp dedupe_items(items) do
    Enum.uniq_by(items, fn i ->
      {i |> Map.get("summary", "") |> to_string() |> String.downcase(), i["date"], i["time"]}
    end)
  end

  defp api_key do
    case System.get_env("GROQ_API_KEY") do
      nil -> {:error, :no_groq_api_key}
      "" -> {:error, :no_groq_api_key}
      key -> {:ok, key}
    end
  end

  defp call_groq(email, image_urls, key) do
    images = Enum.map(image_urls, fn url -> %{type: "image_url", image_url: %{url: url}} end)

    user_text = """
    EMAIL DATE: #{email[:received_at]}
    SOURCE: #{email[:source]}
    SUBJECT: #{email[:subject]}
    BODY:
    #{strip(email[:text])}
    """

    body = %{
      model: @model,
      temperature: 0.0,
      max_tokens: 4096,
      messages: [
        %{role: "system", content: @system},
        %{role: "user", content: [%{type: "text", text: user_text} | images]}
      ]
    }

    case Req.post(@endpoint,
           json: body,
           headers: [{"authorization", "Bearer #{key}"}],
           receive_timeout: 90_000,
           retry: :transient
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => c}} | _]}}} ->
        {:ok, c}

      {:ok, %{status: status, body: b}} ->
        {:error, {:groq_status, status, b}}

      {:error, e} ->
        {:error, e}
    end
  end

  # Newsletter plaintext is full of Mailchimp/CC spacer glyphs; collapse them so we
  # don't waste tokens (and the model doesn't choke on noise).
  defp strip(nil), do: ""

  defp strip(text) do
    text
    |> String.replace(~r/[\x{034f}\x{200c}\x{00ad}\x{a0}\x{2007}\x{2060}]/u, " ")
    |> String.replace(~r/[ \t]{2,}/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> String.slice(0, 6000)
  end

  # Tolerant parse: strip fences, grab the outermost JSON array.
  defp parse(content) do
    cleaned =
      content
      |> String.replace(~r/```json/i, "")
      |> String.replace("```", "")
      |> String.trim()

    case Regex.run(~r/\[.*\]/s, cleaned) do
      [json] ->
        case JSON.decode(json) do
          {:ok, list} when is_list(list) -> {:ok, list}
          _ -> {:error, {:bad_json, content}}
        end

      _ ->
        {:error, {:no_json_array, content}}
    end
  end

  defp to_event(%{"summary" => summary, "date" => date} = item, email)
       when is_binary(summary) and is_binary(date) and summary != "" do
    with {:ok, starts_at} <- build_datetime(date, item["time"]) do
      time_note = if is_nil(item["time"]), do: " (time unconfirmed)", else: ""

      %Event{
        uid: uid(summary, starts_at),
        source: email[:source] || "Newsletter",
        summary: summary,
        location: blank_to_nil(item["location"]),
        description: blank_to_nil(item["source_note"]) |> append(time_note),
        starts_at: starts_at
      }
    else
      _ -> nil
    end
  end

  defp to_event(_, _), do: nil

  defp build_datetime(date, time) do
    time = if is_binary(time) and time =~ ~r/^\d{1,2}:\d{2}$/, do: time, else: "09:00"

    with {:ok, d} <- Date.from_iso8601(date),
         [h, m] <- String.split(time, ":"),
         {:ok, t} <- Time.new(String.to_integer(h), String.to_integer(m), 0),
         {:ok, naive} <- NaiveDateTime.new(d, t),
         {:ok, local} <- DateTime.from_naive(naive, @tz) do
      {:ok, DateTime.shift_zone!(local, "Etc/UTC")}
    else
      _ -> :error
    end
  end

  defp uid(summary, dt) do
    raw = "newsletter|#{summary}|#{DateTime.to_iso8601(dt)}"
    hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> String.slice(0, 16)
    "#{hash}@tricities-events"
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s
  defp blank_to_nil(_), do: nil

  defp append(nil, ""), do: nil
  defp append(nil, note), do: String.trim(note)
  defp append(base, note), do: base <> note
end
