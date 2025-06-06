module Invidious::Routes::BeforeAll
  private COMPANION_PREFIXES = [] of String

  CONFIG.invidious_companion.each_with_index do |_, i|
    prefix = CONFIG.invidious_companion_prefix + "#{i + 1}"
    COMPANION_PREFIXES << prefix
  end

  def self.handle(env)
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

    extra_media_csp = ""
    extra_connect_csp = ""

    if CONFIG.invidious_companion.present?
      current_companion_d = host.split(":")[0].split(".")[0]

      if index = COMPANION_PREFIXES.index(current_companion_d)
        env.set "using_domain", true
        env.set "current_companion", index
        env.set "companion_public_url", CONFIG.invidious_companion[index].public_url.to_s
      else
        if !env.request.cookies[CONFIG.server_id_cookie_name]?
          env.response.cookies[CONFIG.server_id_cookie_name] = Invidious::User::Cookies.server_id(host)
        end

        begin
          current_companion = env.request.cookies[CONFIG.server_id_cookie_name].value.try &.to_i
        rescue
          working_ends = BackendInfo.get_working_ends
          current_companion = working_ends.sample
        end

        if current_companion > CONFIG.invidious_companion.size
          current_companion = current_companion % CONFIG.invidious_companion.size
          env.response.cookies[CONFIG.server_id_cookie_name] = Invidious::User::Cookies.server_id(host, current_companion)
        end

        companion_status = BackendInfo.get_status

        if companion_status[current_companion] != 2
          alive_companion = companion_status.index(2, offset: current_companion)
          if alive_companion
            env.set "companion_switched", true
            current_companion = alive_companion
            env.response.cookies[CONFIG.server_id_cookie_name] = Invidious::User::Cookies.server_id(host, current_companion)
          end
        end

        env.set "current_companion", current_companion

        if host.split(".").last == "i2p"
          env.set "companion_public_url", CONFIG.invidious_companion[current_companion].i2p_public_url.to_s
        else
          env.set "companion_public_url", CONFIG.invidious_companion[current_companion].public_url.to_s
        end
      end

      extra_media_csp, extra_connect_csp = BackendInfo.get_csp(env.get("current_companion").as(Int32))
    end

    # Only allow the pages at /embed/* to be embedded
    if env.request.resource.starts_with?("/embed")
      frame_ancestors = "'self' file: http: https:"
    else
      frame_ancestors = "'none'"
    end

    scheme = env.request.headers["X-Forwarded-Proto"]? || ("https" if CONFIG.https_only) || "http"
    env.set "scheme", scheme

    # TODO: Remove style-src's 'unsafe-inline', requires to remove all
    # inline styles (<style> [..] </style>, style=" [..] ")
    env.response.headers["Content-Security-Policy"] = {
      "default-src 'none'",
      "script-src 'self'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: " + "#{scheme}://#{env.request.headers["Host"]?}",
      "font-src 'self' data:",
      "connect-src 'self'" + extra_connect_csp,
      "manifest-src 'self'",
      "media-src 'self' blob:" + extra_media_csp,
      "child-src 'self' blob:",
      "frame-src 'self'",
      "frame-ancestors " + frame_ancestors,
    }.join("; ") if CONFIG.csp

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
    thin_mode = env.params.query["thin_mode"]? || preferences.thin_mode.to_s
    thin_mode = thin_mode == "true"
    locale = env.params.query["hl"]? || preferences.locale

    preferences.dark_mode = dark_mode
    preferences.thin_mode = thin_mode
    preferences.locale = locale
    env.set "preferences", preferences

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
