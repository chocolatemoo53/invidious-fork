module BackendInfo
  extend self
  @@exvpp_url : Array(String) = Array.new(CONFIG.invidious_companion.size, "")
  @@status : Array(Int32) = Array.new(CONFIG.invidious_companion.size, 0)
  @@csp : Array(String) = Array.new(CONFIG.invidious_companion.size, "")
  @@working_ends : Array(Int32) = Array(Int32).new(0)
  @@csp_mutex : Mutex = Mutex.new
  @@check_mutex : Mutex = Mutex.new

  enum BackendStatus
      Dead
      Problems
      Working
  end

  def check_backends
    check_companion()
    LOGGER.debug("Invidious companion: New working_ends \"#{@@working_ends}\"")
    LOGGER.debug("Invidious companion: New status \"#{@@status}\"")
  end

  private def check_companion
    # Create Channels the size of CONFIG.invidious_companion
    comp_size = CONFIG.invidious_companion.size
    channels = Channel(Nil).new(comp_size)
    updated_ends = Array(Int32).new(0)
    updated_status = Array(Int32).new(CONFIG.invidious_companion.size, 0)
    LOGGER.debug("Invidious companion: comp_size \"#{comp_size}\"")
    CONFIG.invidious_companion.each_with_index do |companion, index|
      spawn do
        begin
          client = HTTP::Client.new(companion.private_url)
          client.connect_timeout = 10.seconds
          response = client.get("/healthz")
          if response.status_code == 200
            check_videoplayback_proxy(companion, index, updated_status, updated_ends)
            generate_csp([companion.public_url.to_s, companion.i2p_public_url.to_s], @@exvpp_url[index], index)
          else
            @@check_mutex.synchronize do
              updated_status[index] = BackendStatus::Dead.to_i
            end
          end
        rescue
          @@check_mutex.synchronize do
            updated_status[index] = BackendStatus::Dead.to_i
          end
        ensure
          LOGGER.debug("Invidious companion: Done Index: \"#{index}\"")
          channels.send(nil)
        end
      end
    end
    # Wait until we receive a signal from them all
    LOGGER.debug("Invidious companion: Updating working_ends")
    comp_size.times { channels.receive }
    @@working_ends = updated_ends
    @@status = updated_status
  end

  private def check_videoplayback_proxy(companion : Config::CompanionConfig, index : Int32, updated_status : Array(Int32), updated_ends : Array(Int32))
    begin
      info = HTTP::Client.get "#{companion.private_url}/info"
      exvpp_url = JSON.parse(info.body)["external_videoplayback_proxy"]?.try &.to_s
    rescue JSON::ParseException
      @@check_mutex.synchronize do
        updated_status[index] = BackendStatus::Working.to_i
        updated_ends.push(index)
      end
      return
    end

    exvpp_url = "" if exvpp_url.nil?
    @@exvpp_url[index] = exvpp_url
    if exvpp_url.empty?
      @@check_mutex.synchronize do
        updated_status[index] = BackendStatus::Working.to_i
        updated_ends.push(index)
      end
      return
    else
      begin
        exvpp_health = HTTP::Client.get "#{exvpp_url}/health"
        if exvpp_health.status_code == 200
            @@check_mutex.synchronize do
              updated_status[index] = BackendStatus::Working.to_i
              updated_ends.push(index)
            end
          return exvpp_url
        else
          @@check_mutex.synchronize do
            updated_status[index] = BackendStatus::Problems.to_i
          end
        end
      rescue
        @@check_mutex.synchronize do
          updated_status[index] = BackendStatus::Problems.to_i
        end
      end
    end
  end

  private def generate_csp(companion_url : Array(String), exvpp_url : String? = nil, index : Int32? = nil)
    @@csp_mutex.synchronize do
      @@csp[index] = ""
      companion_url.each do |url|
        @@csp[index] += " #{url}"
      end
      @@csp[index] += " #{exvpp_url}"
    end
  end

  def get_status
    # Shouldn't need to lock since we never edit this array, only change the pointer.
    return @@status
  end

  def get_working_ends
    # Shouldn't need to lock since we never edit this array, only change the pointer.
    return @@working_ends
  end

  def get_exvpp
    return @@exvpp_url
  end

  def get_csp(index : Int32)
    # A little mutex to prevent sending a partial CSP header
    # Not sure if this is necessary. But if the @@csp[index] is being assigned
    # at the same time when it's being accessed, a data race will appear
    @@csp_mutex.synchronize do
      return @@csp[index], @@csp[index]
    end
  end
end
