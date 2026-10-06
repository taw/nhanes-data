# Shared logic for scraping a CDC survey page and downloading every data file,
# SAS layout and codebook it links to.

require "net/http"
require "uri"
require "fileutils"

module Fetcher
  ROOT = File.expand_path("..", __dir__)
  USER_AGENT = "Mozilla/5.0 (nhanes data fetcher)"

  module_function

  def get(url, limit: 5)
    raise "Too many redirects: #{url}" if limit == 0
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 300) do |http|
      response = http.request(Net::HTTP::Get.new(uri, "User-Agent" => USER_AGENT))
      case response
      when Net::HTTPSuccess
        response
      when Net::HTTPRedirection
        get(URI.join(url, response["location"]).to_s, limit: limit - 1)
      else
        raise "HTTP #{response.code} for #{url}"
      end
    end
  end

  # Data files, SAS input scripts, and PDF/HTML codebooks all live under /nchs/data/.
  # `fixes` maps known-broken links on the page to their current location.
  def file_urls(page_url, fixes: {})
    html = get(page_url).body
    html.scan(/href="([^"#]+)"/i).flatten
        .map { |href| URI.join(page_url, href.strip).to_s }
        .map { |url| fixes.fetch(url, url) }
        .select { |url| URI(url).host == "wwwn.cdc.gov" && URI(url).path.downcase.start_with?("/nchs/data/") }
        .uniq
  end

  # Files under the survey's own data directory keep their subdirectory
  # (NHANES III has many releases with clashing names like readme.txt),
  # anything else is saved by basename.
  def local_name(url, data_dir)
    path = URI(url).path
    prefix = "/nchs/data/#{data_dir}/"
    path.downcase.start_with?(prefix.downcase) ? path[prefix.size..] : File.basename(path)
  end

  # surveys: { "name" => { page: url, data_dir: "nhanes3", fixes: {...} } }
  # Instead of page, pages: [url, ...] scrapes several pages, and
  # filter: ->(url) { ... } keeps only matching files.
  def run(surveys, argv)
    argv = argv.dup
    force = argv.delete("--force")
    selected = argv.empty? ? surveys.keys : argv
    unknown = selected - surveys.keys
    abort "Unknown survey(s): #{unknown.join(", ")}. Known: #{surveys.keys.join(", ")}" unless unknown.empty?

    failures = []
    selected.each do |survey|
      config = surveys[survey]
      dir = File.join(ROOT, "raw_data", survey)
      pages = config[:pages] || [config[:page]]
      urls = pages.flat_map { |page| file_urls(page, fixes: config.fetch(:fixes, {})) }.uniq
      urls = urls.select(&config[:filter]) if config[:filter]
      abort "No files found on #{pages.join(", ")}, page layout may have changed" if urls.empty?
      puts "#{survey}: #{urls.size} files"

      urls.each do |url|
        name = local_name(url, config[:data_dir])
        path = File.join(dir, name)
        if File.exist?(path) && !force
          puts "  skip #{name}"
          next
        end
        begin
          response = get(url)
        rescue => e
          warn "  ERROR: #{e.message}"
          failures << url
          next
        end
        if response["content-type"].to_s.include?("text/html") && !path.match?(/\.html?\z/i)
          warn "  ERROR: #{url} returned HTML, not saving"
          failures << url
          next
        end
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite("#{path}.tmp", response.body)
        File.rename("#{path}.tmp", path)
        puts "  got  #{name} (#{response.body.bytesize} bytes)"
      end
    end

    abort "#{failures.size} download(s) failed:\n  #{failures.join("\n  ")}" unless failures.empty?
  end
end
