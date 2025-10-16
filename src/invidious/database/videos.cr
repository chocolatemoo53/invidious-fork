require "./base.cr"
require "redis"

VideoCache = Invidious::Database::Videos::Cache.new

module Invidious::Database::Videos
  struct VideoCacheInfo
    property info : String
    property id : String
    property updated : String

    def initialize(@info, @id, @updated)
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

    def decompress(video_info_compressed : String, id : String) : String?
      compressed = IO::Memory.new
      compressed << video_info_compressed
      compressed.rewind
      decompressed = Compress::Deflate::Reader.new(compressed, sync_close: true)
      begin
        return decompressed.gets_to_end
      rescue Compress::Deflate::Error
        # If there is an error when decompressing the video data,
        # delete the video from the cache to fetch it again.
        VideoCache.del(id)
        return nil
      end
    end
  end

  class Cache
    def initialize
      case CONFIG.video_cache.backend
      when 0
        @cache = CacheMethods::PostgresSQL.new
      when 1
        @cache = CacheMethods::Redis_.new
      when 2
        @cache = CacheMethods::LRU.new
      else
        LOGGER.debug "Video Cache: Using default cache method to store video cache (PostgreSQL)"
        @cache = CacheMethods::PostgresSQL.new
      end
    end

    def set(video : VideoCacheInfo, expire_time)
      @cache.set(video, expire_time)
    end

    def del(id : String)
      @cache.del(id)
    end

    def get(id : String)
      return @cache.get(id)
    end
  end

  module CacheMethods
    # TODO: Save the cache on a file with a Job
    class LRU
      @max_size : Int32
      @lru = {} of String => String
      @access = [] of String

      def initialize(@max_size = CONFIG.video_cache.lru_max_size)
        LOGGER.info "Video Cache: Using in memory LRU to store video cache"
        LOGGER.info "Video Cache, LRU: LRU cache max size set to #{@max_size}"
      end

      # TODO: Handle expire_time with a Job
      def set(video : VideoCacheInfo, expire_time)
        self[video.id] = video.info
        self[video.id + ":time"] = "#{video.updated}"
      end

      def del(id : String)
        self.delete(id)
        self.delete(id + ":time")
      end

      def get(id : String)
        info = self[id]
        time = self[id + ":time"]
        if info && time
          # With the { we identify if it's a JSON or not. In that way, compressed
          # video info keeps working after setting video_cache.compress to false
          # and new videos inserted will be uncompressed.
          if info[0] != '{'
            info = CacheCompression.decompress(info, id)
            if info.nil?
              return nil
            end
          end
          return Video.new({
            id:      id,
            info:    JSON.parse(info).as_h,
            updated: Time.parse(time, "%Y-%m-%d %H:%M:%S %z", Time::Location::UTC),
          })
        else
          return nil
        end
      end

      private def [](key)
        if @lru[key]?
          @access.delete(key)
          @access.push(key)
          @lru[key]
        else
          nil
        end
      end

      private def []=(key, value)
        if @lru.size >= @max_size
          lru_key = @access.shift
          @lru.delete(lru_key)
        end
        @lru[key] = value
        @access.push(key)
      end

      private def delete(key)
        if @lru[key]?
          @lru.delete(key)
          @access.delete(key)
        end
      end
    end

    class Redis_
      @redis : Redis::Client

      def initialize
        @redis = begin
          Redis::Client.new(CONFIG.redis_url)
        rescue ex
          LOGGER.fatal "Video Cache: Failed to connect to redis database: '#{ex.message}'"
          exit(1)
        end
        LOGGER.info "Video Cache: Using Redis compatible DB to store video cache"
        LOGGER.info "Connecting to Redis compatible DB"
        if @redis.ping
          LOGGER.info "Connected to Redis compatible DB at '#{CONFIG.redis_url}'" if CONFIG.redis_url
        end
      end

      def set(video : VideoCacheInfo, expire_time)
        @redis.set(video.id, video.info, ex: expire_time)
        @redis.set(video.id + ":time", video.updated.to_s, ex: expire_time)
      end

      def del(id : String)
        @redis.del(id)
        @redis.del(id + ":time")
      end

      def get(id : String)
        info = @redis.get(id)
        time = @redis.get(id + ":time")
        if info && time
          # With the { we identify if it's a JSON or not
          if info[0] != '{'
            info = CacheCompression.decompress(info, id)
            if info.nil?
              return nil
            end
          end
          return Video.new({
            id:      id,
            info:    JSON.parse(info).as_h,
            updated: Time.parse(time, "%Y-%m-%d %H:%M:%S %z", Time::Location::UTC),
          })
        else
          return nil
        end
      end
    end

    class PostgresSQL
      def initialize
        LOGGER.info "Video Cache: Using PostgreSQL to store video cache"
      end

      def set(video : VideoCacheInfo, expire_time)
        request = <<-SQL
          INSERT INTO videos
          VALUES ($1, $2, $3)
          ON CONFLICT (id) DO NOTHING
        SQL

        PG_DB.exec(request, video.id, video.info, video.updated)
      end

      def del(id)
        request = <<-SQL
          DELETE FROM videos *
          WHERE id = $1
        SQL

        PG_DB.exec(request, id)
      end

      def get(id : String) : Video?
        request = <<-SQL
          SELECT * FROM videos
          WHERE id = $1
        SQL

        data = PG_DB.query_one?(request, id, as: VideoCacheInfo)

        if data
          if data.info && data.updated
            return Video.new({
              id:      id,
              info:    JSON.parse(data.info).as_h,
              updated: Time.parse(data.updated, "%Y-%m-%d %H:%M:%S %z", Time::Location::UTC),
            })
          else
            return nil
          end
        end
      end
    end
  end

  extend self

  def insert(video : Video)
    video_info = video.info.to_json
    if CONFIG.video_cache.compress
      video_info = CacheCompression.compress(video_info)
    end
    video_cache_info = VideoCacheInfo.new(video_info, video.id, video.updated.to_s)
    VideoCache.set(video: video_cache_info, expire_time: 14400) if CONFIG.video_cache.enabled
  end

  def delete(id)
    VideoCache.del(id)
  end

  def select(id : String) : Video?
    VideoCache.get(id)
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
