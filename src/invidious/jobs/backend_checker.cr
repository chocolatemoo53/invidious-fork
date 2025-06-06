class Invidious::Jobs::CheckBackend < Invidious::Jobs::BaseJob
  def initialize
  end

  def begin
    loop do
      LOGGER.info("Backend Checker: Starting")
      BackendInfo.check_backends
      LOGGER.info("Backend Checker: Done, sleeping for #{CONFIG.check_backends_interval} seconds")
      sleep CONFIG.check_backends_interval.seconds
      Fiber.yield
    end
  end
end
