module Ramaze
  class Reloader
    class StatFileWatcher
      def initialize
        # @files[file_path] = stat
        @files = {}
        @last = Time.now
      end

      # start watching a file for changes
      # true if succeeded, false if failure
      def watch(file)
        # if already watching
        return true if @files.has_key?(file)
        begin
          @files[file] = File.stat(file)
        rescue Errno::ENOENT, Errno::ENOTDIR
          # doesn't exist => failure
          return false
        end
        # success
        true
      end

      # stop watching a file for changes
      def remove_watch(file)
        @files.delete(file)
        true
      end

      # no need for cleanup
      def close
      end

      # return files changed since last call
      def changed_files interval
        return [] if interval and @last + interval < Time.now

        changed = []

        @files.each do |file, stat|
          new_stat = File.stat(file)
          if new_stat.mtime > stat.mtime
            changed << file
            @files[file] = new_stat
          end
        end
        @last = Time.now
        changed
      end
    end

    class InotifyFileWatcher
      POLL_INTERVAL = 1 # seconds
      def initialize
        @watcher = RInotify.new
        @changed = []
        @mutex = Mutex.new
        # TODO: define a finalizer to cleanup? -- reloader never calls #close
        @watcher_thread = Thread.new do
          while true
            # don't wait, just ask if events are available
            if @watcher.wait_for_events(POLL_INTERVAL)
              changed_descriptors = []
              @watcher.each_event do |ev|
                changed_descriptors << ev.watch_descriptor
              end
              @mutex.synchronize do
                @changed += changed_descriptors.map {|des| @watcher.watch_descriptors[des] }
              end
            end
          end
        end
      end

      def watch(file)
        if not @watcher.watch_descriptors.values.include?(file) and File.exist?(file)
          @mutex.synchronize { @watcher.add_watch(file, RInotify::MODIFY) }
          return true
        end
        false
      end

      def remove_watch(file)
        @mutex.synchronize { @watcher.rm_watch(file) }
        true
      end

      def close
        @watcher_thread.terminate
        @watcher.close
        true
      end

      # parameter not used
      def changed_files interval
        @mutex.synchronize do
          @tmp = @changed
          @changed = []
        end
        @tmp.uniq!
        @tmp
      end
    end

    begin
      gem 'RInotify', '>=0.9' # is older version ok?
      require 'rinotify'
      FileWatcher = InotifyFileWatcher
    rescue Gem::LoadError, LoadError
      # stat always available
      FileWatcher = StatFileWatcher
    end
  end
end
