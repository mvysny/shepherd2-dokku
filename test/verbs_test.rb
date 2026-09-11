# frozen_string_literal: true

require_relative 'helper'

# destroy-app must be create-app's exact inverse, and must leave no Docker network behind: the box
# leaks one per project destroyed otherwise (D_isolation).
class DestroyAppTest < Minitest::Test
  def test_destroys_cache_app_and_network_in_that_order
    dokku = DokkuDouble.new(exists: ['apps:exists', 'network:exists'])
    shepherd(dokku).destroy_app('demo', yes: true)

    assert_equal [
      'repo:purge-cache demo',
      'apps:destroy --force demo',
      'network:destroy --force app-demo'
    ], dokku.mutations
  end

  def test_a_failed_cache_purge_does_not_stop_the_destroy
    dokku = DokkuDouble.new(exists: ['apps:exists', 'network:exists'], fail_on: ['repo:purge-cache'])
    shepherd(dokku).destroy_app('demo', yes: true)

    assert_includes dokku.mutations, 'apps:destroy --force demo'
    assert_includes dokku.mutations, 'network:destroy --force app-demo'
  end

  def test_a_missing_network_is_not_an_error
    dokku = DokkuDouble.new(exists: ['apps:exists'])
    shepherd(dokku).destroy_app('demo', yes: true)

    assert_empty dokku.mutations.grep(/network:destroy/)
  end

  def test_an_unknown_app_is_refused_before_anything_is_destroyed
    dokku = DokkuDouble.new
    assert_raises(Shepherd2Error) { shepherd(dokku).destroy_app('demo', yes: true) }

    assert_empty dokku.mutations
  end
end

class PollTest < Minitest::Test
  APPS = "=====> My Apps\ndemo\nother\nhandmade\n"

  # Only apps create-app registered: one made by hand with `dokku apps:create` has no
  # SHEPHERD_GIT_URL and is not ours to poll.
  def test_polls_only_apps_with_a_git_url
    dokku = DokkuDouble.new(output: {
                              'apps:list' => APPS,
                              'config:get demo' => "https://github.com/me/demo\n",
                              'config:get other' => "https://github.com/me/other\n"
                            },
                            fail_on: ['config:get handmade'])

    assert_equal EXIT_OK, shepherd(dokku).poll
    assert_equal [
      'git:sync --build-if-changes demo https://github.com/me/demo',
      'git:sync --build-if-changes other https://github.com/me/other'
    ], dokku.mutations.grep(/git:sync/)
  end

  # One project's failure must not stop the projects after it in the list.
  def test_one_failing_app_does_not_stop_the_rest
    dokku = DokkuDouble.new(output: {
                              'apps:list' => APPS,
                              'config:get demo' => "https://github.com/me/demo\n",
                              'config:get other' => "https://github.com/me/other\n",
                              'config:get handmade' => "https://github.com/me/handmade\n"
                            },
                            fail_on: ['git:sync --build-if-changes demo'])

    assert_equal EXIT_FAILURE, shepherd(dokku).poll
    assert_includes dokku.mutations, 'git:sync --build-if-changes other https://github.com/me/other'
    assert_includes dokku.mutations, 'git:sync --build-if-changes handmade https://github.com/me/handmade'
  end

  # A tick that lands on a running build skips rather than queues, and says so with a zero exit code:
  # at 288 ticks a day, a noisy cron is a cron nobody reads.
  def test_a_busy_box_skips_the_tick_without_failing
    dokku = DokkuDouble.new
    result = shepherd(dokku, lock: LockDouble.new(busy: true)).poll

    assert_equal EXIT_OK, result
    assert_empty dokku.calls
  end
end

