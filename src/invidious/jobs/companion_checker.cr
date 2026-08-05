class Invidious::Jobs::CompanionChecker < Invidious::Jobs::BaseJob
  @companion_status : CompanionStatus

  def initialize(companion_status)
    @companion_status = companion_status
  end

  def begin
    loop do
      LOGGER.debug("Companion checker: Starting")
      @companion_status.check_companions
      LOGGER.debug("Companion checker: Done, sleeping for #{CONFIG.check_backends_interval} seconds")
      sleep CONFIG.check_backends_interval.seconds
      Fiber.yield
    end
  end
end
