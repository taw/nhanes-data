# Converts all data files of one survey in raw_data/<survey> into the common
# output format in data/<survey>:
#
#   <dataset>.jsonl.zst one JSON object per record, keys are the original
#                       variable names, numeric fields as numbers, blank or
#                       missing fields as null. zstd-compressed with a long
#                       window: JSONL repeats every key on every line, and
#                       rows of wide files (NHANES III exam: 2368 columns) are
#                       too far apart for gzip's 32 KB window to dedupe.
#   variables.jsonl     one line per variable: dataset, name, label, type, and
#                       where the source has them, column positions (fixed
#                       width) and value labels (NHANES I/II format files)
#   datasets.jsonl      one line per dataset: title, record count, source files
#
# Two kinds of sources are handled:
#   - fixed-width text (.txt/.dat) described by a SAS input program (.sas)
#   - SAS transport files (.xpt)
#
# Values are exactly as stored in the source files. For fixed-width files,
# implied decimals and units are documented only in the PDF codebooks and are
# NOT applied here (e.g. NHES I height 685 means 68.5 inches).

require "json"
require "fileutils"
require_relative "sas_layout"
require_relative "xpt_reader"

class SurveyConverter
  ROOT = File.expand_path("..", __dir__)
  INTEGER = /\A[-+]?\d+\z/
  FLOAT = /\A[-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?\z/

  def initialize(survey)
    @survey = survey
    @raw_dir = File.join(ROOT, "raw_data", survey)
    @out_dir = File.join(ROOT, "data", survey)
  end

  def run
    FileUtils.mkdir_p(@out_dir)
    datasets = []
    variables = []

    sources = fixed_width_sources + xpt_sources
    names = sources.map { |s| s[:name] }
    duplicates = names.select { |n| names.count(n) > 1 }.uniq
    abort "#{@survey}: duplicate dataset names #{duplicates.join(", ")}" unless duplicates.empty?

    sources.sort_by { |s| s[:name].downcase }.each do |source|
      name = source[:name]
      records = write_records(File.join(@out_dir, "#{name}.jsonl.zst"), source[:records])
      puts "#{@survey}/#{name}: #{records} records, #{source[:variables].size} variables"
      source[:warnings]&.call&.each { |w| puts "  WARNING #{w}" }

      datasets << {
        dataset: name,
        title: source[:title],
        records: records,
        variables: source[:variables].size,
        source_data: relative(source[:data]),
        source_layout: source[:layout] && relative(source[:layout]),
      }.compact
      source[:variables].each { |v| variables << { dataset: name, **v }.compact }
    end

    write_jsonl(File.join(@out_dir, "datasets.jsonl"), datasets)
    write_jsonl(File.join(@out_dir, "variables.jsonl"), variables)
  end

  private

  ## Fixed-width files

  # Every SAS input program (not format file) whose INFILE exists in raw_data
  def fixed_width_sources
    Dir.glob("**/*.sas", base: @raw_dir).sort
       .reject { |f| f =~ /_F\.sas\z/i }
       .filter_map do |f|
         sas = File.join(@raw_dir, f)
         format_file = Dir.glob(sas.sub(/\.sas\z/i, "_F.sas"), File::FNM_CASEFOLD).first
         layout = SasLayout.new(sas, format_path: format_file)
         next unless layout.infile && !layout.variables.empty?
         # Fall back to the data file named like the layout (14a/HPV.sas says HV.DAT, CDC serves HPV.dat)
         data = find_case_insensitive(File.dirname(sas), layout.infile) ||
                Dir.glob(sas.sub(/\.sas\z/i, ".{dat,txt}"), File::FNM_CASEFOLD | File::FNM_EXTGLOB).first
         unless data
           warn "#{@survey}: #{f} refers to #{layout.infile}, which is missing"
           next
         end
         fixed_width_source(layout, data)
       end
  end

  def fixed_width_source(layout, data_path)
    stats = { invalid: Hash.new { |h, k| h[k] = [0, nil] }, unmapped: Hash.new(0) }
    max_end = layout.variables.map(&:end).max
    {
      name: File.basename(data_path).sub(/\.[^.]+\z/, ""),
      title: layout.title,
      data: data_path,
      layout: layout.path,
      variables: layout.variables.map do |v|
        { name: v.name, label: v.label, type: v.type, start: v.start, end: v.end,
          values: v.format && layout.formats[v.format] }
      end,
      records: Enumerator.new { |y| read_fixed_width(layout, data_path, stats) { |r| y << r } },
      warnings: lambda do
        stats[:invalid].map { |var, (count, example)| "#{var}: #{count} non-numeric values set to null, e.g. #{example.inspect}" } +
          if stats[:unmapped].empty?
            []
          else
            examples = stats[:unmapped].sort_by { |_, n| -n }.first(3).map(&:first)
            ["#{stats[:unmapped].values.sum} records have undocumented data past column #{max_end}, e.g. #{examples.inspect}"]
          end
      end,
    }
  end

  def read_fixed_width(layout, data_path, stats)
    vars = layout.variables
    max_end = vars.map(&:end).max
    # A*: fixed-width field, trailing spaces stripped; @: absolute position
    template = vars.map { |v| "@#{v.start - 1}A#{v.end - v.start + 1}" }.join
    names = vars.map(&:name)
    character = vars.map { |v| v.type == "character" }

    File.foreach(data_path, mode: "rb") do |line|
      # Slice raw bytes (positions are byte offsets), source text is Latin-1
      line = line.chomp.delete("\r\x1a")
      next if line.strip.empty?
      # Some tapes pad records with zeros past the last field, anything else is suspicious
      extra = line[max_end..].to_s.strip
      stats[:unmapped][latin1(extra[0, 40])] += 1 unless extra.empty? || extra.match?(/\A0+\z/)
      # Short records (trimmed trailing blanks) are padded, like SAS MISSOVER
      line = line.ljust(max_end) if line.size < max_end
      record = {}
      line.unpack(template).each_with_index do |field, i|
        field = field.lstrip
        name = names[i]
        record[name] =
          if field.empty? || field == "."
            nil
          elsif character[i]
            latin1(field)
          elsif field.match?(INTEGER)
            field.to_i
          elsif field.match?(FLOAT)
            field.to_f
          else
            stats[:invalid][name][0] += 1
            stats[:invalid][name][1] ||= latin1(field)
            nil
          end
      end
      yield record
    end
  end

  ## SAS transport files

  def xpt_sources
    Dir.glob("**/*.xpt", File::FNM_CASEFOLD, base: @raw_dir).sort.map do |f|
      path = File.join(@raw_dir, f)
      xpt = XptReader.new(path)
      abort "#{path}: #{xpt.members.size} members, only single-member files are supported" if xpt.members.size != 1
      member = xpt.members.first
      {
        name: File.basename(f).sub(/\.xpt\z/i, ""),
        title: member.label,
        data: path,
        variables: member.variables.map { |v| { name: v.name, label: v.label, type: v.type } },
        records: xpt.each_record,
      }
    end
  end

  ## Output

  # --long=27 (128 MB window) is the largest any zstd decoder accepts without
  # extra flags
  ZSTD = %w[zstd -q -f -19 --long=27 -T0 -o]

  def write_records(path, records)
    count = 0
    IO.popen([*ZSTD, "#{path}.tmp"], "w") do |out|
      records.each do |record|
        out.puts(JSON.generate(record))
        count += 1
      end
    end
    abort "zstd failed writing #{path}" unless $?.success?
    File.rename("#{path}.tmp", path)
    count
  end

  def write_jsonl(path, rows)
    File.write(path, rows.map { |r| JSON.generate(r) + "\n" }.join)
  end

  def latin1(bytes)
    bytes.force_encoding("ISO-8859-1").encode("UTF-8")
  end

  def find_case_insensitive(dir, name)
    Dir.children(dir).find { |c| c.casecmp?(name) }&.then { |c| File.join(dir, c) }
  end

  def relative(path)
    path.delete_prefix("#{ROOT}/")
  end
end
