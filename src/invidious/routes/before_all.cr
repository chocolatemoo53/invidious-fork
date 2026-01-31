module Invidious::Routes::BeforeAll
  extend self

  def handle(env)
    preferences = Preferences.from_json("{}")
    host = env.request.headers["Host"]

    begin
      if prefs_cookie = env.request.cookies["PREFS"]?
        preferences = Preferences.from_json(URI.decode_www_form(prefs_cookie.value))
      else
        if language_header = env.request.headers["Accept-Language"]?
          if language = ANG.language_negotiator.best(language_header, LOCALES.keys)
            preferences.locale = language.header
          end
        end
      end
    rescue
      preferences = Preferences.from_json("{}")
    end

    env.set "preferences", preferences
    env.response.headers["X-XSS-Protection"] = "1; mode=block"
    env.response.headers["X-Content-Type-Options"] = "nosniff"

    # Only allow the pages at /embed/* to be embedded
    if env.request.resource.starts_with?("/embed")
      frame_ancestors = "'self' file: http: https:"
    else
      frame_ancestors = "'none'"
    end

    scheme = env.request.headers["X-Forwarded-Proto"]? || ("https" if CONFIG.https_only) || "http"
    env.set "scheme", scheme

    env.response.headers["Referrer-Policy"] = "same-origin"

    # Ask the chrom*-based browsers to disable FLoC
    # See: https://blog.runcloud.io/google-floc/
    env.response.headers["Permissions-Policy"] = "interest-cohort=()"

    if (Kemal.config.ssl || CONFIG.https_only) && CONFIG.hsts
      env.response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains; preload"
    end

    return if {
                "/sb/",
                "/vi/",
                "/s_p/",
                "/yts/",
                "/ggpht/",
                "/api/manifest/",
                "/videoplayback",
                "/latest_version",
                "/download",
                "/companion/",
              }.any? { |r| env.request.resource.starts_with? r }

    if env.request.cookies.has_key? "SID"
      sid = env.request.cookies["SID"].value

      if sid.starts_with? "v1:"
        raise "Cannot use token as SID"
      end

      if email = Database::SessionIDs.select_email(sid)
        user = Database::Users.select!(email: email)
        csrf_token = generate_response(sid, {
          ":authorize_token",
          ":playlist_ajax",
          ":signout",
          ":subscription_ajax",
          ":token_ajax",
          ":watch_ajax",
        }, HMAC_KEY, 1.week)

        preferences = user.preferences
        env.set "preferences", preferences

        env.set "sid", sid
        env.set "csrf_token", csrf_token
        env.set "user", user
      end
    end

    dark_mode = convert_theme(env.params.query["dark_mode"]?) || preferences.dark_mode.to_s
    thin_mode = env.params.query["thin_mode"]?
    thin_mode = (thin_mode == "true") || preferences.thin_mode
    locale = env.params.query["hl"]? || preferences.locale

    preferences.dark_mode = dark_mode
    preferences.thin_mode = thin_mode
    preferences.locale = locale
    env.set "preferences", preferences

    companion_csp = ""
    if companion_status = COMPANION_STATUS
      companion_csp = Invidious::Routes::BeforeAll::Companion.process_companion(
        env,
        host,
        companion_status,
        preferences
      )
    end

    # TODO: Remove style-src's 'unsafe-inline', requires to remove all
    # inline styles (<style> [..] </style>, style=" [..] ")
    env.response.headers["Content-Security-Policy"] = {
      "default-src 'none'",
      "script-src 'self'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: " + "#{scheme}://#{env.request.headers["Host"]?}",
      "font-src 'self' data:",
      "connect-src 'self' " + companion_csp,
      "manifest-src 'self'",
      "media-src 'self' blob: " + companion_csp,
      "child-src 'self' blob:",
      "frame-src 'self'",
      "frame-ancestors " + frame_ancestors,
    }.join("; ") if CONFIG.csp

    # Allow media resources to be loaded from google servers
    # TODO: check if *.youtube.com can be removed
    #
    # `!preferences.local` has to be checked after setting and
    # reading `preferences` from the "PREFS" cookie and
    # saved user preferences from the database, otherwise
    # `https://*.googlevideo.com:443 https://*.youtube.com:443`
    # will not be set in the CSP header if
    # `default_user_preferences.local` is set to true on the
    # configuration file, causing preference “Proxy Videos”
    # not to work while having it disabled and using medium quality.
    if CONFIG.disabled?("local") || !preferences.local
      env.response.headers["Content-Security-Policy"] = env.response.headers["Content-Security-Policy"].gsub("media-src", "media-src https://*.googlevideo.com:443 https://*.youtube.com:443")
    end

    current_page = env.request.path
    if env.request.query
      query = HTTP::Params.parse(env.request.query.not_nil!)

      if query["referer"]?
        query["referer"] = get_referer(env, "/")
      end

      current_page += "?#{query}"
    end

    env.set "current_page", URI.encode_www_form(current_page)
  end
end

