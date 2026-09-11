# frozen_string_literal: true

# Loaded by every test file. What it loads is the *library*, not the executable — that is the path a
# front-end other than the CLI takes, so the suite proves it works (D_api_surface). `cli_test.rb`
# loads `shepherd2-cli` on top of this for the handful of things only the CLI owns.

require 'minitest/autorun'
require 'stringio'
require 'json'

require_relative '../shepherd2'
require_relative 'dokku_double'

module Minitest
  class Test
    # A Shepherd2 wired to doubles.
    #
    # @param dokku [DokkuDouble] records the commands the verb emits.
    # @param docker [DockerDouble] counts prunes, and answers `stats` with canned disk usage.
    # @param machine [MachineDouble] canned memory and filesystems, for `stats`.
    # @param lock [LockDouble] free unless the test says otherwise.
    # @param events [EventLog] pass one of your own to assert on the progress a verb emitted.
    # @param confirm [#call] consents by default; pass a refusing one to test the other branch.
    # @return [Shepherd2]
    def shepherd(dokku, docker: DockerDouble.new, machine: MachineDouble.new, lock: LockDouble.new,
                 events: EventLog.new, confirm: ->(_id) { true })
      Shepherd2.new(dokku: dokku, docker: docker, machine: machine, lock: lock,
                    on_event: events.listener, confirm: confirm)
    end
  end
end
