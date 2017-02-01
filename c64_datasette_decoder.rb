# This script is a proof of concept for decoding data recorded on cassette tapes
# with / for a Commodore 64 (using the default “Kernal” routines). It reads
# audio data from a file named `sampledata.wav` and prints a hexdump of the
# decoded bytes to stdout.
#
# More info about the data encoding used on these tapes can be found here:
# http://c64tapes.org/dokuwiki/doku.php?id=loaders:rom_loader

require 'bundler/inline'
require 'logger'

gemfile do
  source 'https://rubygems.org'
  gem 'wavefile', '~> 0.7'
end

LOG_LEVEL = Logger::DEBUG # Use `Logger::ERROR` to suppress debugging output
$logger = Logger.new($stderr).tap do |l|
  l.level = LOG_LEVEL
  l.formatter = ->(severity, _datetime, _progname, msg) do
    "#{severity[0]}: #{msg}\n"
  end
end

def error(msg)
  $logger.error(msg)
  exit
end

# This class behaves like `Enumerator`, but it also has all the methods from
# `Enumerable` mixed in, and there is an additional `position` field (useful for
# debugging output).
class DataStream
  include Enumerable
  attr_reader :position

  def initialize(&block)
    @enum = Enumerator.new(&block)
    @position = 0
  end

  def each
    loop do
      yield @enum.next
      @position += 1
    end
  end

  def next
    @enum.next
  end
end

# First step: Create a data stream of raw audio sample data. Note that we read
# the audio file in chunks of 64K so that we can efficently process arbitrarily
# large files. (This works because we use enumerators all the way down meaning
# the sample data is only loaded when it’s actually needed. Look for the
# “Reading 64k Block” messages in the debugging output to see the effect).
samples = DataStream.new do |yielder|
  WaveFile::Reader.new('sampledata.wav').each_buffer(65_536) do |buffer|
    $logger.debug "Reading 64k Block"
    buffer.samples.each do |sample|
      yielder << sample
    end
  end
end


# Calculate the pulse widths by looking at the distance between two falling
# edges crossing the center line, i.e. pairs of sample values where the first
# one is positive and the second is negative. Additionally, we require the
# difference of these two values to be above a certain threshold to make sure we
# only detect steep edges belonging to pulses with a certain amplitude.
#
# The threshold value was determined by trial and error and might need to be
# adjusted for recordings with different amplitudes.
EDGE_THRESHOLD = 2_000
pulse_widths = DataStream.new do |yielder|
  pulse_width = 0
  samples.each_cons(2) do |a, b|
    pulse_width += 1
    if a - b > EDGE_THRESHOLD && a >= 0 && b < 0
      yielder << pulse_width
      pulse_width = 0
    end
  end
end

# Determine the width of a short pulse by taking the first 100 sync pulses and
# calculating their median (a few pulses at the start may be skewed because of
# tape motor speed issues).
#
# Note that this should ideally be done again at the start of each block instead
# of doing it only once at the very start of the first block. Feel free to
# create a pull request! :-)
short_pulse_width = pulse_widths.first(100).sort[50]
$logger.info "Determined short pulse width: #{short_pulse_width}"

# Calculate pulse width thresholds based on the width of a short pulse. We need
# to allow some overshoot because of wow and flutter.
PULSE_WIDTH_OVERSHOOT_FACTOR = 1.1
pulse_width_thresholds = {
  'S' => short_pulse_width * PULSE_WIDTH_OVERSHOOT_FACTOR,
  'M' => short_pulse_width * PULSE_WIDTH_OVERSHOOT_FACTOR * 1.4,
  'L' => short_pulse_width * PULSE_WIDTH_OVERSHOOT_FACTOR * 1.9,
}
$logger.info "Pulse width thresholds: #{pulse_width_thresholds}"

# Classify pulses by comparing them to the thresholds.
pulse_classifier = ->(width) do
  pulse_width_thresholds.each do |type, expected_width|
    return type if width < expected_width
  end
  return "?(#{width})"
end

decoded_pulses = DataStream.new do |yielder|
  pulse_widths.each do |width|
    yielder << pulse_classifier.call(width)
  end
end

# Read and decode whole blocks of data.
blocks = DataStream.new do |yielder|
  loop do
    $logger.info "Start parsing block at #{samples.position}"

    # Each block starts with a sync leader containg short pulses only. We skip
    # over it until we find the first “start of byte” marker (long pulse
    # followed by a medium pulse).
    decoded_pulses.take_while{ |type| type != 'L' }
    error "Expected M at #{samples.position}" unless decoded_pulses.next == 'M'
    $logger.info "End of leader found at #{samples.position}"

    # Now we can finally decode the real data.
    bytes = DataStream.new do |yielder|
      bits = []
      decoded_pulses.each_slice(2) do |a, b|
        if a == 'S' && b == 'M'
          bits << 0
        elsif a == 'M' && b == 'S'
          bits << 1
        elsif a == 'L' && b == 'M'
          # We found the next “start of byte” marker. This means we should
          # now have read a complete byte (9 bits, because there is 1 parity
          # bit).
          error "\nRead error: Found only #{bits.size} at #{samples.position}" unless bits.size == 9
          # Check the parity.
          parity = bits.pop
          parity_ok = bits.count(1).even? && parity == 1 || bits.count(1).odd? && parity == 0
          error "Read error: Incorrect parity #{parity} for #{bits} at #{samples.position}" unless parity_ok
          # Convert the bits to a byte (note that the bytes are stored on tape
          # with the LSB coming first).
          byte = bits.each.with_index.inject(0){ |acc, (bit, i)| acc + (bit << i) }
          yielder << byte
          bits = []
        elsif a == 'L' && b == 'S'
          # The “end-of-data marker” is optional and we can simply ignore
          # it. See http://c64tapes.org/dokuwiki/doku.php?id=loaders:rom_loader
          # for details.
          $logger.info "End-of-data marker at #{samples.position}"
          break
        else
          error "Read error: #{a} #{b} at #{samples.position}"
          break
        end
      end
    end

    yielder.yield bytes
  end
end

blocks.each do |block|
  $logger.info "Successfully decoded a data block!"
  puts block.map{ |byte| "%02x" % byte }.join(" ")
end
