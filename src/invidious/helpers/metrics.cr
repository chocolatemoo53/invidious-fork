module Invidious::Metrics
  extend self

  REFRESH_SUCCESS     = Atomic(Int64).new(0_i64)
  REFRESH_ERROR       = Atomic(Int64).new(0_i64)
  REFRESH_DELETED     = Atomic(Int64).new(0_i64)
  REFRESH_UNAVAILABLE = Atomic(Int64).new(0_i64)
  REFRESH_LAST_PASS   = Atomic(Int64).new(0_i64)
  REFRESH_BACKOFF     = Atomic(Int64).new(0_i64)
  VIDEOS_FROM_REFRESH = Atomic(Int64).new(0_i64)
  VIDEOS_FROM_PUBSUB  = Atomic(Int64).new(0_i64)

  def render : String
    channels = PG_DB.query_one(<<-SQL, as: {Int64, Int64, Int64, Int64})
      SELECT count(*),
             count(*) FILTER (WHERE updated < now() - interval '1 hour'),
             count(*) FILTER (WHERE updated < now() - interval '1 day'),
             count(*) FILTER (WHERE deleted)
      FROM channels
      SQL

    String.build do |io|
      metric(io, "invidious_channel_refresh_total", "counter", "Channel refreshes by the refresh job, by result.", {
        %(result="success")     => REFRESH_SUCCESS.get,
        %(result="error")       => REFRESH_ERROR.get,
        %(result="deleted")     => REFRESH_DELETED.get,
        %(result="unavailable") => REFRESH_UNAVAILABLE.get,
      })
      metric(io, "invidious_channel_refresh_last_pass_timestamp_seconds", "gauge", "When the refresh job last queued every channel, 0 if it hasn't yet.", {
        "" => REFRESH_LAST_PASS.get,
      })
      metric(io, "invidious_channel_refresh_backoff_seconds", "gauge", "Current refresh job backoff after an error, 0 when healthy.", {
        "" => REFRESH_BACKOFF.get,
      })
      metric(io, "invidious_channel_videos_inserted_total", "counter", "New videos added to subscription feeds, by source.", {
        %(source="refresh") => VIDEOS_FROM_REFRESH.get,
        %(source="pubsub")  => VIDEOS_FROM_PUBSUB.get,
      })
      metric(io, "invidious_channels", "gauge", "Channels in the database, by refresh state.", {
        %(state="all")      => channels[0],
        %(state="stale_1h") => channels[1],
        %(state="stale_1d") => channels[2],
        %(state="deleted")  => channels[3],
      })
      metric(io, "invidious_users", "gauge", "Registered users, by activity.", {
        %(state="all")       => Invidious::Database::Statistics.count_users_total,
        %(state="active_1m") => Invidious::Database::Statistics.count_users_active_1m,
        %(state="active_6m") => Invidious::Database::Statistics.count_users_active_6m,
      })
    end
  end

  private def metric(io, name, type, help, samples)
    io << "# HELP " << name << ' ' << help << '\n'
    io << "# TYPE " << name << ' ' << type << '\n'
    samples.each do |labels, value|
      io << name
      io << '{' << labels << '}' unless labels.empty?
      io << ' ' << value << '\n'
    end
  end
end
