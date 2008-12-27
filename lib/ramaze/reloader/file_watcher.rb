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
        @changed = Set.new
        @files = Set.new
        @mutex = Mutex.new

        # TODO: define a finalizer to cleanup? -- reloader never calls #close
        @watcher_thread = Thread.new do
          while true
            if @watcher.wait_for_events(POLL_INTERVAL)
              changed = Set.new
              @watcher.each_event do |ev|
                dir = @watcher.watch_descriptors[ev.watch_descriptor]
                if dir
                  full_path = File.join(dir, ev.name)
                  changed << full_path if @files.include? full_path
                end
              end
              @mutex.synchronize { @changed += changed }
            end
          end
        end
      end

      def watch(file)
        if File.exist?(file)
          dirname = File.dirname(file)           
					@files << file
          # if not already watching the directory
          if not @watcher.watch_descriptors.values.include?(dirname)
            @mutex.synchronize do
              @watcher.add_watch(File.dirname(file), RInotify::CREATE | RInotify::MOVED_TO | RInotify::CLOSE_WRITE | RInotify::MODIFY)
            end
          end
          return true
        end
        false
      end

      def remove_watch(file)
        @files.delete file
        @mutex.synchronize do
          @watcher.rm_watch( @watcher.watch_descriptors.find {|k,v| v == file }.first )
        end rescue nil
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
          @changed = Set.new
        end
        @tmp
      end
    end
  end
end
