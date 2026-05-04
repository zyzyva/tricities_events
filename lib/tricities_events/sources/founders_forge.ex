defmodule TricitiesEvents.Sources.FoundersForge do
  @behaviour TricitiesEvents.Source

  alias TricitiesEvents.Event

  @url "https://myfoundersforge.com/events/"
  @user_agent "TricitiesEvents/0.1 (calendar aggregator)"

  @impl true
  def name, do: "FoundersForge"

  @impl true
  def fetch do
    with {:ok, %{status: 200, body: html}} <-
           Req.get(@url, headers: [{"user-agent", @user_agent}]),
         {:ok, document} <- Floki.parse_document(html) do
      events =
        document
        |> Floki.find("article.fe-event-card")
        |> Enum.map(&parse_card/1)
        |> Enum.reject(&is_nil/1)

      {:ok, events}
    else
      {:ok, %{status: status}} -> {:error, {:bad_status, status}}
      err -> {:error, err}
    end
  end

  defp parse_card(card) do
    with {:ok, datetime_str} <- find_attr(card, "time.fe-event-card__date", "datetime"),
         {:ok, starts_at} <- parse_datetime(datetime_str),
         summary when is_binary(summary) <- find_text(card, "h3.fe-event-card__title") do
      url = find_attr(card, "a.fe-event-card__link", "href") |> ok_or_nil()
      location = find_text(card, "span.fe-event-card__location")

      %Event{
        uid: build_uid(summary, starts_at),
        source: name(),
        summary: summary,
        location: location,
        url: url,
        starts_at: starts_at
      }
    else
      _ -> nil
    end
  end

  defp find_attr(node, selector, attr) do
    case Floki.find(node, selector) |> Floki.attribute(attr) do
      [value | _] when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp find_text(node, selector) do
    node
    |> Floki.find(selector)
    |> Floki.text()
    |> String.trim()
    |> case do
      "" -> nil
      text -> decode_entities(text)
    end
  end

  defp ok_or_nil({:ok, v}), do: v
  defp ok_or_nil(_), do: nil

  # FoundersForge serves naive datetimes in America/New_York.
  defp parse_datetime(<<y::binary-size(4), "-", mo::binary-size(2), "-", d::binary-size(2),
                        " ", h::binary-size(2), ":", mi::binary-size(2), ":", s::binary-size(2)>>) do
    with {:ok, naive} <-
           NaiveDateTime.new(
             String.to_integer(y),
             String.to_integer(mo),
             String.to_integer(d),
             String.to_integer(h),
             String.to_integer(mi),
             String.to_integer(s)
           ),
         {:ok, local} <- DateTime.from_naive(naive, "America/New_York") do
      {:ok, DateTime.shift_zone!(local, "Etc/UTC")}
    end
  end

  defp parse_datetime(_), do: :error

  defp build_uid(summary, dt) do
    raw = "foundersforge|#{summary}|#{DateTime.to_iso8601(dt)}"

    hash =
      :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> String.slice(0, 16)

    "#{hash}@tricities-events"
  end

  defp decode_entities(text) do
    text
    |> String.replace("&#8217;", "'")
    |> String.replace("&#8216;", "'")
    |> String.replace("&#8220;", "\"")
    |> String.replace("&#8221;", "\"")
    |> String.replace("&amp;", "&")
    |> String.replace("&middot;", "·")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
