# Copyright (c) 2016-2017 Microsoft.  All rights reserved.

# frozen_string_literal: true

require 'scanf'

module PerfMetrics
    require_relative 'PerfMetricIDataCollector.rb'

    class DataCollector < IDataCollector
        def initialize(root_directory_name="/")
            @root = root_directory_name
            @baseline_exception = RuntimeError.new "baseline has not been called"
            @mma_id = nil
            @cpu_count = nil
            @saved_net_data = nil
        end

        def baseline
            @mma_ids = load_mma_ids
            @baseline_exception = nil
            @cpu_count, is_64_bit = get_cpu_info_baseline
            RawNetData.set_32_bit(! is_64_bit)
            @saved_net_data = get_net_data
            u, i = get_cpu_idle
            { :up => u, :idle => i }
        end

        def start_sample
        end

        def end_sample
        end

        def get_mma_ids
            raise @baseline_exception if @baseline_exception
            raise IDataCollector::Unavailable, "no MMA ids found" unless @mma_ids
            @mma_ids
        end

        def get_available_memory_kb
            available = nil
            total = nil
            File.open(File.join(@root, "proc", "meminfo"), "rb") { |f|
                begin
                    line = f.gets
                    next if line.nil?
                    line.scanf("%s%d%s") { |label, value, uom|
                        if (label == "MemTotal:" && value >= 0 && uom == "kB")
                            total = value
                        elsif (label == "MemAvailable:" && value >= 0 && uom == "kB")
                            available = value
                        end
                    }
                end until f.eof?
            }

            raise IDataCollector::Unavailable, "Available memory not found" if available.nil?
            raise IDataCollector::Unavailable, "Total memory not found" if total.nil?

            return available, total
        end

        # returns: cummulative uptime, cummulative idle time
        def get_cpu_idle
            uptime = nil
            idle = nil
            File.open(File.join(@root, "proc", "uptime"), "rb") { |f|
                line = f.gets
                next if line.nil?
                line.scanf(" %f %f ") { |u, i|
                    uptime = u
                    idle = i
                }
            }

            raise IDataCollector::Unavailable, "Uptime not found" if uptime.nil?
            raise IDataCollector::Unavailable, "Idle time not found" if idle.nil?

            return uptime, idle
        end

        # returns:
        #   number of CPUs available for scheduling tasks
        # raises:
        #   Unavailable if not available
        def get_number_of_cpus
            raise @baseline_exception if @baseline_exception
            raise @cpu_count if @cpu_count.kind_of? StandardError
            @cpu_count
        end

        # return:
        #   An array of objects with methods:
        #       mount_point
        #       size_in_bytes
        #       free_space_in_bytes
        #       device_name
        def get_filesystems
            result = []
            df = File.join(@root, "bin", "df")
            IO.popen([df, "--block-size=1", "--output=fstype,source,target,size,avail" ], { :in => :close, :err => File::NULL }) { |io|
                while (line = io.gets)
                    if (line =~ /ext[234]/)
                        begin
                            a = line.split(" ")
                            result << Fs.new(a[1], a[2], a[3], a[4]) if a.size == 5
                        rescue ArgumentError => ex
                            # malformed input
                        end
                    end
                end
            }
            result
        rescue => ex
            raise Unavailable.new ex.message
        end

        # returns:
        #   An array of objects with methods:
        #       device
        #       bytes_received  since last call or baseline
        #       bytes_sent      since last call or baseline
        #   Note: Only devices that are "UP" or had activity are included
        def get_net_stats
            raise @baseline_exception if @baseline_exception
            result = []
            new_data = get_net_data
            new_data.each_pair { |key, new_value|
                previous_value = @saved_net_data[key]
                if previous_value.nil?
                    result << new_value if new_value.up
                else
                    diff = new_value - previous_value
                    result << diff if (new_value.up || diff.active?)
                end
            }
            @saved_net_data = new_data
            result
        end

    private

        class NetData
            def initialize(d, r, s)
                @device = -d
                @bytes_received = r
                @bytes_sent = s
            end

            def active?
                (@bytes_received > 0) || (@bytes_sent > 0)
            end

            attr_reader :device, :bytes_received, :bytes_sent

        end

        class RawNetData < NetData
            def initialize(d, u, r, s)
                super(d, r, s)
                @up = u
            end

            attr_reader :up

            def -(other)
                NetData.new @device,
                            sub_with_wrap(@bytes_received, other.bytes_received),
                            sub_with_wrap(@bytes_sent, other.bytes_sent)
            end

            @@counter_modulus = (2 ** 64)   # default to 64 bit

            def self.set_32_bit(is32bit)
                @@counter_modulus = (2 ** (is32bit ? 32 : 64))
            end

            private

            def sub_with_wrap(a, b)
                (@@counter_modulus + a - b) % @@counter_modulus
            end
        end

        def get_net_data
            sys_devices_virtual_net = File.join(@root, "sys", "devices", "virtual", "net")
            devices_up = get_up_net_devices
            result = { }
            File.open(File.join(@root, "proc", "net", "dev"), "rb") { |f|
                while (line = f.gets)
                    line = line.split(" ")
                    next if line.empty?
                    dev = line[0]
                    next unless ((0...10).include? dev.length) && (dev.end_with? ":")
                    dev.chop!
                    next if Dir.exist? File.join(sys_devices_virtual_net, dev)
                    result[dev] = RawNetData.new(dev, devices_up[dev], line[1].to_i, line[9].to_i)
                end
            }
            result
        end

        def get_up_net_devices
            result = Hash.new(false)
            begin
                File.open(File.join(@root, "proc", "net", "route")) { |f|
                    f.gets # skip the header
                    while (line = f.gets)
                        dev = line.partition(" ")[0]
                        result[dev] = true unless dev.empty?
                    end
                }
            rescue => ex
                # need to log
            end
            result
        end

        class Fs
            def initialize(device, mount_point, size, free)
                raise ArgumentError, device unless device.start_with?("/dev/")
                raise ArgumentError, mount_point unless mount_point.start_with? "/"
                @dev = device
                @mp = mount_point
                @size = Integer(size, 10)
                raise ArgumentError, size if (@size == 0)
                @free = Integer(free, 10)
            end

            def <=>(o)
                r = dev <=> o.dev
                return r unless r.zero?
                r = mp <=> o.mp
                return r unless r.zero?
                r = size <=> o.size
                return r unless r.zero?
                free <=> o.free
            end

            attr_reader :dev, :mp, :size, :free
            alias_method :to_s, :inspect
        end

        def load_mma_ids
            multihome_capable = false
            ids = []
            oms_base_dir = File.join @root, "etc", "opt", "microsoft", "omsagent"
            Dir.glob(File.join(oms_base_dir, "????????-????-????-????-????????????", "conf", "omsadmin.conf")) { |p|
                multihome_capable = true
                IO.foreach(p) { |s|
                    if (s.start_with? "AGENT_GUID=")
                        ids << s.chomp.split("=")[1]
                        break
                    end
                }
            }
            # fallback for OMS Agent older versions that don't support multi-homing
            unless multihome_capable
                Dir.glob(File.join(oms_base_dir, "conf", "omsadmin.conf")) { |p|
                    IO.foreach(p) { |s|
                        if (s.start_with? "AGENT_GUID=")
                            ids << s.chomp.split("=")[1]
                            break
                        end
                    }
                }
            end
            case ids.size
                when 0
                    nil
                when 1
                    ids[0]
                else
                    ids
            end
        end

        def get_cpu_info_baseline
            lscpu = File.join(@root, "usr", "bin", "lscpu")
            count = 0
            IO.popen([lscpu, "-p" ], { :in => :close, :err => File::NULL }) { |io|
                while (line = io.gets)
                    count += 1 if ('0' .. '9').member?(line[0])
                end
            }
            is_64_bit = false
            IO.popen({"LC_ALL" => "C"}, lscpu, { :in => :close, :err => File::NULL }) { |io|
                while (line = io.gets)
                    if line.start_with? "CPU op-mode(s):"
                        is_64_bit = (line.include? "64-bit")
                        break
                    end
                end
            }

            return count, is_64_bit
        rescue => ex
            return (Unavailable.new ex.message), true
        end

    end # DataCollector

end #module
