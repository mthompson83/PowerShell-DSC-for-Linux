require 'yajl'
require 'fluent/input'
require 'fluent/event'
require 'fluent/config/error'
require 'fluent/parser'
require 'open3'
require_relative 'omslog'

module Fluent
  class SudoTail < Input
    Plugin.register_input('sudo_tail', self)

    def initialize
      super
      @command = nil
    end

    attr_accessor :command

    #The command (program) to execute.
    config_param :path, :string

    #The format used to map the program output to the incoming event.
    config_param :format, :string, default: 'none'

    #Tag of the event.
    config_param :tag, :string, default: nil

    #Fluentd will record the position it last read into this file.
    config_param :pos_file, :string, default: nil

    #The interval time between periodic program runs.
    config_param :run_interval, :time, default: nil

    #Start to read the log from the head of file.  
    config_param :read_from_head, :bool, default: false

    BASE_DIR = File.dirname(File.expand_path('..', __FILE__))
    RUBY_DIR = BASE_DIR + '/ruby/bin/ruby '
    TAILSCRIPT = BASE_DIR + '/plugin/tailfilereader.rb '

    def configure(conf)
      super
      unless @path
        raise ConfigError, "'path' parameter is not set to a 'tail' source."
      end
      
      unless @pos_file
        raise ConfigError, "'pos_file' is required to keep track of file"
      end 

      unless @tag 
        raise ConfigError, "'tag' is required on sudo tail"
      end

      unless @run_interval
        raise ConfigError, "'run_interval' is required for periodic tailing"      
      end

      @parser = Plugin.new_parser(conf['format'])
      @parser.configure(conf)
    end

    def start
      @finished = false
      @thread = Thread.new(&method(:run_periodic))
    end

    def shutdown
      @finished = true
      @thread.exit
      @thread.join
    end

    def receive_data(line) 
      es = MultiEventStream.new
      begin
        line.chomp!  # remove \n
        @parser.parse(line) { |time, record|
          if time && record
            es.add(time, record)
          else
            @log.warn "pattern doesn't match: #{line.inspect}"
          end
          unless es.empty?
            tag=@tag
            router.emit_stream(tag, es)
            @count += 1
          end
        }
      rescue => e
        @log.warn line.dump, error: e.to_s
        @log.debug_backtrace(e.backtrace)
      end
    end

    def receive_log(line)
      @log.warn "#{line}" if line.start_with?('WARN')
      @log.error "#{line}" if line.start_with?('ERROR')
      @log.info "#{line}" if line.start_with?('INFO')
      @log.debug "#{line}" if line.start_with?('DEBUG')
    end
 
    def set_system_command
      @command = "sudo " << RUBY_DIR << TAILSCRIPT << %Q{'#{@path}'} <<  " --log_level #{Log::LEVEL_TEXT[@log.level]}" << " -p #{@pos_file}"
    end

    def run_periodic
      set_system_command

      if @read_from_head
        sleep @run_interval
        Open3.popen3(@command + " --readfromhead") {|writeio, readio, errio, wait_thread|
          writeio.close
          readio.each {|line| receive_data(line)}
          errio.each {|line| receive_log(line)}
          wait_thread.value
        }
      end
      until @finished
        begin
          @count = 0
          Open3.popen3(@command) {|writeio, readio, errio, wait_thread|
            writeio.close
            while line = readio.gets
              receive_data(line)
            end

            while line = errio.gets
              receive_log(line)
            end
            
            wait_thread.value #wait until child process terminates
          }
          @log.debug "DEBUG Sent a total of #{@count} lines forward from #{@path} from in_sudo_tail."
          sleep @run_interval
        rescue
          @log.error "sudo_tail failed to run or shutdown child proces", error => $!.to_s, :error_class => $!.class.to_s
          @log.warn_backtrace $!.backtrace
        end
      end
    end
  end

end

