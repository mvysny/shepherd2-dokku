# frozen_string_literal: true

require_relative 'helper'
require 'rbconfig'

# D_ruby's central constraint, enforced rather than promised: the CLI must load with rubygems switched
# off, so it cannot have grown a gem dependency. The box installs `ruby` from the distro archive and
# nothing else — a `require` of anything outside the standard library would fail there, on a cron tick,
# in the dark.
class StdlibOnlyTest < Minitest::Test
  def test_the_cli_loads_with_rubygems_disabled
    cli = File.expand_path('../shepherd2', __dir__)
    ok = system(RbConfig.ruby, '--disable-gems', '-e', "load #{cli.dump}", out: File::NULL, err: File::NULL)

    assert ok, 'shepherd2 must load under `ruby --disable-gems`: it may use the standard library only'
  end
end
