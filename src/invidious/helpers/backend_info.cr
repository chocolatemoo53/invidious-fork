module BackendInfo
  extend self

  enum Status
    Dead    = 0
    Blocked = 1
    Working = 2
  end

  struct CompanionData
    include JSON::Serializable
    property blocked : Bool = false
    @[JSON::Field(key: "blockedCount")]
    property blocked_count : Int64 = 0
  end

  @@status : Array(Int32) = Array.new(CONFIG.invidious_companion.size, Status::Dead.to_i)
  @@csp : Array(String) = Array.new(CONFIG.invidious_companion.size, "")
  @@working_ends : Array(Int32) = Array(Int32).new(0)
  @@csp_mutex : Mutex = Mutex.new
  @@check_mutex : Mutex = Mutex.new

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
          response = client.get(CONFIG.check_backends_path)
          if response.status_code == 200
            if response.content_type == "application/json"
              body = response.body
              status_json = CompanionData.from_json(body)
              if status_json.blocked
                updated_ends, updated_status = self.set_status(index, updated_ends, updated_status, Status::Blocked, true)
              else
                updated_ends, updated_status = self.set_status(index, updated_ends, updated_status, Status::Working, true)
              end
            else
              updated_ends, updated_status = self.set_status(index, updated_ends, updated_status, Status::Working, true)
            end
            self.generate_csp([companion.public_url, companion.i2p_public_url], index)
          else
            _, updated_status = self.set_status(index, updated_ends, updated_status, Status::Dead, false)
          end
        rescue
          _, updated_status = self.set_status(index, updated_ends, updated_status, Status::Dead, false)
        ensure
          LOGGER.trace("Invidious companion: Done Index: \"#{index}\"")
          channels.send(nil)
        end
      end
    end
    # Wait until we receive a signal from them all
    LOGGER.debug("Invidious companion: Updating working_ends")
    comp_size.times { channels.receive }
    @@working_ends = updated_ends.sort!
    @@status = updated_status
  end

  private def generate_csp(companion_url : Array(URI), index : Int32? = nil)
    @@csp_mutex.synchronize do
      @@csp[index] = ""
      companion_url.each do |url|
        fixed_url = "#{url.scheme}://#{url.host}#{url.port ? ":#{url.port}" : ""}"
        @@csp[index] += " #{fixed_url}"
      end
    end
  end

  private def set_status(index, updated_ends, updated_status, status, push = false)
    @@check_mutex.synchronize do
      updated_status[index] = status.to_i
      updated_ends.push(index) if push
    end
    return {updated_ends, updated_status}
  end

  def get_status
    # Shouldn't need to lock since we never edit this array, only change the pointer.
    return @@status
  end

  def get_working_ends
    # Shouldn't need to lock since we never edit this array, only change the pointer.
    return @@working_ends
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
