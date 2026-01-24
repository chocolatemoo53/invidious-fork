class Invidious::Jobs::CompanionChecker < Invidious::Jobs::BaseJob
  @companion_status : CompanionStatus

  def initialize(companion_status)
    @companion_status = companion_status
  end

  def begin
    loop do
      LOGGER.info("Companion checker: Starting")
      @companion_status.check_companions
      LOGGER.info("Companion checker: Done, sleeping for #{CONFIG.check_backends_interval} seconds")
      sleep CONFIG.check_backends_interval.seconds
      Fiber.yield
    end
  end
end
