require "http"
require "colorize"

ESBUILD_VERSION = "0.25.0"

esbuild_os = ""
esbuild_arch = ""

# https://esbuild.github.io/getting-started/#other-ways-to-install
{% if flag?(:linux) %}
  esbuild_os = "linux"
{% elsif flag?(:windows) %}
  esbuild_os = "win32"
{% elsif flag?(:darwin) %}
  esbuild_os = "darwin"
{% elsif flag?(:freebsd) %}
  esbuild_os = "freebsd"
{% elsif flag?(:openbsd) %}
  esbuild_os = "openbsd"
{% elsif flag?(:netbsd) %}
  esbuild_os = "netbsd"
{% elsif flag?(:solaris) %}
  esbuild_os = "sunos"
{% else %}
  esbuild_os = "linux"
{% end %}

{% if flag?(:x86_64) %}
  esbuild_arch = "x64"
{% elsif flag?(:arm64) %}
  esbuild_arch = "arm64"
{% else %}
  esbuild_arch = "x64"
{% end %}

tmp_dir_path = "#{Dir.tempdir}/invidious-esbuild-binary"
esbuild_tar_location = "#{tmp_dir_path}/esbuild-#{esbuild_os}-#{esbuild_os}-#{ESBUILD_VERSION}.tgz"
esbuild_binary_location = "#{tmp_dir_path}/package/bin/esbuild"
Dir.mkdir(tmp_dir_path) if !Dir.exists? tmp_dir_path

esbuild_url = "https://registry.npmjs.org/@esbuild/#{esbuild_os}-#{esbuild_arch}/-/#{esbuild_os}-#{esbuild_arch}-#{ESBUILD_VERSION}.tgz"

# Download esbuild binary
HTTP::Client.get(esbuild_url) do |response|
  puts "Downloading esbuild from #{esbuild_url}"
  data = response.body_io.gets_to_end
  File.write(esbuild_tar_location, data)

  `tar -vzxf '#{esbuild_tar_location}' -C '#{tmp_dir_path}'`
  raise "Extraction for #{esbuild_tar_location} failed" if !$?.success?
  puts "esbuild downloaded successfully"
end

files_to_minify = [
  "_helpers.js",
  "comments.js",
  "embed.js",
  "handlers.js",
  "notifications.js",
  "pagination.js",
  "playlist_widget.js",
  "post.js",
  "sse.js",
  "subscribe_widget.js",
  "themes.js",
  "watch.js",
  "player.js",
  "watched_indicator.js",
  "watched_widget.js",
]

files_to_minify.each do |file|
  file_path = "assets/js/#{file}"
  outdir = "assets/js/minified"
  process_output = IO::Memory.new

  process = Process.run("#{esbuild_binary_location}", error: process_output, args: [
    file_path,
    "--color=false",
    "--sourcemap",
    "--minify",
    "--outdir=#{outdir}",
  ]
  )

  if process.success?
    puts "Minified #{file}".colorize(:green)
  elsif !process.success?
    puts "Failed to minify #{file}, esbuild exited with exit code #{process.exit_code}: #{process_output.to_s.split("\n").first}".colorize(:red)
    raise Exception.new("All files have to be minified sucessfully in order to compile!")
  end
end

puts "Minify done!"

# Cleanup
`rm -rf #{tmp_dir_path}`
