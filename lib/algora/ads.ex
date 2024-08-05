defmodule Algora.Ads do
  @moduledoc """
  The Ads context.
  """

  import Ecto.Query, warn: false
  alias Algora.Repo

  alias Algora.Ads.{Ad, Visit, Impression, Events}

  @pubsub Algora.PubSub

  def display_duration, do: :timer.seconds(20)
  def rotation_interval, do: :timer.minutes(10)

  def unsubscribe_to_ads() do
    Phoenix.PubSub.unsubscribe(@pubsub, topic())
  end

  def subscribe_to_ads() do
    Phoenix.PubSub.subscribe(@pubsub, topic())
  end

  defp topic(), do: "ads"

  defp broadcast!(topic, msg) do
    Phoenix.PubSub.broadcast!(@pubsub, topic, {__MODULE__, msg})
  end

  def broadcast_ad_created!(ad) do
    broadcast!(topic(), %Events.AdCreated{ad: ad})
  end

  def broadcast_ad_updated!(ad) do
    broadcast!(topic(), %Events.AdUpdated{ad: ad})
  end

  def broadcast_ad_deleted!(ad) do
    broadcast!(topic(), %Events.AdDeleted{ad: ad})
  end

  @doc """
  Returns the list of ads.

  ## Examples

      iex> list_ads()
      [%Ad{}, ...]

  """
  def list_ads do
    Ad
    |> where(verified: true, status: :active)
    |> order_by(asc: :id)
    |> Repo.all()
  end

  @doc """
  Gets a single ad.

  Raises `Ecto.NoResultsError` if the Ad does not exist.

  ## Examples

      iex> get_ad!(123)
      %Ad{}

      iex> get_ad!(456)
      ** (Ecto.NoResultsError)

  """
  def get_ad!(id), do: Repo.get!(Ad, id)

  def get_ad_by_slug!(slug) do
    Repo.get_by!(Ad, slug: slug)
  end

  @doc """
  Creates a ad.

  ## Examples

      iex> create_ad(%{field: value})
      {:ok, %Ad{}}

      iex> create_ad(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_ad(attrs \\ %{}) do
    %Ad{status: :active, verified: true}
    |> Ad.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a ad.

  ## Examples

      iex> update_ad(ad, %{field: new_value})
      {:ok, %Ad{}}

      iex> update_ad(ad, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_ad(%Ad{} = ad, attrs) do
    ad
    |> Ad.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a ad.

  ## Examples

      iex> delete_ad(ad)
      {:ok, %Ad{}}

      iex> delete_ad(ad)
      {:error, %Ecto.Changeset{}}

  """
  def delete_ad(%Ad{} = ad) do
    Repo.delete(ad)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking ad changes.

  ## Examples

      iex> change_ad(ad)
      %Ecto.Changeset{data: %Ad{}}

  """
  def change_ad(%Ad{} = ad, attrs \\ %{}) do
    Ad.changeset(ad, attrs)
  end

  def track_visit(attrs \\ %{}) do
    %Visit{}
    |> Visit.changeset(attrs)
    |> Repo.insert()
  end

  def track_impressions(attrs \\ %{}) do
    %Impression{}
    |> Impression.changeset(attrs)
    |> Repo.insert()
  end

  def get_current_index(ads) do
    :os.system_time(:millisecond)
    |> div(rotation_interval())
    |> rem(length(ads))
  end

  def rotate_ads(ads, index \\ nil) do
    index = index || get_current_index(ads)
    Enum.concat(Enum.drop(ads, index), Enum.take(ads, index))
  end

  def next_slot(time \\ DateTime.utc_now()) do
    time
    |> DateTime.truncate(:millisecond)
    |> DateTime.add(ms_until_next_slot(time), :millisecond)
  end

  def time_until_next_slot(time \\ DateTime.utc_now()) do
    DateTime.diff(next_slot(time), time, :millisecond)
  end

  defp ms_until_next_slot(time) do
    rotation_interval() - rem(DateTime.to_unix(time, :millisecond), rotation_interval())
  end
end
