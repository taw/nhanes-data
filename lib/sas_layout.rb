# Parses the SAS input programs CDC ships alongside the pre-1999 fixed-width
# data files (DU*.sas), and the optional companion format files (DU*_F.sas)
# that hold value labels.
#
# The programs are machine-generated and very regular:
#   INFILE 'C:\temp\DU1003.txt' ...;          (or FILENAME ref "path"; INFILE ref)
#   LENGTH  NAME 8  CHARNAME $3 ... ;
#   INPUT   NAME 1-5  OTHER 6 ... ;
#   LABEL   NAME = "Label" ... ;
#   VALUE   FMTNAME  1='Yes' 2='No' ... ;     (format files)
#   FORMAT  NAME FMTNAME. ... ;               (format files)

class SasLayout
  Variable = Struct.new(:name, :start, :end, :type, :label, :format, keyword_init: true)

  attr_reader :path, :title, :infile, :variables, :formats

  def initialize(path, format_path: nil)
    @path = path
    raw = read_raw(path)
    @title = raw[/^\s*\*\s*(?:Questionnaire|Data\s*file|File):\s*(.+?)\s*$/i, 1]
    source = strip_comments(raw)
    @infile = parse_infile(source)
    @variables = parse_input(source)
    apply_lengths(source)
    apply_labels(source)
    @formats = {}
    apply_formats(strip_comments(read_raw(format_path))) if format_path
  end

  private

  # The files are plain ASCII/Latin-1
  def read_raw(path)
    File.binread(path).force_encoding("ISO-8859-1").encode("UTF-8")
  end

  def strip_comments(source)
    source.gsub(%r{/\*.*?\*/}m, "")
  end

  # Either INFILE 'C:\temp\DU1003.txt' or FILENAME EXAM "D:\EXAM.DAT"; ... INFILE EXAM
  def parse_infile(source)
    target = source[/^\s*INFILE\s+(['"][^'"]+['"]|\w+)/i, 1] or return nil
    unless target.match?(/\A['"]/)
      target = source[/^\s*FILENAME\s+#{Regexp.escape(target)}\s+(['"][^'"]+['"])/i, 1] or return nil
    end
    target[1..-2].split(/[\\\/]/).last
  end

  def statements(source, keyword)
    source.scan(/^\s*#{keyword}\b(.*?);/im).map(&:first)
  end

  def parse_input(source)
    statements(source, "INPUT").flat_map do |body|
      body.scan(/^\s*(\S+)\s+\$?\s*(\d+)(?:\s*-\s*(\d+))?\s*$/).map do |name, start, finish|
        Variable.new(name: name, start: start.to_i, end: (finish || start).to_i, type: "numeric")
      end
    end
  end

  def apply_lengths(source)
    by_name = @variables.to_h { |v| [v.name.upcase, v] }
    statements(source, "LENGTH").each do |body|
      body.scan(/^\s*(\S+)\s+(\$)?\s*\d+\s*$/).each do |name, dollar|
        by_name[name.upcase]&.type = "character" if dollar
      end
    end
  end

  def apply_labels(source)
    by_name = @variables.to_h { |v| [v.name.upcase, v] }
    statements(source, "LABEL").each do |body|
      body.scan(/^\s*(\S+)\s*=\s*(["'])(.*?)\2\s*$/).each do |name, _, label|
        by_name[name.upcase]&.label = label.strip
      end
    end
  end

  def apply_formats(source)
    source.scan(/^\s*VALUE\s+(\$?\w+)(.*?);/im).each do |name, body|
      @formats[name.upcase] = body.scan(/^\s*(.+?)\s*=\s*(["'])(.*?)\2\s*$/).to_h { |code, _, label| [code.strip, label.strip] }
    end
    by_name = @variables.to_h { |v| [v.name.upcase, v] }
    statements(source, "FORMAT").each do |body|
      body.scan(/^\s*(\S+)\s+(\$?\w+)\.\s*$/).each do |name, format|
        by_name[name.upcase]&.format = format.upcase
      end
    end
  end
end
