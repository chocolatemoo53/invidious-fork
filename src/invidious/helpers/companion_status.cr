require "wait_group"

class CompanionStatus
  enum Status
    # Color in the backend switcher: Red
    Down = 0
    # Color in the backend switcher: Yellow
    Blocked = 1
    # Color in the backend switcher: Green
    Working = 2
  end

  struct CompanionHealthData
    include JSON::Serializable

    property blocked : Bool = false
    @[JSON::Field(key: "blockedCount")]
    property blocked_count : Int64 = 0
  end

  class CompanionInfo
    property companion : Config::CompanionConfig
    property status : Status
    property csp : String

    def initialize(companion)
      @companion = companion
      @status = Status::Down
      @csp = ""
    end
  end

  class WorkingCompanions
    property all : Array(Int32)
    property community : Array(Int32)

    def initialize
      @all = Array(Int32).new
      @community = Array(Int32).new
    end
  end

  getter companions : Array(CompanionInfo)
  getter working_companions : WorkingCompanions
  # Reusable TLS Context for HTTP Client
  # https://github.com/crystal-lang/crystal/issues/15419
  @tlscontext : OpenSSL::SSL::Context::Client

  def initialize
    @companions = Array(CompanionInfo).new(CONFIG.invidious_companion.size) do |index|
      CompanionInfo.new(CONFIG.invidious_companion[index])
    end
    @working_companions = WorkingCompanions.new
    @tlscontext = OpenSSL::SSL::Context::Client.new
  end

  def check_companions
    wg = WaitGroup.new(@companions.size)

    @companions.each_with_index do |companion, index|
      c = companion.companion
      spawn do
        begin
          self.healthcheck(c, index)
          if @companions[index].status == Status::Working
            LOGGER.trace("Companion checker: generating CSP for #{c.private_url}")
            self.generate_csp(
              [c.public_url,
               c.i2p_public_url], index)
          end
        rescue
          @companions[index].status == Status::Down
        ensure
          wg.done
        end
      end
    end

    wg.wait
    self.generate_working_companions
  end

  private def generate_csp(companion_urls : Array(URI), index : Int32)
    local_csp = ""

    companion_urls.each do |url|
      host = url.host
      next if !host.presence
      scheme = url.scheme
      port = url.port ? ":#{url.port}" : ""

      local_csp += "#{scheme}://#{host}#{port} "
    end

    @companions[index].csp = local_csp
  end

  private def generate_working_companions
    # Aux variable to temporarily store the alive companions
    # If we were to empty the `@working_companions`, some requests in the
    # timespan of the `@info` iteration to find the working companions could be
    # displayed as there was not working companions
    local_working_companions = WorkingCompanions.new

    @companions.each_with_index do |companion, index|
      if companion.status == Status::Working
        local_working_companions.community << index
        if !companion.companion.community
          local_working_companions.all << index
        end
      end
    end

    @working_companions = local_working_companions
  end

  private def healthcheck(companion : Config::CompanionConfig, index : Int32)
    tls = @tlscontext if companion.private_url.scheme == "https"
    client = HTTP::Client.new(companion.private_url, tls: tls)
    client.connect_timeout = 10.seconds

    response = client.get(CONFIG.check_backends_path)
    if response.status_code == 200
      if response.content_type == "application/json"
        body = response.body
        status_json = CompanionHealthData.from_json(body)
        if status_json.blocked
          @companions[index].status = Status::Blocked
        else
          @companions[index].status = Status::Working
        end
      else
        @companions[index].status = Status::Working
      end
    else
      @companions[index].status = Status::Down
    end
  end
end
