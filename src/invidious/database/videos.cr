require "./base.cr"
require "redis"
require "lru"

module Invidious::Database::Videos
  extend self

  @@cache : (CacheMethods::LRU | CacheMethods::InternalRedis | CacheMethods::PostgresSQL)? = nil

  enum CacheType
    Postgres = 0
    Redis    = 1
    LRU      = 2
  end

  class VideoCacheInfo
    include DB::Serializable
    include JSON::Serializable

    property id : String
    property info : String
    property updated : Time

    def initialize(@id, @info, @updated)
    end
  end

  module CacheCompression
    extend self

    def compress(video_info : String) : String
      compressed = IO::Memory.new
      uncompressed = IO::Memory.new
      uncompressed << video_info
      uncompressed.rewind
      Compress::Deflate::Writer.open(compressed, Compress::Deflate::BEST_SPEED) do |deflate|
        IO.copy(uncompressed, deflate)
      end
      compressed.rewind
      return compressed.gets_to_end
    end

    def decompress(video_info_compressed : String) : String?
      compressed = IO::Memory.new
      compressed << video_info_compressed
      compressed.rewind
      decompressed = Compress::Deflate::Reader.new(compressed, sync_close: true)
      return decompressed.gets_to_end
    end
  end

  module CacheMethods
    class LRU
      @max_size : Int32

      def initialize(
        @max_size = CONFIG.video_cache.lru_max_size,
      )
        @cache = LRUCache(VideoCacheInfo).new(max_size: @max_size, clean_interval: 1.second)
        LOGGER.info "Video Cache: Using in memory LRU to store video cache"
        LOGGER.info "Video Cache, LRU: LRU cache max size set to #{@max_size}"
      end

      def set(video : VideoCacheInfo, expire_time)
        if CONFIG.video_cache.compress
          video.info = CacheCompression.compress(video.info)
        end

        @cache.set(video.id, video, expire_time)
      end

      def del(video_id : String)
        @cache.del(video_id)
      end

      def get(video_id : String)
        cached_video = @cache.get(video_id)
        return if cached_video.nil?

        if CONFIG.video_cache.compress && (cached_video.info[0] != '{')
          cached_video.info = CacheCompression.decompress(cached_video.info)
        end

        cached_video
      end
    end

    class InternalRedis
      @client : Redis::Client

      def initialize
        @client = begin
          Redis::Client.new(CONFIG.redis_url)
        rescue ex
          LOGGER.fatal "Video Cache: Failed to connect to redis database: '#{ex.message}'"
          exit(1)
        end
        LOGGER.info "Video Cache: Using Redis compatible DB to store video cache"
        LOGGER.info "Connecting to Redis compatible DB"
        if @client.ping
          LOGGER.info "Connected to Redis compatible DB at '#{CONFIG.redis_url}'" if CONFIG.redis_url
        end
      end

      def set(video : VideoCacheInfo, expire_time)
        video_json = video.to_json

        if CONFIG.video_cache.compress
          video_json_compressed = CacheCompression.compress(video_json)
          @client.set(video.id, video_json_compressed, ex: expire_time)
        else
          @client.set(video.id, video_json, ex: expire_time)
        end
      end

      def del(video_id : String)
        @client.del(video_id)
      end

      def get(video_id : String)
        cached_video = @client.get(video_id)
        return if cached_video.nil?

        # With the { we identify if it's a JSON or not
        if CONFIG.video_cache.compress && (cached_video[0] != '{')
          video_json_decompressed = CacheCompression.decompress(cached_video)
          return VideoCacheInfo.from_json(video_json_decompressed)
        else
          return VideoCacheInfo.from_json(cached_video)
        end
      end
    end

    class PostgresSQL
      def initialize
        LOGGER.info "Video Cache: Using PostgreSQL to store video cache"
        if CONFIG.video_cache.compress
          LOGGER.warn "Video Cache: PostgreSQL does not support cache compression, disabling cache compression"
          CONFIG.video_cache.compress = false
        end
      end

      def set(video : VideoCacheInfo, expire_time)
        request = <<-SQL
          INSERT INTO videos
          VALUES ($1, $2, $3)
          ON CONFLICT (id) DO NOTHING
        SQL

        PG_DB.exec(request, video.id, video.info, video.updated)
      end

      def del(video_id)
        request = <<-SQL
          DELETE FROM videos *
          WHERE id = $1
        SQL

        PG_DB.exec(request, video_id)
      end

      def get(video_id : String) : VideoCacheInfo?
        request = <<-SQL
          SELECT * FROM videos
          WHERE id = $1
        SQL

        PG_DB.query_one?(request, video_id, as: VideoCacheInfo)
      end
    end
  end

  def init
    if !CONFIG.video_cache.enabled
      LOGGER.info "Video Cache: Cache is disabled, no videos will be cached"
      return
    end

    case CONFIG.video_cache.backend
    when CacheType::Postgres
      @@cache = CacheMethods::PostgresSQL.new
    when CacheType::Redis
      @@cache = CacheMethods::InternalRedis.new
    when CacheType::LRU
      @@cache = CacheMethods::LRU.new
    else
      LOGGER.debug "Video Cache: Using default cache method to store video cache (PostgreSQL)"
      @@cache = CacheMethods::PostgresSQL.new
    end
  end

  def insert(video : Video)
    cache = @@cache
    return if cache.nil?

    video_cache_info = VideoCacheInfo.new(video.id, video.info.to_json, video.updated)

    # Videos expire after 6 hours, so we expire them before it expires in the
    # youtube side
    # 3600 * 5.95 = 21420
    cache.set(video_cache_info, 21420)
  end

  def delete(video_id) : Nil
    cache = @@cache
    return if cache.nil?

    cache.del(video_id)
  end

  def select(video_id : String) : Video?
    cache = @@cache
    return if cache.nil?

    cached_video = cache.get(video_id)
    return if cached_video.nil?

    video = Video.new({
      id:      video_id,
      info:    JSON.parse(cached_video.info).as_h,
      updated: cached_video.updated,
    })
  end

  def delete_expired
    request = <<-SQL
      DELETE FROM videos *
      WHERE updated < (now() - interval '6 hours')
    SQL

    PG_DB.exec(request)
  end

  def update(video : Video)
    request = <<-SQL
      UPDATE videos
      SET (id, info, updated) = ($1, $2, $3)
      WHERE id = $1
    SQL

    PG_DB.exec(request, video.id, video.info.to_json, video.updated)
  end
end