class RebuildTest < Minitest::Test
  def test_forces_a_build_from_the_stored_url
    dokku = DokkuDouble.new(exists: ['apps:exists'],
                            output: { 'config:get demo' => "https://github.com/me/demo\n" })

    assert_equal EXIT_OK, shepherd(dokku).rebuild('demo')
    assert_includes dokku.mutations, 'git:sync --build demo https://github.com/me/demo'
  end

  def test_an_app_shepherd2_did_not_register_is_refused
    dokku = DokkuDouble.new(exists: ['apps:exists'], fail_on: ['config:get demo'])
    error = assert_raises(Shepherd2Error) { shepherd(dokku).rebuild('demo') }

    assert_match(/SHEPHERD_GIT_URL/, error.message)
    assert_empty dokku.mutations.grep(/git:sync/)
  end

  # Fails fast rather than queueing behind a five-minute cron; EXIT_BUSY distinguishes it from a
  # build that actually failed.
  def test_a_busy_box_refuses_with_its_own_exit_code
    dokku = DokkuDouble.new(exists: ['apps:exists'],
                            output: { 'config:get demo' => "https://github.com/me/demo\n" })

    assert_equal EXIT_BUSY, shepherd(dokku, lock: LockDouble.new(busy: true)).rebuild('demo')
    assert_empty dokku.mutations.grep(/git:sync/)
  end
end

class WaitIdleTest < Minitest::Test
  def test_returns_immediately_when_nothing_is_building
    dokku = DokkuDouble.new(output: { 'builds:list' => '[]' })

    assert_equal EXIT_OK, shepherd(dokku).wait_idle(timeout: 0)
  end

  # A `git push` deploy never touches our lock, so Dokku's own view of running builds is the second
  # condition — either can be true without the other.
  def test_a_running_build_outside_the_lock_still_counts_as_busy
    running = JSON.generate([{ 'id' => 'x', 'app' => 'demo',
                               'status' => 'running', 'display_status' => 'running' }])
    dokku = DokkuDouble.new(output: { 'builds:list' => running })

    assert_equal EXIT_FAILURE, shepherd(dokku).wait_idle(timeout: 0)
  end

  # Every no-op poll tick leaves a record at `status: "running"` for good, and the cron writes one
  # every five minutes — so keying off `status` made wait-idle time out on every healthy box.
  # `display_status` is Dokku's own liveness check on the recorded pid.
  def test_an_abandoned_no_op_tick_does_not_count_as_busy
    abandoned = JSON.generate([{ 'id' => 'x', 'app' => 'demo',
                                 'status' => 'running', 'display_status' => 'abandoned' }])
    dokku = DokkuDouble.new(output: { 'builds:list' => abandoned })

    assert_equal EXIT_OK, shepherd(dokku).wait_idle(timeout: 0)
  end

  # Older records, and anything that predates the computed field, still have to be read.
  def test_a_record_without_display_status_falls_back_to_status
    running = JSON.generate([{ 'id' => 'x', 'app' => 'demo', 'status' => 'running' }])
    dokku = DokkuDouble.new(output: { 'builds:list' => running })

    assert_equal EXIT_FAILURE, shepherd(dokku).wait_idle(timeout: 0)
  end

  def test_the_poll_lock_alone_counts_as_busy
    dokku = DokkuDouble.new(output: { 'builds:list' => '[]' })

    assert_equal EXIT_FAILURE, shepherd(dokku, lock: LockDouble.new(busy: true)).wait_idle(timeout: 0)
  end

  # A box whose builds plugin has nothing to say must not block a deliberate reboot for an hour.
  def test_unreadable_build_records_do_not_block_a_reboot
    dokku = DokkuDouble.new(fail_on: ['builds:list'])

    assert_equal EXIT_OK, shepherd(dokku).wait_idle(timeout: 0)
  end
end

class ClearcacheTest < Minitest::Test
  def test_prunes_once_and_never_touches_dokku
    dokku = DokkuDouble.new
    docker = DockerDouble.new

    assert_equal EXIT_OK, shepherd(dokku, docker: docker).clearcache
    assert_equal 1, docker.pruned
    assert_empty dokku.calls
  end
end
