module Invidious::Routes::Metrics
  def self.metrics(env)
    env.response.content_type = "text/plain; version=0.0.4; charset=utf-8"
    Invidious::Metrics.render
  end
end
