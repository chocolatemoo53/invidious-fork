{% skip_file if flag?(:api_only) %}

module Invidious::Routes::BackendSwitcher
  def self.switch(env)
    referer = get_referer(env, unroll: false)
    companion_id = env.params.query["companion_id"]?.try &.to_i
    preferences = env.get("preferences").as(Preferences)
    user = env.get? "user"

    if companion_id.nil?
      return error_template(400, "Companion ID is required")
    end

    if user
      user = user.as(User)
      user.preferences.current_companion = companion_id
      Invidious::Database::Users.update_preferences(user)
    else
      preferences.current_companion = companion_id
      env.response.cookies["PREFS"] = Invidious::User::Cookies.prefs(env.request.headers["Host"], preferences)
    end

    env.redirect referer
  end
end
