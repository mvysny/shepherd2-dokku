# frozen_string_literal: true

# Test doubles for the seams in `shepherd2`: every process the CLI would start, recorded instead of
# run. What the tests then assert is the *sequence* — which is the design (SOLUTION.md's registration
# flow), not an implementation detail. A reordering that put `network:set` after the first build would
# still work on a happy path and quietly build the first image on the wrong network.

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
    raise Shepherd2Error, "dokku #{args.join(' ')} failed" if fails?(args)

    true
  end

  def ok?(*args)
    @calls << args
    @exists.any? { |prefix| args.join(' ').start_with?(prefix) }
  end

  def capture(*args)
    @calls << args
    raise Shepherd2Error, "dokku #{args.join(' ')} failed" if fails?(args)

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

  def initialize = @pruned = 0

  def prune
    @pruned += 1
    true
  end
end
