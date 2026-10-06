# Reader for SAS transport (XPORT version 5) files, the .xpt format CDC uses
# for NHANES. Format spec: https://support.sas.com/content/dam/SAS/support/en/technical-papers/record-layout-of-a-sas-version-5-or-6-data-set-in-sas-transport-xport-format.pdf
#
# The file is a sequence of 80-byte records: library headers, then per member
# (dataset) a member header, a NAMESTR block describing each variable, and the
# observations packed back to back. Numbers are IBM mainframe floats.

class XptReader
  Variable = Struct.new(:name, :label, :type, :length, :position, keyword_init: true)
  Member = Struct.new(:name, :label, :variables, :data_offset, :data_length, keyword_init: true)

  RECORD = 80
  HEADER = "HEADER RECORD*******"

  attr_reader :path, :members

  def initialize(path)
    @path = path
    @bytes = File.binread(path)
    raise "#{path}: not a SAS XPORT v5 file" unless @bytes.start_with?("#{HEADER}LIBRARY HEADER RECORD")
    @members = parse_members
  end

  # Yields one Hash per observation: { "NAME" => value }, numeric missing
  # values and blank strings as nil.
  def each_record(member = @members.first)
    return enum_for(:each_record, member) unless block_given?
    row_length = member.variables.sum(&:length)
    return if row_length == 0
    stop = member.data_offset + member.data_length
    offset = member.data_offset
    while offset + row_length <= stop
      row = @bytes.byteslice(offset, row_length)
      # The last record is padded with blanks to 80 bytes
      break if row.count(" ") == row_length && offset + row_length > stop - RECORD
      yield member.variables.to_h { |v| [v.name, decode(v, row.byteslice(v.position, v.length))] }
      offset += row_length
    end
  end

  private

  def parse_members
    members = []
    offset = 3 * RECORD
    while header?(offset, "MEMBER  HEADER RECORD")
      namestr_size = @bytes.byteslice(offset + 74, 4).to_i
      descriptor = offset + 2 * RECORD
      name = @bytes.byteslice(descriptor + 8, 8).rstrip
      label = latin1(@bytes.byteslice(descriptor + RECORD + 32, 40)).rstrip
      namestr_header = descriptor + 2 * RECORD
      count = @bytes.byteslice(namestr_header + 54, 4).to_i
      namestr_start = namestr_header + RECORD
      variables = Array.new(count) { |i| parse_namestr(@bytes.byteslice(namestr_start + i * namestr_size, namestr_size)) }
      obs_header = namestr_start + pad(count * namestr_size)
      raise "#{path}: missing OBS header" unless header?(obs_header, "OBS     HEADER RECORD")
      data_offset = obs_header + RECORD
      next_member = @bytes.index("#{HEADER}MEMBER  HEADER RECORD", data_offset) || @bytes.bytesize
      members << Member.new(name: name, label: label.empty? ? nil : label, variables: variables,
                            data_offset: data_offset, data_length: next_member - data_offset)
      offset = next_member
    end
    raise "#{path}: no members found" if members.empty?
    members
  end

  def header?(offset, kind)
    marker = "#{HEADER}#{kind}"
    @bytes.byteslice(offset, marker.bytesize) == marker
  end

  def parse_namestr(bytes)
    type, _, length, _ = bytes.unpack("s>4")
    Variable.new(
      name: bytes.byteslice(8, 8).rstrip,
      label: latin1(bytes.byteslice(16, 40)).rstrip.then { |l| l.empty? ? nil : l },
      type: type == 1 ? "numeric" : "character",
      length: length,
      position: bytes.byteslice(84, 4).unpack1("l>"),
    )
  end

  def pad(size)
    (size + RECORD - 1) / RECORD * RECORD
  end

  def latin1(bytes)
    bytes.dup.force_encoding("ISO-8859-1").encode("UTF-8")
  end

  def decode(variable, bytes)
    if variable.type == "character"
      text = latin1(bytes).rstrip
      text.empty? ? nil : text
    else
      ibm_to_number(bytes)
    end
  end

  # IBM hex float: sign bit, 7-bit base-16 exponent biased by 64, 56-bit
  # fraction. Truncated to `length` bytes. Missing values (., ._, .A-.Z) are
  # a marker byte followed by zeros.
  def ibm_to_number(bytes)
    bytes = bytes.ljust(8, "\0")
    first = bytes.getbyte(0)
    fraction = bytes.byteslice(1, 7).unpack("C7").inject(0) { |acc, b| (acc << 8) | b }
    if fraction == 0
      return nil if first == 0x2e || first == 0x5f || (0x41..0x5a).cover?(first)
      return 0
    end
    value = fraction * 16.0**((first & 0x7f) - 64) / 2.0**56
    value = -value if first & 0x80 != 0
    # IBM floats carry 56 bits, more than a double. Round to 15 significant
    # digits so 69.3 doesn't come out as 69.30000000000001.
    value = Float(format("%.15g", value))
    value == value.round && value.abs < 2**53 ? value.to_i : value
  end
end
