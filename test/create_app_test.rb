# frozen_string_literal: true

require_relative 'helper'

# What create-app must emit, in what order. The sequence is the design (SOLUTION.md, *Flow —
# registering a project*): a reordering that put the first build before `network:set` would still
# deploy, and would quietly build on the wrong network.
class CreateAppTest < Minitest::Test
  def test_full_sequence_for_a_new_app
    dokku = DokkuDouble.new
    shepherd(dokku).create_app('demo', 'https://github.com/me/demo', 'main',
                               owner: 'me@example.com', buildpack: 'heroku/java')

    assert_equal [
      'apps:create demo',
      'config:set --no-restart demo SHEPHERD_GIT_URL=https://github.com/me/demo SHEPHERD_OWNER=me@example.com',
      'resource:limit --memory 256m demo',
      'resource:limit --process-type build --memory 2g demo',
      'network:create app-demo',
      'network:set demo initial-network app-demo',
      'buildpacks:set demo heroku/java',
      'git:sync --build demo https://github.com/me/demo main'
    ], dokku.mutations
  end

  def test_git_url_is_written_before_the_first_build
    dokku = DokkuDouble.new
    shepherd(dokku).create_app('demo', 'https://github.com/me/demo')

    config = dokku.mutations.index { |c| c.include?('SHEPHERD_GIT_URL') }
    build  = dokku.mutations.index { |c| c.start_with?('git:sync') }
    assert config < build,
           'a project whose first build fails must already be in the poll, so the URL comes first'
  end

  def test_network_is_set_before_the_first_build
    dokku = DokkuDouble.new
    shepherd(dokku).create_app('demo', 'https://github.com/me/demo')

    network = dokku.mutations.index { |c| c.start_with?('network:set') }
    build   = dokku.mutations.index { |c| c.start_with?('git:sync') }
    assert network < build, "the first build's container must join the app's own network"
  end

  def test_rerun_over_an_existing_app_skips_creation_and_still_builds
    dokku = DokkuDouble.new(exists: ['apps:exists', 'network:exists'])
    shepherd(dokku).create_app('demo', 'https://github.com/me/demo', 'main')

    refute_includes dokku.mutations, 'apps:create demo'
    refute_includes dokku.mutations, 'network:create app-demo'
    assert_includes dokku.mutations, 'network:set demo initial-network app-demo'
    assert_includes dokku.mutations, 'git:sync --build demo https://github.com/me/demo main'
  end

  def test_defaults_are_256m_runtime_and_2g_build
    dokku = DokkuDouble.new
    shepherd(dokku).create_app('demo', 'https://github.com/me/demo')

    assert_includes dokku.mutations, 'resource:limit --memory 256m demo'
    assert_includes dokku.mutations, 'resource:limit --process-type build --memory 2g demo'
  end

  def test_cpu_limits_are_omitted_unless_asked_for
    dokku = DokkuDouble.new
    shepherd(dokku).create_app('demo', 'https://github.com/me/demo')

    assert_empty dokku.mutations.grep(/--cpu/)
  end

  def test_cpu_limits_are_passed_through_when_given
    dokku = DokkuDouble.new
    shepherd(dokku).create_app('demo', 'https://github.com/me/demo', nil, cpu: '1', build_cpu: '2')

    assert_includes dokku.mutations, 'resource:limit --memory 256m --cpu 1 demo'
    assert_includes dokku.mutations, 'resource:limit --process-type build --memory 2g --cpu 2 demo'
  end

  def test_no_ref_leaves_the_ref_off_the_sync
    dokku = DokkuDouble.new
    shepherd(dokku).create_app('demo', 'https://github.com/me/demo')

    assert_includes dokku.mutations, 'git:sync --build demo https://github.com/me/demo'
  end

  def test_build_dir_is_set_when_given
    dokku = DokkuDouble.new
    shepherd(dokku).create_app('demo', 'https://github.com/me/demo', nil, build_dir: 'web')

    assert_includes dokku.mutations, 'builder:set demo build-dir web'
  end

  def test_owner_is_omitted_when_not_given
    dokku = DokkuDouble.new
    shepherd(dokku).create_app('demo', 'https://github.com/me/demo')

    assert_includes dokku.mutations, 'config:set --no-restart demo SHEPHERD_GIT_URL=https://github.com/me/demo'
  end

  # D_admin_namespace: the whole prefix, so a future admin surface has a hostname waiting under the
  # wildcard certificate. A namespace is far cheaper to reserve than to reclaim.
  def test_admin_ids_are_refused_before_anything_is_mutated
    %w[admin admin-status admintools].each do |id|
      dokku = DokkuDouble.new
      error = assert_raises(UsageError) { shepherd(dokku).create_app(id, 'https://github.com/me/demo') }

      assert_match(/reserved/, error.message)
      assert_empty dokku.calls, "#{id}: nothing may be mutated before validation"
    end
  end

  # The app name is one DNS label under the wildcard: `foo.bar.mydomain.me` is not covered by
  # `*.mydomain.me`, so a dotted id would work over http and fail over https.
  def test_dotted_ids_are_refused
    dokku = DokkuDouble.new
    error = assert_raises(UsageError) { shepherd(dokku).create_app('foo.bar', 'https://github.com/me/demo') }

    assert_match(/one DNS label/, error.message)
    assert_empty dokku.calls
  end

  def test_malformed_ids_are_refused
    ['Demo', '-demo', 'demo_app', 'demo app', ''].each do |id|
      dokku = DokkuDouble.new
      assert_raises(UsageError, "#{id.inspect} should be refused") do
        shepherd(dokku).create_app(id, 'https://github.com/me/demo')
      end
      assert_empty dokku.calls
    end
  end

  def test_a_missing_url_is_refused
    dokku = DokkuDouble.new
    assert_raises(UsageError) { shepherd(dokku).create_app('demo', nil) }
    assert_empty dokku.calls
  end
end
