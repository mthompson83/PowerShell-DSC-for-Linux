# frozen_string_literal: true
require 'test/unit'

# Do NOT include this test suite in the Unit_test.rb suite.
# This test suite tests that the HeartbeatUpload.rb does the right thing
# to include the version.rb file generated at RPM build time.

module PerformanceMetricsIsolation


  class PerfMetricsVersion_test < Test::Unit::TestCase

    def setup
    end

    def teardown
      File.delete VersionFileName
    rescue Errno::ENOENT
      # ok
    end

    def test_version_loaded
      assert_false File.exist? VersionFileName
      assert_raise NameError do (Kernel.const_get 'PerformanceMetrics'); end

      assert_raise LoadError do require_relative 'HeartbeatUpload.rb'; end
      assert_kind_of Module, (Kernel.const_get 'PerformanceMetrics')
      assert_raise NameError do (::PerformanceMetrics.const_get 'PerfMetricsVersion'); end

      assert_raise LoadError do require_relative 'HeartbeatUpload.rb'; end
      assert_raise NameError do (::PerformanceMetrics.const_get 'PerfMetricsVersion'); end

      expected_version = "1.2.3-1492"
      File.open(VersionFileName, "w") { |f|
        f.puts 'module PerformanceMetrics'
        f.puts "  PerfMetricsVersion = '#{expected_version}'"
        f.puts 'end # module PerformanceMetrics'
      }

      assert (require_relative 'HeartbeatUpload.rb')
      assert_equal expected_version, (::PerformanceMetrics.const_get 'PerfMetricsVersion')
    end

    VersionFileName = 'version.rb'

  end # class PerfMetricsVersion_test < Test::Unit::TestCase

end #module