#
# Invidious companion processing
#
module Invidious::Routes::BeforeAll::Companion
  extend self
  private COMPANION_PREFIXES = [] of String

  if c_prefix = CONFIG.invidious_companion_prefix
    CONFIG.invidious_companion.each_with_index do |_, i|
      prefix = c_prefix + "#{i + 1}"
      COMPANION_PREFIXES << prefix
    end
  end

  def process_companion(
    env : HTTP::Server::Context,
    host : String,
    companion_status : CompanionStatus,
    preferences : Preferences,
  )
    c_size = CONFIG.invidious_companion.size
    current_companion = 0

    # When accessing via domain we assume the user explicitely wants to access
    # that domain.
    if CONFIG.invidious_companion_prefix.presence && (index = self.using_invidious_domain?(host))
      env.set "companion_using_domain", true
      env.set "companion_companion_public_url", CONFIG.invidious_companion[index].public_url.to_s
      current_companion = index
    else
      # Set cookie if there is no cookie
      if !env.request.cookies.has_key?("PREFS")
        current_companion = get_companion(preferences)
        current_companion = self.find_available_companion(env, host, nil, companion_status, preferences)
        if current_companion
          self.set_companion(env, preferences, host, current_companion)
        else
          current_companion = rand(c_size)
          self.set_companion(env, preferences, host, current_companion)
        end
      else
        begin
          current_companion = get_companion(preferences)
          current_companion = self.find_available_companion(env, host, current_companion, companion_status, preferences)
        rescue
          current_companion = rand(c_size)
          self.set_companion(env, preferences, host, current_companion)
        end
      end

      if current_companion.nil?
        return ""
      end

      # Set I2P public URL when it's being accessed via I2P.
      # I2P is not like Tor, therefore I2P users can't connect to "clearnet" sites
      # like it would work in Tor.
      if host.split(".").last == "i2p"
        env.set "companion_using_i2p", true
        env.set "companion_companion_public_url", CONFIG.invidious_companion[current_companion].i2p_public_url.to_s
      else
        env.set "companion_using_i2p", false
        env.set "companion_companion_public_url", CONFIG.invidious_companion[current_companion].public_url.to_s
      end
    end

    env.set "current_companion", current_companion
    companion_csp = companion_status.companions[current_companion].csp
    return companion_csp
  end

  private def set_companion(
    env : HTTP::Server::Context,
    preferences : Preferences,
    host : String,
    current_companion : Int32,
  )
    user = env.get? "user"

    if user
      user = user.as(User)
      user.preferences.current_companion = current_companion
      Invidious::Database::Users.update_preferences(user)
    else
      preferences.current_companion = current_companion
      env.set "preferences", preferences
      env.response.cookies["PREFS"] = Invidious::User::Cookies.prefs(env.request.headers["Host"], preferences)
    end
  end

  private def get_companion(
    preferences : Preferences,
  )
    return preferences.current_companion
  end

  private def find_available_companion(
    env : HTTP::Server::Context,
    host : String,
    current_companion : Int32?,
    companion_status : CompanionStatus,
    preferences : Preferences,
  )
    companions = companion_status.companions
    working_companions = companion_status.working_companions
    c_size = companions.size

    if !preferences.show_community_backends
      working_companions = working_companions.all
    else
      working_companions = working_companions.community
    end

    if !current_companion.nil?
      if working_companions.empty?
        current_companion = self.wrap_current_companion(env, host, current_companion, c_size, working_companions, preferences)
        return current_companion
      end
    end

    if current_companion.nil?
      available_companion = self.get_available_companion(c_size, working_companions)
      if available_companion
        current_companion = available_companion
        current_companion = self.wrap_current_companion(env, host, current_companion, c_size, working_companions, preferences)
        return current_companion
      else
        return nil
      end
    end

    current_companion = self.wrap_current_companion(env, host, current_companion, c_size, working_companions, preferences)
    if current_companion.nil?
      return nil
    end

    status = companions[current_companion].status
    if status != CompanionStatus::Status::Working
      alive_companion = self.get_available_companion(c_size, working_companions)
      if alive_companion
        current_companion = alive_companion
        env.set "companion_switched", true
        self.set_companion(env, preferences, host, current_companion)
      end
    end

    return current_companion
  end

  private def using_invidious_domain?(host : String)
    current_companion_domain = host.split(":")[0].split(".")[0]
    if index = COMPANION_PREFIXES.index(current_companion_domain)
      return index
    else
      return nil
    end
  end

  # Checks if the current_companion does not match any companion
  private def wrap_current_companion(
    env : HTTP::Server::Context,
    host : String,
    current_companion : Int32,
    invidious_companion_size : Int32,
    working_companions : Array(Int32),
    preferences : Preferences,
  )
    if (current_companion < 0) || current_companion >= invidious_companion_size
      current_companion = self.get_available_companion(invidious_companion_size, working_companions)
      if current_companion
        self.set_companion(env, preferences, host, current_companion)
      else
        current_companion = rand(invidious_companion_size)
      end
    end

    return current_companion
  end

  private def check_community(env, current_companion, companions)
    companion = companions[current_companion].companion

    if companion.community
    end
  end

  private def get_available_companion(
    invidious_companion_size : Int32,
    working_companions : Array(Int32),
  )
    if !working_companions.empty?
      # Choose a random working companion
      current_companion = working_companions.sample
      return current_companion
    else
      return nil
    end
  end
end
