# Copyright (c) 2016-2017 Microsoft.  All rights reserved.

# frozen_string_literal: true

module PerfMetrics

  require_relative 'PerfMetricIDataCollector.rb'

  class MetricsEngine

      require 'json'
      require 'thread'

      def initialize
          @thread = nil
      end

      def start(config, &cb)
          raise ArgumentError, 'config is nil' if config.nil?
          raise ArgumentError, "config is not kind of #{Configuration}" unless config.kind_of? Configuration
          raise ArgumentError, 'proc required' if cb.nil?
          raise RuntimeError, 'already started' unless @thread.nil?
          @thread = PollingThread.new config.poll, config.computer, config.log, config.data_collector, cb
          nil
      end

      def stop
          return if @thread.nil?
          @thread = nil if @thread.stop
      end

      def running?
          (! @thread.nil?) && @thread.status
      end

      class Configuration
          def initialize(computer, log, data_collector)
              raise ArgumentError unless log
              raise ArgumentError, "#{data_collector.class.name}" unless data_collector.kind_of? IDataCollector
              @poll = 60 # seconds
              @computer = computer
              @data_collector = data_collector
              @log = log
          end

          def poll=(v)
              raise ArgumentError unless (v.kind_of? Numeric) && (v.real?) && (v >= 1)
              @poll = v
          end

          attr_reader :poll, :computer, :data_collector, :log

      end # class Configuration

  private

      class PollingThread < Thread
          def initialize(interval, computer, log, data_collector, cb)
              @mutex = Mutex.new
              @condvar = ConditionVariable.new
              @run = true
              @log = log
              @data_collector = data_collector
              @cb = cb
              @saved_exception = SavedException.new
              @saved_cpu_exception = SavedException.new
              @cummulative_data = CummulativeData.new
              super() {
                  abort_on_exception = false

                  @cummulative_data.initialize_from_baseline @data_collector.baseline
                  mma_ids = @data_collector.get_mma_ids
                  unless mma_ids
                          @log.error "Unable to get MMA IDs. Terminating"
                  else
                      MetricTuple.mma_ids (if mma_ids.kind_of? Array then mma_ids.map { |g| "m-#{g}" } else "m-#{mma_ids}" end)
                      MetricTuple.computer computer
                      begin
                              @log.info "Starting polling loop at #{interval} second interval"
                              while @run do
                                      @mutex.synchronize {
                                              @condvar.wait(@mutex, interval) if @run
                                      }
                                      yield_metrics_message() if @run
                              end
                      ensure
                              # protected_yield telemetry_message ConnectorStop
                              @log.info "Stopping polling"
                      end
                  end
              }
          end

          def stop
              @mutex.synchronize {
                  @run = false
                  @condvar.broadcast
              }
              self.join(5) || self.terminate
          end

          def yield_metrics_message()
              begin
                  begin #1
                      perf_data = gather_data
                      message = data_to_message perf_data
                      protected_yield message
                  rescue => std
                      @log.error_backtrace std.backtrace
                      @log.error std.message
                  end # begin #1
              rescue SystemCallError => ex
                  return "#{__FILE__}(#{__LINE__}): #{Time.now}" if @saved_exception.same(ex)
                  @log.error ex.message
                  @saved_exception = SavedException.new(ex)
              rescue => std
                  return "#{__FILE__}(#{__LINE__}): #{Time.now}" if @saved_exception.same(std)
                  @log.error std.message
                  @saved_exception = SavedException.new(std)
              end
          end

          def protected_yield(*args)
              @cb[*args]
          rescue => ex
              @log.error "Unexpected exception #{ex.inspect}"
              @log.error_backtrace ex.backtrace
              true    # if there was an exception, assume next steps should happen so as not to have it keep happening
          end

          def gather_data
              @log.debug "Gather Data"    # Don't delete, used in unit test
              data = Array.new
              start_sample
              [
                  :liveness,
                  :available_memory_mb,
                  :processor,
                  :logical_disks,
                  :network,
              ].each { |method|
                  begin
                      send(method) { |me| data << me }
                  rescue IDataCollector::Unavailable => un
                      # TODO
                  rescue => ex
                      @log.error "Unexpected exception #{ex.inspect}"
                      @log.error_backtrace ex.backtrace
                  end
              }
              end_sample
              return data
          rescue SystemCallError => sce
              @log.error sce.message
              @log.debug_backtrace
          rescue NoMemoryError, StandardError => ex
              @log.error ex.message
              @log.debug_backtrace
          end

          def data_to_message(data)
              data
          end

          def start_sample
              @data_collector.start_sample
          end

          def liveness
              yield MetricTuple.factory "Computer", "Heartbeat", 1
              nil
          end

          def available_memory_mb
              free, total = @data_collector.get_available_memory_kb
              free = mb_from_kb free
              total = mb_from_kb total
              yield MetricTuple.factory "Memory", "AvailableMB", free, { "#{MetricTuple::Origin}/memorySizeMB" => total }
              nil
          end

          def processor
              cpu_count_tag = { }
              begin
                  cpu_count_tag["#{MetricTuple::Origin}/totalCpus"] = @data_collector.get_number_of_cpus
              rescue => ex
                  now = Time.now
                  unless @saved_cpu_exception.same(ex)
                      @log.error ex.message
                      @log.debug_backtrace
                      @saved_cpu_exception = SavedException.new(ex)
                  end
              end
              uptime, idle = @data_collector.get_cpu_idle
              uptime, idle = @cummulative_data.get_cpu_time_delta uptime, idle
              raise IDataCollector::Unavailable.new "uptime delta is zero" if uptime.zero?
              yield MetricTuple.factory "Processor", "UtilizationPercentage",
                                  100.0 * (1.0 - ((idle * 1.0) / (uptime * 1.0))),
                                  cpu_count_tag
              nil
          end

          def logical_disks
            @data_collector.get_filesystems.each { |fs|
                common_tag = { "#{MetricTuple::Origin}/mountId" => fs.mount_point }
                yield MetricTuple.factory "LogicalDisk", "Status", 1, common_tag
                yield MetricTuple.factory "LogicalDisk", "FreeSpacePercentage", (100.0 * fs.free_space_in_bytes) / fs.size_in_bytes, common_tag
                yield MetricTuple.factory "LogicalDisk", "FreeSpaceMB",
                                    fs.free_space_in_bytes / (1024 * 1024),
                                    common_tag.merge({"#{MetricTuple::Origin}/diskSizeMB" => fs.size_in_bytes / (1024 * 1024)})
            }
            nil
          end

          def network
            @data_collector.get_net_stats.each { |d|
                yield make_network_metric d.delta_time, d.device, "ReadBytesPerSecond", d.bytes_received
                yield make_network_metric d.delta_time, d.device, "WriteBytesPerSecond", d.bytes_sent
            }
            nil
          end

          def end_sample
              @data_collector.end_sample
          end

      private

        def make_network_metric(delta_time, dev, name, bytes)
            MetricTuple.factory "Network", name,
                (bytes.to_f / delta_time.to_f),
                {
                    "#{MetricTuple::Origin}/networkDeviceId" => dev,
                    "#{MetricTuple::Origin}/bytes" => bytes
                }
        end

          class SavedException
              def initialize(ex = nil)
                  @ex = ex
                  @timeout = Time.now + (60 * 60)
              end

              def same(ex)
                  @ex && (@ex == ex) && (Time.now < @timeout)
              end
          end

          def mb_from_kb(kb)
              kb /= 1024.0
          end

          class CummulativeData
              def initialize
                  @uptime = 0
                  @idle_time = 0
              end

              def initialize_from_baseline(baseline)
                  u = baseline[:up]
                  @uptime = u unless u.nil?
                  i = baseline[:idle]
                  @idle_time = i unless i.nil?
              end

              def get_cpu_time_delta(uptime, idle)
                  uptime_delta = (uptime - @uptime)
                  @uptime = uptime
                  idle_delta = (idle - @idle_time)
                  @idle_time = idle
                  return uptime_delta, idle_delta
              end
          end

          class MetricTuple < Hash
              def self.factory(namespace, name, value, tags = {})
                  result = {}
                  raise ArgumentError, "tags (#{tags.class}) must be a Hash" unless tags.kind_of? Hash
                  tags = Hash.new.merge! tags
                  tags["#{Origin}/machineId"] = @@mma_ids

                  result[:Origin] = Origin
                  result[:Namespace] = namespace
                  result[:Name] = name
                  result[:Value] = value
                  result[:Tags] = JSON.generate(tags)
                  result[:CollectionTime] = Time.new.utc.strftime("%FT%TZ")
                  result[:Computer] = @@computer if @@computer

                  result
              end

              def self.computer(name)
                  raise ArgumentError, "name must be a string or nil" unless name.nil? || name.kind_of?(String)
                  @@computer = name
              end

              def self.mma_ids(ids)
                  raise ArgumentError, "MMA IDs cannot be nil" if ids.nil?
                  @@mma_ids = ids
              end

              @@computer = nil
              @@mma_ids = nil

              Origin = "vm.azm.ms"
          end # class MetricTuple

      end # class PollingThread

  end # class

end #module
