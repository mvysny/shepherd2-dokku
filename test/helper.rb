# frozen_string_literal: true

# Loaded by every test file. `shepherd2` has no .rb extension, so it is `load`ed rather than required;
# its `$PROGRAM_NAME == __FILE__` guard is what keeps that from running the CLI.

require 'minitest/autorun'

load File.expand_path('../shepherd2', __dir__)

require_relative 'dokku_double'

module Minitest
  class Test
    # A Shepherd2 wired to doubles, with both streams swallowed so a passing run stays quiet.
    #
    # @param dokku [DokkuDouble] records the commands the verb emits.
    # @param docker [DockerDouble] counts prunes, and answers `stats` with canned disk usage.
    # @param machine [MachineDouble] canned memory and filesystems, for `stats`.
    # @param lock [LockDouble] free unless the test says otherwise.
    # @param out [IO] pass a StringIO of your own to assert on what the verb printed — which is the
    #   whole output of a reporting verb like +last-build+, where there are no commands to record.
    # @param err [IO] likewise for warnings.
    # @return [Shepherd2]
    def shepherd(dokku, docker: DockerDouble.new, machine: MachineDouble.new, lock: LockDouble.new,
                 out: StringIO.new, err: StringIO.new)
      Shepherd2.new(dokku: dokku, docker: docker, machine: machine, lock: lock, out: out, err: err)
    end
  end
end
