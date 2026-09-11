# frozen_string_literal: true

require_relative 'helper'
require 'rbconfig'

# D_ruby's central constraint, enforced rather than promised: both files must load with rubygems
# switched off, so neither can have grown a gem dependency. The box installs `ruby` from the distro
# archive and nothing else — a `require` of anything outside the standard library would fail there, on
# a cron tick, in the dark.
class StdlibOnlyTest < Minitest::Test
  def loads_without_gems?(file)
    path = File.expand_path("../#{file}", __dir__)
    system(RbConfig.ruby, '--disable-gems', '-e', "load #{path.dump}", out: File::NULL, err: File::NULL)
  end

  def test_the_cli_loads_with_rubygems_disabled
    assert loads_without_gems?('shepherd2-cli'),
           'shepherd2-cli must load under `ruby --disable-gems`: it may use the standard library only'
  end

  # Separately, because a front-end that is not the CLI loads only this one — a gem required by
  # shepherd2-cli alone would leave the check above green and that caller broken.
  def test_the_library_loads_with_rubygems_disabled_on_its_own
    assert loads_without_gems?('shepherd2.rb'),
           'shepherd2.rb must load under `ruby --disable-gems`, without the executable'
  end
end
