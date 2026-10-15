class Invidious::Jobs::RefreshChannelsJob < Invidious::Jobs::BaseJob
  private getter db : DB::Database

  def initialize(@db)
  end

  def begin
    max_fibers = CONFIG.channel_threads
    lim_fibers = max_fibers
    active_fibers = 0
    active_channel = ::Channel(Bool).new
    backoff = 2.minutes

    loop do
      LOGGER.debug("RefreshChannelsJob: Refreshing all channels")
      begin
        ids = PG_DB.query_all("SELECT id FROM channels ORDER BY updated", as: String)
      rescue ex
        LOGGER.error("RefreshChannelsJob: #{ex.message}")
        ids = [] of String
      end

      ids.each do |id|
        if active_fibers >= lim_fibers
          LOGGER.trace("RefreshChannelsJob: Fiber limit reached, waiting...")
          if active_channel.receive
            LOGGER.trace("RefreshChannelsJob: Fiber limit ok, continuing")
            active_fibers -= 1
          end
        end

        LOGGER.debug("RefreshChannelsJob: #{id} : Spawning fiber")
        active_fibers += 1
        spawn do
          begin
            LOGGER.trace("RefreshChannelsJob: #{id} fiber : Fetching channel")
            channel = fetch_channel(id, pull_all_videos: CONFIG.full_refresh)

            lim_fibers = max_fibers

            LOGGER.trace("RefreshChannelsJob: #{id} fiber : Updating DB")
            Invidious::Database::Channels.update_author(id, channel.author)

            Invidious::Metrics::REFRESH_SUCCESS.add(1)
            Invidious::Metrics::REFRESH_BACKOFF.set(0_i64)

            if backoff > 2.minutes
              LOGGER.debug("RefreshChannelsJob: #{id} fiber : decreasing backoff to #{backoff}s")
              backoff = 2.minutes
            end
          rescue ex
            LOGGER.error("RefreshChannelsJob: #{id} : #{ex.message}")
            if ex.message == "Deleted or invalid channel"
              Invidious::Metrics::REFRESH_DELETED.add(1)
              Invidious::Database::Channels.update_mark_deleted(id)
            elsif ex.message == "RSS feed unavailable"
              Invidious::Metrics::REFRESH_UNAVAILABLE.add(1)
            else
              Invidious::Metrics::REFRESH_ERROR.add(1)
              Invidious::Metrics::REFRESH_BACKOFF.set(backoff.total_seconds.to_i64)
              lim_fibers = 1
              LOGGER.error("RefreshChannelsJob: #{id} fiber : backing off for #{backoff}s")
              sleep backoff
              # Step up a fixed ladder (2/3/5/10/15 min) instead of doubling
              # without a cap. backoff is shared by every fiber, so one upstream
              # hiccup that hits all of them at once used to multiply it several
              # times over and could reach the old 1 day ceiling from a single
              # bad moment. A flat ladder keeps that bounded.
              backoff = case backoff
                        when 2.minutes then 3.minutes
                        when 3.minutes then 5.minutes
                        when 5.minutes then 10.minutes
                        else                15.minutes
                        end
            end
          ensure
            LOGGER.debug("RefreshChannelsJob: #{id} fiber : Done")
            active_channel.send(true)
          end
        end
      end

      Invidious::Metrics::REFRESH_LAST_PASS.set(Time.utc.to_unix)

      LOGGER.debug("RefreshChannelsJob: Done, sleeping for #{CONFIG.channel_refresh_interval}")
      sleep CONFIG.channel_refresh_interval
      Fiber.yield
    end
  end
end
