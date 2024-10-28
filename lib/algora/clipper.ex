defmodule Algora.Clipper do
  alias Algora.{Storage, Library}

  def clip(video, from, to) do
    playlists = Algora.Admin.get_media_playlists(video)

    %{timeline: timeline, ss: ss} =
      playlists.video.timeline
      |> Enum.reduce(%{elapsed: 0, ss: 0, timeline: []}, fn x, acc ->
        case x do
          %ExM3U8.Tags.MediaInit{uri: uri} ->
            %{
              acc
              | timeline: [
                  %ExM3U8.Tags.MediaInit{uri: Storage.to_absolute(:video, video.uuid, uri)}
                  | acc.timeline
                ]
            }

          %ExM3U8.Tags.Segment{duration: duration} when acc.elapsed > to ->
            %{acc | elapsed: acc.elapsed + duration}

          %ExM3U8.Tags.Segment{duration: duration} when acc.elapsed + duration < from ->
            %{acc | elapsed: acc.elapsed + duration}

          %ExM3U8.Tags.Segment{duration: duration, uri: uri}
          when acc.elapsed < from and acc.elapsed + duration > from ->
            %{
              acc
              | elapsed: acc.elapsed + duration,
                ss: acc.elapsed + duration - from,
                timeline: [
                  %ExM3U8.Tags.Segment{
                    duration: duration,
                    uri: Storage.to_absolute(:video, video.uuid, uri)
                  }
                  | acc.timeline
                ]
            }

          %ExM3U8.Tags.Segment{duration: duration, uri: uri} ->
            %{
              acc
              | elapsed: acc.elapsed + duration,
                timeline: [
                  %ExM3U8.Tags.Segment{
                    duration: duration,
                    uri: Storage.to_absolute(:video, video.uuid, uri)
                  }
                  | acc.timeline
                ]
            }

          _ ->
            acc
        end
      end)
      |> then(fn clip -> %{ss: clip.ss, timeline: Enum.reverse(clip.timeline)} end)

    %{playlist: %{playlists.video | timeline: timeline}, ss: ss}
  end

  def create_clip(video, from, to) do
    uuid = Ecto.UUID.generate()

    %{playlist: playlist, ss: ss} = clip(video, from, to)

    manifest = "#{ExM3U8.serialize(playlist)}#EXT-X-ENDLIST\n"

    {:ok, _} =
      Storage.upload(manifest, "clips/#{uuid}/g3cFdmlkZW8.m3u8",
        content_type: "application/x-mpegURL"
      )

    {:ok, _} =
      ExAws.S3.put_object_copy(
        Storage.bucket(),
        "clips/#{uuid}/index.m3u8",
        Storage.bucket(),
        "#{video.uuid}/index.m3u8"
      )
      |> ExAws.request()

    url = Storage.to_absolute(:clip, uuid, "index.m3u8")
    filename = Slug.slugify("#{video.title}-#{Library.to_hhmmss(from)}-#{Library.to_hhmmss(to)}")

    "ffmpeg -i \"#{url}\" -ss #{ss} -t #{to - from} \"#{filename}.mp4\""
  end

  def create_combined_local_clips(video, clips_params) do
    # Generate a unique filename for the combined clip
    filename = generate_combined_clip_filename(video, clips_params)
    output_path = Path.join(System.tmp_dir(), "#{filename}.mp4")

    # Create a temporary file for the complex filter
    filter_path = Path.join(System.tmp_dir(), "#{filename}_filter.txt")
    File.write!(filter_path, create_filter_complex(clips_params))

    # Construct the FFmpeg command
    ffmpeg_cmd = [
      "-y",
      "-i",
      video.url,
      "-filter_complex_script",
      filter_path,
      "-map",
      "[v]",
      "-map",
      "[a]",
      "-c:v",
      "libx264",
      "-c:a",
      "aac",
      output_path
    ]

    # Execute the FFmpeg command
    case System.cmd("ffmpeg", ffmpeg_cmd, stderr_to_stdout: true) do
      {_, 0} ->
        File.rm(filter_path)
        {:ok, output_path}

      {error, _} ->
        File.rm(filter_path)
        {:error, "FFmpeg error: #{error}"}
    end
  end

  defp generate_combined_clip_filename(video, clips_params) do
    clip_count = map_size(clips_params)

    total_duration =
      Enum.sum(
        Enum.map(clips_params, fn {_, clip} ->
          Library.from_hhmmss(clip["clip_to"]) - Library.from_hhmmss(clip["clip_from"])
        end)
      )

    Slug.slugify("#{video.title}-#{clip_count}clips-#{total_duration}s")
  end

  defp create_filter_complex(clips_params) do
    {filter_complex, _} =
      clips_params
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.reduce({"", 0}, fn {_, clip}, {acc, index} ->
        from = Library.from_hhmmss(clip["clip_from"])
        to = Library.from_hhmmss(clip["clip_to"])

        clip_filter =
          "[0:v]trim=start=#{from}:end=#{to},setpts=PTS-STARTPTS[v#{index}]; " <>
            "[0:a]atrim=start=#{from}:end=#{to},asetpts=PTS-STARTPTS[a#{index}];\n"

        {acc <> clip_filter, index + 1}
      end)

    clip_count = map_size(clips_params)

    video_concat =
      Enum.map_join(0..(clip_count - 1), "", fn i -> "[v#{i}]" end) <>
        "concat=n=#{clip_count}:v=1:a=0[v];\n"

    audio_concat =
      Enum.map_join(0..(clip_count - 1), "", fn i -> "[a#{i}]" end) <>
        "concat=n=#{clip_count}:v=0:a=1[a]"

    filter_complex <> video_concat <> audio_concat
  end
end
