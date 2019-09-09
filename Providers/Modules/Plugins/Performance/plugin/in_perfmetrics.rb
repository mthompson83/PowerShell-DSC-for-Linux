# Copyright (c) 2019 Microsoft.  All rights reserved.

# frozen_string_literal: true


class Fluent::PerfMetrics < Fluent::Input
    require_relative 'oms_common'

    require_relative 'PerfMetricDataCollector.rb'
    require_relative 'PerfMetricsEngine.rb'

    Fluent::Plugin.register_input('perfmetrics', self)

    config_param :tag, :string
    config_param :poll, :integer, :default => 60
    config_param :log_level, :string, :default => "info"

    def initialize
        super
        @instance_id = self.class.name + "(" + Time.now.to_s + ")"
    end

    def configure(conf)
        super

        begin
            @heartbeat_uploader = conf[:MockMetricsEngine] || ::PerfMetrics::MetricsEngine.new
            @heartbeat_upload_configuration = make_heartbeat_configuration
        rescue Fluent::ConfigError
            raise
        rescue => ex
            @heartbeat_upload_configuration = nil
            @log.error "#{self}: Configuration exception: #{ex}"
            @log.debug_backtrace
            raise Fluent::ConfigError.new.exception("#{ex.class}: #{ex.message}")
        end

    end

    def start
        @log.debug "#{self}: starting ..."
        super
        start_heartbeat_upload
    end

    def shutdown
        @log.debug "#{self}: stopping ..."
        stop_heartbeat_upload
        @log.debug "#{self}: ... stopped"
        super
    end

    def to_s
     @instance_id
    end

private

    def make_heartbeat_configuration
        config = ::PerfMetrics::MetricsEngine::Configuration.new OMS::Common.get_hostname, @log, ::PerfMetrics::DataCollector.new
        config.poll = @poll
        config
    end

    def start_heartbeat_upload
        @heartbeat_uploader.start(@heartbeat_upload_configuration) { | message |
            begin
                wrapper = {
                    "DataType"  => "INSIGHTS_METRICS_BLOB",
                    #"IPName"    => "VMInsights",
                    "IPName"    => "ServiceMap",
                    "DataItems" => message,
                }
                router.emit @tag, Fluent::Engine.now, wrapper
                true
            rescue => ex
                @log.error "Unexpected exception from FluentD Engine: #{ex.message}"
                @log.debug_backtrace
                false
            end
        }
    end

    def stop_heartbeat_upload
        @heartbeat_uploader.stop
    end

end # class Fluent::PerfMetrics
