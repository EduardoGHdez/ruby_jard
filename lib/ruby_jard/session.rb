# frozen_string_literal: true

module RubyJard
  ##
  # Centralized flow control and data storage to feed into screens. Each
  # process supposes to have only one instance of this class.
  # TODO: This class is created to store data, but byebug data structures are
  # leaked, and accessible from outside and this doesn't work if screens stay in
  # other processes. Therefore, an internal, jard-specific data mapping should
  # be built.
  class Session
    class << self
      def instance
        @instance ||= new
      end

      def attach
        unless instance.should_attach?
          $stdout.puts 'Failed to attach. Jard could not detect a valid tty device.'
          $stdout.puts 'This bug occurs when the process Jard trying to access is a non-interactive environment '\
            ' such as docker, daemon, sub-processes, etc.'
          $stdout.puts 'If you are confused, please submit an issue in https://github.com/nguyenquangminh0711/ruby_jard/issues.'
          return
        end

        instance.start unless instance.started?
        if instance.should_skip?
          instance.reduce_skip
          return
        end

        Byebug.attach
        Byebug.current_context.step_out(3, true)
      end
    end

    OUTPUT_BUFFER_LENGTH = 10_000 # 10k lines

    attr_accessor :output_buffer, :path_filter, :screen_manager, :repl_proxy

    def initialize(options = {})
      @screen_manager = RubyJard::ScreenManager.new
      @repl_proxy = RubyJard::ReplProxy.new(
        console: @screen_manager.console,
        key_bindings: RubyJard.global_key_bindings
      )

      @options = options
      @started = false
      @session_lock = Mutex.new
      @output_buffer = []
      @skip = 0

      @current_frame = nil
      @current_backtrace = []
      @threads = []
      @current_thread = nil

      @path_filter = RubyJard::PathFilter.new
    end

    def start
      return if started?

      ##
      # Globally configure Byebug. Byebug doesn't allow configuration by instance.
      # So, I have no choice.
      # TODO: Byebug autoloaded configuration may override those values.
      Byebug::Setting[:autolist] = false
      Byebug::Setting[:autoirb] = false
      Byebug::Setting[:autopry] = false

      require 'ruby_jard/repl_processor'
      Byebug::Context.processor = RubyJard::ReplProcessor
      # Exclude all files in Ruby Jard source code from the stacktrace.
      Byebug::Context.ignored_files = Byebug::Context.all_files + RubyJard.all_files

      $stdout.send(:instance_eval, <<-CODE)
        def write(*string)
          RubyJard::Session.instance.append_output_buffer(string)
          super(*string)
        end
      CODE

      @screen_manager.start
      # Load configurations
      RubyJard.config

      at_exit { stop }
      @started = true
    end

    def append_output_buffer(string)
      @output_buffer.shift if @output_buffer.length > OUTPUT_BUFFER_LENGTH
      @output_buffer << string
    end

    def stop
      return unless started?

      @screen_manager.stop
      Byebug.stop if Byebug.stoppable?
    end

    def started?
      @started == true
    end

    def should_attach?
      @screen_manager.console.attachable?
    end

    def should_stop?(path)
      @path_filter.match?(path)
    end

    def sync(context)
      @current_context = context
      # Remove cache
      @current_frame = nil
      @current_thread = nil
      @current_backtrace = nil
      @threads = nil
    end

    def current_frame
      @current_frame ||=
        begin
          frame = RubyJard::Frame.new(@current_context, @current_context.frame.pos)
          frame.visible = @path_filter.match?(frame.frame_file)
          frame
        end
    end

    def current_thread
      @current_thread ||= RubyJard::ThreadInfo.new(@current_context.thread)
    end

    def current_backtrace
      @current_backtrace ||= generate_backtrace
    end

    def threads
      @threads ||=
        Thread
        .list
        .select(&:alive?)
        .reject { |t| t.name.to_s =~ /<<Jard:.*>>/ }
        .map { |t| RubyJard::ThreadInfo.new(t) }
    end

    def frame=(real_pos)
      @current_context.frame = @current_backtrace[real_pos].real_pos
      @current_frame = @current_backtrace[real_pos]
    end

    def step_into(times)
      @current_context.step_into(times, current_frame.real_pos)
    end

    def step_over(times)
      @current_context.step_over(times, current_frame.real_pos)
    end

    def lock
      raise RubyJard::Error, 'This method requires a block' unless block_given?

      # TODO: This doesn't solve anything. However, debugging a multi-threaded process is hard.
      # Let's deal with that later.
      @session_lock.synchronize do
        yield
      end
    end

    def skip(times)
      stop
      @skip = times
    end

    def reduce_skip
      if @skip > 0
        @skip -= 1
      else
        @skip = 0
      end
    end

    def should_skip?
      @skip > 0
    end

    private

    def generate_backtrace
      virtual_pos = 0
      backtrace = @current_context.backtrace.map.with_index do |_frame, index|
        frame = RubyJard::Frame.new(@current_context, index)
        if @path_filter.match?(frame.frame_file)
          frame.visible = true
          frame.virtual_pos = virtual_pos
          virtual_pos += 1
        else
          frame.visible = false
        end
        frame
      end
      current_frame.virtual_pos = backtrace[current_frame.real_pos].virtual_pos
      backtrace
    end
  end
end
