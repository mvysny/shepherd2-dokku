# frozen_string_literal: true

# Test doubles for Shepherd2's seams: every process a verb would start, recorded instead of run, plus
# the two callbacks a front-end supplies. What the tests then assert is the *sequence* — which is the
# design (SOLUTION.md's registration flow), not an implementation detail. A reordering that put
# `network:set` after the first build would still work on a happy path and quietly build the first
# image on the wrong network.

# Records `dokku` invocations and replays canned answers.
#
#   dokku = DokkuDouble.new(exists: %w[apps:exists], output: { 'config:get' => "https://…\n" })
#
# `exists` is the set of `*:exists` guard calls that should answer yes; anything else answers no.
class DokkuDouble
  attr_reader :calls

  def initialize(exists: [], output: {}, fail_on: [])
    @calls = []
    @exists = exists
    @output = output
    @fail_on = fail_on
  end

  def run(*args)
    @calls << args
    raise Shepherd2::Error, "dokku #{args.join(' ')} failed" if fails?(args)

    true
  end

  def ok?(*args)
    @calls << args
    @exists.any? { |prefix| args.join(' ').start_with?(prefix) }
  end

  def capture(*args)
    @calls << args
    raise Shepherd2::Error, "dokku #{args.join(' ')} failed" if fails?(args)

    canned(args) || ''
  end

  def capture_or_nil(*args)
    @calls << args
    return nil if fails?(args)

    canned(args)
  end

  def json(*args)
    JSON.parse(capture(*args))
  end

  # The recorded calls as strings, which is what assertions read: ['apps:create demo', …].
  def commands = @calls.map { |args| args.join(' ') }

  # The recorded calls with the guards (`*:exists`) dropped — the mutations, in order.
  def mutations = commands.reject { |command| command.include?(':exists') }

  private

  def fails?(args) = @fail_on.any? { |prefix| args.join(' ').start_with?(prefix) }

  def canned(args)
    key = @output.keys.find { |prefix| args.join(' ').start_with?(prefix) }
    key && @output[key]
  end
end

# The progress a verb emitted, in order:
#
#   events = EventLog.new
#   shepherd(dokku, events: events).poll
#   events[:polling]   # => [{app: 'demo'}, {app: 'other'}]
#
# A verb renders nothing, so this is where a test looks for what the CLI would have printed.
class EventLog
  # @return [Array<Array(Symbol, Hash)>] every event, as +[kind, fields]+, in the order emitted.
  attr_reader :events

  def initialize = @events = []

  # @return [Proc] the callback to hand to Shepherd2's +on_event:+.
  def listener = ->(kind, fields) { @events << [kind, fields] }

  # @return [Array<Symbol>] the kinds emitted, in order.
  def kinds = @events.map(&:first)

  # @param kind [Symbol] the event to select.
  # @return [Array<Hash>] the fields of every event of that kind.
  def [](kind) = @events.select { |emitted, _| emitted == kind }.map(&:last)
end

# A lock that is always free, or never.
class LockDouble
  def initialize(busy: false)
    @busy = busy
  end

  def with_lock
    return :busy if @busy

    yield
  end

  def held_by_somebody_else? = @busy
end

class DockerDouble
  attr_reader :pruned

  # @param usage [Hash] the `docker system df -v` answer, with Docker's human size strings — the point
  #   of the double is that `stats` has to parse those back, so the canned data keeps them.
  # @param root_dir [String] what `docker info` would say.
  def initialize(usage: { 'Images' => [], 'Volumes' => [] }, root_dir: '/var/lib/docker')
    @pruned = 0
    @usage = usage
    @root_dir = root_dir
  end

  def prune
    @pruned += 1
    true
  end

  def disk_usage = @usage

  def root_dir = @root_dir
end

# The host's memory and disk, canned. Sizes are bytes, as Machine returns them.
class MachineDouble
  # @param memory [Hash{Symbol => Integer}] overrides on top of a stock 8 GiB box with no swap.
  # @param filesystems [Hash{String => Hash}] keyed by the path asked about; the default answers any
  #   path with one filesystem, which is the stock box where / and Docker's root are the same device.
  def initialize(memory: {}, filesystems: nil)
    @memory = { total: 8 * (1024**3), available: 4 * (1024**3),
                swap_total: 0, swap_free: 0 }.merge(memory)
    @filesystems = filesystems
  end

  def memory = @memory

  def filesystem(path)
    return @filesystems.fetch(path) if @filesystems

    { path: path, device: '/dev/sda1', mount: '/', total: 80 * (1024**3), free: 30 * (1024**3) }
  end
end
